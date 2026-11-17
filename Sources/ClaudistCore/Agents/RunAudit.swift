import Foundation
import GRDB

/// What a run was given when it started: recorded as an `access` event so the audit shows
/// the rights a run had, not only what it used.
public struct RunAccess: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public var name: String
        /// "ro" / "rw" for folders and databases, "file" for secrets passed as a file path.
        public var access: String?
    }

    public var agent: String
    /// The agent's own folder (its working directory).
    public var folder: String
    /// "Docker", "On this Mac" …
    public var isolation: String
    /// The Claude account the run signed in with (older runs: nil).
    public var account: String?
    public var secrets: [Item] = []
    public var storages: [Item] = []
    public var databases: [Item] = []
    public var attachments: [Item] = []
    public var delegates: [String] = []
    public var skills: [String] = []

    public init(agent: String, folder: String, isolation: String) {
        self.agent = agent
        self.folder = folder
        self.isolation = isolation
    }

    public static let eventKind = "access"

    public init(_ config: AgentLaunchConfig, isolation: String) {
        self.init(agent: config.agent.name, folder: config.agent.folderPath, isolation: isolation)
        secrets = config.secrets.map { Item(name: $0.name, access: $0.asFile ? "file" : nil) }
        storages = config.storages.map { Item(name: $0.storage.path, access: $0.access.rawValue) }
        databases = config.databases.map { Item(name: $0.database.name, access: $0.access.rawValue) }
        attachments = config.attachments.map { Item(name: $0.path, access: $0.writable ? "rw" : "ro") }
        delegates = config.delegates.map(\.name)
        skills = config.skills.sorted()
    }

    /// Folders the agent is expected to work in; paths elsewhere are flagged in the audit.
    public var roots: [String] {
        [folder] + storages.map(\.name) + attachments.map(\.name)
    }
}

/// One thing a run touched.
public struct AuditEntry: Identifiable, Sendable, Hashable {
    public enum Category: String, CaseIterable, Sendable {
        case secret, file, command, subagent, database, web, skill, task, tool, permission

        public var title: String {
            switch self {
            case .secret: "Secrets"
            case .file: "Files"
            case .command: "Commands"
            case .subagent: "Sub-agents"
            case .database: "Databases"
            case .web: "Web"
            case .skill: "Skills"
            case .task: "Tasks & dashboards"
            case .tool: "Other tools"
            case .permission: "Permissions"
            }
        }
    }

    public var id: String
    public var category: Category
    /// Tool or kind of access: Read, Edit, Bash, db_query, delegate, $NAME in Bash …
    public var action: String
    /// Path, URL, secret, agent, database …
    public var target: String
    /// Command, SQL, title …
    public var detail: String?
    public var at: String
    public var runId: ID
    public var taskId: ID
    public var agent: String?
    /// The tool call failed or the user denied it.
    public var failed = false
    /// Worth a look: a secret value showed up in output, a path outside the agent's folders.
    public var warning: String?
    /// For sub-agent calls: the sub-task.
    public var linkedTaskId: ID?
}

public enum RunAudit {
    /// Everything recorded for a task's runs, oldest first. With `subtasks`, sub-agent tasks
    /// created by delegation (at any depth) are included.
    public static func entries(_ db: Database, taskId: ID, subtasks: Bool = true) throws -> (entries: [AuditEntry], access: [ID: RunAccess]) {
        var taskIds = [taskId]
        if subtasks {
            var frontier = [taskId]
            while !frontier.isEmpty {
                let marks = Array(repeating: "?", count: frontier.count).joined(separator: ",")
                frontier = try String.fetchAll(db, sql: "SELECT id FROM task WHERE source = 'agent' AND parentId IN (\(marks))",
                                               arguments: StatementArguments(frontier))
                taskIds += frontier
            }
        }
        let tMarks = Array(repeating: "?", count: taskIds.count).joined(separator: ",")
        let runs = try Row.fetchAll(db, sql: """
            SELECT r.id, r.taskId, a.name AS agent FROM run r LEFT JOIN agent a ON a.id = r.agentId
            WHERE r.taskId IN (\(tMarks)) ORDER BY r.startedAt
            """, arguments: StatementArguments(taskIds))
        guard !runs.isEmpty else { return ([], [:]) }
        var runTask: [ID: ID] = [:]
        var runAgent: [ID: String] = [:]
        for r in runs {
            runTask[r["id"]] = r["taskId"]
            runAgent[r["id"]] = r["agent"]
        }
        let ids = Array(runTask.keys)
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let args = StatementArguments(ids)

        var access: [ID: RunAccess] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT runId, json FROM runEvent WHERE runId IN (\(marks)) AND kind = ?",
                                    arguments: args + [RunAccess.eventKind]) {
            if let a = try? JSONDecoder().decode(RunAccess.self, from: Data((row["json"] as String).utf8)) { access[row["runId"]] = a }
        }
        // Secret names a run could use; older runs without an access event: every known secret.
        let allSecrets = try String.fetchAll(db, sql: "SELECT name FROM secret")

        // Tool results: failures and redacted secret values (‹NAME›) in the output.
        var failedCalls: Set<String> = []
        var exposed: [String: [String]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT json_extract(c.value, '$.tool_use_id') AS id, json_extract(c.value, '$.is_error') AS err,
                   instr(c.value, '‹') > 0 AS marked, c.value AS body
            FROM runEvent e, json_each(e.json, '$.message.content') c
            WHERE e.runId IN (\(marks)) AND e.kind = 'user' AND json_extract(c.value, '$.type') = 'tool_result'
            """, arguments: args) {
            guard let id: String = row["id"] else { continue }
            if (row["err"] as Bool?) == true { failedCalls.insert(id) }
            if (row["marked"] as Bool?) == true {
                let body: String = row["body"]
                exposed[id] = allSecrets.filter { body.contains("‹\($0)›") }
            }
        }

        var out: [AuditEntry] = []
        func add(_ e: AuditEntry) { out.append(e) }

        for row in try Row.fetchAll(db, sql: """
            SELECT e.runId, e.seq, e.createdAt, c.key AS idx, json_extract(c.value, '$.id') AS callId,
                   json_extract(c.value, '$.name') AS tool, json_extract(c.value, '$.input') AS input
            FROM runEvent e, json_each(e.json, '$.message.content') c
            WHERE e.runId IN (\(marks)) AND e.kind = 'assistant' AND json_extract(c.value, '$.type') = 'tool_use'
            ORDER BY e.seq
            """, arguments: args) {
            let runId: ID = row["runId"]
            let callId: String = row["callId"] ?? ""
            let tool: String = row["tool"] ?? ""
            let input = JSONValue.parse(row["input"] ?? "{}") ?? .object([:])
            let a = access[runId]
            let base = AuditEntry(id: "\(runId)-\(row["seq"] as Int64)-\(row["idx"] as Int)", category: .tool, action: tool, target: "",
                                  at: row["createdAt"], runId: runId, taskId: runTask[runId] ?? taskId, agent: runAgent[runId],
                                  failed: failedCalls.contains(callId))
            var entries = classify(tool: tool, input: input, base: base, access: a)
            // Secrets referenced in commands.
            if tool == "Bash", let command = input["command"]?.string {
                let names = a.map { $0.secrets.map(\.name) } ?? allSecrets
                for name in names where references(command, name) {
                    var e = base
                    e.id += "-s-\(name)"
                    e.category = .secret
                    e.action = "used in Bash"
                    e.target = name
                    e.detail = command
                    entries.append(e)
                }
            }
            for name in exposed[callId] ?? [] {
                var e = base
                e.id += "-x-\(name)"
                e.category = .secret
                e.action = "value in output"
                e.target = name
                e.detail = "The value appeared in the result of \(tool) (stored redacted)"
                e.warning = "The secret's value was printed; the agent saw it"
                entries.append(e)
            }
            out += entries
        }

        // Sub-agent calls with their sub-tasks; permission questions and answers.
        var answers: [String: Bool] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT json FROM runEvent WHERE runId IN (\(marks)) AND kind = 'permission/answer'", arguments: args) {
            let v = JSONValue.parse(row["json"])
            if let id = v?["request_id"]?.string { answers[id] = v?["allow"]?.bool ?? false }
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT runId, seq, kind, json, createdAt FROM runEvent
            WHERE runId IN (\(marks)) AND kind IN ('delegate', 'permission') ORDER BY seq
            """, arguments: args) {
            let runId: ID = row["runId"]
            let v = JSONValue.parse(row["json"]) ?? .object([:])
            var e = AuditEntry(id: "\(runId)-\(row["seq"] as Int64)", category: .subagent, action: "", target: "", at: row["createdAt"],
                               runId: runId, taskId: runTask[runId] ?? taskId, agent: runAgent[runId])
            if (row["kind"] as String) == "delegate" {
                e.action = "called"
                e.target = v["agent"]?.string ?? "?"
                e.detail = v["title"]?.string
                e.linkedTaskId = v["taskId"]?.string
            } else {
                e.category = .permission
                e.action = v["tool"]?.string ?? "?"
                e.target = v["description"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? String((v["input"]?.string ?? "").prefix(300))
                let allowed = v["request_id"]?.string.flatMap { answers[$0] }
                e.detail = allowed == nil ? "no answer" : allowed! ? "allowed by you" : "denied by you"
                e.failed = allowed == false
            }
            out.append(e)
        }
        out.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        return (out, access)
    }

    static let internalTools: Set<String> = ["ToolSearch", "TodoWrite", "TaskStop", "TaskOutput", "BashOutput", "KillShell",
                                             "KillBash", "ExitPlanMode", "EnterPlanMode", "ListMcpResourcesTool", "ReadMcpResourceTool"]

    static func references(_ command: String, _ name: String) -> Bool {
        guard command.contains(name) else { return false }
        let pattern = "\\$\\{?" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_])"
        return command.range(of: pattern, options: .regularExpression) != nil
    }

    static func classify(tool: String, input: JSONValue, base: AuditEntry, access: RunAccess?) -> [AuditEntry] {
        var e = base
        func outside(_ path: String) -> String? {
            guard let access, path.hasPrefix("/") else { return nil }
            let p = (path as NSString).standardizingPath
            if access.roots.contains(where: { p == $0 || p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return nil }
            if p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") || p.hasPrefix("/var/folders/") { return nil }
            return "Outside the agent's folder, storage and attachments"
        }
        let short = tool.hasPrefix("mcp__") ? String(tool.split(separator: "__").last ?? "") : tool
        // Claude Code's own bookkeeping touches nothing outside the session.
        if internalTools.contains(tool) { return [] }
        switch tool {
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
            e.category = .file
            e.target = input["file_path"]?.string ?? input["notebook_path"]?.string ?? "?"
            e.action = tool == "Read" ? "read" : tool == "Write" ? "wrote" : "edited"
            e.warning = outside(e.target)
        case "Glob", "Grep", "LS":
            e.category = .file
            e.action = tool == "LS" ? "listed" : "searched"
            let path = input["path"]?.string
            e.target = path ?? "(working folder)"
            e.detail = input["pattern"]?.string
            e.warning = path.flatMap(outside)
        case "Bash":
            e.category = .command
            e.action = "ran"
            e.target = input["command"]?.string ?? ""
            e.detail = input["description"]?.string
            // Absolute paths in the command outside the agent's folders.
            let paths = e.target.split(whereSeparator: { " \t\n\"'=;|&<>()".contains($0) })
                .map(String.init).filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
                .map { $0.hasPrefix("~/") ? NSHomeDirectory() + $0.dropFirst() : $0 }
            if let path = paths.first(where: { outside($0) != nil }) { e.warning = "Touches \(path), outside the agent's folders" }
        case "WebFetch":
            e.category = .web
            e.action = "fetched"
            e.target = input["url"]?.string ?? "?"
        case "WebSearch":
            e.category = .web
            e.action = "searched"
            e.target = input["query"]?.string ?? "?"
        case "Skill":
            e.category = .skill
            e.action = "loaded"
            e.target = input["skill"]?.string ?? "?"
        case "Task", "Agent":
            e.category = .subagent
            e.action = "built-in sub-agent"
            e.target = input["subagent_type"]?.string ?? "general-purpose"
            e.detail = input["description"]?.string
        default:
            if tool.hasPrefix("mcp__\(Delegation.serverName)__") {
                switch short {
                case DatabaseAccess.schemaTool, DatabaseAccess.queryTool, DatabaseAccess.executeTool:
                    e.category = .database
                    e.action = short == DatabaseAccess.executeTool ? "changed" : short == DatabaseAccess.queryTool ? "queried" : "read schema"
                    e.target = input["database"]?.string ?? "?"
                    e.detail = input["sql"]?.string
                case Delegation.toolName:
                    // Shown from the delegate event, which links the sub-task.
                    return []
                case Attention.toolName:
                    e.category = .task
                    e.action = "asked you"
                    e.target = input["question"]?.string ?? ""
                default:
                    e.category = .task
                    e.action = short.replacingOccurrences(of: "_", with: " ")
                    e.target = input["content"]?.string ?? input["title"]?.string ?? input["id"]?.string ?? input["filter"]?.string ?? ""
                    e.detail = input["text"]?.string ?? input["sql"]?.string
                }
            } else {
                e.category = .tool
                e.action = short
                e.target = tool.hasPrefix("mcp__") ? String(tool.split(separator: "__").dropFirst().first ?? "") : ""
                e.detail = String(input.compactJSON.prefix(300))
            }
        }
        return [e]
    }
}

extension JSONValue {
    var compactJSON: String {
        let data = (try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
