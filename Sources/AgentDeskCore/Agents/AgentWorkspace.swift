import Foundation

/// Everything needed to launch one agent run, resolved from the database.
public struct AgentLaunchConfig: Sendable {
    public var agent: Agent
    public var skills: Set<String>
    public var storages: [(storage: Storage, access: StorageAccess)]
    /// Agents this agent may call through the delegate tool.
    public var delegates: [Agent]
    /// Task the run works on; settings are generated per task because attachments differ.
    public var taskId: ID?
    /// Host files and folders attached to that task.
    public var attachments: [TaskAttachment] = []
    /// Secrets the run receives (agent's and its skills'), described in the system prompt.
    public var secrets: [Secret] = []

    public init(agent: Agent, skills: Set<String>, storages: [(storage: Storage, access: StorageAccess)], delegates: [Agent] = []) {
        self.agent = agent
        self.skills = skills
        self.storages = storages
        self.delegates = delegates
    }
}

/// Prepares the agent's project folder and builds the `claude` command line.
///
/// Isolation model:
/// - cwd is the agent folder, so project memory (CLAUDE.md, auto-memory) is per agent;
/// - `--setting-sources project,local` ignores the user's ~/.claude settings;
/// - permissions come from a generated settings file kept in app support, not in the agent folder;
/// - storage folders are added with `--add-dir`; read-only ones get Edit/Write deny rules.
///   Deny rules bind Claude Code's file tools only, a Bash command can still write there.
public struct AgentWorkspace: Sendable {
    public let paths: AppPaths
    public let library: SkillLibrary

    public init(paths: AppPaths) {
        self.paths = paths
        self.library = SkillLibrary(root: paths.skills)
    }

    public func defaultFolder(for name: String) -> URL {
        paths.agents.appendingPathComponent(AppPaths.slug(name), isDirectory: true)
    }

    public func prepare(_ config: AgentLaunchConfig) throws -> URL {
        let folder = URL(fileURLWithPath: config.agent.folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try library.sync(agentFolder: folder, names: config.skills)

        let name = [config.agent.id, config.taskId].compactMap { $0 }.joined(separator: "-")
        let settingsURL = paths.root.appendingPathComponent("settings/\(name).json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings(config), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
        return settingsURL
    }

    public func settings(_ config: AgentLaunchConfig) -> [String: Any] {
        var deny = config.agent.denyList
        for (storage, access) in config.storages where access == .ro {
            deny.append("Edit(/\(storage.path)/**)")
            deny.append("Write(/\(storage.path)/**)")
        }
        var allow = config.agent.allowList
        if !config.delegates.isEmpty { allow.append(Delegation.qualifiedToolName) }
        // Attachments are granted exactly: the file itself, or the folder's contents.
        for a in config.attachments where a.exists {
            let target = a.isDirectory ? "/\(a.path)/**" : "/\(a.path)"
            allow.append("Read(\(target))")
            if a.writable {
                allow.append("Edit(\(target))")
                allow.append("Write(\(target))")
            }
        }
        var permissions: [String: Any] = [
            "allow": allow,
            "deny": deny,
        ]
        let dirs = config.storages.map(\.storage.path) + attachedFolders(config)
        if !dirs.isEmpty {
            permissions["additionalDirectories"] = dirs
        }
        return ["permissions": permissions]
    }

    public func arguments(_ config: AgentLaunchConfig, settingsURL: URL, resume sessionId: String?) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompt-tool", "stdio",
            "--setting-sources", "project,local",
            "--settings", settingsURL.path,
            "--permission-mode", config.agent.permissionMode == "default" ? "manual" : config.agent.permissionMode,
        ]
        if let model = config.agent.model, !model.isEmpty, model != "inherit" {
            args += ["--model", model]
        }
        let prompt = [config.agent.prompt, config.delegates.isEmpty ? "" : Delegation.promptSection(config.delegates),
                      Secrets.promptSection(config.secrets) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !prompt.isEmpty {
            args += ["--append-system-prompt", prompt]
        }
        if !config.delegates.isEmpty {
            args += ["--mcp-config", Delegation.mcpConfig]
        }
        if let tools = Self.tools(config) {
            args += ["--tools", tools]
        }
        if let sessionId {
            args += ["--resume", sessionId]
        }
        for (storage, _) in config.storages {
            args += ["--add-dir", storage.path]
        }
        for dir in attachedFolders(config) {
            args += ["--add-dir", dir]
        }
        return args
    }

    /// Imported agent files often list tools without `Skill`; enabled skills would then be
    /// invisible and the agent improvises. Skills you enable in AgentDesk always get the tool.
    static func tools(_ config: AgentLaunchConfig) -> String? {
        guard let tools = config.agent.tools, !tools.isEmpty else { return nil }
        var list = tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !config.skills.isEmpty && !list.contains("Skill") { list.append("Skill") }
        return list.joined(separator: ",")
    }

    /// Attached folders become working directories; attached files only get file rules,
    /// so the rest of their parent folder stays out of reach.
    private func attachedFolders(_ config: AgentLaunchConfig) -> [String] {
        config.attachments.filter { $0.isDirectory && $0.exists }.map(\.path)
    }

    /// Prompt section listing the task's attachments.
    public static func attachmentsPrompt(_ attachments: [TaskAttachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        let lines = attachments.map { a -> String in
            let kind = a.isDirectory ? "folder" : "file"
            let access = a.writable ? "read & write" : "read-only"
            return a.exists ? "- `\(a.path)` (\(kind), \(access))" : "- `\(a.path)` (\(kind), MISSING on disk)"
        }
        return "## Attached files\nThese host paths are attached to the task. Use them in place, do not copy them unless asked.\n" + lines.joined(separator: "\n")
    }
}

/// Parses a Claude Code subagent definition (`.claude/agents/<name>.md`).
public enum AgentImporter {
    public static func parse(_ text: String, fallbackName: String) -> (name: String, description: String, model: String?, tools: String?, prompt: String) {
        let fm = Frontmatter.parse(text)
        let tools = fm.fields["tools"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
        }
        return (
            name: fm.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName,
            description: fm.fields["description"] ?? "",
            model: fm.fields["model"],
            tools: tools?.isEmpty == true ? nil : tools,
            prompt: fm.body
        )
    }
}
