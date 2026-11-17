import Foundation
import Testing
@testable import ClaudistCore

struct DockerConnectedEngineTests {
    func spec() -> LaunchSpec {
        LaunchSpec(executable: URL(fileURLWithPath: "/usr/bin/claude"), arguments: ["-p"],
                   cwd: URL(fileURLWithPath: "/Users/me/agents/a"), environment: [:], agentEnvironment: [],
                   mounts: [IsolationMount("/Users/me/agents/a", readOnly: false), IsolationMount("/Users/me/docs", readOnly: true)],
                   runId: "r1")
    }

    @Test func runSharesHostButMountsOnlyAllowedFolders() {
        let args = DockerConnectedEngine.runArguments(spec(), name: "claudist-r1", home: "/data/homes/a")
        let joined = args.joined(separator: " ")
        #expect(joined.contains("--network host"))
        #expect(joined.contains("--pid host"))
        #expect(joined.contains("type=bind,source=/Users/me/agents/a,target=/Users/me/agents/a"))
        #expect(joined.contains("type=bind,source=/Users/me/docs,target=/Users/me/docs,readonly"))
        #expect(!joined.contains("source=/Users,"))
        #expect(joined.contains("type=volume,source=claudist-connected-usr,target=/usr"))
        #expect(joined.contains("type=volume,source=claudist-connected-etc,target=/etc"))
        // sudo must keep working: no dropped capabilities, no no-new-privileges.
        #expect(!joined.contains("cap-drop") && !joined.contains("no-new-privileges"))
    }

    @Test func agentsAreToldTheyMayInstall() {
        let added = DockerConnectedEngine.withPromptNote(["-p", "--append-system-prompt", "Be brief"])
        #expect(added[2].hasPrefix("Be brief\n\n## Workbench"))
        #expect(DockerConnectedEngine.withPromptNote(["-p"]).suffix(2).first == "--append-system-prompt")
    }

    @Test func replacedHostAccessEngineMapsToConnected() {
        var task = TaskItem(projectId: "p", content: "t")
        task.isolation = "docker-host"
        #expect(Isolation.engineId(for: task) == DockerConnectedEngine.engineId)
        task.runOnHost = true
        #expect(Isolation.engineId(for: task) == Isolation.none)
    }

    @Test func registeredAsAnEngine() {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(Isolation.engine(DockerConnectedEngine.engineId, paths: paths, credentials: MemorySecretStore()) != nil)
    }

    /// Sets up the real workbench and runs a container; run with CLAUDIST_DOCKER_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_DOCKER_TESTS"] == "1")) func workbenchRuns() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("wbc-\(UUID().uuidString)"))
        let engine = DockerConnectedEngine(paths: paths, credentials: MemorySecretStore())
        try engine.prepare { print($0) }
        let exe = try #require(DockerEngine.dockerExecutable())
        let allowed = paths.root.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.root.appendingPathComponent("home"), withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var s = spec()
        s.cwd = allowed
        s.mounts = [IsolationMount(allowed.path, readOnly: false)]
        let args = DockerConnectedEngine.runArguments(s, name: "claudist-test-\(UUID().uuidString.prefix(8))", home: paths.root.appendingPathComponent("home").path)
        let script = "touch marker && sudo -n true && echo sudo-ok && (ls -d '\(home)/Documents' 2>/dev/null || echo hidden) && which claude"
        let r = try engine.docker.run(exe, args + [engine.image, "sh", "-c", script])
        print(r.out, r.err)
        #expect(r.status == 0)
        #expect(r.out.contains("sudo-ok") && r.out.contains("hidden"))
        #expect(FileManager.default.fileExists(atPath: allowed.appendingPathComponent("marker").path))
    }
}
