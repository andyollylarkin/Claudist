import Foundation

/// Skills from GitHub: a repository, branch, folder or SKILL.md link is downloaded as one archive
/// and every folder with a SKILL.md under the linked path is offered for import.
public enum GitHubSkills {
    public struct Source: Equatable, Sendable {
        public var owner: String
        public var repo: String
        /// Branch, tag or commit; nil = the default branch.
        public var ref: String?
        /// Folder inside the repository ("" = root).
        public var path: String

        public var webURL: String {
            "https://github.com/\(owner)/\(repo)" + (ref.map { "/tree/\($0)" + (path.isEmpty ? "" : "/\(path)") } ?? "")
        }
    }

    public struct Found: Identifiable, Sendable, Hashable {
        public var id: String { path }
        /// Folder relative to the repository root.
        public var path: String
        public var name: String
        public var description: String
        public var files: Int
        public var folder: URL
    }

    /// A downloaded repository; `cleanup` removes it.
    public struct Download: Sendable {
        public var source: Source
        public var skills: [Found]
        public var root: URL
        public func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// `https://github.com/o/r`, `…/tree/<ref>/<path>`, `…/blob/<ref>/<path>/SKILL.md`, `o/r` or `o/r/path`.
    public static func parse(_ text: String) -> Source? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        let fromSite = s.hasPrefix("github.com/")
        if fromSite { s.removeFirst("github.com/".count) }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        var parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts.removeFirst()
        var repo = parts.removeFirst()
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let valid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !owner.isEmpty, !repo.isEmpty,
              owner.unicodeScalars.allSatisfy(valid.contains), repo.unicodeScalars.allSatisfy(valid.contains) else { return nil }
        var ref: String?
        if let kind = parts.first, kind == "tree" || kind == "blob" {
            parts.removeFirst()
            guard !parts.isEmpty else { return nil }
            ref = parts.removeFirst()
        } else if !fromSite && !parts.isEmpty {
            // owner/repo/path shorthand: the default branch.
        }
        if parts.last?.caseInsensitiveCompare("SKILL.md") == .orderedSame { parts.removeLast() }
        guard !parts.contains("..") else { return nil }
        return Source(owner: owner, repo: repo, ref: ref, path: parts.joined(separator: "/"))
    }

    static let maxBytes = 200_000_000

    /// Downloads the repository archive and lists the skills under the linked path.
    public static func fetch(_ source: Source, session: URLSession = .shared) async throws -> Download {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("github-skills-\(newID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(source.owner)/\(source.repo)/tarball"
                                              + (source.ref.map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0) } ?? ""))!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Claudist", forHTTPHeaderField: "User-Agent")
            let (file, response) = try await session.download(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw ClaudistError.invalid(status == 404 ? "\(source.owner)/\(source.repo) not found (or private)"
                                            : status == 403 ? "GitHub refused the download (rate limit?); try again later"
                                            : "GitHub answered \(status)")
            }
            let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maxBytes else { throw ClaudistError.invalid("The repository is too large (\(size / 1_000_000) MB)") }
            let archive = root.appendingPathComponent("repo.tar.gz")
            try fm.moveItem(at: file, to: archive)
            let unpacked = root.appendingPathComponent("repo", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", archive.path, "-C", unpacked.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw ClaudistError.invalid("Could not unpack the repository") }
            try? fm.removeItem(at: archive)
            // GitHub wraps everything in one owner-repo-sha folder.
            let top = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first { !$0.lastPathComponent.hasPrefix(".") }
            guard let top else { throw ClaudistError.invalid("The repository is empty") }
            let start = source.path.isEmpty ? top : top.appendingPathComponent(source.path, isDirectory: true)
            guard fm.fileExists(atPath: start.path) else { throw ClaudistError.invalid("No folder \(source.path) in \(source.owner)/\(source.repo)") }
            let skills = find(in: start, repoRoot: top, rootName: source.repo)
            guard !skills.isEmpty else { throw ClaudistError.invalid("No SKILL.md under \(source.webURL)") }
            return Download(source: source, skills: skills, root: root)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    /// Folders with a SKILL.md; a skill's own subfolders aren't searched further.
    static func find(in start: URL, repoRoot: URL, rootName: String) -> [Found] {
        let fm = FileManager.default
        var out: [Found] = []
        func visit(_ dir: URL, depth: Int) {
            let md = dir.appendingPathComponent("SKILL.md")
            if let text = try? String(contentsOf: md, encoding: .utf8) {
                let front = Frontmatter.parse(text)
                let files = (fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
                let rel = dir.standardizedFileURL.path.dropFirst(repoRoot.standardizedFileURL.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                out.append(Found(path: rel, name: front.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? (rel.isEmpty ? rootName : dir.lastPathComponent),
                                 description: front.fields["description"] ?? "", files: files, folder: dir))
                return
            }
            guard depth < 6, let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for e in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where !e.lastPathComponent.hasPrefix(".") && e.lastPathComponent != "node_modules"
                && (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                visit(e, depth: depth + 1)
            }
        }
        visit(start, depth: 0)
        return out
    }
}

extension SkillLibrary {
    /// Imports a found skill under its own name; the source is noted in the skill folder.
    @discardableResult
    public func install(_ found: GitHubSkills.Found, from source: GitHubSkills.Source) throws -> Skill {
        let skill = try importSkill(from: found.folder, name: found.name)
        let origin = "https://github.com/\(source.owner)/\(source.repo)/tree/\(source.ref ?? "HEAD")/\(found.path)\n"
        try? Data(origin.utf8).write(to: skill.url.appendingPathComponent(".source"))
        return skill
    }
}
