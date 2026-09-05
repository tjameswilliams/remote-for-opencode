import Foundation

/// A parsed 5-field cron expression (minute hour day-of-month month
/// day-of-week) and the math to find its next fire date. Pure logic with no
/// clock of its own: callers pass the calendar, which fixes the timezone.
/// Scheduled tasks run on the Mac, so production passes `Calendar.current`
/// and schedules read as Mac-local wall-clock times.
///
/// Supported syntax per field: `*`, single numbers, ranges `a-b`, steps
/// `*/n` and `a-b/n`, and comma lists of any of those. Name tokens (`MON`,
/// `JAN`) and macros (`@daily`) are not supported; the editor's presets
/// cover the friendly cases and compile to plain fields.
public struct CronSchedule: Hashable, Sendable {
    public var minutes: Set<Int>
    public var hours: Set<Int>
    /// 1 through 31.
    public var daysOfMonth: Set<Int>
    /// 1 through 12.
    public var months: Set<Int>
    /// 0 through 6, Sunday is 0. A 7 in the expression is folded to 0.
    public var daysOfWeek: Set<Int>

    /// Vixie cron's day rule: when both day fields are restricted, a date
    /// matches if EITHER matches ("0 0 13 * 5" is Friday the 13th OR any
    /// 13th OR any Friday, per the original cron). A field counts as
    /// unrestricted when it starts with `*`, so `*/2` is unrestricted too.
    /// These flags remember which reading applies.
    var dayOfMonthRestricted: Bool
    var dayOfWeekRestricted: Bool

    public enum ParseError: LocalizedError, Equatable {
        case fieldCount(Int)
        case badToken(field: String, token: String)
        case outOfRange(field: String, token: String, low: Int, high: Int)
        case badStep(field: String, token: String)

        public var errorDescription: String? {
            switch self {
            case let .fieldCount(count):
                return "A schedule needs 5 fields (minute hour day month weekday), not \(count)."
            case let .badToken(field, token):
                return "The \(field) field can't read \"\(token)\"."
            case let .outOfRange(field, token, low, high):
                return "\"\(token)\" is outside the \(field) field's range of \(low) to \(high)."
            case let .badStep(field, token):
                return "\"\(token)\" has a step that must be 1 or more."
            }
        }
    }

    public static func parse(_ expression: String) throws -> CronSchedule {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw ParseError.fieldCount(fields.count) }
        let minutes = try values(of: fields[0], field: "minute", low: 0, high: 59)
        let hours = try values(of: fields[1], field: "hour", low: 0, high: 23)
        let dom = try values(of: fields[2], field: "day", low: 1, high: 31)
        let months = try values(of: fields[3], field: "month", low: 1, high: 12)
        // Both 0 and 7 mean Sunday, so the domain runs to 7 and folds after.
        let dow = try values(of: fields[4], field: "weekday", low: 0, high: 7)
        return CronSchedule(
            minutes: minutes,
            hours: hours,
            daysOfMonth: dom,
            months: months,
            daysOfWeek: Set(dow.map { $0 == 7 ? 0 : $0 }),
            dayOfMonthRestricted: !fields[2].hasPrefix("*"),
            dayOfWeekRestricted: !fields[4].hasPrefix("*")
        )
    }

    /// The first instant strictly after `date` that this schedule matches,
    /// or nil when nothing matches within five years (an impossible date
    /// like "0 0 31 2 *" must not search forever). A wall-clock time that a
    /// spring-forward DST jump erases is skipped; a time repeated by a
    /// fall-back jump fires once, at its first occurrence.
    public func nextFire(after date: Date, calendar: Calendar) -> Date? {
        var floor = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        floor.second = 0
        guard let floored = calendar.date(from: floor),
            let first = calendar.date(byAdding: .minute, value: 1, to: floored),
            let limit = calendar.date(byAdding: .year, value: 5, to: date)
        else { return nil }

        // Walk day by day (bounded above by the five-year limit); inside a
        // matching day, try each allowed hour and minute in order. Building
        // times from components and checking they survive the round trip is
        // what skips DST gaps.
        var day = calendar.startOfDay(for: first)
        var earliest: (hour: Int, minute: Int)? = (
            calendar.component(.hour, from: first), calendar.component(.minute, from: first)
        )
        while day <= limit {
            let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if let month = comps.month, months.contains(month), matchesDay(comps),
                let fire = firstTime(in: comps, atOrAfter: earliest, calendar: calendar)
            {
                return fire
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = calendar.startOfDay(for: next)
            earliest = nil
        }
        return nil
    }

    /// The next `count` fires, for the editor's "runs next at" preview.
    public func nextFires(_ count: Int, after date: Date, calendar: Calendar) -> [Date] {
        var fires: [Date] = []
        var cursor = date
        while fires.count < count, let fire = nextFire(after: cursor, calendar: calendar) {
            fires.append(fire)
            cursor = fire
        }
        return fires
    }

    private func matchesDay(_ comps: DateComponents) -> Bool {
        guard let dayOfMonth = comps.day, let weekday = comps.weekday else { return false }
        let domMatch = daysOfMonth.contains(dayOfMonth)
        // Calendar's weekday is 1 (Sunday) through 7; cron's is 0 through 6.
        let dowMatch = daysOfWeek.contains(weekday - 1)
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (true, true): return domMatch || dowMatch
        case (true, false): return domMatch
        case (false, true): return dowMatch
        case (false, false): return true
        }
    }

    private func firstTime(
        in day: DateComponents, atOrAfter earliest: (hour: Int, minute: Int)?, calendar: Calendar
    ) -> Date? {
        for hour in hours.sorted() {
            if let earliest, hour < earliest.hour { continue }
            for minute in minutes.sorted() {
                if let earliest, hour == earliest.hour, minute < earliest.minute { continue }
                var comps = day
                comps.weekday = nil
                comps.hour = hour
                comps.minute = minute
                comps.second = 0
                guard let fire = calendar.date(from: comps) else { continue }
                // A time inside a spring-forward gap comes back shifted;
                // treat it as nonexistent rather than firing off-schedule.
                let check = calendar.dateComponents([.hour, .minute], from: fire)
                if check.hour == hour, check.minute == minute { return fire }
            }
        }
        return nil
    }

    private static func values(
        of field: String, field name: String, low: Int, high: Int
    ) throws -> Set<Int> {
        var result: Set<Int> = []
        for token in field.split(separator: ",", omittingEmptySubsequences: false) {
            let token = String(token)
            let parts = token.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw ParseError.badToken(field: name, token: token) }
            let step: Int
            if parts.count == 2 {
                guard let parsed = Int(parts[1]), parsed >= 1 else {
                    throw ParseError.badStep(field: name, token: token)
                }
                step = parsed
            } else {
                step = 1
            }

            let start: Int
            let end: Int
            let range = String(parts[0])
            if range == "*" {
                start = low
                end = high
            } else if let bounds = try bounds(of: range, field: name, low: low, high: high) {
                start = bounds.0
                // A bare number with a step reads as "from there to the
                // top", matching vixie; without a step it is just itself.
                end = bounds.1 ?? (parts.count == 2 ? high : bounds.0)
            } else {
                throw ParseError.badToken(field: name, token: token)
            }
            guard start <= end else { throw ParseError.badToken(field: name, token: token) }
            result.formUnion(stride(from: start, through: end, by: step))
        }
        guard !result.isEmpty else { throw ParseError.badToken(field: name, token: field) }
        return result
    }

    /// Reads "5" or "1-5", range-checking both ends. Returns nil only for
    /// tokens that aren't numbers at all.
    private static func bounds(
        of token: String, field: String, low: Int, high: Int
    ) throws -> (Int, Int?)? {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2, let start = Int(parts[0]) else { return nil }
        var end: Int?
        if parts.count == 2 {
            guard let parsed = Int(parts[1]) else { return nil }
            end = parsed
        }
        for value in [start, end].compactMap({ $0 }) where !(low...high).contains(value) {
            throw ParseError.outOfRange(field: field, token: token, low: low, high: high)
        }
        return (start, end)
    }
}
