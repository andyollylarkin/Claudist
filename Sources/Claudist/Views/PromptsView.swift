import ClaudistCore
import GRDB
import SwiftUI

/// Library of shared prompts: instructions written once and merged into agents' system prompts.
struct PromptsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var usage = Observed<[ID: [String]]>([:])
    @State private var editing: PromptTemplate?
    @State private var isNew = false

    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Prompts", subtitle: "Shared instructions merged into the system prompt of the agents that use them") {
                        Button { isNew = true; editing = PromptTemplate(name: "") } label: { SwiftUI.Label("Add prompt", systemImage: "plus") }
                            .buttonStyle(AccentButtonStyle())
                    }
                    if store.promptTemplates.isEmpty {
                        ContentUnavailableView("No shared prompts yet", systemImage: "text.quote",
                                               description: Text("Write rules once (style, reporting, git conventions) and give them to several agents or to all"))
                            .padding(.top, 40)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.promptTemplates.enumerated()), id: \.element.id) { i, t in
                                row(t, index: i, last: i == store.promptTemplates.count - 1)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
                        Text("Merged in this order, before each agent's own prompt. Placeholders: {{agent}}, {{description}}, {{folder}}, {{date}}. Changes apply to the next run or resumed conversation.")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .sheet(item: $editing) { PromptTemplateEditor(template: $0, isNew: isNew) }
        .onAppear {
            usage.observe(store.db) { db in
                var map: [ID: [String]] = [:]
                for row in try Row.fetchAll(db, sql: """
                    SELECT l.templateId, a.name FROM agentPromptTemplate l JOIN agent a ON a.id = l.agentId ORDER BY a.name
                    """) { map[row[0], default: []].append(row[1]) }
                return map
            }
        }
    }

    private func row(_ t: PromptTemplate, index: Int, last: Bool) -> some View {
        HoverRow(cornerRadius: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.accentSoft)
                    Image(systemName: "text.quote").font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    if !t.description.isEmpty {
                        Text(t.description).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Text(t.content.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(2)
                    HStack(spacing: 10) {
                        if t.forAllAgents {
                            Pill(text: "All agents", icon: "person.3.fill", color: Theme.green)
                        } else if let agents = usage.value[t.id], !agents.isEmpty {
                            Pill(text: agents.joined(separator: ", "), icon: "person.2")
                        } else {
                            Text("Not used").foregroundStyle(Theme.tertiary)
                        }
                    }
                    .font(.system(size: 11))
                }
                Spacer()
                Menu {
                    Button("Edit…") { edit(t) }
                    Button("Move up") { move(index, by: -1) }.disabled(index == 0)
                    Button("Move down") { move(index, by: 1) }.disabled(index == store.promptTemplates.count - 1)
                    Divider()
                    Button("Delete", role: .destructive) { store.write { _ = try t.delete($0) } }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.secondary).frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { edit(t) }
        }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 54) } }
    }

    private func edit(_ t: PromptTemplate) { isNew = false; editing = t }

    private func move(_ index: Int, by delta: Int) {
        var list = store.promptTemplates
        let target = index + delta
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        store.write { db in
            for (i, var t) in list.enumerated() where t.itemOrder != i {
                t.itemOrder = i
                try t.update(db)
            }
        }
    }
}

struct PromptTemplateEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var template: PromptTemplate
    let isNew: Bool
    @StateObject private var linked = Observed<[ID]>([])
    @State private var selected: Set<ID> = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add prompt" : "Edit prompt").font(.system(size: 16, weight: .bold)).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        BoxedField(placeholder: "Reporting rules", text: $template.name)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        BoxedField(placeholder: "What these instructions are about", text: $template.description)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instructions").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        BoxedEditor(text: $template.content, minHeight: 220)
                        Text("Placeholders: {{agent}}, {{description}}, {{folder}}, {{date}}")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    Card {
                        CheckRow(title: "All agents", subtitle: "Every agent gets it, including agents added later",
                                 last: template.forAllAgents || store.agents.isEmpty, isOn: $template.forAllAgents)
                        if !template.forAllAgents {
                            ForEach(Array(store.agents.enumerated()), id: \.element.id) { i, agent in
                                CheckRow(title: agent.name, subtitle: agent.description, last: i == store.agents.count - 1,
                                         isOn: Binding(get: { selected.contains(agent.id) },
                                                       set: { if $0 { selected.insert(agent.id) } else { selected.remove(agent.id) } }))
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 560)
            Divider()
            DialogButtons(confirm: "Save", disabled: template.name.trimmingCharacters(in: .whitespaces).isEmpty, action: save)
        }
        .frame(width: 560)
        .onAppear {
            let id = template.id
            linked.observe(store.db) { try String.fetchAll($0, sql: "SELECT agentId FROM agentPromptTemplate WHERE templateId = ?", arguments: [id]) }
        }
        .onChange(of: linked.value) { _, ids in
            if !loaded { selected = Set(ids); loaded = true }
        }
    }

    private func save() {
        template.name = template.name.trimmingCharacters(in: .whitespaces)
        template.updatedAt = LocalDate.stamp(Date())
        if isNew { template.itemOrder = (store.promptTemplates.map(\.itemOrder).max() ?? -1) + 1 }
        let t = template
        let ids = selected
        store.write { db in
            try t.save(db)
            try db.execute(sql: "DELETE FROM agentPromptTemplate WHERE templateId = ?", arguments: [t.id])
            for id in ids { try AgentPromptTemplate(agentId: id, templateId: t.id).insert(db) }
        }
        dismiss()
    }
}

/// Shared prompt checkboxes in the agent editor.
struct PromptTemplateLinks: View {
    @EnvironmentObject var store: AppStore
    let agent: Agent
    @StateObject private var linked = Observed<[ID]>([])

    var body: some View {
        Card(title: "Shared prompts",
             footer: "Merged before the agent's own prompt, in the order of the Prompts library.",
             trailing: AnyView(LinkButton(title: "Manage prompts", icon: "arrow.up.right") { store.selection = .prompts })) {
            if store.promptTemplates.isEmpty {
                CardEmpty(text: "No shared prompts yet")
            }
            ForEach(Array(store.promptTemplates.enumerated()), id: \.element.id) { i, t in
                let last = i == store.promptTemplates.count - 1
                if t.forAllAgents {
                    CheckRow(title: t.name, subtitle: t.description, note: "All agents", last: last, isOn: .constant(true))
                        .disabled(true)
                } else {
                    CheckRow(title: t.name, subtitle: t.description, last: last,
                             isOn: Binding(get: { linked.value.contains(t.id) }, set: { on in
                                 let link = AgentPromptTemplate(agentId: agent.id, templateId: t.id)
                                 store.write { db in if on { try link.save(db) } else { _ = try link.delete(db) } }
                             }))
                }
            }
        }
        .onAppear {
            let id = agent.id
            linked.observe(store.db) { try String.fetchAll($0, sql: "SELECT templateId FROM agentPromptTemplate WHERE agentId = ?", arguments: [id]) }
        }
    }
}
