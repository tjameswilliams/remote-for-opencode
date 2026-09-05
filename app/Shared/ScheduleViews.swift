import RemoteKit
import SwiftUI

/// The scheduled tasks screen: the Mac's list, an editor, and each task's
/// last-run history. Pure SwiftUI over ScheduleStore, so the phone and the
/// desktop workspace share it; navigation stays platform-owned through the
/// `openSession` closure (the phone pushes onto its stack, the workspace
/// changes its selection).
///
/// Laid out as a page rather than a settings list: a title, a search
/// field, status filters, then the tasks. Clicking a task opens its latest
/// run's output when there is one; the switch and the menu on each row
/// pause, run, edit, and delete without leaving the page.
struct ScheduleListView: View {
    @ObservedObject var store: ScheduleStore
    @ObservedObject var models: ModelStore
    var projects: [Project]
    var openSession: (Session) -> Void

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case paused = "Paused"
        case completed = "Completed"
        var id: String { rawValue }
    }

    /// What the editor sheet opens on: an existing task, or a new one
    /// seeded from a suggestion (nil template is a blank task).
    private enum EditorTarget: Identifiable {
        case edit(ScheduledTask)
        case new(template: ScheduledTask?)
        var id: String {
            switch self {
            case let .edit(task): return "edit:\(task.id)"
            case let .new(template): return "new:\(template?.id ?? "")"
            }
        }
    }

    @State private var editor: EditorTarget?
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var pendingDelete: ScheduledTask?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(macOS)
                header
                searchField
                #endif
                filters
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Color.inkMuted)
                }
                taskList
                if let zone = store.macTimeZone, zone.identifier != TimeZone.current.identifier {
                    Text("Times are your Mac's local time (\(zone.identifier)).")
                        .font(.caption)
                        .foregroundStyle(Color.inkFaint)
                }
                if search.isEmpty, filter == .all {
                    suggestions
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, pagePadding)
            .padding(.top, pageTop)
            .padding(.bottom, 32)
        }
        .background(Color.canvas)
        .navigationTitle("Scheduled Tasks")
        #if os(iOS)
        .searchable(text: $search, prompt: "Search scheduled tasks")
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .new(template: nil)
                } label: {
                    Label("New Task", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case let .edit(task):
                ScheduleEditorView(store: store, models: models, projects: projects, existing: task)
            case let .new(template):
                ScheduleEditorView(
                    store: store, models: models, projects: projects, existing: nil,
                    template: template
                )
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete.map { title($0) } ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { task in
            Button("Delete", role: .destructive) {
                Task { await store.delete(task.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The task and its run history go away. Sessions its runs produced stay in the project.")
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

    // MARK: - Header and search

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scheduled tasks")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("Prompts your Mac runs on its own, at the times you set, even while your other devices are away.")
                .font(.body)
                .foregroundStyle(Color.inkMuted)
        }
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.inkFaint)
            TextField("Search scheduled tasks", text: $search)
                .textFieldStyle(.plain)
                .foregroundStyle(Color.ink)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.inkFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.hairline))
    }

    private var filters: some View {
        HStack(spacing: 4) {
            ForEach(Filter.allCases) { candidate in
                Button {
                    withAnimation(Motion.easeOut(Motion.feedback)) { filter = candidate }
                } label: {
                    Text(candidate.rawValue)
                        .font(.callout.weight(filter == candidate ? .medium : .regular))
                        .foregroundStyle(filter == candidate ? Color.ink : Color.inkMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            filter == candidate ? Color.surfaceRaised : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.control)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == candidate ? .isSelected : [])
            }
            Spacer()
        }
    }

    // MARK: - The list

    private var shown: [ScheduledTask] {
        store.tasks.filter { task in
            switch filter {
            case .all: break
            case .active: guard status(task) == .active else { return false }
            case .paused: guard status(task) == .paused else { return false }
            case .completed: guard status(task) == .completed else { return false }
            }
            guard !search.isEmpty else { return true }
            let haystack = [task.name, task.prompt, task.project].compactMap { $0 }
            return haystack.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    @ViewBuilder
    private var taskList: some View {
        if shown.isEmpty {
            if store.loading, store.tasks.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if store.error == nil {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.vertical, 8)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, task in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.hairline)
                            .frame(height: 1)
                            .padding(.leading, 40)
                    }
                    row(task)
                }
            }
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.block))
        }
    }

    private var emptyText: String {
        if !search.isEmpty { return "No scheduled tasks match \"\(search)\"." }
        switch filter {
        case .all: return "Nothing scheduled yet. Start from a suggestion below, or add a task of your own."
        case .active: return "No active tasks."
        case .paused: return "No paused tasks."
        case .completed: return "No completed tasks. One-time tasks land here after they run."
        }
    }

    private func row(_ task: ScheduledTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusDot(task)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(task))
                    .font(.body.weight(.medium))
                    .foregroundStyle(status(task) == .paused ? Color.inkMuted : Color.ink)
                    .lineLimit(1)
                Text(detail(task))
                    .font(.callout)
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(2)
                if let outcome = task.lastOutcome {
                    HStack(spacing: 4) {
                        Text(historyText(task, outcome: outcome))
                            .lineLimit(2)
                        if session(of: task) != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(outcome == "failed" ? Color.negative : Color.inkFaint)
                }
            }
            Spacer(minLength: 12)
            #if os(macOS)
            // The phone's switch is wide enough to crowd the text off the
            // row; there, pausing lives in the menu.
            if status(task) != .completed {
                Toggle("Enabled", isOn: enabledBinding(task))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help(task.isEnabled ? "Pause" : "Resume")
            }
            #endif
            Menu {
                if session(of: task) != nil {
                    Button("Open Latest Run", systemImage: "text.alignleft") { open(task) }
                }
                Button("Run Now", systemImage: "play.fill") {
                    Task { await store.runNow(task.id) }
                }
                if status(task) != .completed {
                    Button(
                        task.isEnabled ? "Pause" : "Resume",
                        systemImage: task.isEnabled ? "pause" : "play"
                    ) {
                        setEnabled(task, !task.isEnabled)
                    }
                }
                Button("Edit…", systemImage: "pencil") { editor = .edit(task) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDelete = task
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
            .accessibilityLabel("Task actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { open(task) }
        .contextMenu {
            Button("Run Now") { Task { await store.runNow(task.id) } }
            if status(task) != .completed {
                Button(task.isEnabled ? "Pause" : "Resume") {
                    setEnabled(task, !task.isEnabled)
                }
            }
            Button("Edit…") { editor = .edit(task) }
            Button("Delete", role: .destructive) { pendingDelete = task }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title(task)), \(detail(task))")
        .accessibilityHint(session(of: task) != nil ? "Opens the latest run" : "Opens the editor")
    }

    /// Hollow until a task has run; then the last outcome's colour.
    @ViewBuilder
    private func statusDot(_ task: ScheduledTask) -> some View {
        if let outcome = task.lastOutcome {
            Circle()
                .fill(outcomeColor(outcome))
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .strokeBorder(Color.inkFaint, lineWidth: 1.5)
                .frame(width: 10, height: 10)
        }
    }

    /// The row's click: the latest run's transcript when there is one,
    /// otherwise the editor (a task that never ran has nothing to read).
    private func open(_ task: ScheduledTask) {
        if let session = session(of: task) {
            openSession(session)
        } else {
            editor = .edit(task)
        }
    }

    private enum Status { case active, paused, completed }

    /// A one-shot that has fired (or been missed) is finished, whatever
    /// its enabled flag says; everything else is active or paused.
    private func status(_ task: ScheduledTask) -> Status {
        if task.runAt != nil, task.lastOutcome != nil { return .completed }
        return task.isEnabled ? .active : .paused
    }

    /// The session a run produced, when there is one to open.
    private func session(of task: ScheduledTask) -> Session? {
        guard let id = task.lastSessionID else { return nil }
        return Session(
            id: id, title: task.name ?? task.prompt, directory: task.project
        )
    }

    private func enabledBinding(_ task: ScheduledTask) -> Binding<Bool> {
        Binding(get: { task.isEnabled }, set: { setEnabled(task, $0) })
    }

    private func setEnabled(_ task: ScheduledTask, _ on: Bool) {
        var changed = task
        changed.enabled = on
        Task { await store.save(changed) }
    }

    private func title(_ task: ScheduledTask) -> String {
        task.name ?? task.prompt ?? "Untitled task"
    }

    /// "project · Weekdays at 9:00 AM · Next run in 56 minutes".
    private func detail(_ task: ScheduledTask) -> String {
        var parts: [String] = []
        if let project = task.project, !project.isEmpty {
            parts.append((project as NSString).lastPathComponent)
        }
        parts.append(ScheduleText.summary(task))
        switch status(task) {
        case .active:
            if let next = task.nextFire {
                parts.append("Next run \(next.formatted(.relative(presentation: .named)))")
            }
        case .paused:
            parts.append("Paused")
        case .completed:
            parts.append("Completed")
        }
        return parts.joined(separator: " · ")
    }

    private func historyText(_ task: ScheduledTask, outcome: String) -> String {
        var text: String
        switch outcome {
        case "running": text = "Running now"
        case "succeeded": text = "Last run succeeded"
        case "failed": text = "Last run failed"
        case "missed": text = "Last run missed"
        default: text = outcome.capitalized
        }
        if outcome != "running", let ran = task.lastRun {
            text += " \(ran.formatted(.relative(presentation: .named)))"
        }
        if outcome == "failed" || outcome == "missed", let reason = task.lastError {
            text += ": \(reason)"
        }
        return text
    }

    private func outcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "succeeded": return .positive
        case "failed": return .negative
        case "missed": return .caution
        default: return .clay
        }
    }

    // MARK: - Suggestions

    /// Starting points, each a complete task minus the project. Picking
    /// one opens the editor with everything filled in, so the only
    /// question left is which repo.
    private struct Suggestion: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let name: String
        let cron: String
        let blurb: String
        let prompt: String

        var template: ScheduledTask {
            var task = ScheduledTask(id: id, name: name)
            task.prompt = prompt
            task.cron = cron
            return task
        }
    }

    private static let suggested: [Suggestion] = [
        Suggestion(
            id: "suggest-triage", symbol: "sun.max", tint: .clay,
            name: "Morning triage", cron: "0 9 * * 1-5",
            blurb: "Start each weekday knowing what needs attention in this repo",
            prompt: "Review the open issues and pull requests in this repository. Summarise what needs attention today, flag anything blocked or stale, and draft replies where you can."
        ),
        Suggestion(
            id: "suggest-weekly", symbol: "doc.text", tint: .positive,
            name: "Weekly review", cron: "0 16 * * 5",
            blurb: "Turn the week's commits into a concise status update every Friday",
            prompt: "Summarise this week's commits and open work into a short status update: what shipped, what is in progress, and what is at risk."
        ),
        Suggestion(
            id: "suggest-health", symbol: "checkmark.shield", tint: .caution,
            name: "Test health monitor", cron: "0 7 * * 1-5",
            blurb: "Run the test suite each weekday morning and investigate anything that fails",
            prompt: "Run the full test suite. If anything fails, investigate the cause and propose a fix, but do not push."
        ),
    ]

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggestions")
                .font(.headline)
                .foregroundStyle(Color.inkMuted)
                .padding(.top, 12)
                .padding(.bottom, 8)
            ForEach(Self.suggested) { suggestion in
                Button {
                    editor = .new(template: suggestion.template)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: suggestion.symbol)
                            .font(.body)
                            .foregroundStyle(suggestion.tint)
                            .frame(width: 20)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(suggestion.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Color.ink)
                                Text(ScheduleText.summary(suggestion.template))
                                    .font(.callout)
                                    .foregroundStyle(Color.inkFaint)
                            }
                            Text(suggestion.blurb)
                                .font(.callout)
                                .foregroundStyle(Color.inkMuted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Create or edit one scheduled task. Presets cover the friendly schedules
/// and compile to plain cron; Custom exposes the expression itself with a
/// live preview of its next fires, so the vixie day rule can never
/// surprise silently.
struct ScheduleEditorView: View {
    @ObservedObject var store: ScheduleStore
    @ObservedObject var models: ModelStore
    var projects: [Project]
    var existing: ScheduledTask?
    /// A starting point for a new task (a suggestion): filled in like an
    /// existing task, but saved under a fresh id as "New Task".
    var template: ScheduledTask? = nil

    @Environment(\.dismiss) private var dismiss

    private enum Timing: String, CaseIterable {
        case once = "Once"
        case hourly = "Hourly"
        case daily = "Daily"
        case weekdays = "Weekdays"
        case weekly = "Weekly"
        case custom = "Custom"
    }

    @State private var name = ""
    @State private var project = ""
    @State private var prompt = ""
    /// Local pick, deliberately NOT ModelStore.selected: that one is the
    /// composer's sticky default and a task must not change it.
    @State private var model: AgentModel?
    @State private var readOnly = false
    @State private var timing: Timing = .once
    @State private var runAt = Date().addingTimeInterval(3600)
    /// Time of day for the repeating presets.
    @State private var presetTime = Date()
    /// Cron weekday (0 is Sunday) for the Weekly preset.
    @State private var weekday = 1
    @State private var customCron = "0 9 * * 1-5"
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Name (optional)", text: $name)
                    Picker("Project", selection: $project) {
                        Text("Choose…").tag("")
                        ForEach(projects) { candidate in
                            Text(candidate.displayName).tag(candidate.worktree)
                        }
                    }
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("Run with") {
                    TaskModelMenu(models: models, selection: $model)
                    Toggle("Plan agent (read-only)", isOn: $readOnly)
                }
                Section("When") {
                    Picker("Repeats", selection: $timing) {
                        ForEach(Timing.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    switch timing {
                    case .once:
                        DatePicker("At", selection: $runAt)
                    case .hourly:
                        DatePicker(
                            "At minute", selection: $presetTime,
                            displayedComponents: .hourAndMinute
                        )
                    case .daily, .weekdays:
                        DatePicker(
                            "At", selection: $presetTime, displayedComponents: .hourAndMinute
                        )
                    case .weekly:
                        Picker("On", selection: $weekday) {
                            ForEach(0..<7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day]).tag(day)
                            }
                        }
                        DatePicker(
                            "At", selection: $presetTime, displayedComponents: .hourAndMinute
                        )
                    case .custom:
                        TextField("Cron (minute hour day month weekday)", text: $customCron)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    preview
                }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(Color.negative)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Task" : "Edit Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || project.isEmpty || trimmedPrompt.isEmpty)
                }
            }
            .task {
                await models.loadIfNeeded()
                populate()
            }
        }
    }

    /// The next few fires the chosen schedule produces, rendered in the
    /// Mac's timezone: the honest answer to "did I write that right".
    @ViewBuilder
    private var preview: some View {
        if let cron = compiledCron {
            switch parsedFires(cron) {
            case let .success(fires) where !fires.isEmpty:
                Text(
                    "Runs "
                        + fires.map { ScheduleText.fire($0, in: store.macTimeZone) }
                        .joined(separator: ", ")
                )
                .font(.caption)
                .foregroundStyle(Color.inkMuted)
            case .success:
                Text("That schedule never fires.")
                    .font(.caption)
                    .foregroundStyle(Color.caution)
            case let .failure(error):
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(Color.negative)
            }
        }
    }

    private func parsedFires(_ cron: String) -> Result<[Date], Error> {
        do {
            var calendar = Calendar.current
            if let zone = store.macTimeZone { calendar.timeZone = zone }
            let schedule = try CronSchedule.parse(cron)
            return .success(schedule.nextFires(3, after: Date(), calendar: calendar))
        } catch {
            return .failure(error)
        }
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cron expression the current preset stands for; nil for Once.
    private var compiledCron: String? {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: presetTime)
        let hour = comps.hour ?? 9
        let minute = comps.minute ?? 0
        switch timing {
        case .once: return nil
        case .hourly: return "\(minute) * * * *"
        case .daily: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * 1-5"
        case .weekly: return "\(minute) \(hour) * * \(weekday)"
        case .custom: return customCron.trimmingCharacters(in: .whitespaces)
        }
    }

    private func populate() {
        guard let source = existing ?? template else { return }
        name = source.name ?? ""
        project = source.project ?? ""
        prompt = source.prompt ?? ""
        readOnly = source.agent == "plan"
        model = models.models.first {
            $0.providerID == source.providerID && $0.modelID == source.modelID
        }
        if let date = source.runAt {
            timing = .once
            runAt = date
        } else if let cron = source.cron {
            adopt(cron: cron)
        }
    }

    /// An expression one of the presets would have compiled edits as that
    /// preset again, so "Weekdays at 9:00 AM" stays a picker and a time.
    /// Anything else edits as the expression it really is.
    private func adopt(cron: String) {
        customCron = cron
        timing = .custom
        guard let schedule = try? CronSchedule.parse(cron),
              let minute = schedule.minutes.only else { return }
        let anyDay = schedule.daysOfMonth.count == 31 && schedule.months.count == 12
        guard anyDay else { return }
        let allWeekdays = schedule.daysOfWeek.count == 7
        if schedule.hours.count == 24 {
            guard allWeekdays else { return }
            timing = .hourly
            presetTime = time(hour: 0, minute: minute)
            return
        }
        guard let hour = schedule.hours.only else { return }
        presetTime = time(hour: hour, minute: minute)
        if allWeekdays {
            timing = .daily
        } else if schedule.daysOfWeek == [1, 2, 3, 4, 5] {
            timing = .weekdays
        } else if let day = schedule.daysOfWeek.only {
            timing = .weekly
            weekday = day
        }
    }

    private func time(hour: Int, minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: Date()
        ) ?? Date()
    }

    private func save() {
        var task = ScheduledTask(id: existing?.id ?? UUID().uuidString)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        task.name = trimmedName.isEmpty ? nil : trimmedName
        task.project = project
        task.prompt = trimmedPrompt
        task.providerID = model?.providerID
        task.modelID = model?.modelID
        task.agent = readOnly ? "plan" : nil
        task.enabled = existing?.enabled
        if let cron = compiledCron {
            if case let .failure(error) = parsedFires(cron) {
                problem = error.localizedDescription
                return
            }
            task.cron = cron
        } else {
            task.runAt = runAt
        }
        saving = true
        problem = nil
        Task {
            await store.save(task)
            saving = false
            if let error = store.error {
                problem = error
            } else {
                dismiss()
            }
        }
    }
}

/// ModelMenu's twin for a per-task pick: same catalogue, same grouping,
/// but bound locally. ModelMenu itself writes ModelStore.selected, which
/// persists as the composer's device-wide default; a scheduled task
/// choosing a model must not change what the user's next prompt runs on.
struct TaskModelMenu: View {
    @ObservedObject var models: ModelStore
    @Binding var selection: AgentModel?

    private var byProvider: [(provider: String, models: [AgentModel])] {
        Dictionary(grouping: models.models, by: \.provider)
            .map { (provider: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.provider < $1.provider }
    }

    var body: some View {
        HStack {
            Text("Model")
            Spacer()
            Menu {
                Button {
                    selection = nil
                } label: {
                    Label(
                        "Mac's default",
                        systemImage: selection == nil ? "checkmark" : "desktopcomputer"
                    )
                }
                if models.models.count <= 12 {
                    ForEach(models.models) { model in
                        button(for: model)
                    }
                } else {
                    ForEach(byProvider, id: \.provider) { group in
                        Menu(group.provider) {
                            ForEach(group.models) { model in
                                button(for: model)
                            }
                        }
                    }
                }
            } label: {
                Text(selection?.name ?? "Mac's default")
                    .foregroundStyle(Color.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func button(for model: AgentModel) -> some View {
        Button {
            selection = model
        } label: {
            if selection?.id == model.id {
                Label(model.name, systemImage: "checkmark")
            } else {
                Text(model.name)
            }
        }
    }
}

/// Shared wording for schedules: the human summary of a task's timing and
/// fire dates rendered in the Mac's timezone, where they actually happen.
enum ScheduleText {
    static func summary(_ task: ScheduledTask) -> String {
        if task.runAt != nil { return "Once" }
        guard let cron = task.cron, let schedule = try? CronSchedule.parse(cron) else {
            return task.cron ?? ""
        }
        let allHours = schedule.hours.count == 24
        let anyDay = schedule.daysOfMonth.count == 31 && schedule.months.count == 12
        let allWeekdays = schedule.daysOfWeek.count == 7
        if let minute = schedule.minutes.only, allHours, anyDay, allWeekdays {
            return "Hourly at :\(String(format: "%02d", minute))"
        }
        if let minute = schedule.minutes.only, let hour = schedule.hours.only, anyDay {
            let time = timeText(hour: hour, minute: minute)
            if allWeekdays { return "Daily at \(time)" }
            if schedule.daysOfWeek == [1, 2, 3, 4, 5] { return "Weekdays at \(time)" }
            if let day = schedule.daysOfWeek.only {
                return "\(Calendar.current.weekdaySymbols[day])s at \(time)"
            }
        }
        return cron
    }

    static func fire(_ date: Date, in zone: TimeZone?) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        if let zone { style.timeZone = zone }
        return date.formatted(style)
    }

    private static func timeText(hour: Int, minute: Int) -> String {
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.hour = hour
        comps.minute = minute
        guard let date = comps.date else {
            return String(format: "%d:%02d", hour, minute)
        }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private extension Set<Int> {
    var only: Int? { count == 1 ? first : nil }
}
