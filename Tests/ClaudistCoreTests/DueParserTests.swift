import Testing
import Foundation
@testable import ClaudistCore

@Suite struct DueParserTests {
    let ctx = TestClock.context  // Fri 2026-10-30 14:00 Europe/Moscow

    func p(_ s: String) throws -> String {
        let d = try DueParser.parse(s, context: ctx)
        return d.time.map { "\(d.date) \($0)" } ?? d.date
    }

    func next(_ s: String, from due: String? = nil, after: String) throws -> String {
        var d = try DueParser.parse(s, context: ctx)
        if let due {
            let parts = due.split(separator: " ")
            d.date = String(parts[0])
            d.time = parts.count > 1 ? String(parts[1]) : nil
        }
        let n = try DueParser.next(d, after: TestClock.date(after), context: ctx)
        #expect(n.string == d.string && n.isRecurring)
        return n.time.map { "\(n.date) \($0)" } ?? n.date
    }

    @Test func oneOff() throws {
        #expect(try p("today") == "2026-10-30")
        #expect(try p("Tomorrow") == "2026-10-31")
        #expect(try p("tom") == "2026-10-31")
        #expect(try p("next monday") == "2026-11-02")
        #expect(try p("mon") == "2026-11-02")
        #expect(try p("fri") == "2026-10-30")
        #expect(try p("next fri") == "2026-11-06")
        #expect(try p("Jan 3") == "2027-01-03")
        #expect(try p("3 Jan 2027") == "2027-01-03")
        #expect(try p("2026-11-05") == "2026-11-05")
        #expect(try p("1/3/2027") == "2027-01-03")
        #expect(try p("in 3 days") == "2026-11-02")
        #expect(try p("+2 weeks") == "2026-11-13")
        #expect(try p("next week") == "2026-11-02")
        #expect(try p("next month") == "2026-11-30")
        #expect(try p("next year") == "2027-01-01")
        #expect(try p("this weekend") == "2026-10-31")
        #expect(try p("27th") == "2026-11-27")
        #expect(try p("end of month") == "2026-10-31")
        #expect(try p("in 2 hours") == "2026-10-30 16:00")
        #expect(try p("3 days after Jan 10") == "2027-01-13")
        let d = try DueParser.parse("Tomorrow at 5pm", context: ctx)
        #expect(d == Due(date: "2026-10-31", time: "17:00", string: "Tomorrow at 5pm", isRecurring: false))
    }

    @Test func times() throws {
        #expect(try p("at 5pm") == "2026-10-30 17:00")
        #expect(try p("17:30") == "2026-10-30 17:30")
        #expect(try p("9am") == "2026-10-31 09:00") // already passed today → tomorrow
        #expect(try p("today 9am") == "2026-10-30 09:00") // explicit day is kept
        #expect(try p("fri at 19:00") == "2026-10-30 19:00")
        #expect(try p("tomorrow at 10") == "2026-10-31 10:00")
        #expect(try p("mon 12pm") == "2026-11-02 12:00")
        #expect(try p("mon at 12am") == "2026-11-02 00:00")
        #expect(try p("tom evening") == "2026-10-31 19:00")
    }

    @Test func errors() {
        #expect(throws: FilterError.self) { try DueParser.parse("", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("blah", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("no date", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("this week", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("next 5 days", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("at 25", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("every blah", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("every", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("every day until dec 1", context: ctx) }
        #expect(throws: FilterError.self) { try DueParser.parse("every 5 minutes", context: ctx) }
        #expect(throws: FilterError.self) {
            try DueParser.next(Due(date: "2026-10-30", string: "today"), after: Date(), context: ctx)
        }
        do {
            _ = try DueParser.parse("every blah", context: ctx)
        } catch let e as FilterError {
            #expect(e.message == "Unknown recurring date 'every blah'")
        } catch {}
    }

    @Test func recurringFirstOccurrence() throws {
        #expect(try p("every day") == "2026-10-30")
        #expect(try p("daily") == "2026-10-30")
        #expect(try p("everyday") == "2026-10-30")
        #expect(try p("every day at 9am") == "2026-10-31 09:00")
        #expect(try p("every day at 6pm") == "2026-10-30 18:00")
        #expect(try p("every weekday") == "2026-10-30")
        #expect(try p("every workday at 9am") == "2026-11-02 09:00")
        #expect(try p("every monday") == "2026-11-02")
        #expect(try p("every mon, fri at 9am") == "2026-11-02 09:00")
        #expect(try p("every mon, fri at 20:00") == "2026-10-30 20:00")
        #expect(try p("every wed and fri at 9am") == "2026-11-04 09:00")
        #expect(try p("every Wednesday and Friday at 20:00") == "2026-10-30 20:00")
        #expect(try p("every mon, wed and fri") == "2026-10-30")
        #expect(try p("every 1st and 15th") == "2026-11-01")
        #expect(try p("every 2 weeks") == "2026-10-30")
        #expect(try p("every other day") == "2026-10-30")
        #expect(try p("every other fri") == "2026-10-30")
        #expect(try p("every month") == "2026-10-30")
        #expect(try p("monthly") == "2026-10-30")
        #expect(try p("every 15th") == "2026-11-15")
        #expect(try p("every 2, 15, 27") == "2026-11-02")
        #expect(try p("every 30th") == "2026-10-30")
        #expect(try p("every last day") == "2026-10-31")
        #expect(try p("every jan 3") == "2027-01-03")
        #expect(try p("every 14 jan, 14 apr") == "2027-01-14")
        #expect(try p("every year") == "2026-10-30")
        #expect(try p("every quarter") == "2026-10-30")
        #expect(try p("every hour") == "2026-10-30 14:00")
        #expect(try p("every 3 hours") == "2026-10-30 14:00")
        #expect(try p("every 12 hours starting at 9pm") == "2026-10-30 21:00")
        #expect(try p("every day starting nov 3") == "2026-11-03")
        #expect(try p("every week from jan 3") == "2027-01-03")
        #expect(try p("every! 3 days") == "2026-10-30")
        #expect(try p("after 10 days") == "2026-10-30")
        #expect(try p("every fri at noon") == "2026-11-06 12:00")
        let d = try DueParser.parse("Every Mon, Fri at 9am", context: ctx)
        #expect(d.isRecurring && d.string == "Every Mon, Fri at 9am")
    }

    @Test func recurringNext() throws {
        #expect(try next("every day", after: "2026-10-30 14:00") == "2026-10-31")
        #expect(try next("every day", from: "2026-10-25", after: "2026-10-30 14:00") == "2026-10-31") // overdue: skip to future
        #expect(try next("every day at 9am", after: "2026-10-31 09:05") == "2026-11-01 09:00")
        #expect(try next("every weekday", after: "2026-10-30 14:00") == "2026-11-02")
        #expect(try next("every monday", after: "2026-11-02 10:00") == "2026-11-09")
        #expect(try next("every mon, fri at 9am", after: "2026-11-02 10:00") == "2026-11-06 09:00")
        #expect(try next("every wed and fri at 9am", from: "2026-11-04", after: "2026-11-04 10:00") == "2026-11-06 09:00")
        #expect(try next("every 2 weeks", after: "2026-10-30 14:00") == "2026-11-13")
        #expect(try next("every 2 weeks", after: "2026-11-20 14:00") == "2026-11-27") // keeps cadence
        #expect(try next("every month", after: "2026-10-30 14:00") == "2026-11-30")
        #expect(try next("every month", from: "2027-01-31", after: "2027-01-31 10:00") == "2027-02-28")
        #expect(try next("every 15th", after: "2026-11-15 10:00") == "2026-12-15")
        #expect(try next("every 31st", from: "2026-10-31", after: "2026-10-31 10:00") == "2026-11-30")
        #expect(try next("every jan 3", after: "2027-01-03 10:00") == "2028-01-03")
        #expect(try next("every year", after: "2026-10-30 14:00") == "2027-10-30")
        #expect(try next("every hour", after: "2026-10-30 14:00") == "2026-10-30 15:00")
        #expect(try next("every 3 hours", after: "2026-10-30 18:30") == "2026-10-30 20:00")
        #expect(try next("every 12 hours starting at 9pm", after: "2026-10-30 21:10") == "2026-10-31 09:00")
        // date-only: completing early still moves past the current due date
        #expect(try next("every day", from: "2026-11-01", after: "2026-10-30 14:00") == "2026-11-02")
    }

    @Test func recurringFromCompletion() throws {
        // every vs every!: due 10-30, completed 11-04
        #expect(try next("every 3 days", after: "2026-11-04 10:00") == "2026-11-05")
        #expect(try next("every! 3 days", after: "2026-11-04 10:00") == "2026-11-07")
        #expect(try next("after 10 days", after: "2026-11-04 10:00") == "2026-11-14")
        #expect(try next("every! 3 hours", after: "2026-10-30 15:20") == "2026-10-30 18:20")
        #expect(try next("every! 2 months", after: "2026-11-04 10:00") == "2027-01-04")
        #expect(try next("every! day at 9am", after: "2026-11-04 10:00") == "2026-11-05 09:00")
        #expect(try next("every! monday", after: "2026-11-04 10:00") == "2026-11-09")
        #expect(try next("every! mon at 9am", from: "2026-11-02 09:00", after: "2026-11-02 08:00") == "2026-11-02 09:00")
    }
}
