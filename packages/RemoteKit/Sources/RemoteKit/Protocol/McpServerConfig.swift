import Foundation

/// One MCP server as OpenCode's global config describes it: the editable
/// definition, as opposed to `McpServer`, which is the runtime view (status,
/// per-conversation switch). Clients edit these; the Mac writes them into
/// `mcp.<name>` of opencode.json, keeping only the keys OpenCode reads.
public struct McpServerConfig: Codable, Hashable, Identifiable, Sendable {
    /// The config key, and the prefix of every tool the server contributes
    /// (`<name>_<tool>`, both halves sanitized by OpenCode).
    public var name: String
    /// "local" (a command OpenCode spawns, speaking stdio) or "remote"
    /// (an HTTP URL, Streamable HTTP with an SSE fallback).
    public var type: String
    /// local: the executable and its arguments.
    public var command: [String]?
    public var cwd: String?
    public var environment: [String: String]?
    /// remote: where the server listens.
    public var url: String?
    public var headers: [String: String]?
    /// Seconds OpenCode waits for the server to connect and for a call.
    public var timeout: Int?
    /// Absent reads as true. False keeps the entry but never connects it,
    /// which is OpenCode's own way of parking a server.
    public var enabled: Bool?
    /// remote: true writes `oauth: false`, which stops OpenCode probing the
    /// URL for an OAuth flow. Anything else about OAuth stays as the file
    /// has it; a full OAuth block is beyond what the clients edit.
    public var oauthDisabled: Bool?

    public var id: String { name }
    public var isEnabled: Bool { enabled ?? true }
    public var isLocal: Bool { type == "local" }

    public init(
        name: String, type: String, command: [String]? = nil, cwd: String? = nil,
        environment: [String: String]? = nil, url: String? = nil,
        headers: [String: String]? = nil, timeout: Int? = nil, enabled: Bool? = nil,
        oauthDisabled: Bool? = nil
    ) {
        self.name = name
        self.type = type
        self.command = command
        self.cwd = cwd
        self.environment = environment
        self.url = url
        self.headers = headers
        self.timeout = timeout
        self.enabled = enabled
        self.oauthDisabled = oauthDisabled
    }

    /// Reads one `mcp.<name>` block. Nil for a block this model can't
    /// represent (OpenCode also accepts a bare `{enabled: false}` stub that
    /// disables a server defined in another config layer); such blocks are
    /// left in the file untouched.
    public init?(name: String, block: [String: Any]) {
        let type = block["type"] as? String
            ?? (block["command"] != nil ? "local" : block["url"] != nil ? "remote" : nil)
        guard let type, type == "local" || type == "remote" else { return nil }
        self.name = name
        self.type = type
        command = block["command"] as? [String]
        cwd = block["cwd"] as? String
        environment = block["environment"] as? [String: String]
        url = block["url"] as? String
        headers = block["headers"] as? [String: String]
        timeout = (block["timeout"] as? NSNumber)?.intValue
        enabled = block["enabled"] as? Bool
        if let oauth = block["oauth"] as? Bool, oauth == false { oauthDisabled = true }
    }

    /// The keys this model owns in a block; anything else in an existing
    /// block (a full `oauth` object, a key a newer OpenCode added) is kept.
    private static let ownedKeys: Set<String> = [
        "type", "command", "cwd", "environment", "url", "headers", "timeout", "enabled",
    ]

    /// The block OpenCode reads, layered over `existing` so unknown keys
    /// survive an edit. Only keys with a value are written: OpenCode's
    /// schema rejects nothing, but a `null` where it expects a string is a
    /// parse failure at startup.
    public func block(over existing: [String: Any]? = nil) -> [String: Any] {
        var block = (existing ?? [:]).filter { !Self.ownedKeys.contains($0.key) }
        block["type"] = type
        if isLocal {
            if let command, !command.isEmpty { block["command"] = command }
            if let cwd, !cwd.isEmpty { block["cwd"] = cwd }
            if let environment, !environment.isEmpty { block["environment"] = environment }
            // A remote block being turned local sheds its remote-only keys.
            block["oauth"] = nil
        } else {
            if let url { block["url"] = url }
            if let headers, !headers.isEmpty { block["headers"] = headers }
            if oauthDisabled == true {
                block["oauth"] = false
            } else if existing?["oauth"] as? Bool == false {
                block["oauth"] = nil
            }
        }
        if let timeout, timeout > 0 { block["timeout"] = timeout }
        if let enabled, !enabled { block["enabled"] = false }
        return block
    }

    /// Why this definition can't be saved, or nil.
    public var validationProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "The server needs a name." }
        if trimmed.contains(where: \.isWhitespace) { return "The name can't contain spaces." }
        switch type {
        case "local":
            guard let command, let first = command.first,
                  !first.trimmingCharacters(in: .whitespaces).isEmpty
            else { return "A local server needs a command to run." }
        case "remote":
            guard let url, let parsed = URL(string: url),
                  let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  parsed.host != nil
            else { return "A remote server needs an http or https URL." }
        default:
            return "The server type must be local or remote."
        }
        if let timeout, timeout <= 0 { return "The timeout must be a positive number of seconds." }
        return nil
    }

    /// One line a list can show: the command or the URL.
    public var summary: String {
        if isLocal { return (command ?? []).joined(separator: " ") }
        return url ?? ""
    }
}

/// Edits to the `mcp` block of OpenCode's global config, as pure functions
/// over the parsed root so they can be tested without a file.
public enum McpConfigEdit {
    /// Every server the config defines, in name order.
    public static func servers(in root: [String: Any]) -> [McpServerConfig] {
        let mcp = root["mcp"] as? [String: Any] ?? [:]
        return mcp.compactMap { name, value in
            guard let block = value as? [String: Any] else { return nil }
            return McpServerConfig(name: name, block: block)
        }
        .sorted { $0.name < $1.name }
    }

    /// The raw block for one server, for callers that need what this
    /// model doesn't represent.
    public static func block(named name: String, in root: [String: Any]) -> [String: Any]? {
        (root["mcp"] as? [String: Any])?[name] as? [String: Any]
    }

    /// Add or replace one server. Unknown keys of an existing block are
    /// kept; nothing else in the file is touched.
    public static func upsert(_ server: McpServerConfig, in root: [String: Any]) -> [String: Any] {
        var root = root
        var mcp = root["mcp"] as? [String: Any] ?? [:]
        mcp[server.name] = server.block(over: mcp[server.name] as? [String: Any])
        root["mcp"] = mcp
        return root
    }

    /// Drop one server. An emptied `mcp` block is removed rather than left
    /// as `{}`, so a config that never had one goes back to not having one.
    public static func remove(_ name: String, from root: [String: Any]) -> [String: Any] {
        var root = root
        var mcp = root["mcp"] as? [String: Any] ?? [:]
        mcp[name] = nil
        root["mcp"] = mcp.isEmpty ? nil : mcp
        return root
    }

    /// Whether the config's `permission` block denies every tool of the
    /// named server (`<server>_*: deny`), which hides its tools from every
    /// session unless that session allows them back. How the companion's
    /// own tool server stays out of ordinary conversations.
    public static func isDeniedByConfig(_ sanitizedName: String, in root: [String: Any]) -> Bool {
        guard let permission = root["permission"] as? [String: Any] else { return false }
        return permission["\(sanitizedName)_*"] as? String == "deny"
    }

    /// Write the config-level deny for a server. A `permission` that isn't
    /// an object (OpenCode also accepts a single string) is widened to the
    /// object form with the same meaning under `*`.
    public static func denyByConfig(_ sanitizedName: String, in root: [String: Any]) -> [String: Any] {
        var root = root
        var permission: [String: Any]
        switch root["permission"] {
        case let object as [String: Any]: permission = object
        case let action as String: permission = ["*": action]
        default: permission = [:]
        }
        permission["\(sanitizedName)_*"] = "deny"
        root["permission"] = permission
        return root
    }

    /// OpenCode names an MCP tool `<server>_<tool>`, squashing anything
    /// outside [a-zA-Z0-9_-] in either half to "_" (their
    /// McpCatalog.sanitize). Rules that name a server's tools must match
    /// that spelling, not the raw config key.
    public static func sanitized(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a" ... "z", "A" ... "Z", "0" ... "9", "-", "_": return Character(scalar)
            default: return "_"
            }
        })
    }
}
