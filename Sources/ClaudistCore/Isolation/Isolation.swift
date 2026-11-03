import Foundation

/// A host path made visible inside an isolated run, at the same absolute path,
/// so paths in prompts, settings and arguments stay valid.
public struct IsolationMount: Sendable, Hashable {
    public var path: String
    public var readOnly: Bool

    public init(_ path: String, readOnly: Bool) {
        self.path = path
        self.readOnly = readOnly
    }
}

/// What to run, before an engine wraps it.
public struct LaunchSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var cwd: URL
    /// Environment of the launched process (host side).
    public var environment: [String: String]
    /// Variables the agent itself needs (secrets, databases, tool timeouts); an engine that
    /// doesn't inherit the host environment passes exactly these.
    public var agentEnvironment: [String]
    public var mounts: [IsolationMount]
    /// Unique per run; engines use it to name and later kill what they started.
    public var runId: ID

    public init(executable: URL, arguments: [String], cwd: URL, environment: [String: String],
                agentEnvironment: [String], mounts: [IsolationMount], runId: ID) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.agentEnvironment = agentEnvironment
        self.mounts = mounts
        self.runId = runId
    }
}

public enum EngineStatus: Sendable, Equatable {
    case ready
    /// Usable after `prepare()` (e.g. an image must be built).
    case needsPreparation(String)
    case unavailable(String)

    public var message: String {
        switch self {
        case .ready: "Ready"
        case .needsPreparation(let s), .unavailable(let s): s
        }
    }
}

/// A way to run an agent away from the host: Docker today; Podman, a VM or
/// Claude Code's own sandbox can be added as further engines.
public protocol IsolationEngine: Sendable {
    /// Stored in `agent.isolation`.
    var id: String { get }
    var title: String { get }
    var summary: String { get }

    func status() -> EngineStatus
    /// One-time setup (building an image). Long-running; `log` receives progress lines.
    func prepare(log: @escaping @Sendable (String) -> Void) throws
    /// Turns a host launch into a launch inside the engine.
    func wrap(_ spec: LaunchSpec) throws -> LaunchSpec
    /// Stops whatever `wrap` started for a run (the process alone may not be enough).
    func stop(runId: ID)
    /// Cleans up runs left over from a previous app session.
    func cleanUpOrphans()
    /// Claude Code's config folder of an agent working in `cwd`, when the engine keeps its own
    /// (sessions live there); nil when it uses the host's.
    func claudeConfigDir(forCwd cwd: URL) -> URL?
}

extension IsolationEngine {
    public func claudeConfigDir(forCwd cwd: URL) -> URL? { nil }
}

/// Claude Code sessions are files in a config folder (`projects/<cwd key>/<id>.jsonl`). The host and
/// each engine keep their own folder, so a conversation resumed in another place is carried over first.
public enum SessionFiles {
    /// The host's config folder: CLAUDE_CONFIG_DIR or ~/.claude.
    public static func hostConfigDir(environment: [String: String]) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Claude Code's folder name for a working directory: every non-alphanumeric character becomes "-".
    public static func projectKey(_ cwd: URL) -> String {
        String(cwd.path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    static func file(_ sessionId: String, cwd: URL, in configDir: URL) -> URL {
        configDir.appendingPathComponent("projects/\(projectKey(cwd))/\(sessionId).jsonl")
    }

    /// Makes the session available in `target`: copies the newest copy found in `sources` when the
    /// target has none or an older one. Returns false when the session exists nowhere.
    @discardableResult
    public static func carry(_ sessionId: String, cwd: URL, to target: URL, from sources: [URL]) throws -> Bool {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        let dest = file(sessionId, cwd: cwd, in: target)
        let newest = sources.filter { $0.standardizedFileURL != target.standardizedFileURL }
            .map { file(sessionId, cwd: cwd, in: $0) }
            .compactMap { url in modified(url).map { (url, $0) } }
            .max { $0.1 < $1.1 }
        guard let (source, date) = newest else { return fm.fileExists(atPath: dest.path) }
        if let current = modified(dest), current >= date { return true }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: source, to: dest)
        // Sub-agent transcripts and saved tool results sit in a folder named after the session.
        let extras = source.deletingPathExtension()
        let extrasDest = dest.deletingPathExtension()
        if fm.fileExists(atPath: extras.path) {
            try? fm.removeItem(at: extrasDest)
            try fm.copyItem(at: extras, to: extrasDest)
        }
        return true
    }
}

/// The registry of engines. One engine, chosen in the app settings, runs every agent;
/// `none` runs Claude Code directly on the host.
public enum Isolation {
    public static let none = "none"
    /// UserDefaults key of the chosen engine id.
    public static let settingKey = "isolation.engine"
    public static let defaultEngine = DockerEngine.engineId

    /// The engine id from the app settings.
    public static var selected: String {
        UserDefaults.standard.string(forKey: settingKey) ?? defaultEngine
    }

    public static func engines(paths: AppPaths, credentials: SecretStore) -> [any IsolationEngine] {
        [DockerEngine(paths: paths, credentials: credentials)]
    }

    public static func engine(_ id: String, paths: AppPaths, credentials: SecretStore) -> (any IsolationEngine)? {
        engines(paths: paths, credentials: credentials).first { $0.id == id }
    }

    /// Host paths an isolated run needs: the agent folder (read-write), its settings file,
    /// enabled skills (read-only), storage, attachments, file secrets and database files.
    public static func mounts(_ config: AgentLaunchConfig, settingsURL: URL, library: SkillLibrary,
                              secretFiles: URL?) -> [IsolationMount] {
        var mounts = [IsolationMount(config.agent.folderPath, readOnly: false),
                      IsolationMount(settingsURL.path, readOnly: true)]
        // Skills are symlinks into the library; their targets must exist inside too.
        for name in config.skills.sorted() {
            let dir = library.root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir.path) { mounts.append(IsolationMount(dir.path, readOnly: true)) }
        }
        for (storage, access) in config.storages {
            mounts.append(IsolationMount(storage.path, readOnly: access != .rw))
        }
        for a in config.attachments where a.exists {
            mounts.append(IsolationMount(a.path, readOnly: !a.writable))
        }
        if let secretFiles, FileManager.default.fileExists(atPath: secretFiles.path) {
            mounts.append(IsolationMount(secretFiles.path, readOnly: true))
        }
        // Scripts get database files read-only; changes go through the db tools served by the app.
        for g in config.databases where g.database.exists {
            mounts.append(IsolationMount(g.database.path, readOnly: true))
        }
        return dedupe(mounts)
    }

    /// Drops mounts already covered by a parent mount with the same or wider access.
    static func dedupe(_ mounts: [IsolationMount]) -> [IsolationMount] {
        var out: [IsolationMount] = []
        for m in mounts {
            let covered = mounts.contains { other in
                other != m && (m.path.hasPrefix(other.path + "/") || (other.path == m.path && !other.readOnly && m.readOnly))
                    && (!other.readOnly || m.readOnly)
            }
            if !covered && !out.contains(m) { out.append(m) }
        }
        return out
    }
}
