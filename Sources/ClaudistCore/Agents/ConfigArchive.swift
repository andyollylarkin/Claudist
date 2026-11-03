import CommonCrypto
import CryptoKit
import Foundation
import GRDB

/// Exports the whole configuration into one .zip and restores it.
///
/// Archive layout:
/// ```
/// manifest.json
/// db.sqlite                     projects, tasks, agents, filters, links, (run history)
/// skills/<name>/...             skill library with attached files
/// agents/<agentId>/folder/...   agent project folders (CLAUDE.md, .claude/ without skill symlinks)
/// agents/<agentId>/memory/...   Claude Code auto-memory of the agent
/// databases/<file>.sqlite       databases created in the app, with their data (optional)
/// secrets.enc                   secret values, AES-GCM with a password (optional)
/// ```
/// Storage folders, task attachments and added database files are host paths: only the paths travel.
public struct ConfigArchive {
    public struct Options: Sendable {
        public var agentFolders = true
        public var runHistory = true
        /// Databases created in the app, with their data.
        public var databases = true
        /// Encrypts secret values with this password; nil leaves values out.
        public var secretsPassword: String?
        public init() {}
    }

    public struct Manifest: Codable, Sendable {
        public var format = 1
        public var app = "Claudist"
        public var exportedAt: String
        /// `<appSupport>/agents` on the exporting machine, to tell default agent folders from custom ones.
        public var agentsRoot: String
        public var agentFolders: Bool
        public var runHistory: Bool
        public var encryptedSecrets: Bool
        public var agents: [AgentEntry]
        /// Files under `databases/` in the archive (absent in older exports).
        public var databaseFiles: [String]?

        public struct AgentEntry: Codable, Sendable {
            public var id: ID
            public var name: String
            public var folderPath: String
            public var hasFolder: Bool
            public var hasMemory: Bool
        }
    }

    public struct ImportReport: Sendable {
        public var projects = 0
        public var tasks = 0
        public var agents = 0
        public var skills = 0
        public var secretsRestored = 0
        public var secretsWithoutValue = 0
        public var keptFolders: [String] = []
        public var backup: URL?
    }

    public enum ArchiveError: LocalizedError {
        case notAnArchive
        case unsupported(Int)
        case wrongPassword
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .notAnArchive: "This file is not an Claudist configuration export."
            case .unsupported(let v): "Export format \(v) is newer than this app supports."
            case .wrongPassword: "Wrong password for the secrets in this export."
            case .tool(let s): s
            }
        }
    }

    public let db: AppDatabase
    public let paths: AppPaths
    public let secretStore: SecretStore
    /// Claude Code's per-project data (`~/.claude/projects`), where auto-memory lives.
    public let claudeProjects: URL

    public init(db: AppDatabase, paths: AppPaths, secretStore: SecretStore,
                claudeProjects: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.db = db
        self.paths = paths
        self.secretStore = secretStore
        self.claudeProjects = claudeProjects
    }

    // MARK: Export

    public func export(to zip: URL, options: Options) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("claudist-export-\(newID())", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        // Database snapshot.
        let snapshot = try DatabaseQueue(path: stage.appendingPathComponent("db.sqlite").path)
        try db.writer.backup(to: snapshot)
        if !options.runHistory {
            try snapshot.writeWithoutTransaction { db in
                try db.execute(sql: "DELETE FROM run")
                try db.execute(sql: "VACUUM")
            }
        }
        let agents = try snapshot.read { try Agent.fetchAll($0) }
        let secrets = try snapshot.read { try Secret.fetchAll($0) }
        let databases = try snapshot.read { try UserDatabase.filter(Column("managed") == true).fetchAll($0) }
        try snapshot.close()

        // Databases created in the app, copied consistently even while in use.
        var databaseFiles: [String] = []
        if options.databases {
            let dir = stage.appendingPathComponent("databases", isDirectory: true)
            for database in databases where database.exists {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = database.url.lastPathComponent
                try SQLiteFile.copy(database.path, to: dir.appendingPathComponent(file))
                databaseFiles.append(file)
            }
        }

        // Skill library.
        if fm.fileExists(atPath: paths.skills.path) {
            try fm.copyItem(at: paths.skills, to: stage.appendingPathComponent("skills"))
        }

        // Agent folders and memory.
        var entries: [Manifest.AgentEntry] = []
        for agent in agents {
            var entry = Manifest.AgentEntry(id: agent.id, name: agent.name, folderPath: agent.folderPath, hasFolder: false, hasMemory: false)
            let dir = stage.appendingPathComponent("agents/\(agent.id)", isDirectory: true)
            if options.agentFolders {
                let folder = URL(fileURLWithPath: agent.folderPath, isDirectory: true)
                if fm.fileExists(atPath: folder.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent("folder")
                    try fm.copyItem(at: folder, to: dest)
                    try removeLibraryLinks(in: dest)
                    entry.hasFolder = true
                }
                let memory = memoryFolder(for: agent.folderPath)
                if fm.fileExists(atPath: memory.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try fm.copyItem(at: memory, to: dir.appendingPathComponent("memory"))
                    entry.hasMemory = true
                }
            }
            entries.append(entry)
        }

        // Secret values, encrypted.
        var encrypted = false
        if let password = options.secretsPassword, !password.isEmpty, !secrets.isEmpty {
            var values: [ID: String] = [:]
            for s in secrets { values[s.id] = try secretStore.value(for: s.id) }
            let plain = try JSONEncoder().encode(values.compactMapValues { $0 })
            try Self.encrypt(plain, password: password).write(to: stage.appendingPathComponent("secrets.enc"))
            encrypted = true
        }

        let manifest = Manifest(exportedAt: LocalDate.stamp(Date()), agentsRoot: paths.agents.path,
                                agentFolders: options.agentFolders, runHistory: options.runHistory,
                                encryptedSecrets: encrypted, agents: entries, databaseFiles: databaseFiles)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"))

        if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
        try Self.ditto(["-c", "-k", "--norsrc", stage.path, zip.path])
    }

    // MARK: Import

    /// Reads the manifest without importing (to ask for a password, show a summary).
    public static func inspect(_ zip: URL) throws -> Manifest {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("claudist-inspect-\(newID())", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try ditto(["-x", "-k", zip.path, tmp.path])
        return try readManifest(tmp)
    }

    /// Replaces the current configuration with the archive. A backup of the current state is
    /// written to `<appSupport>/backups` first. No agent may be running.
    @discardableResult
    public func importArchive(from zip: URL, secretsPassword: String?) throws -> ImportReport {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("claudist-import-\(newID())", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try Self.ditto(["-x", "-k", zip.path, stage.path])
        let manifest = try Self.readManifest(stage)

        // Decrypt first so a wrong password changes nothing.
        var secretValues: [ID: String] = [:]
        let secretsFile = stage.appendingPathComponent("secrets.enc")
        // Without a password the import proceeds and secret values are simply left out.
        if manifest.encryptedSecrets, fm.fileExists(atPath: secretsFile.path), let password = secretsPassword, !password.isEmpty {
            let plain = try Self.decrypt(Data(contentsOf: secretsFile), password: password)
            secretValues = try JSONDecoder().decode([ID: String].self, from: plain)
        }

        var report = ImportReport()
        let backups = paths.root.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent("before-import-\(LocalDate.stamp(Date()).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")).zip")
        var backupOptions = Options()
        backupOptions.secretsPassword = nil
        try export(to: backup, options: backupOptions)
        report.backup = backup

        // Database.
        let source = try DatabaseQueue(path: stage.appendingPathComponent("db.sqlite").path)
        try Schema.migrator().migrate(source)   // older exports get newer tables
        try source.backup(to: db.writer)
        try source.close()

        // Skill library.
        if fm.fileExists(atPath: paths.skills.path) { try fm.removeItem(at: paths.skills) }
        let skills = stage.appendingPathComponent("skills")
        if fm.fileExists(atPath: skills.path) {
            try fm.copyItem(at: skills, to: paths.skills)
        } else {
            try fm.createDirectory(at: paths.skills, withIntermediateDirectories: true)
        }

        // Databases created in the app move to this machine's databases folder.
        if let files = manifest.databaseFiles {
            try fm.createDirectory(at: paths.databases, withIntermediateDirectories: true)
            for file in files {
                let target = paths.databases.appendingPathComponent(file)
                for suffix in ["", "-journal", "-wal", "-shm"] { try? fm.removeItem(atPath: target.path + suffix) }
                try fm.copyItem(at: stage.appendingPathComponent("databases/\(file)"), to: target)
            }
        }
        try db.writer.write { db in
            for var database in try UserDatabase.filter(Column("managed") == true).fetchAll(db) {
                let local = paths.databases.appendingPathComponent(database.url.lastPathComponent).path
                if database.path != local {
                    database.path = local
                    try database.update(db)
                }
            }
        }

        // Agent folders: default ones are restored under this machine's agents folder;
        // custom folders that exist here are left untouched.
        for entry in manifest.agents {
            let archived = stage.appendingPathComponent("agents/\(entry.id)")
            let isDefault = entry.folderPath.hasPrefix(manifest.agentsRoot + "/")
            var target = URL(fileURLWithPath: entry.folderPath, isDirectory: true)
            if isDefault {
                target = paths.agents.appendingPathComponent(URL(fileURLWithPath: entry.folderPath).lastPathComponent, isDirectory: true)
                if entry.hasFolder {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: archived.appendingPathComponent("folder"), to: target)
                }
            } else if fm.fileExists(atPath: target.path) {
                if entry.hasFolder { report.keptFolders.append(target.path) }
            } else {
                target = paths.agents.appendingPathComponent(AppPaths.slug(entry.name), isDirectory: true)
                if entry.hasFolder {
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: archived.appendingPathComponent("folder"), to: target)
                }
            }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            if target.path != entry.folderPath {
                try db.writer.write { db in
                    try db.execute(sql: "UPDATE agent SET folderPath = ? WHERE id = ?", arguments: [target.path, entry.id])
                }
            }
            if entry.hasMemory {
                let memory = memoryFolder(for: target.path)
                try fm.createDirectory(at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: memory.path) { try fm.removeItem(at: memory) }
                try fm.copyItem(at: archived.appendingPathComponent("memory"), to: memory)
            }
        }

        // Skill symlinks for every agent.
        let library = SkillLibrary(root: paths.skills)
        try db.writer.read { db in
            for agent in try Agent.fetchAll(db) {
                let names = try String.fetchAll(db, sql: "SELECT skillName FROM agentSkill WHERE agentId = ?", arguments: [agent.id])
                try library.sync(agentFolder: URL(fileURLWithPath: agent.folderPath), names: Set(names))
            }
        }

        for (id, value) in secretValues {
            try secretStore.setValue(value, for: id)
        }

        try db.writer.read { db in
            report.projects = try Project.fetchCount(db)
            report.tasks = try TaskItem.fetchCount(db)
            report.agents = try Agent.fetchCount(db)
            let secretIds = try String.fetchAll(db, sql: "SELECT id FROM secret")
            report.secretsRestored = secretIds.filter { secretValues[$0] != nil }.count
            report.secretsWithoutValue = secretIds.count - report.secretsRestored
        }
        report.skills = library.list().count
        return report
    }

    // MARK: Helpers

    /// Claude Code keeps per-project auto-memory in `~/.claude/projects/<path with non-alphanumerics as ->/memory`.
    public func memoryFolder(for folderPath: String) -> URL {
        let encoded = String(folderPath.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
        return claudeProjects.appendingPathComponent(encoded).appendingPathComponent("memory")
    }

    /// Skill symlinks point into the library; they are recreated on import.
    private func removeLibraryLinks(in folder: URL) throws {
        let fm = FileManager.default
        let skillsDir = folder.appendingPathComponent(".claude/skills")
        for entry in (try? fm.contentsOfDirectory(atPath: skillsDir.path)) ?? [] {
            let link = skillsDir.appendingPathComponent(entry)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fm.removeItem(at: link)
            }
        }
    }

    private static func readManifest(_ dir: URL) throws -> Manifest {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), ["Claudist", "AgentDesk"].contains(manifest.app)
        else { throw ArchiveError.notAnArchive }
        guard manifest.format <= 1 else { throw ArchiveError.unsupported(manifest.format) }
        return manifest
    }

    static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ArchiveError.tool(text.isEmpty ? "ditto failed" : text)
        }
    }

    // MARK: Crypto: PBKDF2-SHA256 (200k rounds) + AES-GCM. Layout: salt(16) | sealed box.

    static func encrypt(_ plain: Data, password: String) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let sealed = try AES.GCM.seal(plain, using: key(password, salt: salt))
        return salt + sealed.combined!
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        guard data.count > 16 else { throw ArchiveError.wrongPassword }
        let salt = data.prefix(16)
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(16))
            return try AES.GCM.open(box, using: key(password, salt: Data(salt)))
        } catch {
            throw ArchiveError.wrongPassword
        }
    }

    private static func key(_ password: String, salt: Data) -> SymmetricKey {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        _ = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.map { Int8(bitPattern: $0) }, pw.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress!, 32)
            }
        }
        return SymmetricKey(data: out)
    }
}
