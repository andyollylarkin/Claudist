import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct AccessRequestTests {
    let app: AppDatabase
    let task: TaskItem
    let agent: Agent
    let root: URL

    init() throws {
        app = try AppDatabase.inMemory()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("access-\(newID())", isDirectory: true)
        for dir in ["work/repo/pkg", "work/other", "work/repo2"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("work/readme.md"), atomically: true, encoding: .utf8)
        let agent = Agent(name: "Lead", folderPath: root.appendingPathComponent("agent").path)
        let task = try app.writer.write { db -> TaskItem in
            let p = Project(name: "P")
            try p.insert(db)
            try agent.insert(db)
            var t = TaskItem(projectId: p.id, content: "Fix")
            t.agentId = agent.id
            try t.insert(db)
            return t
        }
        self.agent = agent
        self.task = task
    }

    private func ask(_ args: [String: JSONValue]) throws -> AccessRequest {
        try app.writer.write { try AccessRequests.create($0, taskId: task.id, agent: agent, arguments: .object(args)) }
    }

    private func decide(_ answer: String) throws -> String? {
        try app.writer.write { try AccessRequests.decide($0, taskId: task.id, answer: answer) }
    }

    @Test func pathRequestForTheTask() throws {
        let repo = root.appendingPathComponent("work/repo").path
        let r = try ask(["path": .string(repo + "/"), "reason": .string("commit the fix")])
        #expect(r.target == repo && r.access == .rw && r.kind == .path)
        let t = try #require(try app.writer.read { try TaskItem.fetchOne($0, key: task.id) })
        #expect(t.attention?.contains("write access to \(repo)") == true)
        #expect(t.attentionChoices == [AccessRequests.allowTask, AccessRequests.allowAgent("Lead"), AccessRequests.deny])

        let message = try #require(try decide(AccessRequests.allowTask))
        #expect(message.contains("allowed write access"))
        let attachment = try #require(try app.writer.read { try TaskAttachment.filter(Column("taskId") == task.id).fetchOne($0) })
        #expect(attachment.path == repo && attachment.writable && attachment.isDirectory)
        // Decided: a later click does nothing.
        #expect(try decide(AccessRequests.deny) == nil)
    }

    @Test func pathRequestForTheAgentAndCommands() throws {
        let repo = root.appendingPathComponent("work/repo").path
        _ = try ask(["path": .string(repo), "access": .string("read"), "reason": .string("read code")])
        _ = try decide(AccessRequests.allowAgent("Lead"))
        let link = try #require(try app.writer.read { try AgentStorage.filter(Column("agentId") == agent.id).fetchOne($0) })
        #expect(link.access == .ro)

        _ = try ask(["command": .string("gofmt -w pkg/ts/server_test.go"), "reason": .string("format")])
        #expect(try decide(AccessRequests.allowTask) != nil)
        #expect(try app.writer.read { try AccessRequests.taskRules($0, taskId: task.id) } == ["Bash(gofmt:*)"])

        _ = try ask(["command": .string("git commit -m x"), "reason": .string("commit")])
        _ = try decide(AccessRequests.allowAgent("Lead"))
        #expect(try app.writer.read { try Agent.fetchOne($0, key: agent.id) }?.allowList == ["Bash(git commit:*)"])

        _ = try ask(["command": .string("rm -rf /"), "reason": .string("x")])
        #expect(try decide("no way") == nil)
        #expect(try app.writer.read { try AccessRequests.pending($0, taskId: task.id) } == nil)
    }

    @Test func refusesVagueRequests() {
        #expect(throws: (any Error).self) { try ask(["path": .string("/"), "reason": .string("all")]) }
        #expect(throws: (any Error).self) { try ask(["path": .string("~"), "reason": .string("all")]) }
        #expect(throws: (any Error).self) { try ask(["path": .string("relative/x"), "reason": .string("x")]) }
        #expect(throws: (any Error).self) { try ask(["command": .string("sudo rm x"), "reason": .string("x")]) }
        #expect(throws: (any Error).self) { try ask(["path": .string("/tmp/x")]) }
        #expect(AccessRequests.rule(for: "docker run --rm img") == "Bash(docker run:*)")
        #expect(AccessRequests.rule(for: "go test ./pkg/ts/") == "Bash(go test:*)")
        #expect(AccessRequests.rule(for: "$HOME/bin/x") == nil)
    }

    @Test func writableFolderInsideReadOnlyStorage() {
        let work = root.appendingPathComponent("work").path
        let repo = work + "/repo"
        #expect(AgentWorkspace.readOnlyRules(work, except: []) == ["Edit(/\(work)/**)", "Write(/\(work)/**)"])
        #expect(AgentWorkspace.readOnlyRules(work, except: [work]) == [])
        let rules = AgentWorkspace.readOnlyRules(work, except: [repo])
        // Files of the level are denied by name: a "work/*" rule would also take in work/repo and all below it.
        #expect(rules.contains("Edit(/\(work)/readme.md)"))
        #expect(!rules.contains { $0.hasSuffix("/*)") })
        #expect(rules.contains("Edit(/\(work)/other/**)"))
        #expect(rules.contains("Write(/\(work)/repo2/**)"))
        #expect(!rules.contains { $0.contains("/repo/") || $0.hasSuffix("/repo/**)") })
        let deep = AgentWorkspace.readOnlyRules(work, except: [repo + "/pkg"])
        #expect(!deep.contains { $0.contains("/pkg") || $0.hasSuffix("/*)") })
        #expect(deep.contains("Edit(/\(work)/other/**)"))
        // A read-only folder inside a writable one changes nothing: everything below a writable path stays writable.
        #expect(AgentWorkspace.readOnlyRules(repo + "/pkg", except: [repo]) == [])
    }
}
