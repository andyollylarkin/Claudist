import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct ConfigArchiveTests {
    let root: URL
    let paths: AppPaths
    let db: AppDatabase
    let secrets = MemorySecretStore()
    let claudeProjects: URL
    var archive: ConfigArchive { ConfigArchive(db: db, paths: paths, secretStore: secrets, claudeProjects: claudeProjects) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(newID())")
        paths = AppPaths(root: root.appendingPathComponent("app"))
        try paths.ensure()
        claudeProjects = root.appendingPathComponent("claude-projects")
        db = try AppDatabase.inMemory()
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Project + task + agent with a skill, memory, a custom-folder agent and a secret.
    private func seed() throws -> (agent: Agent, custom: Agent, secret: Secret) {
        let lib = SkillLibrary(root: paths.skills)
        let skill = try lib.create(name: "deploy", description: "Deploys")
        try lib.attach([try { let u = root.appendingPathComponent("run.sh"); try write("#!/bin/sh", u); return u }()], to: skill, subfolder: "scripts")

        let agent = Agent(name: "Coder", folderPath: paths.agents.appendingPathComponent("coder").path)
        let custom = Agent(name: "Repo", folderPath: root.appendingPathComponent("my-repo").path)
        try write("# Coder memory file", URL(fileURLWithPath: agent.folderPath).appendingPathComponent("CLAUDE.md"))
        try write("repo file", URL(fileURLWithPath: custom.folderPath).appendingPathComponent("README.md"))
        try write("remembered", archive.memoryFolder(for: agent.folderPath).appendingPathComponent("MEMORY.md"))

        let secret = Secret(name: "TOKEN")
        try secrets.setValue("s3cr3t", for: secret.id)
        try db.writer.write { db in
            let p = Project(name: "Work")
            try p.insert(db)
            try TaskItem(projectId: p.id, content: "Ship it").insert(db)
            try agent.insert(db)
            try custom.insert(db)
            try AgentSkill(agentId: agent.id, skillName: "deploy").insert(db)
            try secret.insert(db)
            try AgentSecret(agentId: agent.id, secretId: secret.id).insert(db)
        }
        try lib.sync(agentFolder: URL(fileURLWithPath: agent.folderPath), names: ["deploy"])
        return (agent, custom, secret)
    }

    @Test func roundTripRestoresEverything() throws {
        let (agent, custom, secret) = try seed()
        let zip = root.appendingPathComponent("export.zip")
        var options = ConfigArchive.Options()
        options.secretsPassword = "pw"
        try archive.export(to: zip, options: options)

        let manifest = try ConfigArchive.inspect(zip)
        #expect(manifest.encryptedSecrets)
        #expect(manifest.agents.first { $0.id == agent.id }?.hasMemory == true)

        // Wreck the current state.
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM project")
            try db.execute(sql: "DELETE FROM agent")
        }
        try FileManager.default.removeItem(at: paths.skills)
        try FileManager.default.removeItem(atPath: agent.folderPath)
        try FileManager.default.removeItem(at: archive.memoryFolder(for: agent.folderPath))
        try write("changed locally", URL(fileURLWithPath: custom.folderPath).appendingPathComponent("README.md"))
        try secrets.remove(secret.id)

        #expect(throws: ConfigArchive.ArchiveError.self) { try archive.importArchive(from: zip, secretsPassword: "wrong") }
        let report = try archive.importArchive(from: zip, secretsPassword: "pw")

        #expect(report.projects == 1 && report.tasks == 1 && report.agents == 2 && report.skills == 1)
        #expect(report.secretsRestored == 1)
        #expect(try secrets.value(for: secret.id) == "s3cr3t")
        #expect(FileManager.default.fileExists(atPath: report.backup!.path))

        let fm = FileManager.default
        #expect(try String(contentsOfFile: agent.folderPath + "/CLAUDE.md", encoding: .utf8) == "# Coder memory file")
        #expect(fm.fileExists(atPath: agent.folderPath + "/.claude/skills/deploy/SKILL.md"), "skill symlink recreated")
        #expect(fm.isExecutableFile(atPath: paths.skills.path + "/deploy/scripts/run.sh"))
        #expect(fm.fileExists(atPath: archive.memoryFolder(for: agent.folderPath).appendingPathComponent("MEMORY.md").path))
        // Custom folders that exist are never overwritten.
        #expect(try String(contentsOfFile: custom.folderPath + "/README.md", encoding: .utf8) == "changed locally")
        #expect(report.keptFolders == [custom.folderPath])
    }

    @Test func exportWithoutHistoryOrSecrets() throws {
        let (agent, _, _) = try seed()
        try db.writer.write { db in
            let task = try TaskItem.fetchOne(db)!
            try Run(taskId: task.id, agentId: agent.id).insert(db)
        }
        let zip = root.appendingPathComponent("lean.zip")
        var options = ConfigArchive.Options()
        options.runHistory = false
        options.agentFolders = false
        try archive.export(to: zip, options: options)
        let manifest = try ConfigArchive.inspect(zip)
        #expect(!manifest.encryptedSecrets && !manifest.runHistory)
        #expect(manifest.agents.allSatisfy { !$0.hasFolder && !$0.hasMemory })

        let report = try archive.importArchive(from: zip, secretsPassword: nil)
        #expect(try db.writer.read { try Run.fetchCount($0) } == 0)
        #expect(report.secretsWithoutValue == 1)
    }

    @Test func rejectsForeignZip() throws {
        let dir = root.appendingPathComponent("junk")
        try write("x", dir.appendingPathComponent("a.txt"))
        let zip = root.appendingPathComponent("junk.zip")
        try ConfigArchive.ditto(["-c", "-k", dir.path, zip.path])
        #expect(throws: ConfigArchive.ArchiveError.self) { try ConfigArchive.inspect(zip) }
    }

    @Test func encryptionRoundTrip() throws {
        let data = Data("hello".utf8)
        let sealed = try ConfigArchive.encrypt(data, password: "a")
        #expect(try ConfigArchive.decrypt(sealed, password: "a") == data)
        #expect(throws: ConfigArchive.ArchiveError.self) { try ConfigArchive.decrypt(sealed, password: "b") }
    }
}
