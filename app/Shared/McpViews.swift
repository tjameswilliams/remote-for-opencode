import RemoteKit
import SwiftUI

/// The MCP servers page: the Mac's roster, each server's status, and the
/// default that decides whether a new conversation starts with its tools
/// on. Pure SwiftUI over McpRegistryStore, so the phone and the desktop
/// workspace share it, laid out like the scheduled tasks page.
struct McpServersView: View {
    @ObservedObject var store: McpRegistryStore

    private enum EditorTarget: Identifiable {
        case edit(McpServer)
        case new
        var id: String {
            switch self {
            case let .edit(server): return "edit:\(server.name)"
            case .new: return "new"
            }
        }
    }

    @State private var editor: EditorTarget?
    @State private var pendingRemove: McpServer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(macOS)
                header
                #endif
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Color.inkMuted)
                }
                if store.restartNeeded { restartCard }
                serverList
                footer
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, pagePadding)
            .padding(.top, pageTop)
            .padding(.bottom, 32)
        }
        .background(Color.canvas)
        .navigationTitle("MCP Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .new
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case let .edit(server):
                McpServerEditorView(store: store, existing: server)
            case .new:
                McpServerEditorView(store: store, existing: nil)
            }
        }
        .confirmationDialog(
            "Remove \"\(pendingRemove?.name ?? "")\"?",
            isPresented: Binding(
                get: { pendingRemove != nil },
                set: { if !$0 { pendingRemove = nil } }
            ),
            presenting: pendingRemove
        ) { server in
            Button("Remove Server", role: .destructive) {
                Task { await store.remove(server.name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The server leaves your Mac's opencode.json and is disconnected. Conversations that used its tools keep their history.")
        }
        .refreshable { await store.load() }
        .task { await store.loadIfNeeded() }
    }

    #if os(macOS)
    private let pagePadding: CGFloat = 32
    private let pageTop: CGFloat = 28
    #else
    private let pagePadding: CGFloat = 16
    private let pageTop: CGFloat = 4
    #endif

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MCP servers")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("The tool servers OpenCode on your Mac can reach, and which ones a new conversation starts with. Each conversation's own Tools menu still overrides these.")
                .font(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .padding(.bottom, 4)
    }

    private var restartCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.clay)
            VStack(alignment: .leading, spacing: 4) {
                Text("Restart OpenCode to finish")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text("The change is live in chats already. Other projects see it once OpenCode restarts, which stops any turn that's running.")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer()
            Button("Restart") { Task { await store.restart() } }
                .disabled(store.loading)
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.block))
    }

    @ViewBuilder
    private var serverList: some View {
        if store.servers.isEmpty {
            if store.loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if store.error == nil {
                Text("No MCP servers yet. Add one here, or ask a chat to add it for you.")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.vertical, 8)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(store.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.hairline)
                            .frame(height: 1)
                            .padding(.leading, 40)
                    }
                    row(server)
                }
            }
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.block))
        }
    }

    private func row(_ server: McpServer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusDot(server)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    if let type = server.type {
                        Text(type)
                            .font(.caption2.smallCaps())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.surfaceRaised, in: Capsule())
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                if let summary = server.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(2)
                }
                Text(detail(server))
                    .font(.caption)
                    .foregroundStyle(server.status == "failed" ? Color.negative : Color.inkFaint)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if server.builtin != true {
                Toggle("On by default", isOn: Binding(
                    get: { server.isDefaultEnabled },
                    set: { enabled in Task { await store.setDefault(server.name, enabled: enabled) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                #if os(macOS)
                .controlSize(.small)
                #endif
                .help("Whether new conversations start with this server's tools on")
                .accessibilityLabel("\(server.name) on by default")
            }
            if store.isEditable(server) {
                Menu {
                    Button("Edit…", systemImage: "pencil") { editor = .edit(server) }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        pendingRemove = server
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.inkMuted)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Server actions")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            if store.isEditable(server) {
                Button("Edit…") { editor = .edit(server) }
                Button("Remove", role: .destructive) { pendingRemove = server }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(server.name), \(detail(server))")
    }

    private func statusDot(_ server: McpServer) -> some View {
        let color: Color
        switch server.status {
        case "connected": color = .positive
        case "failed": color = .negative
        case "needs_auth", "needs_client_registration": color = .caution
        default: color = .inkFaint
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func detail(_ server: McpServer) -> String {
        var parts: [String] = []
        switch server.status {
        case "connected": parts.append("Connected")
        case "failed": parts.append("Failed" + (server.error.map { ": \($0)" } ?? ""))
        case "needs_auth": parts.append("Needs sign-in (run opencode mcp auth \(server.name) on the Mac)")
        case "needs_client_registration": parts.append("Needs an OAuth client id in its config")
        case "disabled": parts.append("Disabled in the config")
        case nil: parts.append("Not connected")
        default: parts.append(server.status ?? "")
        }
        if server.builtin == true {
            parts.append("Remote for OpenCode's management tools: on in chats, off in projects")
        } else if server.configured != true {
            parts.append("Defined by a project's own config")
        } else if !server.isDefaultEnabled {
            parts.append("Off in new conversations")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var footer: some View {
        if let path = store.configPath {
            Text("Servers live in \(path) on your Mac. A chat can manage them too: ask it to add or remove a server.")
                .font(.caption)
                .foregroundStyle(Color.inkFaint)
        }
    }
}

/// Add or edit one server definition. Local servers take a command line;
/// remote ones a URL. Everything else is optional and rarely needed, so it
/// sits below the fold of what most people fill in.
struct McpServerEditorView: View {
    @ObservedObject var store: McpRegistryStore
    var existing: McpServer?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = "local"
    @State private var commandLine = ""
    @State private var cwd = ""
    @State private var environmentText = ""
    @State private var url = ""
    @State private var headersText = ""
    @State private var skipOAuth = false
    @State private var timeoutText = ""
    @State private var enabled = true
    @State private var defaultEnabled = true
    @State private var saving = false
    @State private var problem: String?
    /// The existing definition, so an edit changes only what the form
    /// shows and keeps the rest of the block intact on the Mac.
    @State private var loadedFromMac = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (letters, digits, dash, underscore)", text: $name)
                        .disabled(existing != nil)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Picker("Type", selection: $type) {
                        Text("Local command").tag("local")
                        Text("Remote URL").tag("remote")
                    }
                }
                if type == "local" {
                    Section {
                        TextField("npx -y @modelcontextprotocol/server-github", text: $commandLine, axis: .vertical)
                            .lineLimit(2...4)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField("Working directory (optional)", text: $cwd)
                            .autocorrectionDisabled()
                        TextField("Environment, one KEY=value per line (optional)", text: $environmentText, axis: .vertical)
                            .lineLimit(2...6)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    } header: {
                        Text("Command")
                    } footer: {
                        Text("The command and its arguments, separated by spaces. OpenCode runs it on your Mac and talks to it over stdio.")
                    }
                } else {
                    Section {
                        TextField("https://example.com/mcp", text: $url)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                        TextField("Headers, one Name: value per line (optional)", text: $headersText, axis: .vertical)
                            .lineLimit(2...6)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Toggle("Skip OAuth detection", isOn: $skipOAuth)
                    } header: {
                        Text("URL")
                    } footer: {
                        Text("OpenCode connects over Streamable HTTP and falls back to SSE. Servers that need OAuth are signed in on the Mac with `opencode mcp auth`.")
                    }
                }
                Section("Options") {
                    TextField("Timeout in seconds (optional)", text: $timeoutText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle("Enabled in OpenCode", isOn: $enabled)
                    if existing == nil {
                        Toggle("On in new conversations", isOn: $defaultEnabled)
                    }
                }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(Color.negative)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Server" : "Edit Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: populate)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func populate() {
        guard let existing, !loadedFromMac else { return }
        loadedFromMac = true
        name = existing.name
        defaultEnabled = existing.isDefaultEnabled
        guard let config = existing.config else {
            type = existing.type ?? "local"
            if type == "local" { commandLine = existing.summary ?? "" } else { url = existing.summary ?? "" }
            return
        }
        type = config.type
        enabled = config.isEnabled
        commandLine = (config.command ?? []).joined(separator: " ")
        cwd = config.cwd ?? ""
        environmentText = (config.environment ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        url = config.url ?? ""
        headersText = (config.headers ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        skipOAuth = config.oauthDisabled == true
        timeoutText = config.timeout.map(String.init) ?? ""
    }

    private var built: McpServerConfig {
        var server = McpServerConfig(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), type: type
        )
        if type == "local" {
            server.command = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
            let dir = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            server.cwd = dir.isEmpty ? nil : dir
            let env = Self.pairs(environmentText, separator: "=")
            server.environment = env.isEmpty ? nil : env
        } else {
            server.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let headers = Self.pairs(headersText, separator: ":")
            server.headers = headers.isEmpty ? nil : headers
            server.oauthDisabled = skipOAuth ? true : nil
        }
        if let timeout = Int(timeoutText.trimmingCharacters(in: .whitespaces)) {
            server.timeout = timeout
        }
        server.enabled = enabled ? nil : false
        return server
    }

    /// "KEY=value" or "Name: value" lines into a map; blank lines and
    /// lines without the separator are skipped.
    private static func pairs(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let index = line.firstIndex(of: separator) else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func save() {
        let server = built
        if let problem = server.validationProblem {
            self.problem = problem
            return
        }
        if !timeoutText.trimmingCharacters(in: .whitespaces).isEmpty, server.timeout == nil {
            problem = "The timeout must be a whole number of seconds."
            return
        }
        saving = true
        problem = nil
        Task {
            let saved = await store.save(server)
            if saved, existing == nil, !defaultEnabled {
                await store.setDefault(server.name, enabled: false)
            }
            saving = false
            if saved {
                dismiss()
            } else {
                problem = store.error ?? "The Mac didn't take the change."
            }
        }
    }
}
