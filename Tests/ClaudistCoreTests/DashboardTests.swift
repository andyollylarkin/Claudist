import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct DashboardTests {
    let app: AppDatabase
    let budget: UserDatabase
    let other: UserDatabase

    init() throws {
        app = try AppDatabase.inMemory()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashboards-\(newID())")
        budget = UserDatabase(name: "budget", path: dir.appendingPathComponent("budget.sqlite").path)
        other = UserDatabase(name: "crm", path: dir.appendingPathComponent("crm.sqlite").path)
        try SQLiteFile.create(at: budget.path, ddl: """
            CREATE TABLE expense (id INTEGER PRIMARY KEY, month TEXT, category TEXT, amount REAL, note TEXT);
            INSERT INTO expense (month, category, amount, note) VALUES
              ('2026-09', 'Food', 300, 'a'), ('2026-09', 'Rent', 1000, 'b'),
              ('2026-10', 'Food', 350, 'c'), ('2026-10', 'Taxi', 80, NULL), ('2026-10', 'Rent', 1000, 'd');
            """)
        try SQLiteFile.create(at: other.path, ddl: "CREATE TABLE deal (amount REAL); INSERT INTO deal VALUES (5);")
        try app.writer.write { db in
            try budget.insert(db)
            try other.insert(db)
        }
    }

    private func call(_ tool: String, _ args: [String: JSONValue], grants: [DatabaseGrant]) -> (JSONValue?, Bool) {
        let (text, isError) = DashboardTools.call(tool, arguments: .object(args), db: app.writer, grants: grants, author: "agent: Bob")
        return (JSONValue.parse(text) ?? .string(text), isError)
    }

    @Test func shapesQueryRows() throws {
        let data = try ChartData.load(path: budget.path, sql: """
            SELECT month, SUM(amount) AS total, SUM(CASE WHEN category = 'Food' THEN amount END) AS food, MAX(note) AS note
            FROM expense GROUP BY month ORDER BY month
            """)
        #expect(data.labelColumn == "month")
        #expect(data.labels == ["2026-09", "2026-10"])
        // The text column is not a series.
        #expect(data.series.map(\.name) == ["total", "food"])
        #expect(data.series[0].values == [1300, 1430])

        #expect(throws: (any Error).self) { try ChartData.load(path: budget.path, sql: "SELECT category FROM expense") }
        #expect(throws: (any Error).self) { try ChartData.load(path: budget.path, sql: "SELECT category, note FROM expense") }
        #expect(throws: (any Error).self) { try ChartData.load(path: budget.path, sql: "DELETE FROM expense RETURNING category, amount") }
        #expect(try SQLiteFile.run(budget.path, sql: "SELECT COUNT(*) FROM expense", readOnly: true).rows[0][0] == 5.databaseValue)
    }

    @Test func mergesSmallSlices() {
        let data = ChartData(labelColumn: "c", labels: (1...12).map { "c\($0)" },
                             series: [.init(name: "v", values: (1...12).map { Double($0) } + [])])
        let slices = data.slices(limit: 9)
        #expect(slices.count == 10)
        #expect(slices[0].label == "c12")
        #expect(slices.last?.label == "Other")
        #expect(slices.last?.value == 6.0)
    }

    @Test func agentSavesChartsOnlyOnItsDatabases() throws {
        let grants = [DatabaseGrant(database: budget, access: .ro)]
        let (saved, failed) = call(DashboardTools.saveTool, [
            "dashboard": .string("Budget"), "title": .string("By category"), "kind": .string("pie"), "database": .string("budget"),
            "sql": .string("SELECT category, SUM(amount) FROM expense GROUP BY 1 ORDER BY 2 DESC"),
        ], grants: grants)
        #expect(!failed)
        #expect(saved?["rows"]?.number == 3)
        let id = try #require(saved?["id"]?.string)
        let chart = try #require(try app.writer.read { try DashboardChart.fetchOne($0, key: id) })
        #expect(chart.author == "agent: Bob")
        #expect(try app.writer.read { try Dashboard.fetchCount($0) } == 1)

        // Same dashboard by name (any case); a bad query is reported and nothing is saved.
        let (_, bad) = call(DashboardTools.saveTool, [
            "dashboard": .string("budget"), "title": .string("x"), "kind": .string("bar"), "database": .string("budget"),
            "sql": .string("SELECT nope FROM expense"),
        ], grants: grants)
        #expect(bad)
        #expect(try app.writer.read { try DashboardChart.fetchCount($0) } == 1)

        // No access to the other database: neither new charts nor changes to its charts.
        let (_, denied) = call(DashboardTools.saveTool, [
            "dashboard": .string("Budget"), "title": .string("Deals"), "kind": .string("bar"), "database": .string("crm"),
            "sql": .string("SELECT 'all', SUM(amount) FROM deal"),
        ], grants: grants)
        #expect(denied)
        var foreign = DashboardChart(dashboardId: chart.dashboardId, databaseId: other.id, title: "Deals", kind: .bar, sql: "SELECT 'a', 1")
        try app.writer.write { try foreign.insert($0) }
        #expect(call(DashboardTools.deleteTool, ["id": .string(foreign.id)], grants: grants).1)
        let (list, _) = call(DashboardTools.listTool, [:], grants: grants)
        #expect(list?["dashboards"]?.array?.first?["charts"]?.array?.count == 1)

        // Update in place.
        let (updated, updateFailed) = call(DashboardTools.saveTool, [
            "id": .string(id), "dashboard": .string("Budget"), "title": .string("Monthly"), "kind": .string("line"),
            "database": .string("budget"), "sql": .string("SELECT month, SUM(amount) FROM expense GROUP BY 1 ORDER BY 1"), "wide": .bool(true),
        ], grants: grants)
        #expect(!updateFailed)
        #expect(updated?["id"]?.string == id)
        let changed = try #require(try app.writer.read { try DashboardChart.fetchOne($0, key: id) })
        #expect(changed.kind == .line && changed.wide && changed.title == "Monthly")
        #expect(!call(DashboardTools.deleteTool, ["id": .string(id)], grants: grants).1)
    }

    @Test func deletingADatabaseRemovesItsCharts() throws {
        try app.writer.write { db in
            let d = Dashboard(name: "D")
            try d.insert(db)
            try DashboardChart(dashboardId: d.id, databaseId: budget.id, title: "t", kind: .bar, sql: "SELECT 1, 2").insert(db)
            _ = try budget.delete(db)
            #expect(try DashboardChart.fetchCount(db) == 0)
        }
    }
}

struct ChartNumberAndGeneratorTests {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("charts-\(newID()).sqlite").path
        try SQLiteFile.create(at: path, ddl: """
            CREATE TABLE operation (id INTEGER PRIMARY KEY, day TEXT NOT NULL, category TEXT, amount REAL NOT NULL -- negative: expense
            );
            INSERT INTO operation (day, category, amount) VALUES
              ('2026-10-01', 'Salary', 5000), ('2026-10-03', 'Food', -120.5), ('2026-10-09', 'Rent', -1500),
              ('2026-10-15', 'Food', -80), ('2026-09-20', 'Food', -60);
            """)
    }

    @Test func numberTakesOneValue() throws {
        let one = try ChartData.load(path: path, sql: "SELECT ROUND(SUM(amount), 2) AS \"Balance\" FROM operation", kind: .number)
        #expect(one.value == 3239.5)
        #expect(one.series[0].name == "Balance")
        // A leading text column is skipped; only the first row counts.
        let labelled = try ChartData.load(path: path, sql: "SELECT category, SUM(amount) AS s FROM operation GROUP BY 1 ORDER BY 1", kind: .number)
        #expect(labelled.value == -260.5)
        let empty = try ChartData.load(path: path, sql: "SELECT SUM(amount) FROM operation WHERE 0", kind: .number)
        #expect(empty.value == nil)
        #expect(throws: (any Error).self) { try ChartData.load(path: path, sql: "SELECT 'abc'", kind: .number) }
        // Other kinds still need a label column.
        #expect(throws: (any Error).self) { try ChartData.load(path: path, sql: "SELECT SUM(amount) FROM operation", kind: .bar) }
    }

    @Test func parsesProposalsAndBuildsContext() throws {
        let answer = """
            Here it is:
            ```json
            {"title": "Expenses", "kind": "pie", "wide": false, "sql": "SELECT category, -SUM(amount) FROM operation WHERE amount < 0 GROUP BY 1"}
            ```
            """
        let p = try #require(ChartQueryGenerator.parse(answer))
        #expect(p.kind == .pie && p.title == "Expenses" && p.sql.hasPrefix("SELECT category"))
        #expect(ChartQueryGenerator.parse("{\"kind\": \"number\", \"sql\": \"SELECT 1\"}")?.kind == .number)
        #expect(ChartQueryGenerator.parse("no query") == nil)

        let context = try ChartQueryGenerator.context(path: path)
        #expect(context.contains("CREATE TABLE operation"))
        #expect(context.contains("Sample rows of operation (5 rows in all)"))
        #expect(context.contains("category=Salary"))
        let message = ChartQueryGenerator.message(request: "only food", database: "budget", context: context,
                                                  current: p)
        #expect(message.contains("Change it: only food") && message.contains(p.sql))
    }
}

/// Run with: CLAUDIST_E2E=1 swift test --filter ChartQueryE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1"))
struct ChartQueryE2ETests {
    @Test(.timeLimit(.minutes(3))) func writesQueriesFromDescriptions() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("chart-e2e-\(newID()).sqlite").path
        try SQLiteFile.create(at: path, ddl: """
            CREATE TABLE operation (id INTEGER PRIMARY KEY, day TEXT NOT NULL, category TEXT, amount REAL NOT NULL -- negative: expense
            );
            INSERT INTO operation (day, category, amount) VALUES
              ('2026-10-01', 'Salary', 5000), ('2026-10-03', 'Food', -120.5), ('2026-10-09', 'Rent', -1500),
              ('2026-10-15', 'Food', -80), ('2026-09-20', 'Food', -60), ('2026-09-01', 'Salary', 5000);
            """)
        let context = try ChartQueryGenerator.context(path: path)
        for (request, kind) in [("всего потрачено за всё время, одно число", ChartKind.number),
                                ("расходы по категориям, пирог", .pie)] {
            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var process: AgentProcess?
                var text = ""
            }
            let box = Box()
            let done = AsyncStream<Void>.makeStream()
            let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: ChartQueryGenerator.arguments(model: "haiku"),
                                       cwd: FileManager.default.temporaryDirectory, environment: ClaudeCLI.environment()) { event in
                switch event {
                case .message(let k, let json) where k.hasPrefix("result"):
                    box.lock.withLock { box.text = JSONValue.parse(json)?["result"]?.string ?? "" }
                    box.lock.withLock { box.process }?.closeInput()
                case .exited: done.continuation.finish()
                default: break
                }
            }
            box.lock.withLock { box.process = process }
            try process.start()
            process.send(ChartQueryGenerator.message(request: request, database: "budget", context: context, current: nil))
            for await _ in done.stream {}
            let text = box.lock.withLock { box.text }
            print(request, "→", text)
            let proposal = try #require(ChartQueryGenerator.parse(text))
            #expect(proposal.kind == kind)
            let data = try ChartData.load(path: path, sql: proposal.sql, kind: proposal.kind)
            if kind == .number { #expect(abs(abs(data.value ?? 0) - 1760.5) < 0.01) }
            else { #expect(Set(data.labels) == ["Food", "Rent"]) }
        }
    }
}
