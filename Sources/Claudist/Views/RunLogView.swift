import ClaudistCore
import GRDB
import SwiftUI

/// Every agent run across tasks: when, by whom, and which skills and sub-agents it used.
struct RunLogView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    @StateObject private var entries = Observed<[RunLogEntry]>([])
    @StateObject private var skills = Observed<[String]>([])
    @State private var agentId: ID?
    @State private var status: RunStatus?
    @State private var period = Period.week
    @State private var skill: String?

    enum Period: String, CaseIterable {
        case today = "Today", week = "7 days", month = "30 days", all = "All time"
        var since: Date? {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Run log", subtitle: summary, icon: "list.bullet.rectangle", iconColor: Theme.accent) {
                HStack(spacing: 14) {
                    InlineMenu(value: store.agent(agentId)?.name ?? "All agents",
                               options: [("", "All agents")] + store.agents.map { ($0.id, $0.name) }) { agentId = $0.isEmpty ? nil : $0 }
                        .fixedSize()
                    InlineMenu(value: status?.title ?? "Any status",
                               options: [("", "Any status")] + RunStatus.allCases.map { ($0.rawValue, $0.title) }) { status = RunStatus(rawValue: $0) }
                        .fixedSize()
                    InlineMenu(value: skill ?? "Any skill", options: [("", "Any skill")] + skills.value.map { ($0, $0) }) {
                        skill = $0.isEmpty ? nil : $0
                    }
                    .fixedSize()
                    InlineMenu(value: period.rawValue, options: Period.allCases.map { ($0.rawValue, $0.rawValue) }) {
                        period = Period(rawValue: $0) ?? .week
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 14)
            Divider()
            if entries.value.isEmpty {
                ContentUnavailableView("No runs", systemImage: "clock.arrow.circlepath",
                                       description: Text("Runs of agents appear here with the skills and sub-agents they used"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries.value) { entry in
                            RunLogRow(entry: entry, live: runs.live[entry.run.taskId]?.runId == entry.run.id)
                            Divider().padding(.leading, 52)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("")
        .onAppear(perform: observe)
        .onChange(of: agentId) { observe() }
        .onChange(of: status) { observe() }
        .onChange(of: period) { observe() }
        .onChange(of: skill) { observe() }
    }

    private var summary: String {
        let list = entries.value
        guard !list.isEmpty else { return "Every agent run, with the skills and sub-agents it used" }
        var parts = ["\(list.count) run\(list.count == 1 ? "" : "s")\(list.count >= 300 ? "+" : "")"]
        let cost = list.compactMap(\.run.costUsd).reduce(0, +)
        if cost > 0 { parts.append(String(format: "$%.2f", cost)) }
        let failed = list.filter { $0.run.status == .failed }.count
        if failed > 0 { parts.append("\(failed) failed") }
        var usage: [String: Int] = [:]
        for e in list { for s in e.skills { usage[s.name, default: 0] += s.count } }
        let top = usage.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) ×\($0.value)" }
        if !top.isEmpty { parts.append("top skills: " + top.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func observe() {
        var q = RunLog.Query()
        q.agentId = agentId
        q.status = status
        q.skill = skill
        q.since = period.since.map { LocalDate.stamp($0) }
        let query = q
        entries.observe(store.db) { try RunLog.entries($0, query) }
        skills.observe(store.db) { try RunLog.usedSkills($0) }
    }
}

private struct RunLogRow: View {
    @EnvironmentObject var store: AppStore
    let entry: RunLogEntry
    let live: Bool

    var body: some View {
        let run = entry.run
        let status: RunStatus = live ? .running : run.status
        HoverRow(cornerRadius: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: status.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(status.color)
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(entry.taskTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if let agent = entry.agentName {
                            Pill(text: agent, icon: "person.crop.circle", color: Theme.accent)
                        }
                        Spacer()
                        Text(status.title).font(.system(size: 11, weight: .medium)).foregroundStyle(status.color)
                    }
                    FlowLayout(spacing: 12) {
                        Pill(text: RunHistoryView.when(run.startedAt), icon: "clock")
                        if let d = duration { Pill(text: RunHistoryView.format(d), icon: "timer") }
                        Pill(text: trigger, icon: run.trigger == "schedule" ? "clock.arrow.circlepath"
                             : run.trigger == "agent" ? "arrow.triangle.branch" : "play.circle")
                        if entry.toolCalls > 0 { Pill(text: "\(entry.toolCalls) tool call\(entry.toolCalls == 1 ? "" : "s")", icon: "wrench.and.screwdriver") }
                        if let c = run.costUsd { Pill(text: String(format: "$%.3f", c), icon: "dollarsign.circle") }
                    }
                    if !entry.skills.isEmpty || !entry.delegates.isEmpty || !entry.subagents.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(entry.skills, id: \.name) { s in Chip(text: label(s), icon: "wand.and.stars", color: Theme.purple) }
                            ForEach(entry.delegates, id: \.name) { d in Chip(text: label(d), icon: "person.2", color: Theme.blue) }
                            ForEach(entry.subagents, id: \.name) { s in Chip(text: label(s), icon: "cpu", color: Theme.green) }
                        }
                    }
                    if status == .failed, let error = run.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(Theme.red).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { store.selectedTaskId = run.taskId }
            .help("Open the task")
        }
    }

    private func label(_ item: (name: String, count: Int)) -> String {
        item.count > 1 ? "\(item.name) ×\(item.count)" : item.name
    }

    private var trigger: String {
        switch entry.run.trigger {
        case "schedule": "Scheduled"
        case "agent": entry.calledBy.map { "Called by \($0)" } ?? "Called by an agent"
        default: "Manual"
        }
    }

    private var duration: TimeInterval? {
        guard let start = LocalDate.parse(entry.run.startedAt) else { return nil }
        let end = entry.run.endedAt.flatMap { LocalDate.parse($0) } ?? (live ? Date() : nil)
        return end.map { $0.timeIntervalSince(start) }
    }
}

/// Small tinted capsule for skills and sub-agents.
private struct Chip: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}
