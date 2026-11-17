import Foundation
import GRDB

/// Full-text search over task titles and descriptions (SQLite FTS5).
public enum TaskSearch {
    static let table = "taskSearch"

    /// Tasks matching every word of `text` (each as a word prefix), best matches first, open before completed.
    /// A title match weighs more than a description match.
    public static func tasks(_ db: Database, text: String, limit: Int = 200) throws -> [TaskItem] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try TaskItem.fetchAll(db, sql: """
            SELECT task.* FROM task
            JOIN \(table) ON \(table).rowid = task.rowid
            WHERE \(table) MATCH ?
            ORDER BY task.isCompleted, bm25(\(table), 4.0, 1.0)
            LIMIT ?
            """, arguments: [pattern, limit])
    }
}
