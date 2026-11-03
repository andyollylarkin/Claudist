import ClaudistCore
import AppKit
import GRDB
import SwiftUI

/// One schema design session: Claude proposes SQL, the app checks it on an empty in-memory copy.
@MainActor
final class SchemaGeneration: ObservableObject {
    enum Phase { case form, running, ready, failed }

    @Published var phase: Phase = .form
    @Published var events: [RunEvent] = []
    /// Latest proposal; the user may edit it.
    @Published var sql = "" { didSet { if sql != oldValue { validate() } } }
    @Published var preview: [SQLiteTable] = []
    @Published var validationError: String?

    let existing: UserDatabase?
    /// Current DDL of the database being changed.
    private(set) var baseSchema = ""
    private var firstMessage = ""
    private var options = SchemaGenerator.Options()
    private var process: AgentProcess?
    private let run = Run(taskId: "schema-draft", agentId: nil)
    private var seq: Int64 = 0

    init(existing: UserDatabase?) {
        self.existing = existing
    }

    var transcript: [TranscriptItem] {
        TranscriptItem.build(runs: [run], events: events, agentName: "Claude").filter {
            if case .runHeader = $0.kind { return false }
            return true
        }
    }

    func start(request: String, files: [URL], options: SchemaGenerator.Options) throws {
        self.options = options
        if let existing { baseSchema = try SQLiteFile.schemaSQL(existing.path) }
        let samples = files.map(SchemaGenerator.sample)
        firstMessage = SchemaGenerator.firstMessage(request: request, samples: samples, options: options,
                                                    existing: existing.map { ($0.name, baseSchema) })
        var shown = request
        if !files.isEmpty { shown += "\n\nInput: " + files.map(\.lastPathComponent).joined(separator: ", ") }
        record("user/input", ["text": shown])
        try launch(firstMessage)
    }

    func send(_ text: String) {
        record("user/input", ["text": text])
        if let process, process.isRunning {
            process.send(text)
            phase = .running
            return
        }
        // The session is gone: start over with the original request and the current SQL.
        let context = sql.isEmpty ? "" : "\n\nYour latest proposal (possibly edited by the user):\n```sql\n\(sql)\n```"
        do { try launch(firstMessage + context + "\n\nNow: \(text)") } catch {
            record("stderr", ["text": error.localizedDescription])
            phase = .failed
        }
    }

    /// Asks Claude to fix the SQL that failed the check.
    func askToFix() {
        guard let validationError else { return }
        send("Running the block failed: \(validationError)\nFix it and answer with the complete corrected block.")
    }

    func stop() { process?.interrupt() }

    func end() {
        process?.closeInput()
        process?.terminate()
        process = nil
    }

    private func launch(_ message: String) throws {
        let process = AgentProcess(executable: try ClaudeCLI.executable(),
                                   arguments: SchemaGenerator.arguments(options),
                                   cwd: FileManager.default.temporaryDirectory,
                                   environment: ClaudeCLI.environment()) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        self.process = process
        phase = .running
        try process.start()
        process.send(message)
    }

    private func handle(_ event: AgentProcess.Event) {
        switch event {
        case .message(let kind, let json):
            append(kind, json)
            if kind.hasPrefix("result") {
                let text = JSONValue.parse(json)?["result"]?.string ?? ""
                if let proposal = SchemaGenerator.extractSQL(text) { sql = proposal }
                phase = kind == "result/success" ? .ready : .failed
            }
        case .permission(let request):
            // No tools are enabled; anything that still asks is refused.
            process?.respond(request, .deny("No tools while designing a schema"))
        case .mcp(let requestId, _, let message):
            process?.respondMCP(requestId: requestId, id: message["id"], result: nil, error: (-32601, "No MCP servers"))
        case .stderr(let text):
            record("stderr", ["text": text])
        case .exited(let code):
            process = nil
            if phase == .running {
                phase = .failed
                record("stderr", ["text": "Claude Code exited with code \(code)"])
            }
        }
    }

    private func validate() {
        guard !sql.isEmpty else {
            preview = []
            validationError = nil
            return
        }
        do {
            preview = try SQLiteFile.preview(schema: baseSchema, change: sql)
            validationError = nil
        } catch {
            validationError = (error as? DatabaseError)?.message ?? error.localizedDescription
        }
    }

    private func record(_ kind: String, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        append(kind, String(decoding: data, as: UTF8.self))
    }

    private func append(_ kind: String, _ json: String) {
        seq += 1
        var event = RunEvent(runId: run.id, kind: kind, json: json)
        event.seq = seq
        events.append(event)
    }
}

/// Sheet that designs a new database or a change to an existing one.
struct SchemaGeneratorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var generation: SchemaGeneration
    let onDone: (UserDatabase) -> Void

    @AppStorage("schemaGen.model") private var model = ""
    @State private var name = ""
    @State private var description = ""
    @State private var request = ""
    @State private var files: [URL] = []
    @State private var loadData = false
    @State private var reply = ""
    @State private var tab = 0
    @State private var dropTargeted = false

    private static let models = [("", "Default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku"), ("fable", "Fable")]

    init(existing: UserDatabase?, onDone: @escaping (UserDatabase) -> Void) {
        _generation = StateObject(wrappedValue: SchemaGeneration(existing: existing))
        self.onDone = onDone
    }

    private var existing: UserDatabase? { generation.existing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if generation.phase == .form { form } else { workspace }
            Divider()
            footer
        }
        .frame(width: generation.phase == .form ? 640 : 1080, height: generation.phase == .form ? 620 : 740)
        .background(Theme.background)
        .onDisappear { generation.end() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Theme.green.opacity(0.12))
                Image(systemName: "cylinder.split.1x2").font(.system(size: 13)).foregroundStyle(Theme.green)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(existing.map { "Change “\($0.name)” with Claude" } ?? "Generate a database")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                Text(existing == nil
                     ? "Claude designs the schema; it is checked before the database is created"
                     : "Claude writes a migration; it is checked first, and the file is backed up before it runs")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if existing == nil {
                    HStack(alignment: .top, spacing: 16) {
                        field("Name", hint: "How agents address it") {
                            TextField("crm", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                        }
                        .frame(width: 200)
                        field("Description", hint: "What it stores — agents see this") {
                            TextField("Customers, deals and calls", text: $description).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                field(existing == nil ? "Describe the data" : "What should change?",
                      hint: existing == nil
                        ? "Entities, their fields and relations, what agents will ask of it. Or just drop sample files below."
                        : "New tables or columns, constraints, renames — existing data is kept.") {
                    BoxedEditor(text: $request, minHeight: 140, monospaced: false)
                }
                field("Input data", hint: "CSV, JSON, text or an SQLite file — Claude sees the beginning of each") {
                    VStack(spacing: 0) {
                        ForEach(files, id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                                Text(url.lastPathComponent).font(.system(size: 12))
                                Spacer()
                                IconButton(icon: "xmark", help: "Remove") { files.removeAll { $0 == url } }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 4)
                        }
                        Button { chooseFiles() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.doc")
                                Text(files.isEmpty ? "Drop files here or click to choose" : "Add more")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(dropTargeted ? Theme.accentSoft : Theme.sidebar))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(dropTargeted ? Theme.accent : Theme.divider, style: StrokeStyle(lineWidth: 1, dash: dropTargeted ? [5] : [])))
                    .dropDestination(for: URL.self) { urls, _ in
                        files += urls.filter { $0.isFileURL && !files.contains($0) }
                        return true
                    } isTargeted: { dropTargeted = $0 }
                }
                if !files.isEmpty {
                    CheckRow(title: "Load the input data", subtitle: "Small files that fit completely become INSERT statements; larger ones only shape the schema",
                             last: true, isOn: $loadData)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebar))
                }
                HStack(spacing: 8) {
                    Text("Model").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                    InlineMenu(value: Self.models.first { $0.0 == model }?.1 ?? model, options: Self.models) { model = $0 }
                        .fixedSize()
                }
            }
            .padding(20)
        }
    }

    private func field<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Text(hint).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            content()
        }
    }

    private func chooseFiles() {
        let panel = Finder.openPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        files += panel.urls.filter { !files.contains($0) }
    }

    // MARK: Session

    private var workspace: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(generation.transcript) { TranscriptRow(item: $0).id($0.id) }
                            if generation.phase == .running {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Claude is designing…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                }
                                .id("progress")
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: generation.events.count) {
                        withAnimation { proxy.scrollTo(generation.phase == .running ? "progress" : generation.transcript.last?.id, anchor: .bottom) }
                    }
                }
                replyField
            }
            Divider()
            proposal.frame(width: 470)
        }
    }

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask for changes", text: $reply, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .onSubmit(sendReply)
            Button(action: sendReply) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundStyle(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.tertiary : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .padding(12)
    }

    private var proposal: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if generation.sql.isEmpty {
                    Text(generation.phase == .running ? "Waiting for the proposal…" : "No SQL in the answer yet")
                        .foregroundStyle(Theme.tertiary)
                } else if let error = generation.validationError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red)
                        Text(error).foregroundStyle(Theme.red).lineLimit(4).textSelection(.enabled)
                        Spacer()
                        Button("Ask Claude to fix") { generation.askToFix() }
                            .buttonStyle(AccentButtonStyle(prominent: false))
                            .disabled(generation.phase == .running)
                    }
                } else {
                    SwiftUI.Label(existing == nil ? "Checked: the schema builds" : "Checked: the migration applies to the current schema",
                                  systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.green)
                }
            }
            .font(.system(size: 12))
            .padding(12)
            UnderlineTabs(titles: ["Tables (\(generation.preview.filter { !$0.isView }.count))", "SQL"], selection: $tab)
                .padding(.horizontal, 12)
            if tab == 0 {
                TablesPane(tables: generation.preview)
            } else {
                BoxedEditor(text: $generation.sql, minHeight: 200)
                    .padding(12)
            }
        }
        .background(Theme.sidebar)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if generation.phase == .form {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button { start() } label: { SwiftUI.Label(existing == nil ? "Generate" : "Start", systemImage: "sparkles") }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.5)
            } else {
                if existing == nil {
                    Text("Name").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    TextField("name", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .frame(width: 160)
                }
                Spacer()
                if generation.phase == .running {
                    Button("Stop") { generation.stop() }.buttonStyle(AccentButtonStyle(prominent: false))
                }
                Button("Discard") { dismiss() }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                Button(existing == nil ? "Create database" : "Apply change") { apply() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canApply)
                    .opacity(canApply ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var canStart: Bool {
        let hasInput = !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty
        return hasInput && (existing != nil || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var canApply: Bool {
        generation.phase != .running && !generation.sql.isEmpty && generation.validationError == nil
            && (existing != nil || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func start() {
        if existing == nil {
            name = UserDatabase.normalizedName(name)
            if store.databases.contains(where: { $0.name == name }) {
                store.errorMessage = "A database named \(name) already exists"
                return
            }
        }
        var options = SchemaGenerator.Options()
        options.model = model.isEmpty ? nil : model
        options.loadData = loadData && !files.isEmpty
        var text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing == nil && !description.isEmpty { text = "Purpose: \(description)\n\n" + text }
        do { try generation.start(request: text, files: files, options: options) } catch { store.report(error) }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        generation.send(text)
        reply = ""
    }

    private func apply() {
        do {
            if let existing {
                let stamp = LocalDate.stamp(Date()).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
                let backup = store.paths.databases.appendingPathComponent("backups/\(existing.name)-\(stamp).sqlite")
                try SQLiteFile.migrate(existing.path, sql: generation.sql, backup: backup)
                generation.end()
                onDone(existing)
            } else {
                let database = try DatabaseNaming.create(name: UserDatabase.normalizedName(name), description: description,
                                                         ddl: generation.sql, store: store)
                generation.end()
                onDone(database)
            }
            dismiss()
        } catch {
            store.errorMessage = "Could not apply: " + ((error as? DatabaseError)?.message ?? error.localizedDescription)
        }
    }
}
