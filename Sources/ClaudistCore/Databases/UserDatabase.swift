import Foundation
import GRDB

/// An SQLite database the user works with through agents.
///
/// Databases created in the app live in `<appSupport>/databases` and are deleted with their entry;
/// an existing file added by path stays where it is and is only unregistered.
public struct UserDatabase: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "userDatabase"

    public var id: ID = newID()
    public var name: String
    public var description = ""
    public var path: String
    /// The file belongs to the app (created here) rather than being an existing host file.
    public var managed = true
    public var createdAt = LocalDate.stamp(Date())

    public init(name: String, path: String, managed: Bool = true) {
        self.name = name
        self.path = path
        self.managed = managed
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// `DB_<NAME>`: prefix of the environment variables that point scripts at the file.
    public var envPrefix: String {
        let upper = name.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
        return "DB_" + String(upper)
    }
}

/// Default databases of an agent.
public struct AgentDatabase: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var agentId: ID
    public var databaseId: ID
    public var access: StorageAccess = .ro

    public init(agentId: ID, databaseId: ID, access: StorageAccess) {
        self.agentId = agentId
        self.databaseId = databaseId
        self.access = access
    }
}

/// Databases a task needs, on top of its agent's.
public struct TaskDatabase: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var taskId: ID
    public var databaseId: ID
    public var access: StorageAccess = .ro

    public init(taskId: ID, databaseId: ID, access: StorageAccess) {
        self.taskId = taskId
        self.databaseId = databaseId
        self.access = access
    }
}

/// A database a run may use, with the access it got.
public struct DatabaseGrant: Sendable, Hashable {
    public var database: UserDatabase
    public var access: StorageAccess

    public init(database: UserDatabase, access: StorageAccess) {
        self.database = database
        self.access = access
    }
}

extension UserDatabase {
    /// The agent's databases plus the task's; a database linked to both gets the wider access.
    public static func grants(_ db: Database, agentId: ID?, taskId: ID?) throws -> [DatabaseGrant] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT databaseId, access FROM agentDatabase WHERE agentId = ?
            UNION ALL
            SELECT databaseId, access FROM taskDatabase WHERE taskId = ?
            """, arguments: [agentId, taskId])
        var access: [ID: StorageAccess] = [:]
        for row in rows {
            let id: ID = row[0]
            let a = StorageAccess(rawValue: row[1]) ?? .ro
            if access[id] != .rw { access[id] = a }
        }
        guard !access.isEmpty else { return [] }
        return try UserDatabase.filter(keys: Array(access.keys)).order(Column("name")).fetchAll(db)
            .map { DatabaseGrant(database: $0, access: access[$0.id]!) }
    }

    /// Database names are how agents address them, so they are short identifiers.
    public static func normalizedName(_ name: String) -> String {
        let chars = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
        let parts = String(chars).split(separator: "_", omittingEmptySubsequences: true)
        return parts.isEmpty ? "database" : parts.joined(separator: "_")
    }
}
