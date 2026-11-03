import Foundation
import Security
import GRDB
import Testing
@testable import ClaudistCore

struct SecretsTests {
    @Test func validatesNames() {
        #expect(Secret.isValidName("GITHUB_TOKEN"))
        #expect(Secret.isValidName("_x1"))
        #expect(!Secret.isValidName("1TOKEN"))
        #expect(!Secret.isValidName("MY-TOKEN"))
        #expect(!Secret.isValidName(""))
    }

    @Test func resolvesAgentAndSkillSecretsWithoutDuplicates() throws {
        let db = try AppDatabase.inMemory()
        let agent = Agent(name: "Dev", folderPath: "/tmp/dev")
        let other = Agent(name: "Other", folderPath: "/tmp/other")
        let gh = Secret(name: "GITHUB_TOKEN")
        let jira = Secret(name: "JIRA_TOKEN")
        let unused = Secret(name: "UNUSED")
        try db.writer.write { db in
            for a in [agent, other] { try a.insert(db) }
            for s in [gh, jira, unused] { try s.insert(db) }
            try AgentSecret(agentId: agent.id, secretId: gh.id).insert(db)
            try AgentSkill(agentId: agent.id, skillName: "release").insert(db)
            try SkillSecret(skillName: "release", secretId: gh.id).insert(db)
            try SkillSecret(skillName: "release", secretId: jira.id).insert(db)
            try SkillSecret(skillName: "not-linked", secretId: unused.id).insert(db)
            try AgentSecret(agentId: other.id, secretId: unused.id).insert(db)
        }
        let resolved = try db.writer.read { try Secrets.resolve($0, agentId: agent.id) }
        #expect(resolved.map(\.secret.name) == ["GITHUB_TOKEN", "JIRA_TOKEN"])
        #expect(Set(resolved[0].via) == ["agent", "release"])
        #expect(resolved[1].via == ["release"])
    }

    @Test func buildsEnvironmentAndFailsOnMissingValue() throws {
        let store = MemorySecretStore()
        let a = Secret(name: "A")
        let b = Secret(name: "B")
        try store.setValue("1", for: a.id)
        #expect(try Secrets.environment([a], store: store).env == ["A": "1"])
        #expect(throws: ClaudistError.self) { try Secrets.environment([a, b], store: store) }
        try store.remove(a.id)
        #expect(try store.value(for: a.id) == nil)
    }

    @Test func deletingSecretRemovesLinks() throws {
        let db = try AppDatabase.inMemory()
        let agent = Agent(name: "Dev", folderPath: "/tmp/dev")
        let s = Secret(name: "X")
        try db.writer.write { db in
            try agent.insert(db)
            try s.insert(db)
            try AgentSecret(agentId: agent.id, secretId: s.id).insert(db)
            try SkillSecret(skillName: "k", secretId: s.id).insert(db)
            _ = try s.delete(db)
        }
        #expect(try db.writer.read { try AgentSecret.fetchCount($0) + SkillSecret.fetchCount($0) } == 0)
    }
}

@Test func keychainRoundTrip() throws {
    let store = KeychainSecretStore(service: "io.mindsw.claudist.tests-\(newID())")
    let id = newID()
    #expect(try store.value(for: id) == nil)
    try store.setValue("s3cr3t", for: id)
    #expect(try store.value(for: id) == "s3cr3t")
    try store.setValue("changed", for: id)
    #expect(try store.value(for: id) == "changed")
    try store.remove(id)
    #expect(try store.value(for: id) == nil)
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service] as CFDictionary)
}

@Test func keychainMovesOldItemsIntoTheVault() throws {
    let service = "io.mindsw.claudist.tests-\(newID())"
    let id = newID()
    let add = SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                          kSecAttrAccount as String: id, kSecValueData as String: Data("old".utf8)] as CFDictionary, nil)
    #expect(add == errSecSuccess)
    let store = KeychainSecretStore(service: service)
    #expect(try store.value(for: id) == "old")
    var out: AnyObject?
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
    #expect(SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess)
    #expect((out as? [[String: Any]])?.compactMap { $0[kSecAttrAccount as String] as? String } == ["vault"])
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
}

@Test func fileSecretsAndPrompt() throws {
    let store = MemorySecretStore()
    var key = Secret(name: "SSH_KEY", description: "RunPod key")
    key.asFile = true
    let token = Secret(name: "TOKEN")
    try store.setValue("-----BEGIN KEY-----\nabc\n-----END KEY-----", for: key.id)
    try store.setValue("t0k3n", for: token.id)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-\(newID())")

    let (env, values) = try Secrets.environment([key, token], store: store, fileDir: dir)
    #expect(env["TOKEN"] == "t0k3n")
    #expect(env["SSH_KEY"] == dir.appendingPathComponent("SSH_KEY").path)
    #expect(values["SSH_KEY"]!.hasPrefix("-----BEGIN"))
    #expect(try String(contentsOfFile: env["SSH_KEY"]!, encoding: .utf8).hasSuffix("-----END KEY-----\n"))
    let mode = try FileManager.default.attributesOfItem(atPath: env["SSH_KEY"]!)[.posixPermissions] as! NSNumber
    #expect(mode.intValue == 0o600)

    let prompt = Secrets.promptSection([key, token])!
    #expect(prompt.contains("`$SSH_KEY` — path to a file"))
    #expect(prompt.contains("RunPod key"))
    #expect(Secrets.promptSection([]) == nil)
}

@Test func skillToolAddedWhenToolsAreRestricted() throws {
    var agent = Agent(name: "A", folderPath: "/tmp/a")
    agent.tools = "Read,Bash"
    var config = AgentLaunchConfig(agent: agent, skills: ["transcribe"], storages: [])
    #expect(AgentWorkspace.tools(config) == "Read,Bash,Skill")
    config.skills = []
    #expect(AgentWorkspace.tools(config) == "Read,Bash")
    config.agent.tools = nil
    #expect(AgentWorkspace.tools(config) == nil)
}
