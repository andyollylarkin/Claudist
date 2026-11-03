import Foundation

public struct Skill: Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// Folder name inside the library; this is what agents reference.
    public var name: String
    public var description: String
    public var url: URL
}

/// A file attached to a skill (script, reference, asset), path relative to the skill folder.
public struct SkillFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var isDirectory: Bool
    public var size: Int
    public var isExecutable: Bool

    public var depth: Int { path.split(separator: "/").count - 1 }
    public var name: String { (path as NSString).lastPathComponent }
}

/// The shared skill library. Skills live once in the library and are symlinked
/// into `<agent folder>/.claude/skills/<name>` for every agent that uses them.
public struct SkillLibrary: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func list() -> [Skill] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return dirs.compactMap { dir in
            let md = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: md, encoding: .utf8) else { return nil }
            let fm = Frontmatter.parse(text)
            return Skill(name: dir.lastPathComponent, description: fm.fields["description"] ?? "", url: dir)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Imports a skill into the library from:
    /// - a folder with SKILL.md;
    /// - a .zip / .skill archive with SKILL.md at the root or in a single top folder;
    /// - a single .md file, which becomes the SKILL.md of a new skill.
    @discardableResult
    public func importSkill(from url: URL) throws -> Skill {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ClaudistError.invalid("\(url.lastPathComponent) not found")
        }
        if isDir.boolValue {
            guard fm.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else {
                throw ClaudistError.invalid("Folder \(url.lastPathComponent) has no SKILL.md")
            }
            return try install(folder: url, name: url.lastPathComponent)
        }
        switch url.pathExtension.lowercased() {
        case "zip", "skill":
            return try importArchive(url)
        case "md", "markdown":
            let text = try String(contentsOf: url, encoding: .utf8)
            let base = url.deletingPathExtension().lastPathComponent
            let name = Frontmatter.parse(text).fields["name"].flatMap { $0.isEmpty ? nil : $0 }
                ?? (base.uppercased() == "SKILL" ? url.deletingLastPathComponent().lastPathComponent : base)
            let dest = try newSkillFolder(AppPaths.slug(name))
            try fm.copyItem(at: url, to: dest.appendingPathComponent("SKILL.md"))
            return skill(dest.lastPathComponent)
        default:
            throw ClaudistError.invalid("\(url.lastPathComponent): expected a folder with SKILL.md, a .zip/.skill archive or a .md file")
        }
    }

    /// A folder with SKILL.md, imported under `name`.
    @discardableResult
    public func importSkill(from folder: URL, name: String) throws -> Skill {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) else {
            throw ClaudistError.invalid("Folder \(folder.lastPathComponent) has no SKILL.md")
        }
        return try install(folder: folder, name: name)
    }

    private func importArchive(_ url: URL) throws -> Skill {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("skill-import-\(newID())", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, tmp.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ClaudistError.invalid("Could not unpack \(url.lastPathComponent)") }

        let entries = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        let base = url.deletingPathExtension().lastPathComponent
        if fm.fileExists(atPath: tmp.appendingPathComponent("SKILL.md").path) {
            return try install(folder: tmp, name: base)
        }
        if entries.count == 1, fm.fileExists(atPath: entries[0].appendingPathComponent("SKILL.md").path) {
            return try install(folder: entries[0], name: entries[0].lastPathComponent)
        }
        throw ClaudistError.invalid("Archive \(url.lastPathComponent) has no SKILL.md")
    }

    private func install(folder: URL, name: String) throws -> Skill {
        let dest = root.appendingPathComponent(AppPaths.slug(name), isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw ClaudistError.invalid("Skill \(dest.lastPathComponent) is already in the library")
        }
        try FileManager.default.copyItem(at: folder, to: dest)
        return skill(dest.lastPathComponent)
    }

    private func newSkillFolder(_ name: String) throws -> URL {
        let dest = root.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw ClaudistError.invalid("Skill \(name) is already in the library")
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return dest
    }

    private func skill(_ name: String) -> Skill {
        list().first { $0.name == name }!
    }

    // MARK: Attached files

    /// Files and folders inside the skill (except SKILL.md), depth-first, relative paths.
    public func files(of skill: Skill) -> [SkillFile] {
        let fm = FileManager.default
        let base = skill.url.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard let e = fm.enumerator(at: skill.url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                    options: []) else { return [] }
        var out: [SkillFile] = []
        for case let url as URL in e {
            if url.lastPathComponent == ".DS_Store" { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            if rel == "SKILL.md" { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            out.append(SkillFile(path: rel, isDirectory: values?.isDirectory ?? false,
                                 size: values?.fileSize ?? 0,
                                 isExecutable: fm.isExecutableFile(atPath: full) && values?.isDirectory != true))
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Copies files or folders into the skill, optionally into a subfolder like "scripts".
    /// Existing files with the same name are replaced; scripts are made executable.
    public func attach(_ urls: [URL], to skill: Skill, subfolder: String? = nil) throws {
        let fm = FileManager.default
        var dir = skill.url
        if let subfolder, !subfolder.isEmpty {
            dir = try contained(subfolder, in: skill)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for url in urls {
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            if dest.standardizedFileURL == url.standardizedFileURL { continue }
            if dest.lastPathComponent == "SKILL.md" && dir == skill.url {
                throw ClaudistError.invalid("SKILL.md can't be replaced by an attachment — edit it instead")
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            try makeScriptsExecutable(dest)
        }
    }

    public func removeFile(_ path: String, from skill: Skill) throws {
        guard path != "SKILL.md" else { throw ClaudistError.invalid("SKILL.md can't be deleted") }
        try FileManager.default.removeItem(at: contained(path, in: skill))
    }

    public func setExecutable(_ path: String, in skill: Skill, _ on: Bool) throws {
        let url = try contained(path, in: skill)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let new = on ? mode | 0o111 : mode & ~0o111
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: new)], ofItemAtPath: url.path)
    }

    public func readSkillMD(_ skill: Skill) -> String {
        (try? String(contentsOf: skill.url.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
    }

    public func writeSkillMD(_ skill: Skill, _ text: String) throws {
        try text.write(to: skill.url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    /// Resolves a relative path inside the skill, rejecting `..` escapes.
    private func contained(_ path: String, in skill: Skill) throws -> URL {
        // Component check instead of standardizedFileURL: it strips /private only for existing paths.
        let parts = path.split(separator: "/").filter { $0 != "." }
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains("..") else {
            throw ClaudistError.invalid("Path \(path) points outside the skill")
        }
        return skill.url.appendingPathComponent(parts.joined(separator: "/"))
    }

    private static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "py", "rb", "pl", "js", "mjs", "ts", "swift"]

    func makeScriptsExecutable(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            for child in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                try makeScriptsExecutable(child)
            }
            return
        }
        let shebang = (try? FileHandle(forReadingFrom: url).read(upToCount: 2)) == Data("#!".utf8)
        guard shebang || Self.scriptExtensions.contains(url.pathExtension.lowercased()) else { return }
        let mode = ((try fm.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode | 0o111)], ofItemAtPath: url.path)
    }

    /// Creates an empty skill skeleton.
    @discardableResult
    public func create(name: String, description: String) throws -> Skill {
        let dir = root.appendingPathComponent(AppPaths.slug(name), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let text = "---\nname: \(AppPaths.slug(name))\ndescription: \(description)\n---\n\n# \(name)\n"
        try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return skill(dir.lastPathComponent)
    }

    public func delete(_ skill: Skill) throws {
        try FileManager.default.removeItem(at: skill.url)
    }

    /// Makes `<agentFolder>/.claude/skills` contain exactly the symlinks for `names`.
    /// Only symlinks pointing into the library are removed; agent-local skills are kept.
    public func sync(agentFolder: URL, names: Set<String>) throws {
        let fm = FileManager.default
        let dir = agentFolder.appendingPathComponent(".claude/skills", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let libPath = root.standardizedFileURL.path

        for entry in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let link = dir.appendingPathComponent(entry)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  URL(fileURLWithPath: dest).standardizedFileURL.path.hasPrefix(libPath)
            else { continue }
            if !names.contains(entry) || !fm.fileExists(atPath: dest) {
                try fm.removeItem(at: link)
            }
        }
        for name in names {
            let link = dir.appendingPathComponent(name)
            let target = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: target.path) else { continue }
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) { continue }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        }
    }
}

public enum ClaudistError: LocalizedError {
    case invalid(String)
    case claudeNotFound

    public var errorDescription: String? {
        switch self {
        case .invalid(let s): return s
        case .claudeNotFound: return "Claude Code CLI (claude) not found. Install it from https://claude.com/code"
        }
    }
}
