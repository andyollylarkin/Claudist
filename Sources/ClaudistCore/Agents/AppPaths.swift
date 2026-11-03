import Foundation

public struct AppPaths: Sendable {
    /// ~/Library/Application Support/Claudist
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Data folder keeps its original name: agent folders, skill symlinks and
            // Claude Code's per-folder memory all refer to absolute paths inside it.
            .appendingPathComponent("AgentDesk", isDirectory: true)
    }

    public var database: URL { root.appendingPathComponent("db.sqlite") }
    /// Shared skill library: one folder per skill with SKILL.md inside.
    public var skills: URL { root.appendingPathComponent("skills", isDirectory: true) }
    /// Default parent for agent project folders.
    public var agents: URL { root.appendingPathComponent("agents", isDirectory: true) }
    public var plugins: URL { root.appendingPathComponent("plugins", isDirectory: true) }
    /// SQLite databases created in the app.
    public var databases: URL { root.appendingPathComponent("databases", isDirectory: true) }
    /// Working folder of the built-in assistant.
    public var assistant: URL { root.appendingPathComponent("assistant", isDirectory: true) }

    public func ensure() throws {
        for dir in [root, skills, agents, plugins, databases, assistant] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let s = name.lowercased().replacingOccurrences(of: " ", with: "-")
            .unicodeScalars.filter { allowed.contains($0) }
        return s.isEmpty ? "agent" : String(String.UnicodeScalarView(s))
    }
}
