import ClaudistCore
import AppKit
import GRDB
import SwiftUI

/// One skill generation: a Claude Code process writing into a draft folder.
@MainActor
final class SkillGeneration: ObservableObject {
    enum Phase { case form, running, ready, failed }

    @Published var phase: Phase = .form
    @Published var events: [RunEvent] = []
    @Published var pending: [PermissionRequest] = []
    @Published var files: [SkillFile] = []
    /// Approves every command of this generation without asking.
    @Published var allowAllCommands = false

    let library: SkillLibrary
    /// Skill being changed; nil when writing a new one.
    let editing: Skill?
    private(set) var draft: URL?
    private var process: AgentProcess?
    private var options = SkillGenerator.Options()
    private let run = Run(taskId: "skill-draft", agentId: nil)
    private var seq: Int64 = 0

    init(library: SkillLibrary, editing: Skill?) {
        self.library = library
        self.editing = editing
    }

    var hasSkillMD: Bool { files.contains { $0.path == "SKILL.md" } }

    var transcript: [TranscriptItem] {
        TranscriptItem.build(runs: [run], events: events, agentName: "Claude").filter {
            if case .runHeader = $0.kind { return false }
            return true
        }
    }

    func start(request: String, options: SkillGenerator.Options) throws {
        self.options = options
        let draft = try draft ?? library.makeDraft(from: editing)
        self.draft = draft
        refreshFiles()
        record("user/input", ["text": request])
        try launch(SkillGenerator.firstMessage(request: request, editing: editing?.name))
    }

    /// A follow-up request. Goes to the live session, or starts a new one over the same draft.
    func send(_ text: String) {
        record("user/input", ["text": text])
        if let process, process.isRunning {
            process.send(text)
            phase = .running
            return
        }
        do {
            try launch("The current folder holds your draft of the skill so far. Read it, then: \(text)")
        } catch {
            record("stderr", ["text": error.localizedDescription])
            phase = .failed
        }
    }

    func stop() {
        process?.interrupt()
    }

    func answer(_ request: PermissionRequest, allow: Bool) {
        pending.removeAll { $0.id == request.id }
        process?.respond(request, allow ? .allow : .deny("The user declined this command"))
        record("permission/answer", ["request_id": request.id, "allow": allow])
    }

    /// Moves the draft into the library and links existing secrets the skill asks for.
    /// Returns the skill and the required secrets that don't exist yet.
    func save(secrets: [Secret], db: AppDatabase) throws -> (Skill, missing: [String]) {
        guard let draft else { throw ClaudistError.invalid("Nothing to save") }
        end()
        let md = (try? String(contentsOf: draft.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
        let skill = try library.installDraft(draft, replacing: editing)
        self.draft = nil
        let required = SkillGenerator.requiredSecrets(md)
        let known = secrets.filter { required.contains($0.name) }
        try db.writer.write { db in
            for secret in known {
                try db.execute(sql: "INSERT OR IGNORE INTO skillSecret (skillName, secretId) VALUES (?, ?)",
                               arguments: [skill.name, secret.id])
            }
        }
        return (skill, required.filter { name in !known.contains { $0.name == name } })
    }

    /// Stops Claude and deletes an unsaved draft.
    func discard() {
        end()
        if let draft { library.discardDraft(draft) }
        draft = nil
    }

    private func end() {
        process?.closeInput()
        process?.terminate()
        process = nil
        pending = []
    }

    private func launch(_ message: String) throws {
        guard let draft else { return }
        let process = AgentProcess(executable: try ClaudeCLI.executable(),
                                   arguments: SkillGenerator.arguments(options),
                                   cwd: draft,
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
            if kind == "user" { refreshFiles() }   // tool results: a file may have changed
            if kind.hasPrefix("result") {
                phase = kind == "result/success" ? .ready : .failed
                refreshFiles()
            }
        case .permission(let request):
            guard let draft else { return }
            record("permission", ["request_id": request.id, "tool": request.toolName])
            switch SkillGenerator.decide(tool: request.toolName, input: request.input, draft: draft, options: options) {
            case .allow:
                answer(request, allow: true)
            case .deny(let reason):
                process?.respond(request, .deny(reason))
                record("permission/answer", ["request_id": request.id, "allow": false])
            case .ask:
                if allowAllCommands { answer(request, allow: true) } else { pending.append(request) }
            }
        case .mcp(let requestId, _, let message):
            process?.respondMCP(requestId: requestId, id: message["id"], result: nil,
                                error: (code: -32601, message: "No MCP servers while writing a skill"))
        case .stderr(let text):
            record("stderr", ["text": text])
        case .exited(let code):
            process = nil
            pending = []
            if phase == .running {
                phase = .failed
                record("stderr", ["text": "Claude Code exited with code \(code)"])
            }
            refreshFiles()
        }
    }

    private func refreshFiles() {
        files = draft.map(library.draftFiles) ?? []
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

/// Sheet that writes a new skill — or changes an existing one — from a prompt.
struct SkillGeneratorSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var generation: SkillGeneration
    let onSaved: (Skill) -> Void

    @AppStorage("skillGen.language") private var language = SkillGenerator.defaultLanguage
    @AppStorage("skillGen.model") private var model = ""
    @AppStorage("skillGen.allowWeb") private var allowWeb = true
    @AppStorage("skillGen.allowBash") private var allowBash = false
    @State private var request = ""
    @State private var otherLanguage = false
    @State private var reply = ""
    @State private var selectedFile: String?
    @State private var agents: Set<ID> = []

    private static let models = [("", "Default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku"), ("fable", "Fable")]

    init(library: SkillLibrary, editing: Skill? = nil, onSaved: @escaping (Skill) -> Void) {
        _generation = StateObject(wrappedValue: SkillGeneration(library: library, editing: editing))
        self.onSaved = onSaved
    }

    private var editing: Skill? { generation.editing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if generation.phase == .form { form } else { workspace }
            Divider()
            footer
        }
        .frame(width: generation.phase == .form ? 620 : 1040, height: generation.phase == .form ? 560 : 720)
        .background(Theme.background)
        .onAppear { otherLanguage = !SkillGenerator.languages.contains(language) }
        .onDisappear { generation.discard() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Theme.purple.opacity(0.12))
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Theme.purple)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(editing.map { "Edit “\($0.name)” with Claude" } ?? "Generate a skill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                Text("Claude writes SKILL.md and the tools it needs in a draft; nothing changes until you save")
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(editing == nil ? "What should the skill do?" : "What should change?")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(editing == nil
                         ? "The task, its inputs and outputs, the services or APIs it talks to, the credentials it needs."
                         : "New tools, fixes, a different behaviour — Claude reads the current files first.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    BoxedEditor(text: $request, minHeight: 170, monospaced: false)
                }
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tools language").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        HStack(spacing: 8) {
                            InlineMenu(value: otherLanguage ? "Other…" : language,
                                       options: SkillGenerator.languages.map { ($0, $0) } + [("", "Other…")]) { picked in
                                otherLanguage = picked.isEmpty
                                language = picked.isEmpty ? "" : picked
                            }
                            .fixedSize()
                            if otherLanguage {
                                TextField("e.g. Rust", text: $language)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 140)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        InlineMenu(value: Self.models.first { $0.0 == model }?.1 ?? model, options: Self.models) { model = $0 }
                            .fixedSize()
                    }
                    Spacer()
                }
                Text("A language named in the request wins over this choice.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                VStack(spacing: 0) {
                    CheckRow(title: "Look things up on the web",
                             subtitle: "WebSearch and WebFetch, e.g. to read an API's documentation",
                             isOn: $allowWeb)
                    CheckRow(title: "Test the tools by running them",
                             subtitle: "Gives Claude Bash inside the draft; you approve every command",
                             last: true, isOn: $allowBash)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
                if editing == nil {
                    SkillAgentPicker(selection: $agents)
                }
            }
            .padding(20)
        }
    }

    // MARK: Generation

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
                                    Text("Claude is writing the skill…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
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
                ForEach(generation.pending) { CommandApproval(request: $0, generation: generation) }
                replyField
            }
            Divider()
            filesPane.frame(width: 380)
        }
    }

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(generation.phase == .running ? "Claude is working — add a note" : "Ask for changes", text: $reply, axis: .vertical)
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

    private var filesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Draft").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                if let draft = generation.draft {
                    IconButton(icon: "folder", help: "Open draft folder") { NSWorkspace.shared.open(draft) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if generation.files.isEmpty {
                        Text("No files yet").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(14)
                    }
                    ForEach(generation.files) { file in
                        HoverRow(selected: selectedFile == file.path) {
                            HStack(spacing: 6) {
                                Image(systemName: file.isDirectory ? "folder.fill" : file.isExecutable ? "terminal.fill" : "doc.text")
                                    .font(.system(size: 11))
                                    .foregroundStyle(file.isDirectory ? Theme.blue : file.isExecutable ? Theme.green : Theme.tertiary)
                                    .frame(width: 16)
                                Text(file.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                                Spacer()
                            }
                            .padding(.leading, 10 + CGFloat(file.depth) * 16)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .onTapGesture { if !file.isDirectory { selectedFile = file.path } }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 190)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .id(generation.events.count)   // reload the file while Claude edits it
        }
        .background(Theme.sidebar)
    }

    private var preview: String {
        guard let draft = generation.draft else { return "" }
        let path = selectedFile ?? (generation.hasSkillMD ? "SKILL.md" : nil)
        guard let path, let data = try? Data(contentsOf: draft.appendingPathComponent(path)) else {
            return "Select a file to preview it"
        }
        return data.count > 200_000 ? "File too large to preview" : String(decoding: data, as: UTF8.self)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            switch generation.phase {
            case .form:
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button { start() } label: { SwiftUI.Label(editing == nil ? "Generate" : "Start", systemImage: "sparkles") }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.5)
            default:
                status
                Spacer()
                if generation.phase == .running {
                    Button("Stop") { generation.stop() }.buttonStyle(AccentButtonStyle(prominent: false))
                }
                Button("Discard") { dismiss() }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                Button(editing == nil ? "Save to library" : "Save changes") { save() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var status: some View {
        switch generation.phase {
        case .running:
            Text("Working…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        case .ready:
            SwiftUI.Label("Review the draft, ask for changes or save it", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.green)
        case .failed:
            SwiftUI.Label("Claude stopped with an error — you can ask it to continue", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.red)
        case .form:
            EmptyView()
        }
    }

    private var canStart: Bool {
        !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSave: Bool {
        generation.phase != .running && generation.hasSkillMD
    }

    private func start() {
        var options = SkillGenerator.Options()
        options.language = language
        options.model = model.isEmpty ? nil : model
        options.allowWeb = allowWeb
        options.allowBash = allowBash
        do { try generation.start(request: request.trimmingCharacters(in: .whitespacesAndNewlines), options: options) }
        catch { store.report(error) }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        generation.send(text)
        reply = ""
    }

    private func save() {
        do {
            let (skill, missing) = try generation.save(secrets: store.secrets, db: store.db)
            store.reloadSkills()
            store.enableSkills([skill.name], for: agents)
            for agent in store.agents { store.syncSkills(for: agent) }
            onSaved(skill)
            dismiss()
            if !missing.isEmpty {
                let alert = NSAlert()
                alert.messageText = "“\(skill.name)” needs secrets"
                alert.informativeText = "Create these in Secrets and link them to the skill: \(missing.joined(separator: ", "))"
                alert.runModal()
            }
        } catch { store.report(error) }
    }
}

/// A command Claude wants to run in the draft.
private struct CommandApproval: View {
    let request: PermissionRequest
    @ObservedObject var generation: SkillGeneration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(.orange)
                Text(request.input["description"]?.string ?? "Run a command")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Text(request.input["command"]?.string ?? request.inputJSON)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
            HStack(spacing: 8) {
                Toggle("Allow all commands for this draft", isOn: $generation.allowAllCommands)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button("Deny") { generation.answer(request, allow: false) }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                Button("Allow") { generation.answer(request, allow: true) }
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.4)))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
