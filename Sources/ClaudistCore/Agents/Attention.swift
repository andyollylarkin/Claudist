import Foundation
import GRDB

/// "Needs you": a task whose agent can't continue without the user.
///
/// Two sources: the agent called `ask_user` (stored on the task until the user replies),
/// or its latest run waits for a permission answer.
public enum Attention {
    public static let toolName = "ask_user"
    public static var qualifiedToolName: String { "mcp__\(Delegation.serverName)__\(toolName)" }

    /// SQL over `task t`.
    public static let sqlCondition = """
        (t.attention IS NOT NULL OR (SELECT status FROM run WHERE taskId = t.id \
        ORDER BY startedAt DESC, rowid DESC LIMIT 1) = 'waiting')
        """

    public static func tasks(_ db: Database) throws -> [TaskItem] {
        try TaskItem.fetchAll(db, sql: """
            SELECT t.* FROM task t WHERE t.isCompleted = 0 AND \(sqlCondition)
            ORDER BY COALESCE(t.attentionAt, t.createdAt) DESC
            """)
    }

    public static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task t WHERE t.isCompleted = 0 AND \(sqlCondition)") ?? 0
    }

    public static func toolDefinition() -> [String: Any] {
        [
            "name": toolName,
            "description": """
                Ask the user for a decision you cannot make yourself (missing information, a choice between \
                options, approval of a risky or irreversible step, unclear requirements). The question is posted \
                to the user's "Needs you" list. After calling this tool, stop working: end your turn with a short \
                summary of where you are. The answer arrives later as the next user message.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "The question, with the context needed to answer it"],
                    "options": ["type": "array", "items": ["type": "string"],
                                "description": "Suggested answers the user can pick with one click (optional)"],
                ],
                "required": ["question"],
            ] as [String: Any],
        ]
    }

    public static let promptSection = """
        ## When you need the user
        If you cannot continue without the user's decision, call `\(qualifiedToolName)` with a clear question \
        (and options when there are obvious choices), then stop and end your turn. Do not guess on decisions \
        that are the user's to make, and do not wait in a loop.
        """

    /// Stores the question on the task.
    public static func mark(_ db: Database, taskId: ID, question: String, options: [String]) throws {
        let json = options.isEmpty ? nil : String(data: try JSONEncoder().encode(options), encoding: .utf8)
        try db.execute(sql: "UPDATE task SET attention = ?, attentionOptions = ?, attentionAt = ? WHERE id = ?",
                       arguments: [question, json, LocalDate.stamp(Date()), taskId])
    }

    public static func clear(_ db: Database, taskId: ID) throws {
        try db.execute(sql: "UPDATE task SET attention = NULL, attentionOptions = NULL, attentionAt = NULL WHERE id = ?",
                       arguments: [taskId])
    }
}
