import Foundation

/// Runs the whole Claude Code process of an agent in a Docker container.
///
/// - The image (Debian + Node + Claude Code + common CLI tools) is built locally from an
///   embedded Dockerfile, tagged with the host's Claude Code version.
/// - Only the paths the run needs are bind-mounted, at their host paths; skills, settings,
///   read-only storage and database files are mounted read-only.
/// - Each agent has its own home folder (Claude Code sessions, memory, onboarding state),
///   persisted on the host so `--resume` and memory keep working between runs.
/// - The subscription login comes from a long-lived token (`claude setup-token`) kept in the
///   Keychain and passed as `CLAUDE_CODE_OAUTH_TOKEN`; the host's own login never enters the container.
/// - The container runs as a non-root user with no capabilities; it has network access
///   (Claude Code needs the API).
public struct DockerEngine: IsolationEngine {
    public static let engineId = "docker"
    /// Keychain id of the subscription token used inside containers.
    public static let tokenSecretId = "claudist.container-oauth-token"

    /// Tokens copied from a terminal often carry the line breaks of its wrapping; a token never contains whitespace.
    public static func cleanToken(_ token: String) -> String {
        String(token.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }
    static let imageRepository = "claudist-agent"
    static let runLabel = "io.mindsw.claudist.run"
    static let containerHome = "/home/node"

    public let paths: AppPaths
    let credentials: SecretStore

    public init(paths: AppPaths, credentials: SecretStore) {
        self.paths = paths
        self.credentials = credentials
    }

    public var id: String { Self.engineId }
    public var title: String { "Docker" }
    public var summary: String {
        "Claude Code runs in a container and sees only the agent folder, its skills, storage, attachments and databases."
    }

    // MARK: Status

    public func status() -> EngineStatus {
        guard let docker = Self.dockerExecutable() else {
            return .unavailable("Docker is not installed. Install Docker Desktop (or OrbStack / Colima).")
        }
        guard let info = try? run(docker, ["info", "--format", "{{.ServerVersion}}"]), info.status == 0 else {
            return .unavailable("Docker is installed but not running. Start Docker Desktop.")
        }
        guard imageExists(docker) else {
            return .needsPreparation("The agent image \(image) will be built on first use (a few minutes).")
        }
        return .ready
    }

    public var image: String { "\(Self.imageRepository):\(Self.claudeVersion())" }

    func imageExists(_ docker: URL) -> Bool {
        (try? run(docker, ["image", "inspect", "--format", "{{.Id}}", image]))?.status == 0
    }

    // MARK: Prepare

    public func prepare(log: @escaping @Sendable (String) -> Void) throws {
        guard let docker = Self.dockerExecutable() else { throw ClaudistError.invalid("Docker is not installed") }
        if imageExists(docker) { return }
        let dir = paths.root.appendingPathComponent("containers/image", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.dockerfile.write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        log("Building \(image)…")
        let status = try stream(docker, ["build", "--build-arg", "CLAUDE_VERSION=\(Self.claudeVersion())",
                                         "--label", "io.mindsw.claudist=1", "-t", image, dir.path], log: log)
        guard status == 0 else { throw ClaudistError.invalid("docker build failed (exit \(status)); see the log above") }
        log("Image \(image) is ready")
    }

    static let dockerfile = """
        FROM node:22-bookworm-slim
        RUN apt-get update && apt-get install -y --no-install-recommends \\
              ca-certificates curl git jq less procps ripgrep openssh-client sqlite3 \\
              python3 python3-pip python3-venv \\
            && rm -rf /var/lib/apt/lists/*
        ARG CLAUDE_VERSION=latest
        RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION} || npm install -g @anthropic-ai/claude-code
        ENV DISABLE_AUTOUPDATER=1 \\
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
        USER node
        WORKDIR /home/node
        """

    // MARK: Wrap

    public func wrap(_ spec: LaunchSpec) throws -> LaunchSpec {
        guard let docker = Self.dockerExecutable() else { throw ClaudistError.invalid("Docker is not installed") }
        let credential = try Self.credential(spec, credentials: credentials)
        let home = homeFolder(forCwd: spec.cwd)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        var args = ["run", "--rm", "-i", "--init",
                    "--name", containerName(spec.runId),
                    "--label", "\(Self.runLabel)=\(spec.runId)",
                    "--security-opt", "no-new-privileges",
                    "--cap-drop", "ALL",
                    "--pids-limit", "2048",
                    "--workdir", spec.cwd.path,
                    "--mount", Self.bind(home.path, target: Self.containerHome, readOnly: false)]
        for m in spec.mounts {
            args += ["--mount", Self.bind(m.path, target: m.path, readOnly: m.readOnly)]
        }
        // Values travel in the docker CLI's environment, never on its command line.
        var environment = ClaudeCLI.environment()
        environment[credential.name] = credential.value
        args += ["--env", credential.name]
        for name in spec.agentEnvironment.sorted() {
            guard let value = spec.environment[name] else { continue }
            environment[name] = value
            args += ["--env", name]
        }
        args += [image, "claude"] + spec.arguments

        var wrapped = spec
        wrapped.executable = docker
        wrapped.arguments = args
        wrapped.environment = environment
        return wrapped
    }

    /// How the container signs in: the run's Claude account if it has one, else the container token.
    static func credential(_ spec: LaunchSpec, credentials: SecretStore) throws -> (name: String, value: String) {
        if let key = spec.credential["ANTHROPIC_API_KEY"], !key.isEmpty { return ("ANTHROPIC_API_KEY", key) }
        if let token = spec.credential["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return ("CLAUDE_CODE_OAUTH_TOKEN", token) }
        guard let token = try credentials.value(for: tokenSecretId).map(cleanToken), !token.isEmpty else {
            throw ClaudistError.invalid("No Claude subscription token for containers. Add it in Settings → Isolation, or give the agent a Claude account.")
        }
        return ("CLAUDE_CODE_OAUTH_TOKEN", token)
    }

    public func claudeConfigDir(forCwd cwd: URL) -> URL? {
        homeFolder(forCwd: cwd).appendingPathComponent(".claude", isDirectory: true)
    }

    /// Per-agent home inside the container, kept on the host.
    func homeFolder(forCwd cwd: URL) -> URL {
        let key = String(cwd.path.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
        return paths.root.appendingPathComponent("containers/homes/\(key)", isDirectory: true)
    }

    func containerName(_ runId: ID) -> String { "claudist-\(runId)" }

    static func bind(_ source: String, target: String, readOnly: Bool) -> String {
        // --mount fields are comma-separated; a comma inside a path would need CSV quoting.
        func quote(_ s: String) -> String { s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        return "type=bind,\(quote("source=" + source)),\(quote("target=" + target))" + (readOnly ? ",readonly" : "")
    }

    // MARK: Stop

    public func stop(runId: ID) {
        guard let docker = Self.dockerExecutable() else { return }
        _ = try? run(docker, ["kill", containerName(runId)])
    }

    public func cleanUpOrphans() {
        guard let docker = Self.dockerExecutable(),
              let r = try? run(docker, ["ps", "-q", "--filter", "label=\(Self.runLabel)"]), r.status == 0 else { return }
        let ids = r.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if !ids.isEmpty { _ = try? run(docker, ["kill"] + ids) }
    }

    // MARK: Helpers

    public static func dockerExecutable() -> URL? {
        var candidates = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker",
                          FileManager.default.homeDirectoryForCurrentUser.path + "/.orbstack/bin/docker"]
        for dir in (ClaudeCLI.environment()["PATH"] ?? "").split(separator: ":") { candidates.insert("\(dir)/docker", at: 0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Host Claude Code version, so containers behave like the host CLI.
    static func claudeVersion() -> String {
        guard let exe = try? ClaudeCLI.executable(),
              let r = try? ClaudeCLI.runSync(exe, ["--version"], env: ClaudeCLI.environment()) else { return "latest" }
        return r.out.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "latest"
    }

    func run(_ exe: URL, _ args: [String]) throws -> (status: Int32, out: String, err: String) {
        try ClaudeCLI.runSync(exe, args, env: ClaudeCLI.environment())
    }

    /// Runs a command and forwards its output line by line.
    func stream(_ exe: URL, _ args: [String], log: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = ClaudeCLI.environment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        var buffer = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                log(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty { log(String(decoding: buffer, as: UTF8.self)) }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
