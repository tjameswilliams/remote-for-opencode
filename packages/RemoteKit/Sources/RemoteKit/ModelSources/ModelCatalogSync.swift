import Foundation

/// What one check of a source would change in OpenCode's config: the
/// rewritten provider block, and the differences spelled out so a person
/// can decide. Nothing here writes; `OpenCodeConfigFile` does that, and
/// only after the plan has been shown.
public struct ModelSyncPlan: Identifiable {
    public struct ModelChange: Hashable, Sendable, Identifiable {
        public var modelID: String
        /// Human lines: "context 0 → 131072", "modalities: text, image".
        public var details: [String]
        public var id: String { modelID }
    }

    public var id: String { providerID }
    public var providerID: String
    /// True when the config had no block for this provider at all.
    public var isNewProvider: Bool
    /// Provider-level differences: base URL, package, name, key.
    public var providerChanges: [String]
    public var added: [ModelChange]
    public var changed: [ModelChange]
    public var removed: [String]
    public var unchanged: Int
    /// The block that replaces `provider.<id>` when applied.
    public var providerBlock: [String: Any]
    /// The blocks rendered as JSON, for the "show me exactly" disclosure.
    public var before: String?
    public var after: String

    public var isEmpty: Bool {
        !isNewProvider && providerChanges.isEmpty && added.isEmpty && changed.isEmpty && removed.isEmpty
    }

    /// The models the block ends up with, whatever the endpoint's order.
    public var modelCount: Int {
        (providerBlock["models"] as? [String: Any])?.count ?? 0
    }
}

/// The merge between what an endpoint says and what the config holds.
///
/// Discovered fields win. Curated fields the endpoint didn't mention (a
/// display name, a cost table, modalities from a server that publishes
/// none) survive. Models the endpoint no longer serves go, since a picker
/// entry that 404s is worse than none. Keys OpenCode's schema doesn't
/// have, which it drops silently, are cleaned out so the file stops
/// promising things that never took effect.
public enum ModelCatalogSync {
    /// Keys earlier hand-written configs used for limits and visibility.
    /// OpenCode ignores every one of them; that silence is how a config
    /// full of context windows still ran every model at zero.
    public static let deadModelKeys: Set<String> = ["contextWindow", "maxOutputTokens", "force"]

    /// The output limit written when neither the endpoint nor the config
    /// knows one. OpenCode's schema requires both halves of `limit`.
    public static let fallbackOutputLimit = 4096

    public static func plan(
        source: ModelSource, discovered: [DiscoveredModel], existingProvider: [String: Any]?
    ) -> ModelSyncPlan {
        var block = existingProvider ?? [:]
        var providerChanges: [String] = []

        let npm = source.resolvedNPM
        if (block["npm"] as? String) != npm {
            providerChanges.append(
                block["npm"] == nil ? "package \(npm)" : "package \(block["npm"] as? String ?? "") → \(npm)"
            )
            block["npm"] = npm
        }
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, (block["name"] as? String) != name {
            providerChanges.append(
                block["name"] == nil ? "name \"\(name)\"" : "name \"\(block["name"] as? String ?? "")\" → \"\(name)\""
            )
            block["name"] = name
        } else if block["name"] == nil {
            block["name"] = source.providerID
        }

        var options = block["options"] as? [String: Any] ?? [:]
        let baseURL = source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if (options["baseURL"] as? String) != baseURL {
            providerChanges.append(
                options["baseURL"] == nil
                    ? "base URL \(baseURL)"
                    : "base URL \(options["baseURL"] as? String ?? "") → \(baseURL)"
            )
            options["baseURL"] = baseURL
        }
        if let key = source.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            if (options["apiKey"] as? String) != key {
                providerChanges.append(options["apiKey"] == nil ? "API key set" : "API key changed")
                options["apiKey"] = key
            }
        } else if options["apiKey"] == nil {
            // The OpenAI-compatible adapter wants a key even when the
            // server checks none; the placeholder every local setup uses.
            options["apiKey"] = "none"
        }
        block["options"] = options

        let existingModels = block["models"] as? [String: Any] ?? [:]
        var models: [String: Any] = [:]
        var added: [ModelSyncPlan.ModelChange] = []
        var changed: [ModelSyncPlan.ModelChange] = []
        var unchanged = 0
        for model in discovered {
            let old = existingModels[model.id] as? [String: Any]
            let new = merge(model, into: old)
            models[model.id] = new
            if let old {
                let details = differences(from: old, to: new)
                if details.isEmpty {
                    unchanged += 1
                } else {
                    changed.append(.init(modelID: model.id, details: details))
                }
            } else {
                added.append(.init(modelID: model.id, details: summary(of: new)))
            }
        }
        let discoveredIDs = Set(discovered.map(\.id))
        let removed = existingModels.keys.filter { !discoveredIDs.contains($0) }.sorted()
        block["models"] = models

        let before = existingProvider.flatMap { try? OpenCodeConfigFile.render($0) }
        let after = (try? OpenCodeConfigFile.render(block)) ?? "{}"
        return ModelSyncPlan(
            providerID: source.providerID,
            isNewProvider: existingProvider == nil,
            providerChanges: providerChanges,
            added: added.sorted { $0.modelID < $1.modelID },
            changed: changed.sorted { $0.modelID < $1.modelID },
            removed: removed,
            unchanged: unchanged,
            providerBlock: block,
            before: before,
            after: after
        )
    }

    /// Writes the plans' blocks into a config root. Everything else in the
    /// file is left exactly as it was parsed.
    public static func apply(_ plans: [ModelSyncPlan], to root: [String: Any]) -> [String: Any] {
        var root = root
        var providers = root["provider"] as? [String: Any] ?? [:]
        for plan in plans {
            providers[plan.providerID] = plan.providerBlock
        }
        root["provider"] = providers
        return root
    }

    // MARK: - One model

    static func merge(_ model: DiscoveredModel, into existing: [String: Any]?) -> [String: Any] {
        var out = existing ?? [:]
        for key in deadModelKeys { out.removeValue(forKey: key) }
        if let name = model.name, !name.isEmpty {
            out["name"] = name
        } else if out["name"] == nil {
            out["name"] = model.id
        }
        let oldLimit = existing?["limit"] as? [String: Any]
        if let context = model.contextLimit {
            let output = model.outputLimit
                ?? (oldLimit?["output"] as? Int).flatMap { $0 > 0 ? $0 : nil }
                ?? fallbackOutputLimit
            out["limit"] = ["context": context, "output": output]
        } else if let output = model.outputLimit, let context = oldLimit?["context"] as? Int, context > 0 {
            out["limit"] = ["context": context, "output": output]
        }
        if model.inputModalities != nil || model.outputModalities != nil {
            var modalities = out["modalities"] as? [String: Any] ?? [:]
            if let input = model.inputModalities { modalities["input"] = input }
            if let output = model.outputModalities { modalities["output"] = output }
            out["modalities"] = modalities
        }
        if let attachment = model.attachment { out["attachment"] = attachment }
        if let reasoning = model.reasoning { out["reasoning"] = reasoning }
        if let toolCall = model.toolCall { out["tool_call"] = toolCall }
        if let temperature = model.temperature { out["temperature"] = temperature }
        return out
    }

    /// The fields a reviewer cares about, as "key value" lines.
    static func summary(of model: [String: Any]) -> [String] {
        var lines: [String] = []
        if let limit = model["limit"] as? [String: Any] {
            lines.append("context \(number(limit["context"])), output \(number(limit["output"]))")
        } else {
            lines.append("no context limit")
        }
        if let modalities = model["modalities"] as? [String: Any],
           let input = modalities["input"] as? [String] {
            lines.append("input " + input.joined(separator: ", "))
        }
        var flags: [String] = []
        if model["tool_call"] as? Bool == false { flags.append("no tools") }
        if model["reasoning"] as? Bool == true { flags.append("reasoning") }
        if model["attachment"] as? Bool == true { flags.append("attachments") }
        if !flags.isEmpty { lines.append(flags.joined(separator: ", ")) }
        return lines
    }

    /// What changed between two versions of one model, as "key old → new"
    /// lines. Empty means the endpoint and the config already agree.
    static func differences(from old: [String: Any], to new: [String: Any]) -> [String] {
        var lines: [String] = []
        let oldLimit = old["limit"] as? [String: Any]
        let newLimit = new["limit"] as? [String: Any]
        if !equal(oldLimit, newLimit) {
            lines.append(
                "context \(number(oldLimit?["context"])) → \(number(newLimit?["context"])), "
                    + "output \(number(oldLimit?["output"])) → \(number(newLimit?["output"]))"
            )
        }
        let oldModalities = old["modalities"] as? [String: Any]
        let newModalities = new["modalities"] as? [String: Any]
        if !equal(oldModalities, newModalities) {
            let input = (newModalities?["input"] as? [String])?.joined(separator: ", ") ?? "unset"
            lines.append("input \(input)")
        }
        for key in ["name", "attachment", "reasoning", "tool_call", "temperature"] {
            if !equal(old[key], new[key]) {
                lines.append("\(key) \(describe(old[key])) → \(describe(new[key]))")
            }
        }
        for key in deadModelKeys where old[key] != nil {
            lines.append("\(key) removed (OpenCode never read it)")
        }
        // Anything else that moved: a curated key the merge doesn't know.
        let known: Set<String> = ["limit", "modalities", "name", "attachment", "reasoning", "tool_call", "temperature"]
        for key in Set(old.keys).union(new.keys).subtracting(known).subtracting(deadModelKeys).sorted()
        where !equal(old[key], new[key]) {
            lines.append("\(key) changed")
        }
        return lines
    }

    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?):
            guard let x = a as? NSObject, let y = b as? NSObject else { return false }
            return x.isEqual(y)
        default: return false
        }
    }

    private static func number(_ value: Any?) -> String {
        if let n = value as? Int { return String(n) }
        if let n = value as? Double { return String(Int(n)) }
        return "unset"
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case nil: return "unset"
        case let b as Bool: return b ? "yes" : "no"
        case let s as String: return "\"\(s)\""
        default: return number(value)
        }
    }
}

/// OpenCode's global config file, as the thing the Mac reads and rewrites.
public enum OpenCodeConfigFile {
    public enum FileError: LocalizedError {
        case notAnObject
        case invalidJSON(String)

        public var errorDescription: String? {
            switch self {
            case .notAnObject:
                return "opencode.json doesn't hold a JSON object."
            case let .invalidJSON(detail):
                return "opencode.json isn't plain JSON (\(detail)). Fix it by hand, or move comments to opencode.jsonc, before the Mac can update it."
            }
        }
    }

    /// Where OpenCode reads its global config: `$XDG_CONFIG_HOME/opencode`
    /// or `~/.config/opencode`. The `.json` file is the one this feature
    /// writes; a `.jsonc` beside it is loaded after and merged on top.
    public static func globalPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        let base: String
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = xdg
        } else {
            base = (home as NSString).appendingPathComponent(".config")
        }
        return ((base as NSString).appendingPathComponent("opencode") as NSString)
            .appendingPathComponent("opencode.json")
    }

    /// Sibling files OpenCode merges after the one we write, which could
    /// override a managed provider without this feature knowing.
    public static func shadowingFiles(for path: String, fileManager: FileManager = .default) -> [String] {
        let dir = (path as NSString).deletingLastPathComponent
        let jsonc = (dir as NSString).appendingPathComponent("opencode.jsonc")
        return fileManager.fileExists(atPath: jsonc) ? [jsonc] : []
    }

    /// The parsed root object; an absent file is an empty config, a file
    /// that isn't plain JSON is an error rather than something to clobber.
    public static func read(at path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FileError.invalidJSON((error as NSError).localizedDescription)
        }
        guard let root = object as? [String: Any] else { throw FileError.notAnObject }
        return root
    }

    /// Pretty JSON with keys in a stable order and slashes left alone, so
    /// a URL reads as a URL in the file.
    public static func render(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Replaces the file atomically, keeping the previous version beside it
    /// as `opencode.json.bak-remote`. The directory is created if this is
    /// the first config the machine has had.
    @discardableResult
    public static func write(_ root: [String: Any], to path: String) throws -> String? {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var backup: String?
        if fm.fileExists(atPath: path) {
            let target = path + ".bak-remote"
            if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
            try fm.copyItem(atPath: path, toPath: target)
            backup = target
        }
        let text = try render(root) + "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return backup
    }
}
