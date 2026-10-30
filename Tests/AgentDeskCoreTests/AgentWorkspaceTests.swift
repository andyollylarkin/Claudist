import Foundation
import Testing
@testable import AgentDeskCore

struct AgentWorkspaceTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesk-tests-\(newID())")
        try AppPaths(root: root).ensure()
    }

    @Test func importsAgentMarkdown() {
        let md = """
        ---
        name: code-reviewer
        description: "Reviews diffs"
        tools: Read, Grep, Bash
        model: sonnet
        ---

        You are a reviewer.
        """
        let a = AgentImporter.parse(md, fallbackName: "x")
        #expect(a.name == "code-reviewer")
        #expect(a.description == "Reviews diffs")
        #expect(a.tools == "Read,Grep,Bash")
        #expect(a.model == "sonnet")
        #expect(a.prompt == "You are a reviewer.")
    }

    @Test func markdownWithoutFrontmatterUsesFallbackName() {
        let a = AgentImporter.parse("Just a prompt", fallbackName: "helper")
        #expect(a.name == "helper")
        #expect(a.prompt == "Just a prompt")
    }

    @Test func syncsSkillSymlinksAndKeepsLocalSkills() throws {
        let paths = AppPaths(root: root)
        let lib = SkillLibrary(root: paths.skills)
        try lib.create(name: "alpha", description: "A")
        try lib.create(name: "beta", description: "B")
        #expect(lib.list().map(\.name) == ["alpha", "beta"])

        let agent = root.appendingPathComponent("agent1")
        let local = agent.appendingPathComponent(".claude/skills/local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        try lib.sync(agentFolder: agent, names: ["alpha", "beta"])
        let dir = agent.appendingPathComponent(".claude/skills").path
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir)) == ["alpha", "beta", "local"])
        #expect(FileManager.default.fileExists(atPath: dir + "/alpha/SKILL.md"))

        try lib.sync(agentFolder: agent, names: ["beta"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir)) == ["beta", "local"])
    }

    @Test func buildsArgumentsAndSettings() throws {
        let ws = AgentWorkspace(paths: AppPaths(root: root))
        var agent = Agent(name: "Researcher", folderPath: root.appendingPathComponent("r").path)
        agent.model = "haiku"
        agent.prompt = "Be brief"
        agent.allowList = ["Read"]
        let ro = Storage(name: "Docs", path: "/Users/x/docs")
        let rw = Storage(name: "Out", path: "/Users/x/out")
        let config = AgentLaunchConfig(agent: agent, skills: [], storages: [(ro, .ro), (rw, .rw)])

        let settingsURL = try ws.prepare(config)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        let perms = settings["permissions"] as! [String: Any]
        #expect(perms["allow"] as! [String] == ["Read"])
        #expect(perms["deny"] as! [String] == ["Edit(//Users/x/docs/**)", "Write(//Users/x/docs/**)"])
        #expect(perms["additionalDirectories"] as! [String] == ["/Users/x/docs", "/Users/x/out"])

        let args = ws.arguments(config, settingsURL: settingsURL, resume: "sess-1")
        #expect(args.contains("--permission-prompt-tool"))
        #expect(args.split(separator: "--model").count == 2)
        #expect(Array(args.drop(while: { $0 != "--resume" }).prefix(2)) == ["--resume", "sess-1"])
        #expect(args.filter { $0 == "--add-dir" }.count == 2)
        #expect(Array(args.drop(while: { $0 != "--setting-sources" }).prefix(2)) == ["--setting-sources", "project,local"])
    }
}

struct AttachmentSettingsTests {
    @Test func grantsExactAttachmentAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(newID())")
        let host = root.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try "x".write(to: host.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let ws = AgentWorkspace(paths: AppPaths(root: root.appendingPathComponent("app")))

        var file = TaskAttachment(taskId: "t", url: host.appendingPathComponent("notes.txt"))
        file.writable = true
        let dir = TaskAttachment(taskId: "t", url: host.appendingPathComponent("dir"))
        let gone = TaskAttachment(taskId: "t", url: host.appendingPathComponent("gone.txt"))
        #expect(!file.isDirectory && dir.isDirectory && !gone.exists)

        var config = AgentLaunchConfig(agent: Agent(name: "A", folderPath: root.appendingPathComponent("a").path), skills: [], storages: [])
        config.taskId = "t"
        config.attachments = [file, dir, gone]
        let perms = ws.settings(config)["permissions"] as! [String: Any]
        let allow = perms["allow"] as! [String]
        #expect(allow == ["Read(/\(file.path))", "Edit(/\(file.path))", "Write(/\(file.path))", "Read(/\(dir.path)/**)"])
        #expect(perms["additionalDirectories"] as! [String] == [dir.path])

        let url = try ws.prepare(config)
        #expect(url.lastPathComponent == "\(config.agent.id)-t.json")
        let args = ws.arguments(config, settingsURL: url, resume: nil)
        #expect(args.filter { $0 == "--add-dir" }.count == 1)

        let prompt = AgentWorkspace.attachmentsPrompt([file, gone])!
        #expect(prompt.contains("read & write"))
        #expect(prompt.contains("MISSING"))
    }
}
