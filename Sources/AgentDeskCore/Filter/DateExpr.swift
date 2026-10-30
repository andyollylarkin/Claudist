import Foundation

public enum DateUnit: String, Equatable, Sendable {
    case minute, hour, day, week, month, year
}

/// A date phrase as typed in a filter (`date before: next week`) or in the due field (`tomorrow at 5pm`).
/// It is parsed without a clock and resolved later against a `FilterContext`.
public indirect enum DateExpr: Equatable, Sendable {
    /// today + n days (`today` = 0, `tomorrow` = 1, `yesterday` = -1, `+3 days`, `in 3 days`).
    case days(Int)
    /// now + n units (`in 2 weeks`, `+4 hours`). Hours/minutes give an instant, other units a day.
    case offset(Int, DateUnit)
    /// Weekday, 0 = Monday. `next` follows Todoist's "next <weekday>" rule.
    case weekday(Int, next: Bool)
    /// `Jan 3`, `3 Jan 2027`, `1/3/2027`, `mid January`. Without a year the nearest matching day is used.
    case monthDay(month: Int, day: Int, year: Int?)
    /// `27th`, `first day` (= 1st): the nearest such day of a month.
    case dayOfMonth(Int)
    /// `last day`, `end of month`: last day of the current month.
    case lastDayOfMonth
    /// Whole week (Mon–Sun): 0 = this week, 1 = next week, -1 = last week.
    case week(Int)
    /// Whole calendar month: 0 = this, 1 = next, -1 = last.
    case month(Int)
    /// Whole calendar year: 0 = this, 1 = next.
    case year(Int)
    /// Saturday–Sunday: 0 = this (upcoming) weekend, 1 = next weekend.
    case weekend(Int)
    /// `next N days`: today … today + N - 1.
    case nextDays(Int)
    /// `-N days` as a bare filter: today - N … yesterday.
    case pastDays(Int)
    /// `1 week after next week`, `3 days before Jan 10`.
    case shifted(Int, DateUnit, DateExpr)
    /// A day with a time: `today at 2pm`, `fri 7pm`.
    case at(DateExpr, hour: Int, minute: Int)
    /// A time alone: `5pm`, `at 17:30` (today at that time).
    case time(hour: Int, minute: Int)
}

/// A resolved date: an inclusive day range, or a single instant when `time` is set.
struct ResolvedDate: Equatable {
    var start: CivilDay
    var end: CivilDay
    var time: ClockTime?

    init(_ day: CivilDay, time: ClockTime? = nil) { start = day; end = day; self.time = time }
    init(start: CivilDay, end: CivilDay) { self.start = start; self.end = end }
}

struct DateParseError: Error {
    var message: String
}

// MARK: - Resolution

extension DateExpr {
    /// - Parameter preferPast: for month/day without a year (and `27th`), pick the most recent
    ///   such day instead of the upcoming one (used for `created:`, `completed:`, `run:`).
    func resolve(_ ctx: FilterContext, preferPast: Bool = false) -> ResolvedDate {
        let today = CivilDay(ctx.now, calendar: ctx.calendar)
        switch self {
        case .days(let n):
            return ResolvedDate(today.adding(days: n))
        case .offset(let n, let unit):
            switch unit {
            case .minute, .hour:
                let d = ctx.calendar.date(byAdding: unit == .hour ? .hour : .minute, value: n, to: ctx.now)!
                return ResolvedDate(CivilDay(d, calendar: ctx.calendar), time: ClockTime(d, calendar: ctx.calendar))
            case .day: return ResolvedDate(today.adding(days: n))
            case .week: return ResolvedDate(today.adding(days: 7 * n))
            case .month: return ResolvedDate(today.adding(months: n))
            case .year: return ResolvedDate(today.adding(years: n))
            }
        case .weekday(let w, let next):
            return ResolvedDate(DateExpr.weekday(w, next: next, today: today))
        case .monthDay(let m, let d, let y):
            if let y { return ResolvedDate(CivilDay(year: y, month: m, day: min(d, CivilDay.daysIn(month: m, year: y)))) }
            func inYear(_ y: Int) -> CivilDay { CivilDay(year: y, month: m, day: min(d, CivilDay.daysIn(month: m, year: y))) }
            let this = inYear(today.year)
            if preferPast { return ResolvedDate(this <= today ? this : inYear(today.year - 1)) }
            return ResolvedDate(this >= today ? this : inYear(today.year + 1))
        case .dayOfMonth(let d):
            let this = today.firstOfMonth.adding(months: 0, preferredDay: d)
            if preferPast {
                return ResolvedDate(this <= today ? this : today.firstOfMonth.adding(months: -1, preferredDay: d))
            }
            return ResolvedDate(this >= today ? this : today.firstOfMonth.adding(months: 1, preferredDay: d))
        case .lastDayOfMonth:
            return ResolvedDate(today.lastOfMonth)
        case .week(let k):
            let s = today.startOfWeek.adding(days: 7 * k)
            return ResolvedDate(start: s, end: s.adding(days: 6))
        case .month(let k):
            let s = today.firstOfMonth.adding(months: k)
            return ResolvedDate(start: s, end: s.lastOfMonth)
        case .year(let k):
            return ResolvedDate(start: CivilDay(year: today.year + k, month: 1, day: 1),
                                end: CivilDay(year: today.year + k, month: 12, day: 31))
        case .weekend(let k):
            let sat = DateExpr.weekday(5, next: false, today: today).adding(days: 7 * k)
            return ResolvedDate(start: sat, end: sat.adding(days: 1))
        case .nextDays(let n):
            return ResolvedDate(start: today, end: today.adding(days: max(n, 1) - 1))
        case .pastDays(let n):
            return ResolvedDate(start: today.adding(days: -max(n, 1)), end: today.adding(days: -1))
        case .shifted(let n, let unit, let base):
            let b = base.resolve(ctx, preferPast: preferPast)
            switch unit {
            case .minute, .hour:
                let t = b.time ?? ClockTime(hour: 0, minute: 0)
                let d0 = b.start.date(hour: t.hour, minute: t.minute, calendar: ctx.calendar)
                let d = ctx.calendar.date(byAdding: unit == .hour ? .hour : .minute, value: n, to: d0)!
                return ResolvedDate(CivilDay(d, calendar: ctx.calendar), time: ClockTime(d, calendar: ctx.calendar))
            case .day: return ResolvedDate(b.start.adding(days: n), time: b.time)
            case .week: return ResolvedDate(b.start.adding(days: 7 * n), time: b.time)
            case .month: return ResolvedDate(b.start.adding(months: n), time: b.time)
            case .year: return ResolvedDate(b.start.adding(years: n), time: b.time)
            }
        case .at(let base, let h, let m):
            let b = base.resolve(ctx, preferPast: preferPast)
            return ResolvedDate(b.start, time: ClockTime(hour: h, minute: m))
        case .time(let h, let m):
            return ResolvedDate(today, time: ClockTime(hour: h, minute: m))
        }
    }

    /// Plain weekday = the upcoming one (today counts). `next <weekday>` (Todoist rule): if that
    /// weekday is still ahead in the current Mon–Sun week (or is today), take the one in the
    /// following week; if it has already passed this week, take the upcoming one.
    static func weekday(_ w: Int, next: Bool, today: CivilDay) -> CivilDay {
        let ahead = (w - today.weekdayIndex + 7) % 7
        let upcoming = today.adding(days: ahead)
        if next && w >= today.weekdayIndex { return upcoming.adding(days: 7) }
        return upcoming
    }
}

// MARK: - Parsing

enum DateParseMode {
    /// Filter queries: `next week`/`this month`/`next N days` are whole ranges.
    case filter
    /// Due field: only single days; `next month` = same day next month.
    case due
}

enum DateWords {
    static let weekdays: [String: Int] = [
        "mon": 0, "monday": 0, "tue": 1, "tues": 1, "tuesday": 1, "wed": 2, "weds": 2, "wednesday": 2,
        "thu": 3, "thur": 3, "thurs": 3, "thursday": 3, "fri": 4, "friday": 4,
        "sat": 5, "saturday": 5, "sun": 6, "sunday": 6,
    ]
    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12,
    ]
    static func unit(_ w: String) -> DateUnit? {
        switch w {
        case "min", "mins", "minute", "minutes": return .minute
        case "h", "hr", "hrs", "hour", "hours": return .hour
        case "d", "day", "days": return .day
        case "w", "wk", "wks", "week", "weeks": return .week
        case "mo", "month", "months": return .month
        case "y", "yr", "yrs", "year", "years": return .year
        default: return nil
        }
    }

    /// "3rd" → 3, "27th" → 27, "1st" → 1.
    static func ordinal(_ w: String) -> Int? {
        for suf in ["st", "nd", "rd", "th"] where w.hasSuffix(suf) {
            if let n = Int(w.dropLast(2)), (1...31).contains(n) { return n }
        }
        return nil
    }

    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
}

/// Recursive-descent parser over lowercase words.
struct DateExprParser {
    var words: [String]
    var i = 0
    let mode: DateParseMode

    init(_ text: String, mode: DateParseMode) {
        words = DateWords.tokenize(text)
        self.mode = mode
    }

    static func parse(_ text: String, mode: DateParseMode) throws -> DateExpr {
        var p = DateExprParser(text, mode: mode)
        guard !p.words.isEmpty else { throw DateParseError(message: "Expected a date") }
        let e = try p.parseExpr()
        if p.i < p.words.count {
            throw DateParseError(message: "Unexpected '\(p.words[p.i...].joined(separator: " "))' in date '\(text.trimmingCharacters(in: .whitespaces))'")
        }
        return e
    }

    var peek: String? { i < words.count ? words[i] : nil }
    func peek(_ k: Int) -> String? { i + k < words.count ? words[i + k] : nil }

    mutating func eat(_ w: String) -> Bool {
        if peek == w { i += 1; return true }
        return false
    }

    mutating func parseExpr() throws -> DateExpr {
        // N unit after|before <date>
        if let (n, unit, len) = numberUnit(at: i), let rel = peek(len), rel == "after" || rel == "before" {
            i += len + 1
            let base = try parseExpr()
            return .shifted(rel == "after" ? n : -n, unit, base)
        }
        let base = try parseBase()
        let time = try parseTime()
        switch (base, time) {
        case let (b?, t?): return .at(b, hour: t.hour, minute: t.minute)
        case let (b?, nil): return b
        case let (nil, t?): return .time(hour: t.hour, minute: t.minute)
        default:
            throw DateParseError(message: "Unknown date '\(words[i...].joined(separator: " "))'")
        }
    }

    /// Parses `5`, `+5`, `-5` followed by a unit word. Returns (signed n, unit, words consumed).
    func numberUnit(at k: Int) -> (Int, DateUnit, Int)? {
        guard k < words.count else { return nil }
        let w = words[k]
        // "+4h" style is not supported; "+4 hours" is.
        guard let n = Int(w.hasPrefix("+") ? String(w.dropFirst()) : w), k + 1 < words.count,
              let unit = DateWords.unit(words[k + 1]) else { return nil }
        return (n, unit, 2)
    }

    static func rel(_ n: Int, _ unit: DateUnit) -> DateExpr {
        unit == .day ? .days(n) : .offset(n, unit)
    }

    mutating func parseBase() throws -> DateExpr? {
        guard let w = peek else { return nil }
        switch w {
        case "today", "tod": i += 1; return .days(0)
        case "tomorrow", "tom", "tmr", "tmrw": i += 1; return .days(1)
        case "yesterday": i += 1; return .days(-1)
        case "now": i += 1; return .offset(0, .minute)
        case "in":
            if let (n, unit, len) = numberUnit(at: i + 1) { i += 1 + len; return Self.rel(n, unit) }
            return nil
        case "next", "this", "last":
            return try parseNextThisLast()
        case "first":
            if peek(1) == "day" { i += 2; return .dayOfMonth(1) }
            return nil
        case "end":
            if peek(1) == "of", peek(2) == "month" || peek(2) == "the" {
                i += 3
                if words[i - 1] == "the" { guard eat("month") else { throw DateParseError(message: "Expected 'end of month'") } }
                return .lastDayOfMonth
            }
            return nil
        case "mid":
            if let m = peek(1).flatMap({ DateWords.months[$0] }) { i += 2; return .monthDay(month: m, day: 15, year: nil) }
            return nil
        default: break
        }
        if let (n, unit, len) = numberUnit(at: i) {
            i += len
            if eat("ago") { return Self.rel(-n, unit) }
            return Self.rel(n, unit)
        }
        if let wd = DateWords.weekdays[w] { i += 1; return .weekday(wd, next: false) }
        if let m = DateWords.months[w] {
            // Jan 3 [2027] / Jan 3rd
            guard let d = peek(1).flatMap({ Int($0) ?? DateWords.ordinal($0) }) else {
                throw DateParseError(message: "Expected a day after '\(w)'")
            }
            i += 2
            return try monthDay(m, d, year: parseYear())
        }
        if let d = Int(w) ?? DateWords.ordinal(w), let m = peek(1).flatMap({ DateWords.months[$0] }) {
            i += 2
            return try monthDay(m, d, year: parseYear())
        }
        if let d = DateWords.ordinal(w) { i += 1; return .dayOfMonth(d) }
        if w.contains("/") || w.contains("-") || (w.contains(".") && w.first!.isNumber) {
            if let e = try numericDate(w) { i += 1; return e }
        }
        return nil
    }

    mutating func parseYear() -> Int? {
        if let y = peek.flatMap({ Int($0) }), y >= 1000 && y <= 9999 { i += 1; return y }
        return nil
    }

    func monthDay(_ m: Int, _ d: Int, year: Int?) throws -> DateExpr {
        let maxDay = year.map { CivilDay.daysIn(month: m, year: $0) } ?? CivilDay.daysIn(month: m, year: 2000)
        guard (1...maxDay).contains(d) else { throw DateParseError(message: "Invalid day \(d) for month \(m)") }
        return .monthDay(month: m, day: d, year: year)
    }

    /// `2026-11-05`, `2026/11/05`, `1/3/2027`, `5/5`. Ambiguous a/b is read as month/day
    /// (Todoist's US default); if the first number is > 12 it is read as day/month.
    func numericDate(_ w: String) throws -> DateExpr? {
        let parts = w.split(whereSeparator: { "/-.".contains($0) }).map(String.init)
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count, nums.count == 2 || nums.count == 3 else { return nil }
        if nums.count == 3 && parts[0].count == 4 { return try monthDay(nums[1], nums[2], year: nums[0]) }
        var (a, b) = (nums[0], nums[1])
        var year: Int?
        if nums.count == 3 {
            year = nums[2] < 100 ? 2000 + nums[2] : nums[2]
        }
        if a > 12 { swap(&a, &b) }
        guard (1...12).contains(a) else { throw DateParseError(message: "Invalid date '\(w)'") }
        return try monthDay(a, b, year: year)
    }

    mutating func parseNextThisLast() throws -> DateExpr? {
        let w = words[i]
        let k = w == "next" ? 1 : w == "this" ? 0 : -1
        guard let what = peek(1) else { return nil }
        if w == "next", let n = Int(what), peek(2).flatMap(DateWords.unit) == .day {
            guard mode == .filter else { throw DateParseError(message: "'next \(n) days' is a range; use 'in \(n) days'") }
            i += 3
            return .nextDays(n)
        }
        if let wd = DateWords.weekdays[what] {
            guard k >= 0 else { return nil }
            i += 2
            return .weekday(wd, next: k == 1)
        }
        switch what {
        case "week":
            i += 2
            if mode == .due { guard k == 1 else { throw DateParseError(message: "Use a specific day instead of '\(w) week'") } }
            return .week(k)
        case "month":
            i += 2
            if mode == .due { guard k == 1 else { throw DateParseError(message: "Use a specific day instead of '\(w) month'") }; return .offset(1, .month) }
            return .month(k)
        case "year":
            i += 2
            if mode == .due { guard k == 1 else { throw DateParseError(message: "Use a specific day instead of '\(w) year'") } }
            return .year(k)
        case "weekend":
            guard k >= 0 else { return nil }
            i += 2
            return .weekend(k)
        case "day" where k == -1:
            i += 2
            return .lastDayOfMonth
        default:
            return nil
        }
    }

    /// `[at] 5pm`, `at 5 pm`, `17:30`, `5:30pm`, `at 10`, `noon`, `midnight`, `morning`…
    mutating func parseTime() throws -> ClockTime? {
        let start = i
        let hadAt = eat("at") || eat("@")
        guard let w = peek else {
            if hadAt { throw DateParseError(message: "Expected a time after 'at'") }
            return nil
        }
        let named: [String: ClockTime] = [
            "noon": .init(hour: 12, minute: 0), "midnight": .init(hour: 0, minute: 0),
            "morning": .init(hour: 9, minute: 0), "afternoon": .init(hour: 12, minute: 0),
            "evening": .init(hour: 19, minute: 0), "night": .init(hour: 22, minute: 0),
        ]
        if let t = named[w] { i += 1; return t }
        if ["in", "the"].contains(w), let t = peek(1).flatMap({ named[$0] }) ?? peek(2).flatMap({ named[$0] }) {
            i += peek(1) == "the" ? 3 : 2
            return t
        }
        var body = w
        var suffix: String?
        for s in ["am", "pm", "a", "p"] where body.hasSuffix(s) && body.count > s.count && body.dropLast(s.count).last!.isNumber {
            suffix = s.hasPrefix("a") ? "am" : "pm"
            body = String(body.dropLast(s.count))
            break
        }
        let hm = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(hm.count), let h = Int(hm[0]), hm[0].count <= 2,
              hm.count == 1 || (hm[1].count == 2 && Int(hm[1]) != nil) else {
            if hadAt { throw DateParseError(message: "Invalid time '\(w)'") }
            i = start
            return nil
        }
        let m = hm.count == 2 ? Int(hm[1])! : 0
        if suffix == nil, peek(1) == "am" || peek(1) == "pm" { suffix = peek(1); i += 1 }
        // A bare number is only a time after "at" ("at 10") or with a colon/suffix.
        guard hadAt || suffix != nil || hm.count == 2 else { i = start; return nil }
        i += 1
        var hour = h
        if let suffix {
            guard (1...12).contains(h) else { throw DateParseError(message: "Invalid time '\(w)'") }
            hour = suffix == "am" ? (h == 12 ? 0 : h) : (h == 12 ? 12 : h + 12)
        }
        guard (0...23).contains(hour), (0...59).contains(m) else { throw DateParseError(message: "Invalid time '\(w)'") }
        return ClockTime(hour: hour, minute: m)
    }
}
