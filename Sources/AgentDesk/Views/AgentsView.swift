import AgentDeskCore
import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct AgentsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    @State private var selected: ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Agents", subtitle: "Each agent has its own project folder, memory, skills, storage and secrets") {
                HStack(spacing: 8) {
                    Button { importAgents() } label: { SwiftUI.Label("Import .md", systemImage: "square.and.arrow.down") }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    Button { create() } label: { SwiftUI.Label("Add agent", systemImage: "plus") }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 14)
            Divider()
            HStack(spacing: 0) {
                agentList
                    .frame(width: 280)
                Divider()
                Group {
                    if let agent = store.agent(selected) {
                        AgentEditor(agent: agent).id(agent.id)
                    } else {
                        ContentUnavailableView("No agent selected", systemImage: "person.2",
                                               description: Text("Add an agent or import a Claude Code agent file (.claude/agents/*.md)"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .onAppear { if selected == nil { selected = store.agents.first?.id } }
    }

    private var agentList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.agents) { agent in
                    let running = runs.live.values.contains { liveRun in
                        (store.read { try TaskItem.fetchOne($0, key: liveRun.taskId) } ?? nil)?.agentId == agent.id
                    }
                    HoverRow(selected: selected == agent.id, cornerRadius: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            Avatar(name: agent.name, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(agent.name).font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(selected == agent.id ? Theme.accent : Theme.text)
                                    if running {
                                        Circle().fill(Theme.green).frame(width: 6, height: 6)
                                    }
                                }
                                Text(agent.description.isEmpty ? (agent.model ?? "default model") : agent.description)
                                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = agent.id }
                    }
                    .contextMenu {
                        AgentFolderMenu(folder: agent.folderPath).menuItems
                        Divider()
                        Button("Delete agent", role: .destructive) { delete(agent) }
                    }
                }
            }
            .padding(8)
        }
        .background(Theme.sidebar)
    }

    private func uniqueName(_ base: String) -> String {
        var name = base
        var i = 2
        while store.agents.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) \(i)"
            i += 1
        }
        return name
    }

    private func create() {
        let name = uniqueName("New agent")
        let agent = Agent(name: name, folderPath: store.workspace.defaultFolder(for: name).path)
        store.write { try agent.insert($0) }
        store.syncSkills(for: agent)
        selected = agent.id
    }

    private func importAgents() {
        let panel = Finder.openPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "Choose Claude Code agent files (.claude/agents/*.md)"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let parsed = AgentImporter.parse(text, fallbackName: url.deletingPathExtension().lastPathComponent)
                let name = uniqueName(parsed.name)
                var agent = Agent(name: name, folderPath: store.workspace.defaultFolder(for: name).path)
                agent.description = parsed.description
                agent.model = parsed.model
                agent.tools = parsed.tools
                agent.prompt = parsed.prompt
                store.write { try agent.insert($0) }
                store.syncSkills(for: agent)
                selected = agent.id
            } catch {
                store.report(error)
            }
        }
    }

    private func delete(_ agent: Agent) {
        let alert = NSAlert()
        alert.messageText = "Delete agent “\(agent.name)”?"
        alert.informativeText = "The agent folder \(agent.folderPath) stays on disk."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.write { _ = try agent.delete($0) }
        if selected == agent.id { selected = store.agents.first { $0.id != agent.id }?.id }
    }
}

struct AgentEditor: View {
    @EnvironmentObject var store: AppStore
    @State var agent: Agent
    @StateObject private var skillLinks = Observed<[String]>([])
    @StateObject private var storageLinks = Observed<[AgentStorage]>([])
    @StateObject private var delegateLinks = Observed<[ID]>([])
    @State private var allowText = ""
    @State private var denyText = ""

    private static let models = [("", "Default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku"), ("fable", "Fable")]
    private static let modes = [
        ("manual", "Ask for everything"), ("acceptEdits", "Auto-accept edits"), ("plan", "Plan only"),
        ("auto", "Auto"), ("dontAsk", "Don't ask (deny unlisted)"), ("bypassPermissions", "Bypass all checks"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Avatar(name: agent.name, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Agent name", text: $agent.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .bold))
                        TextField("What is this agent for?", text: $agent.description, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                Card(title: "Runtime") {
                    FieldRow(title: "Model") {
                        InlineMenu(value: Self.models.first { $0.0 == (agent.model ?? "") }?.1 ?? (agent.model ?? "Default"),
                                   options: Self.models) { agent.model = $0.isEmpty ? nil : $0 }
                    }
                    FieldRow(title: "Tools", subtitle: "Empty means all tools") {
                        BoxedField(placeholder: "Read,Grep,Bash", text: Binding(get: { agent.tools ?? "" }, set: { agent.tools = $0.isEmpty ? nil : $0 }),
                                   monospaced: true)
                            .frame(maxWidth: 280)
                    }
                    FieldRow(title: "Folder", subtitle: "Working directory and memory of this agent", last: true) {
                        HStack(spacing: 6) {
                            Text(agent.folderPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button("Change…") { chooseFolder() }.buttonStyle(AccentButtonStyle(prominent: false))
                            AgentFolderMenu(folder: agent.folderPath)
                        }
                    }
                }

                Card(title: "System prompt", footer: "Appended to Claude Code's system prompt on every run.") {
                    BoxedEditor(text: $agent.prompt, minHeight: 160).padding(10)
                }

                Card(title: "Skills", footer: "Enabled skills are symlinked into the agent folder (.claude/skills).",
                     trailing: AnyView(LinkButton(title: "Manage library", icon: "arrow.up.right") { store.selection = .skills })) {
                    if store.skills.isEmpty {
                        CardEmpty(text: "The skill library is empty")
                    }
                    ForEach(Array(store.skills.enumerated()), id: \.element.id) { i, skill in
                        CheckRow(title: skill.name, subtitle: skill.description, last: i == store.skills.count - 1,
                                 isOn: Binding(get: { skillLinks.value.contains(skill.name) }, set: { on in
                                     let link = AgentSkill(agentId: agent.id, skillName: skill.name)
                                     store.write { db in if on { try link.save(db) } else { _ = try link.delete(db) } }
                                     store.syncSkills(for: agent)
                                 }))
                    }
                }

                Card(title: "Storage",
                     footer: "Read-only blocks Claude Code's file tools from writing there. Shell commands are not restricted.",
                     trailing: AnyView(LinkButton(title: "Manage storage", icon: "arrow.up.right") { store.selection = .storage })) {
                    if store.storages.isEmpty {
                        CardEmpty(text: "No folders in storage yet")
                    }
                    ForEach(Array(store.storages.enumerated()), id: \.element.id) { i, storage in
                        let link = storageLinks.value.first { $0.storageId == storage.id }
                        FieldRow(title: storage.name, subtitle: storage.path, last: i == store.storages.count - 1) {
                            AccessSwitch(value: link?.access.rawValue ?? "none") { value in
                                store.write { db in
                                    if let access = StorageAccess(rawValue: value) {
                                        try AgentStorage(agentId: agent.id, storageId: storage.id, access: access).save(db)
                                    } else {
                                        try db.execute(sql: "DELETE FROM agentStorage WHERE agentId = ? AND storageId = ?",
                                                       arguments: [agent.id, storage.id])
                                    }
                                }
                            }
                        }
                    }
                }

                SecretLinks(owner: .agent(agent.id))

                let others = store.agents.filter { $0.id != agent.id }
                Card(title: "Can call agents",
                     footer: "Selected agents become sub-agents: this agent can hand them work through the delegate tool. Each call creates a sub-task that runs in the called agent's own folder, with its own memory, skills and secrets, and its answer comes back to this agent.") {
                    if others.isEmpty {
                        CardEmpty(text: "Add more agents to let this one call them")
                    }
                    ForEach(Array(others.enumerated()), id: \.element.id) { i, other in
                        CheckRow(title: other.name, subtitle: other.description, last: i == others.count - 1,
                                 isOn: Binding(get: { delegateLinks.value.contains(other.id) }, set: { on in
                                     let link = AgentDelegate(agentId: agent.id, delegateId: other.id)
                                     store.write { db in if on { try link.save(db) } else { _ = try link.delete(db) } }
                                 }))
                    }
                }

                Card(title: "Permissions", footer: "Claude Code rules, one per line: Read, Edit, Bash(git *), WebFetch(domain:example.com). Anything else is asked in the task.") {
                    FieldRow(title: "Mode") {
                        InlineMenu(value: Self.modes.first { $0.0 == agent.permissionMode }?.1 ?? agent.permissionMode,
                                   options: Self.modes) { agent.permissionMode = $0 }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Always allow").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        BoxedEditor(text: $allowText, minHeight: 60)
                        Text("Always deny").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                            .padding(.top, 4)
                        BoxedEditor(text: $denyText, minHeight: 44)
                    }
                    .padding(14)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            allowText = agent.allowList.joined(separator: "\n")
            denyText = agent.denyList.joined(separator: "\n")
            let id = agent.id
            skillLinks.observe(store.db) { try String.fetchAll($0, sql: "SELECT skillName FROM agentSkill WHERE agentId = ?", arguments: [id]) }
            storageLinks.observe(store.db) { try AgentStorage.filter(Column("agentId") == id).fetchAll($0) }
            delegateLinks.observe(store.db) { try String.fetchAll($0, sql: "SELECT delegateId FROM agentDelegate WHERE agentId = ?", arguments: [id]) }
        }
        .onChange(of: agent) { _, a in save(a) }
        .onChange(of: allowText) { _, t in agent.allowList = Self.lines(t) }
        .onChange(of: denyText) { _, t in agent.denyList = Self.lines(t) }
        // "Always allow" in a task adds rules while the editor is open.
        .onReceive(store.$agents) { agents in
            if let fresh = agents.first(where: { $0.id == agent.id }), fresh.allowRules != agent.allowRules,
               Self.lines(allowText) != fresh.allowList {
                allowText = fresh.allowList.joined(separator: "\n")
            }
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save(_ a: Agent) {
        guard !a.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.write { try a.update($0) }
    }

    private func chooseFolder() {
        let panel = Finder.openPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Agent project folder: its memory (CLAUDE.md) and skills live here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if store.agents.contains(where: { $0.id != agent.id && $0.folderPath == url.path }) {
            store.errorMessage = "This folder already belongs to another agent. Agents must not share memory."
            return
        }
        agent.folderPath = url.path
        store.syncSkills(for: agent)
    }
}

/// None / Read / Read & write.
private struct AccessSwitch: View {
    let value: String
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("none", "None")
            segment(StorageAccess.ro.rawValue, "Read")
            segment(StorageAccess.rw.rawValue, "Read & write")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
    }

    private func segment(_ key: String, _ title: String) -> some View {
        Button { select(key) } label: {
            Text(title)
                .font(.system(size: 11, weight: value == key ? .semibold : .regular))
                .foregroundStyle(value == key ? (key == "none" ? Theme.text : Theme.accent) : Theme.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(value == key ? Theme.card : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// Finder shortcuts into the agent folder, including the hidden `.claude` directory.
struct AgentFolderMenu: View {
    let folder: String

    var body: some View {
        Menu { menuItems } label: { Image(systemName: "folder").foregroundStyle(Theme.secondary) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open in Finder")
    }

    @ViewBuilder var menuItems: some View {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        Button("Open agent folder") { open(root) }
        Button("Open .claude") { open(root.appendingPathComponent(".claude")) }
        Button("Open .claude/skills") { open(root.appendingPathComponent(".claude/skills")) }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("CLAUDE.md").path) {
            Button("Open CLAUDE.md") { NSWorkspace.shared.open(root.appendingPathComponent("CLAUDE.md")) }
        }
    }

    private func open(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Finder.open(url)
    }
}
