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
    /// This Mac's folders come from a real picker; a remote Mac's disk
    /// can't be browsed from here, so its path gets typed instead.
    @State private var pickingFolder = false
    @State private var typingFolder = false
    @State private var typedFolderPath = ""

    var body: some View {
        List(selection: $state.selection) {
            macSection
            if let error = state.error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Color.inkMuted)
                        .font(.callout)
                }
            }
            sessionSection
            projectSection
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
            TextField("Search sessions", text: $state.search)
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

    @ViewBuilder
    private var sessionSection: some View {
        if !state.sessions.isEmpty {
            Section(state.search.isEmpty ? "Continue" : "Matching sessions") {
                ForEach(state.sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title ?? "Untitled session")
                            .lineLimit(1)
                        if let directory = session.directory {
                            Text(directory.split(separator: "/").last.map(String.init) ?? directory)
                                .font(.caption)
                                .foregroundStyle(Color.inkMuted)
                        }
                    }
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
        }
    }

    /// While searching, projects are noise — the user is looking for a
    /// conversation, not a place to start one.
    @ViewBuilder
    private var projectSection: some View {
        if state.search.isEmpty {
            Section("Projects") {
                ForEach(state.projects) { project in
                    HStack {
                        Text(project.displayName)
                        if project.known == false {
                            // Discovered on disk, never opened with
                            // OpenCode — starting a session here is what
                            // opens it.
                            Spacer()
                            Text("new")
                                .font(.caption2.smallCaps())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(Color.inkMuted)
                        }
                    }
                    .tag(WorkspaceSelection.project(project))
                    .contextMenu {
                        Button("New Session") {
                            state.selection = .project(project)
                        }
                        if project.added == true {
                            Button("Remove from Projects", role: .destructive) {
                                state.removeFolder(project)
                            }
                        }
                    }
                }
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
            }
        }
    }
}
