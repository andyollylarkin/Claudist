import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct PromptTemplatesTests {
    @Test func resolvesLinkedAndGlobalInOrderAndMergesBeforeOwnPrompt() throws {
        let db = try AppDatabase.inMemory()
        var agent = Agent(name: "Dev", folderPath: "/tmp/dev")
        agent.prompt = "Own rules."
        let other = Agent(name: "Ops", folderPath: "/tmp/ops")
        var global = PromptTemplate(name: "Global", content: "You are {{agent}}.")
        global.forAllAgents = true
        global.itemOrder = 1
        var linked = PromptTemplate(name: "Git", content: "Use conventional commits.")
        linked.itemOrder = 0
        let unused = PromptTemplate(name: "Unused", content: "nope")
        try db.writer.write { db in
            try agent.insert(db)
            try other.insert(db)
            for t in [global, linked, unused] { try t.insert(db) }
            try AgentPromptTemplate(agentId: agent.id, templateId: linked.id).insert(db)
        }
        let mine = try db.writer.read { try PromptTemplates.resolve($0, agentId: agent.id) }
        #expect(mine.map(\.name) == ["Git", "Global"])
        #expect(try db.writer.read { try PromptTemplates.resolve($0, agentId: other.id) }.map(\.name) == ["Global"])
        #expect(PromptTemplates.merge(mine, into: agent) == "Use conventional commits.\n\nYou are Dev.\n\nOwn rules.")

        let config = AgentLaunchConfig(agent: agent, skills: [], storages: [])
        var withTemplates = config
        withTemplates.promptTemplates = mine
        let ws = AgentWorkspace(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("pt-\(newID())")))
        let args = ws.arguments(withTemplates, settingsURL: URL(fileURLWithPath: "/tmp/s.json"), resume: nil)
        let prompt = args[args.firstIndex(of: "--append-system-prompt")! + 1]
        #expect(prompt.hasPrefix("Use conventional commits.\n\nYou are Dev.\n\nOwn rules."))
    }
}
