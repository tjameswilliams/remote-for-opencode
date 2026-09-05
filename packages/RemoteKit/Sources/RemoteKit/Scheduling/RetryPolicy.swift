import Foundation

/// The fixed retry and catch-up rules for scheduled task runs. Pure tables
/// and predicates so the behavior is unit-tested; the Mac's scheduler is
/// just the loop around them.
public enum RetryPolicy {
    /// Waits before retry 1, 2, and 3. A transient failure past the last
    /// delay is final. Deliberately generous: the first delay also has to
    /// outlast an OpenCode restart after the Mac wakes.
    public static let delays: [TimeInterval] = [30, 120, 480]

    /// HTTP statuses worth retrying without asking anyone: timeouts, rate
    /// limits, and server-side trouble. Client mistakes (400, 401, 403,
    /// 404, 422) are not here on purpose; retrying a bad model id three
    /// times just delays the bad news.
    public static func isTransientHTTPStatus(_ status: Int) -> Bool {
        [408, 425, 429, 500, 502, 503, 504, 529].contains(status)
    }

    /// Classifies a `session.error` payload from OpenCode's event stream.
    /// The shapes vary across OpenCode versions, so anything unrecognized
    /// is NOT transient: a fatal error must never loop through three extra
    /// attempts before the user hears about it.
    public static func isTransientSessionError(name: String?, message: String?) -> Bool {
        let haystack = [name, message].compactMap { $0?.lowercased() }.joined(separator: " ")
        let markers = ["rate limit", "overloaded", "capacity", "429", "529", "temporarily"]
        return markers.contains { haystack.contains($0) }
    }

    public enum Disposition: Equatable, Sendable {
        case notDue
        case runLate
        case missed
    }

    /// The catch-up decision for a fire time the Mac may have slept
    /// through: still in the future means not due, less than `grace` late
    /// means run it now, later than that means the moment has passed and
    /// the user is told instead.
    public static func disposition(
        nextFire: Date, now: Date, grace: TimeInterval = 3600
    ) -> Disposition {
        let lateness = now.timeIntervalSince(nextFire)
        if lateness < 0 { return .notDue }
        return lateness <= grace ? .runLate : .missed
    }
}
