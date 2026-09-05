import Foundation

/// An OpenAI-style model endpoint the Mac keeps OpenCode's config in step
/// with: a local vLLM, llama.cpp, LM Studio, or a proxy in front of
/// several. OpenCode has no discovery of its own for these providers; it
/// only knows what the `provider` block in its config says, and a model
/// missing there, or present without limits, runs with no context window,
/// which switches off automatic compaction and the context meter.
///
/// The Mac owns the list. Checking a source never touches the config;
/// changes are planned, shown, and applied only once the user says so.
public struct ModelSource: Codable, Hashable, Identifiable, Sendable {
    /// Client-minted UUID string; saving an existing id replaces the source.
    public var id: String
    /// The key under `provider` in opencode.json ("vllm"). Also the first
    /// half of every model id the rest of the app sees ("vllm/GPT-OSS-120B").
    public var providerID: String
    /// The provider's display name in model pickers.
    public var name: String
    /// The OpenAI-compatible base, including `/v1`; `/models` is appended
    /// for discovery and OpenCode uses it verbatim for completions.
    public var baseURL: String
    /// Sent as a bearer token on discovery and written to the provider's
    /// options. It lives in opencode.json in plain text either way, which
    /// is why this is not a Keychain item.
    public var apiKey: String?
    /// The AI SDK package OpenCode loads for this provider. Absent means
    /// the OpenAI-compatible adapter.
    public var npm: String?
    /// Absent reads as true.
    public var enabled: Bool?
    public var created: Date?

    // Discovery history, written only by the Mac.
    public var lastChecked: Date?
    public var lastError: String?
    public var lastModelCount: Int?

    public static let defaultNPM = "@ai-sdk/openai-compatible"

    public var isEnabled: Bool { enabled ?? true }
    public var resolvedNPM: String { npm?.isEmpty == false ? npm! : Self.defaultNPM }

    public init(
        id: String = UUID().uuidString, providerID: String, name: String, baseURL: String,
        apiKey: String? = nil, npm: String? = nil, enabled: Bool? = nil, created: Date? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.npm = npm
        self.enabled = enabled
        self.created = created
    }

    /// The listing endpoint: base URL plus `/models`, whatever the base's
    /// trailing slash situation.
    public var modelsURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: base + "/models")
    }

    /// Why this source can't be saved, or nil when it can.
    public var validationProblem: String? {
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.isEmpty { return "The provider id is empty." }
        if provider.contains("/") || provider.contains(where: \.isWhitespace) {
            return "The provider id can't contain slashes or spaces."
        }
        guard let url = modelsURL, let scheme = url.scheme?.lowercased(), url.host != nil,
              scheme == "http" || scheme == "https"
        else { return "The base URL must start with http:// or https://." }
        return nil
    }
}

/// One model as an endpoint describes it. Only what the endpoint actually
/// said is set; absent fields leave whatever the config already has.
public struct DiscoveredModel: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var contextLimit: Int?
    public var outputLimit: Int?
    public var inputModalities: [String]?
    public var outputModalities: [String]?
    public var attachment: Bool?
    public var reasoning: Bool?
    public var toolCall: Bool?
    public var temperature: Bool?

    public init(
        id: String, name: String? = nil, contextLimit: Int? = nil, outputLimit: Int? = nil,
        inputModalities: [String]? = nil, outputModalities: [String]? = nil,
        attachment: Bool? = nil, reasoning: Bool? = nil, toolCall: Bool? = nil,
        temperature: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.contextLimit = contextLimit
        self.outputLimit = outputLimit
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.attachment = attachment
        self.reasoning = reasoning
        self.toolCall = toolCall
        self.temperature = temperature
    }
}

/// Reads an OpenAI-style `/v1/models` answer, taking limits and
/// capabilities from wherever a server puts them: OpenCode's own `limit`
/// and `modalities` shapes first, then vLLM's `max_model_len` and the
/// OpenRouter-style `architecture` block.
public enum ModelListing {
    public enum ListingError: LocalizedError, Equatable {
        case notJSON
        case noModels

        public var errorDescription: String? {
            switch self {
            case .notJSON: return "The endpoint didn't answer with JSON."
            case .noModels: return "The endpoint's answer has no model list."
            }
        }
    }

    /// The modality words OpenCode's schema accepts; anything else an
    /// endpoint invents is dropped rather than failing the whole config.
    static let modalities: Set<String> = ["text", "audio", "image", "video", "pdf"]

    public static func parse(_ data: Data) throws -> [DiscoveredModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ListingError.notJSON
        }
        let entries: [[String: Any]]
        if let object = json as? [String: Any], let list = object["data"] as? [[String: Any]] {
            entries = list
        } else if let list = json as? [[String: Any]] {
            entries = list
        } else {
            throw ListingError.noModels
        }
        return entries.compactMap(parse(entry:))
    }

    static func parse(entry: [String: Any]) -> DiscoveredModel? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        var model = DiscoveredModel(id: id)
        model.name = entry["name"] as? String
        if let limit = entry["limit"] as? [String: Any] {
            model.contextLimit = integer(limit["context"])
            model.outputLimit = integer(limit["output"])
        }
        model.contextLimit = model.contextLimit
            ?? integer(entry["max_model_len"])
            ?? integer(entry["context_length"])
            ?? integer(entry["max_context_length"])
        model.outputLimit = model.outputLimit ?? integer(entry["max_output_tokens"])

        let architecture = entry["architecture"] as? [String: Any]
        if let declared = entry["modalities"] as? [String: Any] {
            model.inputModalities = modalityList(declared["input"])
            model.outputModalities = modalityList(declared["output"])
        }
        model.inputModalities = model.inputModalities ?? modalityList(architecture?["input_modalities"])
        model.outputModalities = model.outputModalities ?? modalityList(architecture?["output_modalities"])

        model.attachment = entry["attachment"] as? Bool
        // A model that takes images can take an attachment; saying so when
        // the endpoint only described the modality keeps the attach button
        // and the image parts in agreement.
        if model.attachment == nil, model.inputModalities?.contains("image") == true {
            model.attachment = true
        }
        model.reasoning = entry["reasoning"] as? Bool
        model.toolCall = entry["tool_call"] as? Bool
        model.temperature = entry["temperature"] as? Bool
        return model
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n > 0 ? n : nil
        case let n as Double: return n > 0 ? Int(n) : nil
        case let n as NSNumber: return n.intValue > 0 ? n.intValue : nil
        default: return nil
        }
    }

    private static func modalityList(_ value: Any?) -> [String]? {
        guard let list = value as? [String] else { return nil }
        let kept = list.map { $0.lowercased() }.filter { modalities.contains($0) }
        return kept.isEmpty ? nil : kept
    }
}
