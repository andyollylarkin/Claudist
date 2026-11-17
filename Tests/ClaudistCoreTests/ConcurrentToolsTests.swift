import Foundation
import GRDB
import Testing
@testable import ClaudistCore

/// Agents read their tasks through the app's tools, often several calls at once (Claude Code runs
/// tool calls in parallel), each on its own thread. Run these with `swift test -c release
/// -Xswiftc -enable-testing` too: the crash they guard against only showed up optimized.
struct ConcurrentToolsTests {
    /// An agent's own task through its scope. Optimized, `AgentScope.visible` once reported a bogus
    /// error here (a pointer left in the error register), which crashed the app on `get_task`.
    @Test func agentReadsAndChangesItsOwnTask() throws {
        let app = try AppDatabase.inMemory()
        let agent = Agent(name: "Worker", folderPath: "/tmp/w")
        var t = TaskItem(projectId: "", content: "Mine")
        try app.writer.write { db in
            let p = Project(name: "Home")
            try p.insert(db)
            try agent.insert(db)
            t.projectId = p.id
            t.agentId = agent.id
            try t.insert(db)
        }
        let scope = AssistantTools.AgentScope(agentId: agent.id, agentName: agent.name, delegates: [])
        let workspace = AgentWorkspace(paths: AppPaths(root: URL(fileURLWithPath: "/tmp/w")))
        try scope.ensureVisible(t)
        try scope.check(t)
        let got = try AssistantTools.call("get_task", JSONValue.parse(#"{"id":"\#(t.id)"}"#), db: app.writer, workspace: workspace, scope: scope)
        #expect(got.contains("Mine"))
        _ = try AssistantTools.call("create_task", JSONValue.parse(#"{"project":"Home","content":"Sub","parent_id":"\#(t.id)"}"#),
                                    db: app.writer, workspace: workspace, scope: scope)
        _ = try AssistantTools.call("add_comment", JSONValue.parse(#"{"task_id":"\#(t.id)","text":"done"}"#),
                                    db: app.writer, workspace: workspace, scope: scope)
    }

    @Test func parallelGetTaskCalls() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try AppDatabase.onDisk(at: dir.appendingPathComponent("db.sqlite"))
        let agent = Agent(name: "Worker", folderPath: dir.appendingPathComponent("agent").path)
        var ids: [ID] = []
        try app.writer.write { db in
            let p = Project(name: "Home")
            try p.insert(db)
            try agent.insert(db)
            for i in 0..<40 {
                var t = TaskItem(projectId: p.id, content: "Task \(i)")
                t.description = String(repeating: "details \(i) ", count: 50)
                t.agentId = i % 2 == 0 ? agent.id : nil
                try t.insert(db)
                for c in 0..<3 { try Comment(taskId: t.id, content: "comment \(c)").insert(db) }
                var r = Run(taskId: t.id, agentId: agent.id, trigger: "manual")
                r.status = .done
                try r.insert(db)
                ids.append(t.id)
            }
        }
        let workspace = AgentWorkspace(paths: AppPaths(root: dir))
        let scope = AssistantTools.AgentScope(agentId: agent.id, agentName: agent.name, delegates: [])
        let writer = app.writer
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let find = i % 5 == 0
            do {
                _ = try AssistantTools.call(find ? "find_tasks" : "get_task",
                                            find ? JSONValue.parse(#"{"query":"Task"}"#) : JSONValue.parse(#"{"id":"\#(ids[i % ids.count])"}"#),
                                            db: writer, workspace: workspace, scope: scope)
            } catch {
                Issue.record("call \(i): \(error)")
            }
        }
    }
}
