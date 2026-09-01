import RemoteKit
import SwiftUI

/// Which MCP servers' tools this conversation exposes to the model.
///
/// Per conversation on purpose, unlike the model and agent picks: MCP
/// servers are the user's own application integrations, and which ones
/// belong in a conversation is a property of that conversation: a Sentry
/// triage thread wants different tools than a schema migration. Keeping
/// unused ones off is also what keeps the context from being crowded by
/// dozens of tool definitions before the user has said a word.
///
/// The durable truth is the session's permission rules on the Mac, not
/// anything stored here: the full map rides on every prompt, the session
/// keeps it, and reopening the conversation, on any device, reads it
/// back. A fresh conversation starts with everything on, which is what
/// OpenCode would do anyway.
@MainActor
final class McpStore: ObservableObject {
    @Published private(set) var servers: [McpServer] = []
    @Published private(set) var loading = false
    /// Why the list is empty, when that's news rather than "none
    /// configured"; an older Mac companion answers "Unknown request".
    @Published private(set) var error: String?

    /// True once the user flips anything in this conversation, the other
    /// reason (besides loaded rules) a prompt would carry the map.
    private var touched = false
    private var loaded = false

    private let project: String
    private let session: String?
    private let makeLink: () -> CompanionLink

    init(
        project: String,
        session: String?,
        makeLink: @escaping () -> CompanionLink = { CompanionLink() }
    ) {
        self.project = project
        self.session = session
        self.makeLink = makeLink
    }

    /// Whether there is anything to offer; the composer hides the chip
    /// entirely for the many users with no MCP servers configured.
    var configured: Bool { !servers.isEmpty }

    var enabledCount: Int { servers.filter(\.enabled).count }

    /// What the chip says: quiet when everything is on, a fraction when
    /// the conversation is running filtered.
    var label: String {
        enabledCount == servers.count ? "Tools" : "Tools \(enabledCount)/\(servers.count)"
    }

    /// True when some servers are off; the chip tints to say the
    /// conversation isn't running with the full set.
    var filtered: Bool { enabledCount != servers.count }

    func toggle(_ server: McpServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].enabled.toggle()
        touched = true
    }

    func setAll(_ enabled: Bool) {
        for index in servers.indices { servers[index].enabled = enabled }
        touched = true
    }

    /// The map a prompt carries: every server, on or off. Nil when this
    /// conversation has nothing to say (never loaded, never touched, and
    /// nothing off), so a client that never opened the menu can't erase
    /// rules another client set. Complete on purpose: re-enabling a server
    /// must clear its rule, and only the full map can express that.
    var wireMap: [String: Bool]? {
        guard loaded, touched || servers.contains(where: { !$0.enabled }) else { return nil }
        return Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0.enabled) })
    }

    #if DEBUG
    /// A plausible roster for tools/uiharness, which has no Mac to ask.
    func mockForHarness() {
        servers = [
            McpServer(name: "github", status: "connected"),
            McpServer(name: "postgres", status: "connected", enabled: false),
            McpServer(name: "sentry", status: "connected"),
        ]
        loaded = true
    }
    #endif

    func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        await load()
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        var request = Wire.Request(kind: "mcp")
        request.project = project
        request.session = session
        for await event in makeLink().run(request) {
            if event.kind == "failed" { error = event.text }
            guard event.kind == "mcp" else { continue }
            servers = event.mcp ?? []
            loaded = true
        }
    }
}
