import Foundation

/// Locates the `claude` executable and the user's login-shell environment.
/// GUI apps start with a minimal PATH, so we ask the login shell once.
public enum ClaudeCLI {
    public struct AuthStatus: Decodable, Sendable {
        public var loggedIn: Bool
        public var authMethod: String?
        public var email: String?
        public var orgName: String?
        public var subscriptionType: String?
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var env: [String: String]?
        var executable: URL?
    }

    public static func environment() -> [String: String] {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let env = cache.env { return env }
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        if let path = try? runSync(URL(fileURLWithPath: shell), ["-lc", "printf %s \"$PATH\""], env: env).out,
           !path.isEmpty {
            env["PATH"] = path
        }
        // A stray API key would silently switch Claude Code from subscription login to API billing.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        cache.env = env
        return env
    }

    public static func executable() throws -> URL {
        if let exe = cache.lock.withLock({ cache.executable }) { return exe }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        for dir in (environment()["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/claude")
        }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AgentDeskError.claudeNotFound
        }
        let url = URL(fileURLWithPath: found)
        cache.lock.withLock { cache.executable = url }
        return url
    }

    public static func authStatus() throws -> AuthStatus {
        let r = try runSync(executable(), ["auth", "status", "--json"], env: environment())
        return try JSONDecoder().decode(AuthStatus.self, from: Data(r.out.utf8))
    }

    /// Starts the browser-based subscription login. Returns when the CLI finishes.
    public static func login() throws {
        let r = try runSync(executable(), ["auth", "login", "--claudeai"], env: environment())
        if r.status != 0 { throw AgentDeskError.invalid(r.err.isEmpty ? r.out : r.err) }
    }

    public static func logout() throws {
        _ = try runSync(executable(), ["auth", "logout"], env: environment())
    }

    @discardableResult
    static func runSync(_ exe: URL, _ args: [String], env: [String: String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}
