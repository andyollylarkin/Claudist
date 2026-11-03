import Foundation
import Testing
@testable import ClaudistCore

struct SkillGeneratorTests {
    let root: URL
    let lib: SkillLibrary

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skillgen-\(newID())")
        try AppPaths(root: root).ensure()
        lib = SkillLibrary(root: AppPaths(root: root).skills)
    }

    @Test func pathsStayInsideDraft() throws {
        let draft = try lib.makeDraft()
        #expect(SkillGenerator.isInside("SKILL.md", draft))
        #expect(SkillGenerator.isInside("scripts/new/tool.py", draft))
        #expect(SkillGenerator.isInside(draft.appendingPathComponent("scripts/x.py").path, draft))
        #expect(!SkillGenerator.isInside("../other/SKILL.md", draft))
        #expect(!SkillGenerator.isInside(draft.path + "/../escape.txt", draft))
        #expect(!SkillGenerator.isInside("/etc/hosts", draft))
        #expect(!SkillGenerator.isInside(draft.path + "-sibling/x", draft))
        // A symlink inside the draft pointing out of it doesn't count as inside.
        try FileManager.default.createSymbolicLink(at: draft.appendingPathComponent("link"), withDestinationURL: root)
        #expect(!SkillGenerator.isInside("link/secret.txt", draft))
    }

    @Test func permissionPolicy() throws {
        let draft = try lib.makeDraft()
        var options = SkillGenerator.Options()
        let write = JSONValue.object(["file_path": .string(draft.appendingPathComponent("scripts/a.py").path)])
        let outside = JSONValue.object(["file_path": .string("/Users/someone/.ssh/id_rsa")])
        #expect(SkillGenerator.decide(tool: "Write", input: write, draft: draft, options: options) == .allow)
        #expect(SkillGenerator.decide(tool: "Read", input: outside, draft: draft, options: options) != .allow)
        #expect(SkillGenerator.decide(tool: "Glob", input: .object([:]), draft: draft, options: options) == .allow)
        #expect(SkillGenerator.decide(tool: "Bash", input: .object([:]), draft: draft, options: options) != .ask)
        #expect(SkillGenerator.decide(tool: "Task", input: .object([:]), draft: draft, options: options) != .allow)
        options.allowBash = true
        #expect(SkillGenerator.decide(tool: "Bash", input: .object([:]), draft: draft, options: options) == .ask)
        options.allowWeb = false
        #expect(SkillGenerator.decide(tool: "WebFetch", input: .object([:]), draft: draft, options: options) != .allow)
        #expect(!SkillGenerator.tools(options).contains("Web"))
        #expect(SkillGenerator.tools(options).contains("Bash"))
    }

    @Test func argumentsAndLanguage() {
        var options = SkillGenerator.Options()
        var args = SkillGenerator.arguments(options)
        #expect(args.contains("--restricted") && args.contains("--safe-mode") && args.contains("--no-session-persistence"))
        #expect(!args.contains("--model"))
        let prompt = args[args.firstIndex(of: "--append-system-prompt")! + 1]
        #expect(prompt.contains("Language: Python"))
        #expect(prompt.contains("argparse"))

        options.language = "Go"
        options.model = "opus"
        args = SkillGenerator.arguments(options)
        #expect(args[args.firstIndex(of: "--append-system-prompt")! + 1].contains("Language: Go"))
        #expect(args[args.firstIndex(of: "--model")! + 1] == "opus")

        options.language = "  "
        #expect(SkillGenerator.language(options) == "Python")
    }

    @Test func parsesRequiredSecrets() {
        let md = """
            # Weather
            Use `scripts/get.py`.

            ## Required secrets
            - `WEATHER_API_KEY` — API key
            * `PROXY_URL`: optional proxy, not `lowercase`
            - `WEATHER_API_KEY` again

            ## Notes
            - `NOT_A_SECRET` here
            """
        #expect(SkillGenerator.requiredSecrets(md) == ["WEATHER_API_KEY", "PROXY_URL"])
    }

    @Test func installsNewDraftWithUniqueName() throws {
        _ = try lib.create(name: "weather", description: "old")
        let draft = try lib.makeDraft()
        try "---\nname: weather\ndescription: new\n---\n".write(to: draft.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: draft.appendingPathComponent("scripts/__pycache__"), withIntermediateDirectories: true)
        try "#!/usr/bin/env python3\n".write(to: draft.appendingPathComponent("scripts/get.py"), atomically: true, encoding: .utf8)

        let skill = try lib.installDraft(draft)
        #expect(skill.name == "weather-2")
        #expect(skill.description == "new")
        #expect(lib.files(of: skill).map(\.path) == ["scripts", "scripts/get.py"])
        #expect(lib.files(of: skill).last?.isExecutable == true)
        #expect(!FileManager.default.fileExists(atPath: draft.path))
    }

    @Test func editReplacesSkillInPlace() throws {
        let skill = try lib.create(name: "notes", description: "v1")
        try "old".write(to: skill.url.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let draft = try lib.makeDraft(from: skill)
        #expect(FileManager.default.fileExists(atPath: draft.appendingPathComponent("old.txt").path))
        try FileManager.default.removeItem(at: draft.appendingPathComponent("old.txt"))
        try "---\nname: renamed\ndescription: v2\n---\n".write(to: draft.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let updated = try lib.installDraft(draft, replacing: skill)
        #expect(updated.name == "notes")   // folder kept: agent symlinks point at it
        #expect(updated.description == "v2")
        #expect(lib.files(of: updated).isEmpty)
        #expect(lib.list().count == 1)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: lib.draftsRoot.path))?.isEmpty == true)
    }

    @Test func draftWithoutSkillMDIsRejected() throws {
        let draft = try lib.makeDraft()
        #expect(throws: ClaudistError.self) { try lib.installDraft(draft) }
        lib.discardDraft(draft)
        #expect(!FileManager.default.fileExists(atPath: draft.path))
    }
}

/// Run with: CLAUDIST_E2E=1 swift test --filter SkillGeneratorE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1"))
struct SkillGeneratorE2ETests {
    /// Claude writes SKILL.md and a Python tool into the draft; nothing lands outside it.
    @Test(.timeLimit(.minutes(5))) func generatesSkillWithPythonTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudist-gen-\(newID())")
        try AppPaths(root: root).ensure()
        let lib = SkillLibrary(root: AppPaths(root: root).skills)
        let draft = try lib.makeDraft()
        var options = SkillGenerator.Options()
        options.model = "haiku"
        options.allowWeb = false

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var process: AgentProcess?
            var denied: [String] = []
            var result: String?
        }
        let box = Box()
        let done = AsyncStream<Void>.makeStream()
        let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: SkillGenerator.arguments(options),
                                   cwd: draft, environment: ClaudeCLI.environment()) { event in
            let p: AgentProcess? = box.lock.withLock { box.process }
            switch event {
            case .permission(let req):
                switch SkillGenerator.decide(tool: req.toolName, input: req.input, draft: draft, options: options) {
                case .allow: p?.respond(req, .allow)
                default:
                    box.lock.withLock { box.denied.append(req.toolName) }
                    p?.respond(req, .deny("not in test"))
                }
            case .message(let kind, let json):
                if kind.hasPrefix("result") {
                    box.lock.withLock { box.result = kind + " " + json.prefix(300) }
                    p?.closeInput()
                }
            case .exited:
                done.continuation.finish()
            case .mcp, .stderr:
                break
            }
        }
        box.lock.withLock { box.process = process }
        try process.start()
        process.send(SkillGenerator.firstMessage(
            request: "A skill that converts temperatures between Celsius and Fahrenheit with one small tool. Keep it minimal.",
            editing: nil))
        for await _ in done.stream {}

        let files = lib.draftFiles(draft).map(\.path)
        print("result:", box.lock.withLock { box.result ?? "-" }, "files:", files, "denied:", box.lock.withLock { box.denied })
        #expect(files.contains("SKILL.md"))
        #expect(files.contains { $0.hasPrefix("scripts/") && $0.hasSuffix(".py") })
        let skill = try lib.installDraft(draft)
        #expect(lib.files(of: skill).contains { $0.isExecutable })
        print(lib.readSkillMD(skill))
    }
}
