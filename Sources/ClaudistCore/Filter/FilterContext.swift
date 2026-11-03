import Foundation

/// Everything a filter or due string needs to resolve relative dates.
public struct FilterContext {
    public var now: Date
    /// Calendar (and its time zone) used to turn `now` into the local day/time strings stored in the DB.
    public var calendar: Calendar
    /// The name that `assigned to: <name>` treats as "me" (in addition to the literal `me`).
    public var currentUser: String

    public init(now: Date = Date(), calendar: Calendar = .current, currentUser: String = "me") {
        self.now = now
        self.calendar = calendar
        self.currentUser = currentUser
    }

    var today: String { LocalDate.day(now, calendar: calendar) }
}

/// User-facing parse/compile error. `position` is a 0-based character offset into the source text.
public enum FilterError: Error, CustomStringConvertible, Equatable {
    case syntax(position: Int, message: String)

    public var position: Int {
        switch self { case .syntax(let p, _): return p }
    }

    public var message: String {
        switch self { case .syntax(_, let m): return m }
    }

    public var description: String { "\(message) (at position \(position + 1))" }
}
