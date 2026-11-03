import Foundation

/// The user's notes: a folder of Markdown files in Obsidian's format (`[[wikilinks]]`, `#tags`,
/// YAML frontmatter), so the same folder can be an Obsidian vault. Files on disk are the source of truth.
public struct NotesVault: Sendable {
    public struct Note: Sendable, Identifiable, Hashable, Codable {
        public var id: String { path }
        /// Relative to the vault, with the `.md` extension.
        public var path: String
        public var modified: Date
        public var size: Int
        public var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        public var folder: String { (path as NSString).deletingLastPathComponent }
    }

    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public static let folderKey = "notesFolder"

    /// The folder chosen in the app (UserDefaults), or `notes` in the data folder.
    public static func configured(paths: AppPaths) -> NotesVault {
        if let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty {
            return NotesVault(root: URL(fileURLWithPath: path, isDirectory: true))
        }
        return NotesVault(root: paths.root.appendingPathComponent("notes", isDirectory: true))
    }

    /// All notes, newest first. Hidden folders (.obsidian, .trash) are skipped.
    public func list() -> [Note] {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var notes: [Note] = []
        let base = root.resolvingSymlinksInPath().path + "/"
        for case let url as URL in e where url.pathExtension.lowercased() == "md" {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            notes.append(Note(path: String(full.dropFirst(base.count)), modified: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0))
        }
        return notes.sorted { $0.modified > $1.modified }
    }

    /// Notes whose name or text contains `query` (case-insensitive); `#tag` matches the tag.
    public func search(_ query: String) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list() }
        return list().filter { note in
            if !q.hasPrefix("#"), note.path.localizedCaseInsensitiveContains(q) { return true }
            guard let text = try? read(note.path) else { return false }
            if q.hasPrefix("#") { return Self.tags(text).contains { $0.caseInsensitiveCompare(String(q.dropFirst())) == .orderedSame } }
            return text.localizedCaseInsensitiveContains(q)
        }
    }

    /// The file for a note path; `.md` is added when missing. Refuses paths leaving the vault.
    public func url(_ path: String) throws -> URL {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("/") { p.removeFirst() }
        guard !p.isEmpty else { throw ClaudistError.invalid("Give the note path, e.g. Projects/Plan.md") }
        if (p as NSString).pathExtension.lowercased() != "md" { p += ".md" }
        guard !p.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw ClaudistError.invalid("\(path) is outside the notes folder")
        }
        let url = root.appendingPathComponent(p).standardizedFileURL
        // The deepest existing folder on the way must still be inside the vault (no symlinks out).
        var dir = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.path), dir.path.count > root.path.count { dir.deleteLastPathComponent() }
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let resolved = dir.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(root.path + "/"), resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
            throw ClaudistError.invalid("\(path) is outside the notes folder")
        }
        return url
    }

    public func relative(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
    }

    public func read(_ path: String) throws -> String {
        let u = try url(path)
        guard FileManager.default.fileExists(atPath: u.path) else { throw ClaudistError.invalid("No note \(relative(u))") }
        return try String(contentsOf: u, encoding: .utf8)
    }

    public func exists(_ path: String) -> Bool {
        (try? url(path)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public func write(_ path: String, _ text: String) throws {
        let u = try url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u, options: .atomic)
    }

    public func append(_ path: String, _ text: String) throws {
        let current = exists(path) ? try read(path) : ""
        let sep = current.isEmpty || current.hasSuffix("\n\n") ? "" : (current.hasSuffix("\n") ? "\n" : "\n\n")
        try write(path, current + sep + text)
    }

    public func delete(_ path: String) throws {
        try FileManager.default.removeItem(at: try url(path))
    }

    /// Renames or moves a note; returns the new path.
    @discardableResult
    public func move(_ from: String, to: String) throws -> String {
        let src = try url(from), dst = try url(to)
        guard src != dst else { return relative(dst) }
        guard !FileManager.default.fileExists(atPath: dst.path) else { throw ClaudistError.invalid("\(relative(dst)) already exists") }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: dst)
        return relative(dst)
    }

    /// A free path for a new note in `folder`: "Untitled.md", "Untitled 2.md" …
    public func newPath(_ name: String = "Untitled", in folder: String = "") -> String {
        var i = 1
        while true {
            let candidate = (folder.isEmpty ? "" : folder + "/") + (i == 1 ? name : "\(name) \(i)") + ".md"
            if !exists(candidate) { return candidate }
            i += 1
        }
    }

    /// The note a `[[link]]` points to: by path, else by file name anywhere in the vault (Obsidian's rule).
    public func resolve(link: String) -> Note? {
        let target = link.split(separator: "#").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? link
        let notes = list()
        let withExt = target.lowercased().hasSuffix(".md") ? target : target + ".md"
        if let exact = notes.first(where: { $0.path.caseInsensitiveCompare(withExt) == .orderedSame }) { return exact }
        let name = ((withExt as NSString).lastPathComponent as NSString).deletingPathExtension
        return notes.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }.min { $0.path.count < $1.path.count }
    }

    private static let tagPattern = try! NSRegularExpression(pattern: "(?:^|\\s)#([\\p{L}\\p{N}_/-]*\\p{L}[\\p{L}\\p{N}_/-]*)")

    /// `#tags` in the text (outside code and headings), without the `#`.
    public static func tags(_ text: String) -> [String] {
        var out: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.range(of: "^#+ ", options: .regularExpression) != nil && !line.dropFirst().contains("#") { continue }
            let s = String(line)
            let ns = s as NSString
            for m in tagPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return out
    }

    /// Splits YAML frontmatter (between `---` lines at the top) from the body.
    public static func frontmatter(_ text: String) -> (properties: [(String, String)], body: String) {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return ([], text) }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
            return ([], text)
        }
        var props: [(String, String)] = []
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let last = props.indices.last {
                props[last].1 += (props[last].1.isEmpty ? "" : ", ") + trimmed.dropFirst(2)
                continue
            }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            props.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                          String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return (props, lines[(end + 1)...].joined(separator: "\n"))
    }
}

/// Note tools for agents (by their notes access) and the assistant (always).
public enum NotesTools {
    public static let listTool = "list_notes", readTool = "read_note", writeTool = "write_note"
    public static let toolNames: Set<String> = [listTool, readTool, writeTool]

    public static func qualified(_ tool: String) -> String { "mcp__\(Delegation.serverName)__\(tool)" }

    public static func toolNames(_ access: StorageAccess?) -> [String] {
        switch access {
        case .rw?: return [listTool, readTool, writeTool]
        case .ro?: return [listTool, readTool]
        case nil: return []
        }
    }

    static let listDescription = "The user's notes (Markdown, Obsidian-style), newest first: path, title, modified. Optional query matches names and text; `#tag` finds a tag."
    static let readDescription = "The full Markdown text of a note."
    static let writeDescription = """
        Create or change a note. mode: `replace` (default; the whole text), `append` (add to the end), `create` (fails if it exists). \
        Write Obsidian-style Markdown: `[[Other note]]` links, `#tags`, optional YAML frontmatter, `- [ ]` checklists. \
        Paths are relative to the notes folder, e.g. `Projects/Plan.md`; folders are created as needed.
        """

    public static func toolDefinitions(_ access: StorageAccess?) -> [[String: Any]] {
        toolNames(access).map { definition($0) }
    }

    public static func definition(_ name: String) -> [String: Any] {
        switch name {
        case listTool:
            return ["name": name, "description": listDescription,
                    "inputSchema": ["type": "object", "properties": ["query": ["type": "string", "description": "Text or #tag"]]] as [String: Any]]
        case readTool:
            return ["name": name, "description": readDescription,
                    "inputSchema": ["type": "object", "properties": ["path": ["type": "string", "description": "Note path"]],
                                    "required": ["path"]] as [String: Any]]
        default:
            return ["name": name, "description": writeDescription,
                    "inputSchema": ["type": "object", "properties": [
                        "path": ["type": "string", "description": "Note path, e.g. Ideas/Pricing.md"],
                        "content": ["type": "string", "description": "Markdown"],
                        "mode": ["type": "string", "enum": ["replace", "append", "create"]],
                    ] as [String: Any], "required": ["path", "content"]] as [String: Any]]
        }
    }

    public static func promptSection(_ access: StorageAccess?) -> String? {
        guard let access else { return nil }
        let write = access == .rw
            ? "; write them with `\(qualified(writeTool))` when the task asks for a note, using `[[links]]` to related notes and `#tags`"
            : " (read-only for you)"
        return """
            ## Notes
            The user keeps notes in Claudist (Markdown in Obsidian's format). Find and read them with \
            `\(qualified(listTool))` and `\(qualified(readTool))`\(write). Don't look for notes on disk.
            """
    }

    public static func call(_ tool: String, arguments a: JSONValue?, vault: NotesVault, access: StorageAccess?) -> (text: String, isError: Bool) {
        do {
            guard toolNames(access).contains(tool) else {
                throw ClaudistError.invalid(access == .ro ? "Your access to notes is read-only" : "You have no access to notes")
            }
            switch tool {
            case listTool:
                let f = ISO8601DateFormatter()
                let rows = vault.search(a?["query"]?.string ?? "").prefix(200)
                    .map { ["path": $0.path, "title": $0.title, "modified": f.string(from: $0.modified)] }
                let data = try JSONSerialization.data(withJSONObject: ["notes": Array(rows)], options: [.prettyPrinted, .sortedKeys])
                return (String(decoding: data, as: UTF8.self), false)
            case readTool:
                guard let path = a?["path"]?.string else { throw ClaudistError.invalid("Give the path") }
                return (try vault.read(path), false)
            default:
                guard let path = a?["path"]?.string, let content = a?["content"]?.string else {
                    throw ClaudistError.invalid("Give path and content")
                }
                switch a?["mode"]?.string ?? "replace" {
                case "append": try vault.append(path, content)
                case "create":
                    if vault.exists(path) { throw ClaudistError.invalid("\(path) already exists") }
                    try vault.write(path, content)
                default: try vault.write(path, content)
                }
                return ("Saved \(vault.relative(try vault.url(path)))", false)
            }
        } catch {
            return ((error as? LocalizedError)?.errorDescription ?? "\(error)", true)
        }
    }
}
