import Foundation

/// Weak Docker isolation that keeps the Mac clean of tools: each run gets its own container on the
/// host's network and process namespace, with read-write sudo and only the folders the run is allowed
/// (the same mounts as the isolated engine, so every grant, read-only flag and permission rule still holds).
///
/// What agents install persists: the container's system folders (/usr, /etc, /var, /opt) are named
/// volumes shared by every run, filled from the workbench image on first use. "Reset" removes them.
public struct DockerConnectedEngine: IsolationEngine {
    public static let engineId = "docker-connected"
    static let volumePrefix = "claudist-connected"
    static let imageRepository = "claudist-workbench"
    /// The container of the replaced "host access" engine, removed when this one is set up.
    static let legacyContainer = "claudist-workbench"
    /// System folders kept between runs: apt, pip, npm -g and /opt installs all land here.
    static let systemFolders = ["/usr", "/etc", "/var", "/opt"]

    let docker: DockerEngine

    public init(paths: AppPaths, credentials: SecretStore) {
        docker = DockerEngine(paths: paths, credentials: credentials)
    }

    public var id: String { Self.engineId }
    public var title: String { "Docker, host connected" }
    public var summary: String {
        "Weak isolation to keep the Mac free of tools: a Linux container on the host network and process space that sees only the agent's allowed folders. Agents can sudo-install software; it persists between runs."
    }

    /// Debian with Node, build tools and passwordless sudo.
    var image: String { "\(Self.imageRepository):1" }

    static func volume(_ folder: String) -> String { "\(volumePrefix)\(folder.replacingOccurrences(of: "/", with: "-"))" }

    // MARK: Status

    /// Claude Code version confirmed in the volumes during this app session (checking costs a container start).
    nonisolated(unsafe) private static var verifiedVersion: String?
    private static let lock = NSLock()

    public func status() -> EngineStatus {
        guard let exe = DockerEngine.dockerExecutable() else {
            return .unavailable("Docker is not installed. Install Docker Desktop (or OrbStack / Colima).")
        }
        guard let info = try? docker.run(exe, ["info", "--format", "{{.ServerVersion}}"]), info.status == 0 else {
            return .unavailable("Docker is installed but not running. Start Docker Desktop.")
        }
        guard imageExists(exe), Self.systemFolders.allSatisfy({ volumeExists(exe, Self.volume($0)) }) else {
            return .needsPreparation("The workbench will be set up on first use (a few minutes).")
        }
        let want = DockerEngine.claudeVersion()
        if want != "latest", Self.lock.withLock({ Self.verifiedVersion }) != want {
            guard let have = installedClaude(exe) else {
                return .needsPreparation("Claude Code \(want) will be installed in the workbench.")
            }
            if have != want { return .needsPreparation("Claude Code \(want) will be installed in the workbench (it has \(have)).") }
            Self.lock.withLock { Self.verifiedVersion = want }
        }
        return .ready
    }

    func imageExists(_ exe: URL) -> Bool {
        (try? docker.run(exe, ["image", "inspect", "--format", "{{.Id}}", image]))?.status == 0
    }

    func volumeExists(_ exe: URL, _ name: String) -> Bool {
        (try? docker.run(exe, ["volume", "inspect", "--format", "{{.Name}}", name]))?.status == 0
    }

    func installedClaude(_ exe: URL) -> String? {
        guard let r = try? docker.run(exe, ["run", "--rm"] + Self.systemMounts() + [image, "claude", "--version"]),
              r.status == 0 else { return nil }
        return r.out.split(separator: " ").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func systemMounts() -> [String] {
        // A named volume mounted empty is first filled with the image's content at that path.
        systemFolders.flatMap { ["--mount", "type=volume,source=\(volume($0)),target=\($0)"] }
    }

    // MARK: Prepare

    public func prepare(log: @escaping @Sendable (String) -> Void) throws {
        guard let exe = DockerEngine.dockerExecutable() else { throw ClaudistError.invalid("Docker is not installed") }
        if !imageExists(exe) {
            let dir = docker.paths.root.appendingPathComponent("containers/workbench-image", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.dockerfile.write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
            log("Building \(image)…")
            let status = try docker.stream(exe, ["build", "--label", "io.mindsw.claudist=1", "-t", image, dir.path], log: log)
            guard status == 0 else { throw ClaudistError.invalid("docker build failed (exit \(status)); see the log above") }
        }
        _ = try? docker.run(exe, ["rm", "-f", Self.legacyContainer])
        for folder in Self.systemFolders where !volumeExists(exe, Self.volume(folder)) {
            let r = try docker.run(exe, ["volume", "create", "--label", "io.mindsw.claudist=1", Self.volume(folder)])
            guard r.status == 0 else { throw ClaudistError.invalid("docker volume create failed: \(r.err)") }
        }
        let want = DockerEngine.claudeVersion()
        if want != "latest", installedClaude(exe) != want {
            log("Installing Claude Code \(want)…")
            let status = try docker.stream(exe, ["run", "--rm", "-u", "root"] + Self.systemMounts()
                                                + [image, "npm", "install", "-g", "@anthropic-ai/claude-code@\(want)"], log: log)
            guard status == 0 else { throw ClaudistError.invalid("Installing Claude Code failed (exit \(status))") }
        }
        Self.lock.withLock { Self.verifiedVersion = nil }
        log("The workbench is ready")
    }

    static let dockerfile = """
        FROM node:22-bookworm
        RUN apt-get update && apt-get install -y --no-install-recommends \\
              sudo ca-certificates curl wget git jq less procps ripgrep openssh-client sqlite3 \\
              build-essential python3 python3-pip python3-venv unzip zip xz-utils \\
            && rm -rf /var/lib/apt/lists/* \\
            && echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node && chmod 0440 /etc/sudoers.d/node
        RUN npm install -g @anthropic-ai/claude-code
        ENV DISABLE_AUTOUPDATER=1 \\
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
        USER node
        WORKDIR /home/node
        """

    // MARK: Wrap

    /// Told to the agent, so it installs tools in the container instead of asking the user.
    static let promptNote = """
        ## Workbench
        You run in a Linux (Debian) container, not on the Mac directly. You share the host's network and see the \
        container host's processes. Only the folders you were given are mounted (at their own paths); nothing else \
        of the Mac is visible. You may install what you need with `sudo apt-get install`, `pip`, `npm -g` and the \
        like: it stays in the workbench between runs and doesn't touch the Mac. macOS programs (open, brew, \
        osascript) are not available here. Your permission rules apply as usual.
        """

    public func wrap(_ spec: LaunchSpec) throws -> LaunchSpec {
        guard let exe = DockerEngine.dockerExecutable() else { throw ClaudistError.invalid("Docker is not installed") }
        let credential = try DockerEngine.credential(spec, credentials: docker.credentials)
        let home = docker.homeFolder(forCwd: spec.cwd)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        var args = Self.runArguments(spec, name: docker.containerName(spec.runId), home: home.path)
        // Values travel in the docker CLI's environment, never on its command line.
        var environment = ClaudeCLI.environment()
        environment[credential.name] = credential.value
        args += ["--env", credential.name]
        for name in spec.agentEnvironment.sorted() {
            guard let value = spec.environment[name] else { continue }
            environment[name] = value
            args += ["--env", name]
        }
        args += [image, "claude"] + Self.withPromptNote(spec.arguments)

        var wrapped = spec
        wrapped.executable = exe
        wrapped.arguments = args
        wrapped.environment = environment
        return wrapped
    }

    static func runArguments(_ spec: LaunchSpec, name: String, home: String) -> [String] {
        var args = ["run", "--rm", "-i", "--init",
                    "--name", name,
                    "--label", "\(DockerEngine.runLabel)=\(spec.runId)",
                    "--network", "host",
                    "--pid", "host",
                    "--workdir", spec.cwd.path,
                    "--mount", DockerEngine.bind(home, target: DockerEngine.containerHome, readOnly: false)]
        args += systemMounts()
        for m in spec.mounts {
            args += ["--mount", DockerEngine.bind(m.path, target: m.path, readOnly: m.readOnly)]
        }
        return args
    }

    static func withPromptNote(_ arguments: [String]) -> [String] {
        var args = arguments
        if let i = args.firstIndex(of: "--append-system-prompt"), i + 1 < args.count {
            args[i + 1] += "\n\n" + promptNote
        } else {
            args += ["--append-system-prompt", promptNote]
        }
        return args
    }

    /// Whether Docker Desktop shares the Mac's network with containers (Settings → Resources → Network).
    /// nil when it can't be told (another Docker, or a settings format this doesn't know).
    public static func desktopHostNetworking() -> Bool? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.docker/settings-store.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return settings["HostNetworkingEnabled"] as? Bool ?? false
    }

    public func claudeConfigDir(forCwd cwd: URL) -> URL? {
        docker.claudeConfigDir(forCwd: cwd)
    }

    // MARK: Stop

    public func stop(runId: ID) { docker.stop(runId: runId) }

    public func cleanUpOrphans() { docker.cleanUpOrphans() }

    /// Removes everything agents installed; the next run sets the workbench up again from the image.
    public func reset() throws {
        guard let exe = DockerEngine.dockerExecutable() else { return }
        let running = try docker.run(exe, ["ps", "-q", "--filter", "volume=\(Self.volume("/usr"))"])
        guard running.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudistError.invalid("Agents are running in the workbench; reset when they finish.")
        }
        let r = try docker.run(exe, ["volume", "rm", "-f"] + Self.systemFolders.map(Self.volume))
        guard r.status == 0 else { throw ClaudistError.invalid("docker volume rm failed: \(r.err)") }
        Self.lock.withLock { Self.verifiedVersion = nil }
    }
}
