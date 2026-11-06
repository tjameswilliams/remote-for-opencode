import RemoteKit
import SwiftUI

/// One project's file explorer: the folders loaded so far, which are
/// expanded, the open file, and the quick-open index. Platform-neutral;
/// the Mac draws it as a tree in the inspector, the phone as a stack of
/// folder screens.
///
/// Kept per project rather than per view, so switching inspector tabs or
/// conversations in the same project comes back to the tree as it was.
@MainActor
final class FileBrowser: ObservableObject {
    let project: String
    private let makeLink: () -> CompanionLink

    /// Folder path ("" is the root) to its entries, once listed.
    @Published private(set) var children: [String: [FileEntry]] = [:]
    @Published var expanded: Set<String> = []
    @Published private(set) var loadingFolders: Set<String> = []
    /// Why the last listing failed, per folder.
    @Published private(set) var folderErrors: [String: String] = [:]

    /// The open file, by project-relative path. Nil shows the tree.
    @Published private(set) var openPath: String?
    @Published private(set) var content: FileContent?
    @Published private(set) var contentError: String?
    @Published private(set) var loadingContent = false
    /// Which row the tree highlights: the open file, or the last click.
    @Published var selection: String?
    /// The line the open file was asked for at (a reply citing
    /// `Foo.swift:42`), for the viewer to bring into view.
    @Published private(set) var line: Int?
    /// Bumped on every open, so a viewer can react to the same file being
    /// opened again at another line.
    @Published private(set) var openCount = 0

    /// Editing the open file: the text being changed, and the save.
    @Published private(set) var editing = false
    @Published var draft = ""
    @Published private(set) var saving = false
    /// Why the last save failed, for an alert.
    @Published var saveError: String?
    /// The file changed on the Mac since editing began; the user chooses
    /// to overwrite it or drop their edit.
    @Published var conflict = false
    /// Navigation that would throw away an unsaved edit, held until the
    /// user says save, discard, or stay.
    @Published var pendingDiscard: PendingAction?

    enum PendingAction: Equatable {
        case open(String, line: Int?)
        case close
    }

    var dirty: Bool { editing && draft != (content?.text ?? "") }
    var canEdit: Bool { content?.editable == true }

    /// Every file's path, for quick open. Loaded on first use.
    @Published private(set) var index: [String]?
    @Published private(set) var indexTruncated = false
    @Published private(set) var indexing = false
    @Published var query = ""
    /// The index as a resolver for file references in the agent's replies.
    @Published private(set) var links: FileLinks?

    private var contentTask: Task<Void, Never>?

    init(project: String, makeLink: @escaping () -> CompanionLink) {
        self.project = project
        self.makeLink = makeLink
    }

    // MARK: - Folders

    func loadRootIfNeeded() async {
        if children[""] == nil, !loadingFolders.contains("") { await load("") }
    }

    func load(_ folder: String) async {
        loadingFolders.insert(folder)
        defer { loadingFolders.remove(folder) }
        var request = Wire.Request(kind: "files")
        request.project = project
        request.path = folder
        for await event in makeLink().run(request) {
            switch event.kind {
            case "files":
                children[folder] = event.entries ?? []
                folderErrors[folder] = nil
            case "failed":
                folderErrors[folder] = event.text ?? "Couldn't list this folder."
            default:
                break
            }
        }
    }

    func toggle(_ folder: String) {
        if expanded.remove(folder) == nil {
            expanded.insert(folder)
            if children[folder] == nil { Task { await load(folder) } }
        }
    }

    /// The tree as rows, depth-first through the expanded folders.
    var visibleRows: [Row] {
        var rows: [Row] = []
        func walk(_ folder: String, depth: Int) {
            for entry in children[folder] ?? [] {
                rows.append(Row(entry: entry, depth: depth))
                if entry.directory, expanded.contains(entry.path) {
                    walk(entry.path, depth: depth + 1)
                }
            }
        }
        walk("", depth: 0)
        return rows
    }

    struct Row: Identifiable, Equatable {
        let entry: FileEntry
        let depth: Int
        var id: String { entry.path }
    }

    // MARK: - Files

    /// Opens a file by project-relative path, or by absolute path inside
    /// the project (what a tool card carries). Expands the tree down to it
    /// so closing the file lands beside it.
    func open(_ path: String, line: Int? = nil) {
        if dirty {
            pendingDiscard = .open(path, line: line)
            return
        }
        endEditing()
        openCount += 1
        self.line = line
        guard let relative = ProjectPath.relative(path, to: project), !relative.isEmpty else {
            openPath = path
            content = nil
            contentError = "\(path) is outside this project."
            return
        }
        openPath = relative
        selection = relative
        for folder in ProjectPath.ancestors(of: relative) {
            expanded.insert(folder)
            if children[folder] == nil { Task { await load(folder) } }
        }
        loadContent(relative)
    }

    func close() {
        if dirty {
            pendingDiscard = .close
            return
        }
        endEditing()
        line = nil
        contentTask?.cancel()
        openPath = nil
        content = nil
        contentError = nil
        loadingContent = false
    }

    private func loadContent(_ path: String) {
        contentTask?.cancel()
        content = nil
        contentError = nil
        loadingContent = true
        contentTask = Task {
            var request = Wire.Request(kind: "file")
            request.project = project
            request.path = path
            var loaded: FileContent?
            var failure: String?
            for await event in makeLink().run(request) {
                switch event.kind {
                case "file": loaded = event.file
                case "failed": failure = event.text
                default: break
                }
            }
            guard !Task.isCancelled, openPath == path else { return }
            content = loaded
            contentError = loaded == nil ? (failure ?? "Couldn't read this file.") : nil
            loadingContent = false
        }
    }

    /// Re-lists every loaded folder and re-reads the open file: the agent
    /// may have changed any of it.
    func refresh() async {
        // An open edit keeps its file as it was; a save checks for changes.
        if let openPath, !editing { loadContent(openPath) }
        if index != nil { Task { await reloadIndex() } }
        let folders = Array(children.keys)
        await withTaskGroup(of: Void.self) { group in
            for folder in folders {
                group.addTask { await self.load(folder) }
            }
        }
    }

    // MARK: - Quick open

    func loadIndexIfNeeded() async {
        guard index == nil, !indexing else { return }
        await reloadIndex()
    }

    /// Fetches the index again, keeping the old one until the new lands,
    /// so links in the transcript don't blink out while it refreshes.
    func reloadIndex() async {
        guard !indexing else { return }
        indexing = true
        defer { indexing = false }
        var request = Wire.Request(kind: "files.index")
        request.project = project
        for await event in makeLink().run(request) where event.kind == "files.index" {
            let paths = event.paths ?? []
            index = paths
            indexTruncated = event.truncated == true
            let root = project
            links = await Task.detached { FileLinks(root: root, paths: paths) }.value
        }
    }

    // MARK: - Editing

    func beginEditing() {
        guard canEdit, let text = content?.text else { return }
        draft = text
        editing = true
    }

    /// Drops the edit; the viewer goes back to the file as last read.
    func cancelEditing() {
        endEditing()
    }

    private func endEditing() {
        editing = false
        draft = ""
        conflict = false
        saveError = nil
    }

    /// Writes the draft back. True when saved; a conflict sets `conflict`
    /// for the user to settle, any other failure `saveError`.
    @discardableResult
    func save(force: Bool = false) async -> Bool {
        guard editing, let path = openPath, let content, !saving else { return false }
        saving = true
        defer { saving = false }
        var request = Wire.Request(kind: "file.save")
        request.project = project
        request.path = path
        request.text = draft
        request.version = content.version
        request.force = force ? true : nil
        var saved: FileContent?
        var failure: Wire.Event?
        for await event in makeLink().run(request) {
            switch event.kind {
            case "file": saved = event.file
            case "failed": failure = event
            default: break
            }
        }
        guard let saved, openPath == path else {
            if failure?.conflict == true {
                conflict = true
            } else {
                saveError = failure?.text ?? "Couldn't save \((path as NSString).lastPathComponent)."
            }
            return false
        }
        self.content = saved
        endEditing()
        return true
    }

    /// Answers `pendingDiscard`: save first, or throw the edit away, then
    /// carry on where the user was going.
    func resolvePending(save shouldSave: Bool) async {
        guard let action = pendingDiscard else { return }
        pendingDiscard = nil
        if shouldSave {
            guard await save() else { return }
        } else {
            endEditing()
        }
        switch action {
        case let .open(path, line): open(path, line: line)
        case .close: close()
        }
    }

    var matches: [String] {
        guard let index else { return [] }
        return FileSearch.rank(index, query: query)
    }

    /// tools/uiharness renders the folder screens without a Mac.
    func mockForHarness(_ listing: [String: [FileEntry]]) {
        children = listing
    }

    // MARK: - Display helpers

    static func icon(for entry: FileEntry, expanded: Bool = false) -> String {
        entry.directory ? (expanded ? "folder.fill" : "folder") : icon(forFile: entry.name)
    }

    static func icon(forFile name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if FileKind.imageExtensions.contains(ext) { return "photo" }
        switch ext {
        case "pdf": return "doc.richtext"
        case "md", "markdown", "mdx", "txt", "rtf": return "doc.text"
        case "json", "yaml", "yml", "toml", "plist", "xml", "ini", "lock": return "doc.badge.gearshape"
        case "html", "htm", "svg": return "globe"
        case "zip", "gz", "tar", "tgz", "dmg": return "archivebox"
        case "": return "doc"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    static func tint(for status: String?) -> Color {
        switch status {
        case "added", "untracked": return .positive
        case "deleted", "conflicted": return .negative
        case "modified", "renamed": return .caution
        default: return .inkFaint
        }
    }

    /// The one-letter badge an editor puts beside a changed file.
    static func badge(for status: String?) -> String? {
        switch status {
        case "added": return "A"
        case "untracked": return "U"
        case "deleted": return "D"
        case "conflicted": return "!"
        case "renamed": return "R"
        case "modified": return "M"
        default: return nil
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Opens a project file wherever this platform shows files: the Mac's
/// inspector, the phone's Files sheet. Set by the conversation screen; a
/// transcript without one leaves file names as plain text.
struct OpenFileAction {
    let handler: (String, Int?) -> Void
    func callAsFunction(_ path: String, line: Int? = nil) { handler(path, line) }
}

private struct OpenFileKey: EnvironmentKey {
    static let defaultValue: OpenFileAction? = nil
}

extension EnvironmentValues {
    var openFile: OpenFileAction? {
        get { self[OpenFileKey.self] }
        set { self[OpenFileKey.self] = newValue }
    }
}
