import Foundation
import GRDB
import Testing
@testable import ClaudistCore

@Suite(.serialized) struct ClaudeAccountsTests {
    let db: AppDatabase
    let secrets = MemorySecretStore()
    var work = ClaudeAccount(name: "Work", kind: .subscription)
    var api = ClaudeAccount(name: "API", kind: .apiKey)
    let mine: Agent, colleague: Agent, other: Agent
    let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/claudist-accounts-test"))

    init() throws {
        UserDefaults.standard.removeObject(forKey: ClaudeAccounts.defaultKey)
        db = try AppDatabase.inMemory()
        var mine = Agent(name: "Mine", folderPath: "/tmp/agents/mine")
        var colleague = Agent(name: "Colleague", folderPath: "/tmp/agents/colleague")
        var other = Agent(name: "Other", folderPath: "/tmp/agents/other")
        mine.accountId = work.id
        colleague.accountId = work.id
        other.accountId = api.id
        (self.mine, self.colleague, self.other) = (mine, colleague, other)
        try db.writer.write { [work, api, secrets] db in
            try ClaudeAccounts.save(db, work, secret: "sk-ant-oat01-work\n", secrets: secrets)
            try ClaudeAccounts.save(db, api, secret: "sk-ant-api03-key", secrets: secrets)
            for a in [mine, colleague, other] { try a.insert(db) }
            try Project(name: "Work").insert(db)
        }
    }

    @Test func accountsGiveTheirCredential() throws {
        let (w, k) = try db.writer.read { db in
            (try ClaudeAccounts.resolve(db, agent: mine), try ClaudeAccounts.resolve(db, agent: other))
        }
        #expect(try ClaudeAccounts.environment(w, secrets: secrets) == ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-work"])
        #expect(try ClaudeAccounts.environment(k, secrets: secrets) == ["ANTHROPIC_API_KEY": "sk-ant-api03-key"])
        // No own account and no default: this Mac's login.
        let plain = Agent(name: "Plain", folderPath: "/tmp/p")
        #expect(try db.writer.read { try ClaudeAccounts.resolve($0, agent: plain) } == nil)
        let env = ClaudeAccounts.hostEnvironment(["ANTHROPIC_API_KEY": "k"])
        #expect(env["ANTHROPIC_API_KEY"] == "k" && env["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test func containersSignInWithTheRunsAccount() throws {
        var spec = LaunchSpec(executable: URL(fileURLWithPath: "/bin/true"), arguments: [], cwd: URL(fileURLWithPath: "/tmp"),
                              environment: ["ANTHROPIC_API_KEY": "stray"], agentEnvironment: [], mounts: [], runId: "r")
        spec.credential = ["ANTHROPIC_API_KEY": "key"]
        #expect(try DockerEngine.credential(spec, credentials: secrets) == ("ANTHROPIC_API_KEY", "key"))
        var plain = spec
        plain.credential = [:]
        #expect(throws: ClaudistError.self) { try DockerEngine.credential(plain, credentials: secrets) }
        try secrets.setValue("container", for: DockerEngine.tokenSecretId)
        #expect(try DockerEngine.credential(plain, credentials: secrets) == ("CLAUDE_CODE_OAUTH_TOKEN", "container"))
    }

    @Test func otherAccountsTasksDontExist() throws {
        let others = try db.writer.read { try ClaudeAccounts.otherAccountAgents($0, of: mine) }
        #expect(others.map(\.name) == ["Other"])
        let (shared, theirs, ours) = try db.writer.write { db -> (TaskItem, TaskItem, TaskItem) in
            let p = try Project.fetchOne(db)!
            let shared = TaskItem(projectId: p.id, content: "Unassigned")
            var theirs = TaskItem(projectId: p.id, content: "Secret plan")
            theirs.agentId = other.id
            var ours = TaskItem(projectId: p.id, content: "Our work")
            ours.agentId = colleague.id
            for t in [shared, theirs, ours] { try t.insert(db) }
            return (shared, theirs, ours)
        }
        let scope = AssistantTools.AgentScope(agentId: mine.id, agentName: "Mine", delegates: [colleague.id, other.id], hidden: Set(others.map(\.id)))
        let workspace = AgentWorkspace(paths: paths)
        func call(_ name: String, _ args: [String: JSONValue]) throws -> String {
            try AssistantTools.call(name, .object(args), db: db.writer, workspace: workspace, scope: scope)
        }
        let found = try call("find_tasks", [:])
        #expect(found.contains("Unassigned") && found.contains("Our work") && !found.contains("Secret plan"))
        #expect(try call("list_projects", [:]).contains("\"open_tasks\":2"))
        #expect(throws: ClaudistError.self) { try call("get_task", ["id": .string(theirs.id)]) }
        #expect(throws: ClaudistError.self) { try call("add_comment", ["task_id": .string(theirs.id), "text": .string("hi")]) }
        #expect(throws: ClaudistError.self) { try call("complete_task", ["id": .string(theirs.id)]) }
        #expect(throws: ClaudistError.self) { try call("create_task", ["project": .string("Work"), "content": .string("x"), "parent_id": .string(theirs.id)]) }
        // Listed as a delegate, but on another account: still can't be given work.
        #expect(throws: ClaudistError.self) { try call("create_task", ["project": .string("Work"), "content": .string("x"), "agent": .string("Other")]) }
        _ = try call("create_task", ["project": .string("Work"), "content": .string("for colleague"), "agent": .string("Colleague")])
        #expect(try call("get_task", ["id": .string(ours.id)]).contains("Our work"))
        #expect(try call("get_task", ["id": .string(shared.id)]).contains("Unassigned"))
    }

    @Test func otherAccountsFilesAreDenied() throws {
        let others = try db.writer.read { try ClaudeAccounts.otherAccountAgents($0, of: mine) }
        var config = AgentLaunchConfig(agent: mine, skills: [], storages: [])
        config.foreignPaths = ClaudeAccounts.foreignPaths(others, own: mine, paths: paths, hostConfig: URL(fileURLWithPath: "/Users/me/.claude"))
        config.databaseFile = paths.database.path
        let deny = (AgentWorkspace(paths: paths).settings(config)["permissions"] as? [String: Any])?["deny"] as? [String] ?? []
        #expect(deny.contains("Read(//tmp/agents/other/**)"))
        #expect(deny.contains("Read(//Users/me/.claude/projects/-tmp-agents-other/**)"))
        #expect(deny.contains { $0.hasPrefix("Read(//tmp/claudist-accounts-test/containers/homes/-tmp-agents-other") })
        #expect(deny.contains("Read(//tmp/claudist-accounts-test/db.sqlite*)"))
        #expect(!deny.contains { $0.contains("agents/colleague") || $0.contains("agents/mine") })
        // A parent folder of the agent's own is never denied (it would lock the agent out).
        let parent = Agent(name: "Parent", folderPath: "/tmp/agents")
        #expect(ClaudeAccounts.foreignPaths([parent], own: mine, paths: paths, hostConfig: URL(fileURLWithPath: "/h")).allSatisfy { $0 != "/tmp/agents" })
    }

    @Test func removingAnAccountSendsAgentsToTheDefault() throws {
        try db.writer.write { [api, secrets] in try ClaudeAccounts.remove($0, api, secrets: secrets) }
        #expect(try db.writer.read { try Agent.fetchOne($0, key: other.id)?.accountId } == nil)
        #expect(try secrets.value(for: api.secretId) == nil)
        #expect(try db.writer.read { try ClaudeAccounts.otherAccountAgents($0, of: mine) }.map(\.name) == ["Other"])
    }
}
