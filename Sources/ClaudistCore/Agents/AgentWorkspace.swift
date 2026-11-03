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
    /// SQLite databases of the agent and the task, served by the app's db_* tools.
    public var databases: [DatabaseGrant] = []
    /// Permission rules the user allowed for this task only (access requests).
    public var extraAllow: [String] = []
    /// Shared prompt templates merged before the agent's own prompt.
    public var promptTemplates: [PromptTemplate] = []
    /// Built-in integrations that are on and granted to the agent (Telegram…), served by the app.
    public var integrations: [String] = []

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

    /// A folder for a new agent that no agent uses and that doesn't exist yet: agents sharing a
    /// folder would share memory and conversations.
    public func newFolder(for name: String, taken: [String]) -> URL {
        var folder = defaultFolder(for: name)
        var n = 2
        while taken.contains(folder.path) || FileManager.default.fileExists(atPath: folder.path) {
            folder = paths.agents.appendingPathComponent("\(AppPaths.slug(name))-\(n)", isDirectory: true)
            n += 1
        }
        return folder
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

    /// Edit/Write deny rules keeping `root` read-only except the `writable` paths inside it: at each level
    /// down to a writable path, the files of that level and every other existing folder are denied.
    /// (A folder created later next to the path is not covered; Bash isn't limited by these rules anyway.)
    static func readOnlyRules(_ root: String, except writable: [String]) -> [String] {
        func rules(_ glob: String) -> [String] { ["Edit(/\(glob))", "Write(/\(glob))"] }
        let inner = writable.filter { $0.hasPrefix(root + "/") }
        if writable.contains(root) { return [] }
        guard !inner.isEmpty else { return rules(root + "/**") }
        var out = rules(root + "/*")
        let children = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for name in children.sorted() {
            let child = root + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
            if inner.contains(child) { continue }
            if inner.contains(where: { $0.hasPrefix(child + "/") }) {
                out += readOnlyRules(child, except: inner)
            } else {
                out += rules(child + "/**")
            }
        }
        return out
    }

    public func settings(_ config: AgentLaunchConfig) -> [String: Any] {
        var deny = config.agent.denyList
        // Deny wins over allow in Claude Code, so a writable folder inside a read-only one
        // (a granted project in a read-only workspace) needs the read-only part denied around it.
        let writable = config.storages.filter { $0.access == .rw }.map(\.storage.path)
            + config.attachments.filter(\.writable).map(\.path)
        for (storage, access) in config.storages where access == .ro {
            deny += Self.readOnlyRules(storage.path, except: writable)
        }
        var allow = config.agent.allowList + config.extraAllow
        // App-served tools: asking the user and asking for access are always available, delegation when configured.
        allow.append(Attention.qualifiedToolName)
        allow.append(AccessRequests.qualifiedToolName)
        if !config.delegates.isEmpty { allow.append(Delegation.qualifiedToolName) }
        // Task tools are limited by the app to the agent's own tasks and its delegates'.
        allow += AssistantTools.agentToolNames.map(AssistantTools.qualified)
        // Database access is enforced by the app when it runs the SQL.
        allow += DatabaseAccess.toolNames(config.databases).map(DatabaseAccess.qualified)
        // Charts read through the same grants; their queries always run read-only.
        if !config.databases.isEmpty { allow += DashboardTools.toolNames.sorted().map(DashboardTools.qualified) }
        allow += NotesTools.toolNames(config.agent.notesAccess).map(NotesTools.qualified)
        allow += Integrations.toolNames(config.integrations).map(Integrations.qualified)
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
        let prompt = [PromptTemplates.merge(config.promptTemplates, into: config.agent), Self.environmentSection(config), Attention.promptSection, AccessRequests.promptSection,
                      config.delegates.isEmpty ? "" : Delegation.promptSection(config.delegates),
                      Secrets.promptSection(config.secrets) ?? "",
                      DatabaseAccess.promptSection(config.databases) ?? "",
                      NotesTools.promptSection(config.agent.notesAccess) ?? "",
                      Integrations.promptSection(config.integrations) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !prompt.isEmpty {
            args += ["--append-system-prompt", prompt]
        }
        args += ["--mcp-config", Delegation.mcpConfig]
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

    /// Tells the agent where it runs: Claude Code alone doesn't know it is inside Claudist.
    public static func environmentSection(_ config: AgentLaunchConfig) -> String {
        """
        ## Environment
        You are the agent "\(config.agent.name)" in Claudist, a macOS task manager in which Claude Code agents work on \
        the user's tasks. The first message is your task (title, description, comments, attachments). The user is not \
        watching live: your final message is shown as the task's result, and follow-up messages continue this task. \
        Your working folder `\(config.agent.folderPath)` belongs to you alone; files and memory there persist between tasks.

        ## Claudist tasks
        You can read and manage the user's tasks with the app's tools: `\(AssistantTools.qualified("list_projects"))`, \
        `\(AssistantTools.qualified("find_tasks"))` (Todoist filter syntax: `today`, `overdue`, `#Project`, `p1`, `@label`, \
        `agent: Name`, combined with `&`, `|`, `!`), `\(AssistantTools.qualified("get_task"))`, \
        `\(AssistantTools.qualified("create_task"))`, `\(AssistantTools.qualified("update_task"))`, \
        `\(AssistantTools.qualified("complete_task"))` and `\(AssistantTools.qualified("add_comment"))`. Use them when the user asks you \
        to create, plan or update tasks, or to leave follow-ups. A created task with an agent starts by itself when it \
        comes due — once for a date ("tomorrow 9am"), every time for a recurring one ("every Monday at 9am"); without a \
        due date the user starts it. Assign tasks only to yourself or an agent you may call. You can change only unassigned tasks, your own, and those of agents you may call.
        """
    }

    /// Imported agent files often list tools without `Skill`; enabled skills would then be
    /// invisible and the agent improvises. Skills you enable in Claudist always get the tool.
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
