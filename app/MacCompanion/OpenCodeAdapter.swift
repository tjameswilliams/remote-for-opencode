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
/// JSON is handled as dictionaries rather than Codable models on purpose:
/// the adapter's job is tolerating shape drift, and a typed decode that
/// throws on a renamed field is the opposite of that.
struct OpenCodeAdapter {
    let port: Int
    private let logger = Logger(subsystem: "com.timwilliams.opencodego", category: "adapter")

    private var base: String { "http://127.0.0.1:\(port)" }

    // MARK: - Plumbing

    private func get(_ path: String, directory: String? = nil) async throws -> Any {
        try await request(path, method: "GET", directory: directory, body: nil)
    }

    @discardableResult
    private func post(
        _ path: String, directory: String? = nil, body: [String: Any]? = [:]
    ) async throws -> Any {
        try await request(path, method: "POST", directory: directory, body: body)
    }

    private func request(
        _ path: String, method: String, directory: String?, body: [String: Any]?
    ) async throws -> Any {
        var components = URLComponents(string: base + path)!
        if let directory {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "directory", value: directory),
            ]
        }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
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

    enum AdapterError: LocalizedError {
        /// `status` 0 means no HTTP status existed: a synthesized error, or
        /// a response with no usable status line.
        case http(path: String, status: Int, body: String)
        case unknownCommand(String)

        var errorDescription: String? {
            switch self {
            case let .http(path, _, body): return "OpenCode \(path): \(body)"
            case let .unknownCommand(name):
                return "No command named \"/\(name)\" in OpenCode on this Mac."
            }
        }

        /// Worth retrying without asking anyone. Rides Wire.Event.transient
        /// out to clients and drives the scheduler's retry loop.
        var isTransient: Bool {
            switch self {
            case let .http(_, status, _): return RetryPolicy.isTransientHTTPStatus(status)
            case .unknownCommand: return false
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
        let json = try await get("/global/health") as? [String: Any] ?? [:]
        return (json["healthy"] as? Bool ?? false, json["version"] as? String ?? "unknown")
    }

    func capabilities() async throws -> Capabilities {
        let health = try await health()
        // Everything v1 needs exists on every server this adapter supports;
        // flags become meaningful the first time a version drops or gates
        // one of these.
        return Capabilities(
            opencodeVersion: health.version, permissions: true, questions: true, diffs: true,
            schedules: true
        )
    }

    /// The provider/model a prompt falls back to when the phone doesn't
    /// pick. The user's own configured default (`config.model`, as
    /// "provider/model") wins — it's the model their TUI uses, which is the
    /// least surprising choice a remote could make. Only failing that, the
    /// first provider default in *sorted* order: dictionary order once
    /// picked whatever it liked, including an image model.
    func defaultModel() async throws -> (providerID: String, modelID: String)? {
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
        switch builtin {
        case .summarize:
            guard let providerID, let modelID else {
                throw AdapterError.http(path: "/summarize", status: 0, body: "No model configured.")
            }
            try await post(
                "/session/\(sessionID)/summarize", directory: directory,
                body: ["providerID": providerID, "modelID": modelID]
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
            body["parts"] = attachments.map { attachment in
                [
                    "type": "file",
                    "mime": attachment.mime,
                    "filename": attachment.name,
                    "url": "data:\(attachment.mime);base64,\(attachment.data)",
                ]
            }
        }
        try await post("/session/\(sessionID)/command", directory: directory, body: body)
    }

    /// Agents a session can run as. Only primary, non-hidden ones —
    /// subagents are dispatched by the model, and the hidden ones
    /// (compaction, title, summary) are internal machinery.
    func agents() async throws -> [AgentInfo] {
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

    /// OpenCode names an MCP tool `<server>_<tool>`, squashing anything
    /// outside [a-zA-Z0-9_-] in either half to "_" (their
    /// McpCatalog.sanitize). Rules that hide a server's tools must match
    /// that spelling, not the raw config key.
    static func sanitizedMcp(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a" ... "z", "A" ... "Z", "0" ... "9", "-", "_": return Character(scalar)
            default: return "_"
            }
        })
    }

    /// The MCP servers this OpenCode configures, and, when a session is
    /// named, whether that session exposes each one's tools.
    ///
    /// Enablement is read from the session's own permission rules, because
    /// that is where `setMcp` puts it: the session is the durable truth,
    /// so every client shows the same switches and a fresh conversation
    /// starts with everything on.
    func mcpServers(directory: String, sessionID: String?) async throws -> [McpServer] {
        let status = try await get("/mcp", directory: directory) as? [String: Any] ?? [:]
        var denied = Set<String>()
        if let sessionID {
            let session = try await get(
                "/session/\(sessionID)", directory: directory
            ) as? [String: Any] ?? [:]
            let rules = session["permission"] as? [[String: Any]] ?? []
            for rule in rules
                where rule["action"] as? String == "deny" && rule["pattern"] as? String == "*" {
                if let permission = rule["permission"] as? String, permission.hasSuffix("_*") {
                    denied.insert(String(permission.dropLast(2)))
                }
            }
        }
        return status.map { name, value in
            McpServer(
                name: name,
                status: (value as? [String: Any])?["status"] as? String,
                enabled: !denied.contains(Self.sanitizedMcp(name))
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// Make the session's tool exposure exactly `servers`: one wildcard
    /// deny rule per switched-off server, nothing for the rest. A denied
    /// server's tools aren't merely blocked: OpenCode drops them from
    /// what the model sees, which is the decluttering the toggle promises
    /// (verified live against 1.18.15).
    ///
    /// PATCH replaces the session's whole ruleset. That is the intended
    /// semantics (the map is the complete truth), and it mirrors what
    /// OpenCode itself does when a prompt carries a `tools` map.
    func setMcp(sessionID: String, directory: String, servers: [String: Bool]) async throws {
        let rules = servers.filter { !$0.value }.keys.sorted().map { name in
            ["permission": Self.sanitizedMcp(name) + "_*", "pattern": "*", "action": "deny"]
        }
        try await request(
            "/session/\(sessionID)", method: "PATCH", directory: directory,
            body: ["permission": rules]
        )
    }

    func todos(sessionID: String, directory: String) async throws -> [TodoItem] {
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
        try await request(
            "/session/\(sessionID)", method: "DELETE", directory: directory, body: nil
        )
    }

    func renameSession(_ sessionID: String, directory: String, title: String) async throws {
        try await request(
            "/session/\(sessionID)", method: "PATCH", directory: directory,
            body: ["title": title]
        )
    }

    // MARK: - v1: projects / sessions

    func projects() async throws -> [Project] {
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
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        // OpenCode takes file parts as data: URIs, so the bytes go straight
        // through and nothing has to be hosted anywhere.
        for attachment in attachments {
            parts.append([
                "type": "file",
                "mime": attachment.mime,
                "filename": attachment.name,
                "url": "data:\(attachment.mime);base64,\(attachment.data)",
            ])
        }
        var body: [String: Any] = [
            "model": ["providerID": providerID, "modelID": modelID],
            "parts": parts,
        ]
        if let agent { body["agent"] = agent }
        try await post(
            "/session/\(sessionID)/prompt_async", directory: directory, body: body
        )
    }

    func abort(sessionID: String, directory: String) async throws {
        try await post("/session/\(sessionID)/abort", directory: directory)
    }

    // MARK: - v1: permission

    /// Pending asks, straight from the poll endpoint — the recovery path
    /// when an event was missed (or the phone just woke from a push).
    func pendingPermissions(directory: String) async throws -> [PermissionRequest] {
        let list = try await get("/permission", directory: directory) as? [[String: Any]] ?? []
        return list.compactMap(Self.permission(from:))
    }

    func replyPermission(
        id: String, directory: String, reply: String, message: String? = nil
    ) async throws {
        var body: [String: Any] = ["reply": reply]
        // A rejection with direction reaches the agent as guidance rather
        // than a bare no.
        if let message, !message.isEmpty { body["message"] = message }
        try await post("/permission/\(id)/reply", directory: directory, body: body)
    }

    // MARK: - v1: question

    func pendingQuestions(directory: String) async throws -> [QuestionRequest] {
        let list = try await get("/question", directory: directory) as? [[String: Any]] ?? []
        return list.compactMap(Self.question(from:))
    }

    func replyQuestion(id: String, directory: String, answers: [[String]]) async throws {
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
        try await get(
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
        let session = try? await get(
            "/session/\(sessionID)", directory: directory
        ) as? [String: Any]
        usage.cost = session?["cost"] as? Double
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

    /// The instance's SSE feed as parsed dictionaries. One subscription per
    /// running turn is fine at this scale; consolidating to a single global
    /// subscription is an optimization for later.
    ///
    /// `onConnected` fires once the HTTP response has arrived, i.e. the
    /// server is now delivering events to this subscriber. A caller that
    /// invokes a prompt must wait for it: an image that fails to decode
    /// emits its `session.error` within a second, and firing the prompt
    /// before the stream is live loses that event to the race, leaving the
    /// turn waiting for an idle that never comes. The stream buffers
    /// everything from the moment it connects, so nothing after this point
    /// is missed even before the consumer starts iterating.
    func events(
        directory: String, onConnected: (@Sendable () -> Void)? = nil
    ) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var components = URLComponents(string: base + "/event")!
                components.queryItems = [URLQueryItem(name: "directory", value: directory)]
                let (bytes, _) = try await URLSession.shared.bytes(from: components.url!)
                onConnected?()
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: "),
                          let data = line.dropFirst(6).data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
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
        return PermissionRequest(
            id: id,
            sessionID: body["sessionID"] as? String,
            permission: kind,
            patterns: patterns,
            always: body["always"] as? [String],
            risk: PermissionRisk.classify(permission: kind, patterns: patterns).rawValue
        )
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
