import Foundation
import GRDB

/// One agent run with what it used, for the run log.
public struct RunLogEntry: Identifiable, Sendable, Hashable {
    public var id: ID { run.id }
    public var run: Run
    public var taskTitle: String
    public var agentName: String?
    /// For runs started by another agent (a delegated sub-task): that agent.
    public var calledBy: String?
    /// Skills loaded through the Skill tool, in first-use order, with use counts.
    public var skills: [(name: String, count: Int)]
    /// Claudist agents this run delegated to.
    public var delegates: [(name: String, count: Int)]
    /// Claude Code's built-in subagents (Task / Agent tool), by type.
    public var subagents: [(name: String, count: Int)]
    public var toolCalls: Int

    public static func == (a: RunLogEntry, b: RunLogEntry) -> Bool {
        a.run == b.run && a.toolCalls == b.toolCalls && a.calledBy == b.calledBy && a.agentName == b.agentName
            && a.taskTitle == b.taskTitle
            && a.skills.map { "\($0.name)\($0.count)" } == b.skills.map { "\($0.name)\($0.count)" }
            && a.delegates.map { "\($0.name)\($0.count)" } == b.delegates.map { "\($0.name)\($0.count)" }
            && a.subagents.map { "\($0.name)\($0.count)" } == b.subagents.map { "\($0.name)\($0.count)" }
    }

    public func hash(into h: inout Hasher) { h.combine(run.id) }
}

/// Reads the run history across all tasks and agents, with skill and sub-agent usage taken
/// from the recorded stream (`runEvent`).
public enum RunLog {
    public struct Query: Sendable, Equatable {
        public var agentId: ID?
        public var status: RunStatus?
        /// Local stamp; runs started at or after it.
        public var since: String?
        /// Only runs that used this skill.
        public var skill: String?
        public var limit = 300

        public init() {}
    }

    public static func entries(_ db: Database, _ q: Query) throws -> [RunLogEntry] {
        var sql = """
            SELECT r.*, t.content AS taskTitle, a.name AS agentName, pa.name AS callerName
            FROM run r
            JOIN task t ON t.id = r.taskId
            LEFT JOIN agent a ON a.id = r.agentId
            LEFT JOIN task pt ON pt.id = t.parentId AND r.trigger = 'agent'
            LEFT JOIN agent pa ON pa.id = pt.agentId
            WHERE 1
            """
        var args: [DatabaseValueConvertible] = []
        if let agentId = q.agentId { sql += " AND r.agentId = ?"; args.append(agentId) }
        if let status = q.status { sql += " AND r.status = ?"; args.append(status.rawValue) }
        if let since = q.since { sql += " AND r.startedAt >= ?"; args.append(since) }
        if let skill = q.skill {
            sql += """
                 AND EXISTS (SELECT 1 FROM runEvent e, json_each(e.json, '$.message.content') c
                 WHERE e.runId = r.id AND e.kind = 'assistant' AND json_extract(c.value, '$.name') = 'Skill'
                 AND json_extract(c.value, '$.input.skill') = ?)
                """
            args.append(skill)
        }
        sql += " ORDER BY r.startedAt DESC, r.rowid DESC LIMIT ?"
        args.append(max(1, q.limit))
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        guard !rows.isEmpty else { return [] }

        let ids = rows.map { $0["id"] as String }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var skills: [ID: [(String, Int)]] = [:]
        var subagents: [ID: [(String, Int)]] = [:]
        var delegates: [ID: [(String, Int)]] = [:]
        var tools: [ID: Int] = [:]
        func bump(_ map: inout [ID: [(String, Int)]], _ run: ID, _ name: String) {
            var list = map[run] ?? []
            if let i = list.firstIndex(where: { $0.0 == name }) { list[i].1 += 1 } else { list.append((name, 1)) }
            map[run] = list
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT e.runId, json_extract(c.value, '$.name'),
                   json_extract(c.value, '$.input.skill'), json_extract(c.value, '$.input.subagent_type')
            FROM runEvent e, json_each(e.json, '$.message.content') c
            WHERE e.runId IN (\(marks)) AND e.kind = 'assistant' AND json_extract(c.value, '$.type') = 'tool_use'
            ORDER BY e.seq
            """, arguments: StatementArguments(ids)) {
            let run: ID = row[0]
            let tool: String = row[1] ?? ""
            tools[run, default: 0] += 1
            if tool == "Skill", let name: String = row[2] { bump(&skills, run, name) }
            if tool == "Task" || tool == "Agent" { bump(&subagents, run, (row[3] as String?) ?? "general-purpose") }
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT runId, json_extract(json, '$.agent') FROM runEvent
            WHERE runId IN (\(marks)) AND kind = 'delegate' ORDER BY seq
            """, arguments: StatementArguments(ids)) {
            if let name: String = row[1] { bump(&delegates, row[0], name) }
        }

        return try rows.map { row in
            let run = try Run(row: row)
            return RunLogEntry(run: run, taskTitle: row["taskTitle"], agentName: row["agentName"], calledBy: row["callerName"],
                               skills: (skills[run.id] ?? []).map { (name: $0.0, count: $0.1) },
                               delegates: (delegates[run.id] ?? []).map { (name: $0.0, count: $0.1) },
                               subagents: (subagents[run.id] ?? []).map { (name: $0.0, count: $0.1) },
                               toolCalls: tools[run.id] ?? 0)
        }
    }

    /// Skill names ever used, for the filter menu.
    public static func usedSkills(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT json_extract(c.value, '$.input.skill') AS s
            FROM runEvent e, json_each(e.json, '$.message.content') c
            WHERE e.kind = 'assistant' AND json_extract(c.value, '$.name') = 'Skill' AND s IS NOT NULL
            ORDER BY s
            """)
    }
}
