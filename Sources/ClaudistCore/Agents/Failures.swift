import Foundation
import GRDB

/// "Failed": open tasks whose latest run failed and the user hasn't dismissed.
public enum Failures {
    public struct Item: Sendable, Identifiable, Hashable {
        public var id: ID { task.id }
        public var task: TaskItem
        public var run: Run
    }

    static let latestRun = "(SELECT r.id FROM run r WHERE r.taskId = t.id ORDER BY r.startedAt DESC, r.rowid DESC LIMIT 1)"

    public static func items(_ db: Database) throws -> [Item] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.*, r.id AS runId FROM task t JOIN run r ON r.id = \(latestRun)
             WHERE t.isCompleted = 0 AND r.status = 'failed' AND r.dismissed = 0
             ORDER BY COALESCE(r.endedAt, r.startedAt) DESC
            """)
        let runs = try Run.fetchAll(db, keys: rows.map { $0["runId"] as ID })
        let byId = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        return try rows.compactMap { row in
            guard let run = byId[row["runId"]] else { return nil }
            return Item(task: try TaskItem(row: row), run: run)
        }
    }

    public static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM task t JOIN run r ON r.id = \(latestRun)
             WHERE t.isCompleted = 0 AND r.status = 'failed' AND r.dismissed = 0
            """) ?? 0
    }

    /// Hides a failure from the list; the run stays in the history.
    public static func dismiss(_ db: Database, runId: ID) throws {
        try db.execute(sql: "UPDATE run SET dismissed = 1 WHERE id = ?", arguments: [runId])
    }
}
