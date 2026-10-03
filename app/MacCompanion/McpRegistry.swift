import Foundation
import OSLog
import RemoteKit

/// The Mac's global view of MCP servers: the roster in OpenCode's global
/// config, each server's default (whether a new conversation starts with
/// its tools on), and the edits the clients and the management tools make
/// to both. Per-conversation switches (McpStore, session permission rules)
/// sit on top and always win.
///
/// The companion also offers a small MCP server of its own, `remote`,
/// whose tools are exactly these operations. It is registered in the
/// global config at launch, hidden from every conversation by a
/// config-level deny rule, and allowed back only where the defaults say:
/// the chat folder, where the global chat lives. So "ask the assistant to
/// add an MCP server" works from a plain chat, and a project session never
/// sees management tools it didn't ask for.
@MainActor
final class McpRegistry: ObservableObject {
    static let shared = McpRegistry()

    /// The companion's own server, as opencode.json names it and as
    /// OpenCode prefixes its tools (`remote_mcp_add`).
    static let builtinName = "remote"
    /// Loopback port for the tool server. Fixed, like the Wire port, so
    /// the config entry written at launch stays true across launches.
    static let toolPort: UInt16 = 8767
    static let toolPath = "/mcp"

    /// Per-server defaults, by config name. Absent reads as on; only
    /// servers switched off are stored, so a server removed and re-added
    /// comes back on, which is what a fresh definition should do.
    @Published private(set) var defaults: [String: Bool]

    /// The Mac's `opencode serve`, for the live half of an edit. Wired by
    /// the app; nil while OpenCode is down, in which case the file is
    /// still edited and the change lands at the next start.
    var adapter: () -> OpenCodeAdapter? = { nil }

    let configPath: String
    private let logger = Logger(subsystem: "com.timwilliams.opencodego", category: "mcp")
    private static let defaultsKey = "mcpDefaults"
    private static let tokenKey = "mcpTools.token"
    /// Servers removed from the file this run. OpenCode's status keeps
    /// listing a server from its startup config (as `disabled`) until a
    /// restart, and the list shouldn't show a ghost of what was deleted.
    private var removedPendingRestart: Set<String> = []

    init(configPath: String = OpenCodeConfigFile.globalPath()) {
        self.configPath = configPath
        defaults = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
        if let stored = UserDefaults.standard.string(forKey: Self.tokenKey), !stored.isEmpty {
            token = stored
        } else {
            token = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
                .map { String(format: "%02x", $0) }.joined()
            UserDefaults.standard.set(token, forKey: Self.tokenKey)
        }
    }

    // MARK: - The tool server's identity

    /// The bearer token OpenCode presents on every call. Loopback only,
    /// so its job is defense in depth: another local process that finds
    /// the port still can't drive the companion into rewriting the
    /// config through a door that looks like OpenCode's.
    let token: String

    var toolURL: String { "http://127.0.0.1:\(Self.toolPort)\(Self.toolPath)" }

    /// The config entry for the companion's own server, plus the
    /// config-level deny that keeps its tools out of every conversation
    /// that doesn't allow them back. Written before OpenCode starts (the
    /// file is read once, at startup) and only when something differs,
    /// so a launch with nothing to change touches nothing. Failure is
    /// logged, not fatal: OpenCode runs fine without management tools.
    func registerToolServer() {
        do {
            let root = try OpenCodeConfigFile.read(at: configPath)
            let wanted = McpServerConfig(
                name: Self.builtinName, type: "remote", url: toolURL,
                headers: ["Authorization": "Bearer \(token)"], oauthDisabled: true
            )
            var updated = McpConfigEdit.upsert(wanted, in: root)
            updated = McpConfigEdit.denyByConfig(McpConfigEdit.sanitized(Self.builtinName), in: updated)
            guard !NSDictionary(dictionary: updated).isEqual(to: root) else { return }
            let backup = try OpenCodeConfigFile.write(updated, to: configPath)
            logger.notice(
                "registered the tool server in \(self.configPath, privacy: .public)\(backup.map { ", backup at \($0)" } ?? "", privacy: .public)"
            )
        } catch {
            logger.error("could not register the tool server: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Defaults

    /// Whether a new conversation in `directory` starts with this server's
    /// tools on. The companion's own server has a fixed answer: on in the
    /// chat folder, off everywhere else. Everything else is the user's
    /// setting, on until switched off.
    func isDefaultEnabled(_ name: String, directory: String) -> Bool {
        if name == Self.builtinName { return directory == ChatFolder.path }
        return defaults[name] ?? true
    }

    /// Set the named servers' defaults; unnamed ones keep theirs. The
    /// builtin's default is not a setting and is ignored here.
    func setDefaults(_ changes: [String: Bool]) {
        for (name, enabled) in changes where name != Self.builtinName {
            defaults[name] = enabled ? nil : false
        }
        UserDefaults.standard.set(defaults, forKey: Self.defaultsKey)
    }

    private func configRoot() -> [String: Any] {
        (try? OpenCodeConfigFile.read(at: configPath)) ?? [:]
    }

    /// Sanitized names of every server the config's `permission` block
    /// denies outright; a session that wants one needs an allow rule.
    private func configDenied(_ names: some Sequence<String>, root: [String: Any]) -> Set<String> {
        Set(names.map(McpConfigEdit.sanitized).filter { McpConfigEdit.isDeniedByConfig($0, in: root) })
    }

    /// What a fresh session in `directory` starts with, written as its
    /// rules. Called right after the session is created and before the
    /// conversation's own map, if it sent one, so the conversation's
    /// switches stay the final word. Nothing is written when the defaults
    /// say nothing (everything on, nothing config-denied), which keeps a
    /// Mac with no MCP servers from touching sessions at all.
    func applyDefaults(sessionID: String, directory: String, adapter: OpenCodeAdapter) async {
        do {
            let names = try await adapter.mcpStatus(directory: directory).keys
            let root = configRoot()
            let denied = configDenied(names, root: root)
            var map: [String: Bool] = [:]
            for name in names { map[name] = isDefaultEnabled(name, directory: directory) }
            let needsRules = map.contains { !$0.value }
                || map.contains { $0.value && denied.contains(McpConfigEdit.sanitized($0.key)) }
            guard needsRules else { return }
            try await adapter.setMcp(
                sessionID: sessionID, directory: directory, servers: map, configDenied: denied
            )
        } catch {
            logger.error("defaults not applied to \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The conversation's own map, as sent on a prompt: the complete truth
    /// for that session, over whatever the config denies.
    func setConversation(
        _ servers: [String: Bool], sessionID: String, directory: String, adapter: OpenCodeAdapter
    ) async throws {
        let denied = configDenied(servers.keys, root: configRoot())
        try await adapter.setMcp(
            sessionID: sessionID, directory: directory, servers: servers, configDenied: denied
        )
    }

    // MARK: - The list

    /// Every server OpenCode's instance for `directory` knows, joined with
    /// the global config (which says what is editable) and, when a
    /// session is named, that session's own switches. Without a session
    /// the switches show the defaults: what a new conversation would get.
    func servers(directory: String, sessionID: String?, adapter: OpenCodeAdapter) async throws -> [McpServer] {
        let root = configRoot()
        let configured = Dictionary(
            uniqueKeysWithValues: McpConfigEdit.servers(in: root).map { ($0.name, $0) }
        )
        let status = try await adapter.mcpStatus(directory: directory)
        var rules: [String: Bool] = [:]
        if let sessionID {
            rules = try await adapter.mcpRules(sessionID: sessionID, directory: directory)
        }
        let names = Set(status.keys).union(configured.keys).subtracting(removedPendingRestart)
        return names.sorted { left, right in
            // The companion's own server last: it is the odd one out.
            if (left == Self.builtinName) != (right == Self.builtinName) {
                return right == Self.builtinName
            }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
        .map { name in
            let sanitized = McpConfigEdit.sanitized(name)
            let deniedByConfig = McpConfigEdit.isDeniedByConfig(sanitized, in: root)
            let defaultOn = isDefaultEnabled(name, directory: directory)
            let enabled: Bool
            if sessionID != nil {
                enabled = rules[sanitized] ?? !deniedByConfig
            } else {
                enabled = defaultOn
            }
            let config = configured[name]
            return McpServer(
                name: name,
                status: status[name]?.status ?? (config?.isEnabled == false ? "disabled" : nil),
                enabled: enabled,
                defaultEnabled: defaultOn,
                type: config?.type,
                summary: config?.summary,
                configured: config != nil,
                builtin: name == Self.builtinName ? true : nil,
                error: status[name]?.error,
                config: name == Self.builtinName ? nil : config
            )
        }
    }

    // MARK: - Edits: the file, then the live instance

    enum EditError: LocalizedError {
        case invalid(String)
        case builtin
        case missing(String)

        var errorDescription: String? {
            switch self {
            case let .invalid(problem): return problem
            case .builtin:
                return "Remote for OpenCode's own tool server is managed by the app and can't be edited or removed."
            case let .missing(name): return "No MCP server named \"\(name)\" is in opencode.json."
            }
        }
    }

    /// Add or replace a server in the global config, then connect it in
    /// the named instance so the conversation that asked can use it on
    /// its next step. Other instances learn about it at the next
    /// OpenCode restart, which is offered rather than forced: a restart
    /// cuts off every running turn. Returns a sentence about what
    /// happened, for the tool result and the log.
    @discardableResult
    func save(
        _ incoming: McpServerConfig, directory: String, defaultEnabled: Bool? = nil
    ) async throws -> String {
        var server = incoming
        server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard server.name != Self.builtinName else { throw EditError.builtin }
        if let problem = server.validationProblem { throw EditError.invalid(problem) }
        let root = try OpenCodeConfigFile.read(at: configPath)
        let existed = McpConfigEdit.block(named: server.name, in: root) != nil
        try OpenCodeConfigFile.write(McpConfigEdit.upsert(server, in: root), to: configPath)
        removedPendingRestart.remove(server.name)
        if let defaultEnabled { setDefaults([server.name: defaultEnabled]) }
        logger.notice("\(existed ? "replaced" : "added", privacy: .public) MCP server \(server.name, privacy: .public)")
        var note = "\(existed ? "Updated" : "Added") \"\(server.name)\" in opencode.json."
        if let adapter = adapter() {
            do {
                if existed { try? await adapter.disconnectMcp(server.name, directory: directory) }
                let live = try await adapter.addMcp(server, directory: directory)
                note += " OpenCode reports it \(Self.describe(live))."
            } catch {
                note += " OpenCode couldn't connect it yet: \(error.localizedDescription)"
            }
        }
        ModelSourceStore.shared.noteRestartNeeded()
        note += " Other projects pick it up when OpenCode restarts."
        return note
    }

    /// Remove a server from the global config and disconnect it in the
    /// named instance. A server a project's own config defines isn't in
    /// this file and is refused, with the file named.
    @discardableResult
    func remove(_ name: String, directory: String) async throws -> String {
        guard name != Self.builtinName else { throw EditError.builtin }
        let root = try OpenCodeConfigFile.read(at: configPath)
        guard McpConfigEdit.block(named: name, in: root) != nil else { throw EditError.missing(name) }
        try OpenCodeConfigFile.write(McpConfigEdit.remove(name, from: root), to: configPath)
        removedPendingRestart.insert(name)
        setDefaults([name: true])
        logger.notice("removed MCP server \(name, privacy: .public)")
        if let adapter = adapter() {
            try? await adapter.disconnectMcp(name, directory: directory)
        }
        ModelSourceStore.shared.noteRestartNeeded()
        return "Removed \"\(name)\" from opencode.json and disconnected it. It disappears from other projects when OpenCode restarts."
    }

    /// OpenCode was restarted on the current file: nothing is pending.
    func noteRestarted() {
        removedPendingRestart = []
    }

    private static func describe(_ status: (status: String, error: String?)) -> String {
        switch status.status {
        case "connected": return "connected"
        case "failed": return "failed to connect" + (status.error.map { ": \($0)" } ?? "")
        case "needs_auth": return "needs authentication (run `opencode mcp auth <name>` on the Mac)"
        case "needs_client_registration": return "needs a pre-registered OAuth client id"
        default: return status.status
        }
    }

    // MARK: - The management tools

    /// The MCP server the companion offers OpenCode: these operations, as
    /// tools the global chat can call. Every edit lands in the chat
    /// folder's instance, which is the one such a conversation runs in.
    func makeToolServer() -> McpToolServer {
        McpToolServer(
            name: "Remote for OpenCode",
            version: Bundle.companionVersion,
            instructions: """
            These tools manage the MCP servers configured in OpenCode on this Mac, through the \
            Remote for OpenCode companion. Call mcp_list before changing anything. mcp_add writes \
            a server into the global opencode.json and connects it; mcp_remove deletes one; \
            mcp_set_default decides whether new conversations start with a server's tools on. \
            A conversation's own tool switches in the app still override the defaults.
            """,
            tools: [
                McpTool(
                    name: "mcp_list",
                    description: "List the MCP servers configured in OpenCode on this Mac: name, type, command or URL, connection status, and whether new conversations start with the server's tools on.",
                    inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
                ) { [weak self] _ in
                    guard let self else { throw McpToolFailure("The companion is shutting down.") }
                    return try await self.listForTool()
                },
                McpTool(
                    name: "mcp_add",
                    description: "Add an MCP server to OpenCode's global config on this Mac, or replace one with the same name, and connect it. A local server is a command OpenCode runs (stdio); a remote server is an HTTP URL (Streamable HTTP, with an SSE fallback).",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "Config key and tool prefix, e.g. \"github\". Letters, digits, dash, underscore."],
                            "type": ["type": "string", "enum": ["local", "remote"]],
                            "command": ["type": "array", "items": ["type": "string"], "description": "local: the executable and its arguments, e.g. [\"npx\", \"-y\", \"@modelcontextprotocol/server-github\"]."],
                            "cwd": ["type": "string", "description": "local: working directory, optional."],
                            "environment": ["type": "object", "additionalProperties": ["type": "string"], "description": "local: environment variables, optional."],
                            "url": ["type": "string", "description": "remote: the server URL."],
                            "headers": ["type": "object", "additionalProperties": ["type": "string"], "description": "remote: extra request headers, e.g. an Authorization header."],
                            "timeout": ["type": "integer", "description": "Seconds OpenCode waits to connect and per call, optional."],
                            "enabled": ["type": "boolean", "description": "False parks the server in the config without connecting it. Default true."],
                            "default_enabled": ["type": "boolean", "description": "Whether new conversations start with this server's tools on. Default true."],
                        ] as [String: Any],
                        "required": ["name", "type"],
                        "additionalProperties": false,
                    ]
                ) { [weak self] args in
                    guard let self else { throw McpToolFailure("The companion is shutting down.") }
                    return try await self.addFromTool(args)
                },
                McpTool(
                    name: "mcp_remove",
                    description: "Remove an MCP server from OpenCode's global config on this Mac and disconnect it.",
                    inputSchema: [
                        "type": "object",
                        "properties": ["name": ["type": "string"]] as [String: Any],
                        "required": ["name"],
                        "additionalProperties": false,
                    ]
                ) { [weak self] args in
                    guard let self else { throw McpToolFailure("The companion is shutting down.") }
                    guard let name = args["name"] as? String else { throw McpToolFailure("name is required.") }
                    return try await self.remove(name, directory: ChatFolder.path)
                },
                McpTool(
                    name: "mcp_set_default",
                    description: "Set whether new conversations start with an MCP server's tools on (true) or off (false). Existing conversations keep their own switches.",
                    inputSchema: [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string"],
                            "enabled": ["type": "boolean"],
                        ] as [String: Any],
                        "required": ["name", "enabled"],
                        "additionalProperties": false,
                    ]
                ) { [weak self] args in
                    guard let self else { throw McpToolFailure("The companion is shutting down.") }
                    guard let name = args["name"] as? String, let enabled = args["enabled"] as? Bool else {
                        throw McpToolFailure("name and enabled are required.")
                    }
                    return try await self.setDefaultFromTool(name: name, enabled: enabled)
                },
            ]
        )
    }

    private func listForTool() async throws -> String {
        guard let adapter = adapter() else { throw McpToolFailure("OpenCode is not running on this Mac.") }
        let servers = try await servers(directory: ChatFolder.path, sessionID: nil, adapter: adapter)
        let rows: [[String: Any]] = servers.map { server in
            var row: [String: Any] = [
                "name": server.name,
                "status": server.status ?? "unknown",
                "default_enabled": server.isDefaultEnabled,
                "configured_globally": server.configured ?? false,
            ]
            if let type = server.type { row["type"] = type }
            if let summary = server.summary, !summary.isEmpty {
                row[server.type == "remote" ? "url" : "command"] = summary
            }
            if let error = server.error { row["error"] = error }
            if server.builtin == true { row["note"] = "Remote for OpenCode's own management tools; not editable." }
            return row
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["servers": rows, "config": configPath],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func addFromTool(_ args: [String: Any]) async throws -> String {
        guard let name = args["name"] as? String, let type = args["type"] as? String else {
            throw McpToolFailure("name and type are required.")
        }
        let server = McpServerConfig(
            name: name, type: type,
            command: args["command"] as? [String],
            cwd: args["cwd"] as? String,
            environment: args["environment"] as? [String: String],
            url: args["url"] as? String,
            headers: args["headers"] as? [String: String],
            timeout: (args["timeout"] as? NSNumber)?.intValue,
            enabled: args["enabled"] as? Bool
        )
        return try await save(
            server, directory: ChatFolder.path, defaultEnabled: args["default_enabled"] as? Bool
        )
    }

    private func setDefaultFromTool(name: String, enabled: Bool) async throws -> String {
        guard name != Self.builtinName else { throw EditError.builtin }
        guard let adapter = adapter() else { throw McpToolFailure("OpenCode is not running on this Mac.") }
        let known = try await adapter.mcpStatus(directory: ChatFolder.path).keys
        guard known.contains(name) || McpConfigEdit.block(named: name, in: configRoot()) != nil else {
            throw EditError.missing(name)
        }
        setDefaults([name: enabled])
        return "New conversations now start with \"\(name)\" \(enabled ? "on" : "off"). Existing conversations keep their own switches."
    }
}
