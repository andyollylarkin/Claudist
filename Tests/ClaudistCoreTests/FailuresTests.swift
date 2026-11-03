import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct FailuresTests {
    @Test func latestFailedRunsUntilDismissed() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "P")
        let failed = TaskItem(projectId: p.id, content: "failed")
        let recovered = TaskItem(projectId: p.id, content: "recovered")
        var done = TaskItem(projectId: p.id, content: "done")
        done.isCompleted = true
        var failRun = Run(taskId: failed.id, agentId: nil)
        try db.writer.write { db in
            try p.insert(db)
            for t in [failed, recovered, done] { try t.insert(db) }
            failRun.status = .failed; failRun.error = "boom"; failRun.startedAt = "2026-11-01 10:00"
            try failRun.insert(db)
            var old = Run(taskId: recovered.id, agentId: nil); old.status = .failed; old.startedAt = "2026-11-01 09:00"
            var ok = Run(taskId: recovered.id, agentId: nil); ok.status = .done; ok.startedAt = "2026-11-01 11:00"
            try old.insert(db)
            try ok.insert(db)
            var doneRun = Run(taskId: done.id, agentId: nil); doneRun.status = .failed
            try doneRun.insert(db)
        }
        let items = try db.writer.read { try Failures.items($0) }
        #expect(items.map(\.task.content) == ["failed"])
        #expect(items.first?.run.error == "boom")
        #expect(try db.writer.read { try Failures.count($0) } == 1)

        try db.writer.write { try Failures.dismiss($0, runId: failRun.id) }
        #expect(try db.writer.read { try Failures.count($0) } == 0)
    }
}

struct ReviewsTests {
    @Test func finishedRunsUntilOpened() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "P")
        let done = TaskItem(projectId: p.id, content: "done")
        let sub = TaskItem(projectId: p.id, content: "sub")
        let running = TaskItem(projectId: p.id, content: "running")
        try db.writer.write { db in
            try p.insert(db)
            for t in [done, sub, running] { try t.insert(db) }
            var r = Run(taskId: done.id, agentId: nil); r.status = .done
            try r.insert(db)
            var e = RunEvent(runId: r.id, kind: "result/success", json: #"{"result":"All set"}"#)
            try e.insert(db)
            var s = Run(taskId: sub.id, agentId: nil, trigger: "agent"); s.status = .done
            try s.insert(db)
            var x = Run(taskId: running.id, agentId: nil); x.status = .running
            try x.insert(db)
        }
        let items = try db.writer.read { try Reviews.items($0) }
        #expect(items.map(\.task.content) == ["done"])
        #expect(items.first?.result == "All set")
        try db.writer.write { try Reviews.markReviewed($0, taskId: done.id) }
        #expect(try db.writer.read { try Reviews.count($0) } == 0)
    }
}

struct RunStatsTests {
    @Test func countsOneDay() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "P")
        let a = TaskItem(projectId: p.id, content: "a")
        let b = TaskItem(projectId: p.id, content: "b")
        try db.writer.write { db in
            try p.insert(db)
            try a.insert(db)
            try b.insert(db)
            func run(_ t: TaskItem, _ s: RunStatus, _ at: String, _ end: String?, cost: Double = 0) throws {
                var r = Run(taskId: t.id, agentId: nil); r.status = s; r.startedAt = at; r.endedAt = end; r.costUsd = cost
                try r.insert(db)
            }
            try run(a, .failed, "2026-11-02 09:10", "2026-11-02 09:15", cost: 0.5)
            try run(a, .done, "2026-11-02 10:00", "2026-11-02 10:20", cost: 1)
            try run(b, .cancelled, "2026-11-02 10:30", "2026-11-02 10:31")
            try run(b, .done, "2026-11-03 08:00", "2026-11-03 08:01")
        }
        let s = try db.writer.read { try RunStats.load($0, day: "2026-11-02") }
        #expect(s.total.runs == 3)
        #expect(s.total.done == 1 && s.total.failed == 1 && s.total.cancelled == 1)
        #expect(s.total.successRate == 0.5)
        #expect(s.total.cost == 1.5)
        #expect(s.total.minutes == 26)
        #expect(s.hours[10].runs == 2)
        #expect(s.tasks.map(\.task.content) == ["b", "a"])
        #expect(s.tasks.last?.counts.runs == 2)
        #expect(s.tasks.last?.lastStatus == .done)
    }
}
