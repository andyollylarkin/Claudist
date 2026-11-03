import ClaudistCore
import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// SQLite databases agents work with: create, generate, inspect, query.
struct DatabasesView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var usage = Observed<[ID: [String]]>([:])
    @State private var selected: ID?
    @State private var generating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Databases", subtitle: "SQLite databases you can give to agents and tasks") {
                HStack(spacing: 8) {
                    Button { addExisting() } label: { SwiftUI.Label("Add file", systemImage: "doc.badge.plus") }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .help("Register an existing SQLite file; it stays where it is")
                    Button { createEmpty() } label: { SwiftUI.Label("Empty", systemImage: "plus") }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    Button { generating = true } label: { SwiftUI.Label("Generate", systemImage: "sparkles") }
                        .buttonStyle(AccentButtonStyle())
                        .help("Describe the data or drop sample files; Claude designs the schema")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 14)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 260)
                Divider()
                Group {
                    if let database = store.databases.first(where: { $0.id == selected }) {
                        DatabaseDetail(database: database, usedBy: usage.value[database.id] ?? []).id(database.id)
                    } else {
                        ContentUnavailableView("No database selected", systemImage: "cylinder.split.1x2",
                                               description: Text("Generate a schema from a description or sample data, or add an existing SQLite file"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $generating) {
            SchemaGeneratorSheet(existing: nil) { selected = $0.id }
        }
        .onAppear {
            if selected == nil { selected = store.databases.first?.id }
            usage.observe(store.db) { db in
                var map: [ID: [String]] = [:]
                for row in try Row.fetchAll(db, sql: """
                    SELECT l.databaseId, a.name FROM agentDatabase l JOIN agent a ON a.id = l.agentId
                    UNION ALL
                    SELECT l.databaseId, '“' || t.content || '”' FROM taskDatabase l JOIN task t ON t.id = l.taskId
                    WHERE t.isCompleted = 0
                    """) {
                    map[row[0], default: []].append(row[1])
                }
                return map
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.databases) { database in
                    HoverRow(selected: selected == database.id, cornerRadius: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7).fill(Theme.green.opacity(0.12))
                                Image(systemName: "cylinder.split.1x2").font(.system(size: 12)).foregroundStyle(Theme.green)
                            }
                            .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(database.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(selected == database.id ? Theme.accent : Theme.text)
                                if !database.exists {
                                    Text("File missing").font(.system(size: 11)).foregroundStyle(Theme.red)
                                } else if !database.description.isEmpty {
                                    Text(database.description).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                                }
                                let users = usage.value[database.id] ?? []
                                if !users.isEmpty {
                                    Pill(text: users.joined(separator: ", "), icon: "person.2", color: Theme.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = database.id }
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([database.url]) }
                        Divider()
                        Button(database.managed ? "Delete…" : "Remove from Claudist…", role: .destructive) { remove(database) }
                    }
                }
            }
            .padding(8)
        }
        .background(Theme.sidebar)
    }

    private func addExisting() {
        let panel = Finder.openPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "An SQLite database file (.sqlite, .db, …)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try SQLiteFile.tables(url.path)   // fails for files that aren't SQLite
        } catch {
            store.errorMessage = "\(url.lastPathComponent) is not a readable SQLite database: \(error.localizedDescription)"
            return
        }
        guard let name = DatabaseNaming.ask(title: "Add database", suggested: url.deletingPathExtension().lastPathComponent, store: store) else { return }
        let database = UserDatabase(name: name, path: url.standardizedFileURL.path, managed: false)
        store.write { try database.insert($0) }
        selected = database.id
    }

    private func createEmpty() {
        guard let name = DatabaseNaming.ask(title: "New empty database", suggested: "", store: store) else { return }
        do {
            let database = try DatabaseNaming.create(name: name, description: "", ddl: "", store: store)
            selected = database.id
        } catch { store.report(error) }
    }

    private func remove(_ database: UserDatabase) {
        let alert = NSAlert()
        alert.messageText = database.managed ? "Delete database “\(database.name)”?" : "Remove “\(database.name)” from Claudist?"
        alert.informativeText = database.managed
            ? "The file and all its data will be moved to the Trash."
            : "The file stays on disk: \(database.path)"
        alert.addButton(withTitle: database.managed ? "Delete" : "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if database.managed && database.exists {
            do { try FileManager.default.trashItem(at: database.url, resultingItemURL: nil) } catch { store.report(error); return }
        }
        store.write { _ = try database.delete($0) }
        if selected == database.id { selected = store.databases.first { $0.id != database.id }?.id }
    }
}

/// Naming and creating databases in the app's folder.
@MainActor
enum DatabaseNaming {
    static func ask(title: String, suggested: String, store: AppStore) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Agents address the database by this name: letters, digits and underscores."
        let field = NSTextField(string: UserDatabase.normalizedName(suggested.isEmpty ? "database" : suggested))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = UserDatabase.normalizedName(field.stringValue)
        if store.databases.contains(where: { $0.name == name }) {
            store.errorMessage = "A database named \(name) already exists"
            return nil
        }
        return name
    }

    /// New file in the app's databases folder with `ddl` applied.
    static func create(name: String, description: String, ddl: String, store: AppStore) throws -> UserDatabase {
        guard !store.databases.contains(where: { $0.name == name }) else {
            throw ClaudistError.invalid("A database named \(name) already exists")
        }
        var file = store.paths.databases.appendingPathComponent("\(name).sqlite")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = store.paths.databases.appendingPathComponent("\(name)-\(n).sqlite")
            n += 1
        }
        try SQLiteFile.create(at: file.path, ddl: ddl)
        var database = UserDatabase(name: name, path: file.path)
        database.description = description
        try store.db.writer.write { try database.insert($0) }
        return database
    }
}

private struct DatabaseDetail: View {
    @EnvironmentObject var store: AppStore
    let database: UserDatabase
    let usedBy: [String]

    @State private var tab = 0
    @State private var tables: [SQLiteTable] = []
    @State private var schema = ""
    @State private var loadError: String?
    @State private var changing = false
    @State private var description = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(database.name).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                    Spacer()
                    Button { changing = true } label: { SwiftUI.Label("Change with Claude", systemImage: "sparkles") }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .disabled(!database.exists)
                    IconButton(icon: "arrow.clockwise", help: "Reload") { load() }
                    IconButton(icon: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([database.url]) }
                }
                TextField("What it stores — agents see this", text: $description)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .onSubmit(saveDescription)
                HStack(spacing: 12) {
                    Pill(text: database.path, icon: database.managed ? "internaldrive" : "link", color: Theme.tertiary)
                    Pill(text: usedBy.isEmpty ? "Not given to any agent or task" : "Used by " + usedBy.joined(separator: ", "),
                         icon: "person.2", color: Theme.tertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            UnderlineTabs(titles: ["Tables (\(tables.count))", "Data", "SQL", "Schema"], selection: $tab)
                .padding(.horizontal, 24)
            if let loadError {
                Text(loadError).font(.system(size: 12)).foregroundStyle(Theme.red).padding(24)
                Spacer()
            } else {
                switch tab {
                case 0: TablesPane(tables: tables)
                case 1: DataPane(database: database, tables: tables)
                case 2: SQLConsole(database: database, onChange: load)
                default:
                    ScrollView {
                        Text(schema.isEmpty ? "-- no tables yet" : schema)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                }
            }
        }
        .onAppear {
            description = database.description
            load()
        }
        .onDisappear(perform: saveDescription)
        .sheet(isPresented: $changing, onDismiss: load) {
            SchemaGeneratorSheet(existing: database) { _ in load() }
        }
    }

    private func load() {
        guard database.exists else {
            loadError = "The file is missing: \(database.path)"
            return
        }
        do {
            tables = try SQLiteFile.tables(database.path)
            schema = try SQLiteFile.schemaSQL(database.path)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveDescription() {
        guard description != database.description else { return }
        var d = database
        d.description = description
        store.write { try d.update($0) }
    }
}

/// Tables with their columns, keys and row counts.
struct TablesPane: View {
    let tables: [SQLiteTable]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if tables.isEmpty {
                    CardEmpty(text: "No tables yet")
                }
                ForEach(tables) { table in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: table.isView ? "eye" : "tablecells").foregroundStyle(Theme.green)
                            Text(table.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                            if let purpose = Self.purpose(table.sql) {
                                Text(purpose).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let n = table.rowCount {
                                Text("\(n) row\(n == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        Divider()
                        ForEach(table.columns, id: \.name) { column in
                            HStack(spacing: 8) {
                                Image(systemName: column.primaryKey > 0 ? "key.fill" : column.references != nil ? "arrow.turn.down.right" : "circle.fill")
                                    .font(.system(size: column.primaryKey > 0 || column.references != nil ? 10 : 4))
                                    .foregroundStyle(column.primaryKey > 0 ? Color.orange : column.references != nil ? Theme.blue : Theme.tertiary)
                                    .frame(width: 14)
                                Text(column.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                                Text(column.type.isEmpty ? "ANY" : column.type).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.purple)
                                if column.notNull && column.primaryKey == 0 {
                                    Text("NOT NULL").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary)
                                }
                                if let ref = column.references {
                                    Text("→ \(ref)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.blue)
                                }
                                if let def = column.defaultValue {
                                    Text("= \(def)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                        if !table.indexes.isEmpty {
                            Text("Indexes: " + table.indexes.joined(separator: ", "))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
                }
            }
            .padding(24)
        }
    }

    /// The `-- comment` opening a CREATE TABLE body.
    static func purpose(_ sql: String) -> String? {
        guard let open = sql.firstIndex(of: "(") else { return nil }
        let body = sql[sql.index(after: open)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("--") else { return nil }
        return body.dropFirst(2).prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
    }
}

/// First rows of a table.
private struct DataPane: View {
    let database: UserDatabase
    let tables: [SQLiteTable]
    @State private var table: String?
    @State private var result = QueryResult()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                InlineMenu(value: table ?? "Pick a table", options: tables.map { ($0.name, $0.name) }) { table = $0; load() }
                    .fixedSize()
                Spacer()
                if result.truncated { Text("First 200 rows").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                IconButton(icon: "arrow.clockwise", help: "Reload") { load() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).padding(24)
            } else {
                ResultGrid(result: result)
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            if table == nil { table = tables.first?.name }
            load()
        }
    }

    private func load() {
        guard let table else { return }
        do {
            result = try SQLiteFile.run(database.path, sql: "SELECT * FROM \(SQLiteFile.quote(table))", readOnly: true, maxRows: 200)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// SQL console. Read-only unless changes are switched on.
private struct SQLConsole: View {
    let database: UserDatabase
    let onChange: () -> Void
    @AppStorage("sqlConsole.allowChanges") private var allowChanges = false
    @State private var sql = ""
    @State private var result: QueryResult?
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BoxedEditor(text: $sql, minHeight: 110)
            HStack(spacing: 10) {
                Toggle("Allow changes", isOn: $allowChanges).toggleStyle(.checkbox).font(.system(size: 12))
                    .help("Off: the database is opened read-only")
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(failed ? Theme.red : Theme.secondary).lineLimit(3)
                }
                Spacer()
                Button { run() } label: { SwiftUI.Label("Run", systemImage: "play.fill") }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let result, !result.columns.isEmpty {
                ResultGrid(result: result)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebar))
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private func run() {
        do {
            let r = try SQLiteFile.run(database.path, sql: sql, readOnly: !allowChanges, maxRows: 1000)
            result = r
            failed = false
            var parts: [String] = []
            if !r.columns.isEmpty { parts.append("\(r.rows.count)\(r.truncated ? "+" : "") row\(r.rows.count == 1 ? "" : "s")") }
            if r.changes > 0 { parts.append("\(r.changes) change\(r.changes == 1 ? "" : "s")") }
            message = parts.isEmpty ? "Done" : parts.joined(separator: " · ")
            if allowChanges { onChange() }
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }
}

/// Scrollable grid of query rows.
struct ResultGrid: View {
    let result: QueryResult
    private let width: CGFloat = 160

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { i, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                Text(QueryResult.text(value))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(value.isNull ? Theme.tertiary : Theme.text)
                                    .lineLimit(1)
                                    .frame(width: width, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .help(QueryResult.text(value))
                            }
                        }
                        .background(i % 2 == 1 ? Theme.hover.opacity(0.5) : Color.clear)
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(result.columns, id: \.self) { column in
                            Text(column)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .frame(width: width, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                        }
                    }
                    .background(Theme.background)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
            .textSelection(.enabled)
        }
    }
}
