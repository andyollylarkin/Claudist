import Foundation
import GRDB
@testable import ClaudistCore

/// Fixed clock: Friday 2026-10-30 14:00 in Europe/Moscow.
enum TestClock {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }()

    static func date(_ s: String) -> Date { LocalDate.parse(s, calendar: calendar)! }

    static let context = FilterContext(now: date("2026-10-30 14:00"), calendar: calendar, currentUser: "Denis")
}

/// In-memory DB seeded with projects, sections, labels, agents, runs and tasks.
struct FilterFixture {
    let db: AppDatabase
    let ctx = TestClock.context

    init() throws {
        db = try AppDatabase.inMemory()
        try db.writer.write { db in
            func project(_ name: String, parent: Project? = nil, archived: Bool = false) throws -> Project {
                var p = Project(name: name, parentId: parent?.id)
                p.isArchived = archived
                try p.insert(db)
                return p
            }
            let work = try project("Work")
            let backend = try project("Backend", parent: work)
            let api = try project("API", parent: backend)
            let home = try project("Home")
            let archive = try project("Old", archived: true)
            let life = try project("Life & Stuff")
            let rabota = try project("Работа")
            let homework = try project("Homework")
            _ = try project("100%_done")

            let meetings = Section(projectId: work.id, name: "Meetings")
            try meetings.insert(db)
            let garden = Section(projectId: home.id, name: "Garden")
            try garden.insert(db)

            var labels: [String: Label] = [:]
            for n in ["home", "homework", "email", "urgent", "Срочно"] {
                let l = Label(name: n)
                try l.insert(db)
                labels[n] = l
            }

            let researcher = Agent(name: "Researcher", folderPath: "/tmp/r")
            try researcher.insert(db)
            let coder = Agent(name: "Coder", folderPath: "/tmp/c")
            try coder.insert(db)

            var order = 0
            @discardableResult
            func task(_ content: String, _ p: Project, due: String? = nil, time: String? = nil, priority: Int = 4,
                      labels names: [String] = [], section: Section? = nil, parent: TaskItem? = nil,
                      deadline: String? = nil, agent: Agent? = nil, recurring: Bool = false,
                      created: String = "2026-10-20 10:00", completedAt: String? = nil) throws -> TaskItem {
                var t = TaskItem(projectId: p.id, content: content)
                t.dueDate = due
                t.dueTime = time
                t.priority = priority
                t.sectionId = section?.id
                t.parentId = parent?.id
                t.deadline = deadline
                t.agentId = agent?.id
                t.isRecurring = recurring
                t.dueString = recurring ? "every monday" : nil
                t.createdAt = created
                if let completedAt { t.isCompleted = true; t.completedAt = completedAt }
                order += 1
                t.childOrder = order
                try t.insert(db)
                for n in names { try TaskLabel(taskId: t.id, labelId: labels[n]!.id).insert(db) }
                return t
            }

            try task("today", work, due: "2026-10-30", priority: 1, labels: ["email"])
            let am = try task("today am", work, due: "2026-10-30", time: "10:00", section: meetings, agent: researcher)
            try task("today pm", work, due: "2026-10-30", time: "18:00", priority: 2)
            try task("overdue", home, due: "2026-10-28", priority: 2, labels: ["home"])
            try task("tomorrow", backend, due: "2026-10-31", labels: ["homework"], agent: coder)
            let apiTask = try task("api", api, due: "2026-11-03", priority: 3)
            try task("sub", api, parent: apiTask)
            try task("nodate", home, labels: ["urgent", "Срочно"], section: garden)
            try task("deadline only", home, deadline: "2026-11-02")
            try task("deadline and date", home, due: "2026-11-10", deadline: "2026-11-01")
            try task("recurring", home, due: "2026-11-02", recurring: true)
            try task("next thu", home, due: "2026-11-05")
            try task("far", home, due: "2026-12-15", created: "2026-01-03 09:00")
            try task("done", work, due: "2026-10-29", completedAt: "2026-10-29 18:00")
            try task("done old", work, completedAt: "2026-09-01 08:00")
            try task("archived", archive, due: "2026-10-30")
            try task("life", life)
            try task("rabota", rabota)
            try task("hw", homework)
            try task("* Header", home)
            try task("Send EMAIL to bob", home, due: "2026-10-25")
            try task("100% sure", home)
            try task("yesterday", home, due: "2026-10-29", time: "09:00", created: "2026-10-29 08:00")
            try task("last week", home, due: "2026-10-21", created: "2026-10-30 09:00")

            var r1 = Run(taskId: apiTask.id, agentId: coder.id)
            r1.status = .done; r1.startedAt = "2026-10-28 10:00"
            try r1.insert(db)
            var r2 = Run(taskId: apiTask.id, agentId: coder.id)
            r2.status = .failed; r2.startedAt = "2026-10-29 12:00"
            try r2.insert(db)
            var r3 = Run(taskId: am.id, agentId: researcher.id)
            r3.status = .running; r3.startedAt = "2026-10-30 13:00"
            try r3.insert(db)
        }
    }

    func groups(_ query: String) throws -> [(title: String, names: [String])] {
        try db.writer.read { db in
            try FilterEngine.tasks(db, query: query, context: ctx).map { ($0.title, $0.tasks.map(\.content)) }
        }
    }

    /// Contents of the single group, as a set.
    func names(_ query: String) throws -> Set<String> {
        let g = try groups(query)
        precondition(g.count == 1, "expected one group for \(query)")
        return Set(g[0].names)
    }

    /// All open, non-archived task names.
    var allOpen: Set<String> { get throws { try names("view all") } }
}
