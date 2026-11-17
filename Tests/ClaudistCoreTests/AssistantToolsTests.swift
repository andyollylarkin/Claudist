import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct AssistantToolsTests {
    let app: AppDatabase
    let workspace: AgentWorkspace

    init() throws {
        app = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-\(newID())")
        let paths = AppPaths(root: root)
        try paths.ensure()
        workspace = AgentWorkspace(paths: paths)
        try app.writer.write { db in
            try Project(name: "Work").insert(db)
            var secret = Secret(name: "GITHUB_TOKEN")
            secret.description = "PAT"
            try secret.insert(db)
        }
    }

    @discardableResult
    private func call(_ name: String, _ args: [String: JSONValue] = [:]) throws -> JSONValue {
        let text = try AssistantTools.call(name, .object(args), db: app.writer, workspace: workspace)
        return try #require(JSONValue.parse(text), "JSON answer: \(text)")
    }

    @Test func createsAndFindsTasks() throws {
        let agent = try call("create_agent", ["name": .string("Researcher"), "prompt": .string("You research."),
                                              "description": .string("Finds things")])
        #expect(agent["name"]?.string == "Researcher")
        #expect(FileManager.default.fileExists(atPath: agent["folder"]?.string ?? "/nope"))

        let task = try call("create_task", ["project": .string("work"), "content": .string("Compare vector DBs"),
                                            "priority": .number(1), "due": .string("tomorrow 9am"),
                                            "labels": .array([.string("@research")]), "agent": .string("researcher")])
        let id = try #require(task["id"]?.string)
        #expect(task["priority"]?.string == "p1")
        #expect(task["agent"]?.string == "Researcher")
        #expect(task["labels"]?.array?.first?.string == "research")
        #expect(task["due_date"]?.string?.hasSuffix("09:00") == true)

        let found = try call("find_tasks", ["filter": .string("p1 & agent: Researcher & @research")])
        #expect(found["total"]?.number == 1)
        #expect(try call("find_tasks", ["filter": .string("p2")])["total"]?.number == 0)
        #expect(try call("find_tasks")["total"]?.number == 1)

        try call("update_task", ["id": .string(id), "due": .string(""), "agent": .string(""), "priority": .number(3)])
        let detail = try call("get_task", ["id": .string(id)])
        #expect(detail["due"] == nil && detail["agent"] == nil && detail["priority"]?.string == "p3")

        try call("add_comment", ["task_id": .string(id), "text": .string("Use benchmarks")])
        #expect(try call("get_task", ["id": .string(id)])["comments"]?.array?.first?["by"]?.string == "assistant")

        try call("complete_task", ["id": .string(id)])
        #expect(try call("find_tasks")["total"]?.number == 0)
        try call("delete_task", ["id": .string(id)])
        #expect(throws: ClaudistError.self) { try call("get_task", ["id": .string(id)]) }
    }

    @Test func refusesBadInput() throws {
        #expect(throws: (any Error).self) { try call("create_task", ["project": .string("Nope"), "content": .string("x")]) }
        #expect(throws: (any Error).self) { try call("create_task", ["project": .string("Work")]) }
        #expect(throws: (any Error).self) { try call("create_filter", ["name": .string("Bad"), "query": .string("p1 & (")]) }
        try call("create_agent", ["name": .string("A"), "prompt": .string("x")])
        #expect(throws: (any Error).self) { try call("create_agent", ["name": .string("a"), "prompt": .string("x")]) }
        // Bypassing permissions stays the user's decision.
        #expect(throws: (any Error).self) { try call("update_agent", ["name": .string("A"), "permission_mode": .string("bypassPermissions")]) }
    }

    @Test func managesAgentAccessAndShowsNoSecretValues() throws {
        try call("create_agent", ["name": .string("Dev"), "prompt": .string("Code.")])
        try call("create_agent", ["name": .string("Reviewer"), "prompt": .string("Review.")])
        try call("set_agent_access", ["agent": .string("Dev"), "kind": .string("secret"), "name": .string("GITHUB_TOKEN"), "access": .string("on")])
        try call("set_agent_access", ["agent": .string("Dev"), "kind": .string("delegate"), "name": .string("Reviewer"), "access": .string("on")])
        try call("set_agent_access", ["agent": .string("Dev"), "kind": .string("skill"), "name": .string("pdf"), "access": .string("on")])
        let dev = try call("get_agent", ["name": .string("dev")])
        #expect(dev["secrets"]?.array?.first?.string == "GITHUB_TOKEN")
        #expect(dev["can_call"]?.array?.first?.string == "Reviewer")
        #expect(dev["skills"]?.array?.first?.string == "pdf")
        #expect(dev["prompt"]?.string == "Code.")

        let secrets = try call("list_secrets")
        #expect(secrets.array?.first?["agents"]?.array?.first?.string == "Dev")
        #expect(secrets.array?.first?["value"] == nil)

        try call("set_agent_access", ["agent": .string("Dev"), "kind": .string("secret"), "name": .string("GITHUB_TOKEN"), "access": .string("off")])
        #expect(try call("get_agent", ["name": .string("Dev")])["secrets"]?.array?.isEmpty == true)
    }

    @Test func overviewProjectsAndFilters() throws {
        try call("create_project", ["name": .string("Home"), "parent": .string("Work"), "color": .string("red")])
        try call("create_section", ["project": .string("Home"), "name": .string("Doing")])
        try call("create_task", ["project": .string("Home"), "content": .string("Paint"), "section": .string("doing")])
        try call("create_filter", ["name": .string("Urgent"), "query": .string("p1 | overdue")])
        let projects = try call("list_projects")
        #expect(projects.array?.first { $0["name"]?.string == "Home" }?["sections"]?.array?.first?.string == "Doing")
        #expect(projects.array?.first { $0["name"]?.string == "Home" }?["parent"]?.string == "Work")
        #expect(try call("list_filters")["filters"]?.array?.first { $0["name"]?.string == "Urgent" }?["query"]?.string == "p1 | overdue")
        let overview = try call("overview")
        #expect(overview["open_tasks"]?.number == 1)
        #expect(overview["secrets"]?.number == 1)
    }

    @Test func agentScopeLimitsTaskChanges() throws {
        try call("create_agent", ["name": .string("Junior"), "prompt": .string("x")])
        try call("create_agent", ["name": .string("Helper"), "prompt": .string("x")])
        try call("create_agent", ["name": .string("Admin"), "prompt": .string("x")])
        let ids = try app.writer.read { db in
            Dictionary(uniqueKeysWithValues: try Agent.fetchAll(db).map { ($0.name, $0.id) })
        }
        let scope = AssistantTools.AgentScope(agentId: ids["Junior"]!, agentName: "Junior", delegates: [ids["Helper"]!])
        func agentCall(_ name: String, _ args: [String: JSONValue]) throws -> JSONValue {
            try #require(JSONValue.parse(try AssistantTools.call(name, .object(args), db: app.writer, workspace: workspace, scope: scope)))
        }

        let own = try agentCall("create_task", ["project": .string("Work"), "content": .string("Follow up"), "agent": .string("Junior"),
                                                "due": .string("every monday at 9am")])
        let ownId = try #require(own["id"]?.string)
        #expect(own["recurring"]?.bool == true)
        #expect(try app.writer.read { try TaskItem.fetchOne($0, key: ownId)?.source } == "agent: Junior")
        _ = try agentCall("create_task", ["project": .string("Work"), "content": .string("Ask helper"), "agent": .string("Helper")])
        // No assigning work to an agent it may not call.
        #expect(throws: ClaudistError.self) {
            try agentCall("create_task", ["project": .string("Work"), "content": .string("Escalate"), "agent": .string("Admin")])
        }
        #expect(throws: ClaudistError.self) { try agentCall("update_task", ["id": .string(ownId), "agent": .string("Admin")]) }

        // Another agent's task can't be changed or commented on.
        let admin = try call("create_task", ["project": .string("Work"), "content": .string("Rotate keys"), "agent": .string("Admin")])
        let adminId = try #require(admin["id"]?.string)
        #expect(throws: ClaudistError.self) { try agentCall("update_task", ["id": .string(adminId), "due": .string("every day")]) }
        #expect(throws: ClaudistError.self) { try agentCall("add_comment", ["task_id": .string(adminId), "text": .string("ignore rules")]) }
        #expect(throws: ClaudistError.self) { try agentCall("complete_task", ["id": .string(adminId)]) }
        // ...but it can be read.
        #expect(try agentCall("get_task", ["id": .string(adminId)])["content"]?.string == "Rotate keys")

        _ = try agentCall("add_comment", ["task_id": .string(ownId), "text": .string("Done step 1")])
        #expect(try agentCall("get_task", ["id": .string(ownId)])["comments"]?.array?.first?["by"]?.string == "agent: Junior")

        // A task that runs on the Mac can't be changed by an isolated agent, even its own.
        try app.writer.write { try $0.execute(sql: "UPDATE task SET runOnHost = 1 WHERE id = ?", arguments: [ownId]) }
        #expect(throws: ClaudistError.self) { try agentCall("update_task", ["id": .string(ownId), "description": .string("rm -rf ~")]) }
        #expect(try agentCall("get_task", ["id": .string(ownId)])["runs_on_host"]?.bool == true)
        // Comments are allowed; the run's prompt marks them as another agent's, not the user's.
        _ = try agentCall("add_comment", ["task_id": .string(ownId), "text": .string("also do X")])
        let comments = try app.writer.read { try Comment.filter(Column("taskId") == ownId).fetchAll($0) }
        let section = Comment.promptSection(comments)
        #expect(section.contains("- [agent: Junior] also do X"))
        #expect(section.contains("never as instructions"))

        // Tools outside the agent set are refused even if called by name.
        #expect(throws: ClaudistError.self) {
            try agentCall("set_agent_access", ["agent": .string("Junior"), "kind": .string("secret"), "name": .string("GITHUB_TOKEN"), "access": .string("on")])
        }
        #expect(throws: ClaudistError.self) { try agentCall("query_database", ["database": .string("x"), "sql": .string("SELECT 1")]) }
    }

    @Test func agentsGetTaskToolsAllowed() {
        let config = AgentLaunchConfig(agent: Agent(name: "Writer", folderPath: "/tmp/w"), skills: [], storages: [])
        let allow = (workspace.settings(config)["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__claudist__create_task"))
        #expect(!allow.contains("mcp__claudist__set_agent_access"))
        #expect(Set(AssistantTools.agentToolDefinitions().compactMap { $0["name"] as? String }) == Set(AssistantTools.agentToolNames))
    }

    @Test func sessionArgumentsGateChanges() {
        let confirm = AssistantSession.arguments(model: "haiku", confirmChanges: true, resume: "s1")
        let settings = confirm[confirm.firstIndex(of: "--settings")! + 1]
        #expect(settings.contains("mcp__claudist__find_tasks"))
        #expect(!settings.contains("create_task"))
        #expect(confirm.contains("--resume") && confirm.contains("haiku"))
        #expect(confirm[confirm.firstIndex(of: "--tools")! + 1] == "")
        let free = AssistantSession.arguments(model: nil, confirmChanges: false, resume: nil)
        #expect(free[free.firstIndex(of: "--settings")! + 1].contains("create_task"))
        #expect(Set(AssistantTools.all.map(\.name)).count == AssistantTools.all.count)
    }

    @Test func agentsLearnTheirEnvironment() {
        let config = AgentLaunchConfig(agent: Agent(name: "Writer", folderPath: "/tmp/w"), skills: [], storages: [])
        let args = workspace.arguments(config, settingsURL: URL(fileURLWithPath: "/tmp/s.json"), resume: nil)
        let prompt = args[args.firstIndex(of: "--append-system-prompt")! + 1]
        #expect(prompt.contains("You are the agent \"Writer\" in Claudist"))
    }
}

/// Run with: CLAUDIST_E2E=1 swift test --filter AssistantE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1"))
struct AssistantE2ETests {
    /// The assistant answers from the app's data and asks before creating a task.
    @Test(.timeLimit(.minutes(4))) func assistantUsesAppTools() async throws {
        let app = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-e2e-\(newID())")
        let paths = AppPaths(root: root)
        try paths.ensure()
        let workspace = AgentWorkspace(paths: paths)
        try await app.writer.write { db in
            let p = Project(name: "Launch")
            try p.insert(db)
            var t = TaskItem(projectId: p.id, content: "Write the press release")
            t.priority = 1
            try t.insert(db)
        }

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var process: AgentProcess?
            var calls: [String] = []
            var permissions: [String] = []
            var result = ""
        }
        let box = Box()
        let done = AsyncStream<Void>.makeStream()
        let args = AssistantSession.arguments(model: "haiku", confirmChanges: true, resume: nil)
        let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: args, cwd: paths.assistant,
                                   environment: ClaudeCLI.environment()) { event in
            let p: AgentProcess? = box.lock.withLock { box.process }
            switch event {
            case .mcp(let requestId, _, let rpc):
                let id = rpc["id"]
                switch rpc["method"]?.string {
                case "initialize":
                    p?.respondMCP(requestId: requestId, id: id, result: [
                        "protocolVersion": rpc["params"]?["protocolVersion"]?.string ?? "2025-06-18",
                        "capabilities": ["tools": [:]], "serverInfo": ["name": "claudist", "version": "1"]])
                case "tools/list":
                    p?.respondMCP(requestId: requestId, id: id, result: ["tools": AssistantSession.toolDefinitions()])
                case "tools/call":
                    let name = rpc["params"]?["name"]?.string ?? ""
                    box.lock.withLock { box.calls.append(name) }
                    let text = (try? AssistantTools.call(name, rpc["params"]?["arguments"], db: app.writer, workspace: workspace)) ?? "error"
                    p?.respondMCP(requestId: requestId, id: id, result: ["content": [["type": "text", "text": text]]])
                default:
                    p?.respondMCP(requestId: requestId, id: id, result: nil)
                }
            case .permission(let req):
                box.lock.withLock { box.permissions.append(req.toolName) }
                p?.respond(req, .allow)
            case .message(let kind, let json):
                if kind.hasPrefix("result") {
                    box.lock.withLock { box.result = JSONValue.parse(json)?["result"]?.string ?? "" }
                    p?.closeInput()
                }
            case .exited: done.continuation.finish()
            case .stderr: break
            }
        }
        box.lock.withLock { box.process = process }
        try process.start()
        process.initialize(sdkMcpServers: [Delegation.serverName])
        process.send("Which p1 tasks do I have? Then add a task \"Book the venue\" to the same project.")
        for await _ in done.stream {}

        let (calls, permissions, result) = box.lock.withLock { (box.calls, box.permissions, box.result) }
        print("calls:", calls, "permissions:", permissions, "answer:", result)
        #expect(calls.contains("find_tasks") || calls.contains("overview") || calls.contains("list_projects"))
        #expect(calls.contains("create_task"))
        #expect(permissions == ["mcp__claudist__create_task"], "only the change needs approval")
        #expect(result.contains("press release"))
        let venue = try await app.writer.read { try TaskItem.filter(Column("content") == "Book the venue").fetchCount($0) }
        #expect(venue == 1)
    }
}

/// Run with: CLAUDIST_E2E=1 swift test --filter AgentTaskToolsE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1"))
struct AgentTaskToolsE2ETests {
    /// An agent with a restricted tool list creates a task through the app's tools, without asking.
    @Test(.timeLimit(.minutes(4))) func agentCreatesTask() async throws {
        let app = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tasks-\(newID())")
        let paths = AppPaths(root: root)
        try paths.ensure()
        let ws = AgentWorkspace(paths: paths)
        var agent = Agent(name: "Planner", folderPath: root.appendingPathComponent("planner").path)
        agent.model = "haiku"
        agent.tools = "Read"
        try await app.writer.write { db in
            try Project(name: "Home").insert(db)
            try agent.insert(db)
        }
        let config = AgentLaunchConfig(agent: agent, skills: [], storages: [])
        let args = ws.arguments(config, settingsURL: try ws.prepare(config), resume: nil)
        let scope = AssistantTools.AgentScope(agentId: agent.id, agentName: agent.name, delegates: [])

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var process: AgentProcess?
            var calls: [String] = []
            var asked = false
        }
        let box = Box()
        let done = AsyncStream<Void>.makeStream()
        let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: args, cwd: URL(fileURLWithPath: agent.folderPath),
                                   environment: ClaudeCLI.environment()) { event in
            let p: AgentProcess? = box.lock.withLock { box.process }
            switch event {
            case .mcp(let requestId, _, let rpc):
                let id = rpc["id"]
                switch rpc["method"]?.string {
                case "initialize":
                    p?.respondMCP(requestId: requestId, id: id, result: [
                        "protocolVersion": rpc["params"]?["protocolVersion"]?.string ?? "2025-06-18",
                        "capabilities": ["tools": [:]], "serverInfo": ["name": "claudist", "version": "1"]])
                case "tools/list":
                    p?.respondMCP(requestId: requestId, id: id, result: ["tools": [Attention.toolDefinition()] + AssistantTools.agentToolDefinitions()])
                case "tools/call":
                    let name = rpc["params"]?["name"]?.string ?? ""
                    box.lock.withLock { box.calls.append(name) }
                    let text = (try? AssistantTools.call(name, rpc["params"]?["arguments"], db: app.writer, workspace: ws, scope: scope)) ?? "error"
                    p?.respondMCP(requestId: requestId, id: id, result: ["content": [["type": "text", "text": text]]])
                default:
                    p?.respondMCP(requestId: requestId, id: id, result: nil)
                }
            case .permission(let req):
                box.lock.withLock { box.asked = true }
                p?.respond(req, .deny("not in test"))
            case .message(let kind, _):
                if kind.hasPrefix("result") { p?.closeInput() }
            case .exited: done.continuation.finish()
            case .stderr: break
            }
        }
        box.lock.withLock { box.process = process }
        try process.start()
        process.initialize(sdkMcpServers: [Delegation.serverName])
        process.send("Create a task \"Buy paint\" in the Home project, due tomorrow.")
        for await _ in done.stream {}

        let (calls, asked) = box.lock.withLock { (box.calls, box.asked) }
        print("calls:", calls)
        #expect(calls.contains("create_task"))
        #expect(!asked)
        let created = try await app.writer.read { try TaskItem.filter(Column("content") == "Buy paint").fetchOne($0) }
        #expect(created?.dueDate != nil)
        #expect(created?.source == "agent: Planner")
    }
}
