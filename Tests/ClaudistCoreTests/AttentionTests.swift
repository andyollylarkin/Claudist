import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct AttentionTests {
    @Test func marksClearsAndFilters() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "P")
        let asked = TaskItem(projectId: p.id, content: "asked")
        let waiting = TaskItem(projectId: p.id, content: "waiting")
        let calm = TaskItem(projectId: p.id, content: "calm")
        try db.writer.write { db in
            try p.insert(db)
            for t in [asked, waiting, calm] { try t.insert(db) }
            try Attention.mark(db, taskId: asked.id, question: "Which DB?", options: ["Postgres", "SQLite"])
            var old = Run(taskId: waiting.id, agentId: nil); old.status = .done; old.startedAt = "2026-10-30 10:00"
            var live = Run(taskId: waiting.id, agentId: nil); live.status = .waiting; live.startedAt = "2026-10-31 10:00"
            try old.insert(db)
            try live.insert(db)
            var calmRun = Run(taskId: calm.id, agentId: nil); calmRun.status = .waiting; calmRun.startedAt = "2026-10-30 09:00"
            var calmLater = Run(taskId: calm.id, agentId: nil); calmLater.status = .done; calmLater.startedAt = "2026-10-31 09:00"
            try calmRun.insert(db)
            try calmLater.insert(db)
        }
        let names = try db.writer.read { try Attention.tasks($0).map(\.content) }
        #expect(Set(names) == ["asked", "waiting"])
        #expect(try db.writer.read { try Attention.count($0) } == 2)

        let stored = try db.writer.read { try TaskItem.fetchOne($0, key: asked.id)! }
        #expect(stored.attention == "Which DB?")
        #expect(stored.attentionChoices == ["Postgres", "SQLite"])

        let filtered = try db.writer.read {
            try FilterEngine.tasks($0, query: "needs you", context: FilterContext(now: Date()))[0].tasks.map(\.content)
        }
        #expect(Set(filtered) == ["asked", "waiting"])

        try db.writer.write { try Attention.clear($0, taskId: asked.id) }
        #expect(try db.writer.read { try Attention.count($0) } == 1)
    }
}
