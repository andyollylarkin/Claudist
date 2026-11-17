import ClaudistCore
import GRDB
import SwiftUI

/// What the task's agents were given and what they touched: secrets, files, commands,
/// sub-agents, databases, web, skills — from the recorded runs.
struct AuditView: View {
    @EnvironmentObject var store: AppStore
    let task: TaskItem

    struct Data: Equatable {
        var entries: [AuditEntry] = []
        var access: [ID: RunAccess] = [:]
    }

    @StateObject private var audit = Observed(Data())
    @AppStorage("audit.subtasks") private var includeSubtasks = true
    @State private var category: AuditEntry.Category?
    @State private var warningsOnly = false
    @State private var search = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                controls
                accessCard
                let warnings = audit.value.entries.filter { $0.warning != nil }
                if !warnings.isEmpty {
                    Button { warningsOnly.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("\(warnings.count) thing\(warnings.count == 1 ? "" : "s") to check: secret values in output or paths outside the agent's folders")
                                .font(.system(size: 12)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(warningsOnly ? "Show all" : "Show only these").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                if audit.value.entries.isEmpty {
                    Text("Nothing recorded yet: the audit fills in as the agent works.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    ForEach(AuditEntry.Category.allCases, id: \.self) { c in
                        let list = filtered.filter { $0.category == c }
                        if !list.isEmpty { section(c, list) }
                    }
                    if filtered.isEmpty {
                        Text("Nothing matches").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .padding(20)
        }
        .onAppear(perform: observe)
        .onChange(of: includeSubtasks) { observe() }
    }

    private func observe() {
        let id = task.id
        let sub = includeSubtasks
        audit.observe(store.db) { db in
            let (entries, access) = try RunAudit.entries(db, taskId: id, subtasks: sub)
            return Data(entries: entries, access: access)
        }
    }

    private var filtered: [AuditEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return audit.value.entries.filter { e in
            (category == nil || e.category == category)
                && (!warningsOnly || e.warning != nil)
                && (q.isEmpty || [e.action, e.target, e.detail ?? "", e.agent ?? ""].contains { $0.lowercased().contains(q) })
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                TextField("Search paths, commands, SQL…", text: $search).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
            InlineMenu(value: category?.title ?? "Everything",
                       options: [("", "Everything")] + AuditEntry.Category.allCases
                        .filter { c in audit.value.entries.contains { $0.category == c } }
                        .map { c in (c.rawValue, "\(c.title) (\(audit.value.entries.filter { $0.category == c }.count))") }) {
                category = AuditEntry.Category(rawValue: $0)
            }
            .fixedSize()
            Toggle("Sub-agents", isOn: $includeSubtasks)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .help("Include what the agents called by this task did in their sub-tasks")
        }
    }

    // MARK: Access

    /// Latest recorded access per agent.
    private var accesses: [RunAccess] {
        var seen: [String: RunAccess] = [:]
        var order: [String] = []
        let runOrder = audit.value.entries.map(\.runId)
        let ids = audit.value.access.keys.sorted { (runOrder.lastIndex(of: $0) ?? -1) < (runOrder.lastIndex(of: $1) ?? -1) }
        for id in ids {
            guard let a = audit.value.access[id] else { continue }
            if seen[a.agent] == nil { order.append(a.agent) }
            seen[a.agent] = a
        }
        return order.compactMap { seen[$0] }
    }

    @ViewBuilder private var accessCard: some View {
        let list = accesses
        VStack(alignment: .leading, spacing: 10) {
            Text("Access given").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
            if list.isEmpty {
                Text("Recorded for runs started from now on.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            ForEach(list, id: \.agent) { a in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Pill(text: a.agent, icon: "person.crop.circle", color: Theme.accent)
                        Pill(text: a.isolation, icon: a.isolation == "On this Mac" ? "laptopcomputer" : "shippingbox",
                             color: a.isolation == "On this Mac" ? Theme.orange : Theme.green)
                        if let account = a.account { Pill(text: account, icon: "person.badge.key", color: Theme.purple) }
                    }
                    accessRow("folder", "Folder", [a.folder])
                    accessRow("key", "Secrets", a.secrets.map { $0.name + ($0.access == "file" ? " (file)" : "") })
                    accessRow("externaldrive", "Storage", a.storages.map { "\($0.name) — \($0.access == "rw" ? "read & write" : "read")" })
                    accessRow("paperclip", "Attachments", a.attachments.map { "\($0.name) — \($0.access == "rw" ? "read & write" : "read")" })
                    accessRow("cylinder.split.1x2", "Databases", a.databases.map { "\($0.name) — \($0.access == "rw" ? "read & write" : "read")" })
                    accessRow("person.2", "Can call", a.delegates)
                    accessRow("wand.and.stars", "Skills", a.skills)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
    }

    @ViewBuilder private func accessRow(_ icon: String, _ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.tertiary).frame(width: 14)
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 78, alignment: .leading)
                Text(values.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sections

    private func section(_ c: AuditEntry.Category, _ list: [AuditEntry]) -> some View {
        let key = c.rawValue
        let rows: [Row] = c == .file || c == .secret || c == .skill || c == .web ? grouped(list) : list.reversed().map { Row(entries: [$0]) }
        let limit = expanded.contains(key) ? rows.count : 25
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(c.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                Text("\(list.count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
            }
            .padding(.bottom, 6)
            ForEach(rows.prefix(limit)) { row in
                AuditRow(row: row, showAgent: Set(audit.value.entries.compactMap(\.agent)).count > 1)
                Divider()
            }
            if rows.count > limit {
                Button("Show all \(rows.count)") { expanded.insert(key) }
                    .buttonStyle(.link).font(.system(size: 11)).padding(.top, 6)
            }
        }
    }

    /// Same target and action merged, newest first.
    private func grouped(_ list: [AuditEntry]) -> [Row] {
        var order: [String] = []
        var map: [String: [AuditEntry]] = [:]
        for e in list.reversed() {
            let k = e.action + "\u{1}" + e.target
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(e)
        }
        return order.map { Row(entries: map[$0]!) }
    }

    struct Row: Identifiable {
        var entries: [AuditEntry]
        var id: String { entries[0].id }
        var first: AuditEntry { entries[0] }
    }
}

private struct AuditRow: View {
    @EnvironmentObject var store: AppStore
    let row: AuditView.Row
    let showAgent: Bool
    @State private var open = false

    var body: some View {
        let e = row.first
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon(e))
                    .font(.system(size: 11))
                    .foregroundStyle(e.failed ? Theme.red : e.warning != nil ? .orange : Theme.secondary)
                    .frame(width: 14)
                Text(e.action).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                    .frame(minWidth: 52, alignment: .leading)
                Text(e.target.isEmpty ? "—" : e.target)
                    .font(.system(size: 12, design: e.category == .subagent || e.category == .task ? .default : .monospaced))
                    .foregroundStyle(e.linkedTaskId != nil ? Theme.accent : Theme.text)
                    .lineLimit(open ? nil : 2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if row.entries.count > 1 {
                    Text("×\(row.entries.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                if showAgent, let agent = e.agent {
                    Text(agent).font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Text(RunHistoryView.when(e.at)).font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize()
            }
            if let warning = e.warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange).padding(.leading, 22)
            }
            if e.failed {
                Text(e.category == .permission ? "Denied" : "The call failed").font(.system(size: 11)).foregroundStyle(Theme.red).padding(.leading, 22)
            }
            if let detail = e.detail, !detail.isEmpty, detail != e.target {
                Text(detail)
                    .font(.system(size: 11, design: e.category == .database || e.category == .secret ? .monospaced : .default))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(open ? nil : 2)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = e.linkedTaskId { store.selectedTaskId = id } else { open.toggle() }
        }
        .help(e.linkedTaskId != nil ? "Open the sub-task" : "Click to show it all")
    }

    private func icon(_ e: AuditEntry) -> String {
        switch e.category {
        case .secret: "key"
        case .file: e.action == "read" || e.action == "searched" || e.action == "listed" ? "doc.text" : "square.and.pencil"
        case .command: "terminal"
        case .subagent: "person.2"
        case .database: "cylinder.split.1x2"
        case .web: "globe"
        case .skill: "wand.and.stars"
        case .task: "checklist"
        case .tool: "wrench.and.screwdriver"
        case .permission: "hand.raised"
        }
    }
}
