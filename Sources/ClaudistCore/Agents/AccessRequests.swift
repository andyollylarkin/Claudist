import Foundation
import GRDB

/// An agent asking the user for more rights: a folder or file (read or write), or a command its
/// permission mode keeps refusing. Shown in "Needs you"; the user allows it for the task, for the
/// agent from now on, or denies it. Only the user grants: the agent can ask, never widen its rights itself.
public struct AccessRequest: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public enum Kind: String, Codable, Sendable { case path, command }
    public enum Status: String, Codable, Sendable { case pending, task, agent, denied }

    public var id: ID = newID()
    public var taskId: ID
    public var agentId: ID
    public var kind: Kind
    /// Absolute path, or the permission rule for a command (`Bash(gofmt:*)`).
    public var target: String
    /// For paths.
    public var access: StorageAccess = .ro
    /// For commands: the command the agent wants to run.
    public var command: String?
    public var reason: String
    public var status: Status = .pending
    public var createdAt = LocalDate.stamp(Date())
    public var decidedAt: String?

    public init(taskId: ID, agentId: ID, kind: Kind, target: String, reason: String) {
        self.taskId = taskId
        self.agentId = agentId
        self.kind = kind
        self.target = target
        self.reason = reason
    }
}

public enum AccessRequests {
    public static let toolName = "request_access"
    public static var qualifiedToolName: String { "mcp__\(Delegation.serverName)__\(toolName)" }

    public static let allowTask = "Allow for this task"
    public static func allowAgent(_ agent: String) -> String { "Always allow for \(agent)" }
    public static let deny = "Deny"

    public static func toolDefinition() -> [String: Any] {
        [
            "name": toolName,
            "description": """
                Ask the user for access you lack: write (or read) access to a folder or file — e.g. an edit refused \
                with "denied by your permission settings" in a read-only folder — or permission for a command that \
                keeps being refused. Give `path` with `access`, or `command`. The request appears in the user's \
                "Needs you" list; after calling this, stop and end your turn with a short summary. When the user \
                decides, you are resumed with your rights updated. Ask once, for exactly what the task needs \
                (the project folder, not your whole home directory).
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path of the folder or file"],
                    "access": ["type": "string", "enum": ["read", "write"], "description": "For a path; default write"],
                    "command": ["type": "string", "description": "The shell command you need to run, e.g. `gofmt -w pkg/ts/server_test.go`"],
                    "reason": ["type": "string", "description": "Why the task needs it, in a sentence"],
                ],
                "required": ["reason"],
            ] as [String: Any],
        ]
    }

    public static let promptSection = """
        ## When you lack access
        Claudist manages your permissions; the user can't fix them in Claude Code settings files and you must not \
        suggest that. If a folder or file you need is read-only or outside your folders, or a command you need is \
        refused by the permission system, call `\(qualifiedToolName)` with the path (and access) or the command and \
        the reason, then stop and end your turn. Don't work around a refusal (other tools, copying files, scripts) \
        and don't ask a sub-agent to do what you were refused.
        """

    /// The rule a command request grants: the program, plus its subcommand when there is one
    /// (`git commit -m …` → `Bash(git commit:*)`, `gofmt -w x.go` → `Bash(gofmt:*)`).
    public static func rule(for command: String) -> String? {
        let words = command.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first, !program.contains("$"), !["sudo", "sh", "bash", "zsh", "eval", "env"].contains(program) else {
            return nil
        }
        var prefix = program
        if words.count > 1, words[1].range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil {
            prefix += " " + words[1]
        }
        return "Bash(\(prefix):*)"
    }

    /// Stores a request from a run and puts it into "Needs you" as a question with the decisions as options.
    public static func create(_ db: Database, taskId: ID, agent: Agent, arguments a: JSONValue?) throws -> AccessRequest {
        let reason = a?["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reason.isEmpty else { throw ClaudistError.invalid("Say why the task needs it (reason)") }
        var request: AccessRequest
        if let path = a?["path"]?.string?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw ClaudistError.invalid("Give an absolute path") }
            let standard = URL(fileURLWithPath: expanded).standardizedFileURL.path
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            guard standard != "/", standard != home else {
                throw ClaudistError.invalid("Ask for the folder the task needs, not \(standard)")
            }
            request = AccessRequest(taskId: taskId, agentId: agent.id, kind: .path, target: standard, reason: reason)
            request.access = a?["access"]?.string == "read" ? .ro : .rw
        } else if let command = a?["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            guard let rule = rule(for: command) else {
                throw ClaudistError.invalid("Give the command itself (not wrapped in sudo, sh -c or eval)")
            }
            request = AccessRequest(taskId: taskId, agentId: agent.id, kind: .command, target: rule, reason: reason)
            request.command = command
        } else {
            throw ClaudistError.invalid("Give a path or a command")
        }
        // A new request replaces an unanswered one: the question shows one at a time.
        try db.execute(sql: "UPDATE accessRequest SET status = 'denied', decidedAt = ? WHERE taskId = ? AND status = 'pending'",
                       arguments: [LocalDate.stamp(Date()), taskId])
        try request.insert(db)
        try Attention.mark(db, taskId: taskId, question: question(request, agent: agent.name),
                           options: [allowTask, allowAgent(agent.name), deny])
        return request
    }

    public static func question(_ r: AccessRequest, agent: String) -> String {
        switch r.kind {
        case .path:
            return "🔐 \(agent) asks for \(r.access == .rw ? "write" : "read") access to \(r.target)\nWhy: \(r.reason)"
        case .command:
            return "🔐 \(agent) asks to run \(r.command ?? r.target) (allows \(r.target))\nWhy: \(r.reason)"
        }
    }

    public static func pending(_ db: Database, taskId: ID) throws -> AccessRequest? {
        try AccessRequest.filter(Column("taskId") == taskId && Column("status") == AccessRequest.Status.pending.rawValue)
            .order(Column("createdAt").desc).fetchOne(db)
    }

    /// Applies the user's choice (one of the options) and returns the message the agent is resumed with,
    /// or nil when `answer` isn't a decision on the pending request.
    public static func decide(_ db: Database, taskId: ID, answer: String) throws -> String? {
        guard var request = try pending(db, taskId: taskId),
              let agent = try Agent.fetchOne(db, key: request.agentId) else { return nil }
        let choice = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = request.kind == .path
            ? "\(request.access == .rw ? "write" : "read") access to \(request.target)"
            : "running \(request.target) commands"
        switch choice {
        case allowTask:
            request.status = .task
            if request.kind == .path {
                if var existing = try TaskAttachment.filter(Column("taskId") == taskId && Column("path") == request.target).fetchOne(db) {
                    existing.writable = existing.writable || request.access == .rw
                    try existing.update(db)
                } else {
                    var a = TaskAttachment(taskId: taskId, url: URL(fileURLWithPath: request.target))
                    // A path that doesn't exist yet: a folder unless it has an extension.
                    if !a.exists { a.isDirectory = URL(fileURLWithPath: request.target).pathExtension.isEmpty }
                    a.writable = request.access == .rw
                    try a.insert(db)
                }
            }
        case allowAgent(agent.name):
            request.status = .agent
            if request.kind == .path {
                let storage: Storage
                if let s = try Storage.filter(Column("path") == request.target).fetchOne(db) {
                    storage = s
                } else {
                    var name = (request.target as NSString).lastPathComponent
                    if try Storage.filter(Column("name") == name).fetchCount(db) > 0 { name = request.target }
                    storage = Storage(name: name, path: request.target)
                    try storage.insert(db)
                }
                let current = try AgentStorage.filter(Column("agentId") == agent.id && Column("storageId") == storage.id).fetchOne(db)
                let access: StorageAccess = current?.access == .rw || request.access == .rw ? .rw : .ro
                try AgentStorage(agentId: agent.id, storageId: storage.id, access: access).save(db)
            } else {
                var a = agent
                if !a.allowList.contains(request.target) {
                    a.allowList.append(request.target)
                    try a.update(db)
                }
            }
        case deny:
            request.status = .denied
        default:
            // Answered in words: the agent reads the reply and may ask again; nothing is granted.
            request.status = .denied
            request.decidedAt = LocalDate.stamp(Date())
            try request.update(db)
            return nil
        }
        request.decidedAt = LocalDate.stamp(Date())
        try request.update(db)
        switch request.status {
        case .denied:
            return "The user denied \(what). Don't try to get around it; continue without it, or explain what is left undone."
        case .task:
            return "The user allowed \(what) for this task. Your permissions are updated; continue where you stopped."
        default:
            return "The user allowed \(what) from now on. Your permissions are updated; continue where you stopped."
        }
    }

    /// Command rules allowed for this task only, added to the run's settings.
    public static func taskRules(_ db: Database, taskId: ID) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT target FROM accessRequest WHERE taskId = ? AND kind = 'command' AND status = 'task'
            """, arguments: [taskId])
    }
}
