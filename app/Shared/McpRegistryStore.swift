import RemoteKit
import SwiftUI

/// The client's copy of the Mac's global MCP server list: what OpenCode's
/// config defines, each server's status, and whether new conversations
/// start with its tools on. The Mac owns all of it; every operation here
/// answers with the complete regenerated list, so this store only ever
/// replaces its copy with the Mac's truth.
///
/// Distinct from McpStore, which is one conversation's switches: this is
/// the roster and the defaults those switches start from.
@MainActor
final class McpRegistryStore: ObservableObject {
    @Published private(set) var servers: [McpServer] = []
    /// The Mac changed its opencode.json in a way OpenCode only reads at
    /// startup, and hasn't restarted it yet.
    @Published private(set) var restartNeeded = false
    /// Where the Mac keeps the file, for the page to say.
    @Published private(set) var configPath: String?
    @Published private(set) var loading = false
    /// Why the list is empty when that's news; an older Mac companion
    /// answers with its "older version" message.
    @Published private(set) var error: String?

    private var loaded = false
    private let makeLink: () -> CompanionLink

    init(makeLink: @escaping () -> CompanionLink = { CompanionLink() }) {
        self.makeLink = makeLink
    }

    /// Servers the clients can edit: defined in the Mac's global config
    /// and not the companion's own.
    func isEditable(_ server: McpServer) -> Bool {
        server.configured == true && server.builtin != true
    }

    func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        await load()
    }

    func load() async {
        await send(Wire.Request(kind: "mcp.list"))
    }

    /// Add or replace. True when the Mac took it, so an editor can close.
    @discardableResult
    func save(_ server: McpServerConfig) async -> Bool {
        var request = Wire.Request(kind: "mcp.save")
        request.server = server
        return await send(request)
    }

    func remove(_ name: String) async {
        var request = Wire.Request(kind: "mcp.remove")
        request.name = name
        await send(request)
    }

    /// Flip one server's default. Applied locally first so the switch
    /// answers the tap; the Mac's list replaces it a round trip later.
    func setDefault(_ name: String, enabled: Bool) async {
        if let index = servers.firstIndex(where: { $0.name == name }) {
            servers[index].defaultEnabled = enabled
            servers[index].enabled = enabled
        }
        var request = Wire.Request(kind: "mcp.defaults")
        request.mcp = [name: enabled]
        await send(request)
    }

    /// Restart the Mac's OpenCode so every project sees the edited
    /// config. The answer is empty (the server is coming back up); the
    /// list is re-read once it has had a moment.
    func restart() async {
        await send(Wire.Request(kind: "mcp.restart"))
        restartNeeded = false
        loading = true
        try? await Task.sleep(for: .seconds(4))
        await load()
    }

    @discardableResult
    private func send(_ request: Wire.Request) async -> Bool {
        loading = true
        error = nil
        defer { loading = false }
        var succeeded = false
        for await event in makeLink().run(request) {
            switch event.kind {
            case "mcp":
                servers = event.mcp ?? []
                restartNeeded = event.restartNeeded == true
                configPath = event.configPath
                loaded = true
                succeeded = true
            case "failed":
                error = event.text
            default:
                break
            }
        }
        return succeeded
    }

    #if DEBUG
    /// A plausible roster for tools/uiharness, which has no Mac to ask.
    func mockForHarness() {
        servers = [
            McpServer(name: "github", status: "connected", enabled: true, defaultEnabled: true,
                      type: "local", summary: "npx -y @modelcontextprotocol/server-github",
                      configured: true,
                      config: McpServerConfig(name: "github", type: "local",
                                              command: ["npx", "-y", "@modelcontextprotocol/server-github"],
                                              environment: ["GITHUB_TOKEN": "ghp_…"])),
            McpServer(name: "postgres", status: "connected", enabled: false, defaultEnabled: false,
                      type: "local", summary: "uvx mcp-server-postgres", configured: true),
            McpServer(name: "sentry", status: "failed", enabled: true, defaultEnabled: true,
                      type: "remote", summary: "https://mcp.sentry.dev/mcp", configured: true,
                      error: "401 Unauthorized"),
            McpServer(name: "remote", status: "connected", enabled: false, defaultEnabled: false,
                      type: "remote", summary: "http://127.0.0.1:8767/mcp", configured: true,
                      builtin: true),
        ]
        configPath = "/Users/t/.config/opencode/opencode.json"
        loaded = true
    }
    #endif
}
