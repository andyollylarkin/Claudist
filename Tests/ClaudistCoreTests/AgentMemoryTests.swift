import Foundation
import Testing
@testable import ClaudistCore

struct AgentMemoryTests {
    @Test func movesAFileWithItsIndexLineToBothPlacesOfTheOtherAgent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root.appendingPathComponent("app"))
        let env = ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path]
        let from = root.appendingPathComponent("agents/a").path
        let to = root.appendingPathComponent("agents/b").path

        let source = AgentMemory.memoryFolders(agentFolder: from, paths: paths, environment: env)[1].url
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "- [Keep](keep.md) — stays\n- [Mail](mail.md) — trash folders\n".write(to: source.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try "mail notes".write(to: source.appendingPathComponent("mail.md"), atomically: true, encoding: .utf8)
        try "keep".write(to: source.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)

        let file = try #require(AgentMemory.files(agentFolder: from, paths: paths, environment: env).first { $0.name == "mail.md" })
        try AgentMemory.move(file, toAgentFolder: to, paths: paths, environment: env)

        for (_, dir) in AgentMemory.memoryFolders(agentFolder: to, paths: paths, environment: env) {
            #expect(try String(contentsOf: dir.appendingPathComponent("mail.md"), encoding: .utf8) == "mail notes")
            #expect(try String(contentsOf: dir.appendingPathComponent("MEMORY.md"), encoding: .utf8) == "- [Mail](mail.md) — trash folders\n")
        }
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("mail.md").path))
        #expect(try String(contentsOf: source.appendingPathComponent("MEMORY.md"), encoding: .utf8) == "- [Keep](keep.md) — stays\n")

        // A name the other agent already remembers is refused, and nothing moves.
        let keep = try #require(AgentMemory.files(agentFolder: from, paths: paths, environment: env).first { $0.name == "keep.md" })
        try "other".write(to: AgentMemory.memoryFolders(agentFolder: to, paths: paths, environment: env)[0].url.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
        #expect(throws: ClaudistError.self) { try AgentMemory.move(keep, toAgentFolder: to, paths: paths, environment: env) }
        #expect(FileManager.default.fileExists(atPath: keep.url.path))
    }
}
