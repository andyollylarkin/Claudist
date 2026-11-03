import ClaudistCore
import Foundation
import GRDB

/// A conversation whose Claude Code process is alive.
@MainActor
final class LiveChat: ObservableObject {
    let process: AgentProcess
    @Published var pending: [PermissionRequest] = []
    /// A turn is in progress.
    @Published var busy = true
    var sawInit = false
    var resumed = false
    var idleClose: DispatchWorkItem?

    init(process: AgentProcess) { self.process = process }
}

/// Runs the built-in assistant: one Claude Code process per active conversation, with
/// Claudist's own tools served over the stream-json control channel.
@MainActor
final class AssistantManager: ObservableObject {
    @Published private(set) var live: [ID: LiveChat] = [:]   // by chatId

    static let modelKey = "assistant.model"
    static let confirmKey = "assistant.confirmChanges"
    /// An idle process is closed after this; the next message resumes the session.
    private let idleTimeout: TimeInterval = 300

    private let store: AppStore
    private let runs: RunManager

    init(store: AppStore, runs: RunManager) {
        self.store = store
        self.runs = runs
        UserDefaults.standard.register(defaults: [Self.confirmKey: true])
    }

    func newChat() -> AssistantChat {
        let chat = AssistantChat()
        store.write { try chat.insert($0) }
        return chat
    }

    func delete(_ chatId: ID) {
        stop(chatId)
        live[chatId]?.process.terminate()
        live[chatId] = nil
        store.write { try $0.execute(sql: "DELETE FROM assistantChat WHERE id = ?", arguments: [chatId]) }
    }

    func send(_ chatId: ID, text: String, files: [URL] = []) {
        guard var chat = store.read({ try AssistantChat.fetchOne($0, key: chatId) }) ?? nil else { return }
        var shown = text
        if !files.isEmpty {
            shown += (shown.isEmpty ? "" : "\n\n") + files.map { "📎 \($0.lastPathComponent)" }.joined(separator: "\n")
        }
        record(chatId, "user/input", ["text": shown, "files": files.map(\.path)])
        if chat.title == "New chat" {
            let source = text.isEmpty ? files.map(\.lastPathComponent).joined(separator: ", ") : text
            let line = source.split(separator: "\n").first.map(String.init) ?? source
            chat.title = String(line.prefix(60))
        }
        chat.updatedAt = LocalDate.stamp(Date())
        store.write { try chat.update($0) }

        // Files are read now, as they are at the moment of sending.
        let content = ChatAttachments.content(text: text, files: files)
        if let current = live[chatId], current.process.isRunning {
            current.idleClose?.cancel()
            current.busy = true
            current.process.send(content: content)
            return
        }
        launch(chat, message: content)
    }

    func stop(_ chatId: ID) {
        guard let current = live[chatId], current.busy else { return }
        current.process.interrupt()
    }

    func answer(_ chatId: ID, _ request: PermissionRequest, allow: Bool) {
        guard let current = live[chatId] else { return }
        current.pending.removeAll { $0.id == request.id }
        current.process.respond(request, allow ? .allow : .deny("The user declined this change"))
        record(chatId, "permission/answer", ["request_id": request.id, "allow": allow])
    }

    // MARK: Process

    private func launch(_ chat: AssistantChat, message: [[String: Any]]) {
        let chatId = chat.id
        do {
            try FileManager.default.createDirectory(at: store.paths.assistant, withIntermediateDirectories: true)
            let defaults = UserDefaults.standard
            let args = AssistantSession.arguments(model: defaults.string(forKey: Self.modelKey),
                                                  confirmChanges: defaults.bool(forKey: Self.confirmKey),
                                                  resume: chat.sessionId)
            let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: args,
                                       cwd: store.paths.assistant, environment: ClaudeCLI.environment()) { [weak self] event in
                DispatchQueue.main.async { self?.handle(event, chatId: chatId, message: message) }
            }
            let current = LiveChat(process: process)
            current.resumed = chat.sessionId != nil
            live[chatId] = current
            try process.start()
            process.initialize(sdkMcpServers: [Delegation.serverName])
            process.send(content: message)
        } catch {
            live[chatId] = nil
            record(chatId, "stderr", ["text": error.localizedDescription])
        }
    }

    private func handle(_ event: AgentProcess.Event, chatId: ID, message: [[String: Any]]) {
        guard let current = live[chatId] else { return }
        switch event {
        case .message(let kind, let json):
            store.write { db in
                var e = AssistantEvent(chatId: chatId, kind: kind, json: json)
                try e.insert(db)
            }
            if kind == "system/init", let sid = JSONValue.parse(json)?["session_id"]?.string {
                current.sawInit = true
                store.write { try $0.execute(sql: "UPDATE assistantChat SET sessionId = ? WHERE id = ?", arguments: [sid, chatId]) }
            }
            if kind.hasPrefix("result") {
                current.busy = false
                let work = DispatchWorkItem { [weak current] in current?.process.closeInput() }
                current.idleClose = work
                DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
            }

        case .permission(let request):
            record(chatId, "permission", ["request_id": request.id, "tool": request.toolName, "input": request.inputJSON])
            if request.toolName.hasPrefix("mcp__\(Delegation.serverName)__") {
                current.pending.append(request)
            } else {
                current.process.respond(request, .deny("The assistant only uses Claudist's tools"))
                record(chatId, "permission/answer", ["request_id": request.id, "allow": false])
            }

        case .mcp(let requestId, _, let rpc):
            handleMCP(requestId: requestId, rpc: rpc, process: current.process)

        case .stderr(let text):
            record(chatId, "stderr", ["text": text])

        case .exited(let code):
            current.idleClose?.cancel()
            live[chatId] = nil
            if code != 0 && current.busy {
                if current.resumed && !current.sawInit {
                    // The saved session is gone (e.g. Claude Code cleaned it up): start a fresh one.
                    store.write { try $0.execute(sql: "UPDATE assistantChat SET sessionId = NULL WHERE id = ?", arguments: [chatId]) }
                    if let chat = store.read({ try AssistantChat.fetchOne($0, key: chatId) }) ?? nil {
                        launch(chat, message: [["type": "text", "text": "(The earlier part of this conversation could not be restored.)"]] + message)
                    }
                    return
                }
                record(chatId, "stderr", ["text": "Claude Code exited with code \(code)"])
            }
        }
    }

    private func handleMCP(requestId: String, rpc: JSONValue, process: AgentProcess) {
        let id = rpc["id"]
        switch rpc["method"]?.string {
        case "initialize":
            process.respondMCP(requestId: requestId, id: id, result: [
                "protocolVersion": rpc["params"]?["protocolVersion"]?.string ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": Delegation.serverName, "version": "1"],
            ])
        case "tools/list":
            process.respondMCP(requestId: requestId, id: id, result: ["tools": AssistantSession.toolDefinitions()])
        case "tools/call":
            let name = rpc["params"]?["name"]?.string ?? ""
            let args = rpc["params"]?["arguments"]
            func reply(_ text: String, error: Bool = false) {
                var result: [String: Any] = ["content": [["type": "text", "text": text]]]
                if error { result["isError"] = true }
                process.respondMCP(requestId: requestId, id: id, result: result)
            }
            guard let tool = AssistantTools.tool(name) else { return reply("Unknown tool \(name)", error: true) }
            if tool.appAction {
                let (text, failed) = appAction(name, args)
                return reply(text, error: failed)
            }
            let db = store.db.writer
            let workspace = store.workspace
            DispatchQueue.global(qos: .userInitiated).async {
                let answer: (String, Bool)
                do { answer = (try AssistantTools.call(name, args, db: db, workspace: workspace), false) }
                catch { answer = ("Error: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"), true) }
                DispatchQueue.main.async {
                    reply(answer.0, error: answer.1)
                    if tool.mutating {
                        self.store.reloadSkills()
                        for agent in self.store.agents { self.store.syncSkills(for: agent) }
                    }
                }
            }
        default:
            if id == nil {
                process.respondMCP(requestId: requestId, id: nil, result: nil)
            } else {
                process.respondMCP(requestId: requestId, id: id, result: nil, error: (-32601, "Method not found"))
            }
        }
    }

    /// Tools that drive runs go through the RunManager.
    private func appAction(_ name: String, _ args: JSONValue?) -> (String, Bool) {
        let taskId = args?["id"]?.string ?? args?["task_id"]?.string ?? ""
        guard let task = store.read({ try TaskItem.fetchOne($0, key: taskId) }) ?? nil else {
            return ("No task with id \(taskId); use find_tasks", true)
        }
        switch name {
        case "run_task":
            guard let agent = store.agent(task.agentId) else { return ("“\(task.content)” has no agent; assign one with update_task", true) }
            if runs.live[task.id] != nil && (args?["message"]?.string ?? "").isEmpty {
                return ("\(agent.name) is already working on “\(task.content)”", true)
            }
            if let message = args?["message"]?.string, !message.isEmpty {
                runs.send(task, text: message)
            } else {
                runs.start(task)
            }
            return runs.live[task.id] != nil
                ? ("Started \(agent.name) on “\(task.content)”. Check progress with list_runs / get_run.", false)
                : ("Could not start \(agent.name); see the app for the error", true)
        case "stop_task":
            guard runs.live[task.id] != nil else { return ("Nothing is running for “\(task.content)”", true) }
            runs.stop(taskId: task.id)
            return ("Stopping the agent on “\(task.content)”", false)
        case "reply_to_agent":
            let text = args?["text"]?.string ?? ""
            guard !text.isEmpty else { return ("Missing text", true) }
            guard task.agentId != nil else { return ("“\(task.content)” has no agent", true) }
            // Rights are granted by the user's own click, never through the assistant.
            if (store.read { try AccessRequests.pending($0, taskId: task.id) } ?? nil) != nil {
                return ("The agent on “\(task.content)” asked for access; only the user can decide that, in Needs you or in the task", true)
            }
            runs.send(task, text: text)
            return ("Answer sent; the agent continues on “\(task.content)”", false)
        default:
            return ("Unknown action \(name)", true)
        }
    }

    private func record(_ chatId: ID, _ kind: String, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        store.write { db in
            var e = AssistantEvent(chatId: chatId, kind: kind, json: String(decoding: data, as: UTF8.self))
            try e.insert(db)
        }
    }
}
