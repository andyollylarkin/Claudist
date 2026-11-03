import Foundation
import GRDB

/// `#Task` references in a chat message: picked from a list while typing, sent as links with
/// a short summary of each referenced task the agent can build on (or look up with `get_task`).
public enum TaskReferences {
    public static let scheme = "claudist-task"
    /// Separates what the user wrote from the summaries added for the agent; the chat hides what follows.
    public static let marker = "\n\n<!-- claudist:task-references -->\n"

    /// The `#query` being typed at the end of the message, or nil.
    public static func query(in text: String) -> String? {
        guard let hash = text.lastIndex(of: "#") else { return nil }
        if hash > text.startIndex, !text[text.index(before: hash)].isWhitespace { return nil }
        let query = text[text.index(after: hash)...]
        // A space after the word ends it (a picked title is followed by one).
        guard query.count <= 60, !query.contains("\n"), !query.hasPrefix(" "), !query.hasSuffix(" ") else { return nil }
        return String(query)
    }

    /// The message with the `#query` at its end replaced by the picked task's title.
    public static func complete(_ text: String, title: String) -> String {
        guard query(in: text) != nil, let hash = text.lastIndex(of: "#") else { return text }
        return String(text[..<hash]) + "#" + title + " "
    }

    /// Open tasks first, matching the title; the current task left out.
    public static func suggestions(_ db: Database, query: String, excluding taskId: ID?, limit: Int = 8) throws -> [TaskItem] {
        let words = query.split(separator: " ").map { "%\($0)%" }
        var sql = "SELECT * FROM task WHERE id IS NOT ?"
        for _ in words { sql += " AND content LIKE ?" }
        sql += " ORDER BY isCompleted, COALESCE(completedAt, createdAt) DESC LIMIT ?"
        return try TaskItem.fetchAll(db, sql: sql, arguments: StatementArguments([taskId] + words + [limit]))
    }

    public static func url(_ taskId: ID) -> String { "\(scheme):\(taskId)" }

    public static func taskId(_ url: URL) -> ID? {
        url.scheme == scheme ? url.absoluteString.dropFirst(scheme.count + 1).removingPercentEncoding : nil
    }

    /// The message to send: `#Title` of each picked task as a link, then their summaries.
    /// Picks whose `#Title` was edited away are dropped.
    public static func expand(_ db: Database, text: String, picked: [(title: String, id: ID)]) throws -> String {
        var out = text
        var used: [ID] = []
        for p in picked.sorted(by: { $0.title.count > $1.title.count }) where !used.contains(p.id) {
            let token = "#" + p.title
            guard out.contains(token) else { continue }
            let label = "#" + p.title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            out = out.replacingOccurrences(of: token, with: "[\(label)](\(url(p.id)))")
            used.append(p.id)
        }
        let summaries = try used.compactMap { try summary(db, taskId: $0) }
        guard !summaries.isEmpty else { return out }
        return out + marker + "Referenced tasks (look them up with get_task for more):\n\n" + summaries.joined(separator: "\n\n")
    }

    /// What the chat shows of a sent message.
    public static func visible(_ text: String) -> String {
        text.range(of: marker).map { String(text[..<$0.lowerBound]) } ?? text
    }

    static func summary(_ db: Database, taskId: ID) throws -> String? {
        guard let task = try TaskItem.fetchOne(db, key: taskId) else { return nil }
        let project = try String.fetchOne(db, sql: "SELECT name FROM project WHERE id = ?", arguments: [task.projectId])
        let agent = try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ?", arguments: [task.agentId])
        var head = "- \"\(task.content)\" (id `\(task.id)`"
        if let project { head += ", project \(project)" }
        if let agent { head += ", agent \(agent)" }
        head += task.isCompleted ? ", completed)" : ", open)"
        var lines = [head]
        if !task.description.isEmpty { lines.append("  Description: " + clip(task.description, 800)) }
        let result = try String.fetchOne(db, sql: """
            SELECT e.json FROM runEvent e JOIN run r ON r.id = e.runId
             WHERE r.taskId = ? AND e.kind LIKE 'result%' ORDER BY r.startedAt DESC, e.seq DESC LIMIT 1
            """, arguments: [taskId]).flatMap { JSONValue.parse($0)?["result"]?.string }
        if let result, !result.isEmpty { lines.append("  Latest agent result: " + clip(result, 1500)) }
        return lines.joined(separator: "\n")
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n  ")
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}
