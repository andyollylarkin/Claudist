import AgentDeskCore
import Combine
import Foundation
import GRDB
import SwiftUI

enum SidebarItem: Hashable {
    case project(ID)
    case filter(ID)
    case agents
    case skills
    case storage
    case secrets
}

/// App-wide state: the database plus live-observed reference data.
@MainActor
final class AppStore: ObservableObject {
    let db: AppDatabase
    let paths: AppPaths
    let workspace: AgentWorkspace
    let secretStore: SecretStore = KeychainSecretStore()

    @Published var projects: [Project] = []
    @Published var sections: [AgentDeskCore.Section] = []
    @Published var labels: [AgentDeskCore.Label] = []
    @Published var agents: [Agent] = []
    @Published var filters: [SavedFilter] = []
    @Published var storages: [Storage] = []
    @Published var skills: [Skill] = []
    @Published var secrets: [Secret] = []
    /// Open tasks per project, for sidebar counts.
    @Published var projectCounts: [ID: Int] = [:]
    @Published var selection: SidebarItem?
    @Published var selectedTaskId: ID?
    @Published var errorMessage: String?
    @Published var showingExport = false

    private var cancellables: [AnyDatabaseCancellable] = []

    init() {
        // AGENTDESK_HOME points the app at another data folder (demo data, screenshots).
        paths = AppPaths(root: ProcessInfo.processInfo.environment["AGENTDESK_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        do {
            try paths.ensure()
            db = try AppDatabase.onDisk(at: paths.database)
        } catch {
            fatalError("Could not open the database: \(error)")
        }
        workspace = AgentWorkspace(paths: paths)
        observe(\.projects) { try Project.order(Column("childOrder"), Column("name")).fetchAll($0) }
        observe(\.sections) { try AgentDeskCore.Section.order(Column("sectionOrder")).fetchAll($0) }
        observe(\.labels) { try AgentDeskCore.Label.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }
        observe(\.agents) { try Agent.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll($0) }
        observe(\.filters) { try SavedFilter.order(Column("itemOrder"), Column("name")).fetchAll($0) }
        observe(\.storages) { try Storage.order(Column("name")).fetchAll($0) }
        observe(\.secrets) { try Secret.order(Column("name")).fetchAll($0) }
        observe(\.projectCounts) { db in
            var map: [ID: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT projectId, COUNT(*) FROM task WHERE isCompleted = 0 GROUP BY projectId") {
                map[row[0]] = row[1]
            }
            return map
        }
        reloadSkills()
        seedIfEmpty()
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
    func sections(of projectId: ID) -> [AgentDeskCore.Section] { sections.filter { $0.projectId == projectId } }

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

    // MARK: Agents

    func launchConfig(for agent: Agent) -> AgentLaunchConfig? {
        read { db in
            let skills = try AgentSkill.filter(Column("agentId") == agent.id).fetchAll(db).map(\.skillName)
            let links = try AgentStorage.filter(Column("agentId") == agent.id).fetchAll(db)
            let storages = try links.compactMap { link in
                try Storage.fetchOne(db, key: link.storageId).map { (storage: $0, access: link.access) }
            }
            let delegates = try Delegation.delegates(db, of: agent.id)
            var config = AgentLaunchConfig(agent: agent, skills: Set(skills), storages: storages, delegates: delegates)
            config.secrets = try Secrets.resolve(db, agentId: agent.id).map(\.secret)
            return config
        }
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
