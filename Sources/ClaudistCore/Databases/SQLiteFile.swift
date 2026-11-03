import Foundation
import GRDB
import SQLite3

public struct SQLiteColumn: Sendable, Hashable {
    public var name: String
    public var type: String
    public var notNull: Bool
    /// Position in the primary key (1-based), 0 when not part of it.
    public var primaryKey: Int
    public var defaultValue: String?
    /// `table.column` this column references.
    public var references: String?
}

public struct SQLiteTable: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var isView: Bool
    public var sql: String
    public var columns: [SQLiteColumn]
    public var indexes: [String]
    public var rowCount: Int?
}

/// Rows of the last statement that returned any, and how many rows all statements changed.
public struct QueryResult: Sendable {
    public var columns: [String] = []
    public var rows: [[DatabaseValue]] = []
    public var truncated = false
    public var changes = 0
    public var statements = 0

    public init() {}

    /// Compact JSON for agents.
    public var json: String {
        var object: [String: Any] = ["statements": statements, "changes": changes]
        if !columns.isEmpty {
            object["columns"] = columns
            object["rows"] = rows.map { $0.map(Self.jsonValue) }
            object["rowCount"] = rows.count
            if truncated { object["truncated"] = true }
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonValue(_ value: DatabaseValue) -> Any {
        switch value.storage {
        case .null: NSNull()
        case .int64(let i): i
        case .double(let d): d
        case .string(let s): s
        case .blob(let b): "<blob \(b.count) bytes>"
        }
    }

    /// Cell text for tables in the UI.
    public static func text(_ value: DatabaseValue) -> String {
        switch value.storage {
        case .null: "NULL"
        case .int64(let i): String(i)
        case .double(let d): String(d)
        case .string(let s): s
        case .blob(let b): "<blob \(b.count) bytes>"
        }
    }
}

/// Direct work with SQLite files: inspection, queries and schema changes.
///
/// Every connection forbids ATTACH, so a statement can only reach the file it was opened for;
/// read-only connections are opened read-only by SQLite itself.
public enum SQLiteFile {
    public static func open(_ path: String, readOnly: Bool, foreignKeys: Bool = true) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = readOnly
        config.foreignKeysEnabled = foreignKeys
        config.prepareDatabase { db in
            if let c = db.sqliteConnection { sqlite3_limit(c, SQLITE_LIMIT_ATTACHED, 0) }
        }
        return try DatabaseQueue(path: path, configuration: config)
    }

    /// Creates a new database file with `ddl`. Nothing is left behind on failure.
    public static func create(at path: String, ddl: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { throw ClaudistError.invalid("\(path) already exists") }
        try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let queue = try open(path, readOnly: false)
            try queue.inTransaction { db in
                if !ddl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try db.execute(sql: ddl) }
                return .commit
            }
            try queue.close()
        } catch {
            for suffix in ["", "-journal", "-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
            throw error
        }
    }

    public static func tables(_ path: String) throws -> [SQLiteTable] {
        let queue = try open(path, readOnly: true)
        defer { try? queue.close() }
        return try queue.read { try tables($0) }
    }

    public static func tables(_ db: Database, counts: Bool = true) throws -> [SQLiteTable] {
        let shadow = Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_list WHERE type = 'shadow'"))
        let rows = try Row.fetchAll(db, sql: """
            SELECT type, name, sql FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name
            """)
        return try rows.compactMap { row -> SQLiteTable? in
            let name: String = row["name"]
            guard !shadow.contains(name) else { return nil }
            let q = quote(name)
            var fks: [String: String] = [:]
            for fk in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(q))") {
                let from: String = fk["from"]
                let table: String = fk["table"]
                let to: String? = fk["to"]
                fks[from] = "\(table).\(to ?? "rowid")"
            }
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(q))").map { c in
                SQLiteColumn(name: c["name"], type: c["type"], notNull: c["notnull"], primaryKey: c["pk"],
                             defaultValue: c["dflt_value"], references: fks[c["name"]])
            }
            let isView = (row["type"] as String) == "view"
            let indexes = isView ? [] : try String.fetchAll(db, sql: "SELECT name FROM pragma_index_list(?) WHERE origin = 'c'", arguments: [name])
            let count = counts && !isView ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(q)") : nil
            return SQLiteTable(name: name, isView: isView, sql: row["sql"] ?? "", columns: columns, indexes: indexes, rowCount: count)
        }
    }

    /// The DDL of the whole database, in creation order.
    public static func schemaSQL(_ path: String) throws -> String {
        let queue = try open(path, readOnly: true)
        defer { try? queue.close() }
        return try queue.read { try schemaSQL($0) }
    }

    public static func schemaSQL(_ db: Database) throws -> String {
        let shadow = Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_list WHERE type = 'shadow'"))
        return try Row.fetchAll(db, sql: """
            SELECT name, tbl_name, sql FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY rowid
            """)
            .filter { !shadow.contains($0["name"]) && !shadow.contains($0["tbl_name"]) }
            .map { ($0["sql"] as String) + ";" }
            .joined(separator: "\n\n")
    }

    /// Runs one or more statements. Read-write runs are atomic: all statements or none.
    public static func run(_ path: String, sql: String, readOnly: Bool, maxRows: Int = 500) throws -> QueryResult {
        let queue = try open(path, readOnly: readOnly)
        defer { try? queue.close() }
        if readOnly {
            return try queue.read { try run($0, sql: sql, maxRows: maxRows) }
        }
        var result = QueryResult()
        try queue.inTransaction { db in
            result = try run(db, sql: sql, maxRows: maxRows)
            return .commit
        }
        return result
    }

    static func run(_ db: Database, sql: String, maxRows: Int) throws -> QueryResult {
        var result = QueryResult()
        let before = db.totalChangesCount
        let statements = try db.allStatements(sql: sql)
        while let statement = try statements.next() {
            result.statements += 1
            if statement.columnCount > 0 {
                result.columns = statement.columnNames
                result.rows = []
                result.truncated = false
                let rows = try Row.fetchCursor(statement)
                while let row = try rows.next() {
                    if result.rows.count >= maxRows { result.truncated = true; break }
                    result.rows.append(Array(row.databaseValues))
                }
            } else {
                try statement.execute()
            }
        }
        result.changes = db.totalChangesCount - before
        return result
    }

    /// Checks a schema change against an empty copy of the current schema and returns the
    /// resulting tables. Throws the SQLite error when the change doesn't apply.
    public static func preview(schema: String, change: String) throws -> [SQLiteTable] {
        let queue = try DatabaseQueue()
        return try queue.writeWithoutTransaction { db in
            if !schema.isEmpty { try db.execute(sql: schema) }
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.inTransaction {
                try db.execute(sql: change)
                try checkForeignKeys(db)
                return .commit
            }
            return try tables(db, counts: false)
        }
    }

    /// Applies a schema change to a real database in one transaction, after copying the file to `backup`.
    /// Foreign keys are off while it runs (table rebuilds need that) and checked before commit.
    public static func migrate(_ path: String, sql: String, backup: URL?) throws {
        if let backup {
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = try open(path, readOnly: true)
            let copy = try DatabaseQueue(path: backup.path)
            try source.backup(to: copy)
            try copy.close()
            try source.close()
        }
        let queue = try open(path, readOnly: false, foreignKeys: false)
        defer { try? queue.close() }
        try queue.inTransaction { db in
            try db.execute(sql: sql)
            try checkForeignKeys(db)
            return .commit
        }
    }

    private static func checkForeignKeys(_ db: Database) throws {
        let broken = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        if let first = broken.first {
            throw ClaudistError.invalid("Foreign key check failed: \(broken.count) row(s), first in table \(first[0] as String? ?? "?")")
        }
    }

    /// Copies a live database (consistent even while it is open elsewhere).
    public static func copy(_ path: String, to dest: URL) throws {
        let source = try open(path, readOnly: true)
        let target = try DatabaseQueue(path: dest.path)
        try source.backup(to: target)
        try target.close()
        try source.close()
    }

    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
