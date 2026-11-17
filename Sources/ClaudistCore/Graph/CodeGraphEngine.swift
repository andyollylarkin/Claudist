import CryptoKit
import Foundation

/// Experimental: code knowledge graphs of folders.
///
/// The extraction engine is graphify (tree-sitter AST, ~40 languages), installed by the app into
/// its own virtualenv at a pinned version. It runs code-only: no LLM backend, no query log, a clean
/// environment, and its output lives in the app's data folder, never in the user's repository.
/// Everything above the extraction (queries, views, the chat widget) is Claudist's own.
public enum CodeGraph {
    /// UserDefaults switch for the experimental feature.
    public static let enabledKey = "experimental.codeGraph"
    public static let graphifyVersion = "0.9.111"
    public static let package = "graphifyy"

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

public struct CodeGraphEngine: Sendable {
    public let root: URL

    public init(paths: AppPaths) {
        root = paths.graphs
    }

    var runtime: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    var venv: URL { runtime.appendingPathComponent("venv", isDirectory: true) }
    var versionFile: URL { runtime.appendingPathComponent("version.txt") }
    public var executable: URL { venv.appendingPathComponent("bin/graphify") }
    public var views: URL { root.appendingPathComponent("views", isDirectory: true) }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path) && installedVersion != nil
    }

    public var installedVersion: String? {
        (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Installed, but not the version this build of Claudist expects.
    public var needsUpdate: Bool { isInstalled && installedVersion != CodeGraph.graphifyVersion }

    // MARK: Runtime

    /// A Python 3.10+ interpreter on this Mac.
    public static func findPython() -> URL? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for minor in (10...14).reversed() {
            candidates += ["/opt/homebrew/bin/python3.\(minor)", "/usr/local/bin/python3.\(minor)",
                           "/Library/Frameworks/Python.framework/Versions/3.\(minor)/bin/python3"]
        }
        candidates.append("/usr/bin/python3")
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted && FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard let out = try? Shell.run(url, ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"], timeout: 20),
                  out.status == 0 else { continue }
            let parts = out.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
            if parts.count == 2, parts[0] == 3, parts[1] >= 10 { return url }
        }
        return nil
    }

    /// Creates the private virtualenv and installs graphify at the pinned version (a minute or so).
    public func install(log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        guard let python = Self.findPython() else {
            throw ClaudistError.invalid("The code graph needs Python 3.10 or newer. Install it (for example `brew install python`) and try again.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        if fm.fileExists(atPath: venv.path) { try fm.removeItem(at: venv) }
        try? fm.removeItem(at: versionFile)
        log("Creating a Python environment with \(python.path)…")
        let created = try Shell.run(python, ["-m", "venv", venv.path], environment: Self.environment(), timeout: 300)
        guard created.status == 0 else { throw ClaudistError.invalid("Could not create the environment: " + Self.tail(created.output)) }
        log("Installing graphify \(CodeGraph.graphifyVersion)…")
        let pip = venv.appendingPathComponent("bin/python")
        let installed = try Shell.run(pip, ["-m", "pip", "install", "--disable-pip-version-check", "--quiet",
                                            "\(CodeGraph.package)==\(CodeGraph.graphifyVersion)"],
                                      environment: Self.environment(), timeout: 900)
        guard installed.status == 0, fm.isExecutableFile(atPath: executable.path) else {
            throw ClaudistError.invalid("Could not install graphify: " + Self.tail(installed.output))
        }
        try CodeGraph.graphifyVersion.write(to: versionFile, atomically: true, encoding: .utf8)
        log("Graph engine ready")
    }

    public func uninstall() throws {
        if FileManager.default.fileExists(atPath: runtime.path) { try FileManager.default.removeItem(at: runtime) }
    }

    // MARK: Graphs

    /// Data folder of one source folder's graph.
    public func store(for folder: String) -> URL {
        let digest = SHA256.hash(data: Data(Self.normalize(folder).utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("folders/\(name)", isDirectory: true)
    }

    public func graphFile(for folder: String) -> URL {
        store(for: folder).appendingPathComponent("out/graph.json")
    }

    /// Builds or incrementally updates the graph of `folder` (code only, no LLM) and returns graph.json.
    @discardableResult
    public func build(folder: String) throws -> URL {
        guard isInstalled else { throw ClaudistError.invalid("The graph engine isn't installed; turn on the code graph in Settings → Experimental") }
        let folder = Self.normalize(folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            throw ClaudistError.invalid("No folder at \(folder)")
        }
        let lock = Self.locks.lock(for: folder)
        lock.lock()
        defer { lock.unlock() }
        let dir = store(for: folder)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try folder.write(to: dir.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
        var env = Self.environment()
        env["GRAPHIFY_OUT"] = out.path
        // Deleted code must leave the graph too.
        env["GRAPHIFY_FORCE"] = "1"
        let result = try Shell.run(executable, ["update", folder], cwd: URL(fileURLWithPath: folder),
                                   environment: env, timeout: 1800)
        let file = out.appendingPathComponent("graph.json")
        guard result.status == 0, FileManager.default.fileExists(atPath: file.path) else {
            throw ClaudistError.invalid("graphify couldn't map \(folder): " + Self.tail(result.output))
        }
        return file
    }

    /// Clean environment: no API keys reach graphify, no LLM backend, no query log.
    static func environment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "GRAPHIFY_BACKEND": "none",
            "GRAPHIFY_QUERY_LOG_DISABLE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PIP_NO_INPUT": "1",
        ]
    }

    static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func tail(_ text: String, lines: Int = 8) -> String {
        text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    private static let locks = Locks()
    private final class Locks: @unchecked Sendable {
        private let lock = NSLock()
        private var byPath: [String: NSLock] = [:]
        func lock(for path: String) -> NSLock {
            lock.withLock {
                if let l = byPath[path] { return l }
                let l = NSLock()
                byPath[path] = l
                return l
            }
        }
    }
}

/// Runs a command to completion and collects its combined output.
enum Shell {
    struct Result { var status: Int32; var output: String }

    static func run(_ executable: URL, _ arguments: [String], cwd: URL? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let buffer = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ClaudistError.invalid("\(executable.lastPathComponent) took longer than \(Int(timeout))s and was stopped")
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return Result(status: process.terminationStatus, output: buffer.text)
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
