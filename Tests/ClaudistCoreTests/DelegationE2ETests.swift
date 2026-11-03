import Foundation
import Testing
@testable import ClaudistCore

/// Talks to the real `claude` CLI (uses your subscription, model haiku).
/// Run with: CLAUDIST_E2E=1 swift test --filter DelegationE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1"))
struct DelegationE2ETests {
    @Test(.timeLimit(.minutes(3))) func parentCallsDelegateToolServedByHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudist-e2e-\(newID())")
        let paths = AppPaths(root: root)
        try paths.ensure()
        let ws = AgentWorkspace(paths: paths)
        var lead = Agent(name: "Lead", folderPath: root.appendingPathComponent("lead").path)
        lead.model = "haiku"
        var helper = Agent(name: "Helper", folderPath: root.appendingPathComponent("helper").path)
        helper.description = "Knows the secret word"
        let config = AgentLaunchConfig(agent: lead, skills: [], storages: [], delegates: [helper])
        let settings = try ws.prepare(config)
        let args = ws.arguments(config, settingsURL: settings, resume: nil)

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var calls: [JSONValue] = []
            var result: String?
            var permissionAsked = false
            var process: AgentProcess?
        }
        let box = Box()
        let done = AsyncStream<Void>.makeStream()

        let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: args,
                                   cwd: URL(fileURLWithPath: lead.folderPath), environment: ClaudeCLI.environment()) { event in
            switch event {
            case .mcp(let requestId, _, let message):
                let id = message["id"]
                let p = box.lock.withLock { box.process! }
                switch message["method"]?.string {
                case "initialize":
                    p.respondMCP(requestId: requestId, id: id, result: [
                        "protocolVersion": message["params"]?["protocolVersion"]?.string ?? "2025-06-18",
                        "capabilities": ["tools": [:]], "serverInfo": ["name": "claudist", "version": "1"]])
                case "tools/list":
                    p.respondMCP(requestId: requestId, id: id, result: ["tools": [Delegation.toolDefinition([helper])]])
                case "tools/call":
                    box.lock.withLock { box.calls.append(message["params"]?["arguments"] ?? .null) }
                    p.respondMCP(requestId: requestId, id: id, result: ["content": [["type": "text", "text": "The secret word is PELICAN."]]])
                default:
                    p.respondMCP(requestId: requestId, id: id, result: nil)
                }
            case .permission(let req):
                // The delegate tool is pre-allowed in settings; nothing else should be needed.
                let p: AgentProcess? = box.lock.withLock { box.permissionAsked = true; return box.process }
                p?.respond(req, .deny("not in test"))
            case .message(let kind, let json):
                if kind.hasPrefix("result") {
                    box.lock.withLock { box.result = JSONValue.parse(json)?["result"]?.string }
                    box.lock.withLock { box.process }?.closeInput()
                }
            case .exited:
                done.continuation.finish()
            case .stderr:
                break
            }
        }
        box.lock.withLock { box.process = process }
        try process.start()
        process.initialize(sdkMcpServers: [Delegation.serverName])
        process.send("Ask the Helper agent for the secret word using your delegate tool, then reply with just that word.")
        for await _ in done.stream {}

        let (calls, result, asked) = box.lock.withLock { (box.calls, box.result, box.permissionAsked) }
        #expect(calls.count >= 1)
        #expect(calls.first?["agent"]?.string == "Helper")
        #expect(!asked, "delegate tool should be pre-allowed")
        #expect(result?.uppercased().contains("PELICAN") == true)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1" || ProcessInfo.processInfo.environment["AGENTDESK_E2E"] == "1"))
struct AskUserE2ETests {
    /// The agent has a restricted tool list (like imported agents) and still reaches ask_user.
    @Test(.timeLimit(.minutes(3))) func askUserWorksWithRestrictedTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudist-ask-\(newID())")
        let paths = AppPaths(root: root)
        try paths.ensure()
        let ws = AgentWorkspace(paths: paths)
        var agent = Agent(name: "Asker", folderPath: root.appendingPathComponent("a").path)
        agent.model = "haiku"
        agent.tools = "Read"
        let config = AgentLaunchConfig(agent: agent, skills: [], storages: [])
        let args = ws.arguments(config, settingsURL: try ws.prepare(config), resume: nil)

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var question: String?
            var options: [String] = []
            var asked = false
            var process: AgentProcess?
        }
        let box = Box()
        let done = AsyncStream<Void>.makeStream()
        let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: args,
                                   cwd: URL(fileURLWithPath: agent.folderPath), environment: ClaudeCLI.environment()) { event in
            let p: AgentProcess? = box.lock.withLock { box.process }
            switch event {
            case .mcp(let requestId, _, let message):
                let id = message["id"]
                switch message["method"]?.string {
                case "initialize":
                    p?.respondMCP(requestId: requestId, id: id, result: [
                        "protocolVersion": message["params"]?["protocolVersion"]?.string ?? "2025-06-18",
                        "capabilities": ["tools": [:]], "serverInfo": ["name": "claudist", "version": "1"]])
                case "tools/list":
                    p?.respondMCP(requestId: requestId, id: id, result: ["tools": [Attention.toolDefinition()]])
                case "tools/call":
                    let a = message["params"]?["arguments"]
                    box.lock.withLock {
                        box.question = a?["question"]?.string
                        box.options = (a?["options"]?.array ?? []).compactMap(\.string)
                    }
                    p?.respondMCP(requestId: requestId, id: id, result: ["content": [["type": "text", "text": "Posted. Stop now."]]])
                default:
                    p?.respondMCP(requestId: requestId, id: id, result: nil)
                }
            case .permission(let req):
                box.lock.withLock { box.asked = true }
                p?.respond(req, .deny("not in test"))
            case .message(let kind, _):
                if kind.hasPrefix("result") { p?.closeInput() }
            case .exited:
                done.continuation.finish()
            case .stderr:
                break
            }
        }
        box.lock.withLock { box.process = process }
        try process.start()
        process.initialize(sdkMcpServers: [Delegation.serverName])
        process.send("Deploy the app to production. You don't know whether to deploy to the EU or the US region, and it's the user's call.")
        for await _ in done.stream {}

        let (question, options, asked) = box.lock.withLock { (box.question, box.options, box.asked) }
        #expect(question?.isEmpty == false, "agent should call ask_user")
        #expect(!asked, "ask_user should be pre-allowed")
        print("ask_user question:", question ?? "-", "options:", options)
    }
}
