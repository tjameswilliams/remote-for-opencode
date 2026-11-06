import RemoteKit
import SwiftUI

/// The inspector's Files tab: the project as a tree, and a file opened
/// from it filling the pane, with a breadcrumb and a way back. Typing in
/// the field above the tree searches every file by name instead.
struct FilesPane: View {
    @ObservedObject var state: WorkspaceState
    @ObservedObject var browser: FileBrowser
    @ObservedObject var turn: TurnController

    @State private var showSource = false
    @State private var highlighted = 0
    @State private var hovered: String?
    @FocusState private var searchFocused: Bool

    /// Finder and the default app only make sense for this Mac's own disk.
    private var local: Bool { state.activePeer == nil }

    var body: some View {
        Group {
            if let path = browser.openPath {
                fileView(path)
            } else {
                treeView
            }
        }
        .task(id: browser.project) { await browser.loadRootIfNeeded() }
        // A cited line is in the source, whatever the file's kind.
        .onChange(of: browser.openCount) { showSource = browser.line != nil }
        .onChange(of: turn.running) {
            // The agent just finished: its edits are on disk, so the marks
            // and any open file are stale.
            if !turn.running { Task { await browser.refresh() } }
        }
        .onAppear(perform: takeQuickOpenRequest)
        .alert(
            "\(fileName) changed on the Mac",
            isPresented: $browser.conflict
        ) {
            Button("Overwrite", role: .destructive) { Task { await browser.save(force: true) } }
            Button("Discard My Changes") {
                browser.cancelEditing()
                if let path = browser.openPath { browser.open(path) }
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
        .alert(
            "Save changes to \(fileName)?",
            isPresented: Binding(get: { browser.pendingDiscard != nil }, set: { if !$0 { browser.pendingDiscard = nil } })
        ) {
            Button("Save") { Task { await browser.resolvePending(save: true) } }
            Button("Don't Save", role: .destructive) { Task { await browser.resolvePending(save: false) } }
            Button("Cancel", role: .cancel) { browser.pendingDiscard = nil }
        } message: {
            Text("Your edits haven't been saved to the Mac.")
        }
        .onChange(of: state.quickOpenRequested) { takeQuickOpenRequest() }
    }

    private var fileName: String {
        (browser.openPath.map { $0 as NSString })?.lastPathComponent ?? "This file"
    }

    private func takeQuickOpenRequest() {
        guard state.quickOpenRequested else { return }
        state.quickOpenRequested = false
        browser.close()
        DispatchQueue.main.async { searchFocused = true }
    }

    // MARK: - Tree

    private var treeView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.inkFaint)
                    TextField("Go to file", text: $browser.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit(openHighlighted)
                        .onKeyPress(.downArrow) { moveHighlight(1) }
                        .onKeyPress(.upArrow) { moveHighlight(-1) }
                        .onKeyPress(.escape) {
                            browser.query = ""
                            searchFocused = false
                            return .handled
                        }
                    if !browser.query.isEmpty {
                        Button {
                            browser.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.inkFaint)
                        .accessibilityLabel("Clear search")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.surface)
                )
                Button {
                    Task { await browser.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.inkMuted)
                .help("Refresh files")
                .accessibilityLabel("Refresh files")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .onChange(of: browser.query) {
                highlighted = 0
                if !browser.query.isEmpty { Task { await browser.loadIndexIfNeeded() } }
            }
            .onChange(of: searchFocused) {
                if searchFocused { Task { await browser.loadIndexIfNeeded() } }
            }

            Divider().overlay(Color.hairline)

            if browser.query.isEmpty {
                tree
            } else {
                results
            }
        }
    }

    @ViewBuilder
    private var tree: some View {
        if let error = browser.folderErrors[""], browser.children[""] == nil {
            quiet(error)
        } else if browser.children[""] == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.children[""]?.isEmpty == true {
            quiet("This folder is empty.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(browser.visibleRows) { row in
                        treeRow(row)
                    }
                }
                .padding(6)
            }
        }
    }

    private func treeRow(_ row: FileBrowser.Row) -> some View {
        let entry = row.entry
        let expanded = browser.expanded.contains(entry.path)
        let selected = browser.selection == entry.path
        return HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.inkFaint)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .opacity(entry.directory ? 1 : 0)
                .frame(width: 10)
            Image(systemName: FileBrowser.icon(for: entry, expanded: expanded))
                .font(.system(size: 11))
                .foregroundStyle(entry.directory ? Color.clay : Color.inkMuted)
                .frame(width: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(entry.ignored == true ? Color.inkFaint : Self.nameColor(entry.status))
            Spacer(minLength: 6)
            if browser.loadingFolders.contains(entry.path) {
                ProgressView().controlSize(.mini)
            }
            if let error = browser.folderErrors[entry.path] {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.caution)
                    .help(error)
            }
            if entry.directory, entry.status != nil {
                Circle()
                    .fill(FileBrowser.tint(for: entry.status))
                    .frame(width: 5, height: 5)
            } else if let badge = FileBrowser.badge(for: entry.status) {
                Text(badge)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(FileBrowser.tint(for: entry.status))
            }
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(row.depth) * 14 + 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color.clay.opacity(0.16)
                    : hovered == entry.path ? Color.surface : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = entry.path } else if hovered == entry.path { hovered = nil }
        }
        .onTapGesture {
            browser.selection = entry.path
            if entry.directory { browser.toggle(entry.path) } else { browser.open(entry.path) }
        }
        .contextMenu { pathMenu(entry.path, directory: entry.directory) }
        .help(entry.size.map { "\(entry.path) · \(FileBrowser.size($0))" } ?? entry.path)
    }

    /// Changed files read in their change's color, like an editor's tree.
    private static func nameColor(_ status: String?) -> Color {
        status == nil ? .ink : FileBrowser.tint(for: status)
    }

    // MARK: - Quick open

    @ViewBuilder
    private var results: some View {
        let matches = browser.matches
        if browser.index == nil {
            ProgressView("Indexing files…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if matches.isEmpty {
            quiet("No files match “\(browser.query)”.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                            resultRow(path, highlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { open(path) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
            }
        }
    }

    private func resultRow(_ path: String, highlighted: Bool) -> some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        return HStack(spacing: 6) {
            Image(systemName: FileBrowser.icon(forFile: name))
                .font(.system(size: 11))
                .foregroundStyle(Color.inkMuted)
                .frame(width: 16)
            Text(name)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Text(folder)
                .foregroundStyle(Color.inkFaint)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(highlighted ? Color.clay.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .contextMenu { pathMenu(path, directory: false) }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !browser.query.isEmpty else { return .ignored }
        let count = browser.matches.count
        guard count > 0 else { return .handled }
        highlighted = min(max(highlighted + delta, 0), count - 1)
        return .handled
    }

    private func openHighlighted() {
        let matches = browser.matches
        guard matches.indices.contains(highlighted) else { return }
        open(matches[highlighted])
    }

    private func open(_ path: String) {
        browser.query = ""
        searchFocused = false
        browser.open(path)
    }

    // MARK: - File

    private func fileView(_ path: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    browser.close()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.inkMuted)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to files (⌘[)")
                .accessibilityLabel("Back to files")

                breadcrumb(path)
                    .layoutPriority(-1)

                Spacer(minLength: 4)

                if browser.editing {
                    editControls
                } else {
                    if let content = browser.content, content.kind.hasSource {
                        Picker("", selection: $showSource) {
                            Text("Preview").tag(false)
                            Text("Source").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    if browser.canEdit {
                        Button {
                            browser.beginEditing()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.inkMuted)
                        .help("Edit this file")
                        .accessibilityLabel("Edit file")
                    }
                }

                Menu {
                    pathMenu(path, directory: false)
                    Divider()
                    Button("Reload") { browser.open(path) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Color.inkMuted)
                .accessibilityLabel("File actions")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider().overlay(Color.hairline)

            if let content = browser.content {
                FileViewer(
                    content: content, showSource: showSource, line: browser.line,
                    draft: browser.editing ? $browser.draft : nil
                )
            } else if let error = browser.contentError {
                quiet(error)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Cancel and Save, in place of the viewing controls while editing.
    private var editControls: some View {
        HStack(spacing: 6) {
            if browser.saving {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { browser.cancelEditing() }
                .controlSize(.small)
            Button("Save") { Task { await browser.save() } }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Color.clay)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!browser.dirty || browser.saving)
                .help("Save to the Mac (⌘S)")
        }
    }

    /// The path as folders leading to the file. A folder in it closes the
    /// file and shows that folder in the tree.
    private func breadcrumb(_ path: String) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        return HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.inkFaint)
                }
                if index == parts.count - 1 {
                    Text(part)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                        .textSelection(.enabled)
                } else {
                    Button(part) {
                        let folder = parts.prefix(index + 1).joined(separator: "/")
                        browser.close()
                        browser.selection = folder
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
            }
        }
        .help(path)
    }

    // MARK: - Shared

    @ViewBuilder
    private func pathMenu(_ path: String, directory: Bool) -> some View {
        let absolute = browser.project + "/" + path
        Button("Copy Path") { copy(absolute) }
        Button("Copy Relative Path") { copy(path) }
        if local {
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)])
            }
            if !directory {
                Button("Open with Default App") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: absolute))
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.inkMuted)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
