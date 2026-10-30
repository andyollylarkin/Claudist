import AgentDeskCore
import GRDB
import SwiftUI

/// Agent tab of a task: run controls, the conversation and permission prompts.
struct AgentRunPanel: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    let task: TaskItem

    @StateObject private var history = Observed<[Run]>([])
    @StateObject private var events = Observed<[RunEvent]>([])
    @State private var message = ""

    var body: some View {
        let liveRun = runs.live[task.id]
        VStack(spacing: 0) {
            controls(liveRun)
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(items) { item in
                                TranscriptRow(item: item).id(item.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: events.value.count) {
                        if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onAppear {
                        if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let liveRun {
                PendingPermissions(liveRun: liveRun, taskId: task.id)
            }
            composer(liveRun)
        }
        .onAppear(perform: observe)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: task.agentId == nil ? "person.crop.circle.badge.questionmark" : "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(Theme.tertiary)
            Text(task.agentId == nil ? "Assign an agent to run this task" : "Press Run to hand this task to \(store.agent(task.agentId)?.name ?? "the agent")")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func observe() {
        let id = task.id
        history.observe(store.db) {
            try Run.filter(Column("taskId") == id).order(Column("startedAt"), Column("rowid")).fetchAll($0)
        }
        events.observe(store.db) {
            try RunEvent.fetchAll($0, sql: """
                SELECT e.* FROM runEvent e JOIN run r ON r.id = e.runId WHERE r.taskId = ? ORDER BY e.seq
                """, arguments: [id])
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, task.agentId != nil else { return }
        if runs.live[task.id] == nil && history.value.isEmpty {
            // First run: the task is the prompt, the message is extra context.
            var t = task
            t.description = [task.description, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            store.write { try t.update($0) }
            runs.start(t)
        } else {
            runs.send(task, text: text)
        }
        message = ""
    }

    private func controls(_ liveRun: LiveRun?) -> some View {
        HStack(spacing: 10) {
            Avatar(name: store.agent(task.agentId)?.name ?? "?", size: 26)
            Menu {
                Button("Unassigned") {
                    var t = task
                    t.agentId = nil
                    store.write { try t.update($0) }
                }
                ForEach(store.agents) { agent in
                    Button(agent.name) {
                        var t = task
                        t.agentId = agent.id
                        store.write { try t.update($0) }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.agent(task.agentId)?.name ?? "No agent").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let last = history.value.last {
                        Text(summary(last)).font(.system(size: 11)).foregroundStyle(last.status.color)
                    } else {
                        Text("Not run yet").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            if liveRun != nil {
                ProgressView().controlSize(.small)
                Button { runs.stop(taskId: task.id) } label: { SwiftUI.Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(AccentButtonStyle(prominent: false))
            } else {
                Button { runs.start(task) } label: { SwiftUI.Label(history.value.isEmpty ? "Run" : "Run again", systemImage: "play.fill") }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(task.agentId == nil)
                    .opacity(task.agentId == nil ? 0.5 : 1)
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func composer(_ liveRun: LiveRun?) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(liveRun == nil && history.value.isEmpty ? "Extra instructions for the agent (optional)" : "Message the agent",
                      text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? Theme.accent : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .padding(12)
    }

    private var canSend: Bool {
        task.agentId != nil && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func summary(_ run: Run) -> String {
        var parts = [run.status.title]
        if let i = run.inputTokens, let o = run.outputTokens { parts.append("\(i + o) tokens") }
        if let c = run.costUsd { parts.append(String(format: "$%.3f", c)) }
        return parts.joined(separator: " · ")
    }

    private var items: [TranscriptItem] {
        TranscriptItem.build(runs: history.value, events: events.value, agentName: store.agent(task.agentId)?.name)
    }
}

private struct PendingPermissions: View {
    @EnvironmentObject var runs: RunManager
    @ObservedObject var liveRun: LiveRun
    let taskId: ID

    var body: some View {
        ForEach(liveRun.pending) { request in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("Allow \(request.toolName)?").font(.system(size: 13, weight: .semibold))
                }
                if let d = request.description, !d.isEmpty {
                    Text(d).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                ScrollView {
                    Text(request.inputJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                HStack {
                    Button("Deny") { runs.respond(taskId: taskId, request, allow: false) }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    Spacer()
                    Button("Always allow") { runs.respond(taskId: taskId, request, allow: true, always: true) }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .help("Adds the rule \(RunManager.rule(for: request)) to this agent")
                    Button("Allow") { runs.respond(taskId: taskId, request, allow: true) }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.4)))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

// MARK: Transcript

struct TranscriptItem: Identifiable {
    enum Kind {
        case runHeader(Run)
        case user(String)
        case assistant(String)
        case tool(name: String, detail: String)
        case toolResult(String, isError: Bool)
        case permission(tool: String, answer: String?)
        case delegate(agent: String, title: String, taskId: ID)
        case result(String, isError: Bool)
        case error(String)
    }

    var id: String
    var kind: Kind
    var agentName: String?

    static func build(runs: [Run], events: [RunEvent], agentName: String?) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        let byRun = Dictionary(grouping: events, by: \.runId)
        var answers: [String: Bool] = [:]
        for e in events where e.kind == "permission/answer" {
            if let v = JSONValue.parse(e.json), let id = v["request_id"]?.string { answers[id] = v["allow"]?.bool ?? false }
        }
        for run in runs {
            out.append(TranscriptItem(id: "run-\(run.id)", kind: .runHeader(run)))
            for e in byRun[run.id] ?? [] {
                let base = "e\(e.seq ?? 0)"
                guard let v = JSONValue.parse(e.json) else { continue }
                switch e.kind {
                case "user/input":
                    out.append(TranscriptItem(id: base, kind: .user(v["text"]?.string ?? "")))
                case "assistant":
                    for (i, block) in (v["message"]?["content"]?.array ?? []).enumerated() {
                        switch block["type"]?.string {
                        case "text":
                            let text = block["text"]?.string ?? ""
                            if !text.isEmpty { out.append(TranscriptItem(id: "\(base)-\(i)", kind: .assistant(text), agentName: agentName)) }
                        case "tool_use":
                            out.append(TranscriptItem(id: "\(base)-\(i)", kind: .tool(
                                name: block["name"]?.string ?? "?", detail: toolDetail(block["input"]))))
                        default: break
                        }
                    }
                case "user":
                    for (i, block) in (v["message"]?["content"]?.array ?? []).enumerated() where block["type"]?.string == "tool_result" {
                        let text: String
                        if let s = block["content"]?.string { text = s }
                        else { text = (block["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n") }
                        out.append(TranscriptItem(id: "\(base)-\(i)", kind: .toolResult(text, isError: block["is_error"]?.bool == true)))
                    }
                case "permission":
                    let rid = v["request_id"]?.string ?? ""
                    let answer = answers[rid].map { $0 ? "allowed" : "denied" }
                    out.append(TranscriptItem(id: base, kind: .permission(tool: v["tool"]?.string ?? "?", answer: answer)))
                case "delegate":
                    out.append(TranscriptItem(id: base, kind: .delegate(
                        agent: v["agent"]?.string ?? "?", title: v["title"]?.string ?? "", taskId: v["taskId"]?.string ?? "")))
                case let k where k.hasPrefix("result"):
                    let isError = k != "result/success" || v["is_error"]?.bool == true
                    var parts: [String] = []
                    if let d = v["duration_ms"]?.number { parts.append(String(format: "%.0fs", d / 1000)) }
                    if let n = v["num_turns"]?.number { parts.append("\(Int(n)) turns") }
                    if let c = v["total_cost_usd"]?.number { parts.append(String(format: "$%.3f", c)) }
                    out.append(TranscriptItem(id: base, kind: .result(
                        (isError ? "Failed" : "Finished") + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")), isError: isError)))
                case "stderr":
                    let text = v["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !text.isEmpty { out.append(TranscriptItem(id: base, kind: .error(text))) }
                default:
                    break
                }
            }
            if let error = run.error, run.status == .failed {
                out.append(TranscriptItem(id: "err-\(run.id)", kind: .error(error)))
            }
        }
        return out
    }

    private static func toolDetail(_ input: JSONValue?) -> String {
        guard let input else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "skill", "prompt"] {
            if let s = input[key]?.string { return s }
        }
        return input.prettyJSON
    }
}

private struct TranscriptRow: View {
    @EnvironmentObject var store: AppStore
    let item: TranscriptItem
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .runHeader(let run):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.divider).frame(height: 1)
                HStack(spacing: 4) {
                    Image(systemName: run.trigger == "schedule" ? "clock.arrow.circlepath" : run.trigger == "agent" ? "arrow.triangle.branch" : "play.circle")
                    Text("\(run.trigger == "schedule" ? "Scheduled run" : run.trigger == "agent" ? "Called by agent" : "Run") · \(run.startedAt)")
                    Text("· \(run.status.title)").foregroundStyle(run.status.color)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .fixedSize()
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                MarkdownText(text: text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accentSoft))
            }
        case .assistant(let text):
            HStack(alignment: .top, spacing: 8) {
                Avatar(name: item.agentName ?? "A", size: 22)
                VStack(alignment: .leading, spacing: 3) {
                    if let name = item.agentName {
                        Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    MarkdownText(text: text)
                }
            }
        case .tool(let name, let detail):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .padding(.top, 3)
                Text(name).fontWeight(.semibold)
                Text(detail).foregroundStyle(Theme.secondary).lineLimit(expanded ? nil : 1).textSelection(.enabled)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
            .padding(.leading, 30)
            .onTapGesture { expanded.toggle() }
        case .toolResult(let text, let isError):
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isError ? Theme.red : Theme.tertiary)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .padding(.leading, 46)
                .onTapGesture { expanded.toggle() }
        case .permission(let tool, let answer):
            SwiftUI.Label("Permission for \(tool)" + (answer.map { " — \($0)" } ?? " — waiting"),
                          systemImage: "hand.raised")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .padding(.leading, 30)
        case .delegate(let agent, let title, let taskId):
            Button { store.selectedTaskId = taskId } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent)
                    Avatar(name: agent, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Asked \(agent)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("Open sub-task").font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(.leading, 30)
        case .result(let text, let isError):
            SwiftUI.Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(isError ? Theme.red : Theme.green)
                .padding(.leading, 30)
        case .error(let text):
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.red).textSelection(.enabled)
                .padding(.leading, 30)
        }
    }
}
