import Foundation
import GRDB
import Testing
@testable import AgentDeskCore

struct DelegationTests {
    let db: AppDatabase
    let lead = Agent(name: "Lead", folderPath: "/tmp/lead")
    let researcher = Agent(name: "Researcher", folderPath: "/tmp/res")
    let coder = Agent(name: "Coder", folderPath: "/tmp/coder")
    let project = Project(name: "P")

    init() throws {
        db = try AppDatabase.inMemory()
        try db.writer.write { [self] db in
            for a in [lead, researcher, coder] { try a.insert(db) }
            try project.insert(db)
            try AgentDelegate(agentId: lead.id, delegateId: researcher.id).insert(db)
            try AgentDelegate(agentId: lead.id, delegateId: coder.id).insert(db)
            try AgentDelegate(agentId: researcher.id, delegateId: lead.id).insert(db)
        }
    }

    private func task(_ id: ID, agent: Agent, parent: ID? = nil) throws {
        var t = TaskItem(projectId: project.id, content: id)
        t.id = id
        t.agentId = agent.id
        t.parentId = parent
        try db.writer.write { try t.insert($0) }
    }

    @Test func listsDelegatesAndBuildsTool() throws {
        let names = try db.writer.read { try Delegation.delegates($0, of: lead.id).map(\.name) }
        #expect(names == ["Coder", "Researcher"])
        let tool = Delegation.toolDefinition(try db.writer.read { try Delegation.delegates($0, of: lead.id) })
        let schema = tool["inputSchema"] as! [String: Any]
        let agentProp = (schema["properties"] as! [String: Any])["agent"] as! [String: Any]
        #expect(agentProp["enum"] as! [String] == ["Coder", "Researcher"])
    }

    @Test func allowsListedAgentCaseInsensitive() throws {
        try task("root", agent: lead)
        let target = try db.writer.read { try Delegation.validate($0, callerId: lead.id, parentTaskId: "root", agentName: "researcher") }
        #expect(target.id == researcher.id)
    }

    @Test func rejectsUnlistedAgent() throws {
        try task("root", agent: researcher)
        #expect(throws: Delegation.CallError.self) {
            try db.writer.read { try Delegation.validate($0, callerId: researcher.id, parentTaskId: "root", agentName: "Coder") }
        }
    }

    @Test func rejectsCycles() throws {
        // Lead → Researcher; Researcher may call Lead, but Lead is already up the chain.
        try task("root", agent: lead)
        try task("sub", agent: researcher, parent: "root")
        #expect(throws: Delegation.CallError.self) {
            try db.writer.read { try Delegation.validate($0, callerId: researcher.id, parentTaskId: "sub", agentName: "Lead") }
        }
        let chain = try db.writer.read { try Delegation.agentChain($0, taskId: "sub") }
        #expect(chain == [researcher.id, lead.id])
    }
}
