import ClaudistCore
import GRDB
import SwiftUI

/// Everything agents are waiting on: questions they asked and permission prompts.
struct NeedsYouView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var tasks = Observed<[TaskItem]>([])

    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "Needs you", subtitle: "Agents are waiting for your decision", icon: "hand.raised.fill", iconColor: .orange)
                    if tasks.value.isEmpty {
                        ContentUnavailableView("Nothing is waiting for you", systemImage: "checkmark.seal",
                                               description: Text("When an agent can't continue without your decision, it shows up here"))
                            .padding(.top, 40)
                    }
                    ForEach(tasks.value) { task in
                        AttentionCard(task: task)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .onAppear { tasks.observe(store.db) { try Attention.tasks($0) } }
    }
}

/// One waiting task: its question with quick answers, or its permission prompts.
struct AttentionCard: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    let task: TaskItem
    var compact = false
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact { header }
            if let question = task.attention {
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: store.agent(task.agentId)?.name ?? "A", size: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(store.agent(task.agentId)?.name ?? "The agent") asks")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                        MarkdownText(text: question)
                    }
                }
                if !task.attentionChoices.isEmpty {
                    FlowButtons(options: task.attentionChoices) { answer($0) }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(task.attentionChoices.isEmpty ? "Your answer" : "Or write your own answer", text: $reply, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...6)
                        .onSubmit { answer(reply) }
                    Button { answer(reply) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                            .foregroundStyle(reply.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.tertiary : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
            if let liveRun = runs.live[task.id], !liveRun.pending.isEmpty {
                PendingPermissions(liveRun: liveRun, taskId: task.id)
            } else if task.attention == nil {
                // Waiting run whose process is gone (e.g. app restarted): nothing to approve any more.
                Text("This run was waiting for a permission but is no longer active. Run the task again.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(compact ? 0 : 16)
        .background(compact ? nil : RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))
        .overlay(compact ? nil : RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            PriorityCheckbox(task: task, size: 16)
            Text(task.content).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            if let p = store.project(task.projectId) {
                HStack(spacing: 3) {
                    Image(systemName: "number").foregroundStyle(Theme.color(p.color))
                    Text(p.name)
                }
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if let at = task.attentionAt {
                Text(RunHistoryView.when(at)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Menu {
                Button("Open task") { store.openAgentTab(task.id) }
                Button("Dismiss without answering") { runs.dismissQuestion(taskId: task.id) }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.secondary).frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture { store.openAgentTab(task.id) }
    }

    /// Sends the answer into the agent's session; the run continues where it stopped.
    private func answer(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard task.agentId != nil else {
            store.errorMessage = "This task has no agent any more"
            return
        }
        runs.send(task, text: t)
        reply = ""
    }
}

/// Wrapping row of option buttons.
private struct FlowButtons: View {
    let options: [String]
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button { pick(option) } label: {
                    Text(option)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.accentSoft))
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Left-to-right layout that wraps to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: maxX, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
