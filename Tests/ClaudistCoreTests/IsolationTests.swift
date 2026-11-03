import Foundation
import Testing
@testable import ClaudistCore

struct IsolationTests {
    let root: URL
    let paths: AppPaths
    let secrets = MemorySecretStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-\(newID())")
        paths = AppPaths(root: root)
        try paths.ensure()
    }

    private func config() throws -> (AgentLaunchConfig, URL) {
        let fm = FileManager.default
        let agentDir = root.appendingPathComponent("agents/writer")
        let storage = root.appendingPathComponent("docs")
        let nested = storage.appendingPathComponent("drafts")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.skills.appendingPathComponent("pdf"), withIntermediateDirectories: true)
        let attached = root.appendingPathComponent("in.csv")
        try "a,b".write(to: attached, atomically: true, encoding: .utf8)

        var config = AgentLaunchConfig(agent: Agent(name: "Writer", folderPath: agentDir.path), skills: ["pdf", "missing"],
                                       storages: [(Storage(name: "Docs", path: storage.path), .ro)])
        var a1 = TaskAttachment(taskId: "t", url: attached)
        a1.writable = false
        var a2 = TaskAttachment(taskId: "t", url: nested)
        a2.writable = true
        config.attachments = [a1, a2]
        return (config, root.appendingPathComponent("settings/s.json"))
    }

    @Test func mountsWhatTheRunNeedsOnly() throws {
        let (config, settings) = try config()
        let mounts = Isolation.mounts(config, settingsURL: settings, library: SkillLibrary(root: paths.skills), secretFiles: nil)
        let byPath = Dictionary(uniqueKeysWithValues: mounts.map { ($0.path, $0.readOnly) })
        #expect(byPath[config.agent.folderPath] == false)
        #expect(byPath[settings.path] == true)
        #expect(byPath[paths.skills.appendingPathComponent("pdf").path] == true)
        #expect(byPath[paths.skills.appendingPathComponent("missing").path] == nil)
        #expect(byPath[root.appendingPathComponent("docs").path] == true)
        // A writable attachment inside read-only storage keeps its own rw mount.
        #expect(byPath[root.appendingPathComponent("docs/drafts").path] == false)
        #expect(byPath[root.appendingPathComponent("in.csv").path] == true)
        #expect(byPath[paths.skills.path] == nil, "the whole library is not exposed")
    }

    @Test func dedupesCoveredMounts() {
        let m = Isolation.dedupe([IsolationMount("/a", readOnly: false), IsolationMount("/a/b", readOnly: true),
                                  IsolationMount("/a", readOnly: true), IsolationMount("/c", readOnly: true),
                                  IsolationMount("/c/d", readOnly: false)])
        #expect(m == [IsolationMount("/a", readOnly: false), IsolationMount("/c", readOnly: true), IsolationMount("/c/d", readOnly: false)])
    }

    @Test func dockerWrapKeepsValuesOffTheCommandLine() throws {
        guard DockerEngine.dockerExecutable() != nil else { return }
        try secrets.setValue("sk-ant-oat-test", for: DockerEngine.tokenSecretId)
        let engine = DockerEngine(paths: paths, credentials: secrets)
        let spec = LaunchSpec(executable: URL(fileURLWithPath: "/usr/local/bin/claude"), arguments: ["-p", "--verbose"],
                              cwd: URL(fileURLWithPath: "/Users/x/Agent Folder"),
                              environment: ["GITHUB_TOKEN": "ghp_secret", "HOME": "/Users/x", "ANTHROPIC_API_KEY": "nope"],
                              agentEnvironment: ["GITHUB_TOKEN"],
                              mounts: [IsolationMount("/Users/x/Agent Folder", readOnly: false), IsolationMount("/data,odd", readOnly: true)],
                              runId: "r1")
        let wrapped = try engine.wrap(spec)
        let args = wrapped.arguments
        #expect(wrapped.executable.lastPathComponent == "docker")
        #expect(args.starts(with: ["run", "--rm", "-i"]))
        #expect(args.contains("claudist-r1"))
        #expect(args.contains("type=bind,source=/Users/x/Agent Folder,target=/Users/x/Agent Folder"))
        #expect(args.contains("type=bind,\"source=/data,odd\",\"target=/data,odd\",readonly"))
        #expect(args.contains("GITHUB_TOKEN") && args.contains("CLAUDE_CODE_OAUTH_TOKEN"))
        #expect(!args.joined(separator: " ").contains("ghp_secret"))
        #expect(!args.joined(separator: " ").contains("sk-ant-oat-test"))
        #expect(!args.contains("ANTHROPIC_API_KEY") && !args.contains("HOME"))
        #expect(wrapped.environment["GITHUB_TOKEN"] == "ghp_secret")
        #expect(wrapped.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat-test")
        #expect(Array(args.suffix(3)) == ["claude", "-p", "--verbose"])
        #expect(args.contains("--cap-drop") && args.contains("no-new-privileges"))
    }

    @Test func tokenLoosesTerminalLineBreaks() throws {
        #expect(DockerEngine.cleanToken(" sk-ant-oat01-abc\ndef\r\n ghi \n") == "sk-ant-oat01-abcdefghi")
        guard DockerEngine.dockerExecutable() != nil else { return }
        try secrets.setValue("sk-ant-oat01-abc\ndef", for: DockerEngine.tokenSecretId)
        let spec = LaunchSpec(executable: URL(fileURLWithPath: "/x"), arguments: [], cwd: root, environment: [:],
                              agentEnvironment: [], mounts: [], runId: "r")
        let wrapped = try DockerEngine(paths: paths, credentials: secrets).wrap(spec)
        #expect(wrapped.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-abcdef")
    }

    @Test func dockerWithoutTokenIsUnavailable() throws {
        guard DockerEngine.dockerExecutable() != nil else { return }
        let engine = DockerEngine(paths: paths, credentials: MemorySecretStore())
        let spec = LaunchSpec(executable: URL(fileURLWithPath: "/bin/true"), arguments: [], cwd: root, environment: [:],
                              agentEnvironment: [], mounts: [], runId: "r")
        #expect(throws: ClaudistError.self) { try engine.wrap(spec) }
        if case .ready = engine.status() { Issue.record("no token must not be ready") }
    }

    @Test func engineSettingDefaultsToDocker() {
        #expect(Isolation.defaultEngine == "docker")
        #expect(Isolation.engine("docker", paths: paths, credentials: secrets)?.title == "Docker")
        #expect(Isolation.engine("nope", paths: paths, credentials: secrets) == nil)
    }
}

/// Builds the real image and checks the container sees only its mounts.
/// Run with: CLAUDIST_DOCKER_E2E=1 swift test --filter DockerE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_DOCKER_E2E"] == "1"))
struct DockerE2ETests {
    @Test(.timeLimit(.minutes(15))) func imageRunsClaudeWithOnlyMountedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudist-docker-\(newID())")
        let paths = AppPaths(root: root)
        try paths.ensure()
        let secrets = MemorySecretStore()
        try secrets.setValue("not-a-real-token", for: DockerEngine.tokenSecretId)
        let engine = DockerEngine(paths: paths, credentials: secrets)
        try engine.prepare { print("build:", $0) }

        let work = root.appendingPathComponent("agent")
        let readonly = root.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readonly, withIntermediateDirectories: true)
        try "hello".write(to: readonly.appendingPathComponent("in.txt"), atomically: true, encoding: .utf8)

        // Swap `claude` for a shell to probe the container.
        let probe = """
            claude --version
            echo "ro=$(cat \(readonly.path)/in.txt)"
            touch \(readonly.path)/x 2>/dev/null && echo "ro-write=yes" || echo "ro-write=no"
            touch \(work.path)/made && echo "rw-write=yes"
            test -e \(FileManager.default.homeDirectoryForCurrentUser.path)/.ssh && echo "ssh=visible" || echo "ssh=hidden"
            echo "user=$(id -un) secret=$PROBE_SECRET"
            """
        var spec = LaunchSpec(executable: URL(fileURLWithPath: "/x"), arguments: [], cwd: work,
                              environment: ["PROBE_SECRET": "s3"], agentEnvironment: ["PROBE_SECRET"],
                              mounts: [IsolationMount(work.path, readOnly: false), IsolationMount(readonly.path, readOnly: true)],
                              runId: "e2e-\(newID())")
        spec = try engine.wrap(spec)
        let claudeIndex = try #require(spec.arguments.lastIndex(of: "claude"))
        let args = Array(spec.arguments[..<claudeIndex]) + ["bash", "-c", probe]
        let r = try ClaudeCLI.runSync(spec.executable, args, env: spec.environment)
        print(r.out, r.err)
        #expect(r.status == 0)
        #expect(r.out.contains("(Claude Code)"))
        #expect(r.out.contains("ro=hello"))
        #expect(r.out.contains("ro-write=no"))
        #expect(r.out.contains("rw-write=yes"))
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("made").path))
        #expect(r.out.contains("ssh=hidden"))
        #expect(r.out.contains("user=node secret=s3"))
    }
}

struct SessionFilesTests {
    @Test func carriesSessionsBetweenConfigFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(newID())", isDirectory: true)
        let host = root.appendingPathComponent("host/.claude")
        let docker = root.appendingPathComponent("docker/.claude")
        let cwd = URL(fileURLWithPath: "/Users/x/Library/Application Support/AgentDesk/agents/dev")
        #expect(SessionFiles.projectKey(cwd) == "-Users-x-Library-Application-Support-AgentDesk-agents-dev")

        let src = docker.appendingPathComponent("projects/\(SessionFiles.projectKey(cwd))/s1.jsonl")
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent().appendingPathComponent("s1/subagents"),
                                                withIntermediateDirectories: true)
        try "{\"a\":1}\n".write(to: src, atomically: true, encoding: .utf8)

        #expect(try SessionFiles.carry("s1", cwd: cwd, to: host, from: [host, docker]))
        let dest = host.appendingPathComponent("projects/\(SessionFiles.projectKey(cwd))/s1.jsonl")
        #expect(try String(contentsOf: dest, encoding: .utf8) == "{\"a\":1}\n")
        #expect(FileManager.default.fileExists(atPath: dest.deletingPathExtension().appendingPathComponent("subagents").path))
        // Already there and current: nothing to do; unknown sessions are reported.
        #expect(try SessionFiles.carry("s1", cwd: cwd, to: host, from: [host, docker]))
        #expect(try !SessionFiles.carry("nope", cwd: cwd, to: host, from: [host, docker]))
    }
}
