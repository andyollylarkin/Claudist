import Testing
import GRDB
@testable import ClaudistCore

@Suite struct FilterEngineTests {
    let f: FilterFixture
    init() throws { f = try FilterFixture() }

    let overdueSet: Set<String> = ["overdue", "today am", "Send EMAIL to bob", "yesterday", "last week"]
    let noDateSet: Set<String> = ["sub", "nodate", "deadline only", "life", "rabota", "hw", "* Header", "100% sure"]

    @Test func implicitRules() throws {
        let all = try f.allOpen
        #expect(all.count == 21)
        #expect(!all.contains("done"))      // completed hidden
        #expect(!all.contains("archived"))  // archived project hidden
    }

    @Test func basicDates() throws {
        #expect(try f.names("today") == ["today", "today am", "today pm"])
        #expect(try f.names("tomorrow") == ["tomorrow"])
        #expect(try f.names("yesterday") == ["yesterday"])
        #expect(try f.names("overdue") == overdueSet)
        #expect(try f.names("od") == overdueSet)
        #expect(try f.names("no date") == noDateSet)
        #expect(try f.names("!no date").isDisjoint(with: noDateSet))
        #expect(try f.names("no time") == ["today", "overdue", "tomorrow", "api", "deadline and date", "recurring",
                                           "next thu", "far", "Send EMAIL to bob", "last week"])
        #expect(try f.names("!no date & !no time") == ["today am", "today pm", "yesterday"])
        #expect(try f.names("overdue & !no time") == ["today am", "yesterday"])
    }

    @Test func dateRanges() throws {
        let fiveDays: Set<String> = ["today", "today am", "today pm", "tomorrow", "api", "recurring"]
        #expect(try f.names("5 days") == fiveDays)
        #expect(try f.names("next 5 days") == fiveDays)
        #expect(try f.names("-3 days") == ["overdue", "yesterday"])
        #expect(try f.names("date: next week") == ["api", "recurring", "next thu"])
        #expect(try f.names("(date: next week | date after: next week) & date before: 1 week after next week")
                == ["api", "recurring", "next thu"])
        #expect(try f.names("date: this week") == ["today", "today am", "today pm", "tomorrow", "overdue", "yesterday"])
        #expect(try f.names("date before: sat") == overdueSet.union(["today", "today pm"]))
        #expect(try f.names("date after: Nov 5") == ["deadline and date", "far"])
        #expect(try f.names("date before: first day") == overdueSet.union(["today", "today pm", "tomorrow"]))
        #expect(try f.names("date: next month") == ["api", "recurring", "next thu", "deadline and date"])
        #expect(try f.names("Nov 5") == ["next thu"])
        #expect(try f.names("11/5") == ["next thu"])
        #expect(try f.names("5 Nov 2026") == ["next thu"])
        #expect(try f.names("date: 2026-11-05") == ["next thu"])
        #expect(try f.names("sat") == ["tomorrow"])
        #expect(try f.names("thursday") == ["next thu"])
        #expect(try f.names("next tue") == ["api"])
    }

    @Test func dateTimes() throws {
        // timed before 18:00 today, plus earlier days; untimed today tasks don't count
        #expect(try f.names("date before: +4 hours") == overdueSet)
        #expect(try f.names("date: today & date before: today at 2pm") == ["today am"])
        #expect(try f.names("today & date after: today at 2pm") == ["today pm"])
        #expect(try f.names("date: today at 18:00") == ["today pm"])
        #expect(try f.names("date: today at 6pm") == ["today pm"])
    }

    @Test func dueUsesDeadlineFallback() throws {
        #expect(try f.names("due: next week") == ["api", "recurring", "next thu", "deadline only"])
        #expect(try f.names("due before: Nov 3") == overdueSet.union(["today", "today pm", "tomorrow", "recurring", "deadline only"]))
        #expect(try f.names("due after: Nov 9") == ["deadline and date", "far"])
    }

    @Test func deadlines() throws {
        #expect(try f.names("deadline: today").isEmpty)
        #expect(try f.names("deadline: nov 2") == ["deadline only"])
        #expect(try f.names("deadline after: yesterday & deadline before: in 7 days") == ["deadline only", "deadline and date"])
        #expect(try f.names("deadline before: today").isEmpty)
        #expect(try f.names("!no deadline") == ["deadline only", "deadline and date"])
        #expect(try f.names("no date & no deadline") == noDateSet.subtracting(["deadline only"]))
    }

    @Test func created() throws {
        #expect(try f.names("created: today") == ["last week"])
        #expect(try f.names("created: yesterday") == ["yesterday"])
        #expect(try f.names("created: Jan 3") == ["far"])
        #expect(try f.names("created before: -30 days") == ["far"])
        #expect(try f.names("created after: yesterday") == ["last week"])
        #expect(try f.names("created after: today at 8:30") == ["last week"])
        #expect(try f.names("created before: -365 days").isEmpty)
    }

    @Test func showCompletedSwitch() throws {
        let tasks = try f.db.writer.read { db in
            try FilterEngine.tasks(db, query: "view all", context: f.ctx, includeCompleted: true)[0].tasks
        }
        let names = tasks.map(\.content)
        let open = try f.allOpen
        #expect(Set(names) == open.union(["done", "done old"]))
        // Open tasks first, completed after them.
        #expect(Set(names.suffix(2)) == ["done", "done old"])
        #expect(!names.contains("archived"))
    }

    @Test func completed() throws {
        #expect(try f.names("completed") == ["done", "done old"])
        #expect(try f.names("completed after: -7 days") == ["done"])
        #expect(try f.names("completed before: Oct 1") == ["done old"])
        #expect(try f.names("completed: yesterday") == ["done"])
        #expect(try f.names("completed & date: yesterday") == ["done"])
        #expect(try f.names("!completed & #Work") == ["today", "today am", "today pm"])
        #expect(try f.names("#Work").isDisjoint(with: ["done", "done old"]))
    }

    @Test func projectsAndSections() throws {
        #expect(try f.names("#Work") == ["today", "today am", "today pm"])
        #expect(try f.names("#work") == ["today", "today am", "today pm"])
        #expect(try f.names("##Work") == ["today", "today am", "today pm", "tomorrow", "api", "sub"])
        #expect(try f.names("##Backend") == ["tomorrow", "api", "sub"])
        #expect(try f.names("##Work & !#API") == ["today", "today am", "today pm", "tomorrow"])
        #expect(try f.names("#*work") == ["today", "today am", "today pm", "hw"])
        #expect(try f.names("##*work") == ["today", "today am", "today pm", "tomorrow", "api", "sub", "hw"])
        #expect(try f.names("#Old").isEmpty)
        #expect(try f.names("#Nope").isEmpty)
        #expect(try f.names("#Life \\& Stuff") == ["life"])
        #expect(try f.names("#РАБОТА") == ["rabota"])
        #expect(try f.names("/Meetings") == ["today am"])
        #expect(try f.names("#Work & /Meetings") == ["today am"])
        #expect(try f.names("#Home & /Meetings").isEmpty)
        #expect(try f.names("/*") == ["today am", "nodate"])
        #expect(try f.names("/*den") == ["nodate"])
        #expect(try f.names("!/*").count == 19)
        #expect(try f.names("!/* & !#Home") == ["today", "today pm", "tomorrow", "api", "sub", "life", "rabota", "hw"])
    }

    @Test func labels() throws {
        #expect(try f.names("@home") == ["overdue"])
        #expect(try f.names("%home") == ["overdue"])
        #expect(try f.names("@HOME*") == ["overdue", "tomorrow"])
        #expect(try f.names("%email & today") == ["today"])
        #expect(try f.names("@срочно") == ["nodate"])
        #expect(try f.names("@urgent & @срочно") == ["nodate"])
        #expect(try f.names("no labels").count == 17)
        #expect(try f.names("!no labels") == ["today", "overdue", "tomorrow", "nodate"])
    }

    @Test func priorities() throws {
        #expect(try f.names("p1") == ["today"])
        #expect(try f.names("P2") == ["today pm", "overdue"])
        #expect(try f.names("p3") == ["api"])
        #expect(try f.names("p4") == f.names("no priority"))
        #expect(try f.names("p4").count == 17)
        #expect(try f.names("(P1 | P2) & 14 days") == ["today", "today pm"])
    }

    @Test func precedenceAgainstData() throws {
        #expect(try f.names("p1 | p2 & overdue") == ["today", "overdue"])
        #expect(try f.names("(p1 | p2) & overdue") == ["overdue"])
        #expect(try f.names("!p1 & today") == ["today am", "today pm"])
        #expect(try f.names("!(p1 | today)").count == 18)
        #expect(try f.names("(today | overdue) & #Work") == ["today", "today am", "today pm"])
        #expect(try f.names("today & !#Work").isEmpty)
        #expect(try f.names("#Homework & tomorrow & !@languages").isEmpty)
    }

    @Test func notTreatsNullAsNoMatch() throws {
        // tasks without a date are not "before today", so !(date before: today) includes them
        let notBefore = try f.names("!(date before: today)")
        #expect(notBefore.isSuperset(of: noDateSet))
        #expect(notBefore.isDisjoint(with: ["overdue", "yesterday"]))
        #expect(try f.names("!deadline: nov 2").count == 20)
    }

    @Test func groups() throws {
        let g = try f.groups("p1 & overdue, p4 & today")
        #expect(g.map(\.title) == ["p1 & overdue", "p4 & today"])
        #expect(g[0].names.isEmpty)
        #expect(Set(g[1].names) == ["today am"])
        let d = try f.groups("date: yesterday, today")
        #expect(d.count == 2)
        #expect(d[0].names == ["yesterday"])
        #expect(d[1].names == ["today am", "today pm", "today"]) // timed first, then untimed
    }

    @Test func ordering() throws {
        let g = try f.groups("5 days | no date")
        #expect(Array(g[0].names.prefix(6)) == ["today am", "today pm", "today", "tomorrow", "recurring", "api"])
        #expect(Set(g[0].names.suffix(8)) == noDateSet)
    }

    @Test func search() throws {
        #expect(try f.names("search: email") == ["Send EMAIL to bob"])
        #expect(try f.names("search: send email") == ["Send EMAIL to bob"])
        #expect(try f.names("search: email & today").isEmpty)
        #expect(try f.names("search: email | search: header") == ["Send EMAIL to bob", "* Header"])
        #expect(try f.names("search: %") == ["100% sure"])  // LIKE metacharacters are escaped
        #expect(try f.names("search: _").isEmpty)
        #expect(try f.names("search: *").count == 1)        // literal star
    }

    @Test func misc() throws {
        #expect(try f.names("recurring") == ["recurring"])
        #expect(try f.names("!recurring").count == 20)
        #expect(try f.names("no time & !recurring").count == 9)
        #expect(try f.names("subtask") == ["sub"])
        #expect(try f.names("!subtask").count == 20)
        #expect(try f.names("shared").isEmpty)
        #expect(try f.names("shared & !assigned").isEmpty)
        #expect(try f.names("uncompletable") == ["* Header"])
        #expect(try f.allOpen == f.names("all"))
    }

    @Test func assignment() throws {
        #expect(try f.names("assigned") == ["today am", "tomorrow"])
        #expect(try f.names("assigned to: others") == ["today am", "tomorrow"])
        #expect(try f.names("!assigned").count == 19)
        #expect(try f.names("assigned to: me") == f.names("!assigned"))
        #expect(try f.names("assigned to: denis") == f.names("!assigned")) // currentUser
        #expect(try f.names("assigned to: Res*") == ["today am"])
        #expect(try f.names("assigned to: researcher") == ["today am"])
        #expect(try f.names("agent: coder") == ["tomorrow"])
        #expect(try f.names("agent: *er") == ["today am", "tomorrow"])
        let g = try f.groups("assigned to: Researcher, assigned to: Coder")
        #expect(g.map(\.names) == [["today am"], ["tomorrow"]])
        #expect(try f.names("#Work & assigned to: me") == ["today", "today pm"])
    }

    @Test func runs() throws {
        #expect(try f.names("run") == ["api", "today am"])
        #expect(try f.names("!run").count == 19)
        #expect(try f.names("run: none").count == 19)
        #expect(try f.names("run: failed") == ["api"])
        #expect(try f.names("run: done").isEmpty) // only the latest run counts
        #expect(try f.names("run: running") == ["today am"])
        #expect(try f.names("run: queued").isEmpty)
        #expect(try f.names("run after: yesterday") == ["today am"])
        #expect(try f.names("run: yesterday") == ["api"])
        #expect(try f.names("run before: today") == ["api"])
        #expect(try f.names("run after: today at 12:30") == ["today am"])
    }

    @Test func compileProducesBoundArguments() throws {
        let e = try FilterQuery.parse("#Work' OR 1=1 --")[0].expr
        let (sql, args) = try FilterSQL.compile(e, context: f.ctx)
        #expect(!sql.contains("OR 1=1"))
        #expect(args.description.contains("or 1=1 --"))
        #expect(try f.names("#Work' OR 1=1 --").isEmpty)
    }
}
