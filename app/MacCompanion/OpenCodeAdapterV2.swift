import RemoteKit
import Foundation

/// OpenCode 2's half of the compatibility seam. Every operation here reads
/// the 2.x API and answers in the shape its 1.x twin in OpenCodeAdapter.swift
/// already returns, so RemoteServer, the scheduler and the phone never learn
/// which generation is installed.
///
/// Verified live against 2.1.4. What changed, in the terms that matter here:
/// - Every path is under `/api/`, behind HTTP Basic auth (user `opencode`).
/// - The working directory is `location[directory]`, except on session
///   create, which takes it in the body as `location: {directory}` and
///   silently falls back to the server's cwd when it is only in the query.
/// - Most answers are wrapped as `{location, data}`; a few (`/api/project`,
///   `/api/location`, `/api/info`) are not.
/// - A message is one record with `content[]`, not an info plus parts;
///   user messages carry their `text` directly.
/// - Per-turn diffs are no longer stored on user messages; the session
///   computes one on request (`/diff?from=<user message>`).
/// - Model and agent are session state (`POST /model`, `POST /agent`), not
///   fields of the prompt.
/// - Question cards are "forms"; the question tool's fields are `q0`, `q1`…
/// - Permission rules are `{action, resource, effect}`.
extension OpenCodeAdapter {
    /// The `data` of a `{location, data}` envelope; anything else as is.
    static func unwrapped(_ json: Any) -> Any {
        if let object = json as? [String: Any], let data = object["data"] { return data }
        return json
    }

    /// Where catalog reads go when the caller names no project: the
    /// companion's own chat folder. Without a location, 2.x would resolve
    /// the server's cwd, which for a GUI app is `/`.
    /// It must exist: 2.x refuses a location that isn't a directory.
    private var catalogDirectory: String {
        try? FileManager.default.createDirectory(
            atPath: ChatFolder.path, withIntermediateDirectories: true
        )
        return ChatFolder.path
    }

    func v2Get(_ path: String, directory: String? = nil) async throws -> Any {
        Self.unwrapped(try await get(path, directory: directory))
    }

    func v2Session(_ sessionID: String) async throws -> [String: Any] {
        try await v2Get("/api/session/\(sessionID)") as? [String: Any] ?? [:]
    }

    // MARK: - Status and catalog

    func v2Health() async throws -> (healthy: Bool, version: String) {
        let info = try await get("/api/info", timeout: Self.healthTimeout) as? [String: Any] ?? [:]
        guard let version = info["version"] as? String else {
            throw AdapterError.http(path: "/api/info", status: 0, body: "no version in response")
        }
        return (true, version)
    }

    func v2DefaultModel() async throws -> (providerID: String, modelID: String)? {
        guard let model = try await v2Get("/api/model/default", directory: catalogDirectory)
            as? [String: Any],
            let providerID = model["providerID"] as? String,
            let id = model["id"] as? String
        else { return nil }
        return (providerID, id)
    }

    /// Every enabled, tool-calling model, the same filter as 1.x. A model's
    /// `id` is what a session's model reference names, so it is the id here.
    func v2Models() async throws -> (models: [AgentModel], defaultID: String?) {
        let list = try await v2Get("/api/model", directory: catalogDirectory) as? [[String: Any]] ?? []
        let providers = (try? await v2Get("/api/provider", directory: catalogDirectory))
            as? [[String: Any]] ?? []
        var names: [String: String] = [:]
        for provider in providers {
            if let id = provider["id"] as? String { names[id] = provider["name"] as? String ?? id }
        }
        var out: [AgentModel] = []
        for model in list {
            guard let providerID = model["providerID"] as? String,
                  let id = model["id"] as? String,
                  model["enabled"] as? Bool != false
            else { continue }
            let capabilities = model["capabilities"] as? [String: Any]
            guard capabilities?["tools"] as? Bool != false else { continue }
            let input = capabilities?["input"] as? [String] ?? []
            let variants = model["variants"] as? [[String: Any]] ?? []
            let compatibility = model["compatibility"] as? [String: Any]
            out.append(AgentModel(
                providerID: providerID,
                modelID: id,
                name: model["name"] as? String ?? id,
                provider: names[providerID] ?? providerID,
                reasoning: !variants.isEmpty || compatibility?["reasoningField"] != nil,
                attachment: input.contains("image") || input.contains("pdf")
            ))
        }
        out.sort {
            ($0.provider, $0.name.lowercased()) < ($1.provider, $1.name.lowercased())
        }
        let configured = (try? await v2DefaultModel()).map { "\($0.providerID)/\($0.modelID)" }
        let usable = configured.flatMap { id in out.first { $0.id == id }?.id } ?? out.first?.id
        return (out, usable)
    }

    func v2ContextLimits() async throws -> [String: Int] {
        let list = try await v2Get("/api/model", directory: catalogDirectory) as? [[String: Any]] ?? []
        var out: [String: Int] = [:]
        for model in list {
            guard let providerID = model["providerID"] as? String,
                  let id = model["id"] as? String,
                  let limit = (model["limit"] as? [String: Any])?["context"] as? Int,
                  limit > 0
            else { continue }
            out["\(providerID)/\(id)"] = limit
        }
        return out
    }

    /// 2.x has no share links (removed in 1.19.1 too), so those two
    /// session operations are not offered.
    static let v2Builtins = Builtin.allCases.filter { $0 != .share && $0 != .unshare }

    func v2Commands() async throws -> [AgentCommand] {
        let list = try await v2Get("/api/command", directory: catalogDirectory) as? [[String: Any]] ?? []
        var out = list.compactMap { item -> AgentCommand? in
            guard let name = item["name"] as? String else { return nil }
            return AgentCommand(name: name, description: item["description"] as? String)
        }
        let taken = Set(out.map(\.name))
        out.append(contentsOf: Self.v2Builtins.filter { !taken.contains($0.rawValue) }.map {
            AgentCommand(name: $0.rawValue, description: $0.describe, source: "session")
        })
        return out.sorted { $0.name < $1.name }
    }

    /// Agents by id: the id is what `POST /agent` takes back, so it is
    /// what the phone sends as `agent`.
    func v2Agents() async throws -> [AgentInfo] {
        let list = try await v2Get("/api/agent", directory: catalogDirectory) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String,
                  item["mode"] as? String != "subagent",
                  item["hidden"] as? Bool != true
            else { return nil }
            return AgentInfo(
                name: id, description: item["description"] as? String, mode: item["mode"] as? String
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Session operations

    func v2RunBuiltin(
        _ builtin: Builtin, sessionID: String, directory: String,
        providerID: String?, modelID: String?
    ) async throws -> String? {
        switch builtin {
        case .summarize:
            // Queued like a prompt; the compaction streams as events.
            try await post("/api/session/\(sessionID)/compact")
            return nil
        case .share, .unshare:
            return "OpenCode 2 removed session sharing."
        case .undo:
            let messages = try await v2RawMessages(sessionID: sessionID)
            guard let id = messages.last(where: { $0["type"] as? String == "user" })?["id"] as? String
            else { return "Nothing to undo." }
            try await post(
                "/api/session/\(sessionID)/revert/stage", body: ["messageID": id, "files": true]
            )
            return "Reverted the last exchange."
        case .redo:
            try await request(
                "/api/session/\(sessionID)/revert", method: "DELETE", directory: nil, body: nil
            )
            return "Restored."
        }
    }

    func v2RunCommand(
        sessionID: String, directory: String, command: String, arguments: String,
        providerID: String?, modelID: String?, attachments: [Attachment], agent: String?
    ) async throws {
        // Same courtesy as 1.x: name the problem rather than relay a 404.
        let known = try await v2Commands()
        guard known.contains(where: { $0.name == command && $0.source != "session" }) else {
            throw AdapterError.unknownCommand(command)
        }
        try await v2Select(sessionID: sessionID, providerID: providerID, modelID: modelID, agent: agent)
        let (text, files) = try Self.v2Input(text: arguments, attachments: attachments)
        var body: [String: Any] = ["name": command, "text": text]
        if !files.isEmpty { body["files"] = files }
        try await post("/api/session/\(sessionID)/command", body: body, timeout: Self.turnTimeout)
    }

    func v2CreateSession(directory: String) async throws -> String {
        // The location goes in the body: on this endpoint the query
        // parameter is ignored and the session would land in the server's
        // own cwd (seen live).
        let json = try await v2Post("/api/session", body: ["location": ["directory": directory]])
        guard let id = json["id"] as? String else {
            throw AdapterError.http(path: "/api/session", status: 0, body: "no id in response")
        }
        return id
    }

    private func v2Post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        Self.unwrapped(try await post(path, body: body)) as? [String: Any] ?? [:]
    }

    func v2Prompt(
        sessionID: String, directory: String, text: String,
        providerID: String, modelID: String, attachments: [Attachment], agent: String?
    ) async throws {
        try await v2Select(sessionID: sessionID, providerID: providerID, modelID: modelID, agent: agent)
        let (text, files) = try Self.v2Input(text: text, attachments: attachments)
        var body: [String: Any] = ["text": text]
        if !files.isEmpty { body["files"] = files }
        try await post("/api/session/\(sessionID)/prompt", body: body)
    }

    /// Model and agent are session state in 2.x. Switching records a
    /// message in the thread, so only an actual change is sent.
    private func v2Select(
        sessionID: String, providerID: String?, modelID: String?, agent: String?
    ) async throws {
        guard (providerID != nil && modelID != nil) || agent != nil else { return }
        let session = try await v2Session(sessionID)
        if let providerID, let modelID {
            let current = session["model"] as? [String: Any]
            if current?["providerID"] as? String != providerID || current?["id"] as? String != modelID {
                try await post(
                    "/api/session/\(sessionID)/model",
                    body: ["model": ["providerID": providerID, "id": modelID]]
                )
            }
        }
        if let agent, session["agent"] as? String != agent {
            try await post("/api/session/\(sessionID)/agent", body: ["agent": agent])
        }
    }

    /// A prompt's text and file attachments. Images and PDFs ride as data:
    /// URIs, which 2.x decodes itself; text-like files are inlined into the
    /// prompt text, as 1.x got them as text parts.
    static func v2Input(
        text: String, attachments: [Attachment]
    ) throws -> (text: String, files: [[String: Any]]) {
        var text = text
        var files: [[String: Any]] = []
        for attachment in attachments {
            switch AttachmentDelivery.classify(attachment) {
            case .image, .pdf:
                files.append([
                    "uri": "data:\(attachment.mime);base64,\(attachment.data)",
                    "name": attachment.name,
                ])
            case let .text(contents):
                text += "\n\n" + AttachmentDelivery.inlined(name: attachment.name, text: contents)
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
        return (text, files)
    }

    // MARK: - MCP

    func v2McpStatus(directory: String) async throws -> [String: (status: String, error: String?)] {
        let list = try await v2Get("/api/mcp", directory: directory) as? [[String: Any]] ?? []
        var result: [String: (status: String, error: String?)] = [:]
        for server in list {
            guard let name = server["name"] as? String else { continue }
            let status = server["status"] as? [String: Any]
            result[name] = (status?["status"] as? String ?? "unknown", status?["error"] as? String)
        }
        return result
    }

    /// A runtime override in the instance for `directory` (2.x calls the
    /// endpoint experimental; it never writes config, which suits us, since
    /// the companion owns the file). The block is converted to 2.x's
    /// encoding: `enabled: false` became `disabled: true`, and the timeout
    /// became a per-phase object, so it is left to the file.
    func v2AddMcp(_ server: McpServerConfig, directory: String) async throws -> (status: String, error: String?) {
        var config = server.block()
        if let enabled = config.removeValue(forKey: "enabled") as? Bool, !enabled {
            config["disabled"] = true
        }
        config["timeout"] = nil
        try await request(
            "/api/experimental/mcp/\(Self.pathEncoded(server.name))", method: "PUT",
            directory: directory, body: ["config": config], timeout: Self.requestTimeout * 2
        )
        let status = try await v2McpStatus(directory: directory)[server.name]
        return status ?? ("unknown", nil)
    }

    func v2DisconnectMcp(_ name: String, directory: String) async throws {
        try await post("/api/experimental/mcp/\(Self.pathEncoded(name))/disconnect", directory: directory)
    }

    static func pathEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? text
    }

    /// 2.x rule → the 1.x shape the rule logic is written against.
    static func v1Rule(from rule: [String: Any]) -> [String: Any] {
        [
            "permission": rule["action"] as? String ?? "",
            "pattern": rule["resource"] as? String ?? "*",
            "action": rule["effect"] as? String ?? "ask",
        ]
    }

    static func v2Rule(from rule: [String: Any]) -> [String: Any] {
        [
            "action": rule["permission"] as? String ?? "",
            "resource": rule["pattern"] as? String ?? "*",
            "effect": rule["action"] as? String ?? "ask",
        ]
    }

    // MARK: - Todos, working tree, projects, sessions

    /// 2.x has no todo endpoint; the list lives in the todo tool's input.
    /// The latest call is the current plan.
    func v2Todos(sessionID: String, directory: String) async throws -> [TodoItem] {
        let messages = try await v2RawMessages(sessionID: sessionID)
        for message in messages.reversed() {
            let content = message["content"] as? [[String: Any]] ?? []
            for item in content.reversed() where Self.isTodoTool(item["name"] as? String) {
                let input = (item["state"] as? [String: Any])?["input"] as? [String: Any]
                if let todos = input?["todos"] as? [[String: Any]] { return Self.todos(from: todos) }
            }
        }
        return []
    }

    static func isTodoTool(_ name: String?) -> Bool {
        name == "todo" || name == "todowrite"
    }

    /// 1.x's `git` mode (working tree against HEAD) is 2.x's `working`.
    func v2WorkingChanges(directory: String, mode: String) async throws -> WorkingChanges {
        let vcs = try await v2Get("/api/vcs", directory: directory) as? [String: Any] ?? [:]
        let branch = vcs["branch"] as? [String: Any]
        let v2Mode = mode == "git" ? "working" : mode
        let list = try await v2Get("/api/vcs/diff?mode=\(v2Mode)", directory: directory)
            as? [[String: Any]] ?? []
        return WorkingChanges(
            branch: branch?["current"] as? String,
            defaultBranch: branch?["default"] as? String,
            files: list.compactMap(Self.fileDiff(from:)),
            mode: mode
        )
    }

    static func fileDiff(from item: [String: Any]) -> FileDiff? {
        guard let file = item["file"] as? String else { return nil }
        return FileDiff(
            file: file,
            patch: item["patch"] as? String,
            additions: item["additions"] as? Int,
            deletions: item["deletions"] as? Int,
            status: item["status"] as? String
        )
    }

    func v2Projects() async throws -> [Project] {
        let list = try await v2Get("/api/project") as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String, id != "global",
                  let worktree = item["canonical"] as? String
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

    /// Root sessions only: a subagent's child session is part of its
    /// parent's thread, not a thread of its own.
    func v2Sessions(limit: Int, search: String?) async throws -> [Session] {
        var path = "/api/session?limit=\(limit)&order=desc&parentID=null"
        if let search, !search.isEmpty { path += "&search=\(Self.queryEncoded(search))" }
        let list = try await v2Get(path) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let time = item["time"] as? [String: Any]
            return Session(
                id: id,
                title: item["title"] as? String,
                directory: (item["location"] as? [String: Any])?["directory"] as? String,
                updated: (time?["updated"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
    }

    // MARK: - Permissions and questions

    func v2PendingPermissions(directory: String) async throws -> [PermissionRequest] {
        let list = try await v2Get("/api/permission/request", directory: directory)
            as? [[String: Any]] ?? []
        return list.map(Self.v1Permission(from:)).compactMap(Self.permission(from:))
    }

    /// A 2.x permission request in the 1.x names `permission(from:)` reads:
    /// `action` was `permission`, `resources` were `patterns`, and `save`
    /// (what "always" would whitelist) was `always`.
    static func v1Permission(from request: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out["id"] = request["id"]
        out["sessionID"] = request["sessionID"]
        out["permission"] = request["action"]
        out["patterns"] = request["resources"]
        out["always"] = request["save"]
        out["metadata"] = request["metadata"]
        return out
    }

    func v2PendingQuestions(directory: String) async throws -> [QuestionRequest] {
        let list = try await v2Get("/api/form", directory: directory) as? [[String: Any]] ?? []
        return list.compactMap(Self.v1Question(from:)).compactMap(Self.question(from:))
    }

    /// A form as a 1.x question request, or nil when it asks for something
    /// a question card can't answer (a number, an external link). The
    /// question tool's own forms always convert: one string or multiselect
    /// field per question, keyed `q0`, `q1`…, with the header as the title
    /// and the question as the description.
    static func v1Question(from form: [String: Any]) -> [String: Any]? {
        guard let id = form["id"] as? String,
              let fields = form["fields"] as? [[String: Any]], !fields.isEmpty
        else { return nil }
        var questions: [[String: Any]] = []
        for field in fields {
            let type = field["type"] as? String
            var options = (field["options"] as? [[String: Any]] ?? []).map { option -> [String: Any] in
                var out: [String: Any] = ["label": option["label"] as? String ?? option["value"] as? String ?? ""]
                if let description = option["description"] { out["description"] = description }
                return out
            }
            switch type {
            case "string", "multiselect":
                break
            case "boolean":
                options = [["label": "Yes"], ["label": "No"]]
            default:
                return nil
            }
            let title = field["title"] as? String
            questions.append([
                "question": field["description"] as? String ?? title ?? form["title"] as? String ?? "",
                "header": title ?? form["title"] as? String ?? "",
                "options": options,
                "multiple": type == "multiselect",
                "custom": type == "boolean" ? false : (field["custom"] as? Bool ?? options.isEmpty),
            ])
        }
        return ["id": id, "sessionID": form["sessionID"] as Any, "questions": questions]
    }

    /// Answers by question index, as the card collects them, become the
    /// form's answer keyed by field: a multiselect takes the list, a
    /// boolean "Yes", anything else the first answer.
    func v2ReplyQuestion(id: String, directory: String, answers: [[String]]) async throws {
        let forms = try await v2Get("/api/form", directory: directory) as? [[String: Any]] ?? []
        guard let form = forms.first(where: { $0["id"] as? String == id }),
              let sessionID = form["sessionID"] as? String
        else {
            throw AdapterError.http(path: "/api/form", status: 404, body: "That question is no longer pending.")
        }
        var answer: [String: Any] = [:]
        for (index, field) in (form["fields"] as? [[String: Any]] ?? []).enumerated() {
            guard let key = field["key"] as? String, index < answers.count else { continue }
            let given = answers[index]
            switch field["type"] as? String {
            case "multiselect": answer[key] = given
            case "boolean": if let first = given.first { answer[key] = first == "Yes" }
            default: if let first = given.first { answer[key] = first }
            }
        }
        try await post("/api/session/\(sessionID)/form/\(id)/reply", body: ["answer": answer])
    }

    // MARK: - Transcript

    /// Every message record of the session, oldest first, as 2.x stores
    /// them. Paged at the server's maximum of 200.
    func v2RawMessages(sessionID: String) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var cursor: String?
        repeat {
            var path = "/api/session/\(sessionID)/message?limit=200&order=asc"
            if let cursor { path += "&cursor=\(Self.queryEncoded(cursor))" }
            let json = try await get(path) as? [String: Any] ?? [:]
            let page = json["data"] as? [[String: Any]] ?? []
            out += page
            cursor = page.count == 200 ? (json["cursor"] as? [String: Any])?["next"] as? String : nil
        } while cursor != nil
        return out
    }

    /// How many recent turns get their diff computed for a transcript.
    /// 2.x works each one out from snapshots on request, so a long thread
    /// would otherwise cost a request per turn it ever had.
    static let diffTurnLimit = 30

    /// The session's messages in 1.x shape (`[{info, parts}]`), which is
    /// what the transcript, the per-turn diffs and the context meter read.
    /// Each turn's diff is attached to the user message that opened it as
    /// `info.summary.diffs`, where 1.x kept it.
    func v2Messages(sessionID: String, directory: String) async throws -> [[String: Any]] {
        let raw = try await v2RawMessages(sessionID: sessionID)
        var out = raw.compactMap(Self.v1Message(from:))
        let openers = Array(Self.turnOpeners(in: raw).suffix(Self.diffTurnLimit))
        let diffs = await withTaskGroup(of: (String, [[String: Any]]).self) { group in
            for id in openers {
                group.addTask {
                    let list = (try? await self.v2Get("/api/session/\(sessionID)/diff?from=\(id)"))
                        as? [[String: Any]] ?? []
                    return (id, list)
                }
            }
            var result: [String: [[String: Any]]] = [:]
            for await (id, list) in group { result[id] = list }
            return result
        }
        for index in out.indices {
            guard var info = out[index]["info"] as? [String: Any],
                  let id = info["id"] as? String, let list = diffs[id], !list.isEmpty
            else { continue }
            info["summary"] = ["diffs": list]
            out[index]["info"] = info
        }
        return out
    }

    /// The user message that opened each turn: the first one after the
    /// start or after an idle marker. Prompts steered in mid-turn belong
    /// to the turn already running.
    static func turnOpeners(in messages: [[String: Any]]) -> [String] {
        var openers: [String] = []
        var open = false
        for message in messages {
            switch message["type"] as? String {
            case "idle": open = false
            case "user":
                if !open, let id = message["id"] as? String { openers.append(id) }
                open = true
            default: continue
            }
        }
        return openers
    }

    /// One 2.x message as a 1.x `{info, parts}` record, or nil for the
    /// kinds the transcript never showed (markers, switches, system text).
    static func v1Message(from message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"] as? String else { return nil }
        switch message["type"] as? String {
        case "user":
            return [
                "info": ["id": id, "role": "user"],
                "parts": [["type": "text", "id": "\(id):text", "text": message["text"] as? String ?? ""]],
            ]
        case "assistant":
            var info: [String: Any] = ["id": id, "role": "assistant"]
            if let model = message["model"] as? [String: Any] {
                info["providerID"] = model["providerID"]
                info["modelID"] = model["id"]
            }
            if let tokens = message["tokens"] { info["tokens"] = tokens }
            // Ordinals count per kind within a step, as the live events
            // number them: the second text block is text 1 however many
            // tool calls sit between.
            var counters: [String: Int] = [:]
            let content = message["content"] as? [[String: Any]] ?? []
            let parts = content.compactMap { item -> [String: Any]? in
                let kind = item["type"] as? String ?? ""
                let ordinal = counters[kind, default: 0]
                counters[kind] = ordinal + 1
                return v1Part(from: item, messageID: id, ordinal: ordinal)
            }
            return ["info": info, "parts": parts]
        default:
            return nil
        }
    }

    /// One assistant content item as a 1.x part. Text and reasoning take a
    /// stable id from their message and position, the same one the live
    /// translator gives them, so a resumed view and a live one agree.
    static func v1Part(from item: [String: Any], messageID: String, ordinal: Int) -> [String: Any]? {
        switch item["type"] as? String {
        case "text":
            return ["type": "text", "id": "\(messageID):text:\(ordinal)", "text": item["text"] as? String ?? ""]
        case "reasoning":
            return [
                "type": "reasoning", "id": "\(messageID):reasoning:\(ordinal)",
                "text": item["text"] as? String ?? "",
            ]
        case "tool":
            let state = item["state"] as? [String: Any] ?? [:]
            return v1ToolPart(
                id: item["id"] as? String ?? "\(messageID):tool:\(ordinal)",
                name: item["name"] as? String,
                status: state["status"] as? String,
                input: state["input"] as? [String: Any]
            )
        default:
            return nil
        }
    }

    /// A tool call as a 1.x tool part. 2.x calls the file argument `path`
    /// where 1.x said `filePath`, and `streaming` is 1.x's `pending`.
    static func v1ToolPart(
        id: String, name: String?, status: String?, input: [String: Any]?
    ) -> [String: Any] {
        var state: [String: Any] = ["status": status == "streaming" ? "pending" : (status ?? "pending")]
        if var input {
            if input["filePath"] == nil, let path = input["path"] { input["filePath"] = path }
            state["input"] = input
        }
        var part: [String: Any] = ["type": "tool", "id": id, "state": state]
        if let name { part["tool"] = name }
        return part
    }
}
