import Foundation
import GRDB

/// Agents reach their databases through app-served tools on the `claudist` MCP server.
/// The app opens each file with the granted access, so a read-only grant can't write
/// whatever SQL the agent sends.
public enum DatabaseAccess {
    public static let schemaTool = "db_schema"
    public static let queryTool = "db_query"
    public static let executeTool = "db_execute"
    public static let toolNames: Set<String> = [schemaTool, queryTool, executeTool]
    /// Rows returned to the agent per statement.
    public static let maxRows = 500
    /// Characters of one tool answer, so a huge result doesn't flood the context.
    public static let maxAnswer = 60_000

    public static func qualified(_ tool: String) -> String { "mcp__\(Delegation.serverName)__\(tool)" }

    /// Tools of a run: execute only when some database is writable.
    public static func toolNames(_ grants: [DatabaseGrant]) -> [String] {
        guard !grants.isEmpty else { return [] }
        return grants.contains { $0.access == .rw } ? [schemaTool, queryTool, executeTool] : [schemaTool, queryTool]
    }

    public static func toolDefinitions(_ grants: [DatabaseGrant]) -> [[String: Any]] {
        let all = grants.map(\.database.name)
        let writable = grants.filter { $0.access == .rw }.map(\.database.name)
        func database(_ names: [String]) -> [String: Any] {
            ["type": "string", "enum": names, "description": "Database name"]
        }
        var tools: [[String: Any]] = [
            [
                "name": schemaTool,
                "description": "Tables, views, columns, keys, indexes and row counts of a database, with its DDL.",
                "inputSchema": ["type": "object", "properties": ["database": database(all)], "required": ["database"]] as [String: Any],
            ],
            [
                "name": queryTool,
                "description": """
                    Run read-only SQL (SQLite dialect) on a database and get rows as JSON (at most \(maxRows) rows; \
                    use LIMIT/OFFSET or aggregates for more). Use ? placeholders with `params` for values.
                    """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "database": database(all),
                        "sql": ["type": "string", "description": "SELECT / WITH / PRAGMA statement"],
                        "params": ["type": "array", "description": "Values for ? placeholders"],
                    ] as [String: Any],
                    "required": ["database", "sql"],
                ] as [String: Any],
            ],
        ]
        if !writable.isEmpty {
            tools.append([
                "name": executeTool,
                "description": """
                    Run SQL that changes a database: INSERT, UPDATE, DELETE, CREATE (tables, views, indexes), ALTER, DROP. Several statements \
                    separated by ; run atomically — all or none; don't add BEGIN/COMMIT. Returns the number of changed \
                    rows and the rows of the last statement that returns any (e.g. RETURNING).
                    """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "database": database(writable),
                        "sql": ["type": "string"],
                        "params": ["type": "array", "description": "Values for ? placeholders (single statement only)"],
                    ] as [String: Any],
                    "required": ["database", "sql"],
                ] as [String: Any],
            ])
        }
        return tools
    }

    /// System prompt section describing the databases of a run.
    public static func promptSection(_ grants: [DatabaseGrant]) -> String? {
        guard !grants.isEmpty else { return nil }
        let lines = grants.map { g -> String in
            var line = "- `\(g.database.name)` (\(g.access == .rw ? "read & write" : "read-only"))"
            if !g.database.description.isEmpty { line += ": \(g.database.description)" }
            if let tables = try? SQLiteFile.tables(g.database.path), !tables.isEmpty {
                line += "\n  Tables: " + tables.map { t in "\(t.name)(\(t.columns.map(\.name).joined(separator: ", ")))" }
                    .joined(separator: "; ")
            }
            line += "\n  Scripts: $\(g.database.envPrefix)_PATH is the file, $\(g.database.envPrefix)_URI an SQLite URI with the matching mode."
            return line
        }
        return """
            ## Databases
            You have SQLite databases. Use `\(qualified(schemaTool))` to learn a schema, `\(qualified(queryTool))` to read\
            \(grants.contains { $0.access == .rw } ? " and `\(qualified(executeTool))` to change data" : ""). \
            Prefer these tools; scripts (e.g. of a skill) may open the file through the environment variables below, \
            respecting the access you have.
            \(lines.joined(separator: "\n"))

            \(DashboardTools.promptLines(writable: grants.contains { $0.access == .rw }))
            """
    }

    /// `DB_<NAME>_PATH` and `DB_<NAME>_URI` for scripts.
    public static func environment(_ grants: [DatabaseGrant]) -> [String: String] {
        var env: [String: String] = [:]
        for g in grants {
            env["\(g.database.envPrefix)_PATH"] = g.database.path
            var uri = URLComponents()
            uri.scheme = "file"
            uri.path = g.database.path
            uri.queryItems = [URLQueryItem(name: "mode", value: g.access == .rw ? "rw" : "ro")]
            env["\(g.database.envPrefix)_URI"] = uri.string ?? ""
        }
        return env
    }

    /// Runs one tool call. Returns the text answer and whether it is an error.
    public static func call(_ tool: String, arguments: JSONValue?, grants: [DatabaseGrant]) -> (text: String, isError: Bool) {
        let name = arguments?["database"]?.string ?? ""
        guard let grant = grants.first(where: { $0.database.name == name }) else {
            return ("Unknown database \(name.isEmpty ? "(none given)" : name). Available: \(grants.map(\.database.name).joined(separator: ", "))", true)
        }
        guard grant.database.exists else { return ("The file of database \(name) is missing: \(grant.database.path)", true) }
        do {
            switch tool {
            case schemaTool:
                let tables = try SQLiteFile.tables(grant.database.path)
                return (describe(tables), false)
            case queryTool, executeTool:
                if tool == executeTool && grant.access != .rw {
                    return ("Database \(name) is read-only for you", true)
                }
                let sql = arguments?["sql"]?.string ?? ""
                let params = (arguments?["params"]?.array ?? []).map(\.any)
                let result = try run(grant.database.path, sql: sql, params: params, readOnly: tool == queryTool)
                let text = result.json
                return (text.count > maxAnswer
                        ? String(text.prefix(maxAnswer)) + "\n…answer cut at \(maxAnswer) characters; select fewer columns or rows"
                        : text, false)
            default:
                return ("Unknown tool \(tool)", true)
            }
        } catch {
            return ("SQLite error: \(error.localizedDescription)", true)
        }
    }

    private static func run(_ path: String, sql: String, params: [Any], readOnly: Bool) throws -> QueryResult {
        guard !params.isEmpty else { return try SQLiteFile.run(path, sql: sql, readOnly: readOnly, maxRows: maxRows) }
        // Placeholders bind to a single statement.
        let values = params.map(databaseValue)
        let queue = try SQLiteFile.open(path, readOnly: readOnly)
        defer { try? queue.close() }
        let body = { (db: Database) throws -> QueryResult in
            let statement = try db.makeStatement(sql: sql)
            try statement.setArguments(StatementArguments(values))
            return try SQLiteFile.run(db, statement: statement, maxRows: maxRows)
        }
        if readOnly { return try queue.read(body) }
        var result = QueryResult()
        try queue.inTransaction { db in
            result = try body(db)
            return .commit
        }
        return result
    }

    private static func databaseValue(_ value: Any) -> DatabaseValue {
        switch value {
        case let v as Bool: v.databaseValue
        case let v as Double: v == v.rounded() && abs(v) < 9e15 ? Int64(v).databaseValue : v.databaseValue
        case let v as String: v.databaseValue
        case is NSNull: .null
        default:
            // Objects and arrays are stored as JSON text.
            String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self).databaseValue
        }
    }

    /// Schema in a compact text form for agents.
    public static func describe(_ tables: [SQLiteTable]) -> String {
        guard !tables.isEmpty else { return "The database is empty: no tables." }
        return tables.map { t in
            var text = "\(t.isView ? "VIEW" : "TABLE") \(t.name)" + (t.rowCount.map { " — \($0) rows" } ?? "")
            text += "\n" + t.sql
            if !t.indexes.isEmpty { text += "\nIndexes: \(t.indexes.joined(separator: ", "))" }
            return text
        }.joined(separator: "\n\n")
    }
}

extension SQLiteFile {
    /// Rows of one prepared statement.
    static func run(_ db: Database, statement: Statement, maxRows: Int) throws -> QueryResult {
        var result = QueryResult()
        result.statements = 1
        let before = db.totalChangesCount
        if statement.columnCount > 0 {
            result.columns = statement.columnNames
            let rows = try Row.fetchCursor(statement)
            while let row = try rows.next() {
                if result.rows.count >= maxRows { result.truncated = true; break }
                result.rows.append(Array(row.databaseValues))
            }
        } else {
            try statement.execute()
        }
        result.changes = db.totalChangesCount - before
        return result
    }
}
