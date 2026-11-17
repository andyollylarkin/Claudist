import ClaudistCore
import Combine
import Foundation
import GRDB
import SwiftUI

enum SidebarItem: Hashable {
    case project(ID)
    case filter(ID)
    case dashboard(ID)
    case agents
    case skills
    case storage
    case secrets
    case databases
    case assistant
    case runLog
    case needsYou
    case failed
    case review
    case stats
    case prompts
    case notes
    case memory
    case integrations
    case recordings
    case search
    /// The App Builder's gallery of apps.
    case apps
    case appBuilder
    case miniApp(ID)
}

/// App-wide state: the database plus live-observed reference data.
@MainActor
final class AppStore: ObservableObject {
    let db: AppDatabase
    let paths: AppPaths
    let workspace: AgentWorkspace
    /// Experimental code graphs.
    var graphEngine: CodeGraphEngine { CodeGraphEngine(paths: paths) }
    let secretStore: SecretStore = KeychainSecretStore()
    let telegram: TelegramService
    let transcription: TranscriptionService

    @Published var projects: [Project] = []
    @Published var sections: [ClaudistCore.Section] = []
    @Published var labels: [ClaudistCore.Label] = []
    @Published var agents: [Agent] = []
    @Published var filters: [SavedFilter] = []
    @Published var storages: [Storage] = []
    @Published var skills: [Skill] = []
    @Published var secrets: [Secret] = []
    @Published var promptTemplates: [PromptTemplate] = []
    @Published var databases: [UserDatabase] = []
    @Published var dashboards: [Dashboard] = []
    @Published var claudeAccounts: [ClaudeAccount] = []
    @Published var miniApps: [MiniApp] = []
    /// App filling the whole window (sidebar hidden, macOS full screen).
    @Published var expandedAppId: ID?
    /// Opens the new-app wizard.
    @Published var showingNewApp = false
    /// Builder chat to show when the App Builder appears, or `"app:<id>"` for a new chat on that app.
    @Published var builderFocus: String?
    /// Locked tasks can be read (the master password was entered).
    @Published var vaultOpen = false
    /// Master password sheet.
    @Published var vaultPrompt: VaultPrompt?
    /// Bumped when the default Claude account changes (it lives in UserDefaults).
    @Published var defaultAccountChanged = 0
    /// Open tasks per project, for sidebar counts.
    @Published var projectCounts: [ID: Int] = [:]
    /// Tasks waiting for the user's decision or permission answer.
    @Published var needsYouCount = 0 {
        didSet { NSApp?.dockTile.badgeLabel = needsYouCount > 0 ? "\(needsYouCount)" : nil }
    }
    /// Open tasks whose latest run failed.
    @Published var failedCount = 0
    /// Agent to show when the Memory screen opens (from the agent editor).
    var memoryAgentId: ID?
    /// Note to open when the Notes screen appears (from a recording).
    var noteToOpen: String?
    @Published var selection: SidebarItem? {
        didSet { if selection != oldValue { taskExpanded = false } }
    }
    /// Text of the sidebar search field; the Search screen shows its matches.
    @Published var searchText = ""
    @Published var selectedTaskId: ID? {
        didSet {
            if let id = selectedTaskId { markReviewed(id) } else { taskExpanded = false }
        }
    }
    /// The open task fills the whole detail area instead of the side panel.
    @Published var taskExpanded = false
    /// Task whose detail should switch to the Agent tab when it opens.
    @Published var agentTabTaskId: ID?
    /// Finished runs the user hasn't opened.
    @Published var reviewCount = 0
    @Published var errorMessage: String?
    @Published var showingExport = false
    /// Open syntax reference (filters or due dates).
    @Published var syntaxHelp: SyntaxHelpTab?

    private var cancellables: [AnyDatabaseCancellable] = []

    init() {
        // CLAUDIST_HOME points the app at another data folder (demo data, screenshots).
        paths = AppPaths(root: (ProcessInfo.processInfo.environment["CLAUDIST_HOME"] ?? ProcessInfo.processInfo.environment["AGENTDESK_HOME"]).map { URL(fileURLWithPath: $0, isDirectory: true) })
        do {
            try paths.ensure()
            db = try AppDatabase.onDisk(at: paths.database)
        } catch {
            fatalError("Could not open the database: \(error)")
        }
        workspace = AgentWorkspace(paths: paths)
        telegram = TelegramService(db: db, secrets: secretStore, paths: paths)
        transcription = TranscriptionService(db: db, paths: paths)
        let writer = db.writer, secrets = secretStore
        Isolation.migrateSetting()
        ClaudeAccounts.defaultAccountEnvironment = {
            let account = (try? writer.read { try ClaudeAccounts.resolve($0, agent: nil) }) ?? nil
            return (try? ClaudeAccounts.environment(account, secrets: secrets)) ?? [:]
        }
        observe(\.projects) { try Project.order(Column("childOrder"), Column("name")).fetchAll($0) }
        observe(\.sections) { try ClaudistCore.Section.order(Column("sectionOrder")).fetchAll($0) }
        observe(\.labels) { try ClaudistCore.Label.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }
        observe(\.agents) { try Agent.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }
        observe(\.filters) { try SavedFilter.order(Column("itemOrder"), Column("name")).fetchAll($0) }
        observe(\.storages) { try Storage.order(Column("name")).fetchAll($0) }
        observe(\.secrets) { try Secret.order(Column("name")).fetchAll($0) }
        observe(\.promptTemplates) { try PromptTemplate.order(Column("itemOrder"), Column("name")).fetchAll($0) }
        observe(\.databases) { try UserDatabase.order(Column("name")).fetchAll($0) }
        observe(\.claudeAccounts) { try ClaudeAccount.order(Column("itemOrder"), Column("createdAt")).fetchAll($0) }
        observe(\.miniApps) { try MiniApp.order(Column("itemOrder"), Column("createdAt")).fetchAll($0) }
        observe(\.dashboards) { try Dashboard.order(Column("itemOrder"), Column("name")).fetchAll($0) }
        observe(\.needsYouCount) { try Attention.count($0) }
        observe(\.failedCount) { try Failures.count($0) }
        observe(\.reviewCount) { try Reviews.count($0) }
        observe(\.projectCounts) { db in
            var map: [ID: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT projectId, COUNT(*) FROM task WHERE isCompleted = 0 GROUP BY projectId") {
                map[row[0]] = row[1]
            }
            return map
        }
        reloadSkills()
        seedIfEmpty()
        telegram.restart()
    }

    private func observe<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppStore, T>, _ fetch: @escaping @Sendable (Database) throws -> T) {
        let c = ValueObservation.tracking(fetch).removeDuplicates()
            .start(in: db.writer, scheduling: .immediate, onError: { [weak self] in self?.report($0) }) { [weak self] value in
                self?[keyPath: keyPath] = value
            }
        cancellables.append(c)
    }

    func reloadSkills() {
        skills = workspace.library.list()
    }

    func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// Runs a write transaction and surfaces errors in the UI.
    func write(_ block: (Database) throws -> Void) {
        do { try db.writer.write { try block($0) } } catch { report(error) }
    }

    func read<T>(_ block: (Database) throws -> T) -> T? {
        do { return try db.writer.read { try block($0) } } catch { report(error); return nil }
    }

    // MARK: Lookups

    func project(_ id: ID?) -> Project? { projects.first { $0.id == id } }
    func agent(_ id: ID?) -> Agent? { agents.first { $0.id == id } }
    func miniApp(_ id: ID?) -> MiniApp? { miniApps.first { $0.id == id } }
    func sections(of projectId: ID) -> [ClaudistCore.Section] { sections.filter { $0.projectId == projectId } }

    /// Projects in tree order with nesting depth.
    var projectTree: [(project: Project, depth: Int)] {
        var out: [(Project, Int)] = []
        func walk(_ parent: ID?, _ depth: Int) {
            for p in projects where p.parentId == parent && !p.isArchived {
                out.append((p, depth))
                walk(p.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    func markReviewed(_ taskId: ID) {
        write { try Reviews.markReviewed($0, taskId: taskId) }
    }

    // MARK: Agents

    func launchConfig(for agent: Agent) -> AgentLaunchConfig? {
        read { db in
            let skills = try AgentSkill.filter(Column("agentId") == agent.id).fetchAll(db).map(\.skillName)
            let links = try AgentStorage.filter(Column("agentId") == agent.id).fetchAll(db)
            let storages = try links.compactMap { link in
                try Storage.fetchOne(db, key: link.storageId).map { (storage: $0, access: link.access) }
            }
            // Accounts are walls: agents on another Claude account can't be called or looked into.
            let others = try ClaudeAccounts.otherAccountAgents(db, of: agent)
            let foreign = Set(others.map(\.id))
            let delegates = try Delegation.delegates(db, of: agent.id).filter { !foreign.contains($0.id) }
            var config = AgentLaunchConfig(agent: agent, skills: Set(skills), storages: storages, delegates: delegates)
            config.secrets = try Secrets.resolve(db, agentId: agent.id).map(\.secret)
            config.promptTemplates = try PromptTemplates.resolve(db, agentId: agent.id)
            config.integrations = try Integrations.granted(db, agentId: agent.id)
            config.foreignPaths = ClaudeAccounts.foreignPaths(others, own: agent, paths: paths,
                                                              hostConfig: SessionFiles.hostConfigDir(environment: ClaudeCLI.environment()))
            config.databaseFile = paths.database.path
            config.codeGraph = CodeGraph.isEnabled
            return config
        }
    }

    /// Name of the account agents without their own run on.
    var defaultAccountName: String {
        _ = defaultAccountChanged
        return ClaudeAccounts.defaultId.flatMap { id in claudeAccounts.first { $0.id == id }?.name } ?? "This Mac's login"
    }

    /// Opens a task on its Agent tab (the conversation), as from the review and failure lists.
    func openAgentTab(_ taskId: ID) {
        agentTabTaskId = taskId
        selectedTaskId = taskId
    }

    /// Links host files/folders to a task by path (no copy).
    func attach(_ urls: [URL], to taskId: ID) {
        write { db in
            for url in urls where url.isFileURL {
                let a = TaskAttachment(taskId: taskId, url: url)
                if try TaskAttachment.filter(Column("taskId") == taskId && Column("path") == a.path).fetchCount(db) == 0 {
                    try a.insert(db)
                }
            }
        }
    }

    /// Turns skills on for agents and copies them into those agents' folders.
    func enableSkills(_ names: [String], for agentIds: Set<ID>) {
        guard !names.isEmpty, !agentIds.isEmpty else { return }
        write { db in
            for id in agentIds { for name in names { try AgentSkill(agentId: id, skillName: name).save(db) } }
        }
        for agent in agents where agentIds.contains(agent.id) { syncSkills(for: agent) }
    }

    func syncSkills(for agent: Agent) {
        guard let config = launchConfig(for: agent) else { return }
        do {
            try FileManager.default.createDirectory(atPath: agent.folderPath, withIntermediateDirectories: true)
            try workspace.library.sync(agentFolder: URL(fileURLWithPath: agent.folderPath), names: config.skills)
        } catch { report(error) }
    }

    private func seedIfEmpty() {
        write { db in
            // Seed data from the first (Russian UI) builds.
            try db.execute(sql: "UPDATE project SET name = 'My Project' WHERE name = 'Мой проект'")
            try db.execute(sql: "UPDATE filter SET name = 'Overdue & today' WHERE name = 'Просрочено и сегодня'")
            try db.execute(sql: "UPDATE filter SET name = 'Agent work' WHERE name = 'Агенты в работе'")
            // Only a brand-new database gets sample data; deleting every project later must not re-seed.
            guard try Project.fetchCount(db) == 0, try SavedFilter.fetchCount(db) == 0, try Agent.fetchCount(db) == 0 else { return }
            var p = Project(name: "My Project")
            p.color = "blue"
            try p.insert(db)
            try SavedFilter(name: "Overdue & today", query: "overdue | today").insert(db)
            var running = SavedFilter(name: "Agent work", query: "assigned")
            running.groupBy = .run
            try running.insert(db)
        }
    }
}
