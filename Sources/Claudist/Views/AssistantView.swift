import ClaudistCore
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Chat with the built-in assistant, which sees and manages everything in Claudist.
struct AssistantView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var assistant: AssistantManager
    @StateObject private var chats = Observed<[AssistantChat]>([])
    @AppStorage("assistant.selectedChat") private var selected = ""

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 230)
            Divider()
            Group {
                if let chat = chats.value.first(where: { $0.id == selected }) {
                    ChatPane(chat: chat).id(chat.id)
                } else {
                    ChatPane(chat: nil) { text, files in
                        let chat = assistant.newChat()
                        selected = chat.id
                        assistant.send(chat.id, text: text, files: files)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
        .onAppear {
            chats.observe(store.db) { try AssistantChat.order(Column("updatedAt").desc).fetchAll($0) }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Assistant").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                IconButton(icon: "square.and.pencil", help: "New chat") { selected = "" }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(chats.value) { chat in
                        HoverRow(selected: selected == chat.id) {
                            HStack(spacing: 8) {
                                if assistant.live[chat.id]?.busy == true {
                                    ProgressView().controlSize(.mini)
                                } else if assistant.live[chat.id]?.pending.isEmpty == false {
                                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chat.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(RunHistoryView.when(chat.updatedAt)).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = chat.id }
                        }
                        .contextMenu {
                            Button("Delete chat", role: .destructive) {
                                assistant.delete(chat.id)
                                if selected == chat.id { selected = "" }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .background(Theme.sidebar)
    }
}

private struct ChatPane: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var assistant: AssistantManager
    let chat: AssistantChat?
    /// Sends the first message of a chat that doesn't exist yet.
    var start: ((String, [URL]) -> Void)?

    @StateObject private var events = Observed<[AssistantEvent]>([])
    @AppStorage(AssistantManager.modelKey) private var model = ""
    @AppStorage(AssistantManager.confirmKey) private var confirmChanges = true
    @State private var message = ""
    @State private var files: [URL] = []
    @State private var dropTargeted = false

    private static let models = [("", "Default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku"), ("fable", "Fable")]
    private static let suggestions = [
        "What needs my attention right now?",
        "Which agents are running, and what are they doing?",
        "Show the runs that failed this week and why",
        "Set up an agent that summarizes my overdue tasks every morning",
    ]

    private var liveChat: LiveChat? { chat.flatMap { assistant.live[$0.id] } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if chat == nil || events.value.isEmpty {
                welcome
            } else {
                transcript
            }
            if let liveChat {
                PendingChanges(chatId: chat!.id, live: liveChat)
            }
            input
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Theme.accent.opacity(0.05))
                    .overlay(Text("Drop files to attach").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async { attach([url]) }
                }
            }
            return true
        }
        .onAppear {
            guard let id = chat?.id else { return }
            events.observe(store.db) { try AssistantEvent.filter(Column("chatId") == id).order(Column("seq")).fetchAll($0) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(chat?.title ?? "New chat").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Toggle("Ask before changes", isOn: $confirmChanges)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .help("Creating, changing, deleting or running anything needs your approval in the chat. Applies to the next message.")
            InlineMenu(value: Self.models.first { $0.0 == model }?.1 ?? model, options: Self.models) { model = $0 }
                .fixedSize()
                .help("Model for new conversations and the next message")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text("Ask about anything in Claudist").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text("The assistant sees your projects, tasks, agents, runs, skills, secrets (names only) and databases, and can create or change them.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            VStack(spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        Text(s).font(.system(size: 12)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.accentSoft))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var items: [TranscriptItem] {
        guard let chat else { return [] }
        let run = Run(taskId: chat.id, agentId: nil)
        let runEvents = events.value.map { e -> RunEvent in
            var r = RunEvent(runId: run.id, kind: e.kind, json: e.json)
            r.seq = e.seq
            return r
        }
        let prefix = "mcp__\(Delegation.serverName)__"
        return TranscriptItem.build(runs: [run], events: runEvents, agentName: "Assistant").compactMap { item in
            var item = item
            switch item.kind {
            case .runHeader:
                return nil
            case .tool(let name, let detail):
                item.kind = .tool(name: name.replacingOccurrences(of: prefix, with: ""), detail: detail)
            case .permission(let tool, let answer):
                item.kind = .permission(tool: tool.replacingOccurrences(of: prefix, with: ""), answer: answer)
            default:
                break
            }
            return item
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { TranscriptRow(item: $0).id($0.id) }
                    if liveChat?.busy == true {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                        .id("progress")
                    }
                }
                .padding(20)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(items.last?.id, anchor: .bottom) }
            .onChange(of: events.value.count) {
                withAnimation { proxy.scrollTo(liveChat?.busy == true ? "progress" : items.last?.id, anchor: .bottom) }
            }
        }
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !files.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(files, id: \.self) { url in
                        HStack(spacing: 5) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 14, height: 14)
                            Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(Theme.text).lineLimit(1)
                            Button { files.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.hover))
                        .help(url.path)
                    }
                }
            }
        HStack(alignment: .bottom, spacing: 8) {
            Button { pickFiles() } label: {
                Image(systemName: "paperclip").font(.system(size: 15)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)
            .help("Attach files: images, PDFs and text are shown to the assistant (or drop files here)")
            TextField("Message the assistant", text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .onSubmit { send(message) }
                .onKeyPress(.return, phases: .down) { $0.modifiers.contains(.shift) ? AgentRunPanel.insertNewline() : .ignored }
            if liveChat?.busy == true {
                Button { if let id = chat?.id { assistant.stop(id) } } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
            Button { send(message) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundStyle(canSend ? Theme.accent : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .frame(maxWidth: 860)
        .padding(14)
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !files.isEmpty else { return }
        if let chat { assistant.send(chat.id, text: t, files: files) } else { start?(t, files) }
        message = ""
        files = []
    }

    private func attach(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url.standardizedFileURL) }
    }

    private func pickFiles() {
        let panel = Finder.openPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Files for the assistant: images, PDFs, text, CSV, JSON, SQLite…"
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }
}

/// Changes the assistant wants to make, waiting for approval.
private struct PendingChanges: View {
    @EnvironmentObject var assistant: AssistantManager
    let chatId: ID
    @ObservedObject var live: LiveChat

    var body: some View {
        ForEach(live.pending) { request in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.and.list.clipboard").foregroundStyle(.orange)
                    Text(request.toolName.replacingOccurrences(of: "mcp__\(Delegation.serverName)__", with: "").replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                }
                Text(request.inputJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(14)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
                HStack {
                    Spacer()
                    Button("Decline") { assistant.answer(chatId, request, allow: false) }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    Button("Allow") { assistant.answer(chatId, request, allow: true) }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.4)))
            .frame(maxWidth: 860)
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }
}
