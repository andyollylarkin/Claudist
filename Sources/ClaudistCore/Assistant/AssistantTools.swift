import Foundation
import GRDB

/// A conversation with the built-in assistant.
public struct AssistantChat: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: ID = newID()
    public var title = "New chat"
    /// Claude Code session, resumed when the conversation continues after the process ended.
    public var sessionId: String?
    public var createdAt = LocalDate.stamp(Date())
    public var updatedAt = LocalDate.stamp(Date())

    public init() {}
}

/// One stream-json line (or app event) of an assistant conversation; same shape as `runEvent`.
public struct AssistantEvent: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public var seq: Int64?
    public var chatId: ID
    public var kind: String
    public var json: String
    public var createdAt = LocalDate.stamp(Date())

    public init(chatId: ID, kind: String, json: String) {
        self.chatId = chatId
        self.kind = kind
        self.json = json
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }
}

/// Tools the assistant uses to read and change Claudist, served on the app's `claudist` MCP server.
///
/// Read tools run without asking. Tools that change something are `mutating`: unless the user
/// turned confirmations off, Claude Code asks the app for permission and the user approves in the chat.
/// Secret values are never exposed — only names and where they are used.
public enum AssistantTools {
    public struct Tool: Sendable {
        public var name: String
        public var description: String
        public var schema: JSONValue
        public var mutating: Bool
        /// Handled by the app (starting and stopping runs) rather than by `call`.
        public var appAction: Bool

        public var definition: [String: Any] {
            ["name": name, "description": description, "inputSchema": schema.any]
        }
    }

    public static func qualified(_ name: String) -> String { "mcp__\(Delegation.serverName)__\(name)" }

    public static func tool(_ name: String) -> Tool? { all.first { $0.name == name } }

    // MARK: Definitions

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map { .string($0) })])
    }
    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
    private static func strings(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }
    private static func choice(_ values: [String], _ description: String) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map { .string($0) }), "description": .string(description)])
    }

    private static func read(_ name: String, _ description: String, _ schema: JSONValue = schema([:])) -> Tool {
        Tool(name: name, description: description, schema: schema, mutating: false, appAction: false)
    }
    private static func change(_ name: String, _ description: String, _ schema: JSONValue, app: Bool = false) -> Tool {
        Tool(name: name, description: description, schema: schema, mutating: true, appAction: app)
    }

    public static let all: [Tool] = [
        read("overview", "Counts of everything in Claudist and what needs attention right now: running agents, tasks waiting for the user, overdue tasks."),
        read("list_projects", "Projects with their sections and open task counts.",
             schema(["include_archived": .object(["type": .string("boolean")])])),
        read("find_tasks", """
            Find tasks with a Todoist-style filter query (see the system prompt), e.g. "today | overdue", "#Work & p1", \
            "agent: Researcher & run: failed", "needs you", "completed after: -7 days". Without a filter: all open tasks.
            """, schema(["filter": string("Filter query"), "limit": integer("Max tasks, default 50")])),
        read("get_task", "Everything about one task: description, comments, subtasks, attachments, databases, recent runs.",
             schema(["id": string("Task id")], required: ["id"])),
        read("list_agents", "Agents with their model, permission mode, skills, storage, secrets, databases and the agents they may call."),
        read("get_agent", "One agent in full, including its system prompt and allow/deny rules.",
             schema(["name": string("Agent name")], required: ["name"])),
        read("list_runs", "Recent agent runs, newest first.", schema([
            "status": choice(RunStatus.allCases.map(\.rawValue), "Only runs with this status"),
            "task_id": string("Only runs of this task"),
            "limit": integer("Default 20"),
        ])),
        read("get_run", "The transcript of a run: messages, tool calls, results, errors (long parts shortened).",
             schema(["id": string("Run id"), "max_events": integer("Default 60")], required: ["id"])),
        read("list_skills", "Skills in the shared library and which agents use them."),
        read("get_skill", "A skill's SKILL.md and its attached files.", schema(["name": string("Skill name")], required: ["name"])),
        read("list_secrets", "Secret names, descriptions and where they are used. Values are never available."),
        read("list_storage", "Host folders registered as storage and which agents can read or write them."),
        read("list_databases", "SQLite databases with their tables and who uses them."),
        read("database_schema", "DDL and row counts of a database.", schema(["database": string("Database name")], required: ["database"])),
        read("query_database", "Read-only SQL on a database (max 200 rows).",
             schema(["database": string("Database name"), "sql": string("SELECT statement")], required: ["database", "sql"])),
        read("list_filters", "Saved filters (views) and labels."),
        read(DashboardTools.listTool, "Dashboards with their charts (title, kind, database, SQL)."),
        read(NotesTools.listTool, NotesTools.listDescription, schema(["query": string("Text or #tag")])),
        read(NotesTools.readTool, NotesTools.readDescription, schema(["path": string("Note path")], required: ["path"])),
        change(NotesTools.writeTool, NotesTools.writeDescription, schema([
            "path": string("Note path, e.g. Ideas/Pricing.md"), "content": string("Markdown"),
            "mode": choice(["replace", "append", "create"], "Default replace"),
        ], required: ["path", "content"])),

        change("create_task", "Create a task. Assign an agent to let it work on the task; nothing runs until run_task.", schema([
            "project": string("Project name or id"),
            "content": string("Title"),
            "description": string("Details, markdown"),
            "section": string("Section name in the project"),
            "parent_id": string("Parent task id, to make a subtask"),
            "priority": integer("1 = p1 (urgent) … 4 = none"),
            "due": string("Natural due string: \"tomorrow 9am\", \"every weekday at 9am\" (a task with an agent starts by itself when due; recurring ones every time)"),
            "deadline": string("YYYY-MM-DD"),
            "labels": strings("Label names; missing labels are created"),
            "agent": string("Agent name"),
        ], required: ["project", "content"])),
        change("update_task", "Change a task. Only given fields change; an empty string clears due, deadline, agent or section.", schema([
            "id": string("Task id"),
            "content": string("Title"), "description": string("Details"),
            "project": string("Move to project"), "section": string("Section name"),
            "priority": integer("1–4"), "due": string("Due string"), "deadline": string("YYYY-MM-DD"),
            "labels": strings("Replace labels"), "agent": string("Agent name"),
        ], required: ["id"])),
        change("complete_task", "Mark a task done (or not done).",
               schema(["id": string("Task id"), "completed": .object(["type": .string("boolean")])], required: ["id"])),
        change("delete_task", "Delete a task with its subtasks, comments and run history.", schema(["id": string("Task id")], required: ["id"])),
        change("add_comment", "Comment on a task; agents see comments in their prompt.",
               schema(["task_id": string("Task id"), "text": string("Comment")], required: ["task_id", "text"])),
        change("create_project", "Create a project.", schema(["name": string("Name"), "parent": string("Parent project name or id"),
                                                              "color": string("Color name, e.g. red, blue, green")], required: ["name"])),
        change("create_section", "Create a section (board column) in a project.",
               schema(["project": string("Project name or id"), "name": string("Section name")], required: ["project", "name"])),
        change("create_filter", "Save a filter view.", schema(["name": string("Name"), "query": string("Filter query")], required: ["name", "query"])),
        change("create_agent", "Create an agent with its own folder (memory).", schema([
            "name": string("Unique name"), "description": string("What it does — other agents see this"),
            "prompt": string("System prompt"), "model": string("sonnet, opus, haiku, fable, or empty for default"),
            "tools": string("Comma-separated Claude Code tools, empty = all"),
            "permission_mode": choice(["manual", "acceptEdits", "plan", "auto", "dontAsk"], "Default manual: ask the user for risky actions"),
        ], required: ["name", "prompt"])),
        change("update_agent", "Change an agent's description, prompt, model, tools or permission mode.", schema([
            "name": string("Agent name"), "description": string("Description"), "prompt": string("System prompt"),
            "model": string("Model"), "tools": string("Tools"),
            "permission_mode": choice(["manual", "acceptEdits", "plan", "auto", "dontAsk"], "Permission mode"),
        ], required: ["name"])),
        change("set_agent_access", """
            Give or take an agent's access: kind skill / secret / delegate (access on|off), storage / database (access none|ro|rw).
            """, schema([
                "agent": string("Agent name"),
                "kind": choice(["skill", "secret", "delegate", "storage", "database"], "What to link"),
                "name": string("Skill, secret, agent (for delegate), storage or database name"),
                "access": choice(["on", "off", "none", "ro", "rw"], "Access level"),
            ], required: ["agent", "kind", "name", "access"])),
        change("set_task_database", "Give a task a database (on top of its agent's).", schema([
            "task_id": string("Task id"), "database": string("Database name"), "access": choice(["none", "ro", "rw"], "Access"),
        ], required: ["task_id", "database", "access"])),
        change(DashboardTools.saveTool, DashboardTools.saveDescription,
               JSONValue.parse(encode(DashboardTools.saveSchema(nil))) ?? schema([:])),
        change(DashboardTools.deleteTool, "Delete a chart from its dashboard.", schema(["id": string("Chart id")], required: ["id"])),
        change("run_task", "Start the task's agent. With `message`, continue the task's last conversation with that message instead.",
               schema(["id": string("Task id"), "message": string("Follow-up message for the agent")], required: ["id"]), app: true),
        change("stop_task", "Stop the agent working on a task.", schema(["id": string("Task id")], required: ["id"]), app: true),
        change("reply_to_agent", "Answer an agent that asked the user a question (a task in Needs you); the run continues.",
               schema(["task_id": string("Task id"), "text": string("Answer")], required: ["task_id", "text"]), app: true),
    ]

    // MARK: Prompt

    public static func systemPrompt(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        return """
            # You are the Claudist assistant

            Claudist is a native macOS task manager (Todoist-style) whose tasks are worked on by Claude Code agents. \
            You live inside the app as its built-in assistant. You are not one of the agents: you help the user \
            understand and manage everything in Claudist through the `\(qualified("…"))` tools. Now: \(f.string(from: now)), \
            time zone \(TimeZone.current.identifier).

            ## How Claudist works
            - Projects (nested) contain sections (board columns) and tasks. Tasks have priority p1 (urgent, stored as 1) \
            to p4 (none, 4), a due date (natural language, may be recurring: "every weekday at 9am"), a deadline, labels, \
            subtasks, comments, attachments (host files linked by path) and an assigned agent.
            - Agents are Claude Code processes. Each has a role prompt, its own folder (cwd, so its memory is its own), \
            a model, a permission mode, skills from the shared library, storage folders (none / read / read & write), \
            secrets (injected as environment variables), SQLite databases (read or read & write) and a list of agents it \
            may delegate to (each call becomes a subtask).
            - An agent works only from a task: the user (or you, with run_task) starts it; the task title, description, \
            comments and attachments become its prompt. Replies continue the same conversation. A task with an agent and a \
            due date runs by itself when due: a recurring one every time, a one-off one once (if it never ran). Every run is recorded with its transcript, tokens and cost.
            - "Needs you": an agent asked the user a question (ask_user) or waits for a permission. Answer with \
            reply_to_agent only when the user tells you what to answer.
            - Filters are saved views written in the Todoist filter language: `today`, `overdue`, `tomorrow`, `7 days`, \
            `no date`, `date before: 2026-12-01`, `p1`, `#Project`, `##Project` (with subprojects), `/Section`, `@label`, \
            `search: text`, `subtask`, `recurring`, `assigned to:`, `deadline: …`, `created: …`, combined with `&`, `|`, `!`, \
            `( )`; commas separate groups (board columns). Claudist adds `agent: Name`, `run: queued|running|waiting|done|failed|cancelled`, \
            `run before:/after:`, `completed`, `completed before:/after:`, `needs you`.
            - Skills are folders with SKILL.md and tools; the Skills screen can generate them with Claude. Databases are \
            SQLite files; the Databases screen can design schemas with Claude. Dashboards show charts (number, pie, bar, line) \
            over databases: each chart is a read-only query whose first column is the label and the next columns numbers; \
            make them with save_chart when the user wants to see data. Secrets live in the macOS Keychain — you \
            never see their values and must not ask the user to paste them into the chat; point them to the Secrets screen.
            - Notes are the user's Markdown notes in Obsidian's format (`[[links]]`, `#tags`, frontmatter), kept as files;             read and write them with list_notes, read_note, write_note. Agents reach them too, by the access the user gave each agent.

            ## How you work
            - Look things up with the tools instead of guessing; refer to items by name, use ids in tool calls.
            - The user may attach files: images and PDFs you see directly, text files inline, with each file's path. \
            You can't open other files; ask the user to attach what you need.
            - Before changing many things or deleting anything, say what you are about to do. The user may have to approve \
            each change in the chat; if they decline, don't retry the same call.
            - When asked to set something up (an agent, a recurring job), create it completely: the agent, its access, the \
            task, and say how to start it.
            - Keep answers short and concrete. Answer in the user's language.
            """
    }

    // MARK: Agents

    /// The part of the toolset an agent gets during a run: reading tasks and managing tasks.
    /// Nothing that changes agents, their access, secrets or databases, and no starting runs:
    /// those would let an agent widen its own rights.
    public static let agentToolNames: [String] = [
        "list_projects", "find_tasks", "get_task", "create_task", "update_task", "complete_task", "add_comment",
    ]

    public static func agentToolDefinitions() -> [[String: Any]] {
        agentToolNames.compactMap { tool($0)?.definition }
    }

    /// Who calls the tools when it is an agent, and which agents' tasks it may touch.
    public struct AgentScope: Sendable {
        public var agentId: ID
        public var agentName: String
        /// The agent itself and the agents it may delegate to.
        public var allowedAgents: Set<ID>

        public init(agentId: ID, agentName: String, delegates: [ID]) {
            self.agentId = agentId
            self.agentName = agentName
            self.allowedAgents = Set(delegates + [agentId])
        }

        /// Changing (or commenting on) a task feeds its agent; only tasks without an agent,
        /// its own, or its delegates' are open to the caller. A task that runs on the Mac takes
        /// comments only: its prompt shows them as other agents' notes, not as the user's words.
        func check(_ task: TaskItem, commenting: Bool = false) throws {
            // Its text becomes the prompt of a run outside isolation; an isolated agent must not write it.
            if task.runOnHost && !commenting {
                throw ClaudistError.invalid("""
                    “\(task.content)” is set to run on the Mac outside isolation, so agents can't change it: its text \
                    becomes the prompt of an unisolated run. This is intended, not an error. You can still comment on it \
                    with add_comment. To change it, tell the user what you wanted; they can edit it themselves, or switch \
                    the task's “Runs” setting to isolation and ask you again.
                    """)
            }
            if let owner = task.agentId, !allowedAgents.contains(owner) {
                throw ClaudistError.invalid("“\(task.content)” belongs to another agent; you can only change your own tasks, unassigned ones and those of agents you may call")
            }
        }

        func checkAssignment(_ agentId: ID?) throws {
            if let agentId, !allowedAgents.contains(agentId) {
                throw ClaudistError.invalid("You can assign tasks only to yourself or to agents you may call")
            }
        }
    }

    // MARK: Calls

    /// Runs a non-app tool and returns its answer as JSON text. With `scope` the caller is an
    /// agent: only `agentToolNames` are available and task changes are limited by the scope.
    public static func call(_ name: String, _ args: JSONValue?, db: DatabaseWriter, workspace: AgentWorkspace,
                            scope: AgentScope? = nil) throws -> String {
        let a = args ?? .object([:])
        if scope != nil && !agentToolNames.contains(name) {
            throw ClaudistError.invalid("\(name) is not available to agents")
        }
        switch name {
        case "overview": return try db.read { try overview($0, library: workspace.library) }
        case "list_projects": return try db.read { try listProjects($0, archived: a["include_archived"]?.bool ?? false) }
        case "find_tasks":
            return try db.read { try findTasks($0, filter: a["filter"]?.string ?? "", limit: a["limit"]?.number.map { Int($0) } ?? 50) }
        case "get_task": return try db.read { try getTask($0, id: try require(a, "id")) }
        case "list_agents": return try db.read { try listAgents($0) }
        case "get_agent": return try db.read { try getAgent($0, name: try require(a, "name")) }
        case "list_runs":
            return try db.read { try listRuns($0, status: a["status"]?.string, taskId: a["task_id"]?.string,
                                             limit: a["limit"]?.number.map { Int($0) } ?? 20) }
        case "get_run": return try db.read { try getRun($0, id: try require(a, "id"), max: a["max_events"]?.number.map { Int($0) } ?? 60) }
        case "list_skills": return try db.read { try listSkills($0, library: workspace.library) }
        case "get_skill": return try getSkill(try require(a, "name"), library: workspace.library)
        case "list_secrets": return try db.read { try listSecrets($0) }
        case "list_storage": return try db.read { try listStorage($0) }
        case "list_databases": return try db.read { try listDatabases($0) }
        case "database_schema":
            let d = try db.read { try database($0, try require(a, "database")) }
            return DatabaseAccess.describe(try SQLiteFile.tables(d.path))
        case "query_database":
            let d = try db.read { try database($0, try require(a, "database")) }
            return try SQLiteFile.run(d.path, sql: try require(a, "sql"), readOnly: true, maxRows: 200).json
        case "list_filters": return try db.read { try listFilters($0) }
        case NotesTools.listTool, NotesTools.readTool, NotesTools.writeTool:
            let (text, isError) = NotesTools.call(name, arguments: a, vault: NotesVault.configured(paths: workspace.paths), access: .rw)
            if isError { throw ClaudistError.invalid(text) }
            return text
        case DashboardTools.listTool, DashboardTools.saveTool, DashboardTools.deleteTool:
            // The assistant reaches every database; chart queries still run read-only.
            let grants = try db.read { try UserDatabase.order(Column("name")).fetchAll($0) }.map { DatabaseGrant(database: $0, access: .ro) }
            let (text, isError) = DashboardTools.call(name, arguments: a, db: db, grants: grants, author: "assistant")
            if isError { throw ClaudistError.invalid(text) }
            return text

        case "create_task": return try db.write { try createTask($0, a, scope: scope) }
        case "update_task": return try db.write { try updateTask($0, a, scope: scope) }
        case "complete_task":
            return try db.write { db in
                let task = try task(db, try require(a, "id"))
                try scope?.check(task)
                let done = a["completed"]?.bool ?? true
                try db.execute(sql: "UPDATE task SET isCompleted = ?, completedAt = ? WHERE id = ?",
                               arguments: [done, done ? LocalDate.stamp(Date()) : nil, task.id])
                return ok("\(done ? "Completed" : "Reopened") “\(task.content)”")
            }
        case "delete_task":
            return try db.write { db in
                let task = try task(db, try require(a, "id"))
                try deleteTree(db, task.id)
                return ok("Deleted “\(task.content)”")
            }
        case "add_comment":
            return try db.write { db in
                let task = try task(db, try require(a, "task_id"))
                try scope?.check(task, commenting: true)
                try Comment(taskId: task.id, content: try require(a, "text"), author: scope.map { "agent: \($0.agentName)" } ?? "assistant").insert(db)
                return ok("Commented on “\(task.content)”")
            }
        case "create_project":
            return try db.write { db in
                var p = Project(name: try require(a, "name"), parentId: try a["parent"]?.string.map { try project(db, $0).id })
                if let color = a["color"]?.string, !color.isEmpty { p.color = color }
                p.childOrder = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") ?? 0) + 1
                try p.insert(db)
                return encode(["id": p.id, "name": p.name])
            }
        case "create_section":
            return try db.write { db in
                let p = try project(db, try require(a, "project"))
                let order = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM section WHERE projectId = ?", arguments: [p.id]) ?? 0) + 1
                let s = Section(projectId: p.id, name: try require(a, "name"), sectionOrder: order)
                try s.insert(db)
                return encode(["id": s.id, "name": s.name, "project": p.name])
            }
        case "create_filter":
            return try db.write { db in
                let query = try require(a, "query")
                _ = try FilterQuery.parse(query)   // reject invalid syntax before saving
                let f = SavedFilter(name: try require(a, "name"), query: query)
                try f.insert(db)
                return encode(["id": f.id, "name": f.name])
            }
        case "create_agent": return try db.write { try createAgent($0, a, workspace: workspace) }
        case "update_agent":
            return try db.write { db in
                var agent = try self.agent(db, try require(a, "name"))
                try apply(a, to: &agent)
                try agent.update(db)
                return ok("Updated agent \(agent.name)")
            }
        case "set_agent_access": return try db.write { try setAgentAccess($0, a) }
        case "set_task_database":
            return try db.write { db in
                let task = try task(db, try require(a, "task_id"))
                let d = try database(db, try require(a, "database"))
                if let access = StorageAccess(rawValue: try require(a, "access")) {
                    try TaskDatabase(taskId: task.id, databaseId: d.id, access: access).save(db)
                } else {
                    try db.execute(sql: "DELETE FROM taskDatabase WHERE taskId = ? AND databaseId = ?", arguments: [task.id, d.id])
                }
                return ok("Database \(d.name) on “\(task.content)”: \(a["access"]?.string ?? "")")
            }
        default:
            throw ClaudistError.invalid("Unknown tool \(name)")
        }
    }

    // MARK: Read tools

    static func overview(_ db: Database, library: SkillLibrary) throws -> String {
        func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
        let today = LocalDate.day(Date())
        let running = try Row.fetchAll(db, sql: """
            SELECT r.id, r.status, t.id AS taskId, t.content, a.name FROM run r
            JOIN task t ON t.id = r.taskId LEFT JOIN agent a ON a.id = r.agentId
            WHERE r.status IN ('queued', 'running', 'waiting') ORDER BY r.startedAt
            """).map { ["run_id": $0["id"] as String, "status": $0["status"] as String, "task_id": $0["taskId"] as String,
                        "task": $0["content"] as String, "agent": ($0["name"] as String?) ?? ""] }
        let waiting = try Attention.tasks(db).map { t -> [String: Any] in
            var d: [String: Any] = ["task_id": t.id, "task": t.content]
            if let q = t.attention { d["question"] = q }
            return d
        }
        return encode([
            "projects": try count("SELECT COUNT(*) FROM project WHERE isArchived = 0"),
            "open_tasks": try count("SELECT COUNT(*) FROM task WHERE isCompleted = 0"),
            "overdue_tasks": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE isCompleted = 0 AND dueDate < ?", arguments: [today]) ?? 0,
            "due_today": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE isCompleted = 0 AND dueDate = ?", arguments: [today]) ?? 0,
            "agents": try count("SELECT COUNT(*) FROM agent"),
            "skills": library.list().count,
            "secrets": try count("SELECT COUNT(*) FROM secret"),
            "databases": try count("SELECT COUNT(*) FROM userDatabase"),
            "filters": try count("SELECT COUNT(*) FROM filter"),
            "active_runs": running,
            "needs_you": waiting,
            "runs_last_24h": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM run WHERE startedAt >= ?",
                                               arguments: [LocalDate.stamp(Date().addingTimeInterval(-86400))]) ?? 0,
            "cost_last_7_days_usd": try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUsd), 0) FROM run WHERE startedAt >= ?",
                                                        arguments: [LocalDate.stamp(Date().addingTimeInterval(-7 * 86400))]) ?? 0,
        ])
    }

    static func listProjects(_ db: Database, archived: Bool) throws -> String {
        let projects = try Project.order(Column("childOrder"), Column("name")).fetchAll(db).filter { archived || !$0.isArchived }
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        return encode(try projects.map { p -> [String: Any] in
            var d: [String: Any] = [
                "id": p.id, "name": p.name, "color": p.color,
                "sections": try String.fetchAll(db, sql: "SELECT name FROM section WHERE projectId = ? ORDER BY sectionOrder", arguments: [p.id]),
                "open_tasks": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE projectId = ? AND isCompleted = 0", arguments: [p.id]) ?? 0,
            ]
            if let parent = p.parentId { d["parent"] = names[parent] ?? parent }
            if p.isArchived { d["archived"] = true }
            if p.isFavorite { d["favorite"] = true }
            return d
        })
    }

    static func findTasks(_ db: Database, filter: String, limit: Int) throws -> String {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups: [(title: String, tasks: [TaskItem])]
        if query.isEmpty {
            groups = [("open", try TaskItem.fetchAll(db, sql: "SELECT t.* FROM task t WHERE t.isCompleted = 0 ORDER BY \(FilterEngine.orderBy)"))]
        } else {
            groups = try FilterEngine.tasks(db, query: query, context: FilterContext(now: Date()))
        }
        let total = groups.reduce(0) { $0 + $1.tasks.count }
        var left = max(1, limit)
        let out = try groups.map { g -> [String: Any] in
            let shown = Array(g.tasks.prefix(left))
            left -= shown.count
            return ["group": g.title, "count": g.tasks.count, "tasks": try shown.map { try summary(db, $0) }]
        }
        return encode(["total": total, "groups": out, "truncated": total > limit])
    }

    static func summary(_ db: Database, _ t: TaskItem) throws -> [String: Any] {
        var d: [String: Any] = ["id": t.id, "content": t.content, "priority": "p\(t.priority)"]
        d["project"] = try String.fetchOne(db, sql: "SELECT name FROM project WHERE id = ?", arguments: [t.projectId])
        if let s = t.sectionId { d["section"] = try String.fetchOne(db, sql: "SELECT name FROM section WHERE id = ?", arguments: [s]) }
        if let due = t.dueString ?? t.dueDate { d["due"] = due }
        if let date = t.dueDate { d["due_date"] = [date, t.dueTime].compactMap { $0 }.joined(separator: " ") }
        if t.isRecurring { d["recurring"] = true }
        if let deadline = t.deadline { d["deadline"] = deadline }
        if t.isCompleted { d["completed"] = t.completedAt ?? true }
        if let parent = t.parentId { d["parent_id"] = parent }
        let labels = try String.fetchAll(db, sql: "SELECT l.name FROM label l JOIN taskLabel x ON x.labelId = l.id WHERE x.taskId = ?", arguments: [t.id])
        if !labels.isEmpty { d["labels"] = labels }
        if let agent = t.agentId { d["agent"] = try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ?", arguments: [agent]) }
        if let status = try String.fetchOne(db, sql: "SELECT status FROM run WHERE taskId = ? ORDER BY startedAt DESC, rowid DESC LIMIT 1",
                                            arguments: [t.id]) {
            d["last_run"] = status
        }
        if let q = t.attention { d["needs_you"] = q }
        if t.runOnHost { d["runs_on_host"] = true }
        return d
    }

    static func getTask(_ db: Database, id: String) throws -> String {
        let t = try task(db, id)
        var d = try summary(db, t)
        if !t.description.isEmpty { d["description"] = t.description }
        if !t.attentionChoices.isEmpty { d["needs_you_options"] = t.attentionChoices }
        d["created"] = t.createdAt
        if let source = t.source { d["source"] = source }
        d["comments"] = try Comment.filter(Column("taskId") == t.id).order(Column("createdAt")).fetchAll(db)
            .map { ["by": $0.author, "at": $0.createdAt, "text": $0.content] }
        d["subtasks"] = try TaskItem.filter(Column("parentId") == t.id).order(Column("childOrder")).fetchAll(db)
            .map { ["id": $0.id, "content": $0.content, "completed": $0.isCompleted] }
        d["attachments"] = try TaskAttachment.filter(Column("taskId") == t.id).fetchAll(db)
            .map { ["path": $0.path, "writable": $0.writable, "exists": $0.exists] }
        d["databases"] = try Row.fetchAll(db, sql: """
            SELECT d.name, l.access FROM taskDatabase l JOIN userDatabase d ON d.id = l.databaseId WHERE l.taskId = ?
            """, arguments: [t.id]).map { ["name": $0[0] as String, "access": $0[1] as String] }
        d["runs"] = try Run.filter(Column("taskId") == t.id).order(Column("startedAt").desc).limit(10).fetchAll(db).map(runSummary)
        return encode(d)
    }

    static func runSummary(_ r: Run) -> [String: Any] {
        var d: [String: Any] = ["id": r.id, "status": r.status.rawValue, "trigger": r.trigger, "started": r.startedAt]
        if let e = r.endedAt { d["ended"] = e }
        if let c = r.costUsd { d["cost_usd"] = c }
        if let e = r.error { d["error"] = String(e.prefix(500)) }
        return d
    }

    static func listAgents(_ db: Database) throws -> String {
        encode(try Agent.order(Column("name")).fetchAll(db).map { try agentInfo(db, $0, full: false) })
    }

    static func getAgent(_ db: Database, name: String) throws -> String {
        encode(try agentInfo(db, try agent(db, name), full: true))
    }

    static func agentInfo(_ db: Database, _ a: Agent, full: Bool) throws -> [String: Any] {
        var d: [String: Any] = [
            "id": a.id, "name": a.name, "description": a.description, "model": a.model ?? "default",
            "permission_mode": a.permissionMode, "tools": a.tools ?? "all", "folder": a.folderPath,
            "skills": try String.fetchAll(db, sql: "SELECT skillName FROM agentSkill WHERE agentId = ? ORDER BY skillName", arguments: [a.id]),
            "secrets": try String.fetchAll(db, sql: "SELECT s.name FROM secret s JOIN agentSecret x ON x.secretId = s.id WHERE x.agentId = ?", arguments: [a.id]),
            "storage": try Row.fetchAll(db, sql: "SELECT s.name, s.path, x.access FROM storage s JOIN agentStorage x ON x.storageId = s.id WHERE x.agentId = ?",
                                        arguments: [a.id]).map { ["name": $0[0] as String, "path": $0[1] as String, "access": $0[2] as String] },
            "databases": try Row.fetchAll(db, sql: "SELECT d.name, x.access FROM userDatabase d JOIN agentDatabase x ON x.databaseId = d.id WHERE x.agentId = ?",
                                          arguments: [a.id]).map { ["name": $0[0] as String, "access": $0[1] as String] },
            "can_call": try Delegation.delegates(db, of: a.id).map(\.name),
            "open_tasks": try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE agentId = ? AND isCompleted = 0", arguments: [a.id]) ?? 0,
        ]
        if full {
            d["prompt"] = a.prompt
            d["allow_rules"] = a.allowList
            d["deny_rules"] = a.denyList
            d["recent_runs"] = try Run.filter(Column("agentId") == a.id).order(Column("startedAt").desc).limit(10).fetchAll(db).map(runSummary)
        }
        return d
    }

    static func listRuns(_ db: Database, status: String?, taskId: String?, limit: Int) throws -> String {
        var sql = "SELECT r.*, t.content AS taskContent, a.name AS agentName FROM run r JOIN task t ON t.id = r.taskId LEFT JOIN agent a ON a.id = r.agentId WHERE 1"
        var args: [DatabaseValueConvertible] = []
        if let status, !status.isEmpty { sql += " AND r.status = ?"; args.append(status) }
        if let taskId, !taskId.isEmpty { sql += " AND r.taskId = ?"; args.append(taskId) }
        sql += " ORDER BY r.startedAt DESC, r.rowid DESC LIMIT ?"
        args.append(max(1, limit))
        return encode(try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row -> [String: Any] in
            var d = runSummary(try Run(row: row))
            d["task_id"] = row["taskId"] as String
            d["task"] = row["taskContent"] as String
            d["agent"] = (row["agentName"] as String?) ?? ""
            return d
        })
    }

    static func getRun(_ db: Database, id: String, max: Int) throws -> String {
        guard let run = try Run.fetchOne(db, key: id) else { throw ClaudistError.invalid("No run with id \(id)") }
        let events = try RunEvent.filter(Column("runId") == id).order(Column("seq")).fetchAll(db)
        var lines: [String] = []
        for e in events {
            guard let v = JSONValue.parse(e.json) else { continue }
            switch e.kind {
            case "user/input": lines.append("USER: " + clip(v["text"]?.string ?? "", 1500))
            case "assistant":
                for block in v["message"]?["content"]?.array ?? [] {
                    if block["type"]?.string == "text", let t = block["text"]?.string, !t.isEmpty { lines.append("AGENT: " + clip(t, 1500)) }
                    if block["type"]?.string == "tool_use" {
                        lines.append("TOOL \(block["name"]?.string ?? "?"): " + clip(block["input"]?.prettyJSON ?? "", 300))
                    }
                }
            case "user":
                for block in v["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                    let text = block["content"]?.string ?? (block["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                    lines.append((block["is_error"]?.bool == true ? "TOOL ERROR: " : "TOOL RESULT: ") + clip(text, 300))
                }
            case "permission": lines.append("PERMISSION ASKED: \(v["tool"]?.string ?? "?")")
            case "ask": lines.append("ASKED USER: " + (v["question"]?.string ?? ""))
            case "delegate": lines.append("DELEGATED to \(v["agent"]?.string ?? "?"): \(v["title"]?.string ?? "")")
            case "stderr": lines.append("STDERR: " + clip(v["text"]?.string ?? "", 300))
            case let k where k.hasPrefix("result"): lines.append("RESULT (\(k)): " + clip(v["result"]?.string ?? "", 3000))
            default: break
            }
        }
        let shown = lines.count > max ? ["… \(lines.count - max) earlier events omitted"] + lines.suffix(max) : lines
        var d = runSummary(run)
        d["transcript"] = shown
        return encode(d)
    }

    static func listSkills(_ db: Database, library: SkillLibrary) throws -> String {
        let users = Dictionary(grouping: try Row.fetchAll(db, sql: "SELECT s.skillName, a.name FROM agentSkill s JOIN agent a ON a.id = s.agentId"),
                               by: { $0[0] as String }).mapValues { $0.map { $0[1] as String } }
        return encode(library.list().map { s in
            ["name": s.name, "description": s.description, "agents": users[s.name] ?? [],
             "files": library.files(of: s).filter { !$0.isDirectory }.map(\.path)] as [String: Any]
        })
    }

    static func getSkill(_ name: String, library: SkillLibrary) throws -> String {
        guard let skill = library.list().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ClaudistError.invalid("No skill named \(name)")
        }
        return encode(["name": skill.name, "skill_md": clip(library.readSkillMD(skill), 20_000),
                       "files": library.files(of: skill).filter { !$0.isDirectory }.map { ["path": $0.path, "size": $0.size, "executable": $0.isExecutable] }])
    }

    static func listSecrets(_ db: Database) throws -> String {
        encode(try Secret.order(Column("name")).fetchAll(db).map { s in
            [
                "name": s.name, "description": s.description, "as_file": s.asFile,
                "agents": try String.fetchAll(db, sql: "SELECT a.name FROM agent a JOIN agentSecret x ON x.agentId = a.id WHERE x.secretId = ?", arguments: [s.id]),
                "skills": try String.fetchAll(db, sql: "SELECT skillName FROM skillSecret WHERE secretId = ?", arguments: [s.id]),
            ] as [String: Any]
        })
    }

    static func listStorage(_ db: Database) throws -> String {
        encode(try Storage.order(Column("name")).fetchAll(db).map { s in
            ["name": s.name, "path": s.path,
             "agents": try Row.fetchAll(db, sql: "SELECT a.name, x.access FROM agent a JOIN agentStorage x ON x.agentId = a.id WHERE x.storageId = ?",
                                        arguments: [s.id]).map { ["agent": $0[0] as String, "access": $0[1] as String] }] as [String: Any]
        })
    }

    static func listDatabases(_ db: Database) throws -> String {
        encode(try UserDatabase.order(Column("name")).fetchAll(db).map { d in
            var info: [String: Any] = ["name": d.name, "description": d.description, "path": d.path, "created_in_app": d.managed, "exists": d.exists]
            if d.exists, let tables = try? SQLiteFile.tables(d.path) {
                info["tables"] = tables.map { ["name": $0.name, "rows": $0.rowCount ?? 0, "columns": $0.columns.map(\.name)] as [String: Any] }
            }
            info["agents"] = try Row.fetchAll(db, sql: "SELECT a.name, x.access FROM agent a JOIN agentDatabase x ON x.agentId = a.id WHERE x.databaseId = ?",
                                              arguments: [d.id]).map { ["agent": $0[0] as String, "access": $0[1] as String] }
            return info
        })
    }

    static func listFilters(_ db: Database) throws -> String {
        encode([
            "filters": try SavedFilter.order(Column("itemOrder"), Column("name")).fetchAll(db).map { ["id": $0.id, "name": $0.name, "query": $0.query] },
            "labels": try String.fetchAll(db, sql: "SELECT name FROM label ORDER BY name"),
        ])
    }

    // MARK: Change tools

    static func createTask(_ db: Database, _ a: JSONValue, scope: AgentScope? = nil) throws -> String {
        let p = try project(db, try require(a, "project"))
        var t = TaskItem(projectId: p.id, content: try require(a, "content"))
        t.description = a["description"]?.string ?? ""
        if let parent = a["parent_id"]?.string, !parent.isEmpty {
            let parentTask = try task(db, parent)
            t.parentId = parentTask.id
            t.projectId = parentTask.projectId
            t.sectionId = parentTask.sectionId
        }
        try apply(a, to: &t, db)
        if let scope {
            try scope.checkAssignment(t.agentId)
            t.source = "agent: \(scope.agentName)"
        }
        t.childOrder = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE projectId = ?", arguments: [t.projectId]) ?? 0) + 1
        try t.insert(db)
        try setLabels(db, t.id, a["labels"])
        return encode(try summary(db, t))
    }

    static func updateTask(_ db: Database, _ a: JSONValue, scope: AgentScope? = nil) throws -> String {
        var t = try task(db, try require(a, "id"))
        try scope?.check(t)
        if let c = a["content"]?.string, !c.isEmpty { t.content = c }
        if let d = a["description"]?.string { t.description = d }
        if let p = a["project"]?.string, !p.isEmpty {
            let project = try project(db, p)
            if project.id != t.projectId { t.projectId = project.id; t.sectionId = nil }
        }
        try apply(a, to: &t, db)
        try scope?.checkAssignment(t.agentId)
        try t.update(db)
        try setLabels(db, t.id, a["labels"])
        return encode(try summary(db, t))
    }

    /// Shared optional task fields: section, priority, due, deadline, agent.
    static func apply(_ a: JSONValue, to t: inout TaskItem, _ db: Database) throws {
        if let s = a["section"]?.string {
            if s.isEmpty { t.sectionId = nil } else {
                guard let id = try String.fetchOne(db, sql: "SELECT id FROM section WHERE projectId = ? AND name = ? COLLATE NOCASE",
                                                   arguments: [t.projectId, s]) else {
                    throw ClaudistError.invalid("No section \(s) in this project")
                }
                t.sectionId = id
            }
        }
        if let p = a["priority"]?.number { t.priority = min(4, max(1, Int(p))) }
        if let due = a["due"]?.string {
            if due.isEmpty {
                t.dueDate = nil; t.dueTime = nil; t.dueString = nil; t.isRecurring = false
            } else {
                let d = try DueParser.parse(due, context: FilterContext(now: Date()))
                t.dueDate = d.date; t.dueTime = d.time; t.dueString = d.string; t.isRecurring = d.isRecurring
            }
        }
        if let deadline = a["deadline"]?.string {
            if !deadline.isEmpty && LocalDate.parse(deadline) == nil { throw ClaudistError.invalid("Deadline must be YYYY-MM-DD") }
            t.deadline = deadline.isEmpty ? nil : deadline
        }
        if let name = a["agent"]?.string { t.agentId = name.isEmpty ? nil : try agent(db, name).id }
    }

    static func setLabels(_ db: Database, _ taskId: ID, _ value: JSONValue?) throws {
        guard let names = value?.array?.compactMap(\.string) else { return }
        try db.execute(sql: "DELETE FROM taskLabel WHERE taskId = ?", arguments: [taskId])
        for name in names where !name.isEmpty {
            let clean = name.hasPrefix("@") ? String(name.dropFirst()) : name
            var label = try Label.filter(sql: "name = ? COLLATE NOCASE", arguments: [clean]).fetchOne(db)
            if label == nil {
                label = Label(name: clean)
                try label!.insert(db)
            }
            try TaskLabel(taskId: taskId, labelId: label!.id).save(db)
        }
    }

    static func deleteTree(_ db: Database, _ id: ID) throws {
        for child in try String.fetchAll(db, sql: "SELECT id FROM task WHERE parentId = ?", arguments: [id]) {
            try deleteTree(db, child)
        }
        try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [id])
    }

    static func createAgent(_ db: Database, _ a: JSONValue, workspace: AgentWorkspace) throws -> String {
        let name = try require(a, "name")
        if try Agent.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchCount(db) > 0 {
            throw ClaudistError.invalid("An agent named \(name) already exists")
        }
        let folder = workspace.newFolder(for: name, taken: try String.fetchAll(db, sql: "SELECT folderPath FROM agent"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var agent = Agent(name: name, folderPath: folder.path)
        try apply(a, to: &agent)
        try agent.insert(db)
        return encode(try agentInfo(db, agent, full: false))
    }

    static func apply(_ a: JSONValue, to agent: inout Agent) throws {
        if let d = a["description"]?.string { agent.description = d }
        if let p = a["prompt"]?.string { agent.prompt = p }
        if let m = a["model"]?.string { agent.model = m.isEmpty ? nil : m }
        if let t = a["tools"]?.string { agent.tools = t.isEmpty ? nil : t }
        if let mode = a["permission_mode"]?.string, !mode.isEmpty {
            // bypassPermissions is the user's call, made in the Agents screen.
            guard ["manual", "acceptEdits", "plan", "auto", "dontAsk"].contains(mode) else {
                throw ClaudistError.invalid("Permission mode \(mode) can only be set by the user in the Agents screen")
            }
            agent.permissionMode = mode
        }
    }

    static func setAgentAccess(_ db: Database, _ a: JSONValue) throws -> String {
        let agent = try agent(db, try require(a, "agent"))
        let name = try require(a, "name")
        let access = try require(a, "access")
        let on = ["on", "ro", "rw"].contains(access)
        switch try require(a, "kind") {
        case "skill":
            if on { try AgentSkill(agentId: agent.id, skillName: name).save(db) }
            else { try db.execute(sql: "DELETE FROM agentSkill WHERE agentId = ? AND skillName = ?", arguments: [agent.id, name]) }
        case "secret":
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM secret WHERE name = ?", arguments: [name]) else {
                throw ClaudistError.invalid("No secret named \(name)")
            }
            if on { try db.execute(sql: "INSERT OR IGNORE INTO agentSecret (agentId, secretId) VALUES (?, ?)", arguments: [agent.id, id]) }
            else { try db.execute(sql: "DELETE FROM agentSecret WHERE agentId = ? AND secretId = ?", arguments: [agent.id, id]) }
        case "delegate":
            let other = try self.agent(db, name)
            guard other.id != agent.id else { throw ClaudistError.invalid("An agent can't call itself") }
            if on { try AgentDelegate(agentId: agent.id, delegateId: other.id).save(db) }
            else { try db.execute(sql: "DELETE FROM agentDelegate WHERE agentId = ? AND delegateId = ?", arguments: [agent.id, other.id]) }
        case "storage":
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM storage WHERE name = ? COLLATE NOCASE", arguments: [name]) else {
                throw ClaudistError.invalid("No storage named \(name)")
            }
            if let level = StorageAccess(rawValue: access) { try AgentStorage(agentId: agent.id, storageId: id, access: level).save(db) }
            else { try db.execute(sql: "DELETE FROM agentStorage WHERE agentId = ? AND storageId = ?", arguments: [agent.id, id]) }
        case "database":
            let d = try database(db, name)
            if let level = StorageAccess(rawValue: access) { try AgentDatabase(agentId: agent.id, databaseId: d.id, access: level).save(db) }
            else { try db.execute(sql: "DELETE FROM agentDatabase WHERE agentId = ? AND databaseId = ?", arguments: [agent.id, d.id]) }
        case let kind:
            throw ClaudistError.invalid("Unknown kind \(kind)")
        }
        return ok("\(agent.name): \(a["kind"]?.string ?? "") \(name) → \(access)")
    }

    // MARK: Lookups

    static func require(_ a: JSONValue, _ key: String) throws -> String {
        guard let v = a[key]?.string, !v.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ClaudistError.invalid("Missing \(key)")
        }
        return v
    }

    static func task(_ db: Database, _ id: String) throws -> TaskItem {
        guard let t = try TaskItem.fetchOne(db, key: id) else { throw ClaudistError.invalid("No task with id \(id); use find_tasks") }
        return t
    }

    static func project(_ db: Database, _ ref: String) throws -> Project {
        let clean = ref.hasPrefix("#") ? String(ref.dropFirst()) : ref
        if let p = try Project.fetchOne(db, key: clean) { return p }
        guard let p = try Project.filter(sql: "name = ? COLLATE NOCASE", arguments: [clean]).fetchOne(db) else {
            throw ClaudistError.invalid("No project \(ref); projects: \(try String.fetchAll(db, sql: "SELECT name FROM project").joined(separator: ", "))")
        }
        return p
    }

    static func agent(_ db: Database, _ name: String) throws -> Agent {
        if let a = try Agent.filter(sql: "name = ? COLLATE NOCASE OR id = ?", arguments: [name, name]).fetchOne(db) { return a }
        throw ClaudistError.invalid("No agent \(name); agents: \(try String.fetchAll(db, sql: "SELECT name FROM agent").joined(separator: ", "))")
    }

    static func database(_ db: Database, _ name: String) throws -> UserDatabase {
        if let d = try UserDatabase.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db) { return d }
        throw ClaudistError.invalid("No database \(name)")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    static func ok(_ message: String) -> String { encode(["ok": true, "message": message]) }

    static func encode(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Command line of the assistant's Claude Code process.
public enum AssistantSession {
    /// The assistant gets no built-in tools (no files, no shell): only the app's tools,
    /// with no user skills, commands or MCP servers.
    public static func arguments(model: String?, confirmChanges: Bool, resume sessionId: String?) -> [String] {
        let allowed = AssistantTools.all.filter { !$0.mutating || !confirmChanges }.map { AssistantTools.qualified($0.name) }
        let settings = AssistantTools.encode(["permissions": ["allow": allowed]])
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", "manual",
            "--setting-sources", "project,local",
            "--settings", settings,
            "--strict-mcp-config",
            "--mcp-config", Delegation.mcpConfig,
            "--disable-slash-commands",
            "--tools", "",
            "--append-system-prompt", AssistantTools.systemPrompt(),
        ]
        if let model, !model.isEmpty { args += ["--model", model] }
        if let sessionId { args += ["--resume", sessionId] }
        return args
    }

    public static func toolDefinitions() -> [[String: Any]] {
        AssistantTools.all.map(\.definition)
    }
}
