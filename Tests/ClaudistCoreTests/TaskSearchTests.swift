import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct TaskSearchTests {
    @Test func findsByWordPrefixesInTitleAndDescriptionAndFollowsChanges() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "P")
        var topology = TaskItem(projectId: p.id, content: "USTOR-4338 Настраиваемый ключ топологии")
        topology.description = "Флаг --topology-key прокинуть в драйвер"
        var mention = TaskItem(projectId: p.id, content: "Ревью")
        mention.description = "проверить ключ топологии после правок"
        var done = TaskItem(projectId: p.id, content: "Старая задача про топологию")
        done.isCompleted = true
        try db.writer.write { db in
            try p.insert(db)
            for t in [done, topology, mention] { try t.insert(db) }
        }
        func search(_ text: String) throws -> [String] {
            try db.writer.read { try TaskSearch.tasks($0, text: text).map(\.content) }
        }

        // Case-insensitive Cyrillic prefixes; the title match ranks above the description match.
        #expect(try search("ключ топол") == [topology.content, mention.content])
        #expect(try search("драйв") == [topology.content])
        #expect(try search("ustor-4338") == [topology.content])
        // Completed tasks come last.
        #expect(try search("топол").last == done.content)
        #expect(try search("").isEmpty)
        #expect(try search("\"(*").isEmpty)

        try db.writer.write { db in
            topology.content = "Другое название"
            topology.description = ""
            try topology.update(db)
            _ = try TaskItem.deleteOne(db, key: mention.id)
        }
        #expect(try search("ключ").isEmpty)
        #expect(try search("другое") == ["Другое название"])
    }
}
