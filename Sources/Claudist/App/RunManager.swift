import ClaudistCore
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
    var sessionId: String?
    /// The process got end of input and will exit; nothing more can be sent to it.
    var inputClosed = false
    /// Claude Code's background tasks (background Bash, background sub-agents) still running:
    /// the process goes on after the turn ends and starts a new turn when one finishes.
    var backgroundTasks: [String] = []

    func closeInput() {
        inputClosed = true
        process.closeInput()
    }

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
    /// Databases each run may use (by runId).
    private var databasesByRun: [ID: [DatabaseGrant]] = [:]
    /// Which tasks each run may change through the task tools (by runId).
    private var scopesByRun: [ID: AssistantTools.AgentScope] = [:]
    /// One-off tasks started by the schedule in this session.
    private var scheduledOnce: Set<ID> = []
    /// Follow-up messages of resumed runs, to retry in a new conversation when the session is gone.
    private var followUps: [ID: String] = [:]
    private var lostSessions: Set<ID> = []
    /// Messages to resume a task with after its process exits (its permissions changed meanwhile).
    private var resumeAfterExit: [ID: String] = [:]
    /// Sub-agent calls waiting for an answer, by the sub-task id.
    private var pendingCalls: [ID: PendingCall] = [:]
    /// Isolation engine of each isolated run (by runId), to stop what it started.
    private var enginesByRun: [ID: any IsolationEngine] = [:]
    /// Tasks whose run waits for its isolation engine to get ready (e.g. an image build).
    @Published private(set) var preparing: Set<ID> = []

    private struct PendingCall {
        let parentTaskId: ID
        let requestId: String
        let rpcId: JSONValue?
        let agentName: String
    }

    init(store: AppStore) {
        self.store = store
        markOrphanedRuns()
        let engines = Isolation.engines(paths: store.paths, credentials: store.secretStore)
        DispatchQueue.global(qos: .utility).async {
            // Containers of runs from a previous session have nobody to talk to.
            for engine in engines { engine.cleanUpOrphans() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDueSchedules() }
        }
        Notifications.setUp(store: store)
    }

    var waitingCount: Int { live.values.filter { !$0.pending.isEmpty }.count }

    // MARK: Start / follow-up / stop

    /// Starts the task's agent. Without `message` the task itself becomes the prompt;
    /// with a message the last session of this task (or `session`) is resumed (dialog).
    /// `trigger`: "manual", "schedule" or "agent" (called by another agent).
    func start(_ task: TaskItem, message: String? = nil, trigger: String = "manual", session: String? = nil, fresh: Bool = false) {
        guard live[task.id] == nil, !preparing.contains(task.id) else { return }
        guard let agent = store.agent(task.agentId) else {
            store.errorMessage = "Assign an agent to this task first"
            return
        }
        guard var config = store.launchConfig(for: agent) else { return }
        config.taskId = task.id
        // Running the task again by hand supersedes an unanswered question.
        if trigger == "manual" && message == nil {
            store.write { try Attention.clear($0, taskId: task.id) }
            Notifications.clear(taskId: task.id)
        }
        config.attachments = store.read { try TaskAttachment.filter(Column("taskId") == task.id).order(Column("createdAt")).fetchAll($0) } ?? []
        config.databases = store.read { try UserDatabase.grants($0, agentId: agent.id, taskId: task.id) } ?? []
        config.extraAllow = store.read { try AccessRequests.taskRules($0, taskId: task.id) } ?? []

        var resume = message == nil || fresh ? nil : session ?? store.read { db in
            try String.fetchOne(db, sql: """
                SELECT sessionId FROM run WHERE taskId = ? AND sessionId IS NOT NULL
                ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [task.id])
        } ?? nil
        // The session may have been recorded on the host or in a container (the task's isolation can
        // change between replies): carry it to where this run looks, or start over with a recap.
        if let sid = resume {
            let cwd = URL(fileURLWithPath: agent.folderPath)
            let host = SessionFiles.hostConfigDir(environment: ClaudeCLI.environment())
            let engines = Isolation.engines(paths: store.paths, credentials: store.secretStore)
            let target = task.runOnHost ? host
                : engines.first { $0.id == Isolation.selected }?.claudeConfigDir(forCwd: cwd) ?? host
            let sources = [host] + engines.compactMap { $0.claudeConfigDir(forCwd: cwd) }
            if (try? SessionFiles.carry(sid, cwd: cwd, to: target, from: sources)) != true { resume = nil }
        }
        let prompt: String
        if let message, resume == nil {
            prompt = recap(task, attachments: config.attachments) + message
        } else {
            prompt = message ?? initialPrompt(task, attachments: config.attachments)
        }

        var run = Run(taskId: task.id, agentId: agent.id, trigger: trigger)
        run.status = .running
        if resume != nil, let message { followUps[run.id] = message }
        do {
            let settings = try store.workspace.prepare(config)
            let args = store.workspace.arguments(config, settingsURL: settings, resume: resume)
            let exe = try ClaudeCLI.executable()
            let secrets = config.secrets
            let (secretEnv, secretValues) = try Secrets.environment(secrets, store: store.secretStore,
                                                                    fileDir: secretFiles(runId: run.id))
            var environment = ClaudeCLI.environment().merging(secretEnv) { _, secret in secret }
                .merging(DatabaseAccess.environment(config.databases)) { current, _ in current }
            if !config.databases.isEmpty { databasesByRun[run.id] = config.databases }
            scopesByRun[run.id] = AssistantTools.AgentScope(agentId: agent.id, agentName: agent.name, delegates: config.delegates.map(\.id))
            if !config.delegates.isEmpty {
                // A sub-agent call blocks the tool until the other agent finishes.
                environment["MCP_TOOL_TIMEOUT"] = "86400000"
                delegatesByRun[run.id] = config.delegates
            }
            redactions[run.id] = secrets.compactMap { s in secretValues[s.name].flatMap { $0.count >= 4 ? (s.name, $0) : nil } }

            var spec = LaunchSpec(executable: exe, arguments: args, cwd: URL(fileURLWithPath: agent.folderPath),
                                  environment: environment,
                                  agentEnvironment: Array(secretEnv.keys) + Array(DatabaseAccess.environment(config.databases).keys)
                                      + (config.delegates.isEmpty ? [] : ["MCP_TOOL_TIMEOUT"]),
                                  mounts: [], runId: run.id)
            var engine: (any IsolationEngine)?
            let engineId = task.runOnHost ? Isolation.none : Isolation.selected
            if engineId != Isolation.none {
                guard let found = Isolation.engine(engineId, paths: store.paths, credentials: store.secretStore) else {
                    throw ClaudistError.invalid("Unknown isolation engine \(engineId). Choose one in Settings → Isolation.")
                }
                engine = found
                let secretDir = secretFiles(runId: run.id)
                spec.mounts = Isolation.mounts(config, settingsURL: settings, library: store.workspace.library,
                                               secretFiles: secretDir)
            }
            let ready = engine.map { $0.status() } ?? .ready
            if case .unavailable(let why) = ready {
                throw ClaudistError.invalid("\(engine!.title) isolation: \(why) Or switch isolation off in Settings → Isolation.")
            }
            if case .needsPreparation = ready { run.status = .queued }
            // What the run is given, for the task's audit.
            let access = RunAccess(config, isolation: engine?.title ?? "On this Mac")
            let accessJSON = (try? JSONEncoder().encode(access)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            try store.db.writer.write { db in
                try run.insert(db)
                var a = RunEvent(runId: run.id, kind: RunAccess.eventKind, json: accessJSON)
                try a.insert(db)
                var e = RunEvent(runId: run.id, kind: "user/input", json: Self.json(["text": prompt]))
                try e.insert(db)
            }
            let runId = run.id
            guard let engine else {
                if task.runOnHost && Isolation.selected != Isolation.none {
                    record(runId: runId, kind: "note", ["text": "Running on this Mac: isolation is off for this task"])
                }
                try launch(spec, runId: runId, taskId: task.id, prompt: prompt)
                return
            }
            enginesByRun[runId] = engine
            guard case .needsPreparation = ready else {
                try launch(engine.wrap(spec), runId: runId, taskId: task.id, prompt: prompt)
                return
            }
            // First isolated run: build the image (minutes) off the main thread, then start.
            preparing.insert(task.id)
            record(runId: runId, kind: "note", ["text": "Preparing \(engine.title) isolation…"])
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try engine.prepare { line in
                    DispatchQueue.main.async { self?.record(runId: runId, kind: "note", ["text": line]) }
                } }
                DispatchQueue.main.async {
                    guard let self else { return }
                    let cancelled = !self.preparing.contains(task.id)
                    self.preparing.remove(task.id)
                    do {
                        try result.get()
                        if cancelled {
                            self.finish(runId: runId, status: .cancelled, error: nil)
                            return
                        }
                        self.setStatus(runId: runId, .running)
                        try self.launch(engine.wrap(spec), runId: runId, taskId: task.id, prompt: prompt)
                    } catch {
                        self.live[task.id] = nil
                        self.cleanUp(runId: runId)
                        self.finish(runId: runId, status: .failed, error: error.localizedDescription)
                    }
                }
            }
        } catch {
            live[task.id] = nil
            cleanUp(runId: run.id)
            finish(runId: run.id, status: .failed, error: "\(error.localizedDescription)")
            store.report(error)
        }
    }

    /// Starts the (possibly wrapped) Claude Code process of a run and sends the prompt.
    private func launch(_ spec: LaunchSpec, runId: ID, taskId: ID, prompt: String) throws {
        let process = AgentProcess(executable: spec.executable, arguments: spec.arguments,
                                   cwd: spec.cwd, environment: spec.environment) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event, runId: runId, taskId: taskId) }
        }
        let liveRun = LiveRun(runId: runId, taskId: taskId, process: process)
        live[taskId] = liveRun
        try process.start()
        process.initialize(sdkMcpServers: [Delegation.serverName])
        process.send(prompt)
    }

    /// Per-run state that must not outlive the run.
    private func cleanUp(runId: ID) {
        redactions[runId] = nil
        delegatesByRun[runId] = nil
        databasesByRun[runId] = nil
        scopesByRun[runId] = nil
        try? FileManager.default.removeItem(at: secretFiles(runId: runId))
        if let engine = enginesByRun.removeValue(forKey: runId) {
            DispatchQueue.global(qos: .utility).async { engine.stop(runId: runId) }
        }
    }

    /// Chat input: goes to the running process, or resumes the session in a new run.
    /// `files` are attached to the task first; a running agent picks them up in a resumed process.
    func send(_ task: TaskItem, text: String, files: [URL] = [], session: String? = nil) {
        // A decision on an access request updates the rights first; the agent gets told what was decided.
        var text = text
        var rightsChanged = false
        do {
            if let message = try store.db.writer.write({ try AccessRequests.decide($0, taskId: task.id, answer: text) }) {
                text = message
                rightsChanged = true
            }
        } catch {
            store.report(error)
            return
        }
        // Attached paths are mounted and allowed when Claude Code starts.
        if !files.isEmpty {
            store.attach(files, to: task.id)
            text += (text.isEmpty ? "" : "\n\n") + "Attached to the task: " + files.map { "`\($0.standardizedFileURL.path)`" }.joined(separator: ", ")
            rightsChanged = true
        }
        // Any reply answers the agent's pending question.
        store.write { try Attention.clear($0, taskId: task.id) }
        Notifications.clear(taskId: task.id)
        if let liveRun = live[task.id], rightsChanged || liveRun.inputClosed {
            // Permissions are read when Claude Code starts, and a process past its input can't take
            // the message: resume in a new process once this one ends.
            resumeAfterExit[task.id] = text
            liveRun.closeInput()
            return
        }
        if let liveRun = live[task.id], session == nil || liveRun.sessionId == session {
            liveRun.process.send(text)
            record(runId: liveRun.runId, kind: "user/input", ["text": text])
        } else {
            start(task, message: text, session: session)
        }
    }

    func stop(taskId: ID) {
        if preparing.contains(taskId) {
            // The run starts after the engine is ready; dropping the mark cancels it.
            preparing.remove(taskId)
            return
        }
        guard let liveRun = live[taskId] else { return }
        // Sub-agents working for this task stop too.
        for (child, call) in pendingCalls where call.parentTaskId == taskId { stop(taskId: child) }
        stopping.insert(liveRun.runId)
        resumeAfterExit[taskId] = nil
        liveRun.process.interrupt()
        liveRun.closeInput()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { liveRun.process.terminate() }
    }

    func respond(taskId: ID, _ request: PermissionRequest, allow: Bool, always: Bool = false) {
        guard let liveRun = live[taskId] else { return }
        liveRun.process.respond(request, allow ? .allow : .deny("The user denied this action"))
        liveRun.pending.removeAll { $0.id == request.id }
        if liveRun.pending.isEmpty { Notifications.clear(taskId: taskId) }
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
                live[taskId]?.sessionId = sid
                store.write { db in
                    try db.execute(sql: "UPDATE run SET sessionId = ? WHERE id = ?", arguments: [sid, runId])
                }
            }
            if kind == "system/background_tasks_changed", let liveRun = live[taskId] {
                liveRun.backgroundTasks = (JSONValue.parse(json)?["tasks"]?.array ?? [])
                    .map { $0["description"]?.string ?? $0["task_type"]?.string ?? "task" }
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
                if let liveRun = live[taskId], !liveRun.backgroundTasks.isEmpty, !stopping.contains(runId) {
                    // The turn ended but work goes on in the background; the agent continues by itself
                    // when it finishes. The run stays open and still takes messages.
                    setStatus(runId: runId, .running)
                    record(runId: runId, kind: "note", ["text": "Working in the background: "
                        + liveRun.backgroundTasks.map { String($0.prefix(120)) }.joined(separator: "; ")])
                    return
                }
                let status: RunStatus = stopping.contains(runId) ? .cancelled : (ok ? .done : .failed)
                finish(runId: runId, status: status, error: ok ? nil : v?["result"]?.string)
                live[taskId]?.closeInput()
                if !waitForUser(childTaskId: taskId) {
                    answerCall(childTaskId: taskId, ok: ok, text: v?["result"]?.string ?? "")
                }
            }

        case .permission(let request):
            live[taskId]?.pending.append(request)
            record(runId: runId, kind: "permission", ["request_id": request.id, "tool": request.toolName,
                                                       "description": redact(request.description ?? "", runId: runId),
                                                       "input": redact(request.inputJSON, runId: runId)])
            setStatus(runId: runId, .waiting)
            notifyNeedsYou(taskId: taskId, title: "\(agentName(taskId)) needs your approval",
                           body: Self.describe(request, redact: { self.redact($0, runId: runId) }))

        case .mcp(let requestId, let server, let message):
            handleMCP(requestId: requestId, server: server, message: message, runId: runId, taskId: taskId)

        case .stderr(let text):
            record(runId: runId, kind: "stderr", ["text": redact(text, runId: runId)])
            if text.contains("No conversation found with session ID") { lostSessions.insert(runId) }

        case .exited(let code):
            let current = store.read { try Run.fetchOne($0, key: runId) } ?? nil
            if let current, [.running, .waiting, .queued].contains(current.status) {
                let status: RunStatus = stopping.contains(runId) ? .cancelled : (code == 0 ? .done : .failed)
                finish(runId: runId, status: status, error: code == 0 ? nil : "claude exited with code \(code)")
            }
            if !waitForUser(childTaskId: taskId) {
                answerCall(childTaskId: taskId, ok: false, text: "The agent stopped without an answer.")
            }
            // Sub-agents can no longer answer a caller that is gone.
            for (child, call) in pendingCalls where call.parentTaskId == taskId { pendingCalls[child] = nil }
            stopping.remove(runId)
            cleanUp(runId: runId)
            live[taskId] = nil
            if lostSessions.remove(runId) != nil, let message = followUps[runId],
               let task = store.read({ try TaskItem.fetchOne($0, key: taskId) }) ?? nil {
                // Claude Code couldn't find the conversation: go on in a new one with a recap.
                record(runId: runId, kind: "note", ["text": "The earlier conversation could not be restored; continuing in a new one with a recap"])
                followUps[runId] = nil
                start(task, message: message, trigger: "manual", fresh: true)
                return
            }
            followUps[runId] = nil
            if let message = resumeAfterExit.removeValue(forKey: taskId),
               let task = store.read({ try TaskItem.fetchOne($0, key: taskId) }) ?? nil {
                start(task, message: message)
                return
            }
            // Permission prompts died with the process; a question (ask_user) still waits for an answer.
            if (store.read { try TaskItem.fetchOne($0, key: taskId) } ?? nil)?.attention == nil {
                Notifications.clear(taskId: taskId)
            }
        }
    }

    // MARK: Sub-agents

    private func notesAccess(runId: ID, taskId: ID) -> StorageAccess? {
        let agentId = scopesByRun[runId]?.agentId ?? (store.read { try TaskItem.fetchOne($0, key: taskId) } ?? nil)?.agentId
        return store.agent(agentId)?.notesAccess
    }

    private func integrations(runId: ID, taskId: ID) -> [String] {
        let agentId = scopesByRun[runId]?.agentId ?? (store.read { try TaskItem.fetchOne($0, key: taskId) } ?? nil)?.agentId
        guard let agentId else { return [] }
        return store.read { try Integrations.granted($0, agentId: agentId) } ?? []
    }

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
            var tools = [Attention.toolDefinition(), AccessRequests.toolDefinition()]
            if let delegates = delegatesByRun[runId], !delegates.isEmpty { tools.append(Delegation.toolDefinition(delegates)) }
            if let grants = databasesByRun[runId] {
                tools += DatabaseAccess.toolDefinitions(grants)
                tools += DashboardTools.toolDefinitions(grants)
            }
            tools += AssistantTools.agentToolDefinitions()
            tools += NotesTools.toolDefinitions(notesAccess(runId: runId, taskId: taskId))
            tools += Integrations.toolDefinitions(integrations(runId: runId, taskId: taskId))
            process.respondMCP(requestId: requestId, id: id, result: ["tools": tools])
        case "tools/call" where message["params"]?["name"]?.string == Attention.toolName:
            let args = message["params"]?["arguments"]
            let question = args?["question"]?.string ?? ""
            let options = (args?["options"]?.array ?? []).compactMap(\.string)
            store.write { try Attention.mark($0, taskId: taskId, question: question, options: options) }
            record(runId: runId, kind: "ask", ["question": question, "options": options])
            notifyNeedsYou(taskId: taskId, title: "\(agentName(taskId)) asks", body: question)
            process.respondMCP(requestId: requestId, id: id, result: ["content": [["type": "text", "text":
                "Posted to the user's Needs you list. Stop now and end your turn with a short summary; the answer will arrive as the next message."]]])
        case "tools/call" where AssistantTools.agentToolNames.contains(message["params"]?["name"]?.string ?? ""):
            let tool = message["params"]?["name"]?.string ?? ""
            let args = message["params"]?["arguments"]
            let scope = scopesByRun[runId]
            let db = store.db.writer
            let workspace = store.workspace
            DispatchQueue.global(qos: .userInitiated).async {
                var result: [String: Any]
                do {
                    guard let scope else { throw ClaudistError.invalid("This run has no task scope") }
                    let text = try AssistantTools.call(tool, args, db: db, workspace: workspace, scope: scope)
                    result = ["content": [["type": "text", "text": text]]]
                } catch {
                    result = ["content": [["type": "text", "text": "Error: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)")]],
                              "isError": true]
                }
                process.respondMCP(requestId: requestId, id: id, result: result)
            }
        case "tools/call" where message["params"]?["name"]?.string == AccessRequests.toolName:
            let args = message["params"]?["arguments"]
            var reply = "Posted to the user's Needs you list. Stop now and end your turn with a short summary; you'll be resumed after the user decides."
            var failed = false
            do {
                guard let task = store.read({ try TaskItem.fetchOne($0, key: taskId) }) ?? nil,
                      let agent = store.agent(task.agentId) else { throw ClaudistError.invalid("No agent on this task") }
                let request = try store.db.writer.write { try AccessRequests.create($0, taskId: taskId, agent: agent, arguments: args) }
                record(runId: runId, kind: "ask", ["question": AccessRequests.question(request, agent: agent.name),
                                                   "options": [AccessRequests.allowTask, AccessRequests.allowAgent(agent.name), AccessRequests.deny]])
                notifyNeedsYou(taskId: taskId, title: "\(agent.name) asks for access", body: AccessRequests.question(request, agent: agent.name))
            } catch {
                reply = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                failed = true
            }
            var result: [String: Any] = ["content": [["type": "text", "text": reply]]]
            if failed { result["isError"] = true }
            process.respondMCP(requestId: requestId, id: id, result: result)
        case "tools/call" where DashboardTools.toolNames.contains(message["params"]?["name"]?.string ?? ""):
            let tool = message["params"]?["name"]?.string ?? ""
            let args = message["params"]?["arguments"]
            let grants = databasesByRun[runId] ?? []
            let author = "agent: " + (scopesByRun[runId]?.agentName ?? agentName(taskId))
            let db = store.db.writer
            DispatchQueue.global(qos: .userInitiated).async {
                let (text, isError) = DashboardTools.call(tool, arguments: args, db: db, grants: grants, author: author)
                var result: [String: Any] = ["content": [["type": "text", "text": text]]]
                if isError { result["isError"] = true }
                process.respondMCP(requestId: requestId, id: id, result: result)
            }
        case "tools/call" where Telegram.toolNames.contains(message["params"]?["name"]?.string ?? ""):
            let tool = message["params"]?["name"]?.string ?? ""
            let args = message["params"]?["arguments"]
            // Checked at call time: the user may turn the integration off or take it from the agent.
            guard integrations(runId: runId, taskId: taskId).contains(Telegram.id) else {
                process.respondMCP(requestId: requestId, id: id, result: ["content": [["type": "text", "text": "Telegram is not available to this agent"]], "isError": true])
                return
            }
            let telegram = store.telegram
            Task {
                let (text, isError) = await telegram.call(tool, arguments: args)
                var result: [String: Any] = ["content": [["type": "text", "text": text]]]
                if isError { result["isError"] = true }
                process.respondMCP(requestId: requestId, id: id, result: result)
            }
        case "tools/call" where NotesTools.toolNames.contains(message["params"]?["name"]?.string ?? ""):
            let tool = message["params"]?["name"]?.string ?? ""
            let args = message["params"]?["arguments"]
            // Read at call time: the user may change the agent's access while it runs.
            let access = notesAccess(runId: runId, taskId: taskId)
            let vault = NotesVault.configured(paths: store.paths)
            DispatchQueue.global(qos: .userInitiated).async {
                let (text, isError) = NotesTools.call(tool, arguments: args, vault: vault, access: access)
                var result: [String: Any] = ["content": [["type": "text", "text": text]]]
                if isError { result["isError"] = true }
                process.respondMCP(requestId: requestId, id: id, result: result)
            }
        case "tools/call" where DatabaseAccess.toolNames.contains(message["params"]?["name"]?.string ?? ""):
            let tool = message["params"]?["name"]?.string ?? ""
            let args = message["params"]?["arguments"]
            let grants = databasesByRun[runId] ?? []
            // Queries may take a while; keep them off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let (text, isError) = DatabaseAccess.call(tool, arguments: args, grants: grants)
                var result: [String: Any] = ["content": [["type": "text", "text": text]]]
                if isError { result["isError"] = true }
                process.respondMCP(requestId: requestId, id: id, result: result)
            }
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
        // Same isolation as the caller: a containerized agent can't get work done on the host, and back.
        child.runOnHost = parent.runOnHost
        child.source = "agent"
        do {
            try store.db.writer.write { db in
                child.childOrder = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE parentId = ?", arguments: [parent.id]) ?? 0) + 1
                try child.insert(db)
                // The sub-agent sees the same host files and databases as the task it works for.
                for var a in try TaskAttachment.filter(Column("taskId") == parent.id).fetchAll(db) {
                    a.id = newID()
                    a.taskId = child.id
                    try a.insert(db)
                }
                for var link in try TaskDatabase.filter(Column("taskId") == parent.id).fetchAll(db) {
                    link.taskId = child.id
                    try link.insert(db)
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
            fail("Could not start \(target.name). Check its settings in Claudist.")
        }
    }

    /// A sub-agent that asked the user a question ends its turn but hasn't answered its caller yet:
    /// the caller keeps waiting (its tool call stays open) until the sub-agent finishes after the answer.
    private func waitForUser(childTaskId: ID) -> Bool {
        guard let call = pendingCalls[childTaskId],
              let child = store.read({ try TaskItem.fetchOne($0, key: childTaskId) }) ?? nil,
              let question = child.attention else { return false }
        if let parentRun = live[call.parentTaskId] {
            setStatus(runId: parentRun.runId, .waiting)
            record(runId: parentRun.runId, kind: "note",
                   ["text": "Waiting for \(call.agentName): it asked you “\(question)” in “\(child.content)”"])
        }
        return true
    }

    /// Drops an agent's question without an answer. A caller waiting on that sub-agent gets told so.
    func dismissQuestion(taskId: ID) {
        store.write { try Attention.clear($0, taskId: taskId) }
        Notifications.clear(taskId: taskId)
        if live[taskId] == nil, pendingCalls[taskId] != nil {
            answerCall(childTaskId: taskId, ok: false,
                       text: "The user dismissed the sub-agent's question without answering; its task is unfinished. Continue without it or ask the user yourself.")
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
        guard let parentRun = live[call.parentTaskId] else { return }
        let parent = parentRun.process
        if parentRun.pending.isEmpty { setStatus(runId: parentRun.runId, .running) }
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
        // Finished while the user is looking at the task: already seen.
        if NSApp?.isActive == true, let taskId = (store.read({ try Run.fetchOne($0, key: runId) }) ?? nil)?.taskId,
           store.selectedTaskId == taskId {
            store.markReviewed(taskId)
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

    /// Tasks with an agent run by themselves when they become due: recurring ones every time
    /// (the due date moves to the next occurrence), one-off ones once.
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

        // One-off tasks with an agent run once when they come due (a date alone: from the start of that day).
        // A task that has ever run is left alone, so moving its date doesn't restart it; one that came due
        // while the app was closed starts on the next check.
        let oneOff: [TaskItem] = store.read { db in
            try TaskItem.fetchAll(db, sql: """
                SELECT * FROM task t
                WHERE t.isRecurring = 0 AND t.isCompleted = 0 AND t.agentId IS NOT NULL AND t.dueDate IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM run r WHERE r.taskId = t.id)
                """)
        } ?? []
        for task in oneOff where live[task.id] == nil && !scheduledOnce.contains(task.id) {
            guard let at = task.dueAt, at <= now else { continue }
            // A start that fails before its run is recorded (e.g. isolation unavailable) isn't retried every check.
            scheduledOnce.insert(task.id)
            start(task, trigger: "schedule")
        }
    }

    // MARK: Helpers

    /// A follow-up whose conversation can't be resumed: the task and what was said so far, then the reply.
    private func recap(_ task: TaskItem, attachments: [TaskAttachment]) -> String {
        let lines: [String] = store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.kind, e.json FROM runEvent e JOIN run r ON r.id = e.runId
                WHERE r.taskId = ? AND (e.kind = 'user/input' OR e.kind LIKE 'result%')
                ORDER BY r.startedAt, e.seq
                """, arguments: [task.id]).compactMap { row -> String? in
                let kind: String = row[0]
                let v = JSONValue.parse(row[1])
                let text = (kind == "user/input" ? v?["text"]?.string : v?["result"]?.string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { return nil }
                return (kind == "user/input" ? "USER: " : "YOU: ") + String(text.prefix(2500))
            }
        } ?? []
        var text = initialPrompt(task, attachments: attachments)
        // The first input is the task itself, already above.
        let history = lines.dropFirst().suffix(16)
        if !history.isEmpty {
            text += "\n\n# Earlier conversation on this task\nThe previous session could not be restored; this is what was said "
                + "(long parts shortened). Check the current state of files before relying on it.\n\n" + history.joined(separator: "\n\n")
        }
        return text + "\n\n# New message from the user\n\n"
    }

    private func initialPrompt(_ task: TaskItem, attachments: [TaskAttachment]) -> String {
        var text = "# Task\n\n\(task.content)"
        if !task.description.isEmpty { text += "\n\n\(task.description)" }
        let comments = store.read { db in
            try Comment.filter(Column("taskId") == task.id).order(Column("createdAt")).fetchAll(db)
        } ?? []
        if !comments.isEmpty {
            text += "\n\n" + Comment.promptSection(comments)
        }
        if let section = AgentWorkspace.attachmentsPrompt(attachments) {
            text += "\n\n" + section
        }
        return text
    }

    /// The only system notification: an agent waits for the user (a question or a permission).
    /// Skipped when the user is already looking at that task.
    private func notifyNeedsYou(taskId: ID, title: String, body: String) {
        if NSApp.isActive && store.selectedTaskId == taskId { return }
        let task = store.read { try TaskItem.fetchOne($0, key: taskId) } ?? nil
        Notifications.post(taskId: taskId, title: title, subtitle: task?.content ?? "", body: body)
    }

    private func agentName(_ taskId: ID) -> String {
        let task = store.read { try TaskItem.fetchOne($0, key: taskId) } ?? nil
        return store.agent(task?.agentId)?.name ?? "An agent"
    }

    /// One line about what a permission request would do, e.g. the command or the file.
    static func describe(_ request: PermissionRequest, redact: (String) -> String) -> String {
        let input = request.input
        let detail = input["command"]?.string ?? input["file_path"]?.string ?? input["url"]?.string
            ?? input["path"]?.string ?? request.description ?? ""
        let tool = request.toolName.replacingOccurrences(of: "mcp__\(Delegation.serverName)__", with: "")
        return redact(detail.isEmpty ? tool : "\(tool): \(detail)")
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
