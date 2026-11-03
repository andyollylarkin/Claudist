import Foundation
import GRDB

/// Writes a chart query from a plain-language description with Claude.
///
/// Claude gets no tools: the app puts the database schema and a few sample rows into the message,
/// and checks the proposed query read-only before using it.
public enum ChartQueryGenerator {
    public struct Proposal: Sendable, Equatable {
        public var title: String
        public var kind: ChartKind
        public var sql: String
        public var wide: Bool

        public init(title: String, kind: ChartKind, sql: String, wide: Bool) {
            self.title = title
            self.kind = kind
            self.sql = sql
            self.wide = wide
        }
    }

    /// Sample rows per table shown to Claude, so it sees real category names and date formats.
    public static let sampleRows = 3

    public static func arguments(model: String? = nil) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--safe-mode",
            "--restricted",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--permission-prompts", "none",
            "--tools", "",
            "--append-system-prompt", systemPrompt,
        ]
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    public static let systemPrompt = """
        # You write SQLite queries for dashboard charts

        You have no tools. Answer with exactly one ```json code block and nothing else:
        {"title": "short chart title in the user's language", "kind": "number|pie|bar|line", "wide": false, "sql": "SELECT …"}

        ## Query shape
        - number: one row; the first number column is the value shown big. Name it as the caption, with units when \
        known: SELECT SUM(amount) AS "Spent in October, ₽". Use for totals, balances, counts, averages.
        - pie: label column first, then one number column; positive values; shares of a whole (by category, by account). \
        Order by the value descending.
        - bar: label column first, then one or more number columns, one series each (e.g. month, income, expense). \
        Comparing categories or periods.
        - line: like bar, for a trend over ordered labels (days, weeks, months); order by the label ascending.
        - Pick the kind the user asks for; otherwise the one that fits the question. wide = true for long time series \
        or many categories.

        ## Rules
        - SQLite dialect, read-only: one SELECT (WITH allowed). No PRAGMA, ATTACH or changes.
        - Use only tables and columns from the schema. Look at the sample rows for value formats (dates, signs of \
        amounts, category names) and filter accordingly.
        - Relative periods use the current date: date('now', 'localtime'), date('now', 'start of month', 'localtime'), \
        strftime('%Y-%m', date_column).
        - Labels are readable: month as 'YYYY-MM', NULL categories as COALESCE(category, 'Other').
        - Round money to 2 decimals: ROUND(SUM(amount), 2).
        - When you are given a current query and a change, return the whole new query.
        - When the query fails, you get the error: answer again with a fixed block.
        """

    /// Schema and sample rows of a database as Claude sees them.
    public static func context(path: String) throws -> String {
        let queue = try SQLiteFile.open(path, readOnly: true)
        defer { try? queue.close() }
        return try queue.read { db in
            let tables = try SQLiteFile.tables(db)
            guard !tables.isEmpty else { return "-- the database is empty: no tables" }
            var text = "```sql\n" + (try SQLiteFile.schemaSQL(db)) + "\n```"
            for t in tables {
                let result = try SQLiteFile.run(db, sql: "SELECT * FROM \(SQLiteFile.quote(t.name)) LIMIT \(sampleRows)", maxRows: sampleRows)
                guard !result.rows.isEmpty else { continue }
                text += "\n\nSample rows of \(t.name)\(t.rowCount.map { " (\($0) rows in all)" } ?? ""):\n"
                text += result.rows.map { row in
                    zip(result.columns, row).map { "\($0)=\(String(QueryResult.text($1).prefix(80)))" }.joined(separator: ", ")
                }.joined(separator: "\n")
            }
            return text
        }
    }

    public static func message(request: String, database: String, context: String, current: Proposal?) -> String {
        var text = """
            Database `\(database)`:

            \(context)

            Today is \(LocalDate.stamp(Date()).prefix(10)).
            """
        if let current, !current.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += """


                The chart now (\(current.kind.rawValue), "\(current.title)"):
                ```sql
                \(current.sql)
                ```
                Change it: \(request)
                """
        } else {
            text += "\n\nChart: \(request)"
        }
        return text
    }

    public static func fixMessage(error: String) -> String {
        "The query failed: \(error)\nAnswer again with a fixed ```json block."
    }

    /// The JSON object of an answer (last ```json block, or the bare object).
    public static func parse(_ text: String) -> Proposal? {
        var body: String?
        if let regex = try? NSRegularExpression(pattern: "```(?:json)?[ \\t]*\\n([\\s\\S]*?)```", options: [.caseInsensitive]),
           let last = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
           let r = Range(last.range(at: 1), in: text) {
            body = String(text[r])
        } else if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            body = String(text[start...end])
        }
        guard let body, let json = JSONValue.parse(body),
              let sql = json["sql"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty else { return nil }
        return Proposal(title: json["title"]?.string ?? "", kind: ChartKind(rawValue: json["kind"]?.string ?? "") ?? .bar,
                        sql: sql, wide: json["wide"]?.bool ?? false)
    }
}
