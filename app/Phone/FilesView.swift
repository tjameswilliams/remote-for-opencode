import RemoteKit
import SwiftUI

/// The project's files, a folder per screen the way Files.app drills,
/// with search across every file name at the top. Opened from the session
/// toolbar, or straight onto one file from a tool card.
struct FilesView: View {
    @ObservedObject var browser: FileBrowser
    @State private var route: [FilesRoute] = []
    @Environment(\.dismiss) private var dismiss

    init(browser: FileBrowser, file: String? = nil, line: Int? = nil) {
        self.browser = browser
        // The file's screen is already on the stack at first draw, rather
        // than pushed with an animation after the sheet slides up.
        _route = State(initialValue: file.flatMap { ProjectPath.relative($0, to: browser.project) }
            .map { [.file($0, line: line)] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $route) {
            FolderScreen(browser: browser, folder: "")
                .navigationDestination(for: FilesRoute.self) { route in
                    switch route {
                    case let .folder(path): FolderScreen(browser: browser, folder: path)
                    case let .file(path, line): FileScreen(browser: browser, path: path, line: line)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // A swipe down mustn't throw away an unsaved edit.
        .interactiveDismissDisabled(browser.dirty)
    }
}

enum FilesRoute: Hashable {
    case folder(String)
    case file(String, line: Int? = nil)
}

/// One folder's entries. The root also searches the whole project.
struct FolderScreen: View {
    @ObservedObject var browser: FileBrowser
    let folder: String

    private var isRoot: Bool { folder.isEmpty }

    var body: some View {
        content
            .background(Color.canvas)
            .navigationTitle(isRoot ? "Files" : (folder as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if browser.children[folder] == nil { await browser.load(folder) }
            }
            .refreshable { await browser.refresh() }
            .modifier(SearchIfRoot(browser: browser, isRoot: isRoot))
    }

    @ViewBuilder
    private var content: some View {
        if isRoot, !browser.query.isEmpty {
            results
        } else if let entries = browser.children[folder] {
            if entries.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            } else {
                List(entries) { entry in
                    NavigationLink(value: entry.directory ? FilesRoute.folder(entry.path) : .file(entry.path)) {
                        EntryRow(entry: entry)
                    }
                }
                .listStyle(.plain)
            }
        } else if let error = browser.folderErrors[folder] {
            ContentUnavailableView(
                "Couldn't list this folder", systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var results: some View {
        let matches = browser.matches
        if browser.index == nil {
            ProgressView("Indexing files…")
        } else if matches.isEmpty {
            ContentUnavailableView.search(text: browser.query)
        } else {
            List(matches, id: \.self) { path in
                NavigationLink(value: FilesRoute.file(path)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((path as NSString).lastPathComponent)
                            .foregroundStyle(Color.ink)
                        Text((path as NSString).deletingLastPathComponent)
                            .font(.caption)
                            .foregroundStyle(Color.inkFaint)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

/// Search lives on the root screen only: a search field on every pushed
/// folder would search the same whole project from each of them.
private struct SearchIfRoot: ViewModifier {
    @ObservedObject var browser: FileBrowser
    let isRoot: Bool

    func body(content: Content) -> some View {
        if isRoot {
            content
                .searchable(text: $browser.query, prompt: "Go to file")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: browser.query) {
                    if !browser.query.isEmpty { Task { await browser.loadIndexIfNeeded() } }
                }
        } else {
            content
        }
    }
}

private struct EntryRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: FileBrowser.icon(for: entry))
                .font(.callout)
                .foregroundStyle(entry.directory ? Color.clay : Color.inkMuted)
                .frame(width: 22)
            Text(entry.name)
                .foregroundStyle(entry.ignored == true ? Color.inkFaint
                    : entry.status == nil ? Color.ink : FileBrowser.tint(for: entry.status))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if entry.directory, entry.status != nil {
                Circle()
                    .fill(FileBrowser.tint(for: entry.status))
                    .frame(width: 6, height: 6)
            } else if let badge = FileBrowser.badge(for: entry.status) {
                Text(badge)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(FileBrowser.tint(for: entry.status))
            }
            if let size = entry.size {
                Text(FileBrowser.size(size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.inkFaint)
            }
        }
    }
}

/// One file, full screen, editable where it's whole text.
struct FileScreen: View {
    @ObservedObject var browser: FileBrowser
    let path: String
    var line: Int?

    @State private var showSource = false

    private var current: Bool { browser.openPath == path }
    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        Group {
            if current, let content = browser.content {
                FileViewer(
                    content: content, showSource: showSource, line: browser.line,
                    draft: browser.editing ? $browser.draft : nil
                )
            } else if current, let error = browser.contentError {
                ContentUnavailableView(
                    "Couldn't open this file", systemImage: "doc.questionmark",
                    description: Text(error)
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.canvas)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        // Leaving goes through Cancel or Save while editing.
        .navigationBarBackButtonHidden(current && browser.editing)
        .toolbar {
            if current, browser.editing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { browser.cancelEditing() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if browser.saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await browser.save() } }
                            .fontWeight(.semibold)
                            .disabled(!browser.dirty)
                    }
                }
            } else {
                if current, browser.canEdit {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            browser.beginEditing()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel("Edit file")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { actions }
            }
        }
        .alert("\(name) changed on the Mac", isPresented: $browser.conflict) {
            Button("Overwrite", role: .destructive) { Task { await browser.save(force: true) } }
            Button("Discard My Changes") {
                browser.cancelEditing()
                browser.open(path)
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Something else, probably the agent, wrote this file after you started editing. Saving now replaces what's there.")
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(get: { browser.saveError != nil }, set: { if !$0 { browser.saveError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browser.saveError ?? "")
        }
        // Each appearance re-reads: coming back to a file after the agent
        // edited it should show the edit. Not mid-edit, though.
        .onAppear {
            guard !(current && browser.editing) else { return }
            browser.open(path, line: line)
            showSource = line != nil
        }
    }

    private var actions: some View {
        Menu {
            if current, browser.content?.kind.hasSource == true {
                Picker("View", selection: $showSource) {
                    Label("Preview", systemImage: "eye").tag(false)
                    Label("Source", systemImage: "chevron.left.forwardslash.chevron.right").tag(true)
                }
                Divider()
            }
            Button {
                UIPasteboard.general.string = path
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if current, let text = browser.content?.text, browser.content?.truncated != true {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy Contents", systemImage: "doc.on.clipboard")
                }
            }
            Button {
                browser.open(path)
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("File actions")
    }
}
