import RemoteKit
import SwiftUI
import UniformTypeIdentifiers

/// The workspace's left column: which Mac, which conversation, which
/// project. Structure is space and weight, not separators — the sidebar
/// list style already agrees with the design language.
struct WorkspaceSidebar: View {
    @ObservedObject var state: WorkspaceState
    @State private var renaming: Session?
    @State private var newTitle = ""
    /// Disclosure the user has set by hand, by project id. Anything absent
    /// falls back to the default: only the freshest project open.
    @State private var toggled: [String: Bool] = [:]
    /// This Mac's folders come from a real picker; a remote Mac's disk
    /// can't be browsed from here, so its path gets typed instead.
    @State private var pickingFolder = false
    @State private var typingFolder = false
    @State private var typedFolderPath = ""

    var body: some View {
        List(selection: $state.selection) {
            scheduledSection
            macSection
            if let error = state.error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Color.inkMuted)
                        .font(.callout)
                }
            }
            groupSection
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .safeAreaInset(edge: .top, spacing: 0) { searchField }
        .alert("Rename session", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let s = renaming { state.rename(s, to: newTitle) }
                renaming = nil
            }
        }
        .fileImporter(
            isPresented: $pickingFolder, allowedContentTypes: [.folder]
        ) { result in
            if case let .success(url) = result { state.addFolder(url.path) }
        }
        .alert("Add a folder on \(state.activePeer?.name ?? "this Mac")", isPresented: $typingFolder) {
            TextField("~/path/to/project", text: $typedFolderPath)
            Button("Cancel", role: .cancel) { typingFolder = false }
            Button("Add") {
                let path = typedFolderPath
                typedFolderPath = ""
                state.addFolder(path)
            }
        } message: {
            Text("The full path of the folder, as that Mac sees it.")
        }
    }

    /// The standing entry above everything else: what this Mac runs on
    /// its own, reachable without hunting through the toolbar.
    private var scheduledSection: some View {
        Section {
            Label("Scheduled", systemImage: "clock.badge")
                .tag(WorkspaceSelection.schedules)
            // Edits this Mac's own opencode.json, so a remote Mac's
            // workspace has nothing to show here.
            if state.activePeer == nil {
                // A trailing count rather than `.badge`: on macOS 14 the
                // badge modifier swallows the row's tag and the row can no
                // longer be selected at all.
                HStack {
                    Label("Model Sources", systemImage: "cpu")
                    if !modelSources.pending.isEmpty {
                        Spacer()
                        Text("\(modelSources.pending.count)")
                            .font(.caption)
                            .foregroundStyle(Color.clay)
                    }
                }
                .tag(WorkspaceSelection.modelSources)
            }
        }
    }

    @ObservedObject private var modelSources = ModelSourceStore.shared

    /// This Mac, then every paired Mac. The active one's dot is honest —
    /// green until a request fails, red after; an inactive remote Mac gets
    /// the neutral dot because nothing has been asked of it yet.
    @Environment(\.openWindow) private var openWindow

    private var macSection: some View {
        Section("Macs") {
            macRow(name: "This Mac", peer: nil)
            ForEach(state.pairedMacs) { peer in
                macRow(name: peer.name, peer: peer)
            }
            Button {
                openWindow(id: "devices")
            } label: {
                Label("Pair another Mac…", systemImage: "plus")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            }
            .buttonStyle(.plain)
        }
    }

    private func macRow(name: String, peer: PairedPeer?) -> some View {
        let active = state.activePeer?.id == peer?.id
        return Button {
            state.selectPeer(peer)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(active ? (state.error == nil ? Color.green : .red) : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(name)
                    .fontWeight(active ? .semibold : .regular)
                if peer?.legacy == true {
                    Spacer()
                    Text("update")
                        .font(.caption2.smallCaps())
                        .foregroundStyle(Color.inkFaint)
                        .help("This Mac runs a pre-1.2 companion — update it for the best connection.")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            active
                ? "\(name), active\(state.error == nil ? "" : ", unreachable")"
                : name
        )
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Search projects and sessions", text: $state.search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onChange(of: state.search) { state.searchChanged() }
            // The lists load once per window otherwise, and a session
            // started in a terminal has no way to announce itself.
            Button {
                Task { await state.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(state.loading)
            .help("Refresh sessions and projects (⌘R)")
            .accessibilityLabel("Refresh sessions and projects")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// The grouped list, built fresh from whatever the last round trips
    /// returned. Session matching happened on the active Mac; project
    /// names are matched here, so a search covers both.
    private var groups: [ProjectGroup] {
        ProjectGrouping.groups(
            projects: state.projects, sessions: state.sessions, search: state.search
        )
    }

    /// The one project open by default: the freshest, so continuing the
    /// last conversation is the state the sidebar arrives in.
    private var defaultExpandedID: String? {
        groups.first { !$0.sessions.isEmpty }?.id
    }

    private func isExpanded(_ group: ProjectGroup) -> Bool {
        // A search result that stayed folded would be a result withheld.
        if !state.search.isEmpty { return true }
        return toggled[group.id] ?? (group.id == defaultExpandedID)
    }

    @ViewBuilder
    private var groupSection: some View {
        Section(state.search.isEmpty ? "Projects" : "Results") {
            ForEach(groups) { group in
                projectRow(group)
                if isExpanded(group) {
                    // Searching means looking for a conversation, not a
                    // place to start one.
                    if state.search.isEmpty, !group.project.worktree.isEmpty {
                        Label("New Session", systemImage: "plus")
                            .font(.callout)
                            .foregroundStyle(Color.inkMuted)
                            .padding(.leading, indent)
                            .tag(WorkspaceSelection.project(group.project))
                    }
                    ForEach(group.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
            if state.search.isEmpty {
                Button {
                    // A remote Mac's disk can't be browsed from here.
                    if state.activePeer == nil {
                        pickingFolder = true
                    } else {
                        typingFolder = true
                    }
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                        .font(.callout)
                        .foregroundStyle(Color.inkMuted)
                }
                .buttonStyle(.plain)
            } else if groups.isEmpty, !state.loading {
                Text("No matching projects or sessions")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            }
        }
    }

    /// Nested rows sit past the disclosure chevron's column, so a group
    /// reads as one indented block under its project.
    private let indent: CGFloat = 16

    private func projectRow(_ group: ProjectGroup) -> some View {
        Button {
            withAnimation(Motion.easeOut(0.25)) {
                toggled[group.id] = !isExpanded(group)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.inkMuted)
                    .rotationEffect(.degrees(isExpanded(group) ? 90 : 0))
                Text(group.project.displayName)
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
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(group.project.displayName), \(isExpanded(group) ? "expanded" : "collapsed"), \(group.sessions.count) sessions"
        )
        .contextMenu {
            if !group.project.worktree.isEmpty {
                Button("New Session") {
                    state.selection = .project(group.project)
                }
            }
            if group.project.added == true {
                Button("Remove from Projects", role: .destructive) {
                    state.removeFolder(group.project)
                }
            }
        }
    }

    /// No directory subtitle here: the project row above already says it.
    private func sessionRow(_ session: Session) -> some View {
        Text(session.title ?? "Untitled session")
            .lineLimit(1)
            .padding(.leading, indent)
            .tag(WorkspaceSelection.session(session))
            .contextMenu {
                Button("Rename…") {
                    renaming = session
                    newTitle = session.title ?? ""
                }
                Button("Delete", role: .destructive) {
                    state.delete(session)
                }
            }
    }
}
