import Foundation
import Testing
@testable import ClaudistCore

/// Every example shown in the app's syntax help must parse.
struct SyntaxHelpExamplesTests {
    static let filters = [
        "today & p1", "today | overdue", "!subtask", "(today | overdue) & #Work", "today, tomorrow, no date",
        "today", "tomorrow", "yesterday", "overdue", "od", "7 days", "next 7 days", "-3 days", "no date", "no time",
        "date: next week", "date: this week", "date: next month", "date before: sat", "date after: Nov 5",
        "date before: +4 hours", "date: today at 18:00", "Nov 5", "11/5", "2026-11-05",
        "deadline: today", "no deadline", "deadline before: today", "created: -7 days", "created before: -7 days", "recurring",
        "#Work", "##Work", "/Doing", "#Work & /Doing", "@urgent", "no labels", "#Client*", "@home*", "#My\\ Project",
        "p1", "p2", "p3", "p4", "search: invoice", "subtask",
        "agent: Researcher", "assigned to: Researcher", "assigned", "run: running", "run: none", "run after: -1 day", "run before: -1 day",
        "needs you", "completed", "completed after: -7 days", "completed & #Work", "view all",
    ]

    static let dues = [
        "today", "tod", "tomorrow", "tom", "monday", "next monday", "fri", "tomorrow 9am", "fri 7pm", "today at 17:30",
        "at 5pm", "17:30", "Jan 3", "3 Jan 2027", "2026-11-05", "1/3/2027", "27th", "in 3 days", "+2 weeks", "in 1 month",
        "next week", "next month", "this weekend", "end of month", "mid january", "tomorrow morning", "today evening",
        "every day", "daily", "every weekday", "every workday", "every weekend", "every monday", "every mon, fri",
        "every mon, fri at 9am", "every week", "weekly", "every 2 weeks", "every other day", "every other fri",
        "every month", "every 15th", "every 2, 15, 27", "every last day", "every quarter", "every year", "every jan 3",
        "every hour", "every 3 hours", "every monday starting jan 5", "every monday from jan 5", "every! 3 days", "after 2 weeks",
    ]

    @Test func filterExamplesParse() {
        for q in Self.filters {
            #expect(throws: Never.self, "\(q)") { _ = try FilterQuery.parse(q) }
        }
    }

    @Test func dueExamplesParse() {
        let ctx = FilterContext(now: Date())
        for d in Self.dues {
            #expect(throws: Never.self, "\(d)") { _ = try DueParser.parse(d, context: ctx) }
        }
    }
}
