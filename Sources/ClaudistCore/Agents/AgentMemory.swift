import Foundation

/// What an agent remembers, as Claude Code keeps it: instruction files in the agent's folder
/// (CLAUDE.md) and auto-memory per working folder, on the Mac (~/.claude) and in Docker's home.
public enum AgentMemory {
    public enum Kind: String, Sendable {
        /// CLAUDE.md files the agent reads at every start and may edit.
        case instructions
        /// Claude Code's auto-memory folder (`projects/<folder key>/memory`).
        case memory
    }

    public struct File: Sendable, Identifiable, Hashable {
        public var id: String { url.path }
        public var url: URL
        public var kind: Kind
        /// Where it lives: "Agent folder", "Mac", "Docker".
        public var place: String
        public var modified: Date
        public var size: Int
        public var name: String { url.lastPathComponent }
    }

    /// Auto-memory folders of an agent folder: the Mac's and the Docker home's.
    public static func memoryFolders(agentFolder: String, paths: AppPaths, environment: [String: String]) -> [(place: String, url: URL)] {
        let cwd = URL(fileURLWithPath: agentFolder, isDirectory: true)
        let key = SessionFiles.projectKey(cwd)
        let host = SessionFiles.hostConfigDir(environment: environment)
        let docker = paths.root.appendingPathComponent("containers/homes/\(key)/.claude", isDirectory: true)
        return [("Mac", host.appendingPathComponent("projects/\(key)/memory", isDirectory: true)),
                ("Docker", docker.appendingPathComponent("projects/\(key)/memory", isDirectory: true))]
    }

    public static func files(agentFolder: String, paths: AppPaths, environment: [String: String]) -> [File] {
        let fm = FileManager.default
        func file(_ url: URL, _ kind: Kind, _ place: String) -> File? {
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  v.isRegularFile == true else { return nil }
            return File(url: url, kind: kind, place: place, modified: v.contentModificationDate ?? .distantPast, size: v.fileSize ?? 0)
        }
        let folder = URL(fileURLWithPath: agentFolder, isDirectory: true)
        var out = ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md"].compactMap {
            file(folder.appendingPathComponent($0), .instructions, "Agent folder")
        }
        for (place, dir) in memoryFolders(agentFolder: agentFolder, paths: paths, environment: environment) {
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            // The index first, then the rest by name.
            for name in names.sorted(by: { ($0 == "MEMORY.md" ? 0 : 1, $0) < ($1 == "MEMORY.md" ? 0 : 1, $1) }) {
                if let f = file(dir.appendingPathComponent(name), .memory, place) { out.append(f) }
            }
        }
        return out
    }
}
