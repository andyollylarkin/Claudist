import Foundation
import Testing
@testable import ClaudistCore

struct NotesTests {
    private func vault() -> NotesVault {
        NotesVault(root: FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(newID())"))
    }

    @Test func writesReadsAndResolvesLinks() throws {
        let v = vault()
        try v.write("Projects/Plan", "# Plan\nSee [[Ideas]] #work")
        try v.write("Ideas.md", "---\ntags:\n  - a\n  - b\nstatus: draft\n---\nBody #idea/new")
        try v.append("Ideas", "More")
        #expect(try v.read("Ideas.md").hasSuffix("Body #idea/new\n\nMore"))
        #expect(Set(v.list().map(\.path)) == ["Projects/Plan.md", "Ideas.md"])
        #expect(v.resolve(link: "Plan")?.path == "Projects/Plan.md")
        #expect(v.resolve(link: "ideas#Heading")?.path == "Ideas.md")
        #expect(v.search("#work").map(\.path) == ["Projects/Plan.md"])
        #expect(NotesVault.tags("# Heading\ntext #one and #two/sub, not#three\n```\n#code\n```") == ["one", "two/sub"])
        let (props, body) = NotesVault.frontmatter(try v.read("Ideas"))
        #expect(props.map(\.0) == ["tags", "status"])
        #expect(props.first?.1 == "a, b")
        #expect(body.hasPrefix("Body"))
        #expect(v.newPath("Ideas") == "Ideas 2.md")
        #expect(try v.move("Ideas.md", to: "Archive/Old ideas") == "Archive/Old ideas.md")
    }

    @Test func refusesPathsOutsideTheVault() throws {
        let v = vault()
        for bad in ["../escape", "a/../../escape", ".obsidian/config", ""] {
            #expect(throws: (any Error).self) { try v.write(bad, "x") }
        }
    }

    @Test func toolsFollowAccess() throws {
        let v = vault()
        let write: JSONValue = .object(["path": .string("A"), "content": .string("hi")])
        #expect(NotesTools.call(NotesTools.writeTool, arguments: write, vault: v, access: .ro).isError)
        #expect(NotesTools.call(NotesTools.listTool, arguments: nil, vault: v, access: nil).isError)
        #expect(!NotesTools.call(NotesTools.writeTool, arguments: write, vault: v, access: .rw).isError)
        #expect(NotesTools.call(NotesTools.readTool, arguments: .object(["path": .string("A")]), vault: v, access: .ro).text == "hi")
        #expect(NotesTools.toolDefinitions(.ro).count == 2)

        var agent = Agent(name: "N", folderPath: "/tmp/n")
        agent.notesAccess = .ro
        let ws = AgentWorkspace(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("nw-\(newID())")))
        let allow = (ws.settings(AgentLaunchConfig(agent: agent, skills: [], storages: []))["permissions"] as! [String: Any])["allow"] as! [String]
        #expect(allow.contains(NotesTools.qualified(NotesTools.readTool)))
        #expect(!allow.contains(NotesTools.qualified(NotesTools.writeTool)))
    }

    @Test func memoryFilesAndUniqueAgentFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(newID())")
        let paths = AppPaths(root: root)
        let folder = root.appendingPathComponent("agents/dev")
        let home = root.appendingPathComponent("home/.claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "rules".write(to: folder.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let mem = home.appendingPathComponent("projects/\(SessionFiles.projectKey(folder))/memory")
        try FileManager.default.createDirectory(at: mem, withIntermediateDirectories: true)
        for name in ["b.md", "MEMORY.md", "a.md"] { try "x".write(to: mem.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let files = AgentMemory.files(agentFolder: folder.path, paths: paths, environment: ["CLAUDE_CONFIG_DIR": home.path])
        #expect(files.map(\.name) == ["CLAUDE.md", "MEMORY.md", "a.md", "b.md"])
        #expect(files.first?.kind == .instructions)

        let ws = AgentWorkspace(paths: paths)
        #expect(ws.newFolder(for: "Dev", taken: []).lastPathComponent == "dev-2")   // agents/dev exists
        #expect(ws.newFolder(for: "New agent", taken: [ws.defaultFolder(for: "New agent").path]).lastPathComponent == "new-agent-2")
    }
}
