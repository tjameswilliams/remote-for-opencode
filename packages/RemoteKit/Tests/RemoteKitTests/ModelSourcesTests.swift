import Foundation
import Testing

@testable import RemoteKit

/// The config OpenCode reads is the only place a custom model's context
/// window exists, and it drops unknown keys without a word. The parser has
/// to find limits wherever a server puts them, the merge has to write the
/// keys OpenCode actually reads while keeping what a person curated, and
/// the plan has to describe every change honestly, because a person
/// approves it before the file moves.
@Suite("Model sources")
struct ModelSourcesTests {
    // MARK: - Listing parser

    @Test("OpenCode-shaped limit and modalities are read verbatim")
    func parseOpenCodeShape() throws {
        let json = """
        {"object":"list","data":[{"id":"GLM-5.3-Flash","object":"model","owned_by":"local",
          "limit":{"context":65536,"output":16384},
          "modalities":{"input":["text","image"],"output":["text"]},
          "attachment":true,"reasoning":false,"tool_call":true,"temperature":true}]}
        """
        let models = try ModelListing.parse(Data(json.utf8))
        #expect(models.count == 1)
        let m = try #require(models.first)
        #expect(m.id == "GLM-5.3-Flash")
        #expect(m.contextLimit == 65536)
        #expect(m.outputLimit == 16384)
        #expect(m.inputModalities == ["text", "image"])
        #expect(m.outputModalities == ["text"])
        #expect(m.attachment == true)
        #expect(m.reasoning == false)
        #expect(m.toolCall == true)
        #expect(m.temperature == true)
    }

    @Test("vLLM's max_model_len and an architecture block are fallbacks")
    func parseVLLMShape() throws {
        let json = """
        {"data":[{"id":"qwen","max_model_len":32768,
          "architecture":{"input_modalities":["text","image","weird"],"output_modalities":["text"]}}]}
        """
        let m = try #require(try ModelListing.parse(Data(json.utf8)).first)
        #expect(m.contextLimit == 32768)
        #expect(m.outputLimit == nil)
        #expect(m.inputModalities == ["text", "image"], "unknown modality words are dropped")
        #expect(m.attachment == true, "image input implies attachments")
        #expect(m.toolCall == nil, "absent flags stay absent")
    }

    @Test("A bare listing leaves every optional field unset")
    func parseBare() throws {
        let m = try #require(try ModelListing.parse(Data(#"{"data":[{"id":"m","object":"model"}]}"#.utf8)).first)
        #expect(m.contextLimit == nil)
        #expect(m.inputModalities == nil)
        #expect(m.attachment == nil)
    }

    @Test("Zero and missing ids are not models; non-JSON and shapeless answers are errors")
    func parseRejects() throws {
        let models = try ModelListing.parse(Data(#"{"data":[{"id":"","limit":{"context":0,"output":0}},{"id":"ok","limit":{"context":0,"output":0}}]}"#.utf8))
        #expect(models.map(\.id) == ["ok"])
        #expect(models.first?.contextLimit == nil, "a zero limit is no limit")
        #expect(throws: ModelListing.ListingError.notJSON) { try ModelListing.parse(Data("nope".utf8)) }
        #expect(throws: ModelListing.ListingError.noModels) { try ModelListing.parse(Data(#"{"status":"ok"}"#.utf8)) }
    }

    // MARK: - Source validation

    @Test("The models URL is the base plus /models, trailing slash or not")
    func modelsURL() {
        let a = ModelSource(providerID: "vllm", name: "vLLM", baseURL: "http://host:8100/v1")
        let b = ModelSource(providerID: "vllm", name: "vLLM", baseURL: "http://host:8100/v1/")
        #expect(a.modelsURL?.absoluteString == "http://host:8100/v1/models")
        #expect(b.modelsURL?.absoluteString == "http://host:8100/v1/models")
        #expect(a.validationProblem == nil)
    }

    @Test("A provider id with a slash or a non-HTTP base can't be saved")
    func validation() {
        #expect(ModelSource(providerID: "a/b", name: "", baseURL: "http://x/v1").validationProblem != nil)
        #expect(ModelSource(providerID: "", name: "", baseURL: "http://x/v1").validationProblem != nil)
        #expect(ModelSource(providerID: "ok", name: "", baseURL: "ftp://x/v1").validationProblem != nil)
        #expect(ModelSource(providerID: "ok", name: "", baseURL: "host:8100").validationProblem != nil)
    }

    // MARK: - Merge and plan

    private let source = ModelSource(
        providerID: "vllm", name: "vLLM (home)", baseURL: "http://100.1.1.1:8100/v1"
    )

    /// The shape the hand-written config had: keys OpenCode never read,
    /// plus modalities someone added by hand.
    private let legacyProvider: [String: Any] = [
        "npm": "@ai-sdk/openai-compatible",
        "name": "vLLM (home)",
        "options": ["baseURL": "http://100.1.1.1:8100/v1", "apiKey": "none"],
        "models": [
            "GPT-OSS-120B": [
                "name": "GPT-OSS 120B (MXFP4)", "contextWindow": 131072, "maxOutputTokens": 4096, "force": true,
            ],
            "Qwen2.5-VL": [
                "name": "Qwen VL", "contextWindow": 65536, "maxOutputTokens": 4096, "force": true,
                "attachment": true, "modalities": ["input": ["text", "image"], "output": ["text"]],
            ],
            "Gone-Model": ["name": "Gone", "contextWindow": 4096, "maxOutputTokens": 1024, "force": true],
        ],
    ]

    @Test("Discovered limits replace dead keys; curated names and modalities survive; vanished models go")
    func planAgainstLegacyConfig() throws {
        let discovered = [
            DiscoveredModel(id: "GPT-OSS-120B", contextLimit: 131072, outputLimit: 32768, inputModalities: ["text"], outputModalities: ["text"], toolCall: true),
            DiscoveredModel(id: "Qwen2.5-VL", contextLimit: 65536, outputLimit: 16384),
            DiscoveredModel(id: "New-Model", contextLimit: 262144, outputLimit: 32768, inputModalities: ["text", "image"], attachment: true, reasoning: true),
        ]
        let plan = ModelCatalogSync.plan(source: source, discovered: discovered, existingProvider: legacyProvider)

        #expect(!plan.isNewProvider)
        #expect(plan.providerChanges.isEmpty, "same package, name, URL, and key: nothing at provider level")
        #expect(plan.added.map(\.modelID) == ["New-Model"])
        #expect(plan.changed.map(\.modelID) == ["GPT-OSS-120B", "Qwen2.5-VL"])
        #expect(plan.removed == ["Gone-Model"])
        #expect(plan.unchanged == 0)
        #expect(plan.modelCount == 3)
        #expect(!plan.isEmpty)

        let models = try #require(plan.providerBlock["models"] as? [String: Any])
        let gpt = try #require(models["GPT-OSS-120B"] as? [String: Any])
        #expect(gpt["name"] as? String == "GPT-OSS 120B (MXFP4)", "the curated display name is kept")
        #expect((gpt["limit"] as? [String: Int]) == ["context": 131072, "output": 32768])
        #expect(gpt["tool_call"] as? Bool == true)
        for dead in ModelCatalogSync.deadModelKeys {
            #expect(gpt[dead] == nil, "\(dead) is gone")
        }
        let qwen = try #require(models["Qwen2.5-VL"] as? [String: Any])
        #expect((qwen["modalities"] as? [String: [String]])?["input"] == ["text", "image"], "hand-written modalities survive a listing that has none")
        #expect(qwen["attachment"] as? Bool == true)
        #expect(models["Gone-Model"] == nil)
        let new = try #require(models["New-Model"] as? [String: Any])
        #expect(new["name"] as? String == "New-Model", "a model with no name is named after its id")
        #expect(new["reasoning"] as? Bool == true)

        // The change lines say what moved, in words a reviewer can check.
        let gptChange = try #require(plan.changed.first { $0.modelID == "GPT-OSS-120B" })
        #expect(gptChange.details.contains { $0.hasPrefix("context unset → 131072") })
        #expect(gptChange.details.contains { $0.hasPrefix("contextWindow removed") })
        #expect(gptChange.details.contains { $0.hasPrefix("force removed") })
    }

    @Test("Checking again after applying is a no-op plan")
    func idempotent() {
        let discovered = [
            DiscoveredModel(id: "A", contextLimit: 1000, outputLimit: 100, inputModalities: ["text"], outputModalities: ["text"], attachment: false, reasoning: true, toolCall: true, temperature: true),
        ]
        let first = ModelCatalogSync.plan(source: source, discovered: discovered, existingProvider: nil)
        #expect(first.isNewProvider)
        #expect(first.added.map(\.modelID) == ["A"])
        #expect(first.providerChanges.contains { $0.hasPrefix("base URL") })
        let second = ModelCatalogSync.plan(source: source, discovered: discovered, existingProvider: first.providerBlock)
        #expect(second.isEmpty, "\(second.providerChanges) \(second.changed)")
        #expect(second.unchanged == 1)
    }

    @Test("A context without an output limit gets the curated output, else the fallback")
    func outputFallback() throws {
        let curated: [String: Any] = ["models": ["A": ["limit": ["context": 10, "output": 2048]]]]
        let plan = ModelCatalogSync.plan(
            source: source, discovered: [DiscoveredModel(id: "A", contextLimit: 5000), DiscoveredModel(id: "B", contextLimit: 7000)],
            existingProvider: curated
        )
        let models = try #require(plan.providerBlock["models"] as? [String: Any])
        #expect(((models["A"] as? [String: Any])?["limit"] as? [String: Int]) == ["context": 5000, "output": 2048])
        #expect(((models["B"] as? [String: Any])?["limit"] as? [String: Int]) == ["context": 7000, "output": ModelCatalogSync.fallbackOutputLimit])
    }

    @Test("An endpoint that publishes nothing but ids leaves curated limits alone")
    func bareListingKeepsCuratedLimits() throws {
        let curated: [String: Any] = ["models": ["A": ["name": "Curated A", "limit": ["context": 10, "output": 2]]]]
        let plan = ModelCatalogSync.plan(source: source, discovered: [DiscoveredModel(id: "A")], existingProvider: curated)
        let a = try #require((plan.providerBlock["models"] as? [String: Any])?["A"] as? [String: Any])
        #expect((a["limit"] as? [String: Int]) == ["context": 10, "output": 2])
        #expect(a["name"] as? String == "Curated A")
        #expect(plan.changed.isEmpty)
    }

    @Test("Provider-level edits are listed: URL, key, package")
    func providerChanges() {
        var edited = source
        edited.baseURL = "http://other:9/v1"
        edited.apiKey = "sk-1"
        edited.npm = "@ai-sdk/openai"
        let plan = ModelCatalogSync.plan(source: edited, discovered: [], existingProvider: legacyProvider)
        #expect(plan.providerChanges.count == 3)
        #expect(plan.providerChanges.contains("API key set") == false, "the config had a placeholder key, so this is a change")
        #expect(plan.providerChanges.contains("API key changed"))
        #expect((plan.providerBlock["options"] as? [String: Any])?["apiKey"] as? String == "sk-1")
        #expect(plan.removed.count == 3, "an empty listing removes every model; the review shows it before anything is written")
    }

    @Test("Applying touches only the planned provider; siblings and the rest of the file are untouched")
    func applyToRoot() throws {
        let root: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "lsp": ["html": ["command": ["x"]]],
            "provider": ["anthropic": ["options": ["apiKey": "k"]], "vllm": legacyProvider],
        ]
        let plan = ModelCatalogSync.plan(source: source, discovered: [DiscoveredModel(id: "Only", contextLimit: 1, outputLimit: 1)], existingProvider: legacyProvider)
        let out = ModelCatalogSync.apply([plan], to: root)
        #expect(out["$schema"] as? String == "https://opencode.ai/config.json")
        #expect((out["lsp"] as? [String: Any]) != nil)
        let providers = try #require(out["provider"] as? [String: Any])
        #expect((providers["anthropic"] as? [String: Any]) != nil)
        #expect(((providers["vllm"] as? [String: Any])?["models"] as? [String: Any])?.keys.sorted() == ["Only"])
    }

    // MARK: - The file

    @Test("The global path honors XDG_CONFIG_HOME and falls back to ~/.config")
    func globalPath() {
        #expect(OpenCodeConfigFile.globalPath(environment: [:], home: "/Users/t") == "/Users/t/.config/opencode/opencode.json")
        #expect(OpenCodeConfigFile.globalPath(environment: ["XDG_CONFIG_HOME": "/x"], home: "/Users/t") == "/x/opencode/opencode.json")
        #expect(OpenCodeConfigFile.globalPath(environment: ["XDG_CONFIG_HOME": ""], home: "/Users/t") == "/Users/t/.config/opencode/opencode.json")
    }

    @Test("Rendering keeps URLs readable and keys stable")
    func render() throws {
        let text = try OpenCodeConfigFile.render(["b": 1, "a": ["baseURL": "http://h/v1"]])
        #expect(text.contains("http://h/v1"), "no escaped slashes")
        #expect(text.range(of: "\"a\"")!.lowerBound < text.range(of: "\"b\"")!.lowerBound)
    }

    @Test("A commented config is refused rather than rewritten; a missing one reads as empty")
    func readGuards() throws {
        #expect(throws: (any Error).self) { try OpenCodeConfigFile.parse(Data("// hi\n{}".utf8)) }
        #expect(throws: (any Error).self) { try OpenCodeConfigFile.parse(Data("[]".utf8)) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = dir.appendingPathComponent("opencode.json").path
        #expect(try OpenCodeConfigFile.read(at: path).isEmpty)

        // Write, then write again: the backup holds the previous version.
        #expect(try OpenCodeConfigFile.write(["v": 1], to: path) == nil, "nothing to back up the first time")
        let backup = try OpenCodeConfigFile.write(["v": 2], to: path)
        #expect(backup == path + ".bak-remote")
        #expect(try OpenCodeConfigFile.read(at: path)["v"] as? Int == 2)
        #expect(try OpenCodeConfigFile.read(at: backup!)["v"] as? Int == 1)
        try? FileManager.default.removeItem(at: dir)
    }
}
