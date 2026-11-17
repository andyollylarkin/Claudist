import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct FlagTests {
    @Test func flaggedFilterFindsFlaggedTasks() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "P")
        var flagged = TaskItem(projectId: p.id, content: "flagged")
        flagged.isFlagged = true
        let plain = TaskItem(projectId: p.id, content: "plain")
        try db.writer.write { db in
            try p.insert(db)
            try flagged.insert(db)
            try plain.insert(db)
        }
        func names(_ query: String) throws -> [String] {
            try db.writer.read { try FilterEngine.tasks($0, query: query, context: FilterContext(now: Date())).flatMap(\.tasks).map(\.content) }
        }
        #expect(try names("flagged") == ["flagged"])
        #expect(try names("!flagged") == ["plain"])
        #expect(try names("flag & #P") == ["flagged"])

        // The migration adds a ready "Flagged" filter.
        let filter = try db.writer.read { try SavedFilter.filter(Column("name") == "Flagged").fetchOne($0) }
        #expect(filter?.query == "flagged")
    }
}
