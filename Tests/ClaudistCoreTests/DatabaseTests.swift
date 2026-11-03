import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct DatabaseTests {
    let dir: URL
    let path: String

    static let ddl = """
        CREATE TABLE customers (
          -- a person or company we sell to
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL UNIQUE -- display name
        );
        CREATE TABLE deals (
          id INTEGER PRIMARY KEY,
          customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
          amount REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX deals_customer ON deals(customer_id);
        INSERT INTO customers (name) VALUES ('Acme'), ('Globex');
        INSERT INTO deals (customer_id, amount) VALUES (1, 100), (1, 50), (2, 7);
        """

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbtests-\(newID())")
        path = dir.appendingPathComponent("crm.sqlite").path
        try SQLiteFile.create(at: path, ddl: Self.ddl)
    }

    @Test func inspectsTables() throws {
        let tables = try SQLiteFile.tables(path)
        #expect(tables.map(\.name) == ["customers", "deals"])
        let deals = tables[1]
        #expect(deals.rowCount == 3)
        #expect(deals.indexes == ["deals_customer"])
        #expect(deals.columns.first { $0.name == "customer_id" }?.references == "customers.id")
        #expect(deals.columns.first { $0.name == "id" }?.primaryKey == 1)
        #expect(tables[0].sql.contains("-- a person or company"))
        #expect(try SQLiteFile.schemaSQL(path).hasPrefix("CREATE TABLE customers"))
    }

    @Test func createFailureLeavesNoFile() {
        let bad = dir.appendingPathComponent("bad.sqlite").path
        #expect(throws: (any Error).self) { try SQLiteFile.create(at: bad, ddl: "CREATE TABLE x (id INTEGER); CREATE TABLE x (id INTEGER);") }
        #expect(!FileManager.default.fileExists(atPath: bad))
    }

    @Test func readOnlyRunsCannotWrite() throws {
        let r = try SQLiteFile.run(path, sql: "SELECT name FROM customers ORDER BY id", readOnly: true)
        #expect(r.columns == ["name"])
        #expect(r.rows.map { QueryResult.text($0[0]) } == ["Acme", "Globex"])
        #expect(throws: (any Error).self) { try SQLiteFile.run(path, sql: "DELETE FROM deals", readOnly: true) }
        #expect(try SQLiteFile.run(path, sql: "SELECT COUNT(*) FROM deals", readOnly: true).rows[0][0] == 3.databaseValue)
    }

    @Test func attachIsRefused() throws {
        let other = dir.appendingPathComponent("other.sqlite").path
        try SQLiteFile.create(at: other, ddl: "CREATE TABLE secrets (v TEXT); INSERT INTO secrets VALUES ('x');")
        #expect(throws: (any Error).self) { try SQLiteFile.run(path, sql: "ATTACH DATABASE '\(other)' AS o", readOnly: false) }
        #expect(throws: (any Error).self) { try SQLiteFile.run(path, sql: "ATTACH DATABASE '\(other)' AS o", readOnly: true) }
    }

    @Test func writesAreAtomicAndReturnLastRows() throws {
        let r = try SQLiteFile.run(path, sql: "INSERT INTO customers (name) VALUES ('Initech'); SELECT COUNT(*) AS n FROM customers", readOnly: false)
        #expect(r.changes == 1)
        #expect(r.statements == 2)
        #expect(r.rows[0][0] == 3.databaseValue)
        // The second statement fails: the first one is rolled back.
        #expect(throws: (any Error).self) {
            try SQLiteFile.run(path, sql: "INSERT INTO customers (name) VALUES ('Umbrella'); INSERT INTO customers (name) VALUES ('Acme')", readOnly: false)
        }
        #expect(try SQLiteFile.run(path, sql: "SELECT COUNT(*) FROM customers WHERE name = 'Umbrella'", readOnly: true).rows[0][0] == 0.databaseValue)
    }

    @Test func truncatesLongResults() throws {
        let r = try SQLiteFile.run(path, sql: "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 50) SELECT i FROM n",
                                   readOnly: true, maxRows: 10)
        #expect(r.rows.count == 10)
        #expect(r.truncated)
    }

    @Test func previewChecksChangesAgainstSchema() throws {
        let schema = try SQLiteFile.schemaSQL(path)
        let tables = try SQLiteFile.preview(schema: schema, change: "ALTER TABLE deals ADD COLUMN stage TEXT NOT NULL DEFAULT 'new' CHECK (stage IN ('new', 'won', 'lost'))")
        #expect(tables.first { $0.name == "deals" }?.columns.map(\.name) == ["id", "customer_id", "amount", "stage"])
        #expect(throws: (any Error).self) { try SQLiteFile.preview(schema: schema, change: "ALTER TABLE nope ADD COLUMN x TEXT") }
        // Nothing touched the real file.
        #expect(try SQLiteFile.tables(path)[1].columns.count == 3)
    }

    @Test func migratesWithBackupAndRebuild() throws {
        let backup = dir.appendingPathComponent("backups/crm.sqlite")
        // A table rebuild: needs foreign keys off while it runs.
        try SQLiteFile.migrate(path, sql: """
            CREATE TABLE customers_new (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, email TEXT);
            INSERT INTO customers_new (id, name) SELECT id, name FROM customers;
            DROP TABLE customers;
            ALTER TABLE customers_new RENAME TO customers;
            """, backup: backup)
        #expect(try SQLiteFile.tables(path)[0].columns.map(\.name) == ["id", "name", "email"])
        #expect(try SQLiteFile.run(path, sql: "SELECT COUNT(*) FROM deals", readOnly: true).rows[0][0] == 3.databaseValue)
        #expect(try SQLiteFile.tables(backup.path)[0].columns.count == 2)
        // Broken references roll the whole migration back.
        #expect(throws: (any Error).self) { try SQLiteFile.migrate(path, sql: "DELETE FROM customers WHERE id = 1", backup: nil) }
        #expect(try SQLiteFile.run(path, sql: "SELECT COUNT(*) FROM customers", readOnly: true).rows[0][0] == 2.databaseValue)
    }

    // MARK: Agent tools

    private func grants(_ access: StorageAccess) -> [DatabaseGrant] {
        var d = UserDatabase(name: "crm", path: path)
        d.description = "Sales"
        return [DatabaseGrant(database: d, access: access)]
    }

    @Test func toolsRespectAccess() throws {
        let ro = grants(.ro)
        #expect(DatabaseAccess.toolNames(ro) == ["db_schema", "db_query"])
        #expect(DatabaseAccess.toolDefinitions(ro).count == 2)
        #expect(DatabaseAccess.toolNames(grants(.rw)).contains("db_execute"))
        #expect(DatabaseAccess.toolNames([]).isEmpty)

        let q = DatabaseAccess.call("db_query", arguments: .object(["database": .string("crm"), "sql": .string("SELECT name FROM customers WHERE id = ?"),
                                                                     "params": .array([.number(2)])]), grants: ro)
        #expect(!q.isError)
        #expect(q.text.contains("Globex"))

        let write = DatabaseAccess.call("db_query", arguments: .object(["database": .string("crm"), "sql": .string("DELETE FROM deals")]), grants: ro)
        #expect(write.isError)
        let exec = DatabaseAccess.call("db_execute", arguments: .object(["database": .string("crm"), "sql": .string("DELETE FROM deals")]), grants: ro)
        #expect(exec.isError && exec.text.contains("read-only"))
        let unknown = DatabaseAccess.call("db_query", arguments: .object(["database": .string("hr"), "sql": .string("SELECT 1")]), grants: ro)
        #expect(unknown.isError && unknown.text.contains("crm"))

        let done = DatabaseAccess.call("db_execute", arguments: .object(["database": .string("crm"),
                                                                          "sql": .string("UPDATE deals SET amount = amount * 2")]), grants: grants(.rw))
        #expect(!done.isError && done.text.contains("\"changes\":3"))

        let schema = DatabaseAccess.call("db_schema", arguments: .object(["database": .string("crm")]), grants: ro)
        #expect(schema.text.contains("TABLE deals — 3 rows"))
    }

    @Test func promptAndEnvironment() throws {
        let prompt = try #require(DatabaseAccess.promptSection(grants(.ro)))
        #expect(prompt.contains("`crm` (read-only): Sales"))
        #expect(prompt.contains("customers(id, name)"))
        #expect(!prompt.contains("db_execute"))
        let env = DatabaseAccess.environment(grants(.ro))
        #expect(env["DB_CRM_PATH"] == path)
        #expect(env["DB_CRM_URI"]?.hasSuffix("?mode=ro") == true)
        #expect(UserDatabase(name: "my-db 2", path: "").envPrefix == "DB_MY_DB_2")
        #expect(UserDatabase.normalizedName("  Sales CRM!  ") == "sales_crm")
        #expect(UserDatabase.normalizedName("…") == "database")
    }

    @Test func grantsMergeAgentAndTask() throws {
        let app = try AppDatabase.inMemory()
        try app.writer.write { db in
            var project = Project(name: "P")
            try project.insert(db)
            let agent = Agent(name: "A", folderPath: "/tmp/a")
            try agent.insert(db)
            let task = TaskItem(projectId: project.id, content: "T")
            try task.insert(db)
            let crm = UserDatabase(name: "crm", path: path)
            let hr = UserDatabase(name: "hr", path: path)
            let other = UserDatabase(name: "other", path: path)
            for d in [crm, hr, other] { try d.insert(db) }
            try AgentDatabase(agentId: agent.id, databaseId: crm.id, access: .ro).insert(db)
            try TaskDatabase(taskId: task.id, databaseId: crm.id, access: .rw).insert(db)
            try TaskDatabase(taskId: task.id, databaseId: hr.id, access: .ro).insert(db)

            let grants = try UserDatabase.grants(db, agentId: agent.id, taskId: task.id)
            #expect(grants.map(\.database.name) == ["crm", "hr"])
            #expect(grants.map(\.access) == [.rw, .ro])
            #expect(try UserDatabase.grants(db, agentId: agent.id, taskId: nil).map(\.access) == [.ro])
        }
    }

    @Test func workspaceAllowsDatabaseTools() throws {
        let root = dir.appendingPathComponent("app")
        let ws = AgentWorkspace(paths: AppPaths(root: root))
        var config = AgentLaunchConfig(agent: Agent(name: "A", folderPath: root.appendingPathComponent("a").path), skills: [], storages: [])
        config.databases = grants(.rw)
        let allow = (ws.settings(config)["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__claudist__db_execute"))
        let args = ws.arguments(config, settingsURL: root.appendingPathComponent("s.json"), resume: nil)
        #expect(args[args.firstIndex(of: "--append-system-prompt")! + 1].contains("## Databases"))
    }

    // MARK: Schema generation

    @Test func extractsLastSQLBlock() {
        let answer = "Design:\n```sql\nCREATE TABLE a (id INTEGER);\n```\nFixed:\n```SQL\nCREATE TABLE b (id INTEGER);\n```\nDone."
        #expect(SchemaGenerator.extractSQL(answer) == "CREATE TABLE b (id INTEGER);")
        #expect(SchemaGenerator.extractSQL("no code") == nil)
        #expect(SchemaGenerator.extractSQL("```\nSELECT 1;\n```") == "SELECT 1;")
    }

    @Test func samplesInputFiles() throws {
        let small = dir.appendingPathComponent("small.csv")
        try "a,b\n1,2\n".write(to: small, atomically: true, encoding: .utf8)
        #expect(SchemaGenerator.sample(small).complete)

        let big = dir.appendingPathComponent("big.csv")
        try (["id,name"] + (1...500).map { "\($0),n\($0)" }).joined(separator: "\n").write(to: big, atomically: true, encoding: .utf8)
        let s = SchemaGenerator.sample(big)
        #expect(!s.complete)
        #expect(s.text.split(separator: "\n").count == SchemaGenerator.sampleLines)

        let sqlite = SchemaGenerator.sample(URL(fileURLWithPath: path))
        #expect(sqlite.text.contains("CREATE TABLE customers"))

        let message = SchemaGenerator.firstMessage(request: "Track sales", samples: [SchemaGenerator.sample(small), s],
                                                   options: { var o = SchemaGenerator.Options(); o.loadData = true; return o }(),
                                                   existing: nil)
        #expect(message.contains("### big.csv (beginning only)"))
        #expect(message.contains("INSERT statements"))
        let change = SchemaGenerator.firstMessage(request: "Add email", samples: [], options: .init(), existing: ("crm", "CREATE TABLE x (id);"))
        #expect(change.contains("`crm`") && change.contains("CREATE TABLE x"))
        #expect(SchemaGenerator.arguments(.init()).contains("--restricted"))
    }
}

/// Run with: CLAUDIST_E2E=1 swift test --filter DatabaseE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1"))
struct DatabaseE2ETests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var process: AgentProcess?
        var result = ""
        var calls: [String] = []
        var permissionAsked = false
    }

    /// Claude designs a schema from a description; it builds on an empty database.
    @Test(.timeLimit(.minutes(4))) func generatesSchema() async throws {
        var options = SchemaGenerator.Options()
        options.model = "haiku"
        let box = Box()
        let done = AsyncStream<Void>.makeStream()
        let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: SchemaGenerator.arguments(options),
                                   cwd: FileManager.default.temporaryDirectory, environment: ClaudeCLI.environment()) { event in
            let p: AgentProcess? = box.lock.withLock { box.process }
            switch event {
            case .message(let kind, let json):
                if kind.hasPrefix("result") {
                    box.lock.withLock { box.result = JSONValue.parse(json)?["result"]?.string ?? "" }
                    p?.closeInput()
                }
            case .permission(let req):
                box.lock.withLock { box.permissionAsked = true }
                p?.respond(req, .deny("no tools"))
            case .exited: done.continuation.finish()
            default: break
            }
        }
        box.lock.withLock { box.process = process }
        try process.start()
        process.send(SchemaGenerator.firstMessage(
            request: "A small library: books, authors (a book may have several), members and loans with due dates.",
            samples: [], options: options, existing: nil))
        for await _ in done.stream {}

        let answer = box.lock.withLock { box.result }
        let sql = try #require(SchemaGenerator.extractSQL(answer), "answer has an sql block: \(answer.prefix(300))")
        let tables = try SQLiteFile.preview(schema: "", change: sql)
        print(sql)
        #expect(tables.filter { !$0.isView }.count >= 4)
        #expect(!box.lock.withLock { box.permissionAsked })
    }

    /// An agent reads a read-only database through the db tools and can't write it.
    @Test(.timeLimit(.minutes(4))) func agentQueriesDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudist-dbe2e-\(newID())")
        let paths = AppPaths(root: root)
        try paths.ensure()
        let file = paths.databases.appendingPathComponent("crm.sqlite").path
        try SQLiteFile.create(at: file, ddl: DatabaseTests.ddl)
        let grants = [DatabaseGrant(database: UserDatabase(name: "crm", path: file), access: .ro)]

        let ws = AgentWorkspace(paths: paths)
        var agent = Agent(name: "Analyst", folderPath: root.appendingPathComponent("a").path)
        agent.model = "haiku"
        agent.tools = "Read"
        var config = AgentLaunchConfig(agent: agent, skills: [], storages: [])
        config.databases = grants
        let args = ws.arguments(config, settingsURL: try ws.prepare(config), resume: nil)

        let box = Box()
        let done = AsyncStream<Void>.makeStream()
        let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: args, cwd: URL(fileURLWithPath: agent.folderPath),
                                   environment: ClaudeCLI.environment().merging(DatabaseAccess.environment(grants)) { a, _ in a }) { event in
            let p: AgentProcess? = box.lock.withLock { box.process }
            switch event {
            case .mcp(let requestId, _, let message):
                let id = message["id"]
                switch message["method"]?.string {
                case "initialize":
                    p?.respondMCP(requestId: requestId, id: id, result: [
                        "protocolVersion": message["params"]?["protocolVersion"]?.string ?? "2025-06-18",
                        "capabilities": ["tools": [:]], "serverInfo": ["name": "claudist", "version": "1"]])
                case "tools/list":
                    p?.respondMCP(requestId: requestId, id: id, result: ["tools": [Attention.toolDefinition()] + DatabaseAccess.toolDefinitions(grants)])
                case "tools/call":
                    let name = message["params"]?["name"]?.string ?? ""
                    box.lock.withLock { box.calls.append(name) }
                    let (text, isError) = DatabaseAccess.call(name, arguments: message["params"]?["arguments"], grants: grants)
                    p?.respondMCP(requestId: requestId, id: id, result: ["content": [["type": "text", "text": text]], "isError": isError])
                default:
                    p?.respondMCP(requestId: requestId, id: id, result: nil)
                }
            case .permission(let req):
                box.lock.withLock { box.permissionAsked = true }
                p?.respond(req, .deny("not in test"))
            case .message(let kind, let json):
                if kind.hasPrefix("result") {
                    box.lock.withLock { box.result = JSONValue.parse(json)?["result"]?.string ?? "" }
                    p?.closeInput()
                }
            case .exited: done.continuation.finish()
            case .stderr: break
            }
        }
        box.lock.withLock { box.process = process }
        try process.start()
        process.initialize(sdkMcpServers: [Delegation.serverName])
        process.send("Using the crm database: what is the total deal amount of the customer Acme? Answer with the number only.")
        for await _ in done.stream {}

        let (result, calls, asked) = box.lock.withLock { (box.result, box.calls, box.permissionAsked) }
        print("calls:", calls, "answer:", result)
        #expect(calls.contains("db_query"))
        #expect(result.contains("150"))
        #expect(!asked, "db tools should be pre-allowed")
    }
}
