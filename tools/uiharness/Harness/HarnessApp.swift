import RemoteKit
import SwiftUI

// Renders the app's REAL views against representative content, for design
// iteration and for App Store screenshots. Nothing here reimplements a
// view — every screen below is the code the app ships, so what you see is
// what users get.
//
// Pick a scene at launch:
//   xcrun simctl launch <device> com.timwilliams.harness.ui -scene 2

@main
struct HarnessApp: App {
    var body: some Scene {
        WindowGroup { HarnessView() }
    }
}

struct HarnessView: View {
    @StateObject private var models = ModelStore.shared
    @StateObject private var agents = AgentStore.shared
    @StateObject private var mcp = McpStore(project: "/tmp/harness", session: nil)
    @StateObject private var schedules = ScheduleStore()
    @StateObject private var mcpServers = McpRegistryStore()
    @StateObject private var attachments = PromptAttachments()
    @StateObject private var dictation = Dictation()
    @State private var input = ""
    @State private var draft = ""
    @StateObject private var files = FileBrowser(project: "/Users/t/app", makeLink: { CompanionLink() })

    private var scene: Int { UserDefaults.standard.integer(forKey: "scene") }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { BrandWordmark(height: 15) }
                    if scene != 3 {
                        ToolbarItem(placement: .topBarTrailing) {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(Color.ink)
                        }
                    }
                }
        }
        .task {
            models.mockForHarness()
            agents.mockForHarness(plan: scene == 4)
            mcp.mockForHarness()
            schedules.mockForHarness()
            mcpServers.mockForHarness()
            files.mockForHarness(["": [
                .init(path: ".github", name: ".github", directory: true),
                .init(path: "Sources", name: "Sources", directory: true, status: "modified"),
                .init(path: "Tests", name: "Tests", directory: true),
                .init(path: "node_modules", name: "node_modules", directory: true, ignored: true),
                .init(path: "Package.swift", name: "Package.swift", directory: false, size: 1204),
                .init(path: "README.md", name: "README.md", directory: false, size: 4310, status: "modified"),
                .init(path: "docs.pdf", name: "docs.pdf", directory: false, size: 482_000),
                .init(path: "NOTES.md", name: "NOTES.md", directory: false, size: 210, status: "untracked"),
            ]])
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scene {
        case 2: permission
        case 3: patch
        case 4: planning
        case 5: scheduled
        case 6: mcpServersScene
        case 7: FolderScreen(browser: files, folder: "")
        case 8: FileViewer(content: .init(path: "Sources/Auth/TokenStore.swift", size: 1840, text: Content.swiftFile))
                    .navigationTitle("TokenStore.swift")
        case 9: FileViewer(content: .init(path: "README.md", size: 1200, text: Content.readme))
                    .navigationTitle("README.md")
        case 10: FileViewer(content: .init(path: "Sources/Auth/TokenStore.swift", size: 1840, text: Content.swiftFile), line: 14)
                    .navigationTitle("TokenStore.swift")
        case 11: FileViewer(content: .init(path: "Sources/Auth/TokenStore.swift", size: 1840, text: Content.swiftFile), draft: $draft)
                    .navigationTitle("TokenStore.swift")
                    .onAppear { draft = Content.swiftFile }
        default: working
        }
    }

    private var working: some View {
        VStack(spacing: 0) {
            Transcript(
                rows: [
                    .init(type: "user", text: "The token refresh races when two requests 401 at once. Fix it."),
                    .init(type: "reasoning", id: "r", text: Content.reasoning),
                    .init(type: "tool", id: "t1", tool: "read", status: "completed", file: "/Users/t/app/Sources/Auth/TokenStore.swift"),
                    .init(
                        type: "tool", id: "s1", tool: "subagent", status: "completed",
                        subagent: .init(
                            session: "ses_child1", agent: "explore",
                            description: "Find every caller of refreshToken"
                        )
                    ),
                    .init(type: "tool", id: "t2", tool: "edit", status: "completed"),
                    .init(
                        type: "tool", id: "s2", tool: "subagent", status: "completed",
                        subagent: .init(
                            session: "ses_child2", agent: "general",
                            description: "Run the auth test suite and report failures",
                            background: true
                        )
                    ),
                    .init(type: "text", id: "x", text: Content.answer),
                ],
                diffs: [.init(file: "Sources/Auth/TokenStore.swift", additions: 18, deletions: 6, status: "modified")],
                error: nil, running: true, activity: "Running the test suite",
                turnStartedAt: Date().addingTimeInterval(-14),
                todos: Content.todos,
                usage: .init(
                    input: 31_400, output: 2_800, cacheRead: 9_100,
                    cost: 0.34, contextLimit: 200_000
                ),
                project: "/Users/t/app"
            )
            .environment(\.openFile, OpenFileAction { _, _ in })
            .environment(\.fileLinks, FileLinks(root: "/Users/t/app", paths: ["Sources/Auth/TokenStore.swift"]))
            composer
        }
    }

    private var scheduled: some View {
        ScheduleListView(
            store: schedules, models: models,
            projects: [
                Project(id: "p1", worktree: "/Users/t/app", name: "app"),
                Project(id: "p2", worktree: "/Users/t/site", name: "site"),
            ]
        ) { _ in }
    }

    private var mcpServersScene: some View {
        McpServersView(store: mcpServers)
    }

    private var permission: some View {
        ZStack {
            working
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack {
                Spacer()
                PermissionSheet(request: .init(
                    id: "p", permission: "bash",
                    patterns: ["rm -rf ./build && npm publish --access public"],
                    always: ["rm *"], risk: "high"
                ).with(session: "ses_child2"), conversation: "ses_parent") { _ in }
                .frame(height: 540)
                .background(Color.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var patch: some View {
        PatchView(diff: .init(
            file: "Sources/Auth/TokenStore.swift", patch: Content.patch,
            additions: 18, deletions: 6, status: "modified"
        ))
    }

    private var planning: some View {
        VStack(spacing: 0) {
            Transcript(
                rows: [
                    .init(type: "user", text: "How would you restructure the sync layer? Don't change anything yet."),
                    .init(type: "reasoning", id: "r2", text: Content.planReasoning),
                    .init(type: "text", id: "x2", text: Content.plan),
                ],
                diffs: [], error: nil, running: false, activity: "",
                turnStartedAt: Date(), todos: []
            )
            composer
        }
    }

    private var composer: some View {
        Composer(
            input: $input, running: scene == 0 || scene == 1,
            dictation: dictation, attachments: attachments,
            models: models, agents: agents, mcp: mcp,
            onDictate: {}, onSend: {}
        )
    }
}

private enum Content {
    static let swiftFile = """
    import Foundation

    /// Hands out access tokens, refreshing at most once at a time.
    actor TokenStore {
        private var token: Token?
        private var refreshing: Task<Token, Error>?
        private let client: AuthClient

        init(client: AuthClient) {
            self.client = client
        }

        func current() async throws -> Token {
            if let token, !token.isExpired { return token }
            // Two callers that 401 together share one refresh.
            if let refreshing { return try await refreshing.value }
            let task = Task { try await client.refresh() }
            refreshing = task
            defer { refreshing = nil }
            let fresh = try await task.value
            token = fresh
            return fresh
        }
    }
    """

    static let readme = """
    # TokenStore

    A small actor that hands out **access tokens** and refreshes them *once*, however many requests fail together.

    ## Usage

    ```swift
    let store = TokenStore(client: client)
    let token = try await store.current()
    ```

    - Concurrent callers share one refresh
    - Expired tokens are never returned
    - Errors propagate to every waiter

    | Case | Refreshes |
    | --- | --- |
    | One 401 | 1 |
    | Ten 401s at once | 1 |
    """

    static let reasoning = """
    Two concurrent 401s both call refresh(), so the second overwrites the \
    first's token and one request ends up holding a token that was already \
    replaced. The fix is to make refresh idempotent for the duration of a \
    single refresh — one in-flight task everyone awaits.
    """

    static let answer = """
    Found it. `refresh()` in `TokenStore.swift` had no guard against \
    concurrent callers (Sources/Auth/TokenStore.swift:14), so two \
    401s produced two refreshes and the loser kept a stale token.

    ```swift
    actor TokenStore {
        private var inFlight: Task<Token, Error>?

        func token() async throws -> Token {
            if let inFlight { return try await inFlight.value }
            let task = Task { try await api.refresh(current) }
            inFlight = task
            defer { inFlight = nil }
            return try await task.value
        }
    }
    ```

    Everyone now awaits the same task, so exactly one refresh happens.
    """

    static let planReasoning = """
    Before proposing anything I should be clear about what the sync layer \
    actually owns today: cursor bookkeeping, conflict resolution and the \
    retry policy all live in one type.
    """

    static let plan = """
    Three changes, in the order I'd make them:

    1. **Split `SyncEngine`.** Cursor bookkeeping and conflict resolution are unrelated responsibilities sharing one 600-line file.

    2. **Make retries a policy object.** The backoff is inlined in four places with three different sets of constants.

    3. **Then** move the cursor store behind a protocol, once there is something small enough to test.

    I haven't changed anything — say the word and I'll start with (1).
    """

    static let todos: [TodoItem] = [
        .init(id: "1", content: "Reproduce the race in a test", status: "completed"),
        .init(id: "2", content: "Serialise refresh through one task", status: "completed"),
        .init(id: "3", content: "Run the test suite", status: "in_progress"),
        .init(id: "4", content: "Check the retry path still backs off", status: "pending"),
    ]

    static let patch = """
    diff --git a/Sources/Auth/TokenStore.swift b/Sources/Auth/TokenStore.swift
    index 8f2a1c4..d91b7e0 100644
    --- a/Sources/Auth/TokenStore.swift
    +++ b/Sources/Auth/TokenStore.swift
    @@ -12,18 +12,30 @@ actor TokenStore {
         private var current: Token?
    -    private var refreshing = false
    +    private var inFlight: Task<Token, Error>?

    -    func token() async throws -> Token {
    -        if let current, !current.isExpired { return current }
    -        refreshing = true
    -        let fresh = try await api.refresh(current)
    -        current = fresh
    -        refreshing = false
    -        return fresh
    +    /// Concurrent callers share one refresh. Two requests hitting 401
    +    /// together used to trigger two refreshes, and the loser kept a
    +    /// token the server had already rotated away.
    +    func token() async throws -> Token {
    +        if let current, !current.isExpired { return current }
    +        if let inFlight { return try await inFlight.value }
    +
    +        let task = Task { try await api.refresh(current) }
    +        inFlight = task
    +        defer { inFlight = nil }
    +
    +        let fresh = try await task.value
    +        current = fresh
    +        return fresh
         }
     }
    """
}

private extension PermissionRequest {
    func with(session: String) -> PermissionRequest {
        var copy = self
        copy.sessionID = session
        return copy
    }
}
