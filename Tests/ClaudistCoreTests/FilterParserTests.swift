import Testing
@testable import ClaudistCore

@Suite struct FilterParserTests {
    func expr(_ s: String) throws -> FilterExpr {
        let g = try FilterQuery.parse(s)
        #expect(g.count == 1)
        return g[0].expr
    }

    func error(_ s: String) -> FilterError? {
        do { _ = try FilterQuery.parse(s); return nil } catch let e as FilterError { return e } catch { return nil }
    }

    @Test func precedenceNotAndOr() throws {
        #expect(try expr("p1 | p2 & overdue") == .or(.priority(1), .and(.priority(2), .overdue)))
        #expect(try expr("p1 & p2 | overdue") == .or(.and(.priority(1), .priority(2)), .overdue))
        #expect(try expr("!p1 & p2") == .and(.not(.priority(1)), .priority(2)))
        #expect(try expr("!(p1 | p2)") == .not(.or(.priority(1), .priority(2))))
        #expect(try expr("(p1 | p2) & overdue") == .and(.or(.priority(1), .priority(2)), .overdue))
        #expect(try expr("!!subtask") == .not(.not(.subtask)))
    }

    @Test func groupsAndTitles() throws {
        let g = try FilterQuery.parse(" p1 & overdue ,  p4 & today ")
        #expect(g.map(\.title) == ["p1 & overdue", "p4 & today"])
        #expect(g[1].expr == .and(.priority(4), .date(.date, .on, .days(0))))
        let d = try FilterQuery.parse("date: yesterday, today")
        #expect(d.map(\.title) == ["date: yesterday", "today"])
        #expect(d[0].expr == .date(.date, .on, .days(-1)))
    }

    @Test func commaInsideParenthesesIsAnError() {
        let e = error("(today, overdue)")
        #expect(e?.message.contains("Commas can't be used inside parentheses") == true)
        #expect(e?.position == 6)
    }

    @Test func errors() {
        #expect(error("")?.message == "Empty filter query")
        #expect(error("today &")?.message == "Expected a filter term")
        #expect(error("today &")?.position == 7)
        #expect(error("& today")?.message == "Expected a filter term before '&'")
        #expect(error("(today")?.message == "Missing ')'")
        #expect(error("(today")?.position == 0)
        #expect(error("today)")?.message == "Unmatched ')'")
        #expect(error("(today) p1")?.message == "Expected '&', '|' or ','")
        #expect(error("today,")?.message == "Expected a filter term")
        #expect(error("foo bar")?.message == "Unknown filter 'foo bar'")
        #expect(error("p1 & foo")?.position == 5)
        #expect(error("#")?.message == "Expected a project name after '#'")
        #expect(error("##  ")?.message == "Expected a project name after '##'")
        #expect(error("@")?.message == "Expected a label name after '@'")
        #expect(error("frobnicate: x")?.message == "Unknown filter keyword 'frobnicate:'")
        #expect(error("assigned by: me")?.message == "'assigned by:' is not supported in Claudist")
        #expect(error("search:")?.message == "Expected text after 'search:'")
        let d = error("date before: blah")
        #expect(d?.message == "Unknown date 'blah'")
        #expect(d?.position == 13)
        #expect(error("date: Feb 30")?.message == "Invalid day 30 for month 2")
        #expect(error("today at 25:00") != nil)
        #expect(error("run: exploded")?.message.contains("run status") == true)
        #expect(error("today \\")?.message == "Nothing to escape after '\\'")
        #expect(FilterError.syntax(position: 4, message: "Oops").description == "Oops (at position 5)")
    }

    @Test func names() throws {
        #expect(try expr("#Work") == .project(NamePattern("Work"), includeSubprojects: false))
        #expect(try expr("##Design team") == .project(NamePattern("Design team"), includeSubprojects: true))
        #expect(try expr("/Meetings") == .section(NamePattern("Meetings")))
        #expect(try expr("!/*") == .not(.section(NamePattern(parts: [.wildcard]))))
        #expect(try expr("#Work & /Meetings") == .and(.project(NamePattern("Work"), includeSubprojects: false), .section(NamePattern("Meetings"))))
        #expect(try expr("@home*") == .label(NamePattern(parts: [.literal("home"), .wildcard])))
        #expect(try expr("%email") == .label(NamePattern("email")))
        // Escapes: special characters become literal, \* is a literal star.
        #expect(try expr("#Life \\& Stuff") == .project(NamePattern("Life & Stuff"), includeSubprojects: false))
        #expect(try expr("#A\\*B") == .project(NamePattern(parts: [.literal("A*B")]), includeSubprojects: false))
        #expect(try expr("#Q\\(1\\)") == .project(NamePattern("Q(1)"), includeSubprojects: false))
        #expect(NamePattern(parts: [.literal("100%_\\")]).likePattern == "100\\%\\_\\\\")
    }

    @Test func keywords() throws {
        #expect(try expr("No Priority") == .priority(4))
        #expect(try expr("od") == .overdue)
        #expect(try expr("no due date") == .noDate)
        #expect(try expr("no   time") == .noTime)
        #expect(try expr("no labels") == .noLabels)
        #expect(try expr("no deadline") == .noDeadline)
        #expect(try expr("view all") == .all)
        #expect(try expr("recurring") == .recurring)
        #expect(try expr("subtask") == .subtask)
        #expect(try expr("shared") == .shared)
        #expect(try expr("assigned") == .assigned)
        #expect(try expr("uncompletable") == .uncompletable)
        #expect(try expr("search: send email") == .search("send email"))
        #expect(try expr("assigned to: me") == .assignedTo(.me))
        #expect(try expr("assigned to: others") == .assignedTo(.others))
        #expect(try expr("assigned to: m* smith") == .assignedTo(.named(NamePattern("m* smith"))))
        #expect(try expr("agent: Coder") == .assignedTo(.named(NamePattern("Coder"))))
        #expect(try expr("completed") == .completed)
        #expect(try expr("run") == .run(nil))
        #expect(try expr("run: failed") == .run(.failed))
        #expect(try expr("run: none") == .not(.run(nil)))
    }

    @Test func dates() throws {
        #expect(try expr("today") == .date(.date, .on, .days(0)))
        #expect(try expr("tom") == .date(.date, .on, .days(1)))
        #expect(try expr("5 days") == .date(.date, .on, .nextDays(5)))
        #expect(try expr("next 5 days") == .date(.date, .on, .nextDays(5)))
        #expect(try expr("-3 days") == .date(.date, .on, .pastDays(3)))
        #expect(try expr("+3 days") == .date(.date, .on, .days(3)))
        #expect(try expr("Jan 3") == .date(.date, .on, .monthDay(month: 1, day: 3, year: nil)))
        #expect(try expr("3 jan 2027") == .date(.date, .on, .monthDay(month: 1, day: 3, year: 2027)))
        #expect(try expr("date before: 5/5") == .date(.date, .before, .monthDay(month: 5, day: 5, year: nil)))
        #expect(try expr("date: 27/1/2027") == .date(.date, .on, .monthDay(month: 1, day: 27, year: 2027)))
        #expect(try expr("date: 2026-11-05") == .date(.date, .on, .monthDay(month: 11, day: 5, year: 2026)))
        #expect(try expr("Saturday") == .date(.date, .on, .weekday(5, next: false)))
        #expect(try expr("date before: sat") == .date(.date, .before, .weekday(5, next: false)))
        #expect(try expr("due before: +4 hours") == .date(.due, .before, .offset(4, .hour)))
        #expect(try expr("date: next week") == .date(.date, .on, .week(1)))
        #expect(try expr("date before: 1 week after next week") == .date(.date, .before, .shifted(1, .week, .week(1))))
        #expect(try expr("date before: first day") == .date(.date, .before, .dayOfMonth(1)))
        #expect(try expr("date before: today at 2pm") == .date(.date, .before, .at(.days(0), hour: 14, minute: 0)))
        #expect(try expr("today at 14:00") == .date(.date, .on, .at(.days(0), hour: 14, minute: 0)))
        #expect(try expr("deadline after: yesterday") == .date(.deadline, .after, .days(-1)))
        #expect(try expr("deadline before: in 7 days") == .date(.deadline, .before, .days(7)))
        #expect(try expr("created: Jan 3 2023") == .date(.created, .on, .monthDay(month: 1, day: 3, year: 2023)))
        #expect(try expr("created before: -365 days") == .date(.created, .before, .days(-365)))
        #expect(try expr("completed after: -7 days") == .date(.completed, .after, .days(-7)))
        #expect(try expr("run after: yesterday") == .date(.run, .after, .days(-1)))
        #expect(try expr("date: this month") == .date(.date, .on, .month(0)))
        #expect(try expr("date: mid jan") == .date(.date, .on, .monthDay(month: 1, day: 15, year: nil)))
        #expect(try expr("date: 27th") == .date(.date, .on, .dayOfMonth(27)))
        #expect(try expr("date: end of month") == .date(.date, .on, .lastDayOfMonth))
        #expect(try expr("date: 3 days ago") == .date(.date, .on, .days(-3)))
    }

    @Test func mentionsCompleted() throws {
        #expect(try expr("completed & today").mentionsCompleted)
        #expect(try expr("!(completed before: today)").mentionsCompleted)
        #expect(try !expr("today | p1").mentionsCompleted)
    }
}

@Suite struct DateResolutionTests {
    let ctx = TestClock.context

    func r(_ s: String, past: Bool = false) throws -> String {
        let x = try DateExprParser.parse(s, mode: .filter).resolve(ctx, preferPast: past)
        if let t = x.time { return "\(x.start) \(t)" }
        return x.start == x.end ? x.start.description : "\(x.start)..\(x.end)"
    }

    @Test func relative() throws {
        #expect(try r("today") == "2026-10-30")
        #expect(try r("yesterday") == "2026-10-29")
        #expect(try r("in 3 weeks") == "2026-11-20")
        #expect(try r("+4 hours") == "2026-10-30 18:00")
        #expect(try r("in 12 hours") == "2026-10-31 02:00")
        #expect(try r("next month") == "2026-11-01..2026-11-30")
        #expect(try r("this week") == "2026-10-26..2026-11-01")
        #expect(try r("next week") == "2026-11-02..2026-11-08")
        #expect(try r("last week") == "2026-10-19..2026-10-25")
        #expect(try r("1 week after next week") == "2026-11-09")
        #expect(try r("3 days before Jan 10") == "2027-01-07")
        #expect(try r("next 3 days") == "2026-10-30..2026-11-01")
        #expect(try r("this weekend") == "2026-10-31..2026-11-01")
        #expect(try r("next year") == "2027-01-01..2027-12-31")
        #expect(try r("first day") == "2026-11-01")
        #expect(try r("last day") == "2026-10-31")
    }

    @Test func weekdays() throws {
        #expect(try r("fri") == "2026-10-30")       // today counts
        #expect(try r("sat") == "2026-10-31")
        #expect(try r("thursday") == "2026-11-05")
        #expect(try r("next monday") == "2026-11-02") // Monday already passed this week → upcoming
        #expect(try r("next saturday") == "2026-11-07") // still ahead this week → following week
        #expect(try r("next friday") == "2026-11-06")
        #expect(try r("sat 7pm") == "2026-10-31 19:00")
        #expect(try r("sat at 7:30 pm") == "2026-10-31 19:30")
        #expect(try r("tom morning") == "2026-10-31 09:00")
    }

    @Test func explicitDays() throws {
        #expect(try r("Jan 3") == "2027-01-03")      // upcoming
        #expect(try r("Jan 3", past: true) == "2026-01-03") // created/completed: most recent
        #expect(try r("oct 30") == "2026-10-30")
        #expect(try r("30th") == "2026-10-30")
        #expect(try r("29th") == "2026-11-29")
        #expect(try r("29th", past: true) == "2026-10-29")
        #expect(try r("31st") == "2026-10-31")
        #expect(try r("12/25") == "2026-12-25")
        #expect(try r("25/12") == "2026-12-25")
        #expect(try r("1/3/2027") == "2027-01-03")
        #expect(try r("2027/01/03") == "2027-01-03")
        #expect(try r("feb 29") == "2027-02-28") // clamps in non-leap years
        #expect(try r("3rd jan 2027 at noon") == "2027-01-03 12:00")
        #expect(try r("12am") == "2026-10-30 00:00")
        #expect(try r("12pm") == "2026-10-30 12:00")
    }
}
