import AppKit
import Foundation
import OSLog
import RemoteKit

/// Runs scheduled tasks: prompts the user asked this Mac to fire later,
/// once or on a cron beat, with a chosen model. The Mac is the natural
/// place for this; it is the machine that stays on next to OpenCode.
///
/// A fired task is an ordinary headless turn through LiveTurns with no
/// sink, so everything unattended runs already need exists: events buffer
/// for a late resume, and permissions, questions, failures, and completion
/// escalate to a push. The one thing added here is the retry loop: a
/// transient failure (OpenCode restarting, a lost event stream, a provider
/// rate limit) retries up to three times on RetryPolicy's backoff before
/// anyone is bothered.
@MainActor
final class Scheduler: ObservableObject {
    static let changed = Notification.Name("Scheduler.changed")

    @Published private(set) var tasks: [ScheduledTask] = []

    private let adapter: () -> OpenCodeAdapter?
    private let logger = Logger(subsystem: "com.timwilliams.opencodego", category: "scheduler")
    private static let key = "scheduledTasks"
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Task ids whose run is still going; a cron beat that lands on one is
    /// recorded as missed rather than piling a second run onto the first.
    private var running: Set<String> = []

    enum ScheduleError: LocalizedError {
        case emptyPrompt
        case missingProject
        case ambiguousTiming

        var errorDescription: String? {
            switch self {
            case .emptyPrompt: return "The scheduled task has no prompt."
            case .missingProject: return "The scheduled task has no project."
            case .ambiguousTiming:
                return "A scheduled task needs a repeat schedule or a run date, not both."
            }
        }
    }

    init(adapter: @escaping () -> OpenCodeAdapter?) {
        self.adapter = adapter
        if let data = UserDefaults.standard.data(forKey: Self.key),
            let stored = try? JSONDecoder().decode([ScheduledTask].self, from: data)
        {
            tasks = stored
        }
    }

    /// Catch up on anything that came due while the app was closed, then
    /// arm the loop. Wake from sleep re-runs the same pair: a lid closed
    /// across a fire time must resolve the moment it opens, not a minute
    /// later.
    func start() {
        fireDue()
        rearm()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.fireDue()
                    self?.rearm()
                }
            }
        }
    }

    // MARK: - CRUD (all return the regenerated list, the server's truth)

    func list() -> [ScheduledTask] { tasks }

    var timeZoneIdentifier: String { TimeZone.current.identifier }

    @discardableResult
    func save(_ incoming: ScheduledTask) throws -> [ScheduledTask] {
        var task = incoming
        guard let prompt = task.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty
        else { throw ScheduleError.emptyPrompt }
        guard let project = task.project, !project.isEmpty else {
            throw ScheduleError.missingProject
        }
        switch (task.cron, task.runAt) {
        case (nil, nil), (.some, .some):
            throw ScheduleError.ambiguousTiming
        case let (cron?, nil):
            _ = try CronSchedule.parse(cron)
        case (nil, .some):
            break
        }

        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            // History belongs to the Mac; an edit from a client must not
            // erase what already ran.
            let old = tasks[index]
            task.created = old.created
            task.lastRun = old.lastRun
            task.lastOutcome = old.lastOutcome
            task.lastError = old.lastError
            task.lastSessionID = old.lastSessionID
            task.lastTurnID = old.lastTurnID
            task.nextFire = upcomingFire(for: task, after: Date())
            tasks[index] = task
        } else {
            task.created = Date()
            task.nextFire = upcomingFire(for: task, after: Date())
            tasks.append(task)
        }
        persist()
        rearm()
        return tasks
    }

    @discardableResult
    func delete(id: String) -> [ScheduledTask] {
        tasks.removeAll { $0.id == id }
        persist()
        rearm()
        return tasks
    }

    /// Fires now, outside the schedule: the next cron beat is untouched. A
    /// task already running just keeps running; the list says so.
    @discardableResult
    func runNow(id: String) -> [ScheduledTask] {
        if let task = tasks.first(where: { $0.id == id }), !running.contains(id) {
            fire(task, advancing: false)
        }
        return tasks
    }

    // MARK: - The clock

    /// One arming loop for all tasks: fire whatever is due, then sleep
    /// until the earliest next fire, capped at a minute. The cap is what
    /// makes sleep and clock changes harmless; no arithmetic here has to
    /// survive them, because the loop rechecks against the wall clock at
    /// least that often.
    private func rearm() {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                let upcoming = self.tasks
                    .filter(\.isEnabled)
                    .compactMap(\.nextFire)
                    .filter { $0 > now }
                    .min()
                let wait = upcoming.map { min($0.timeIntervalSince(now), 60) } ?? 60
                try? await Task.sleep(for: .seconds(max(1, wait)))
                guard !Task.isCancelled else { return }
                self.fireDue()
            }
        }
    }

    /// Resolve every task whose fire time has arrived, or passed while the
    /// Mac was off or asleep: on time or within the grace window it runs
    /// (late is better than silently never), past the window it is marked
    /// missed and the phone is told.
    private func fireDue() {
        let now = Date()
        for task in tasks {
            guard task.isEnabled, let due = task.nextFire else { continue }
            switch RetryPolicy.disposition(nextFire: due, now: now) {
            case .notDue:
                continue
            case .runLate:
                if running.contains(task.id) {
                    markMissed(id: task.id, reason: "The previous run was still going.")
                } else {
                    fire(task, advancing: true)
                }
            case .missed:
                markMissed(
                    id: task.id,
                    reason: "The Mac wasn't available at the scheduled time."
                )
            }
        }
    }

    private func markMissed(id: String, reason: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].lastOutcome = "missed"
        tasks[index].lastError = reason
        advance(at: index)
        persist()
        logger.notice("schedule missed: \(reason, privacy: .public)")
        Attention.publish(kind: "missed", sessionID: nil, directory: tasks[index].project)
    }

    /// Move a task past the fire that was just consumed: a cron task gets
    /// its next beat, a one-shot is disabled but kept so its history and
    /// session remain reachable.
    private func advance(at index: Int) {
        if tasks[index].cron != nil {
            tasks[index].nextFire = upcomingFire(for: tasks[index], after: Date())
        } else {
            tasks[index].enabled = false
            tasks[index].nextFire = nil
        }
    }

    private func upcomingFire(for task: ScheduledTask, after date: Date) -> Date? {
        guard task.isEnabled else { return nil }
        if let cron = task.cron, let schedule = try? CronSchedule.parse(cron) {
            return schedule.nextFire(after: date, calendar: Calendar.current)
        }
        // A one-shot's fire time stands even when it is already past;
        // fireDue's grace window decides whether it still runs.
        return task.runAt
    }

    // MARK: - Firing

    private func fire(_ task: ScheduledTask, advancing: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let turnID = UUID().uuidString
        running.insert(task.id)
        tasks[index].lastRun = Date()
        tasks[index].lastOutcome = "running"
        tasks[index].lastError = nil
        tasks[index].lastSessionID = nil
        tasks[index].lastTurnID = turnID
        if advancing { advance(at: index) }
        persist()
        logger.notice("firing scheduled task \(task.id, privacy: .public)")

        // The same request an interactive prompt would send; absent model
        // fields fall through to the Mac's default inside TurnRunner. Each
        // fire starts a fresh session so runs never contaminate each other.
        var request = Wire.Request(kind: "prompt")
        request.turn = turnID
        request.project = task.project
        request.text = task.prompt
        request.providerID = task.providerID
        request.modelID = task.modelID
        request.agent = task.agent

        let adapter = self.adapter
        LiveTurns.shared.start(turnID, directory: task.project, sink: nil) { [weak self] emit in
            let outcome = await Scheduler.runWithRetries(request, adapter: adapter, emit: emit)
            await self?.finish(taskID: task.id, turnID: turnID, outcome: outcome)
        }
    }

    private struct RunOutcome {
        var succeeded: Bool
        var error: String?
        var sessionID: String?
    }

    /// Collects what the event filter learns across one attempt. A class
    /// because TurnRunner's emit closure needs shared mutable state; every
    /// touch happens on the main actor, where TurnRunner emits.
    private final class Attempt {
        var sessionID: String?
        /// A `failed` held back until its `done` says whether to retry.
        var failure: Wire.Event?
        var retrying = false
    }

    /// TurnRunner.run, wrapped in the transient retry loop. Each attempt
    /// re-resolves the adapter (a restarted OpenCode is a new port) and
    /// filters the emitted events: a transient `failed` with retries left
    /// is swallowed together with its `done`, so nobody watching the turn
    /// sees a failure that is about to be retracted and no premature push
    /// goes out. Later attempts reuse the session the first one created;
    /// the prompt's context lives there.
    private static func runWithRetries(
        _ base: Wire.Request, adapter: @escaping () -> OpenCodeAdapter?,
        emit: @escaping (Wire.Event) -> Void
    ) async -> RunOutcome {
        var request = base
        for attempt in 0...RetryPolicy.delays.count {
            let lastAttempt = attempt == RetryPolicy.delays.count
            if let live = adapter() {
                let state = Attempt()
                await TurnRunner.run(request, adapter: live) { event in
                    if event.kind == "status", let session = event.session {
                        state.sessionID = session
                    }
                    switch event.kind {
                    case "failed":
                        state.failure = event
                    case "done":
                        if let failure = state.failure, failure.transient == true, !lastAttempt {
                            state.retrying = true
                        } else {
                            if let failure = state.failure { emit(failure) }
                            emit(event)
                        }
                    default:
                        emit(event)
                    }
                }
                if let session = state.sessionID { request.session = session }
                if !state.retrying {
                    if let failure = state.failure {
                        return RunOutcome(
                            succeeded: false, error: failure.text, sessionID: state.sessionID
                        )
                    }
                    return RunOutcome(succeeded: true, sessionID: state.sessionID)
                }
            } else if lastAttempt {
                // Out of patience and OpenCode never came back; now it is
                // a real failure, delivered like any other.
                var failed = Wire.Event(kind: "failed")
                failed.text = "OpenCode wasn't running on your Mac."
                emit(failed)
                emit(Wire.Event(kind: "done"))
                return RunOutcome(succeeded: false, error: failed.text, sessionID: request.session)
            }
            if !lastAttempt {
                try? await Task.sleep(for: .seconds(RetryPolicy.delays[attempt]))
            }
        }
        // Unreachable: the last loop pass always returns.
        return RunOutcome(succeeded: false, error: "The scheduled run never completed.")
    }

    private func finish(taskID: String, turnID: String, outcome: RunOutcome) {
        running.remove(taskID)
        // The task may have been deleted or re-fired while this run was
        // going; only the run the history row still points at may write it.
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
            tasks[index].lastTurnID == turnID
        else { return }
        tasks[index].lastOutcome = outcome.succeeded ? "succeeded" : "failed"
        tasks[index].lastError = outcome.error
        tasks[index].lastSessionID = outcome.sessionID
        persist()
        logger.notice(
            "scheduled task \(taskID, privacy: .public) \(outcome.succeeded ? "succeeded" : "failed", privacy: .public)"
        )
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
