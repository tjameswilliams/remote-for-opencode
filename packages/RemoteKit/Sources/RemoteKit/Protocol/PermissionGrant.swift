import Foundation

/// One way of saying yes that outlives the ask: a set of patterns the
/// user can choose to whitelist instead of OpenCode's own suggestion.
///
/// OpenCode's `always` reply is exact: it whitelists the patterns the
/// server proposes, which for a folder is the immediate parent and for a
/// command is the command. A model that reads its way across a sibling
/// project therefore asks once per subfolder, and a user who has said
/// yes four times in a row has learned nothing except to tap yes. The
/// scopes below are the wider grants the card offers alongside; the Mac
/// computes them (it can see the disk) and sends them with the ask, so
/// the phone never guesses at a path.
public struct PermissionScope: Codable, Equatable, Identifiable, Sendable {
    /// Stable within one ask: "folder", "project", "command", "prefix".
    public var id: String
    /// The choice as the card shows it: "Whole project: ai-video-editor".
    public var label: String
    /// What gets whitelisted, in OpenCode's pattern syntax.
    public var patterns: [String]

    public init(id: String, label: String, patterns: [String]) {
        self.id = id
        self.label = label
        self.patterns = patterns
    }
}

/// The rider on an approving reply: which patterns to whitelist and for
/// how long. Without one, a reply is exactly what OpenCode offers.
public struct PermissionGrant: Codable, Equatable, Sendable {
    /// The permission class the rule is for: "external_directory", "bash".
    public var permission: String
    public var patterns: [String]
    /// True writes the rule into the project's config, where it survives
    /// restarts and applies to every conversation; false applies it to
    /// this session only, and immediately.
    public var persist: Bool

    public init(permission: String, patterns: [String], persist: Bool) {
        self.permission = permission
        self.patterns = patterns
        self.persist = persist
    }
}

/// Everything a client sends back for one ask.
public struct PermissionAnswer: Equatable, Sendable {
    /// "once" | "always" | "reject"
    public var reply: String
    /// Direction for the agent when redirecting instead of just refusing.
    public var message: String?
    public var grant: PermissionGrant?

    public init(reply: String, message: String? = nil, grant: PermissionGrant? = nil) {
        self.reply = reply
        self.message = message
        self.grant = grant
    }
}

public enum PermissionScopes {
    /// The wider grants worth offering for `request`, narrowest first.
    /// Empty for anything the card should never offer blanket approval
    /// on: a command already classified as dangerous, the network.
    ///
    /// `projectRoot` answers "which project holds this path": the Mac
    /// walks the disk for a `.git`; tests hand in a table.
    public static func candidates(
        for request: PermissionRequest,
        projectRoot: (String) -> String?
    ) -> [PermissionScope] {
        let patterns = request.patterns ?? []
        guard let permission = request.permission, let first = patterns.first else { return [] }
        let suggested = (request.always ?? []).isEmpty ? patterns : request.always!
        switch permission {
        case "external_directory", "read", "glob", "grep", "list", "edit", "write", "patch":
            var scopes = [PermissionScope(id: "folder", label: "This folder", patterns: suggested)]
            if let root = projectRoot(directory(of: first)) {
                let folder = directory(of: first)
                // The parent itself is what "this folder" already covers;
                // a project scope that says the same thing twice is noise.
                if folder != root {
                    let name = (root as NSString).lastPathComponent
                    scopes.append(PermissionScope(
                        id: "project", label: "Whole project: \(name)", patterns: [root + "/**"]
                    ))
                }
            }
            return scopes
        case "bash":
            guard PermissionRisk.classify(permission: permission, patterns: patterns) != .high
            else { return [] }
            var scopes = [PermissionScope(id: "command", label: "This command", patterns: suggested)]
            if let word = first.split(separator: " ").first.map(String.init),
               !word.isEmpty, word != first,
               !PermissionRisk.dangerous.contains(where: { $0.trimmingCharacters(in: .whitespaces) == word }) {
                scopes.append(PermissionScope(
                    id: "prefix", label: "Every \(word) command", patterns: ["\(word) *"]
                ))
            }
            return scopes
        default:
            return []
        }
    }

    /// The folder a pattern is about: `/a/b/*` and `/a/b/file.ts` both
    /// mean `/a/b`.
    static func directory(of pattern: String) -> String {
        if pattern.hasSuffix("/**") { return String(pattern.dropLast(3)) }
        if pattern.hasSuffix("/*") { return String(pattern.dropLast(2)) }
        if pattern.hasSuffix("/") { return String(pattern.dropLast()) }
        return (pattern as NSString).deletingLastPathComponent
    }

    /// OpenCode's wildcard rules: `*` is zero or more of anything, `?` is
    /// exactly one; everything else is literal. Slashes are not special.
    public static func matches(pattern: String, _ text: String) -> Bool {
        var regex = "^"
        for scalar in pattern.unicodeScalars {
            switch scalar {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(scalar))
            }
        }
        regex += "$"
        return text.range(of: regex, options: .regularExpression) != nil
    }

    /// The nearest ancestor of `path` (or `path` itself) that holds a
    /// `.git`, or nil when the path is in no repository.
    public static func projectRoot(
        containing path: String, fileManager: FileManager = .default
    ) -> String? {
        var current = (path as NSString).standardizingPath
        while !current.isEmpty, current != "/" {
            let marker = (current as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: marker) { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}

/// The `permission` block of an opencode.json, edited to add a rule.
public enum PermissionConfig {
    /// Returns `root` with `permission.<permission>` holding
    /// `pattern: "allow"` for each pattern, converting the shorthand
    /// forms OpenCode accepts (`"permission": "ask"`,
    /// `"bash": "allow"`) into the object form that can carry rules. A
    /// shorthand becomes the `*` entry, so nothing the user had set is
    /// lost. Idempotent.
    public static func allowing(
        _ patterns: [String], for permission: String, in root: [String: Any]
    ) -> [String: Any] {
        var root = root
        var block: [String: Any]
        switch root["permission"] {
        case let object as [String: Any]: block = object
        case let shorthand as String: block = ["*": shorthand]
        default: block = [:]
        }
        var rules: [String: Any]
        switch block[permission] {
        case let object as [String: Any]: rules = object
        case let shorthand as String: rules = ["*": shorthand]
        default: rules = [:]
        }
        for pattern in patterns { rules[pattern] = "allow" }
        block[permission] = rules
        root["permission"] = block
        return root
    }

    /// The project-level config file OpenCode reads for `directory`.
    public static func projectPath(for directory: String) -> String {
        ((directory as NSString).appendingPathComponent(".opencode") as NSString)
            .appendingPathComponent("opencode.json")
    }
}
