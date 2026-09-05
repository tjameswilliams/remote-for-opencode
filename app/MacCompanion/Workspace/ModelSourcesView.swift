import RemoteKit
import SwiftUI

/// The model sources page: the endpoints this Mac keeps OpenCode's config
/// in step with, what the last check found, and the review that stands
/// between a check and the file. Laid out like the scheduled tasks page,
/// since it is the same kind of thing: something the Mac does on its own.
struct ModelSourcesView: View {
    @ObservedObject var store: ModelSourceStore

    private enum EditorTarget: Identifiable {
        case edit(ModelSource)
        case new
        var id: String {
            switch self {
            case let .edit(source): return "edit:\(source.id)"
            case .new: return "new"
            }
        }
    }

    @State private var editor: EditorTarget?
    @State private var reviewing = false
    @State private var pendingDelete: ModelSource?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !store.pending.isEmpty { pendingCard }
                if store.restartNeeded { restartCard }
                if let problem = store.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Color.negative)
                }
                sourceList
                settings
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .background(Color.canvas)
        .navigationTitle("Model Sources")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .new
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case let .edit(source):
                ModelSourceEditor(store: store, existing: source)
            case .new:
                ModelSourceEditor(store: store, existing: nil)
            }
        }
        .sheet(isPresented: $reviewing) {
            ModelSyncReviewSheet(store: store)
        }
        .confirmationDialog(
            "Remove \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { source in
            Button("Remove Source", role: .destructive) {
                store.delete(id: source.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The Mac stops checking this endpoint. Its provider block stays in opencode.json until you remove it there.")
        }
        .onChange(of: store.reviewRequested) {
            if store.reviewRequested {
                store.reviewRequested = false
                if !store.pending.isEmpty { reviewing = true }
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model sources")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("Local OpenAI-style endpoints this Mac keeps OpenCode's model list in step with: context windows, output limits, and which models take images. Changes are shown to you before anything is written.")
                .font(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .padding(.bottom, 4)
    }

    private var pendingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.clay)
            VStack(alignment: .leading, spacing: 4) {
                Text(pendingSummary)
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text("Review what would change in opencode.json before it is written.")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer()
            Button("Review…") { reviewing = true }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.block))
    }

    private var pendingSummary: String {
        let added = store.pending.reduce(0) { $0 + $1.added.count }
        let changed = store.pending.reduce(0) { $0 + $1.changed.count }
        let removed = store.pending.reduce(0) { $0 + $1.removed.count }
        var parts: [String] = []
        if added > 0 { parts.append("\(added) new") }
        if changed > 0 { parts.append("\(changed) updated") }
        if removed > 0 { parts.append("\(removed) removed") }
        if parts.isEmpty { return "Provider settings changed" }
        return "Model changes ready: " + parts.joined(separator: ", ")
    }

    private var restartCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.caution)
            VStack(alignment: .leading, spacing: 4) {
                Text("Restart OpenCode to use the new model list")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text("The config was written, but OpenCode only reads it at startup and a turn was still running. Restarting now interrupts any turn in progress.")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer()
            Button("Restart OpenCode") { store.restartNow() }
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.block))
    }

    @ViewBuilder
    private var sourceList: some View {
        if store.sources.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No sources yet")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text("Add the base URL of a vLLM, llama.cpp, LM Studio, or proxy endpoint. Its /models listing becomes the provider's model list in OpenCode's config.")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
                Button("Add Source…") { editor = .new }
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.block))
        } else {
            VStack(spacing: 0) {
                ForEach(store.sources) { source in
                    sourceRow(source)
                    if source.id != store.sources.last?.id {
                        Divider().overlay(Color.hairline)
                    }
                }
            }
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.block))
        }
    }

    private func sourceRow(_ source: ModelSource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { store.setEnabled($0, id: source.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(source.name.isEmpty ? source.providerID : source.name)
                        .font(.headline)
                        .foregroundStyle(source.isEnabled ? Color.ink : Color.inkMuted)
                    Text(source.providerID)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(Color.inkMuted)
                }
                Text(source.baseURL)
                    .font(.callout.monospaced())
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status(for: source)
            }
            Spacer()
            Menu {
                Button("Edit…") { editor = .edit(source) }
                Button("Check Now") { Task { await store.check() } }
                    .disabled(store.checking || !source.isEnabled)
                Divider()
                Button("Remove…", role: .destructive) { pendingDelete = source }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editor = .edit(source) }
    }

    @ViewBuilder
    private func status(for source: ModelSource) -> some View {
        if let error = source.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Color.negative)
        } else if let plan = store.plan(for: source) {
            Label(
                "\(source.lastModelCount ?? plan.modelCount) models, changes waiting for review",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .foregroundStyle(Color.clay)
        } else if let count = source.lastModelCount, let checked = source.lastChecked {
            Text("\(count) models, in sync as of \(checked.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(Color.inkFaint)
        } else {
            Text("Not checked yet")
                .font(.caption)
                .foregroundStyle(Color.inkFaint)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Check sources", selection: $store.autoCheck) {
                    ForEach(ModelSourceStore.AutoCheck.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .fixedSize()
                Spacer()
                if store.checking {
                    ProgressView().controlSize(.small)
                }
                Button(store.checking ? "Checking…" : "Check Now") {
                    Task { await store.check() }
                }
                .disabled(store.checking || !store.isEnabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let last = store.lastCheck {
                    Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened)).")
                }
                Text("Writes to \(store.configPath). The previous version is kept beside it as opencode.json.bak-remote, and OpenCode is restarted to pick up the change.")
                ForEach(store.shadowingFiles, id: \.self) { file in
                    Label(
                        "\(file) is loaded after opencode.json. A provider defined there overrides what this Mac writes.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(Color.caution)
                }
            }
            .font(.caption)
            .foregroundStyle(Color.inkFaint)
        }
        .padding(.top, 8)
    }
}

/// Add or edit one endpoint.
struct ModelSourceEditor: View {
    @ObservedObject var store: ModelSourceStore
    var existing: ModelSource?
    @Environment(\.dismiss) private var dismiss

    @State private var providerID = ""
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var npm = ""
    @State private var problem: String?
    @State private var probing = false
    @State private var probeResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Endpoint") {
                    TextField("Base URL", text: $baseURL, prompt: Text("http://localhost:8000/v1"))
                        .textContentType(.URL)
                    TextField("API key (optional)", text: $apiKey)
                    HStack {
                        Button(probing ? "Testing…" : "Test Connection") { probe() }
                            .disabled(probing || baseURL.isEmpty)
                        if let probeResult {
                            Text(probeResult)
                                .font(.caption)
                                .foregroundStyle(Color.inkMuted)
                        }
                    }
                }
                Section("In OpenCode") {
                    TextField("Provider id", text: $providerID, prompt: Text("vllm"))
                        .font(.body.monospaced())
                        .disabled(existing != nil)
                    TextField("Display name", text: $name, prompt: Text("vLLM (home)"))
                    TextField("Adapter package", text: $npm, prompt: Text(ModelSource.defaultNPM))
                        .font(.body.monospaced())
                    Text("The provider id is the key under \"provider\" in opencode.json and the first half of every model id. Models show as \"\(providerID.isEmpty ? "vllm" : providerID)/<model>\".")
                        .font(.caption)
                        .foregroundStyle(Color.inkFaint)
                }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(Color.negative)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Add Source" : "Edit Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(providerID.isEmpty || baseURL.isEmpty)
                }
            }
            .onAppear(perform: populate)
        }
        .frame(minWidth: 480, minHeight: 380)
    }

    private func populate() {
        guard let existing else { return }
        providerID = existing.providerID
        name = existing.name
        baseURL = existing.baseURL
        apiKey = existing.apiKey ?? ""
        npm = existing.npm ?? ""
    }

    private var draft: ModelSource {
        var source = ModelSource(
            id: existing?.id ?? UUID().uuidString,
            providerID: providerID, name: name, baseURL: baseURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            npm: npm.isEmpty ? nil : npm,
            enabled: existing?.enabled
        )
        source.lastChecked = existing?.lastChecked
        source.lastError = existing?.lastError
        source.lastModelCount = existing?.lastModelCount
        return source
    }

    private func probe() {
        let source = draft
        if let problem = source.validationProblem {
            self.problem = problem
            return
        }
        problem = nil
        probing = true
        probeResult = nil
        Task {
            do {
                let models = try await ModelSourceStore.fetch(source)
                let withLimits = models.filter { $0.contextLimit != nil }.count
                probeResult = "\(models.count) models, \(withLimits) with a context limit."
            } catch {
                probeResult = error.localizedDescription
            }
            probing = false
        }
    }

    private func save() {
        if let problem = store.save(draft) {
            self.problem = problem
        } else {
            dismiss()
        }
    }
}

/// The question the whole feature turns on: here is what would change in
/// your config; write it?
struct ModelSyncReviewSheet: View {
    @ObservedObject var store: ModelSourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingJSON: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Update opencode.json?")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text("Each provider block below is replaced whole. Everything else in the file stays as it is.")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            }
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(store.pending) { plan in
                        planSection(plan)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            Divider().overlay(Color.hairline)
            HStack {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Color.inkFaint)
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply and Restart OpenCode") {
                    store.applyPending()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.pending.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 420, idealHeight: 600)
        .background(Color.canvas)
    }

    private var footer: String {
        if store.activeTurns() > 0 {
            return "A turn is running: the file is written now, OpenCode restarts when you say so."
        }
        return "Backup kept as opencode.json.bak-remote."
    }

    private func planSection(_ plan: ModelSyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(plan.providerID)
                    .font(.headline.monospaced())
                    .foregroundStyle(Color.ink)
                if plan.isNewProvider {
                    Text("new provider")
                        .font(.caption2.smallCaps())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(Color.inkMuted)
                }
                Spacer()
                Text("\(plan.modelCount) models after")
                    .font(.caption)
                    .foregroundStyle(Color.inkFaint)
            }
            if !plan.providerChanges.isEmpty {
                group("Provider", plan.providerChanges.map { ($0, [String]()) }, color: .inkMuted)
            }
            if !plan.added.isEmpty {
                group("Added", plan.added.map { ($0.modelID, $0.details) }, color: .positive)
            }
            if !plan.changed.isEmpty {
                group("Updated", plan.changed.map { ($0.modelID, $0.details) }, color: .clay)
            }
            if !plan.removed.isEmpty {
                group("Removed (no longer served)", plan.removed.map { ($0, [String]()) }, color: .negative)
            }
            if plan.unchanged > 0 {
                Text("\(plan.unchanged) unchanged")
                    .font(.caption)
                    .foregroundStyle(Color.inkFaint)
            }
            DisclosureGroup(
                isExpanded: Binding(
                    get: { showingJSON.contains(plan.providerID) },
                    set: { open in
                        if open { showingJSON.insert(plan.providerID) } else { showingJSON.remove(plan.providerID) }
                    }
                )
            ) {
                ScrollView(.horizontal) {
                    Text(plan.after)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.control))
                .frame(maxHeight: 320)
            } label: {
                Text("Show the block as it will be written")
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.block))
    }

    private func group(_ title: String, _ rows: [(String, [String])], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.0)
                        .font(.callout.monospaced())
                        .foregroundStyle(Color.ink)
                    if !row.1.isEmpty {
                        Text(row.1.joined(separator: "; "))
                            .font(.caption)
                            .foregroundStyle(Color.inkMuted)
                    }
                }
            }
        }
    }
}
