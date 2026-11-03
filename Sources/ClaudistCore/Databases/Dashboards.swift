import Foundation
import GRDB

/// A page of charts over the user's databases.
public struct Dashboard: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: ID = newID()
    public var name: String
    public var itemOrder = 0
    public var createdAt = LocalDate.stamp(Date())

    public init(name: String) {
        self.name = name
    }
}

public enum ChartKind: String, Codable, CaseIterable, Sendable {
    case number, pie, bar, line

    public var title: String {
        switch self {
        case .number: "Number"
        case .pie: "Pie"
        case .bar: "Bar"
        case .line: "Line"
        }
    }

    public var symbol: String {
        switch self {
        case .number: "number.square"
        case .pie: "chart.pie"
        case .bar: "chart.bar"
        case .line: "chart.xyaxis.line"
        }
    }
}

/// One chart: a read-only query on a database and how to draw its rows.
///
/// The query returns a label column first (category, month, …) and one or more number columns,
/// each a series. A pie uses the first number column; a number shows one value (first row, first number).
public struct DashboardChart: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: ID = newID()
    public var dashboardId: ID
    public var databaseId: ID
    public var title: String
    public var kind: ChartKind = .bar
    public var sql: String
    /// Takes the whole row of the dashboard instead of half.
    public var wide = false
    public var itemOrder = 0
    /// "user", "assistant" or "agent: Name".
    public var author = "user"
    public var createdAt = LocalDate.stamp(Date())
    public var updatedAt = LocalDate.stamp(Date())

    public init(dashboardId: ID, databaseId: ID, title: String, kind: ChartKind, sql: String) {
        self.dashboardId = dashboardId
        self.databaseId = databaseId
        self.title = title
        self.kind = kind
        self.sql = sql
    }
}

/// Rows of a chart query shaped for drawing.
public struct ChartData: Sendable, Equatable {
    public struct Series: Sendable, Equatable {
        public var name: String
        public var values: [Double?]
    }

    public var labelColumn: String
    public var labels: [String]
    public var series: [Series]
    public var truncated = false

    /// Rows a chart reads at most.
    public static let maxRows = 1000

    public init(labelColumn: String, labels: [String], series: [Series]) {
        self.labelColumn = labelColumn
        self.labels = labels
        self.series = series
    }

    public init(_ result: QueryResult, kind: ChartKind = .bar) throws {
        if kind == .number {
            // One value: the first number column of the first row; a leading text column is ignored.
            guard !result.columns.isEmpty else { throw ClaudistError.invalid("The query returns no columns") }
            let column = result.columns.indices.first { i in result.rows.first.map { Self.number($0[i]) != nil } ?? false } ?? (result.columns.count - 1)
            labelColumn = ""
            labels = result.rows.prefix(1).map { _ in "" }
            series = [Series(name: result.columns[column], values: result.rows.prefix(1).map { Self.number($0[column]) })]
            if let first = result.rows.first, Self.number(first[column]) == nil, !first[column].isNull {
                throw ClaudistError.invalid("The value is not a number: \(QueryResult.text(first[column]))")
            }
            return
        }
        guard result.columns.count >= 2 else {
            throw ClaudistError.invalid("A chart query returns a label column first and then one or more number columns, e.g. SELECT category, SUM(amount) … GROUP BY category")
        }
        labelColumn = result.columns[0]
        labels = result.rows.map { row in
            row[0].isNull ? "(none)" : QueryResult.text(row[0])
        }
        series = result.columns.indices.dropFirst().compactMap { i in
            let values = result.rows.map { Self.number($0[i]) }
            // Text columns next to the numbers (notes, names) are not series.
            guard values.contains(where: { $0 != nil }) || result.rows.allSatisfy({ $0[i].isNull }) else { return nil }
            return Series(name: result.columns[i], values: values)
        }
        guard !series.isEmpty else {
            throw ClaudistError.invalid("No number column: after the label column the query must return numbers (SUM(…), COUNT(*), …)")
        }
        truncated = result.truncated
    }

    static func number(_ value: DatabaseValue) -> Double? {
        switch value.storage {
        case .int64(let i): Double(i)
        case .double(let d): d
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        case .null, .blob: nil
        }
    }

    /// Runs a chart query read-only.
    public static func load(path: String, sql: String, kind: ChartKind = .bar) throws -> ChartData {
        try ChartData(SQLiteFile.run(path, sql: sql, readOnly: true, maxRows: maxRows), kind: kind)
    }

    /// The single value of a number chart.
    public var value: Double? { series.first?.values.first ?? nil }

    /// Pie slices of the first series: positive values, the smallest beyond `limit` merged into "Other".
    public func slices(limit: Int = 9) -> [(label: String, value: Double)] {
        guard let values = series.first?.values else { return [] }
        let all = zip(labels, values).compactMap { label, value in value.flatMap { $0 > 0 ? (label: label, value: $0) : nil } }
        guard all.count > limit + 1 else { return all }
        let sorted = all.sorted { $0.value > $1.value }
        return Array(sorted.prefix(limit)) + [(label: "Other", value: sorted.dropFirst(limit).map(\.value).reduce(0, +))]
    }
}

/// Dashboard tools on the app's `claudist` MCP server, for agents (limited to their databases)
/// and the assistant (all databases). Chart queries always run read-only.
public enum DashboardTools {
    public static let listTool = "list_dashboards"
    public static let saveTool = "save_chart"
    public static let deleteTool = "delete_chart"
    public static let toolNames: Set<String> = [listTool, saveTool, deleteTool]

    public static func qualified(_ tool: String) -> String { "mcp__\(Delegation.serverName)__\(tool)" }

    static let saveDescription = """
        Create or change a chart on a dashboard in Claudist (the user sees it on the Dashboards screen). The query is \
        read-only SQL whose first column is the label (category, month, …) and the next columns are numbers, one series \
        each; a pie uses the first number column. Kinds: number (one big value such as a balance or a monthly total: \
        the query returns one row, e.g. SELECT SUM(amount) AS "Balance, EUR"; the column name is shown as the caption), \
        pie (shares of a whole), bar (compare categories or periods, several series side by side), line (a trend over \
        ordered labels such as months). Order rows in the query. \
        The dashboard is created when it doesn't exist. Pass `id` to change an existing chart. The query is checked \
        and a sample of its rows is returned.
        """

    public static func toolDefinitions(_ grants: [DatabaseGrant]) -> [[String: Any]] {
        guard !grants.isEmpty else { return [] }
        return [
            ["name": listTool, "description": "Dashboards with their charts (only charts on databases you can read).",
             "inputSchema": ["type": "object", "properties": [:] as [String: Any]] as [String: Any]],
            ["name": saveTool, "description": saveDescription, "inputSchema": saveSchema(grants.map(\.database.name))],
            ["name": deleteTool, "description": "Delete a chart from its dashboard.",
             "inputSchema": ["type": "object", "properties": ["id": ["type": "string", "description": "Chart id"]],
                             "required": ["id"]] as [String: Any]],
        ]
    }

    public static func saveSchema(_ databases: [String]?) -> [String: Any] {
        var database: [String: Any] = ["type": "string", "description": "Database name"]
        if let databases { database["enum"] = databases }
        return [
            "type": "object",
            "properties": [
                "dashboard": ["type": "string", "description": "Dashboard name"],
                "id": ["type": "string", "description": "Chart id, to change an existing chart"],
                "title": ["type": "string"],
                "kind": ["type": "string", "enum": ChartKind.allCases.map(\.rawValue)],
                "database": database,
                "sql": ["type": "string", "description": "SELECT label, number[, number…] …"],
                "wide": ["type": "boolean", "description": "Full width instead of half (long time series, many categories)"],
            ] as [String: Any],
            "required": ["dashboard", "title", "kind", "database", "sql"],
        ]
    }

    /// Prompt lines for agents with databases.
    public static func promptLines(writable: Bool) -> String {
        var text = """
            To show data to the user, build charts with `\(qualified(saveTool))` (number, pie, bar, line) on a dashboard; \
            `\(qualified(listTool))` shows the existing ones — update a chart (pass its id) instead of adding a duplicate.
            """
        if writable {
            text += """
                 When several charts share logic, put it in an SQL view (CREATE VIEW … with \
                `\(DatabaseAccess.qualified(DatabaseAccess.executeTool))` on a database you can write) and chart the view.
                """
        }
        return text
    }

    /// Runs one tool call for `author` with access to `grants`. Returns the text answer and whether it is an error.
    public static func call(_ tool: String, arguments: JSONValue?, db: DatabaseWriter, grants: [DatabaseGrant],
                            author: String) -> (text: String, isError: Bool) {
        let a = arguments ?? .object([:])
        let byId = Dictionary(grants.map { ($0.database.id, $0) }, uniquingKeysWith: { first, _ in first })
        do {
            switch tool {
            case listTool:
                return (try db.read { try list($0, visible: byId) }, false)
            case saveTool:
                return (try save(a, db: db, grants: grants, byId: byId, author: author), false)
            case deleteTool:
                let id = a["id"]?.string ?? ""
                return try db.write { db in
                    guard let chart = try DashboardChart.fetchOne(db, key: id) else { throw ClaudistError.invalid("No chart with id \(id)") }
                    guard byId[chart.databaseId] != nil else { throw ClaudistError.invalid("The chart “\(chart.title)” uses a database you have no access to") }
                    try chart.delete(db)
                    return (AssistantTools.ok("Deleted chart “\(chart.title)”"), false)
                }
            default:
                return ("Unknown tool \(tool)", true)
            }
        } catch {
            return ((error as? LocalizedError)?.errorDescription ?? "\(error)", true)
        }
    }

    private static func list(_ db: Database, visible: [ID: DatabaseGrant]) throws -> String {
        let charts = try DashboardChart.order(Column("itemOrder")).fetchAll(db)
        let dashboards = try Dashboard.order(Column("itemOrder"), Column("name")).fetchAll(db).map { d -> [String: Any] in
            ["id": d.id, "name": d.name, "charts": charts.filter { $0.dashboardId == d.id && visible[$0.databaseId] != nil }.map { c in
                ["id": c.id, "title": c.title, "kind": c.kind.rawValue, "database": visible[c.databaseId]!.database.name,
                 "sql": c.sql, "wide": c.wide, "author": c.author] as [String: Any]
            }]
        }
        return AssistantTools.encode(["dashboards": dashboards])
    }

    private static func save(_ a: JSONValue, db: DatabaseWriter, grants: [DatabaseGrant], byId: [ID: DatabaseGrant],
                             author: String) throws -> String {
        let name = try AssistantTools.require(a, "database")
        guard let grant = grants.first(where: { $0.database.name == name }) else {
            throw ClaudistError.invalid("Unknown database \(name). Available: \(grants.map(\.database.name).joined(separator: ", "))")
        }
        guard let kind = ChartKind(rawValue: a["kind"]?.string ?? "") else {
            throw ClaudistError.invalid("kind must be one of \(ChartKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let sql = try AssistantTools.require(a, "sql")
        let title = try AssistantTools.require(a, "title")
        let dashboardName = try AssistantTools.require(a, "dashboard").trimmingCharacters(in: .whitespaces)
        // Check the query before saving anything, so the caller can fix it.
        let data: ChartData
        do {
            data = try ChartData.load(path: grant.database.path, sql: sql, kind: kind)
        } catch let error as DatabaseError {
            throw ClaudistError.invalid("The query failed: \(error.message ?? error.localizedDescription)")
        }

        let chart: DashboardChart = try db.write { db in
            let dashboard: Dashboard
            if let existing = try Dashboard.filter(sql: "name = ? COLLATE NOCASE", arguments: [dashboardName]).fetchOne(db) {
                dashboard = existing
            } else {
                var d = Dashboard(name: dashboardName)
                d.itemOrder = (try Int.fetchOne(db, sql: "SELECT MAX(itemOrder) FROM dashboard") ?? 0) + 1
                try d.insert(db)
                dashboard = d
            }
            var chart: DashboardChart
            if let id = a["id"]?.string, !id.isEmpty {
                guard let existing = try DashboardChart.fetchOne(db, key: id) else { throw ClaudistError.invalid("No chart with id \(id)") }
                guard byId[existing.databaseId] != nil else {
                    throw ClaudistError.invalid("The chart “\(existing.title)” uses a database you have no access to")
                }
                chart = existing
                if chart.dashboardId != dashboard.id {
                    chart.dashboardId = dashboard.id
                    chart.itemOrder = try nextOrder(db, dashboard.id)
                }
                chart.databaseId = grant.database.id
                chart.title = title
                chart.kind = kind
                chart.sql = sql
                chart.updatedAt = LocalDate.stamp(Date())
            } else {
                chart = DashboardChart(dashboardId: dashboard.id, databaseId: grant.database.id, title: title, kind: kind, sql: sql)
                chart.itemOrder = try nextOrder(db, dashboard.id)
                chart.author = author
            }
            if let wide = a["wide"]?.bool { chart.wide = wide }
            try chart.save(db)
            return chart
        }
        var answer: [String: Any] = [
            "ok": true, "id": chart.id, "dashboard": dashboardName,
            "rows": data.labels.count, "label_column": data.labelColumn, "series": data.series.map(\.name),
            "sample": zip(data.labels, data.labels.indices).prefix(5).map { label, i in
                [label] + data.series.map { $0.values[i].map { $0 as Any } ?? NSNull() } as [Any]
            },
        ]
        if data.labels.isEmpty { answer["note"] = "The query returned no rows; the chart is empty for now" }
        if data.truncated { answer["note"] = "Only the first \(ChartData.maxRows) rows are drawn; aggregate or limit the query" }
        if kind == .pie, data.series.count > 1 { answer["note"] = "A pie draws only the first number column (\(data.series[0].name))" }
        return AssistantTools.encode(answer)
    }

    private static func nextOrder(_ db: Database, _ dashboardId: ID) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(itemOrder) FROM dashboardChart WHERE dashboardId = ?", arguments: [dashboardId]) ?? 0) + 1
    }
}
