import Foundation
import Testing

@testable import RemoteKit

/// A schedule that misfires does its damage silently, at night, when
/// nobody is watching the Mac. These tests pin down the parser's rejection
/// messages, the next-fire walk (including the vixie day OR rule), and the
/// DST edges, all in a fixed timezone so the results never depend on the
/// machine running them.
@Suite("Cron schedules")
struct CronScheduleTests {
    /// America/Los_Angeles in 2026: DST starts March 8 (2:00 jumps to
    /// 3:00) and ends November 1 (2:00 falls back to 1:00).
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private func next(_ expression: String, after date: Date) throws -> Date? {
        try CronSchedule.parse(expression).nextFire(after: date, calendar: calendar)
    }

    @Test("Steps, ranges, and lists expand to the right values")
    func parsing() throws {
        #expect(try CronSchedule.parse("*/15 * * * *").minutes == [0, 15, 30, 45])
        #expect(try CronSchedule.parse("0-10/5 * * * *").minutes == [0, 5, 10])
        #expect(try CronSchedule.parse("1,3,5 * * * *").minutes == [1, 3, 5])
        #expect(try CronSchedule.parse("30/10 * * * *").minutes == [30, 40, 50])
        #expect(try CronSchedule.parse("* * * * 1-5").daysOfWeek == [1, 2, 3, 4, 5])
    }

    @Test("Both 0 and 7 mean Sunday in the weekday field")
    func sundayAliases() throws {
        #expect(try CronSchedule.parse("* * * * 7").daysOfWeek == [0])
        #expect(try CronSchedule.parse("* * * * 0").daysOfWeek == [0])
        #expect(try CronSchedule.parse("* * * * 5-7").daysOfWeek == [0, 5, 6])
    }

    @Test("Bad expressions are rejected with the field named")
    func rejection() {
        #expect(throws: CronSchedule.ParseError.fieldCount(4)) {
            try CronSchedule.parse("* * * *")
        }
        #expect(throws: CronSchedule.ParseError.fieldCount(6)) {
            try CronSchedule.parse("* * * * * *")
        }
        #expect(throws: CronSchedule.ParseError.outOfRange(field: "minute", token: "61", low: 0, high: 59)) {
            try CronSchedule.parse("61 * * * *")
        }
        #expect(throws: CronSchedule.ParseError.outOfRange(field: "month", token: "0", low: 1, high: 12)) {
            try CronSchedule.parse("* * * 0 *")
        }
        #expect(throws: CronSchedule.ParseError.badToken(field: "hour", token: "noon")) {
            try CronSchedule.parse("* noon * * *")
        }
        #expect(throws: CronSchedule.ParseError.badToken(field: "minute", token: "10-5")) {
            try CronSchedule.parse("10-5 * * * *")
        }
        #expect(throws: CronSchedule.ParseError.badStep(field: "minute", token: "*/0")) {
            try CronSchedule.parse("*/0 * * * *")
        }
    }

    @Test("Every minute fires on the very next minute, never this one")
    func everyMinute() throws {
        #expect(try next("* * * * *", after: date(2026, 9, 1, 10, 30)) == date(2026, 9, 1, 10, 31))
        // Landing exactly on a matching minute still moves forward: "after"
        // is strict, or a rearm at fire time would fire twice.
        #expect(try next("0 * * * *", after: date(2026, 9, 1, 10, 0)) == date(2026, 9, 1, 11, 0))
    }

    @Test("Minutes and hours roll over into the next day")
    func rollover() throws {
        #expect(try next("*/15 9 * * *", after: date(2026, 9, 1, 9, 50)) == date(2026, 9, 2, 9, 0))
        #expect(try next("0 0 1 * *", after: date(2026, 9, 15)) == date(2026, 10, 1))
    }

    @Test("Weekday ranges skip the weekend")
    func weekdays() throws {
        // September 4, 2026 is a Friday.
        #expect(try next("0 9 * * 1-5", after: date(2026, 9, 4, 10, 0)) == date(2026, 9, 7, 9, 0))
    }

    @Test("Restricted day-of-month and day-of-week match as OR, like vixie cron")
    func vixieDayRule() throws {
        // September 11, 2026 is a Friday; the 13th is a Sunday. With both
        // day fields restricted, whichever comes first wins.
        #expect(try next("0 0 13 * 5", after: date(2026, 9, 11, 1, 0)) == date(2026, 9, 13))
        // With only the weekday restricted, the 13th no longer matters.
        #expect(try next("0 0 * * 5", after: date(2026, 9, 11, 1, 0)) == date(2026, 9, 18))
    }

    @Test("February 29 waits for the next leap year")
    func leapDay() throws {
        #expect(try next("0 0 29 2 *", after: date(2026, 3, 1)) == date(2028, 2, 29))
    }

    @Test("An impossible date gives up instead of searching forever")
    func impossibleDate() throws {
        #expect(try next("0 0 31 2 *", after: date(2026, 9, 1)) == nil)
    }

    @Test("A time erased by spring-forward is skipped, not shifted")
    func springForward() throws {
        // 2:30 does not exist on March 8, 2026 in Los Angeles.
        #expect(try next("30 2 * * *", after: date(2026, 3, 7, 3, 0)) == date(2026, 3, 9, 2, 30))
    }

    @Test("A time repeated by fall-back fires once, at its first occurrence")
    func fallBack() throws {
        // 1:30 happens twice on November 1, 2026 in Los Angeles.
        let first = try #require(try next("30 1 * * *", after: date(2026, 11, 1, 0, 0)))
        #expect(first == date(2026, 11, 1, 1, 30))
        // The fire after it is the next day's, not the repeated 1:30.
        #expect(try next("30 1 * * *", after: first) == date(2026, 11, 2, 1, 30))
    }

    @Test("The preview lists upcoming fires in order")
    func preview() throws {
        let schedule = try CronSchedule.parse("0 12 * * *")
        let fires = schedule.nextFires(3, after: date(2026, 9, 1, 13, 0), calendar: calendar)
        #expect(fires == [date(2026, 9, 2, 12, 0), date(2026, 9, 3, 12, 0), date(2026, 9, 4, 12, 0)])
    }

    @Test("The same question always gets the same answer")
    func determinism() throws {
        let a = try next("17 3 * * 2", after: date(2026, 9, 1, 0, 0))
        let b = try next("17 3 * * 2", after: date(2026, 9, 1, 0, 0))
        #expect(a == b)
        #expect(a != nil)
    }
}
