import ClaudistCore
import GRDB
import SwiftUI

/// One launch of an agent and the follow-up replies that resumed its session.
struct RunConversation: Identifiable {
    var runs: [Run]
    var id: ID { runs[0].id }
    var first: Run { runs[0] }
    var last: Run { runs[runs.count - 1] }
    var sessionId: String? { runs.lazy.compactMap(\.sessionId).first }

    var costUsd: Double? {
        let costs = runs.compactMap(\.costUsd)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var tokens: Int? {
        let t = runs.compactMap { r in r.inputTokens.flatMap { i in r.outputTokens.map { i + $0 } } }
        return t.isEmpty ? nil : t.reduce(0, +)
    }

    /// Wall time from the first start to the last end.
    var duration: TimeInterval? {
        guard let start = LocalDate.parse(first.startedAt), let endText = last.endedAt,
              let end = LocalDate.parse(endText) else { return nil }
        return end.timeIntervalSince(start)
    }

    /// Runs ordered by start, grouped by Claude Code session.
    static func group(_ runs: [Run]) -> [RunConversation] {
        var out: [RunConversation] = []
        var index: [String: Int] = [:]
        for run in runs {
            if let sid = run.sessionId, let i = index[sid] {
                out[i].runs.append(run)
            } else {
                if let sid = run.sessionId { index[sid] = out.count }
                out.append(RunConversation(runs: [run]))
            }
        }
        return out
    }
}

/// History of a task's runs: a list, and the conversation of the selected one.
struct RunHistoryView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    let task: TaskItem

    @StateObject private var history = Observed<[Run]>([])
    @StateObject private var answers = Observed<[ID: String]>([:])
    @State private var selected: ID?

    var body: some View {
        let conversations = RunConversation.group(history.value)
        Group {
            if let conv = conversations.first(where: { $0.id == selected }) {
                ConversationDetail(task: task, conversation: conv) { selected = nil }
                    .id(conv.id)
            } else if conversations.isEmpty {
                ContentUnavailableView("No runs yet", systemImage: "clock.arrow.circlepath",
                                       description: Text(task.isRecurring
                                           ? "Each scheduled run will appear here with its own conversation"
                                           : "Run the agent from the Agent tab"))
            } else {
                list(conversations.reversed())
            }
        }
        .onAppear(perform: observe)
    }

    private func observe() {
        let id = task.id
        history.observe(store.db) {
            try Run.filter(Column("taskId") == id).order(Column("startedAt"), Column("rowid")).fetchAll($0)
        }
        // The agent's final answer of each run, for the preview line.
        answers.observe(store.db) { db in
            var map: [ID: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT e.runId, e.json FROM runEvent e JOIN run r ON r.id = e.runId
                WHERE r.taskId = ? AND e.kind LIKE 'result%'
                """, arguments: [id]) {
                if let text = JSONValue.parse(row[1])?["result"]?.string { map[row[0]] = text }
            }
            return map
        }
    }

    private func list(_ conversations: [RunConversation]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(conversations.count) run\(conversations.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Spacer()
                    if let total = totalCost(conversations) {
                        Text(String(format: "Total $%.2f", total)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(conversations.enumerated()), id: \.element.id) { i, conv in
                        row(conv, last: i == conversations.count - 1)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
            }
            .padding(16)
        }
    }

    private func totalCost(_ conversations: [RunConversation]) -> Double? {
        let costs = conversations.compactMap(\.costUsd)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    private func row(_ conv: RunConversation, last: Bool) -> some View {
        let status = runs.live[task.id].map { live in conv.runs.contains { $0.id == live.runId } } == true ? RunStatus.running : conv.last.status
        let preview = conv.runs.reversed().lazy.compactMap { answers.value[$0.id] }.first
        return HoverRow(cornerRadius: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(status.color)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(RunHistoryView.when(conv.first.startedAt)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(RunHistoryView.trigger(conv.first.trigger)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        Spacer()
                        Text(status.title).font(.system(size: 11, weight: .medium)).foregroundStyle(status.color)
                    }
                    HStack(spacing: 10) {
                        if let d = conv.duration { Pill(text: RunHistoryView.format(d), icon: "timer") }
                        if conv.runs.count > 1 { Pill(text: "\(conv.runs.count - 1) repl\(conv.runs.count == 2 ? "y" : "ies")", icon: "arrowshape.turn.up.left") }
                        if let t = conv.tokens { Pill(text: "\(t) tokens", icon: "number") }
                        if let c = conv.costUsd { Pill(text: String(format: "$%.3f", c), icon: "dollarsign.circle") }
                    }
                    if let preview, !preview.isEmpty {
                        Text(preview.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
                    } else if let error = conv.last.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).lineLimit(2)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { selected = conv.id }
        }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 40) } }
    }

    static func when(_ stamp: String) -> String {
        guard let date = LocalDate.parse(stamp) else { return stamp }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "EEE d MMM, HH:mm" : "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }

    static func trigger(_ t: String) -> String {
        switch t {
        case "schedule": "Scheduled"
        case "agent": "Called by agent"
        default: "Manual"
        }
    }

    static func format(_ d: TimeInterval) -> String {
        let s = Int(d.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// The conversation of one launch, with replies resuming that same session.
private struct ConversationDetail: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    let task: TaskItem
    let conversation: RunConversation
    let back: () -> Void

    @StateObject private var events = Observed<[RunEvent]>([])
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("All runs")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(RunHistoryView.when(conversation.first.startedAt) + " · " + RunHistoryView.trigger(conversation.first.trigger))
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { TranscriptRow(item: $0).id($0.id) }
                    }
                    .padding(16)
                }
                .onChange(of: events.value.count) {
                    if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            reply
        }
        .onAppear {
            let ids = conversation.runs.map(\.id)
            events.observe(store.db) { db in
                try RunEvent.filter(ids.contains(Column("runId"))).order(Column("seq")).fetchAll(db)
            }
        }
    }

    private var items: [TranscriptItem] {
        TranscriptItem.build(runs: conversation.runs, events: events.value, agentName: store.agent(task.agentId)?.name)
    }

    /// Replying resumes this run's session; another run of the task must not be active.
    @ViewBuilder private var reply: some View {
        let live = runs.live[task.id]
        let busyElsewhere = live != nil && !conversation.runs.contains { $0.id == live!.runId } && live?.sessionId != conversation.sessionId
        if conversation.sessionId == nil {
            EmptyView()
        } else if busyElsewhere {
            Text("Another run of this task is in progress. Reply here when it finishes.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .padding(12)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply in this run", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
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
    }

    private var canSend: Bool {
        task.agentId != nil && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let session = conversation.sessionId else { return }
        runs.send(task, text: text, session: session)
        message = ""
    }
}
