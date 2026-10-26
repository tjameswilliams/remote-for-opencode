import RemoteKit
import Foundation
import OSLog

/// The compatibility seam: mobile protocol v1 on one side, whatever OpenCode
/// version is installed on the other. Everything version-specific about
/// OpenCode's API lives in this file — endpoint paths, event names, JSON
/// shapes — so when OpenCode churns, this file changes and the phone app
/// doesn't. Verified against 1.18.10; docs/protocol-v1.md records the
/// contract and the skew already observed.
///
/// OpenCode 2 replaced the whole HTTP API (everything under `/api/`, a new
/// event vocabulary, messages without parts). It is served by the same
/// type: `api` says which generation the server speaks, each operation
/// branches on it, and the 2.x path (OpenCodeAdapterV2.swift) translates
/// what it reads back into the 1.x shapes everything downstream already
/// consumes. Callers never branch.
///
/// JSON is handled as dictionaries rather than Codable models on purpose:
/// the adapter's job is tolerating shape drift, and a typed decode that
/// throws on a renamed field is the opposite of that.
struct OpenCodeAdapter {
    let port: Int
    /// Which generation of OpenCode's HTTP API the server speaks.
    var api: API = .v1
    /// The server password, sent as HTTP Basic auth (username `opencode`).
    /// OpenCode 2 always requires one; 1.x only when configured.
    var password: String?
    let logger = Logger(subsystem: "com.timwilliams.opencodego", category: "adapter")

    enum API: String {
        /// OpenCode 1.x: `/session`, `/event`, `/global/health`.
        case v1
        /// OpenCode 2.x: everything under `/api/`, verified on 2.1.4.
        case v2
    }

    var base: String { "http://127.0.0.1:\(port)" }

    /// Which API a freshly started server speaks, and its version. Nil
    /// while it isn't answering yet. 2.x is asked first because its
    /// web app answers every unknown path, `/global/health` included,
    /// with a 200 and an HTML page.
    static func probe(port: Int, password: String?) async -> (api: API, version: String)? {
        let v2 = OpenCodeAdapter(port: port, api: .v2, password: password)
        if let info = try? await v2.get("/api/info", timeout: healthTimeout) as? [String: Any],
           let version = info["version"] as? String {
            return (.v2, version)
        }
        let v1 = OpenCodeAdapter(port: port, api: .v1, password: password)
        if let health = try? await v1.health(), health.healthy {
            return (.v1, health.version)
        }
        return nil
    }

    /// `Authorization` for the server password, nil without one.
    var authorization: String? {
        guard let password, !password.isEmpty else { return nil }
        return "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
    }

    // MARK: - Plumbing

    /// The session for one-shot requests. Separate from the event streams
    /// (see `EventStreamHub`) so that no number of open streams can queue
    /// a request behind them, and sized for a phone that fires several
    /// requests at once on reconnect. The idle timeout is short on
    /// purpose: a request that has gone quiet for this long is a stuck
    /// server, and a `failed` the phone can show beats a spinner.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Seconds a request may go without any data before it fails.
    static let requestTimeout: TimeInterval = 30
    /// For the calls that block for a whole turn: `POST /command` returns
    /// when the command has run, and a `/review` runs for minutes.
    static let turnTimeout: TimeInterval = 15 * 60
    /// The health check gates the handshake's `ready`; the phone waits four
    /// seconds for that on the LAN, so a slow answer is as good as none.
    static let healthTimeout: TimeInterval = 5

    func get(
        _ path: String, directory: String? = nil, timeout: TimeInterval = Self.requestTimeout
    ) async throws -> Any {
        try await request(path, method: "GET", directory: directory, body: nil, timeout: timeout)
    }

    @discardableResult
    func post(
        _ path: String, directory: String? = nil, body: [String: Any]? = [:],
        timeout: TimeInterval = Self.requestTimeout
    ) async throws -> Any {
        try await request(path, method: "POST", directory: directory, body: body, timeout: timeout)
    }

    /// The query parameter that names the working directory: 1.x took
    /// `directory`, 2.x takes `location[directory]`.
    var directoryParameter: String { api == .v2 ? "location[directory]" : "directory" }

    @discardableResult
    func request(
        _ path: String, method: String, directory: String?, body: [String: Any]?,
        timeout: TimeInterval = Self.requestTimeout
    ) async throws -> Any {
        var components = URLComponents(string: base + path)!
        if let directory {
            // Encoded by hand: URLComponents leaves the brackets of
            // `location[directory]` bare, and a path can hold `&` or `+`.
            components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? []) + [
                URLQueryItem(
                    name: Self.queryEncoded(directoryParameter), value: Self.queryEncoded(directory)
                ),
            ]
        }
        var req = URLRequest(url: components.url!, timeoutInterval: timeout)
        req.httpMethod = method
        if let authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AdapterError.http(
                path: path, status: status, body: Self.readableError(from: data, status: status)
            )
        }
        // Some endpoints answer with nothing — prompt_async is a 204 —
        // and an empty body is success, not JSON to choke on.
        guard !data.isEmpty else { return NSNull() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// A query name or value, percent-encoded strictly enough for any
    /// server to read back exactly.
    static func queryEncoded(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#[]")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    enum AdapterError: LocalizedError {
        /// `status` 0 means no HTTP status existed: a synthesized error, or
        /// a response with no usable status line.
        case http(path: String, status: Int, body: String)
        case unknownCommand(String)
        /// An attachment no model could read, or a text file too large
        /// to inline. Named by file, so the user knows which to drop.
        case attachment(String)

        var errorDescription: String? {
            switch self {
            case let .http(path, _, body): return "OpenCode \(path): \(body)"
            case let .unknownCommand(name):
                return "No command named \"/\(name)\" in OpenCode on this Mac."
            case let .attachment(reason): return reason
            }
        }

        /// Worth retrying without asking anyone. Rides Wire.Event.transient
        /// out to clients and drives the scheduler's retry loop.
        var isTransient: Bool {
            switch self {
            case let .http(_, status, _): return RetryPolicy.isTransientHTTPStatus(status)
            case .unknownCommand, .attachment: return false
            }
        }
    }

    /// The one classification callers use: adapter errors answer for
    /// themselves, and a URLError (connection refused while OpenCode
    /// restarts, a timed-out socket) is transient by nature.
    static func isTransient(_ error: Error) -> Bool {
        if let adapterError = error as? AdapterError { return adapterError.isTransient }
        return error is URLError
    }

    /// OpenCode's errors arrive as `{"name":…,"data":{"message":…,"ref":…}}`.
    /// Raw JSON on a phone screen is not an error message, so pull out the
    /// sentence a person can act on and keep the ref for the logs.
    private static func readableError(from data: Data, status: Int) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // A 502 from something in front of the server, or a crash with
            // nothing written — the status is the only fact available, and
            // an empty string on screen is worse than a dull one.
            let text = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "HTTP \(status), no details" : String(text.prefix(200))
        }
        let payload = json["data"] as? [String: Any]
        let message = payload?["message"] as? String
            ?? json["message"] as? String
            ?? json["name"] as? String
            ?? "unexpected error"
        if let ref = payload?["ref"] as? String {
            return "\(message) (\(ref))"
        }
        return message
    }

    // MARK: - v1: status / capabilities

    func health() async throws -> (healthy: Bool, version: String) {
        if api == .v2 { return try await v2Health() }
        let json = try await get("/global/health", timeout: Self.healthTimeout)
            as? [String: Any] ?? [:]
        return (json["healthy"] as? Bool ?? false, json["version"] as? String ?? "unknown")
    }

    func capabilities() async throws -> Capabilities {
        let health = try await health()
        // Everything v1 needs exists on every server this adapter supports;
        // flags become meaningful the first time a version drops or gates
        // one of these.
        return Capabilities(
            opencodeVersion: health.version, permissions: true, questions: true, diffs: true,
            schedules: true, mcpManagement: true
        )
    }

    /// The provider/model a prompt falls back to when the phone doesn't
    /// pick. The user's own configured default (`config.model`, as
    /// "provider/model") wins — it's the model their TUI uses, which is the
    /// least surprising choice a remote could make. Only failing that, the
    /// first provider default in *sorted* order: dictionary order once
    /// picked whatever it liked, including an image model.
    func defaultModel() async throws -> (providerID: String, modelID: String)? {
        if api == .v2 { return try await v2DefaultModel() }
        if let config = try? await get("/config") as? [String: Any],
           let model = config["model"] as? String {
            let parts = model.split(separator: "/", maxSplits: 1)
            if parts.count == 2 { return (String(parts[0]), String(parts[1])) }
        }
        let json = try await get("/config/providers") as? [String: Any] ?? [:]
        let defaults = json["default"] as? [String: String] ?? [:]
        let providers = (json["providers"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
            .sorted()
        for id in providers {
            if let model = defaults[id] { return (id, model) }
        }
        return nil
    }

    /// Every model the user's OpenCode can actually run as an agent.
    ///
    /// Filtered to tool-callers on purpose: a model that can't call tools
    /// cannot read a file or run a command, so offering one here would be
    /// offering a coding agent that can only talk. (This is also what made
    /// the old provider-default fallback pick an image model.)
    func models() async throws -> (models: [AgentModel], defaultID: String?) {
        if api == .v2 { return try await v2Models() }
        let json = try await get("/config/providers") as? [String: Any] ?? [:]
        let providers = json["providers"] as? [[String: Any]] ?? []
        var out: [AgentModel] = []
        for provider in providers {
            guard let providerID = provider["id"] as? String,
                  let models = provider["models"] as? [String: Any]
            else { continue }
            let providerName = provider["name"] as? String ?? providerID
            for (modelID, value) in models {
                guard let model = value as? [String: Any] else { continue }
                let capabilities = model["capabilities"] as? [String: Any]
                guard capabilities?["toolcall"] as? Bool != false else { continue }
                let input = capabilities?["input"] as? [String: Any]
                out.append(AgentModel(
                    providerID: providerID,
                    modelID: modelID,
                    name: model["name"] as? String ?? modelID,
                    provider: providerName,
                    reasoning: capabilities?["reasoning"] as? Bool,
                    attachment: (capabilities?["attachment"] as? Bool)
                        ?? (input?["image"] as? Bool)
                ))
            }
        }
        out.sort {
            ($0.provider, $0.name.lowercased()) < ($1.provider, $1.name.lowercased())
        }
        // The advertised default must be one of the models actually
        // offered, or the phone's chip reads "Default model" forever with
        // nothing to match it against. That happens whenever the
        // configured default isn't tool-capable — an image model, say —
        // since those never make this list.
        let configured = (try? await defaultModel()).map { "\($0.providerID)/\($0.modelID)" }
        let usable = configured.flatMap { id in out.first { $0.id == id }?.id } ?? out.first?.id
        return (out, usable)
    }

    /// Context windows for every configured model ("provider/model" →
    /// tokens), from the same catalog `models()` reads (`limit.context`).
    /// The denominator for a client's context meter; callers cache, since
    /// the catalog doesn't change under a running turn.
    func contextLimits() async throws -> [String: Int] {
        if api == .v2 { return try await v2ContextLimits() }
        let json = try await get("/config/providers") as? [String: Any] ?? [:]
        var out: [String: Int] = [:]
        for provider in json["providers"] as? [[String: Any]] ?? [] {
            guard let providerID = provider["id"] as? String,
                  let models = provider["models"] as? [String: Any]
            else { continue }
            for (modelID, value) in models {
                guard let model = value as? [String: Any],
                      let limit = (model["limit"] as? [String: Any])?["context"] as? Int,
                      limit > 0
                else { continue }
                out["\(providerID)/\(modelID)"] = limit
            }
        }
        return out
    }

    /// Session operations OpenCode exposes as endpoints rather than as
    /// commands.
    ///
    /// `/command` lists prompt templates. Things like summarize and share
    /// aren't templates — they're operations on the session, and OpenCode's
    /// own TUI implements them client-side against these endpoints. A phone
    /// user typing `/summarize` has no way to know the difference and
    /// shouldn't have to, so we offer them in the same palette.
    enum Builtin: String, CaseIterable {
        case summarize
        case share
        case unshare
        case undo
        case redo

        /// True when the operation runs a model and therefore produces a
        /// turn worth streaming. The rest finish immediately and just need
        /// a confirmation.
        var streams: Bool { self == .summarize }

        var describe: String {
            switch self {
            case .summarize: return "compact this conversation, keeping the key context"
            case .share: return "create a shareable link for this session"
            case .unshare: return "make this session private again"
            case .undo: return "revert the last exchange and its file changes"
            case .redo: return "restore what undo reverted"
            }
        }
    }

    /// Run a session operation. Returns a line to show the user for the
    /// instant ones; nil when the work streams as a normal turn.
    @discardableResult
    func runBuiltin(
        _ builtin: Builtin, sessionID: String, directory: String,
        providerID: String?, modelID: String?
    ) async throws -> String? {
        if api == .v2 {
            return try await v2RunBuiltin(
                builtin, sessionID: sessionID, directory: directory,
                providerID: providerID, modelID: modelID
            )
        }
        switch builtin {
        case .summarize:
            guard let providerID, let modelID else {
                throw AdapterError.http(path: "/summarize", status: 0, body: "No model configured.")
            }
            try await post(
                "/session/\(sessionID)/summarize", directory: directory,
                body: ["providerID": providerID, "modelID": modelID],
                timeout: Self.turnTimeout
            )
            return nil
        case .share:
            let json = try await post("/session/\(sessionID)/share", directory: directory)
                as? [String: Any] ?? [:]
            let url = (json["share"] as? [String: Any])?["url"] as? String
            return url.map { "Shared: \($0)" } ?? "Session shared."
        case .unshare:
            try await request(
                "/session/\(sessionID)/share", method: "DELETE",
                directory: directory, body: nil
            )
            return "Session is private again."
        case .undo:
            // Revert takes a message id, so find the exchange to undo: the
            // most recent thing the user said.
            let messages = try await get(
                "/session/\(sessionID)/message", directory: directory
            ) as? [[String: Any]] ?? []
            let lastUser = messages.reversed().first {
                ($0["info"] as? [String: Any])?["role"] as? String == "user"
            }
            guard let id = (lastUser?["info"] as? [String: Any])?["id"] as? String else {
                return "Nothing to undo."
            }
            try await post(
                "/session/\(sessionID)/revert", directory: directory,
                body: ["messageID": id]
            )
            return "Reverted the last exchange."
        case .redo:
            try await post("/session/\(sessionID)/unrevert", directory: directory)
            return "Restored."
        }
    }

    /// The slash commands this OpenCode offers — built-ins, the user's own
    /// `.opencode/command/*.md`, MCP prompts, and skills, all in one list.
    ///
    /// Templates are dropped here deliberately: OpenCode expands them when
    /// the command runs, so shipping them to the phone would be several KB
    /// of prompt text the phone can't use and mustn't interpret.
    func commands() async throws -> [AgentCommand] {
        if api == .v2 { return try await v2Commands() }
        let list = try await get("/command") as? [[String: Any]] ?? []
        var out = list.compactMap { item -> AgentCommand? in
            guard let name = item["name"] as? String else { return nil }
            return AgentCommand(
                name: name,
                description: item["description"] as? String,
                source: item["source"] as? String,
                hints: item["hints"] as? [String],
                subtask: item["subtask"] as? Bool
            )
        }
        // Session operations, which OpenCode exposes as endpoints rather
        // than as commands. Only added when the name is free, so a user
        // who writes their own `.opencode/command/summarize.md` keeps it.
        let taken = Set(out.map(\.name))
        out.append(contentsOf: Builtin.allCases.filter { !taken.contains($0.rawValue) }.map {
            AgentCommand(name: $0.rawValue, description: $0.describe, source: "session")
        })
        return out.sorted { $0.name < $1.name }
    }

    /// Run a slash command in a session. We pass the name and the user's
    /// arguments; OpenCode does the template expansion, so nothing here
    /// depends on their template syntax.
    func runCommand(
        sessionID: String, directory: String, command: String, arguments: String,
        providerID: String?, modelID: String?, attachments: [Attachment] = [],
        agent: String? = nil
    ) async throws {
        if api == .v2 {
            return try await v2RunCommand(
                sessionID: sessionID, directory: directory, command: command, arguments: arguments,
                providerID: providerID, modelID: modelID, attachments: attachments, agent: agent
            )
        }
        // OpenCode answers an unregistered command name with a bare 500
        // ("UnknownError", no detail — verified live). Checking the list
        // first turns that into a sentence naming the actual problem.
        // Session operations are dispatched before we ever get here.
        let known = try await commands()
        guard known.contains(where: { $0.name == command && $0.source != "session" }) else {
            throw AdapterError.unknownCommand(command)
        }
        var body: [String: Any] = ["command": command, "arguments": arguments]
        // This endpoint takes the model as one "provider/model" string,
        // unlike prompt_async's object. An adapter's whole job.
        if let providerID, let modelID { body["model"] = "\(providerID)/\(modelID)" }
        if let agent { body["agent"] = agent }
        if !attachments.isEmpty {
            body["parts"] = try Self.parts(for: attachments)
        }
        try await post(
            "/session/\(sessionID)/command", directory: directory, body: body,
            timeout: Self.turnTimeout
        )
    }

    /// Agents a session can run as. Only primary, non-hidden ones —
    /// subagents are dispatched by the model, and the hidden ones
    /// (compaction, title, summary) are internal machinery.
    func agents() async throws -> [AgentInfo] {
        if api == .v2 { return try await v2Agents() }
        let list = try await get("/agent") as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let name = item["name"] as? String,
                  item["mode"] as? String != "subagent",
                  item["hidden"] as? Bool != true
            else { return nil }
            return AgentInfo(
                name: name,
                description: item["description"] as? String,
                mode: item["mode"] as? String
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - v1: MCP servers

    /// Every server the instance for `directory` knows (the merged config
    /// at its startup, plus anything added live), with OpenCode's status
    /// word and, for a failure, why.
    func mcpStatus(directory: String) async throws -> [String: (status: String, error: String?)] {
        if api == .v2 { return try await v2McpStatus(directory: directory) }
        let status = try await get("/mcp", directory: directory) as? [String: Any] ?? [:]
        var result: [String: (status: String, error: String?)] = [:]
        for (name, value) in status {
            let entry = value as? [String: Any]
            result[name] = (entry?["status"] as? String ?? "unknown", entry?["error"] as? String)
        }
        return result
    }

    /// The session's own word on each server, by sanitized name: true
    /// under an allow rule, false under a deny rule, absent when the
    /// session has no rule and the config decides. A later rule for the
    /// same server wins, which is how OpenCode evaluates them.
    func mcpRules(sessionID: String, directory: String) async throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        for rule in try await sessionRules(sessionID: sessionID, directory: directory)
        where Self.isMcpRule(rule) {
            guard let permission = rule["permission"] as? String else { continue }
            result[String(permission.dropLast(2))] = rule["action"] as? String == "allow"
        }
        return result
    }

    /// Make the session's tool exposure exactly `servers`: one wildcard
    /// deny rule per switched-off server, an allow rule for a switched-on
    /// server the config denies (the companion's own tool server), and
    /// nothing for the rest. A denied server's tools aren't merely
    /// blocked: OpenCode drops them from what the model sees, which is
    /// the decluttering the toggle promises (verified live against
    /// 1.18.15). Session rules are evaluated after the config's, so the
    /// allow rule re-exposes what the config hid.
    ///
    /// PATCH replaces the session's whole ruleset. That is the intended
    /// semantics (the map is the complete truth), and it mirrors what
    /// OpenCode itself does when a prompt carries a `tools` map.
    func setMcp(
        sessionID: String, directory: String, servers: [String: Bool], configDenied: Set<String>
    ) async throws {
        var rules: [[String: Any]] = []
        for name in servers.keys.sorted() {
            let sanitized = McpConfigEdit.sanitized(name)
            if servers[name] == false {
                rules.append(["permission": sanitized + "_*", "pattern": "*", "action": "deny"])
            } else if configDenied.contains(sanitized) {
                rules.append(["permission": sanitized + "_*", "pattern": "*", "action": "allow"])
            }
        }
        try await updateRules(sessionID: sessionID, directory: directory) { existing in
            // Only the MCP switches are this call's to rewrite; a grant
            // the user made from a permission card stays.
            existing.filter { !Self.isMcpRule($0) } + rules
        }
    }

    /// A rule that switches a whole server on or off. A permission grant
    /// names a tool ("bash", "edit"), never a `<server>_*` prefix.
    private static func isMcpRule(_ rule: [String: Any]) -> Bool {
        guard (rule["permission"] as? String)?.hasSuffix("_*") == true,
              rule["pattern"] as? String == "*",
              let action = rule["action"] as? String
        else { return false }
        return action == "deny" || action == "allow"
    }

    /// Add or replace a server in the running instance for `directory`
    /// and connect it (`POST /mcp`, verified on 1.18.15). In-memory only:
    /// the file is the companion's to write, and other instances see the
    /// server at the next restart.
    func addMcp(_ server: McpServerConfig, directory: String) async throws -> (status: String, error: String?) {
        if api == .v2 { return try await v2AddMcp(server, directory: directory) }
        let json = try await post(
            "/mcp", directory: directory, body: ["name": server.name, "config": server.block()],
            timeout: Self.requestTimeout * 2
        ) as? [String: Any] ?? [:]
        let entry = json[server.name] as? [String: Any]
        return (entry?["status"] as? String ?? "unknown", entry?["error"] as? String)
    }

    /// Close a server's client in the instance for `directory`; its
    /// tools leave the model's list at the next step.
    func disconnectMcp(_ name: String, directory: String) async throws {
        if api == .v2 { return try await v2DisconnectMcp(name, directory: directory) }
        try await post("/mcp/\(name)/disconnect", directory: directory)
    }

    /// Read-modify-write of the session's ruleset. PATCH replaces the
    /// whole list, and two features now write to it (MCP switches and
    /// permission grants), so each edits only its own rules.
    private func updateRules(
        sessionID: String, directory: String,
        transform: ([[String: Any]]) -> [[String: Any]]
    ) async throws {
        let existing = try await sessionRules(sessionID: sessionID, directory: directory)
        let rules = transform(existing)
        if api == .v2 {
            try await request(
                "/api/session/\(sessionID)", method: "PATCH", directory: nil,
                body: ["permissions": rules.map(Self.v2Rule(from:))]
            )
            return
        }
        try await request(
            "/session/\(sessionID)", method: "PATCH", directory: directory,
            body: ["permission": rules]
        )
    }

    /// The session's own ruleset in 1.x shape (`{permission, pattern,
    /// action}`), whichever generation stores it. 2.x names the same
    /// three things `{action, resource, effect}`.
    private func sessionRules(sessionID: String, directory: String) async throws -> [[String: Any]] {
        if api == .v2 {
            let session = try await v2Session(sessionID)
            return (session["permissions"] as? [[String: Any]] ?? []).map(Self.v1Rule(from:))
        }
        let session = try await get("/session/\(sessionID)", directory: directory)
            as? [String: Any] ?? [:]
        return session["permission"] as? [[String: Any]] ?? []
    }

    /// Whitelist `patterns` for `permission` in this session, effective
    /// for the very next tool call. Duplicates are replaced, not stacked.
    func allow(
        _ patterns: [String], for permission: String, sessionID: String, directory: String
    ) async throws {
        try await updateRules(sessionID: sessionID, directory: directory) { existing in
            let kept = existing.filter { rule in
                !(rule["permission"] as? String == permission
                    && patterns.contains(rule["pattern"] as? String ?? ""))
            }
            return kept + patterns.map {
                ["permission": permission, "pattern": $0, "action": "allow"]
            }
        }
    }

    func todos(sessionID: String, directory: String) async throws -> [TodoItem] {
        if api == .v2 { return try await v2Todos(sessionID: sessionID, directory: directory) }
        let list = try await get("/session/\(sessionID)/todo", directory: directory)
            as? [[String: Any]] ?? []
        return Self.todos(from: list)
    }

    static func todos(from list: [[String: Any]]) -> [TodoItem] {
        list.enumerated().compactMap { index, item in
            guard let content = item["content"] as? String else { return nil }
            return TodoItem(
                id: item["id"] as? String ?? "todo-\(index)",
                content: content,
                status: item["status"] as? String ?? "pending"
            )
        }
    }

    // MARK: - v1: working tree

    /// Everything the agent has changed, accumulated — not one turn's
    /// worth. `mode: "git"` is the working tree against HEAD; `"branch"`
    /// is against the default branch, which is what a reviewer would see
    /// in a pull request.
    func workingChanges(directory: String, mode: String) async throws -> WorkingChanges {
        if api == .v2 { return try await v2WorkingChanges(directory: directory, mode: mode) }
        let vcs = try await get("/vcs", directory: directory) as? [String: Any] ?? [:]
        let list = try await get(
            "/vcs/diff?mode=\(mode)", directory: directory
        ) as? [[String: Any]] ?? []
        let files = list.compactMap { item -> FileDiff? in
            guard let file = item["file"] as? String else { return nil }
            return FileDiff(
                file: file,
                patch: item["patch"] as? String,
                additions: item["additions"] as? Int,
                deletions: item["deletions"] as? Int,
                status: item["status"] as? String
            )
        }
        return WorkingChanges(
            branch: vcs["branch"] as? String,
            defaultBranch: vcs["default_branch"] as? String,
            files: files,
            mode: mode
        )
    }

    // MARK: - v1: session management

    func deleteSession(_ sessionID: String, directory: String) async throws {
        if api == .v2 {
            try await request("/api/session/\(sessionID)", method: "DELETE", directory: nil, body: nil)
            return
        }
        try await request(
            "/session/\(sessionID)", method: "DELETE", directory: directory, body: nil
        )
    }

    func renameSession(_ sessionID: String, directory: String, title: String) async throws {
        if api == .v2 {
            try await request(
                "/api/session/\(sessionID)", method: "PATCH", directory: nil, body: ["title": title]
            )
            return
        }
        try await request(
            "/session/\(sessionID)", method: "PATCH", directory: directory,
            body: ["title": title]
        )
    }

    // MARK: - v1: projects / sessions

    func projects() async throws -> [Project] {
        if api == .v2 { return try await v2Projects() }
        let list = try await get("/project") as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String, id != "global",
                  let worktree = item["worktree"] as? String
            else { return nil }
            let time = item["time"] as? [String: Any]
            return Project(
                id: id,
                worktree: worktree,
                name: item["name"] as? String,
                updated: (time?["updated"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                known: true
            )
        }
        .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    func sessions(limit: Int = 20, search: String? = nil) async throws -> [Session] {
        if api == .v2 { return try await v2Sessions(limit: limit, search: search) }
        var path = "/experimental/session?limit=\(limit)"
        if let search, !search.isEmpty,
           let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&search=\(encoded)"
        }
        let list = try await get(path) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let time = item["time"] as? [String: Any]
            return Session(
                id: id,
                title: item["title"] as? String,
                directory: item["directory"] as? String,
                updated: (time?["updated"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
    }

    // MARK: - v1: prompt

    func createSession(directory: String) async throws -> String {
        if api == .v2 { return try await v2CreateSession(directory: directory) }
        let json = try await post("/session", directory: directory) as? [String: Any] ?? [:]
        guard let id = json["id"] as? String else {
            throw AdapterError.http(path: "/session", status: 0, body: "no id in response")
        }
        return id
    }

    /// Total attachment bytes a single turn may carry. Generous enough for
    /// a handful of screenshots, small enough that a mistake (a video, a
    /// whole log directory) fails fast instead of stalling a turn for
    /// minutes on cellular.
    static let attachmentLimit = 20 << 20

    func promptAsync(
        sessionID: String, directory: String, text: String,
        providerID: String, modelID: String, attachments: [Attachment] = [],
        agent: String? = nil
    ) async throws {
        if api == .v2 {
            return try await v2Prompt(
                sessionID: sessionID, directory: directory, text: text,
                providerID: providerID, modelID: modelID, attachments: attachments, agent: agent
            )
        }
        let parts: [[String: Any]] = [["type": "text", "text": text]]
            + (try Self.parts(for: attachments))
        var body: [String: Any] = [
            "model": ["providerID": providerID, "modelID": modelID],
            "parts": parts,
        ]
        if let agent { body["agent"] = agent }
        try await post(
            "/session/\(sessionID)/prompt_async", directory: directory, body: body
        )
    }

    /// Attachments as OpenCode parts. Images and PDFs ride as file parts
    /// with data: URIs (the bytes go straight through; nothing is hosted).
    /// Text-like files go inline as text parts: the provider under
    /// OpenCode rejects any other file media type, and a rejected part
    /// stays in the thread's history, failing every turn after it.
    static func parts(for attachments: [Attachment]) throws -> [[String: Any]] {
        try attachments.map { attachment in
            switch AttachmentDelivery.classify(attachment) {
            case .image, .pdf:
                return [
                    "type": "file",
                    "mime": attachment.mime,
                    "filename": attachment.name,
                    "url": "data:\(attachment.mime);base64,\(attachment.data)",
                ]
            case let .text(text):
                return [
                    "type": "text",
                    "text": AttachmentDelivery.inlined(name: attachment.name, text: text),
                ]
            case .tooLarge:
                throw AdapterError.attachment(
                    "\(attachment.name) is too large to send as text (limit \(AttachmentDelivery.textLimit >> 10) KB)."
                )
            case .unreadable:
                throw AdapterError.attachment(
                    "\(attachment.name) isn't something the model can read. Send text files, images, or PDFs."
                )
            }
        }
    }

    func abort(sessionID: String, directory: String) async throws {
        if api == .v2 {
            try await post("/api/session/\(sessionID)/interrupt")
            return
        }
        try await post("/session/\(sessionID)/abort", directory: directory)
    }

    // MARK: - v1: permission

    /// Pending asks, straight from the poll endpoint — the recovery path
    /// when an event was missed (or the phone just woke from a push).
    func pendingPermissions(directory: String) async throws -> [PermissionRequest] {
        if api == .v2 { return try await v2PendingPermissions(directory: directory) }
        let list = try await get("/permission", directory: directory) as? [[String: Any]] ?? []
        return list.compactMap(Self.permission(from:))
    }

    /// Answers an ask. A grant is applied first, so the rule is in place
    /// before the tool call proceeds, and then extended to every other
    /// pending ask it already covers: a "whole project" grant made on the
    /// second of four reads answers the other three too, rather than
    /// surfacing three more cards for something the user just decided.
    /// Returns true when the grant was written to the project's config.
    @discardableResult
    func replyPermission(
        id: String, directory: String, reply: String, message: String? = nil,
        grant: PermissionGrant? = nil
    ) async throws -> Bool {
        var reply = reply
        var persisted = false
        var covered: [PermissionRequest] = []
        // 2.x answers an ask under its session's path, so the session has
        // to be known even without a grant.
        var pending: [PermissionRequest] = []
        if api == .v2 || (grant != nil && reply != "reject") {
            pending = try await pendingPermissions(directory: directory)
        }
        let ask = pending.first { $0.id == id }
        if let grant, reply != "reject", !grant.patterns.isEmpty {
            if let sessionID = ask?.sessionID {
                try await allow(
                    grant.patterns, for: grant.permission, sessionID: sessionID, directory: directory
                )
            }
            if grant.persist {
                let path = PermissionConfig.projectPath(for: directory)
                let root = try OpenCodeConfigFile.read(at: path)
                try OpenCodeConfigFile.write(
                    PermissionConfig.allowing(grant.patterns, for: grant.permission, in: root),
                    to: path
                )
                persisted = true
            }
            // OpenCode's own "always" whitelists what it suggested; keep
            // it only when that is exactly what the user chose, so the
            // session never ends up holding two different answers.
            if grant.patterns != ask?.always { reply = "once" }
            covered = pending.filter { other in
                other.id != id && other.sessionID == ask?.sessionID
                    && other.permission == grant.permission
                    && Self.isCovered(other, by: grant.patterns)
            }
        }
        if api == .v2 {
            guard let sessionID = ask?.sessionID else {
                // Already answered elsewhere (the TUI, another device), or
                // gone with its turn: nothing left to say yes or no to.
                throw AdapterError.http(
                    path: "/permission", status: 404, body: "That request is no longer pending."
                )
            }
            var body: [String: Any] = ["decision": reply]
            if let message, !message.isEmpty { body["message"] = message }
            try await post("/api/session/\(sessionID)/permission/\(id)/reply", body: body)
            for other in covered {
                try? await post(
                    "/api/session/\(sessionID)/permission/\(other.id)/reply", body: ["decision": "once"]
                )
            }
            return persisted
        }
        var body: [String: Any] = ["reply": reply]
        // A rejection with direction reaches the agent as guidance rather
        // than a bare no.
        if let message, !message.isEmpty { body["message"] = message }
        try await post("/permission/\(id)/reply", directory: directory, body: body)
        for other in covered {
            try? await post("/permission/\(other.id)/reply", directory: directory, body: ["reply": "once"])
        }
        return persisted
    }

    /// True when every pattern the ask is about falls under the grant.
    static func isCovered(_ ask: PermissionRequest, by patterns: [String]) -> Bool {
        let subjects = ask.patterns ?? []
        guard !subjects.isEmpty else { return false }
        return subjects.allSatisfy { subject in
            patterns.contains { PermissionScopes.matches(pattern: $0, subject) }
        }
    }

    // MARK: - v1: question

    func pendingQuestions(directory: String) async throws -> [QuestionRequest] {
        if api == .v2 { return try await v2PendingQuestions(directory: directory) }
        let list = try await get("/question", directory: directory) as? [[String: Any]] ?? []
        return list.compactMap(Self.question(from:))
    }

    func replyQuestion(id: String, directory: String, answers: [[String]]) async throws {
        if api == .v2 { return try await v2ReplyQuestion(id: id, directory: directory, answers: answers) }
        try await post(
            "/question/\(id)/reply", directory: directory, body: ["answers": answers]
        )
    }

    // MARK: - v1: transcript + diff

    /// The session's message records, whole. The transcript, the per-turn
    /// diffs and the context meter all read this one document, and on a
    /// long thread it is megabytes: a cold load fetches it once and
    /// derives the three from the same copy.
    func messages(sessionID: String, directory: String) async throws -> [[String: Any]] {
        if api == .v2 { return try await v2Messages(sessionID: sessionID, directory: directory) }
        return try await get(
            "/session/\(sessionID)/message", directory: directory
        ) as? [[String: Any]] ?? []
    }

    /// The durable per-turn diffs: user messages carry what their turn
    /// changed (`info.summary.diffs`).
    func turnDiffs(sessionID: String, directory: String) async throws -> [FileDiff] {
        turnDiffs(in: try await messages(sessionID: sessionID, directory: directory))
    }

    func turnDiffs(in messages: [[String: Any]]) -> [FileDiff] {
        messages.flatMap { message -> [FileDiff] in
            let info = message["info"] as? [String: Any]
            let summary = info?["summary"] as? [String: Any]
            let diffs = summary?["diffs"] as? [[String: Any]] ?? []
            return diffs.compactMap { d in
                guard let file = d["file"] as? String else { return nil }
                return FileDiff(
                    file: file,
                    patch: d["patch"] as? String,
                    additions: d["additions"] as? Int,
                    deletions: d["deletions"] as? Int,
                    status: d["status"] as? String
                )
            }
        }
    }

    /// Transcript flattened to protocol parts, for continuing a session.
    func transcript(in messages: [[String: Any]]) -> [TurnPart] {
        messages.flatMap { message -> [TurnPart] in
            let info = message["info"] as? [String: Any]
            let role = info?["role"] as? String ?? "assistant"
            let parts = message["parts"] as? [[String: Any]] ?? []
            return parts.compactMap { part in
                Self.turnPart(from: part, role: role)
            }
        }
    }

    /// The context meter's starting point for a cold load: the last
    /// assistant step's token accounting, the same numbers
    /// `message.updated` streams live. Nil while the session has never
    /// completed a step.
    ///
    /// Not the session record's `tokens`: OpenCode sums that field over
    /// every step the session has ever run, so on a long thread it reads
    /// as millions against a 65k window. Only the latest step says how
    /// full the window is now.
    func sessionUsage(
        in messages: [[String: Any]], sessionID: String, directory: String
    ) async throws -> TurnUsage? {
        guard let info = messages.reversed().lazy
            .compactMap({ $0["info"] as? [String: Any] })
            .first(where: { Self.usage(from: $0) != nil }),
            var usage = Self.usage(from: info)
        else { return nil }
        usage.contextLimit = try? await contextLimit(for: info)
        // Cost is the one number that is meant to accumulate; the session
        // record carries the running total.
        let session = api == .v2
            ? try? await v2Session(sessionID)
            : try? await get("/session/\(sessionID)", directory: directory) as? [String: Any]
        usage.cost = (session?["cost"] as? NSNumber)?.doubleValue
        return usage
    }

    /// The context window of the model an assistant message ran on
    /// (`providerID` + `modelID` on the message record), nil when the
    /// catalog doesn't know it.
    func contextLimit(for message: [String: Any]) async throws -> Int? {
        guard let providerID = message["providerID"] as? String,
              let modelID = message["modelID"] as? String
        else { return nil }
        return try await contextLimits()["\(providerID)/\(modelID)"]
    }

    // MARK: - v1: event stream

    /// The instance's SSE feed as parsed dictionaries.
    ///
    /// One socket per instance, however many callers: the feed is shared
    /// through `EventStreamHub`, so a phone reconnecting twenty times in
    /// an evening costs twenty subscriptions and one connection. Each
    /// caller still gets its own ordered stream, carrying everything from
    /// the moment it subscribed, that ends when the server goes away,
    /// exactly as if it held the socket itself.
    ///
    /// `onConnected` fires once the socket is open and delivering events
    /// to this subscriber, at once if it already was. A caller that
    /// invokes a prompt must wait for it: an image that fails to decode
    /// emits its `session.error` within a second, and firing the prompt
    /// before the stream is live loses that event to the race, leaving the
    /// turn waiting for an idle that never comes.
    func events(
        directory: String, onConnected: (@Sendable () -> Void)? = nil
    ) async -> AsyncThrowingStream<[String: Any], Error> {
        let url: URL
        if api == .v2 {
            // One feed for every location; the turn loop filters by
            // session. The hub opens it as a plain GET, so the credential
            // rides as the `auth_token` query parameter 2.x accepts.
            var components = URLComponents(string: base + "/api/event")!
            if let password, !password.isEmpty {
                components.percentEncodedQueryItems = [URLQueryItem(
                    name: "auth_token",
                    value: Self.queryEncoded(Data("opencode:\(password)".utf8).base64EncodedString())
                )]
            }
            url = components.url!
        } else {
            var components = URLComponents(string: base + "/event")!
            components.queryItems = [URLQueryItem(name: "directory", value: directory)]
            url = components.url!
        }
        let payloads = await EventStreamHub.shared.subscribe(url, onConnected: onConnected)
        // 2.x speaks a different event vocabulary; each subscriber gets its
        // own translator, since translating needs per-stream memory.
        let translator = api == .v2 ? OpenCodeEventsV2() : nil
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await payload in payloads {
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data)
                                  as? [String: Any]
                        else { continue }
                        if let translator {
                            for translated in translator.translate(event) {
                                continuation.yield(translated)
                            }
                            continue
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 1.x heartbeats with a real event every ten seconds, and the
            // turn loop leans on it: an invocation that failed (an unknown
            // command, a rejected prompt) is only noticed when the next
            // event arrives. 2.x heartbeats with an SSE comment the hub
            // never passes on, so the same beat is made here.
            let heartbeat: Task<Void, Never>? = translator == nil ? nil : Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    continuation.yield(["type": "server.heartbeat", "properties": [String: Any]()])
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                heartbeat?.cancel()
            }
        }
    }

    // MARK: - OpenCode → v1 mapping

    /// A `session.error` event's real reason and whether it is worth a
    /// retry. The payload shape (`{"error": {"name":…, "data": {"message":…}}}`)
    /// has drifted before, so every lookup degrades: no readable message
    /// falls back to a generic sentence, and anything unrecognized
    /// classifies as NOT transient so a fatal error never loops.
    static func sessionError(from properties: [String: Any]) -> (message: String, transient: Bool) {
        let payload = properties["error"] as? [String: Any]
        let name = payload?["name"] as? String
        let data = payload?["data"] as? [String: Any]
        let message = data?["message"] as? String ?? payload?["message"] as? String
        // OpenCode's message can be a whole stack trace (an ImageDecodeError
        // arrives with a dozen `at …` frames). The first line is the human
        // reason; the frames are for its own log, not the phone.
        let headline = message?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let text = (headline?.isEmpty == false ? headline : nil)
            ?? name ?? "The agent hit an error on your Mac."
        return (text, RetryPolicy.isTransientSessionError(name: name, message: message))
    }

    /// `permission.asked` (1.18+) carries the request at `properties`;
    /// 1.16-era `permission.updated` did too. Both funnel here.
    static func permission(from json: [String: Any]) -> PermissionRequest? {
        // Some versions nest under "request".
        let body = (json["request"] as? [String: Any]) ?? json
        guard let id = body["id"] as? String else { return nil }
        var patterns = body["patterns"] as? [String] ?? []
        if patterns.isEmpty, let metadata = body["metadata"] as? [String: Any],
           let command = metadata["command"] as? String {
            patterns = [command]
        }
        let kind = body["permission"] as? String ?? body["type"] as? String
        var request = PermissionRequest(
            id: id,
            sessionID: body["sessionID"] as? String,
            permission: kind,
            patterns: patterns,
            always: body["always"] as? [String],
            risk: PermissionRisk.classify(permission: kind, patterns: patterns).rawValue
        )
        // The wider grants the card can offer. Worked out here, on the
        // machine that can see whether a folder sits inside a repository.
        let scopes = PermissionScopes.candidates(for: request) { path in
            PermissionScopes.projectRoot(containing: path)
        }
        request.scopes = scopes.isEmpty ? nil : scopes
        return request
    }

    /// A question request, from the poll endpoint or a `question.asked`
    /// event's properties (some versions nest under "request").
    static func question(from json: [String: Any]) -> QuestionRequest? {
        let body = (json["request"] as? [String: Any]) ?? json
        guard let id = body["id"] as? String,
              let rawQuestions = body["questions"] as? [[String: Any]]
        else { return nil }
        let items = rawQuestions.compactMap { q -> QuestionItem? in
            guard let question = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> QuestionOption? in
                guard let label = o["label"] as? String else { return nil }
                return QuestionOption(label: label, description: o["description"] as? String)
            }
            return QuestionItem(
                question: question,
                header: q["header"] as? String,
                options: options,
                multiple: q["multiple"] as? Bool,
                custom: q["custom"] as? Bool
            )
        }
        guard !items.isEmpty else { return nil }
        return QuestionRequest(id: id, sessionID: body["sessionID"] as? String, questions: items)
    }

    /// An assistant message's token accounting (`tokens`, as carried on
    /// `message.updated` and on `GET /session/{id}/message`) → the
    /// phone's TurnUsage. One step's input covers the whole conversation,
    /// so these are the context meter. Nil for anything that isn't a
    /// completed assistant step: user messages have no tokens, and a step
    /// that was aborted before the model answered carries all zeros,
    /// which means "no reading", not "the context is empty".
    static func usage(from info: [String: Any]) -> TurnUsage? {
        guard info["role"] as? String == "assistant",
              let tokens = info["tokens"] as? [String: Any]
        else { return nil }
        let cache = tokens["cache"] as? [String: Any]
        let usage = TurnUsage(
            input: tokens["input"] as? Int,
            output: tokens["output"] as? Int,
            reasoning: tokens["reasoning"] as? Int,
            cacheRead: cache?["read"] as? Int,
            cacheWrite: cache?["write"] as? Int
        )
        return usage.total > 0 ? usage : nil
    }

    /// A preview may not cost more than this on the wire. Chosen to hold a
    /// few hundred lines of code; anything bigger reads better in the
    /// turn's diff anyway. Cut at a line boundary so the last visible line
    /// is a real one, not half of one.
    static let previewLimit = 16 << 10

    private static func cappedPreview(_ code: String) -> String {
        guard code.count > previewLimit else { return code }
        let head = String(code.prefix(previewLimit))
        return head[..<(head.lastIndex(of: "\n") ?? head.endIndex)] + "\n…"
    }

    /// An OpenCode message part → the phone's TurnPart, or nil for part
    /// types the phone doesn't render.
    static func turnPart(from part: [String: Any], role: String) -> TurnPart? {
        guard let type = part["type"] as? String else { return nil }
        let id = part["id"] as? String
        switch type {
        case "text":
            // The user's own words come back as role "user" — the phone
            // already has them, but a resumed/continued session needs them
            // to rebuild the conversation.
            return TurnPart(
                type: role == "user" ? "user" : "text", id: id, text: part["text"] as? String
            )
        case "reasoning":
            return TurnPart(type: "reasoning", id: id, text: part["text"] as? String)
        case "tool":
            let state = part["state"] as? [String: Any]
            // The code a write/edit is producing lives in the tool call's
            // input (verified against 1.18-era storage: write carries
            // {filePath, content}, edit {filePath, oldString, newString}).
            // Forwarding it is what turns the tool row from "edit…" into
            // the code itself, the way OpenCode's own TUI previews it.
            let input = state?["input"] as? [String: Any]
            let code = input?["content"] as? String ?? input?["newString"] as? String
            return TurnPart(
                type: "tool", id: id,
                tool: part["tool"] as? String,
                status: state?["status"] as? String,
                file: code == nil ? nil : input?["filePath"] as? String,
                preview: code.map(cappedPreview)
            )
        case "subtask":
            // A command with `subtask: true` (like /review) runs in a
            // subagent, and its work arrives as this. Observed live —
            // without it, a subagent command looks like nothing happening.
            return TurnPart(
                type: "tool", id: id, tool: "subagent",
                status: (part["state"] as? [String: Any])?["status"] as? String
            )
        default:
            // step-start/step-finish/patch and future kinds: nothing the
            // phone renders yet.
            return nil
        }
    }
}
