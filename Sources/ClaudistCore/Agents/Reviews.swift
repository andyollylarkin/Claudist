import Foundation
import GRDB

/// "To review": tasks whose agent finished a run the user hasn't looked at yet. Opening the task
/// marks its runs reviewed. Runs started by another agent (sub-tasks) are reviewed by that agent.
public enum Reviews {
    public struct Item: Sendable, Identifiable, Hashable {
        public var id: ID { task.id }
        public var task: TaskItem
        public var run: Run
        /// The agent's final message.
        public var result: String
    }

    static let latestRun = "(SELECT r.id FROM run r WHERE r.taskId = t.id ORDER BY r.startedAt DESC, r.rowid DESC LIMIT 1)"
    static let condition = "r.status = 'done' AND r.reviewed = 0 AND r.trigger != 'agent'"

    public static func items(_ db: Database) throws -> [Item] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.*, r.id AS runId FROM task t JOIN run r ON r.id = \(latestRun)
             WHERE \(condition)
             ORDER BY COALESCE(r.endedAt, r.startedAt) DESC
            """)
        let runs = Dictionary(uniqueKeysWithValues: try Run.fetchAll(db, keys: rows.map { $0["runId"] as ID }).map { ($0.id, $0) })
        return try rows.compactMap { row in
            guard let run = runs[row["runId"]] else { return nil }
            let json = try String.fetchOne(db, sql: """
                SELECT json FROM runEvent WHERE runId = ? AND kind LIKE 'result%' ORDER BY seq DESC LIMIT 1
                """, arguments: [run.id])
            return Item(task: try TaskItem(row: row), run: run, result: json.flatMap { JSONValue.parse($0)?["result"]?.string } ?? "")
        }
    }

    public static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task t JOIN run r ON r.id = \(latestRun) WHERE \(condition)") ?? 0
    }

    /// The user has seen the task's results.
    public static func markReviewed(_ db: Database, taskId: ID) throws {
        try db.execute(sql: "UPDATE run SET reviewed = 1 WHERE taskId = ? AND reviewed = 0 AND status NOT IN ('queued', 'running', 'waiting')",
                       arguments: [taskId])
    }

    public static func markAllReviewed(_ db: Database) throws {
        try db.execute(sql: "UPDATE run SET reviewed = 1 WHERE reviewed = 0 AND status NOT IN ('queued', 'running', 'waiting')")
    }
}
