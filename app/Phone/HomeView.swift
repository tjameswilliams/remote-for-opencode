import RemoteKit
import SwiftUI

/// The launcher: every project, with its conversations nested underneath.
/// Tap a project to expand it; the freshest one arrives already open, so
/// continuing the last conversation stays one tap. Both lists come from
/// the Mac in one round trip each; pull-to-refresh re-asks. Errors render
/// inline where the list would be: on a phone, away from home, "couldn't
/// reach your Mac" IS the content.
struct HomeView: View {
    @State private var projects: [Project] = []
    @State private var sessions: [Session] = []
    /// Disclosure the user has set by hand, by project id. Anything absent
    /// falls back to the default: only the freshest project open.
    @State private var toggled: [String: Bool] = [:]
    @State private var error: String?
    @State private var loading = false
    /// Nil = unknown/checking, true = a path to the Mac exists right now.
    @State private var reachable: Bool?
    @State private var search = ""
    /// Debounces typing into one request per pause, so a search doesn't
    /// fire a round trip to the Mac per keystroke.
    @State private var searchTask: Task<Void, Never>?
    @State private var renaming: Session?
    @State private var newTitle = ""
    /// The phone can't browse the Mac's disk, so a new project source is a
    /// typed path, validated on the Mac.
    @State private var addingFolder = false
    @State private var newFolderPath = ""
    /// The Mac's scheduled tasks; created here so the list survives
    /// pushing in and out of the schedules screen.
    @StateObject private var schedules = ScheduleStore()
    /// Bound so screens without a link of their own (the schedules page
    /// opening a run's output) can still push.
    @State private var path = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error {
                    Section {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                groupSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // 15 rather than 13: five rows of whole-point cells.
                    BrandWordmark(height: 15, color: .ink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Destination.schedules) {
                        Image(systemName: "clock.badge")
                            .accessibilityLabel("Scheduled tasks")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The standing answer to "is my Mac in reach?" — probed
                    // over the punched path, which is the only honest test:
                    // it proves packets travel, from home or anywhere.
                    Circle()
                        .fill(reachable == true ? .green : reachable == false ? .red : .gray)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel(
                            reachable == true ? "Mac connected"
                                : reachable == false ? "Mac unreachable" : "Checking"
                        )
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case let .session(session):
                    SessionView(
                        project: session.directory ?? "", session: session.id,
                        title: session.title ?? "Session"
                    )
                case let .project(project):
                    SessionView(
                        project: project.worktree, session: nil,
                        title: project.displayName
                    )
                case .schedules:
                    ScheduleListView(
                        store: schedules, models: ModelStore.shared, projects: projects
                    ) { session in
                        path.append(session)
                    }
                }
            }
            // ScheduleListView pushes Session values directly; they land
            // in the same session screen as the launcher's rows.
            .navigationDestination(for: Session.self) { session in
                SessionView(
                    project: session.directory ?? "", session: session.id,
                    title: session.title ?? "Session"
                )
            }
            .overlay {
                if loading, sessions.isEmpty, projects.isEmpty {
                    ProgressView("Reaching your Mac…")
                }
            }
            .searchable(text: $search, prompt: "Search projects and sessions")
            .onChange(of: search) {
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await loadSessions()
                }
            }
            .refreshable { await load() }
            .task { await load() }
            // Returning to the app is the moment a session started
            // elsewhere (the OpenCode CLI on the Mac) should already be in
            // the list, without knowing to pull down.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await load() }
            }
            .alert("Rename session", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let s = renaming { rename(s, to: newTitle) } }
            }
            .alert("Add a folder on your Mac", isPresented: $addingFolder) {
                TextField("~/path/to/project", text: $newFolderPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { addingFolder = false }
                Button("Add") {
                    let path = newFolderPath
                    newFolderPath = ""
                    addFolder(path)
                }
            } message: {
                Text("The full path of the folder, as your Mac sees it. It becomes a project you can start sessions in.")
            }
        }
    }

    private enum Destination: Hashable {
        case session(Session)
        case project(Project)
        case schedules
    }

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil
        // Probe alongside the lists, not before them — the lists are their
        // own proof of reach when they arrive, and a successful probe
        // leaves a proven punch path for the next request to reuse.
        Task { reachable = await PunchClient.shared.reachable().isSuccess }
        await loadSessions()
        for await event in CompanionLink().run(Wire.Request(kind: "projects")) {
            switch event.kind {
            case "projects": projects = event.projects ?? []
            case "failed": error = event.text
            default: break
            }
        }
    }

    /// The grouped list, built fresh from whatever the last round trips
    /// returned. Session matching happened on the Mac; project names are
    /// matched here, so a search covers both.
    private var groups: [ProjectGroup] {
        ProjectGrouping.groups(projects: projects, sessions: sessions, search: search)
    }

    /// The one project open by default: the freshest, so "continue where I
    /// left off" is the state the launcher arrives in.
    private var defaultExpandedID: String? {
        groups.first { !$0.sessions.isEmpty }?.id
    }

    private func isExpanded(_ group: ProjectGroup) -> Bool {
        // A search result that stayed folded would be a result withheld.
        if !search.isEmpty { return true }
        return toggled[group.id] ?? (group.id == defaultExpandedID)
    }

    @ViewBuilder
    private var groupSection: some View {
        Section(search.isEmpty ? "Projects" : "Results") {
            ForEach(groups) { group in
                projectRow(group)
                if isExpanded(group) {
                    // Searching means looking for a conversation, not a
                    // place to start one.
                    if search.isEmpty, !group.project.worktree.isEmpty {
                        NavigationLink(value: Destination.project(group.project)) {
                            Label("New Session", systemImage: "plus")
                                .foregroundStyle(Color.inkMuted)
                                .padding(.leading, indent)
                        }
                    }
                    ForEach(group.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
            if search.isEmpty {
                Button {
                    addingFolder = true
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                        .foregroundStyle(Color.inkMuted)
                }
            } else if groups.isEmpty, !loading {
                Text("No matching projects or sessions")
                    .foregroundStyle(Color.inkMuted)
            }
        }
    }

    /// Nested rows sit past the disclosure chevron's column, so a group
    /// reads as one indented block under its project.
    private let indent: CGFloat = 22

    private func projectRow(_ group: ProjectGroup) -> some View {
        Button {
            withAnimation(Motion.easeOut(0.25)) {
                toggled[group.id] = !isExpanded(group)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkMuted)
                    .rotationEffect(.degrees(isExpanded(group) ? 90 : 0))
                Text(group.project.displayName)
                    .foregroundStyle(Color.ink)
                Spacer()
                if group.project.known == false {
                    // Discovered on disk, never opened with OpenCode;
                    // starting a session here is what opens it.
                    Text("new")
                        .font(.caption2.smallCaps())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(Color.inkMuted)
                } else if !group.sessions.isEmpty, !isExpanded(group) {
                    // A folded group still says how much it holds.
                    Text("\(group.sessions.count)")
                        .font(.caption)
                        .foregroundStyle(Color.inkFaint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(
            "\(group.project.displayName), \(isExpanded(group) ? "expanded" : "collapsed"), \(group.sessions.count) sessions"
        )
        .swipeActions(edge: .trailing) {
            // Only folders the user pinned by hand: known projects are
            // OpenCode's history, and discovered repos would just be
            // found again.
            if group.project.added == true {
                Button(role: .destructive) { removeFolder(group.project) } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    /// No directory subtitle here: the project row above already says it.
    private func sessionRow(_ session: Session) -> some View {
        NavigationLink(value: Destination.session(session)) {
            Text(session.title ?? "Untitled session")
                .lineLimit(1)
                .padding(.leading, indent)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(session) } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renaming = session
                newTitle = session.title ?? ""
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.gray)
        }
    }

    /// Both edits answer with the merged project list, so the phone shows
    /// exactly what the Mac decided, never its own guess.
    private func addFolder(_ path: String) {
        sendFolderEdit(kind: "project.add", path: path)
    }

    private func removeFolder(_ project: Project) {
        sendFolderEdit(kind: "project.remove", path: project.worktree)
    }

    private func sendFolderEdit(kind: String, path: String) {
        var request = Wire.Request(kind: kind)
        request.project = path
        Task {
            for await event in CompanionLink().run(request) {
                switch event.kind {
                case "projects": projects = event.projects ?? []
                case "failed": error = event.text
                default: break
                }
            }
        }
    }

    /// Removed locally first: the list should respond to the swipe, not to
    /// a round trip. A failure puts it back and says why.
    private func delete(_ session: Session) {
        let index = sessions.firstIndex(of: session)
        sessions.removeAll { $0.id == session.id }
        var request = Wire.Request(kind: "session.delete")
        request.session = session.id
        request.project = session.directory
        Task {
            for await event in CompanionLink().run(request) where event.kind == "failed" {
                error = event.text
                if let index { sessions.insert(session, at: min(index, sessions.count)) }
            }
        }
    }

    private func rename(_ session: Session, to title: String) {
        renaming = nil
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].title = trimmed
        }
        var request = Wire.Request(kind: "session.rename")
        request.session = session.id
        request.project = session.directory
        request.title = trimmed
        Task {
            for await event in CompanionLink().run(request) where event.kind == "failed" {
                error = event.text
            }
        }
    }

    /// Sessions alone — what a search re-runs without disturbing the
    /// project list or the presence probe.
    private func loadSessions() async {
        var request = Wire.Request(kind: "sessions")
        request.search = search.isEmpty ? nil : search
        for await event in CompanionLink().run(request) {
            switch event.kind {
            case "sessions": sessions = event.sessions ?? []
            case "failed": error = event.text
            default: break
            }
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
