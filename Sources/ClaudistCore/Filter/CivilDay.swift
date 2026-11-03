import Foundation

/// A calendar day without a time zone ("yyyy-MM-dd"). All arithmetic is done in a fixed
/// UTC Gregorian calendar, so it is immune to DST and the user's time zone.
struct CivilDay: Hashable, Comparable, CustomStringConvertible {
    var year: Int
    var month: Int
    var day: Int

    static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local day of `date` in `calendar`'s time zone.
    init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    init?(string: String) {
        let p = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        self.init(year: p[0], month: p[1], day: p[2])
    }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    private var utcDate: Date {
        Self.gregorian.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private init(utc: Date) {
        let c = Self.gregorian.dateComponents([.year, .month, .day], from: utc)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    func adding(days n: Int) -> CivilDay {
        CivilDay(utc: Self.gregorian.date(byAdding: .day, value: n, to: utcDate)!)
    }

    /// Adds months, clamping the day to the target month's length (Jan 31 + 1 month = Feb 28/29).
    func adding(months n: Int, preferredDay: Int? = nil) -> CivilDay {
        var total = year * 12 + (month - 1) + n
        if total < 0 { total = 0 }
        let y = total / 12, m = total % 12 + 1
        let d = min(preferredDay ?? day, CivilDay.daysIn(month: m, year: y))
        return CivilDay(year: y, month: m, day: d)
    }

    func adding(years n: Int) -> CivilDay { adding(months: 12 * n) }

    /// 0 = Monday … 6 = Sunday.
    var weekdayIndex: Int {
        let w = Self.gregorian.component(.weekday, from: utcDate) // 1 = Sunday
        return (w + 5) % 7
    }

    var startOfWeek: CivilDay { adding(days: -weekdayIndex) }
    var firstOfMonth: CivilDay { CivilDay(year: year, month: month, day: 1) }
    var lastOfMonth: CivilDay { CivilDay(year: year, month: month, day: CivilDay.daysIn(month: month, year: year)) }

    func daysUntil(_ other: CivilDay) -> Int {
        Self.gregorian.dateComponents([.day], from: utcDate, to: other.utcDate).day!
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func < (a: CivilDay, b: CivilDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// The `Date` of this day at `hour:minute` in `calendar`'s time zone.
    func date(hour: Int = 0, minute: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

/// Hour and minute of a local time.
struct ClockTime: Hashable, Comparable, CustomStringConvertible {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }

    init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour!, minute: c.minute!)
    }

    init?(string: String) {
        let p = string.split(separator: ":").compactMap { Int($0) }
        guard p.count >= 2 else { return nil }
        self.init(hour: p[0], minute: p[1])
    }

    var description: String { String(format: "%02d:%02d", hour, minute) }

    static func < (a: ClockTime, b: ClockTime) -> Bool { (a.hour, a.minute) < (b.hour, b.minute) }
}
