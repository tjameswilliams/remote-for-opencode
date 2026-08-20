import RemoteKit
import SwiftUI

/// The launcher: recent sessions to continue, projects to start fresh in.
/// Both lists come from the Mac in one round trip each; pull-to-refresh
/// re-asks. Errors render inline where the list would be — on a phone,
/// away from home, "couldn't reach your Mac" IS the content.
struct HomeView: View {
    @State private var projects: [Project] = []
    @State private var sessions: [Session] = []
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                sessionSection
                projectSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // 15 rather than 13: five rows of whole-point cells.
                    BrandWordmark(height: 15, color: .ink)
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
                }
            }
            .overlay {
                if loading, sessions.isEmpty, projects.isEmpty {
                    ProgressView("Reaching your Mac…")
                }
            }
            .searchable(text: $search, prompt: "Search sessions")
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

    @ViewBuilder
    private var sessionSection: some View {
        if !sessions.isEmpty {
            Section(search.isEmpty ? "Continue" : "Matching sessions") {
                ForEach(sessions) { session in
                    NavigationLink(value: Destination.session(session)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title ?? "Untitled session")
                                .lineLimit(1)
                            if let directory = session.directory {
                                Text(directory.split(separator: "/").last.map(String.init) ?? directory)
                                    .font(.caption)
                                    .foregroundStyle(Color.inkMuted)
                            }
                        }
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
            }
        }
    }

    /// While searching, projects are noise — the user is looking for a
    /// conversation, not a place to start one.
    @ViewBuilder
    private var projectSection: some View {
        if search.isEmpty {
            Section("Projects") {
                ForEach(projects) { project in
                    NavigationLink(value: Destination.project(project)) {
                        HStack {
                            Text(project.displayName)
                            if project.known == false {
                                // Discovered on disk, never opened with
                                // OpenCode — starting a session here is
                                // what opens it.
                                Spacer()
                                Text("new")
                                    .font(.caption2.smallCaps())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                    .foregroundStyle(Color.inkMuted)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        // Only folders the user pinned by hand: known
                        // projects are OpenCode's history, and discovered
                        // repos would just be found again.
                        if project.added == true {
                            Button(role: .destructive) { removeFolder(project) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    addingFolder = true
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                        .foregroundStyle(Color.inkMuted)
                }
            }
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
