import Foundation

public struct AppPaths: Sendable {
    /// ~/Library/Application Support/AgentDesk
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDesk", isDirectory: true)
    }

    public var database: URL { root.appendingPathComponent("db.sqlite") }
    /// Shared skill library: one folder per skill with SKILL.md inside.
    public var skills: URL { root.appendingPathComponent("skills", isDirectory: true) }
    /// Default parent for agent project folders.
    public var agents: URL { root.appendingPathComponent("agents", isDirectory: true) }
    public var plugins: URL { root.appendingPathComponent("plugins", isDirectory: true) }

    public func ensure() throws {
        for dir in [root, skills, agents, plugins] {
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
