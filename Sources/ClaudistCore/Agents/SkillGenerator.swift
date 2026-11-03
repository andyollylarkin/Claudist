import Foundation

/// Writes a skill — SKILL.md and the tools it uses — with Claude Code from a prompt.
///
/// Claude works in a draft folder outside the library:
/// - `--restricted` confines its file tools to that folder and drops Bash/WebFetch unless listed;
/// - `--safe-mode` keeps the user's own skills, CLAUDE.md, plugins and hooks out;
/// - every permission request is checked again by the app (`decide`).
/// The draft enters the library only when the user saves it.
public enum SkillGenerator {
    public static let defaultLanguage = "Python"
    public static let languages = ["Python", "Bash", "Node.js", "TypeScript", "Go", "Swift", "Ruby"]

    public struct Options: Sendable {
        /// Language for the skill's tools; the request text may still name another one.
        public var language = SkillGenerator.defaultLanguage
        public var model: String?
        /// Bash lets Claude run the tools it wrote; each command is approved by the user.
        public var allowBash = false
        public var allowWeb = true

        public init() {}
    }

    public static func tools(_ options: Options) -> String {
        var tools = ["Read", "Write", "Edit", "Glob", "Grep"]
        if options.allowBash { tools.append("Bash") }
        if options.allowWeb { tools += ["WebSearch", "WebFetch"] }
        return tools.joined(separator: ",")
    }

    public static func arguments(_ options: Options) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompt-tool", "stdio",
            "--safe-mode",
            "--restricted",
            "--strict-mcp-config",
            // Drafts are throwaway folders; don't leave sessions for them in ~/.claude/projects.
            "--no-session-persistence",
            "--permission-mode", "acceptEdits",
            "--tools", tools(options),
            "--append-system-prompt", systemPrompt(language: language(options)),
        ]
        if let model = options.model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    static func language(_ options: Options) -> String {
        let l = options.language.trimmingCharacters(in: .whitespacesAndNewlines)
        return l.isEmpty ? defaultLanguage : l
    }

    public static func systemPrompt(language: String) -> String {
        """
        # You write Agent Skills for Claude Code

        The current working directory is the skill folder. Write every file there and nowhere else.

        ## Layout
        - `SKILL.md` — required. YAML frontmatter with `name` (lowercase letters, digits and hyphens, \
        at most 64 characters) and `description` (what the skill does AND when to use it, third person, \
        at most 1024 characters; this text alone decides whether an agent loads the skill). Then the \
        instructions: short, imperative, only what an agent would not know without them.
        - `scripts/` — the skill's tools: executables the agent runs instead of improvising code.
        - `references/` — longer documentation the agent reads only when needed (optional).
        - `assets/` — templates and static files used in the output (optional).
        Do not create README, CHANGELOG, tests or example folders unless asked.

        ## Tools
        - Write tools for any step that is deterministic, fiddly or repeated: API calls, parsing, \
        conversions, validation. Leave judgement to the instructions.
        - Language: \(language). If the user's request explicitly names another language, follow the request.
        - One tool per job. Each starts with a shebang, has `--help`, takes input as arguments or stdin, \
        prints results to stdout (offer `--json` when the output is structured), reports errors to stderr \
        and exits non-zero on failure.
        \(languageNotes(language))
        - In SKILL.md show the exact command for every tool, with paths relative to the skill folder \
        (for example `python3 scripts/fetch.py --help`), and say that they run from the skill's base directory.

        ## Credentials
        - Tools read credentials only from environment variables in UPPER_SNAKE_CASE. Never hardcode them, \
        take them as arguments, write them to files or print them.
        - A credential that is a file (SSH key, certificate) arrives as a variable holding the file's path.
        - List every variable in SKILL.md under a `## Required secrets` heading, one bullet each in the \
        form "- `NAME` — what it is and where to get it". The app injects secrets with those names.

        ## Finish
        Read your files once more and fix inconsistencies between SKILL.md and the tools. Then end with a \
        short summary: the files you wrote, how an agent uses the skill, and the required secrets.
        """
    }

    static func languageNotes(_ language: String) -> String {
        switch language.lowercased() {
        case "python", "python3":
            return """
                - Python 3: `#!/usr/bin/env python3`, `argparse`, standard library only when possible. If a \
                package is truly needed, declare it with PEP 723 inline script metadata and document \
                `uv run scripts/<tool>.py` (with `pip install <package>` as the fallback).
                """
        case "bash", "sh", "shell", "zsh":
            return "- Bash: `#!/usr/bin/env bash`, `set -euo pipefail`, quote variables; macOS ships BSD tools, not GNU."
        case "node.js", "node", "javascript", "js":
            return "- Node.js: `#!/usr/bin/env node`, ES modules (`.mjs`), built-in modules and `fetch` only when possible."
        case "typescript", "ts":
            return "- TypeScript: run without a build step (`#!/usr/bin/env -S npx tsx` or Deno); state the runtime in SKILL.md."
        case "go":
            return "- Go: single-file programs run with `go run scripts/<tool>.go`; standard library only when possible."
        case "swift":
            return "- Swift: single-file scripts with `#!/usr/bin/env swift`, Foundation only."
        default:
            return "- State in SKILL.md which runtime the tools need and how to install it."
        }
    }

    /// The first message of a generation, or of an edit of an existing skill copied into the draft.
    public static func firstMessage(request: String, editing name: String?) -> String {
        if let name {
            return """
                The current folder holds the existing skill `\(name)`. Read SKILL.md and the files it uses, \
                then change the skill as requested. Keep the name `\(name)` unless asked to rename it.

                Request:
                \(request)
                """
        }
        return """
            Create a new skill in the current folder.

            Request:
            \(request)
            """
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case deny(String)
        /// The user decides (commands).
        case ask
    }

    /// The app's policy for permission requests coming from a generation.
    public static func decide(tool: String, input: JSONValue, draft: URL, options: Options) -> Decision {
        switch tool {
        case "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "NotebookEdit":
            let key = ["file_path", "notebook_path", "path"].first { input[$0]?.string != nil }
            guard let key, let path = input[key]?.string else { return .allow }   // Glob/Grep default to cwd
            return isInside(path, draft) ? .allow : .deny("Only the skill draft folder is available")
        case "WebSearch", "WebFetch":
            return options.allowWeb ? .allow : .deny("Web access is off for this generation")
        case "Bash":
            return options.allowBash ? .ask : .deny("Running commands is off for this generation")
        default:
            return .deny("\(tool) is not available while writing a skill")
        }
    }

    /// Whether `path` (absolute, or relative to the draft) stays inside the draft folder.
    public static func isInside(_ path: String, _ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        // Resolve symlinks of the existing part only; a new file's parent may not exist yet.
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard !rest.contains("..") else { return false }
        let full = ([existing.resolvingSymlinksInPath().path] + rest).joined(separator: "/")
        return full == base || full.hasPrefix(base + "/")
    }

    /// Variable names listed under `## Required secrets` in SKILL.md.
    public static func requiredSecrets(_ skillMD: String) -> [String] {
        var inSection = false
        var names: [String] = []
        for line in skillMD.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                inSection = t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                    .hasPrefix("required secrets")
                continue
            }
            guard inSection, t.hasPrefix("-") || t.hasPrefix("*"),
                  let r = t.range(of: "`[A-Za-z_][A-Za-z0-9_]*`", options: .regularExpression) else { continue }
            let name = String(t[r].dropFirst().dropLast())
            if !names.contains(name) { names.append(name) }
        }
        return names
    }
}

extension SkillLibrary {
    /// Folder for generation drafts, next to the library.
    public var draftsRoot: URL { root.deletingLastPathComponent().appendingPathComponent("skill-drafts", isDirectory: true) }

    /// A fresh draft folder: empty for a new skill, or a copy of `skill` to edit.
    public func makeDraft(from skill: Skill? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: draftsRoot, withIntermediateDirectories: true)
        let draft = draftsRoot.appendingPathComponent(newID(), isDirectory: true)
        if let skill {
            try fm.copyItem(at: skill.url.resolvingSymlinksInPath(), to: draft)
        } else {
            try fm.createDirectory(at: draft, withIntermediateDirectories: false)
        }
        return draft
    }

    /// Moves a finished draft into the library. A new skill is named after its frontmatter `name`
    /// (with a numeric suffix on a clash); an edited skill keeps its folder so agent symlinks stay valid.
    @discardableResult
    public func installDraft(_ draft: URL, replacing existing: Skill? = nil) throws -> Skill {
        let fm = FileManager.default
        let md = draft.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: md, encoding: .utf8) else {
            throw ClaudistError.invalid("The draft has no SKILL.md yet")
        }
        for junk in [".claude", ".DS_Store", "__pycache__", "scripts/__pycache__", "node_modules"] {
            try? fm.removeItem(at: draft.appendingPathComponent(junk))
        }
        try makeScriptsExecutable(draft)

        if let existing {
            let backup = draftsRoot.appendingPathComponent("\(existing.name)-previous-\(newID())", isDirectory: true)
            try fm.moveItem(at: existing.url, to: backup)
            do {
                try fm.moveItem(at: draft, to: existing.url)
            } catch {
                try? fm.moveItem(at: backup, to: existing.url)
                throw error
            }
            try? fm.removeItem(at: backup)
            return list().first { $0.name == existing.name }!
        }

        let base = AppPaths.slug(Frontmatter.parse(text).fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "new-skill")
        var name = base
        var n = 2
        while fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            name = "\(base)-\(n)"
            n += 1
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.moveItem(at: draft, to: root.appendingPathComponent(name, isDirectory: true))
        return list().first { $0.name == name }!
    }

    public func discardDraft(_ draft: URL) {
        guard draft.deletingLastPathComponent().standardizedFileURL == draftsRoot.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: draft)
    }

    /// Text files of a draft for preview, SKILL.md first.
    public func draftFiles(_ draft: URL) -> [SkillFile] {
        let skill = Skill(name: draft.lastPathComponent, description: "", url: draft)
        var out = files(of: skill)
        if FileManager.default.fileExists(atPath: draft.appendingPathComponent("SKILL.md").path) {
            out.insert(SkillFile(path: "SKILL.md", isDirectory: false, size: 0, isExecutable: false), at: 0)
        }
        return out
    }
}
