import ClaudistCore
import GRDB
import SwiftUI

/// Tasks whose agent run failed: the error, and a way to run again or put it aside.
struct FailedView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var items = Observed<[Failures.Item]>([])

    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Failed", subtitle: "Agent runs that ended with an error",
                               icon: "exclamationmark.triangle.fill", iconColor: Theme.red)
                    if items.value.isEmpty {
                        ContentUnavailableView("No failed runs", systemImage: "checkmark.seal",
                                               description: Text("When an agent's run fails, the task shows up here"))
                            .padding(.top, 40)
                    }
                    ForEach(items.value) { item in
                        FailureCard(item: item)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .onAppear { items.observe(store.db) { try Failures.items($0) } }
    }
}

private struct FailureCard: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    let item: Failures.Item
    @State private var expanded = false

    private var error: String {
        let e = item.run.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return e.isEmpty ? "The run failed without an error message. Open the task to see its log." : e
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: store.agent(item.run.agentId ?? item.task.agentId)?.name ?? "A", size: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(store.agent(item.run.agentId ?? item.task.agentId)?.name ?? "The agent") failed")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Text(error)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                        .lineLimit(expanded ? nil : 6)
                        .textSelection(.enabled)
                    if error.count > 400 || error.filter({ $0 == "\n" }).count > 5 {
                        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { runs.start(item.task) } label: { SwiftUI.Label("Run again", systemImage: "play.fill") }
                    .buttonStyle(AccentButtonStyle(prominent: true))
                    .disabled(runs.live[item.task.id] != nil || item.task.agentId == nil)
                Button("Open task") { store.openAgentTab(item.task.id) }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                Spacer()
                Button("Dismiss") { store.write { try Failures.dismiss($0, runId: item.run.id) } }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                    .help("Remove from Failed; the run stays in the task's history")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.red.opacity(0.35)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            PriorityCheckbox(task: item.task, size: 16)
            Text(item.task.content).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            if let p = store.project(item.task.projectId) {
                HStack(spacing: 3) {
                    Image(systemName: "number").foregroundStyle(Theme.color(p.color))
                    Text(p.name)
                }
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Text(RunHistoryView.when(item.run.endedAt ?? item.run.startedAt)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.openAgentTab(item.task.id) }
    }
}
