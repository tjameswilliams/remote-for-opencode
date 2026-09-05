import Foundation
import Testing

@testable import RemoteKit

/// A scheduled run that retries a fatal error wastes twenty minutes before
/// delivering bad news; one that gives up on a rate limit fails work that
/// would have succeeded. The classification tables and the grace-window
/// math are the whole behavior, so they are pinned down exactly.
@Suite("Retry policy")
struct RetryPolicyTests {
    @Test("Three retries, spaced 30 seconds, 2 minutes, 8 minutes")
    func delays() {
        #expect(RetryPolicy.delays == [30, 120, 480])
    }

    @Test("Timeouts, rate limits, and server trouble retry; client mistakes never do")
    func httpStatuses() {
        for status in [408, 425, 429, 500, 502, 503, 504, 529] {
            #expect(RetryPolicy.isTransientHTTPStatus(status), "\(status) should retry")
        }
        for status in [200, 400, 401, 403, 404, 422] {
            #expect(!RetryPolicy.isTransientHTTPStatus(status), "\(status) should not retry")
        }
    }

    @Test("Session errors retry only on recognizable provider-overload wording")
    func sessionErrors() {
        #expect(RetryPolicy.isTransientSessionError(name: nil, message: "Rate limit exceeded"))
        #expect(RetryPolicy.isTransientSessionError(name: "ProviderError", message: "overloaded_error"))
        #expect(RetryPolicy.isTransientSessionError(name: nil, message: "HTTP 529 from provider"))
        #expect(RetryPolicy.isTransientSessionError(name: nil, message: "Temporarily unavailable"))
        // Unrecognized payloads must NOT retry: a fatal error looping three
        // extra times delays the push the user is waiting on.
        #expect(!RetryPolicy.isTransientSessionError(name: "AuthError", message: "Invalid API key"))
        #expect(!RetryPolicy.isTransientSessionError(name: nil, message: "Model not found"))
        #expect(!RetryPolicy.isTransientSessionError(name: nil, message: nil))
    }

    @Test("A fire less than an hour late still runs; later than that is missed")
    func grace() {
        let fire = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(RetryPolicy.disposition(nextFire: fire, now: fire.addingTimeInterval(-60)) == .notDue)
        #expect(RetryPolicy.disposition(nextFire: fire, now: fire) == .runLate)
        #expect(RetryPolicy.disposition(nextFire: fire, now: fire.addingTimeInterval(59 * 60)) == .runLate)
        #expect(RetryPolicy.disposition(nextFire: fire, now: fire.addingTimeInterval(61 * 60)) == .missed)
    }
}
