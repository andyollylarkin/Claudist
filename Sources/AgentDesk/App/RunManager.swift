import AgentDeskCore
import AppKit
import Foundation
import GRDB
import UserNotifications

/// A run in progress: the process and its unanswered permission requests.
@MainActor
final class LiveRun: ObservableObject {
    let runId: ID
    let taskId: ID
    let process: AgentProcess
    @Published var pending: [PermissionRequest] = []

    init(runId: ID, taskId: ID, process: AgentProcess) {
        self.runId = runId
        self.taskId = taskId
        self.process = process
    }
}

/// Starts agent runs for tasks, records their stream into `runEvent`,
/// answers permission prompts and fires recurring (scheduled) tasks.
@MainActor
final class RunManager: ObservableObject {
    @Published private(set) var live: [ID: LiveRun] = [:]   // by taskId

    private let store: AppStore
    private var timer: Timer?
    private var stopping: Set<ID> = []
    /// Secret values per run, masked before events are stored.
    private var redactions: [ID: [(name: String, value: String)]] = [:]
    /// Agents each run may call (by runId).
    private var delegatesByRun: [ID: [Agent]] = [:]
    /// Sub-agent calls waiting for an answer, by the sub-task id.
    private var pendingCalls: [ID: PendingCall] = [:]

    private struct PendingCall {
        let parentTaskId: ID
        let requestId: String
        let rpcId: JSONValue?
        let agentName: String
    }

    init(store: AppStore) {
        self.store = store
        markOrphanedRuns()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDueSchedules() }
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    var waitingCount: Int { live.values.filter { !$0.pending.isEmpty }.count }

    // MARK: Start / follow-up / stop

    /// Starts the task's agent. Without `message` the task itself becomes the prompt;
    /// with a message the last session of this task is resumed (dialog).
    /// `trigger`: "manual", "schedule" or "agent" (called by another agent).
    func start(_ task: TaskItem, message: String? = nil, trigger: String = "manual") {
        guard live[task.id] == nil else { return }
        guard let agent = store.agent(task.agentId) else {
            store.errorMessage = "Assign an agent to this task first"
            return
        }
        guard var config = store.launchConfig(for: agent) else { return }
        config.taskId = task.id
        config.attachments = store.read { try TaskAttachment.filter(Column("taskId") == task.id).order(Column("createdAt")).fetchAll($0) } ?? []

        let resume = message == nil ? nil : store.read { db in
            try String.fetchOne(db, sql: """
                SELECT sessionId FROM run WHERE taskId = ? AND sessionId IS NOT NULL
                ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [task.id])
        } ?? nil
        let prompt = message ?? initialPrompt(task, attachments: config.attachments)

        var run = Run(taskId: task.id, agentId: agent.id, trigger: trigger)
        run.status = .running
        do {
            let settings = try store.workspace.prepare(config)
            let args = store.workspace.arguments(config, settingsURL: settings, resume: resume)
            let exe = try ClaudeCLI.executable()
            let secrets = config.secrets
            let (secretEnv, secretValues) = try Secrets.environment(secrets, store: store.secretStore,
                                                                    fileDir: secretFiles(runId: run.id))
            var environment = ClaudeCLI.environment().merging(secretEnv) { _, secret in secret }
            if !config.delegates.isEmpty {
                // A sub-agent call blocks the tool until the other agent finishes.
                environment["MCP_TOOL_TIMEOUT"] = "86400000"
                delegatesByRun[run.id] = config.delegates
            }
            redactions[run.id] = secrets.compactMap { s in secretValues[s.name].flatMap { $0.count >= 4 ? (s.name, $0) : nil } }
            try store.db.writer.write { db in
                try run.insert(db)
                var e = RunEvent(runId: run.id, kind: "user/input", json: Self.json(["text": prompt]))
                try e.insert(db)
            }
            let runId = run.id
            let process = AgentProcess(executable: exe, arguments: args,
                                       cwd: URL(fileURLWithPath: agent.folderPath),
                                       environment: environment) { [weak self] event in
                DispatchQueue.main.async { self?.handle(event, runId: runId, taskId: task.id) }
            }
            let liveRun = LiveRun(runId: run.id, taskId: task.id, process: process)
            live[task.id] = liveRun
            try process.start()
            if !config.delegates.isEmpty { process.initialize(sdkMcpServers: [Delegation.serverName]) }
            process.send(prompt)
        } catch {
            live[task.id] = nil
            finish(runId: run.id, status: .failed, error: "\(error.localizedDescription)")
            store.report(error)
        }
    }

    /// Chat input: goes to the running process, or resumes the session in a new run.
    func send(_ task: TaskItem, text: String) {
        if let liveRun = live[task.id] {
            liveRun.process.send(text)
            record(runId: liveRun.runId, kind: "user/input", ["text": text])
        } else {
            start(task, message: text)
        }
    }

    func stop(taskId: ID) {
        guard let liveRun = live[taskId] else { return }
        // Sub-agents working for this task stop too.
        for (child, call) in pendingCalls where call.parentTaskId == taskId { stop(taskId: child) }
        stopping.insert(liveRun.runId)
        liveRun.process.interrupt()
        liveRun.process.closeInput()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { liveRun.process.terminate() }
    }

    func respond(taskId: ID, _ request: PermissionRequest, allow: Bool, always: Bool = false) {
        guard let liveRun = live[taskId] else { return }
        liveRun.process.respond(request, allow ? .allow : .deny("The user denied this action"))
        liveRun.pending.removeAll { $0.id == request.id }
        record(runId: liveRun.runId, kind: "permission/answer",
               ["request_id": request.id, "allow": allow, "always": always])
        if liveRun.pending.isEmpty { setStatus(runId: liveRun.runId, .running) }
        if allow && always, let task = store.read({ try TaskItem.fetchOne($0, key: taskId) }) ?? nil,
           var agent = store.agent(task.agentId) {
            let rule = Self.rule(for: request)
            if !agent.allowList.contains(rule) {
                agent.allowList.append(rule)
                store.write { try agent.update($0) }
            }
        }
    }

    // MARK: Events

    private func handle(_ event: AgentProcess.Event, runId: ID, taskId: ID) {
        switch event {
        case .message(let kind, let rawJSON):
            let json = redact(rawJSON, runId: runId)
            store.write { db in
                var e = RunEvent(runId: runId, kind: kind, json: json)
                try e.insert(db)
            }
            if kind == "system/init", let sid = JSONValue.parse(json)?["session_id"]?.string {
                store.write { db in
                    try db.execute(sql: "UPDATE run SET sessionId = ? WHERE id = ?", arguments: [sid, runId])
                }
            }
            if kind.hasPrefix("result") {
                let v = JSONValue.parse(json)
                let ok = kind == "result/success" && v?["is_error"]?.bool != true
                store.write { db in
                    try db.execute(sql: """
                        UPDATE run SET costUsd = ?, inputTokens = ?, outputTokens = ? WHERE id = ?
                        """, arguments: [v?["total_cost_usd"]?.number,
                                         v?["usage"]?["input_tokens"]?.number.map { Int($0) },
                                         v?["usage"]?["output_tokens"]?.number.map { Int($0) }, runId])
                }
                let status: RunStatus = stopping.contains(runId) ? .cancelled : (ok ? .done : .failed)
                finish(runId: runId, status: status, error: ok ? nil : v?["result"]?.string)
                live[taskId]?.process.closeInput()
                answerCall(childTaskId: taskId, ok: ok, text: v?["result"]?.string ?? "")
                notify(taskId: taskId, title: ok ? "Agent finished" : "Agent run failed")
            }

        case .permission(let request):
            live[taskId]?.pending.append(request)
            record(runId: runId, kind: "permission", ["request_id": request.id, "tool": request.toolName,
                                                       "description": redact(request.description ?? "", runId: runId),
                                                       "input": redact(request.inputJSON, runId: runId)])
            setStatus(runId: runId, .waiting)
            notify(taskId: taskId, title: "Agent needs approval: \(request.toolName)")

        case .mcp(let requestId, let server, let message):
            handleMCP(requestId: requestId, server: server, message: message, runId: runId, taskId: taskId)

        case .stderr(let text):
            record(runId: runId, kind: "stderr", ["text": redact(text, runId: runId)])

        case .exited(let code):
            let current = store.read { try Run.fetchOne($0, key: runId) } ?? nil
            if let current, [.running, .waiting, .queued].contains(current.status) {
                let status: RunStatus = stopping.contains(runId) ? .cancelled : (code == 0 ? .done : .failed)
                finish(runId: runId, status: status, error: code == 0 ? nil : "claude exited with code \(code)")
            }
            answerCall(childTaskId: taskId, ok: false, text: "The agent stopped without an answer.")
            stopping.remove(runId)
            redactions[runId] = nil
            try? FileManager.default.removeItem(at: secretFiles(runId: runId))
            delegatesByRun[runId] = nil
            live[taskId] = nil
        }
    }

    // MARK: Sub-agents

    private func handleMCP(requestId: String, server: String, message: JSONValue, runId: ID, taskId: ID) {
        guard let process = live[taskId]?.process else { return }
        let id = message["id"]
        switch message["method"]?.string {
        case "initialize":
            process.respondMCP(requestId: requestId, id: id, result: [
                "protocolVersion": message["params"]?["protocolVersion"]?.string ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": Delegation.serverName, "version": "1"],
            ])
        case "tools/list":
            let tools = (delegatesByRun[runId] ?? []).isEmpty ? [] : [Delegation.toolDefinition(delegatesByRun[runId]!)]
            process.respondMCP(requestId: requestId, id: id, result: ["tools": tools])
        case "tools/call":
            let args = message["params"]?["arguments"]
            callAgent(requestId: requestId, rpcId: id, parentTaskId: taskId, runId: runId,
                      agentName: args?["agent"]?.string ?? "", title: args?["title"]?.string,
                      instructions: args?["task"]?.string ?? "")
        default:
            if id == nil {
                process.respondMCP(requestId: requestId, id: nil, result: nil)
            } else {
                process.respondMCP(requestId: requestId, id: id, result: nil, error: (-32601, "Method not found"))
            }
        }
    }

    /// Creates a sub-task for the called agent, runs it and answers the parent when it finishes.
    private func callAgent(requestId: String, rpcId: JSONValue?, parentTaskId: ID, runId: ID,
                           agentName: String, title: String?, instructions: String) {
        guard let parentProcess = live[parentTaskId]?.process,
              let parent = store.read({ try TaskItem.fetchOne($0, key: parentTaskId) }) ?? nil,
              let callerId = parent.agentId else { return }
        func fail(_ text: String) {
            parentProcess.respondMCP(requestId: requestId, id: rpcId,
                                     result: ["content": [["type": "text", "text": text]], "isError": true])
        }
        let target: Agent
        do {
            target = try store.db.writer.read {
                try Delegation.validate($0, callerId: callerId, parentTaskId: parentTaskId, agentName: agentName)
            }
        } catch {
            fail(error.localizedDescription)
            return
        }

        let firstLine = instructions.split(separator: "\n").first.map(String.init) ?? instructions
        var child = TaskItem(projectId: parent.projectId, content: title?.isEmpty == false ? title! : String(firstLine.prefix(120)))
        child.description = instructions
        child.parentId = parent.id
        child.sectionId = parent.sectionId
        child.agentId = target.id
        child.priority = parent.priority
        child.source = "agent"
        do {
            try store.db.writer.write { db in
                child.childOrder = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE parentId = ?", arguments: [parent.id]) ?? 0) + 1
                try child.insert(db)
                // The sub-agent sees the same host files as the task it works for.
                for var a in try TaskAttachment.filter(Column("taskId") == parent.id).fetchAll(db) {
                    a.id = newID()
                    a.taskId = child.id
                    try a.insert(db)
                }
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        record(runId: runId, kind: "delegate", ["agent": target.name, "taskId": child.id, "title": child.content])
        pendingCalls[child.id] = PendingCall(parentTaskId: parentTaskId, requestId: requestId, rpcId: rpcId, agentName: target.name)
        start(child, trigger: "agent")
        if live[child.id] == nil {
            pendingCalls[child.id] = nil
            fail("Could not start \(target.name). Check its settings in AgentDesk.")
        }
    }

    private func answerCall(childTaskId: ID, ok: Bool, text: String) {
        guard let call = pendingCalls.removeValue(forKey: childTaskId) else { return }
        if ok {
            store.write { db in
                try db.execute(sql: "UPDATE task SET isCompleted = 1, completedAt = ? WHERE id = ?",
                               arguments: [LocalDate.stamp(Date()), childTaskId])
            }
        }
        guard let parent = live[call.parentTaskId]?.process else { return }
        let answer = text.isEmpty ? (ok ? "\(call.agentName) finished without a text answer." : "\(call.agentName) failed.") : text
        var result: [String: Any] = ["content": [["type": "text", "text": answer]]]
        if !ok { result["isError"] = true }
        parent.respondMCP(requestId: call.requestId, id: call.rpcId, result: result)
    }

    /// Replaces secret values with `‹NAME›` so they never land in the run history.
    private func redact(_ text: String, runId: ID) -> String {
        var out = text
        for (name, value) in redactions[runId] ?? [] {
            out = out.replacingOccurrences(of: value, with: "‹\(name)›")
            // Values inside JSON strings are escaped.
            if let data = try? JSONEncoder().encode(value), let escaped = String(data: data, encoding: .utf8)?.dropFirst().dropLast(),
               escaped != value[...] {
                out = out.replacingOccurrences(of: String(escaped), with: "‹\(name)›")
            }
        }
        return out
    }

    private func finish(runId: ID, status: RunStatus, error: String?) {
        store.write { db in
            try db.execute(sql: "UPDATE run SET status = ?, endedAt = ?, error = COALESCE(?, error) WHERE id = ?",
                           arguments: [status.rawValue, LocalDate.stamp(Date()), error, runId])
        }
    }

    private func setStatus(runId: ID, _ status: RunStatus) {
        store.write { db in
            try db.execute(sql: "UPDATE run SET status = ? WHERE id = ?", arguments: [status.rawValue, runId])
        }
    }

    private func record(runId: ID, kind: String, _ object: [String: Any]) {
        store.write { db in
            var e = RunEvent(runId: runId, kind: kind, json: Self.json(object))
            try e.insert(db)
        }
    }

    /// Private folder for file secrets of one run, deleted when the run ends.
    private func secretFiles(runId: ID) -> URL {
        store.paths.root.appendingPathComponent("run-secrets/\(runId)", isDirectory: true)
    }

    /// Runs left "running" by a previous app session can't be continued.
    private func markOrphanedRuns() {
        // File secrets of runs interrupted by a crash or quit.
        try? FileManager.default.removeItem(at: store.paths.root.appendingPathComponent("run-secrets"))
        store.write { db in
            try db.execute(sql: """
                UPDATE run SET status = 'failed', error = 'The app was closed while the agent was running'
                WHERE status IN ('queued', 'running', 'waiting')
                """)
        }
    }

    // MARK: Schedule

    /// Recurring tasks with an agent run by themselves when they become due;
    /// then the due date moves to the next occurrence.
    func fireDueSchedules() {
        let now = Date()
        let context = FilterContext(now: now)
        let due: [TaskItem] = store.read { db in
            try TaskItem.filter(Column("isRecurring") == true && Column("isCompleted") == false
                                && Column("agentId") != nil && Column("dueDate") != nil)
                .fetchAll(db)
        } ?? []
        for var task in due where live[task.id] == nil {
            guard let at = task.dueAt, at <= now,
                  let string = task.dueString,
                  let current = try? DueParser.parse(string, context: context)
            else { continue }
            var anchor = current
            anchor.date = task.dueDate!
            anchor.time = task.dueTime
            do {
                let next = try DueParser.next(anchor, after: now, context: context)
                task.dueDate = next.date
                task.dueTime = next.time
                store.write { try task.update($0) }
            } catch {
                store.report(error)
                continue
            }
            start(task, trigger: "schedule")
        }
    }

    // MARK: Helpers

    private func initialPrompt(_ task: TaskItem, attachments: [TaskAttachment]) -> String {
        var text = "# Task\n\n\(task.content)"
        if !task.description.isEmpty { text += "\n\n\(task.description)" }
        let comments = store.read { db in
            try Comment.filter(Column("taskId") == task.id).order(Column("createdAt")).fetchAll(db)
        } ?? []
        if !comments.isEmpty {
            text += "\n\n## Comments\n" + comments.map { "- \($0.content)" }.joined(separator: "\n")
        }
        if let section = AgentWorkspace.attachmentsPrompt(attachments) {
            text += "\n\n" + section
        }
        return text
    }

    private func notify(taskId: ID, title: String) {
        guard Bundle.main.bundleIdentifier != nil, !NSApp.isActive else { return }
        let task = store.read { try TaskItem.fetchOne($0, key: taskId) } ?? nil
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = task?.content ?? ""
        content.userInfo = ["taskId": taskId]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: newID(), content: content, trigger: nil))
    }

    static func rule(for request: PermissionRequest) -> String {
        if request.toolName == "Bash", let cmd = request.input["command"]?.string {
            return "Bash(\(cmd))"
        }
        return request.toolName
    }

    static func json(_ object: [String: Any]) -> String {
        (try? String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)) ?? "{}"
    }
}
