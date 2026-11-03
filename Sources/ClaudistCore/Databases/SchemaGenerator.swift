import Foundation

/// Designs an SQLite schema — or a change to one — with Claude from a description and sample data.
///
/// Claude gets no tools at all: input files are sampled by the app and put into the message,
/// and the answer is SQL that the app checks on an empty in-memory copy before applying it.
public enum SchemaGenerator {
    public struct Options: Sendable {
        public var model: String?
        /// Ask for INSERT statements with the rows of fully included input files.
        public var loadData = false
        public init() {}
    }

    /// One input file as Claude sees it.
    public struct Sample: Sendable, Hashable {
        public var name: String
        public var text: String
        /// The whole file fits into `text`.
        public var complete: Bool
    }

    public static let sampleBytes = 24_000
    public static let sampleLines = 120

    public static func arguments(_ options: Options) -> [String] {
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
        if let model = options.model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    public static let systemPrompt = """
        # You design SQLite databases

        You have no tools. Answer with a few short bullets explaining the design, then exactly one \
        ```sql code block. The app runs that block in one transaction and shows the result to the user.

        ## A new database
        The block is the complete DDL: tables, indexes, views, triggers — and seed rows when asked.

        ## A change to an existing database
        You get its current DDL. The block holds only the migration that turns it into the requested one. \
        Use ALTER TABLE (ADD / RENAME / DROP COLUMN, RENAME TO) where it is enough. For anything else (column \
        types, constraints, keys) rebuild the table: CREATE TABLE x_new, INSERT INTO x_new SELECT … FROM x, \
        DROP TABLE x, ALTER TABLE x_new RENAME TO x, then recreate its indexes, views and triggers. Existing data \
        must survive.

        ## Rules
        - SQLite only. No BEGIN, COMMIT, PRAGMA, ATTACH or VACUUM.
        - snake_case names, plural table names, `id INTEGER PRIMARY KEY` unless a natural key is clearly better.
        - Foreign keys as `REFERENCES table(id) ON DELETE CASCADE|SET NULL|RESTRICT`, and an index on every \
        foreign key column.
        - Types: INTEGER, REAL, TEXT, BLOB. Dates and times as ISO-8601 TEXT; money as INTEGER minor units or REAL \
        when precision is not critical. Booleans as INTEGER with CHECK (x IN (0, 1)).
        - NOT NULL when a value is always known, UNIQUE for natural keys, CHECK for enumerations and ranges, \
        `created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP` where history matters.
        - Comments are the documentation agents read: start every CREATE TABLE body with a `-- what a row is` \
        line and end column lines with `-- meaning, units, allowed values` where the name alone isn't enough. \
        Keep comments inside the parentheses so SQLite stores them.
        - From sample data, infer entities, types and relations; split repeated values into lookup tables only \
        when that helps queries.
        - When the user asks for changes, answer again with the complete block, not a diff of your previous one.
        """

    /// Reads the beginning of an input file. SQLite files contribute their schema.
    public static func sample(_ url: URL) -> Sample {
        let name = url.lastPathComponent
        if let header = try? FileHandle(forReadingFrom: url).read(upToCount: 16),
           header.starts(with: Data("SQLite format 3".utf8)) {
            let ddl = (try? SQLiteFile.schemaSQL(url.path)) ?? ""
            return Sample(name: name, text: "-- schema of an existing SQLite database\n" + ddl, complete: false)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Sample(name: name, text: "(could not be read)", complete: false)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: sampleBytes + 1)) ?? Data()
        if data.prefix(4096).contains(0) {
            return Sample(name: name, text: "(binary file, \(url.pathExtension.uppercased()) — export it as CSV or JSON to include its data)",
                          complete: false)
        }
        var text = String(decoding: data.prefix(sampleBytes), as: UTF8.self)
        var complete = data.count <= sampleBytes
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > sampleLines {
            text = lines.prefix(sampleLines).joined(separator: "\n")
            complete = false
        }
        return Sample(name: name, text: text, complete: complete)
    }

    public static func firstMessage(request: String, samples: [Sample], options: Options,
                                    existing: (name: String, schema: String)?) -> String {
        var text: String
        if let existing {
            text = """
                Change the existing database `\(existing.name)`. Its current DDL:

                ```sql
                \(existing.schema.isEmpty ? "-- empty: no tables yet" : existing.schema)
                ```

                Requested change:
                \(request)
                """
        } else {
            text = "Design a new SQLite database.\n\n\(request)"
        }
        if !samples.isEmpty {
            text += "\n\n## Input data\n"
            for s in samples {
                text += "\n### \(s.name)\(s.complete ? "" : " (beginning only)")\n```\n\(s.text)\n```\n"
            }
            if options.loadData {
                text += "\nAfter the DDL, add INSERT statements loading the rows of the files marked complete. "
                    + "Files given only partly: no rows, the user loads them later."
            }
        }
        return text
    }

    /// The last ```sql block of an answer.
    public static func extractSQL(_ text: String) -> String? {
        let pattern = "```(?:sql|sqlite)?[ \\t]*\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let r = Range(last.range(at: 1), in: text) else { return nil }
        let sql = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        return sql.isEmpty ? nil : sql
    }
}
