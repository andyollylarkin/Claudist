import Foundation

/// Conversions between `Date` and the local calendar strings stored in the database.
public enum LocalDate {
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    public static func stamp(_ date: Date, calendar: Calendar = .current) -> String {
        day(date, calendar: calendar) + " " + time(date, calendar: calendar)
    }

    /// Parses "yyyy-MM-dd" or "yyyy-MM-dd HH:mm" (optionally with a separate "HH:mm" time).
    public static func parse(_ day: String, time: String? = nil, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: " ")
        let d = parts[0].split(separator: "-").compactMap { Int($0) }
        guard d.count == 3 else { return nil }
        var comps = DateComponents(year: d[0], month: d[1], day: d[2])
        let t = time ?? (parts.count > 1 ? String(parts[1]) : nil)
        if let t {
            let hm = t.split(separator: ":").compactMap { Int($0) }
            if hm.count >= 2 { comps.hour = hm[0]; comps.minute = hm[1] }
        }
        return calendar.date(from: comps)
    }
}
