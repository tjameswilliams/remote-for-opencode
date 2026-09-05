import RemoteKit
import SwiftUI

/// The desktop workspace: sidebar of Macs, sessions, and projects on the
/// left; the conversation in the middle; the inspector (changes, plan,
/// approvals) on the right. Everything in this window reaches the
/// companion through `WorkspaceState.makeLink` — this Mac's own server
/// over loopback in v1, a chosen peer once multi-Mac pairing lands.
struct WorkspaceWindow: View {
    @StateObject private var state = WorkspaceState()
    @ObservedObject private var modelSources = ModelSourceStore.shared

    /// Enough of the selection to survive a relaunch: "session:<id>" or
    /// "project:<worktree>", re-matched against the loaded lists.
    @SceneStorage("workspace.selection") private var storedSelection = ""
    @SceneStorage("workspace.inspector.shown") private var storedInspectorShown = true
    @SceneStorage("workspace.inspector.tab") private var storedInspectorTab = InspectorTab.changes.rawValue

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(state: state)
        } detail: {
            detail
        }
        .background(Color.canvas)
        .background(WindowAccessor { ActivationPolicy.shared.windowOpened($0) })
        .toolbar {
            ToolbarItem {
                Button {
                    state.selection = .schedules
                } label: {
                    Label("Scheduled Tasks", systemImage: "clock.badge")
                }
                .help("Scheduled tasks on this Mac")
            }
        }
        .overlay {
            if state.paletteShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                        .onTapGesture { state.paletteShown = false }
                    CommandKPalette(
                        state: state,
                        insertCommand: { state.pendingCommand = $0 },
                        dismiss: { state.paletteShown = false }
                    )
                    .padding(.top, 80)
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.easeOut(Motion.feedback), value: state.paletteShown)
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.palette)) { _ in
            state.paletteShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.newSession)) { _ in
            // A fresh conversation where you are, or in the first project
            // when you're nowhere yet.
            switch state.selection {
            case let .session(session):
                if let project = state.projects.first(where: { $0.worktree == session.directory }) {
                    state.selection = .project(project)
                } else if let first = state.projects.first {
                    state.selection = .project(first)
                }
            case .project:
                break   // already an empty conversation in that project
            case .schedules, .modelSources, nil:
                if let first = state.projects.first { state.selection = .project(first) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.toggleInspector)) { _ in
            state.inspectorShown.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.inspectorTab)) { note in
            guard let raw = note.userInfo?["tab"] as? String,
                  let tab = InspectorTab(rawValue: raw) else { return }
            state.inspectorTab = tab
            state.inspectorShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.previousSession)) { _ in
            state.step(-1)
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.nextSession)) { _ in
            state.step(1)
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceCommand.refresh)) { _ in
            Task { await state.load() }
        }
        // A rewritten config means a restarted OpenCode with a new
        // catalogue; the composer's model menu must not keep the old one.
        .onReceive(NotificationCenter.default.publisher(for: ModelSourceStore.applied)) { _ in
            Task {
                try? await Task.sleep(for: .seconds(3))
                await state.models.load()
            }
        }
        .onReceive(modelSources.$reviewRequested) { requested in
            if requested, state.activePeer == nil { state.selection = .modelSources }
        }
        // Coming back to the app is the moment a session started elsewhere
        // (the OpenCode CLI in a terminal, the phone) should already be in
        // the sidebar, without anyone knowing to ask.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await state.load() }
        }
        .onChange(of: state.selection) { persistSelection() }
        .onChange(of: state.inspectorShown) { storedInspectorShown = state.inspectorShown }
        .onChange(of: state.inspectorTab) { storedInspectorTab = state.inspectorTab.rawValue }
        .task {
            state.inspectorShown = storedInspectorShown
            state.inspectorTab = InspectorTab(rawValue: storedInspectorTab) ?? .changes
            await state.load()
            restoreSelection()
        }
        .task { await state.models.loadIfNeeded() }
        .task { await state.agents.loadIfNeeded() }
        .task { await state.commands.loadIfNeeded() }
    }

    private func persistSelection() {
        switch state.selection {
        case let .session(session): storedSelection = "session:\(session.id)"
        case let .project(project): storedSelection = "project:\(project.worktree)"
        case .schedules: storedSelection = "schedules"
        case .modelSources: storedSelection = "modelSources"
        case nil: storedSelection = ""
        }
    }

    private func restoreSelection() {
        guard state.selection == nil, !storedSelection.isEmpty else { return }
        if storedSelection.hasPrefix("session:") {
            let id = String(storedSelection.dropFirst("session:".count))
            if let session = state.sessions.first(where: { $0.id == id }) {
                state.selection = .session(session)
            }
        } else if storedSelection.hasPrefix("project:") {
            let worktree = String(storedSelection.dropFirst("project:".count))
            if let project = state.projects.first(where: { $0.worktree == worktree }) {
                state.selection = .project(project)
            }
        } else if storedSelection == "schedules" {
            state.selection = .schedules
        } else if storedSelection == "modelSources" {
            state.selection = .modelSources
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case let .session(session):
            WorkspaceSessionView(
                state: state,
                project: session.directory ?? "",
                session: session.id,
                title: session.title ?? "Session"
            )
            // A fresh controller per conversation: the id is what stops one
            // session's in-flight turn from streaming into another's pane.
            .id(session.id)
        case let .project(project):
            WorkspaceSessionView(
                state: state,
                project: project.worktree,
                session: nil,
                title: project.displayName
            )
            .id(project.worktree)
        case .schedules:
            ScheduleListView(
                store: state.schedules, models: state.models, projects: state.projects
            ) { session in
                state.selection = .session(session)
            }
        case .modelSources:
            ModelSourcesView(store: modelSources)
        case nil:
            VStack(spacing: 16) {
                BrandWordmark(height: 14, color: .inkFaint)
                Text("Pick a session to continue, or a project to start one.")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
        }
    }
}
