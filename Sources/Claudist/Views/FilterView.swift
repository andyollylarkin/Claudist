import ClaudistCore
import GRDB
import SwiftUI

struct FilterView: View {
    @EnvironmentObject var store: AppStore
    let filter: SavedFilter
    @StateObject private var groups = Observed<[FilterResultGroup]>([])
    @StateObject private var decor = Observed(TaskDecor())
    @State private var editing = false
    @State private var showCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = groups.error {
                ReadableColumn {
                    SwiftUI.Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.red)
                        .padding(.vertical, 8)
                }
            }
            if filter.viewStyle == .board {
                BoardView(columns: columns, decor: decor.value, showProject: true)
            } else if filter.viewStyle == .calendar {
                TaskCalendar(tasks: columns.flatMap(\.tasks), decor: decor.value, showProject: true,
                             newTask: store.projectTree.first.map { first in { content, day in
                                 var t = TaskItem(projectId: first.project.id, content: content)
                                 t.dueDate = day
                                 return t
                             } })
            } else if columns.allSatisfy({ $0.tasks.isEmpty }) {
                ContentUnavailableView("Nothing matches this filter", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text(filter.query))
            } else {
                GroupedListView(columns: columns, decor: decor.value, showProject: true)
            }
        }
        // Empty content must not let the header float to the middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("")
        .sheet(isPresented: $editing) { FilterEditor(filter: filter) }
        .onAppear(perform: observe)
        .onChange(of: filter.query) { observe() }
        .onChange(of: showCompleted) { observe() }
        // Relative dates (today, overdue) move with the clock.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in observe() }
    }

    private var header: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
            PageHeader(title: filter.name, icon: "line.3.horizontal.decrease", iconColor: Theme.color(filter.color)) {
                HStack(spacing: 4) {
                    Menu {
                        Picker("Group by", selection: binding(\.groupBy)) {
                            ForEach(GroupBy.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                            Text(filter.groupBy == .none ? "Group" : filter.groupBy.title)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    ViewStyleSwitch(style: binding(\.viewStyle))
                    CompletedToggle(isOn: $showCompleted)
                    IconButton(icon: "ellipsis", help: "Edit filter") { editing = true }
                }
            }
            Text(filter.query)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hover))
                .textSelection(.enabled)
        }
        return Group {
            if filter.viewStyle != .list { content.padding(.horizontal, 36) } else { ReadableColumn { content } }
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SavedFilter, T>) -> Binding<T> {
        Binding(get: { filter[keyPath: keyPath] }, set: { value in
            var f = filter
            f[keyPath: keyPath] = value
            store.write { try f.update($0) }
        })
    }

    private func observe() {
        let query = filter.query
        let completed = showCompleted
        groups.observe(store.db) { db in
            try FilterEngine.tasks(db, query: query, context: FilterContext(now: Date()), includeCompleted: completed)
                .map { FilterResultGroup(title: $0.title, tasks: $0.tasks) }
        }
        decor.observe(store.db) { try TaskDecor.fetch($0) }
    }

    // MARK: Columns

    private var columns: [BoardColumn] {
        switch filter.groupBy {
        case .none:
            return groups.value.enumerated().map { i, g in
                BoardColumn(id: "\(i)", title: groups.value.count > 1 ? g.title : "", tasks: g.tasks)
            }
        default:
            var seen = Set<ID>()
            let all = groups.value.flatMap(\.tasks).filter { seen.insert($0.id).inserted }
            return grouped(all)
        }
    }

    private func grouped(_ all: [TaskItem]) -> [BoardColumn] {
        switch filter.groupBy {
        case .none:
            return []

        case .project:
            return store.projectTree.map(\.project).compactMap { p in
                let tasks = all.filter { $0.projectId == p.id }
                return tasks.isEmpty ? nil : BoardColumn(
                    id: p.id, title: p.name, color: Theme.color(p.color), tasks: tasks,
                    onDrop: { $0.projectId = p.id; $0.sectionId = nil; $0.parentId = nil })
            }

        case .section:
            var cols: [BoardColumn] = []
            for p in store.projectTree.map(\.project) {
                let inProject = all.filter { $0.projectId == p.id }
                guard !inProject.isEmpty else { continue }
                let loose = inProject.filter { $0.sectionId == nil }
                if !loose.isEmpty {
                    cols.append(BoardColumn(id: p.id, title: p.name, color: Theme.color(p.color), tasks: loose,
                                            onDrop: { $0.projectId = p.id; $0.sectionId = nil; $0.parentId = nil }))
                }
                for s in store.sections(of: p.id) {
                    let tasks = inProject.filter { $0.sectionId == s.id }
                    if tasks.isEmpty { continue }
                    cols.append(BoardColumn(id: s.id, title: "\(p.name) / \(s.name)", color: Theme.color(p.color), tasks: tasks,
                                            onDrop: { $0.projectId = p.id; $0.sectionId = s.id; $0.parentId = nil }))
                }
            }
            return cols

        case .priority:
            return (1...4).map { p in
                BoardColumn(id: "p\(p)", title: p == 4 ? "Priority 4" : "Priority \(p)", color: Theme.priority(p),
                            tasks: all.filter { $0.priority == p }, onDrop: { $0.priority = p })
            }

        case .date:
            let cal = Calendar.current
            let today = LocalDate.day(Date())
            let tomorrow = LocalDate.day(cal.date(byAdding: .day, value: 1, to: Date())!)
            let week = LocalDate.day(cal.date(byAdding: .day, value: 7, to: Date())!)
            func setDate(_ d: String?) -> (inout TaskItem) -> Void {
                { t in
                    t.dueDate = d
                    if d == nil { t.dueTime = nil; t.dueString = nil; t.isRecurring = false }
                    else if !t.isRecurring { t.dueString = nil }
                }
            }
            let buckets: [(String, Color?, (TaskItem) -> Bool, ((inout TaskItem) -> Void)?)] = [
                ("Overdue", Theme.red, { $0.isOverdue }, nil),
                ("Today", Theme.green, { !$0.isOverdue && $0.dueDate == today }, setDate(today)),
                ("Tomorrow", Theme.orange, { $0.dueDate == tomorrow }, setDate(tomorrow)),
                ("Next 7 days", Theme.purple, { ($0.dueDate ?? "") > tomorrow && ($0.dueDate ?? "") <= week }, nil),
                ("Later", Theme.blue, { ($0.dueDate ?? "") > week }, nil),
                ("No date", Theme.tertiary, { $0.dueDate == nil }, setDate(nil)),
            ]
            return buckets.map { title, color, match, drop in
                BoardColumn(id: title, title: title, color: color, tasks: all.filter(match), onDrop: drop)
            }

        case .label:
            let decor = decor.value
            var cols = store.labels.compactMap { label -> BoardColumn? in
                let tasks = all.filter { decor.labels[$0.id]?.contains(label.name) == true }
                return tasks.isEmpty ? nil : BoardColumn(
                    id: label.id, title: label.name, color: Theme.color(label.color), tasks: tasks,
                    onDrop: { t in let id = t.id; store.write { try TaskLabel(taskId: id, labelId: label.id).save($0) } })
            }
            let none = all.filter { decor.labels[$0.id]?.isEmpty ?? true }
            cols.append(BoardColumn(id: "nolabel", title: "No labels", tasks: none, onDrop: { t in
                let id = t.id
                store.write { try $0.execute(sql: "DELETE FROM taskLabel WHERE taskId = ?", arguments: [id]) }
            }))
            return cols

        case .agent:
            var cols = store.agents.map { agent in
                BoardColumn(id: agent.id, title: agent.name, tasks: all.filter { $0.agentId == agent.id },
                            onDrop: { $0.agentId = agent.id })
            }
            cols.append(BoardColumn(id: "noagent", title: "Unassigned", tasks: all.filter { $0.agentId == nil },
                                    onDrop: { $0.agentId = nil }))
            return cols

        case .run:
            let decor = decor.value
            var cols = RunStatus.allCases.map { status in
                BoardColumn(id: status.rawValue, title: status.title, color: status.color,
                            tasks: all.filter { decor.runStatus[$0.id] == status })
            }
            cols.append(BoardColumn(id: "never", title: "Never run", tasks: all.filter { decor.runStatus[$0.id] == nil }))
            return cols.filter { !$0.tasks.isEmpty || $0.id == RunStatus.running.rawValue }
        }
    }
}

struct FilterResultGroup: Equatable {
    var title: String
    var tasks: [TaskItem]
}

extension GroupBy {
    var title: String {
        switch self {
        case .none: "None"
        case .project: "Project"
        case .section: "Section"
        case .priority: "Priority"
        case .date: "Date"
        case .label: "Label"
        case .agent: "Agent"
        case .run: "Run status"
        }
    }
}

struct FilterEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var filter: SavedFilter
    @State private var showingHelp = false

    private var parseError: String? {
        guard !filter.query.isEmpty else { return nil }
        do { _ = try FilterQuery.parse(filter.query); return nil } catch { return "\(error)" }
    }

    private static let examples = [
        ("today | overdue", "Due today or overdue"),
        ("#Work & p1", "Priority 1 in Work"),
        ("##Work & !assigned", "Work and sub-projects, no agent"),
        ("7 days & @review", "Next 7 days with label review"),
        ("agent: Researcher & run: failed", "Failed runs of an agent"),
        ("today, overdue, no date", "Three groups"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(filter.name.isEmpty ? "Add filter" : "Edit filter")
                .font(.system(size: 16, weight: .bold))
                .padding(20)
            Divider()
            Form {
                TextField("Name", text: $filter.name)
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Query", text: $filter.query, prompt: Text("(today | overdue) & #Work"))
                        .font(.system(.body, design: .monospaced))
                    HStack {
                        if let parseError {
                            Text(parseError).font(.caption).foregroundStyle(Theme.red)
                        }
                        Spacer()
                        Button { showingHelp = true } label: {
                            SwiftUI.Label("Syntax help", systemImage: "questionmark.circle").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                }
                DisclosureGroup("Examples") {
                    ForEach(Self.examples, id: \.0) { q, d in
                        Button { filter.query = q } label: {
                            HStack {
                                Text(q).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(d).font(.caption).foregroundStyle(Theme.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker(selection: $filter.color)
                Picker("Group by", selection: $filter.groupBy) {
                    ForEach(GroupBy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Layout", selection: $filter.viewStyle) {
                    SwiftUI.Label("List", systemImage: "list.bullet").tag(ViewStyle.list)
                    SwiftUI.Label("Board", systemImage: "rectangle.split.3x1").tag(ViewStyle.board)
                    SwiftUI.Label("Calendar", systemImage: "calendar").tag(ViewStyle.calendar)
                }
                .pickerStyle(.segmented)
                Toggle("Add to favorites", isOn: $filter.isFavorite)
            }
            .formStyle(.grouped)
            DialogButtons(confirm: "Save", disabled: filter.name.isEmpty || filter.query.isEmpty || parseError != nil) {
                store.write { try filter.save($0) }
                store.selection = .filter(filter.id)
                dismiss()
            }
        }
        .frame(width: 540)
        // The editor is itself a sheet, so the help opens from here rather than from the window.
        .sheet(isPresented: $showingHelp) { SyntaxHelpView(tab: .filters) }
    }
}
