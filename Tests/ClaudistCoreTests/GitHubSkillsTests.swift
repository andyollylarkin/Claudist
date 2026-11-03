import Foundation
import Testing
@testable import ClaudistCore

struct GitHubSkillsTests {
    @Test func parsesLinks() {
        #expect(GitHubSkills.parse("https://github.com/anthropics/skills") == .init(owner: "anthropics", repo: "skills", ref: nil, path: ""))
        #expect(GitHubSkills.parse("github.com/anthropics/skills/tree/main/skills/pdf")
                == .init(owner: "anthropics", repo: "skills", ref: "main", path: "skills/pdf"))
        #expect(GitHubSkills.parse("https://github.com/o/r/blob/v1/a/SKILL.md?plain=1") == .init(owner: "o", repo: "r", ref: "v1", path: "a"))
        #expect(GitHubSkills.parse("o/r.git") == .init(owner: "o", repo: "r", ref: nil, path: ""))
        #expect(GitHubSkills.parse("o/r/skills/x") == .init(owner: "o", repo: "r", ref: nil, path: "skills/x"))
        #expect(GitHubSkills.parse("nonsense") == nil)
        #expect(GitHubSkills.parse("o/r/tree/main/../etc") == nil)
        #expect(GitHubSkills.parse("o;rm/r") == nil)
    }

    @Test func findsSkillFoldersAndInstalls() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let repo = base.appendingPathComponent("o-r-abc")
        func write(_ path: String, _ text: String) throws {
            let url = repo.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("skills/pdf/SKILL.md", "---\nname: pdf\ndescription: Read PDFs\n---\nBody")
        try write("skills/pdf/scripts/x.py", "print(1)")
        try write("skills/pdf/inner/SKILL.md", "---\nname: inner\n---")
        try write("skills/xlsx/SKILL.md", "---\ndescription: Sheets\n---")
        try write("node_modules/junk/SKILL.md", "---\nname: junk\n---")
        try write("README.md", "hi")

        let found = GitHubSkills.find(in: repo, repoRoot: repo, rootName: "r")
        #expect(found.map(\.path) == ["skills/pdf", "skills/xlsx"])
        #expect(found[0].name == "pdf" && found[0].description == "Read PDFs" && found[0].files == 3)
        #expect(found[1].name == "xlsx")

        let library = SkillLibrary(root: base.appendingPathComponent("library"))
        try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
        let skill = try library.install(found[0], from: .init(owner: "o", repo: "r", ref: "main", path: "skills"))
        #expect(skill.name == "pdf")
        #expect(fm.fileExists(atPath: skill.url.appendingPathComponent("scripts/x.py").path))
        #expect((try? String(contentsOf: skill.url.appendingPathComponent(".source"), encoding: .utf8))?.contains("github.com/o/r/tree/main/skills/pdf") == true)
        #expect(throws: ClaudistError.self) { try library.install(found[0], from: .init(owner: "o", repo: "r", ref: nil, path: "")) }
    }

    /// Downloads a real public repository; run with CLAUDIST_NETWORK_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_NETWORK_TESTS"] == "1")) func fetchesFromGitHub() async throws {
        let download = try await GitHubSkills.fetch(GitHubSkills.parse("https://github.com/anthropics/skills/tree/main/skills")!)
        defer { download.cleanup() }
        #expect(download.skills.count > 3)
        #expect(download.skills.contains { $0.name == "pdf" })
    }
}
