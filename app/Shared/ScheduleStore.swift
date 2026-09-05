import RemoteKit
import SwiftUI

/// The client's copy of the Mac's scheduled task list. The Mac owns the
/// list, the clock, and every run's history; each operation here answers
/// with the complete regenerated list, so this store only ever replaces
/// its copy with the Mac's truth, never edits it in place.
@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var tasks: [ScheduledTask] = []
    /// The Mac's timezone identifier: fire times are that machine's
    /// wall-clock times, and rendering them in any other zone would lie.
    @Published private(set) var timeZone: String?
    @Published private(set) var loading = false
    /// Why the list is empty when that's news; an older Mac companion
    /// answers with its "older version" message, which reads as "update
    /// the Mac app to use schedules".
    @Published private(set) var error: String?

    private var loaded = false
    private let makeLink: () -> CompanionLink

    init(makeLink: @escaping () -> CompanionLink = { CompanionLink() }) {
        self.makeLink = makeLink
    }

    var macTimeZone: TimeZone? {
        timeZone.flatMap(TimeZone.init(identifier:))
    }

    func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        await load()
    }

    func load() async {
        await send(Wire.Request(kind: "schedule.list"))
    }

    func save(_ task: ScheduledTask) async {
        var request = Wire.Request(kind: "schedule.save")
        request.task = task
        await send(request)
    }

    func delete(_ id: String) async {
        var request = Wire.Request(kind: "schedule.delete")
        request.taskID = id
        await send(request)
    }

    func runNow(_ id: String) async {
        var request = Wire.Request(kind: "schedule.run")
        request.taskID = id
        await send(request)
    }

    private func send(_ request: Wire.Request) async {
        loading = true
        error = nil
        defer { loading = false }
        for await event in makeLink().run(request) {
            switch event.kind {
            case "schedules":
                tasks = event.tasks ?? []
                timeZone = event.timeZone
                loaded = true
            case "failed":
                error = event.text
            default:
                break
            }
        }
    }

    #if DEBUG
    /// A plausible list for tools/uiharness, which has no Mac to ask.
    func mockForHarness() {
        var triage = ScheduledTask(id: "t1", name: "Nightly triage", project: "/Users/t/app")
        triage.prompt = "Review open issues and draft replies."
        triage.cron = "0 9 * * 1-5"
        triage.lastRun = Date().addingTimeInterval(-86_400)
        triage.lastOutcome = "succeeded"
        triage.lastSessionID = "s1"
        triage.nextFire = Date().addingTimeInterval(7_200)
        var once = ScheduledTask(id: "t2", name: "Migrate the schema", project: "/Users/t/site")
        once.prompt = "Run the pending migration and verify."
        once.runAt = Date().addingTimeInterval(3_600)
        once.nextFire = once.runAt
        tasks = [triage, once]
        timeZone = TimeZone.current.identifier
        loaded = true
    }
    #endif
}
