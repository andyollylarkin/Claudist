import Foundation

/// A task's due date as stored in `task.dueDate` / `dueTime` / `dueString` / `isRecurring`.
public struct Due: Equatable, Sendable {
    /// "yyyy-MM-dd" (local).
    public var date: String
    /// "HH:mm" (local) or nil for an all-day due.
    public var time: String?
    /// The text the user typed, e.g. "every mon, fri at 9am".
    public var string: String
    public var isRecurring: Bool

    public init(date: String, time: String? = nil, string: String, isRecurring: Bool = false) {
        self.date = date
        self.time = time
        self.string = string
        self.isRecurring = isRecurring
    }
}

/// Parses English due strings typed into the task editor (Todoist syntax subset):
///
/// - one-off: `today`, `tom`, `next monday`, `fri 7pm`, `Jan 3`, `3 Jan 2027`, `2026-11-05`, `1/3/2027`,
///   `in 3 days`, `+2 weeks`, `27th`, `mid january`, `end of month`, `next week` (next Monday),
///   `next month` (same day), `this weekend`, `at 5pm` / `17:30` alone (today, or tomorrow when passed);
/// - recurring: `every day`/`daily`, `every weekday`/`workday`, `every week`/`weekly`, `every month`/`monthly`,
///   `every year`/`yearly`, `every quarter`, `every monday`, `every mon, fri at 9am`, `every 2 weeks`,
///   `every other day`, `every other fri`, `every 15th`, `every 2, 15, 27`, `every last day`, `every jan 3`,
///   `every hour`, `every 3 hours`, `… starting <date>` / `… from <date>`;
///   `every!` / `after N days` repeat from the completion date.
public enum DueParser {
    public static func parse(_ s: String, context: FilterContext) throws -> Due {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw err("Empty due date") }
        let lower = text.lowercased()
        if ["no date", "no due date", "none"].contains(lower) {
            throw err("'\(text)' removes the date; clear the due date instead")
        }
        if let rec = try Recurrence.parse(text) {
            let (day, time) = try rec.first(context: context)
            return Due(date: day.description, time: time?.description, string: text, isRecurring: true)
        }
        let expr: DateExpr
        do { expr = try DateExprParser.parse(text, mode: .due) } catch let e as DateParseError {
            throw err(e.message)
        }
        var r = expr.resolve(context)
        if case .time = expr, let t = r.time, t < ClockTime(context.now, calendar: context.calendar) {
            r = ResolvedDate(r.start.adding(days: 1), time: t)
        }
        return Due(date: r.start.description, time: r.time?.description, string: text, isRecurring: false)
    }

    /// For recurring dues: the next occurrence strictly after `after`.
    ///
    /// `every …` keeps the schedule anchored to the current due date (and skips occurrences
    /// that are not after both the current due and `after`); `every! …` counts from `after`
    /// (the completion time).
    public static func next(_ due: Due, after: Date, context: FilterContext) throws -> Due {
        guard due.isRecurring, let rec = try Recurrence.parse(due.string) else {
            throw err("'\(due.string)' is not a recurring date")
        }
        guard let cur = CivilDay(string: due.date) else { throw err("Invalid due date '\(due.date)'") }
        let (day, time) = rec.next(current: cur, currentTime: due.time.flatMap(ClockTime.init(string:)),
                                   after: after, context: context)
        return Due(date: day.description, time: time?.description, string: due.string, isRecurring: true)
    }

    static func err(_ m: String) -> FilterError { .syntax(position: 0, message: m) }
}

struct Recurrence {
    enum Rule: Equatable {
        case interval(Int, DateUnit)
        case weekdays(Set<Int>)
        /// Days of month; -1 = last day. Days past the month's end clamp to the last day.
        case monthDays(Set<Int>)
        case yearly([MonthDay])
    }

    struct MonthDay: Equatable { var month: Int; var day: Int }

    var rule: Rule
    var fromCompletion: Bool
    var time: ClockTime?
    var start: DateExpr?

    /// Returns nil if `text` isn't a recurring due string.
    static func parse(_ text: String) throws -> Recurrence? {
        var words = text.lowercased()
            .replacingOccurrences(of: ",", with: " , ")
            .replacingOccurrences(of: "every!", with: "every ! ")
            .replacingOccurrences(of: "ev!", with: "every ! ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let head = words.first else { return nil }
        var fromCompletion = false
        switch head {
        case "every", "ev":
            words.removeFirst()
            if words.first == "!" { fromCompletion = true; words.removeFirst() }
        case "everyday": words[0] = "day"
        case "daily": words[0] = "day"
        case "weekly": words[0] = "week"
        case "monthly": words[0] = "month"
        case "yearly", "annually": words[0] = "year"
        case "quarterly": words[0] = "quarter"
        case "after":
            // "after 10 days" = "every! 10 days"
            guard words.count >= 3, Int(words[1]) != nil, DateWords.unit(words[2]) != nil else { return nil }
            words.removeFirst()
            fromCompletion = true
        default:
            return nil
        }

        for stop in ["ending", "until", "for"] where words.contains(stop) {
            throw DueParser.err("'\(stop)' (end of a recurring date) is not supported")
        }
        var start: DateExpr?
        if let k = words.firstIndex(where: { $0 == "starting" || $0 == "from" }) {
            var rest = Array(words[(k + 1)...])
            if rest.first == "on" { rest.removeFirst() }
            guard !rest.isEmpty else { throw DueParser.err("Expected a date after '\(words[k])'") }
            do { start = try DateExprParser.parse(rest.joined(separator: " "), mode: .due) } catch let e as DateParseError {
                throw DueParser.err(e.message)
            }
            words = Array(words[..<k])
        }

        var time: ClockTime?
        if let k = words.lastIndex(where: { $0 == "at" || $0 == "@" }) {
            var p = DateExprParser(words[k...].joined(separator: " "), mode: .due)
            do { time = try p.parseTime() } catch let e as DateParseError { throw DueParser.err(e.message) }
            guard time != nil, p.i == p.words.count else { throw DueParser.err("Invalid time '\(words[(k + 1)...].joined(separator: " "))'") }
            words = Array(words[..<k])
        } else if let last = words.last, !["day", "week", "month", "year"].contains(last) {
            var p = DateExprParser(last, mode: .due)
            if let t = try? p.parseTime(), p.i == 1 { time = t; words.removeLast() }
        }
        if case .time(let h, let m)? = start, time == nil {
            // "every 12 hours starting at 9pm"
            time = ClockTime(hour: h, minute: m)
            start = nil
        }

        let ws = words.filter { $0 != "," }
        guard !ws.isEmpty else { throw DueParser.err("Expected what to repeat after 'every'") }
        let rule = try parseRule(ws, start: &start)
        return Recurrence(rule: rule, fromCompletion: fromCompletion, time: time, start: start)
    }

    static func unit(_ w: String) -> DateUnit? {
        if w == "quarter" || w == "quarters" { return .month }
        return DateWords.unit(w)
    }

    static func parseRule(_ ws: [String], start: inout DateExpr?) throws -> Rule {
        func bad() -> FilterError { DueParser.err("Unknown recurring date 'every \(ws.joined(separator: " "))'") }
        let quarterMul: (String) -> Int = { ($0 == "quarter" || $0 == "quarters") ? 3 : 1 }

        if ws.count == 1 {
            let w = ws[0]
            if ["weekday", "weekdays", "workday", "workdays"].contains(w) { return .weekdays([0, 1, 2, 3, 4]) }
            if ["weekend", "weekends"].contains(w) { return .weekdays([5, 6]) }
            if let u = unit(w) { return .interval(quarterMul(w), u) }
        }
        if ws.count == 2, ws[0] == "last", ws[1] == "day" { return .monthDays([-1]) }
        if ws.count == 2, ws[0] == "other" {
            if let u = unit(ws[1]) { return .interval(2 * quarterMul(ws[1]), u) }
            if let wd = DateWords.weekdays[ws[1]] {
                if start == nil { start = .weekday(wd, next: false) }
                return .interval(2, .week)
            }
        }
        if ws.count == 2, let n = Int(ws[0]), n > 0, let u = unit(ws[1]) {
            if u == .minute { throw DueParser.err("Repeating every few minutes is not supported") }
            return .interval(n * quarterMul(ws[1]), u)
        }
        if ws.allSatisfy({ DateWords.weekdays[$0] != nil }) {
            return .weekdays(Set(ws.compactMap { DateWords.weekdays[$0] }))
        }
        // every 15th / every 2, 15, 27 / every last day (mixed lists)
        var days: Set<Int> = []
        var i = 0
        while i < ws.count {
            if ws[i] == "last", i + 1 < ws.count, ws[i + 1] == "day" { days.insert(-1); i += 2; continue }
            guard let d = Int(ws[i]) ?? DateWords.ordinal(ws[i]), (1...31).contains(d) else { days = []; break }
            days.insert(d)
            i += 1
        }
        if !days.isEmpty { return .monthDays(days) }
        // every jan 3 / every 3 jan / every 14 jan, 14 apr
        var mds: [MonthDay] = []
        i = 0
        while i + 1 < ws.count {
            if let m = DateWords.months[ws[i]], let d = Int(ws[i + 1]) ?? DateWords.ordinal(ws[i + 1]) {
                mds.append(MonthDay(month: m, day: d))
            } else if let d = Int(ws[i]) ?? DateWords.ordinal(ws[i]), let m = DateWords.months[ws[i + 1]] {
                mds.append(MonthDay(month: m, day: d))
            } else {
                throw bad()
            }
            guard (1...CivilDay.daysIn(month: mds.last!.month, year: 2000)).contains(mds.last!.day) else { throw bad() }
            i += 2
        }
        if i == ws.count, !mds.isEmpty { return .yearly(mds) }
        throw bad()
    }

    // MARK: Occurrences

    func matches(_ d: CivilDay) -> Bool {
        switch rule {
        case .interval: return true
        case .weekdays(let set): return set.contains(d.weekdayIndex)
        case .monthDays(let set):
            let last = d.lastOfMonth.day
            return set.contains { $0 == -1 ? d.day == last : min($0, last) == d.day }
        case .yearly(let mds):
            return mds.contains { $0.month == d.month && min($0.day, CivilDay.daysIn(month: d.month, year: d.year)) == d.day }
        }
    }

    /// Steps an interval rule `k` times from `anchor`.
    func step(_ anchor: CivilDay, _ k: Int) -> CivilDay {
        guard case .interval(let n, let u) = rule else { return anchor.adding(days: k) }
        switch u {
        case .day: return anchor.adding(days: n * k)
        case .week: return anchor.adding(days: 7 * n * k)
        case .month: return anchor.adding(months: n * k)
        case .year: return anchor.adding(years: n * k)
        case .hour, .minute: return anchor
        }
    }

    var isHourly: Bool {
        if case .interval(_, let u) = rule { return u == .hour || u == .minute }
        return false
    }

    var hourStep: (Calendar.Component, Int) {
        if case .interval(let n, let u) = rule { return (u == .hour ? .hour : .minute, n) }
        return (.hour, 1)
    }

    /// First occurrence on or after `from` (and, when timed, at or after `notBefore`).
    func search(from anchor: CivilDay, time: ClockTime?, accept: (CivilDay, ClockTime?) -> Bool) -> CivilDay {
        if case .interval = rule {
            var k = 0
            while k < 10_000 {
                let d = step(anchor, k)
                if accept(d, time) { return d }
                k += 1
            }
            return anchor
        }
        var d = anchor
        for _ in 0..<(366 * 8) {
            if matches(d) && accept(d, time) { return d }
            d = d.adding(days: 1)
        }
        return anchor
    }

    func first(context ctx: FilterContext) throws -> (CivilDay, ClockTime?) {
        let today = CivilDay(ctx.now, calendar: ctx.calendar)
        let nowTime = ClockTime(ctx.now, calendar: ctx.calendar)
        let s = start?.resolve(ctx)
        let t = time ?? s?.time
        if isHourly {
            let (comp, n) = hourStep
            var d: Date
            if let s {
                let tt = t ?? ClockTime(hour: 0, minute: 0)
                d = s.start.date(hour: tt.hour, minute: tt.minute, calendar: ctx.calendar)
            } else if let t {
                d = today.date(hour: t.hour, minute: t.minute, calendar: ctx.calendar)
            } else {
                d = today.date(hour: nowTime.hour, minute: nowTime.minute, calendar: ctx.calendar)
            }
            let floor = today.date(hour: nowTime.hour, minute: nowTime.minute, calendar: ctx.calendar)
            var guardCount = 0
            while d < floor && guardCount < 100_000 { d = ctx.calendar.date(byAdding: comp, value: n, to: d)!; guardCount += 1 }
            return (CivilDay(d, calendar: ctx.calendar), ClockTime(d, calendar: ctx.calendar))
        }
        let anchor = s?.start ?? today
        let day = search(from: anchor, time: t) { d, tm in
            if let tm { return d > today || (d == today && tm >= nowTime) }
            return d >= today
        }
        return (day, t)
    }

    func next(current: CivilDay, currentTime: ClockTime?, after: Date, context ctx: FilterContext) -> (CivilDay, ClockTime?) {
        let afterDay = CivilDay(after, calendar: ctx.calendar)
        let afterTime = ClockTime(after, calendar: ctx.calendar)
        let t = time ?? currentTime

        if isHourly {
            let (comp, n) = hourStep
            let tt = currentTime ?? t ?? ClockTime(hour: 0, minute: 0)
            var d: Date
            if fromCompletion {
                d = ctx.calendar.date(byAdding: comp, value: n, to: afterDay.date(hour: afterTime.hour, minute: afterTime.minute, calendar: ctx.calendar))!
            } else {
                d = ctx.calendar.date(byAdding: comp, value: n, to: current.date(hour: tt.hour, minute: tt.minute, calendar: ctx.calendar))!
                var guardCount = 0
                while d <= after && guardCount < 100_000 { d = ctx.calendar.date(byAdding: comp, value: n, to: d)!; guardCount += 1 }
            }
            return (CivilDay(d, calendar: ctx.calendar), ClockTime(d, calendar: ctx.calendar))
        }

        if fromCompletion {
            if case .interval = rule { return (step(afterDay, 1), t) }
            let day = search(from: afterDay, time: t) { d, tm in
                if let tm { return d > afterDay || (d == afterDay && tm > afterTime) }
                return d > afterDay
            }
            return (day, t)
        }

        // Anchored on the current due: strictly after both the current due and `after`.
        let (thDay, thTime): (CivilDay, ClockTime?) = {
            guard let ct = currentTime else { return (max(current, afterDay), nil) }
            return (current, ct) > (afterDay, afterTime) ? (current, ct) : (afterDay, afterTime)
        }()
        let day = search(from: current, time: t) { d, tm in
            if let tm, let thTime { return d > thDay || (d == thDay && tm > thTime) }
            return d > thDay
        }
        return (day, t)
    }
}

private func > (a: (CivilDay, ClockTime), b: (CivilDay, ClockTime)) -> Bool {
    a.0 != b.0 ? a.0 > b.0 : a.1 > b.1
}
