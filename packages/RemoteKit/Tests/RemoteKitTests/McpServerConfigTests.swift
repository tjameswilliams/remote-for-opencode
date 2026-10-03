import Foundation
import Testing

@testable import RemoteKit

/// The `mcp` block of opencode.json is the whole truth about which MCP
/// servers exist. Edits must write only keys OpenCode reads, keep what a
/// person wrote by hand, and leave the rest of the file alone.
@Suite("MCP server config")
struct McpServerConfigTests {
    @Test("a local and a remote block round-trip")
    func roundTrip() throws {
        let root: [String: Any] = [
            "mcp": [
                "github": ["type": "local", "command": ["npx", "-y", "gh-mcp"], "environment": ["TOKEN": "x"], "timeout": 30],
                "docs": ["type": "remote", "url": "https://docs.example/mcp", "headers": ["Authorization": "Bearer y"], "oauth": false, "enabled": false],
                "stub": ["enabled": false],
            ],
        ]
        let servers = McpConfigEdit.servers(in: root)
        #expect(servers.map(\.name) == ["docs", "github"])
        let github = try #require(servers.first { $0.name == "github" })
        #expect(github.isLocal)
        #expect(github.command == ["npx", "-y", "gh-mcp"])
        #expect(github.environment == ["TOKEN": "x"])
        #expect(github.timeout == 30)
        #expect(github.isEnabled)
        let docs = try #require(servers.first { $0.name == "docs" })
        #expect(!docs.isLocal)
        #expect(docs.url == "https://docs.example/mcp")
        #expect(docs.oauthDisabled == true)
        #expect(!docs.isEnabled)
        #expect(github.block() as NSDictionary == root["mcp"].flatMap { ($0 as? [String: Any])?["github"] } as? NSDictionary)
    }

    @Test("a type is inferred from command or url when the block omits it")
    func inferredType() {
        #expect(McpServerConfig(name: "a", block: ["command": ["x"]])?.type == "local")
        #expect(McpServerConfig(name: "b", block: ["url": "http://x"])?.type == "remote")
        #expect(McpServerConfig(name: "c", block: ["enabled": false]) == nil)
    }

    @Test("upsert keeps unknown keys and everything else in the file")
    func upsert() throws {
        let root: [String: Any] = [
            "model": "anthropic/claude-opus-5",
            "mcp": ["docs": ["type": "remote", "url": "https://old", "oauth": ["clientId": "abc"], "future": 1]],
        ]
        var edited = McpServerConfig(name: "docs", type: "remote", url: "https://new", timeout: 10)
        let updated = McpConfigEdit.upsert(edited, in: root)
        let block = try #require(McpConfigEdit.block(named: "docs", in: updated))
        #expect(block["url"] as? String == "https://new")
        #expect(block["timeout"] as? Int == 10)
        #expect((block["oauth"] as? [String: Any])?["clientId"] as? String == "abc")
        #expect(block["future"] as? Int == 1)
        #expect(updated["model"] as? String == "anthropic/claude-opus-5")

        // Turning it local sheds the remote-only keys.
        edited = McpServerConfig(name: "docs", type: "local", command: ["docs-mcp"])
        let local = try #require(McpConfigEdit.block(named: "docs", in: McpConfigEdit.upsert(edited, in: updated)))
        #expect(local["url"] == nil)
        #expect(local["oauth"] == nil)
        #expect(local["command"] as? [String] == ["docs-mcp"])
    }

    @Test("remove drops the server and an emptied block")
    func remove() {
        let root: [String: Any] = ["mcp": ["a": ["type": "local", "command": ["a"]]], "model": "m"]
        let removed = McpConfigEdit.remove("a", from: root)
        #expect(removed["mcp"] == nil)
        #expect(removed["model"] as? String == "m")
        #expect(McpConfigEdit.remove("zzz", from: root)["mcp"] != nil)
    }

    @Test("validation names the missing piece")
    func validation() {
        #expect(McpServerConfig(name: "", type: "local", command: ["x"]).validationProblem != nil)
        #expect(McpServerConfig(name: "my server", type: "local", command: ["x"]).validationProblem != nil)
        #expect(McpServerConfig(name: "a", type: "local").validationProblem != nil)
        #expect(McpServerConfig(name: "a", type: "remote", url: "ftp://x").validationProblem != nil)
        #expect(McpServerConfig(name: "a", type: "remote", url: "https://x/mcp").validationProblem == nil)
        #expect(McpServerConfig(name: "a", type: "local", command: ["x"], timeout: 0).validationProblem != nil)
        #expect(McpServerConfig(name: "a", type: "local", command: ["x"]).validationProblem == nil)
    }

    @Test("a config-level deny hides a server, and a string permission is widened to write one")
    func configDeny() {
        let object: [String: Any] = ["permission": ["remote_*": "deny", "bash": "ask"]]
        #expect(McpConfigEdit.isDeniedByConfig("remote", in: object))
        #expect(!McpConfigEdit.isDeniedByConfig("github", in: object))
        let widened = McpConfigEdit.denyByConfig("remote", in: ["permission": "allow"])
        let permission = widened["permission"] as? [String: Any]
        #expect(permission?["*"] as? String == "allow")
        #expect(permission?["remote_*"] as? String == "deny")
        #expect(McpConfigEdit.isDeniedByConfig("remote", in: McpConfigEdit.denyByConfig("remote", in: [:])))
    }

    @Test("names are sanitized the way OpenCode names tools")
    func sanitize() {
        #expect(McpConfigEdit.sanitized("my.server") == "my_server")
        #expect(McpConfigEdit.sanitized("ok-name_1") == "ok-name_1")
    }
}
