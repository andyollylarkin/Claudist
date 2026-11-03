import ClaudistCore
import GRDB
import SwiftUI

/// Finished agent work the user hasn't looked at: the agent's final message, open or mark reviewed.
struct ReviewView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var items = Observed<[Reviews.Item]>([])

    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "To review", subtitle: "Agents finished these tasks; open one to see the result",
                               icon: "checkmark.circle.fill", iconColor: Theme.accent) {
                        if !items.value.isEmpty {
                            Button("Mark all reviewed") { store.write { try Reviews.markAllReviewed($0) } }
                                .buttonStyle(AccentButtonStyle(prominent: false))
                        }
                    }
                    if items.value.isEmpty {
                        ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal",
                                               description: Text("When an agent finishes a task you haven't opened since, it shows up here"))
                            .padding(.top, 40)
                    }
                    ForEach(items.value) { item in
                        ReviewCard(item: item)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .onAppear { items.observe(store.db) { try Reviews.items($0) } }
    }
}

private struct ReviewCard: View {
    @EnvironmentObject var store: AppStore
    let item: Reviews.Item
    @State private var expanded = false

    private var agentName: String { store.agent(item.run.agentId ?? item.task.agentId)?.name ?? "The agent" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: agentName, size: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(agentName) finished").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                        if item.run.trigger == "schedule" {
                            Text("· scheduled").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                        if let cost = item.run.costUsd {
                            Text(String(format: "· $%.2f", cost)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    if item.result.isEmpty {
                        Text("No final message. Open the task to see what was done.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    } else {
                        // Natural height, cut off below: a capped frame would squeeze the blocks into each other.
                        MarkdownText(text: item.result, size: 13)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, maxHeight: expanded ? nil : 160, alignment: .topLeading)
                            .clipped()
                        if item.result.count > 500 || item.result.filter({ $0 == "\n" }).count > 8 {
                            Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Open task") { store.openAgentTab(item.task.id) }
                    .buttonStyle(AccentButtonStyle(prominent: true))
                Spacer()
                Button("Mark reviewed") { store.markReviewed(item.task.id) }
                    .buttonStyle(AccentButtonStyle(prominent: false))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.3)))
    }
}
