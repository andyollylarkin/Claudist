import ClaudistCore
import GRDB
import SwiftUI

struct BoardColumn: Identifiable {
    var id: String
    var title: String
    var color: Color?
    var tasks: [TaskItem]
    /// What dropping a card into this column changes; nil = not a drop target.
    var onDrop: ((inout TaskItem) -> Void)?
    /// Template for tasks added in this column; nil hides "Add task".
    var newTask: ((String) -> TaskItem?)?
    /// The project section this column shows: its header can be renamed, moved and deleted.
    var section: ClaudistCore.Section?
    /// Section headers dropped here are reordered (columns of a project).
    var reordersSections = false
}

struct BoardView: View {
    let columns: [BoardColumn]
    let decor: TaskDecor
    var showProject = false
    var trailing: AnyView?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(columns) { column in
                    ColumnView(column: column, decor: decor, showProject: showProject)
                }
                if let trailing { trailing }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// How a board column orders its cards; chosen per column and remembered.
enum ColumnSort: String, CaseIterable {
    case manual, priority, due, name, added

    var title: String {
        switch self {
        case .manual: "Manual"
        case .priority: "Priority"
        case .due: "Due date"
        case .name: "Name"
        case .added: "Date added"
        }
    }

    func apply(_ tasks: [TaskItem]) -> [TaskItem] {
        guard self != .manual else { return tasks }
        // Stable: ties keep the manual order.
        return Array(tasks.enumerated()).sorted { a, b in
            switch ordered(a.element, b.element) {
            case .some(let before): before
            case .none: a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Whether `a` goes before `b`; nil when they tie.
    private func ordered(_ a: TaskItem, _ b: TaskItem) -> Bool? {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> Bool? { x == y ? nil : x < y }
        switch self {
        case .manual: return nil
        case .priority: return cmp(a.priority, b.priority)
        case .due:
            // Undated last.
            return cmp(a.dueDate == nil ? 1 : 0, b.dueDate == nil ? 1 : 0)
                ?? cmp(a.dueDate ?? "", b.dueDate ?? "") ?? cmp(a.dueTime ?? "99", b.dueTime ?? "99")
        case .name: return cmp(a.content.localizedLowercase, b.content.localizedLowercase)
        // Newest first.
        case .added: return cmp(b.createdAt, a.createdAt)
        }
    }

    private static let storageKey = "boardColumnSorts"

    static func stored(_ columnId: String) -> ColumnSort {
        let all = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        return all[columnId].flatMap(ColumnSort.init) ?? .manual
    }

    static func store(_ sort: ColumnSort, for columnId: String) {
        var all = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        all[columnId] = sort == .manual ? nil : sort.rawValue
        UserDefaults.standard.set(all, forKey: storageKey)
    }
}

private struct ColumnSortMenu: View {
    @Binding var sort: ColumnSort

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(ColumnSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: sort == .manual ? .regular : .semibold))
                .foregroundStyle(sort == .manual ? Theme.tertiary : Theme.accent)
                .frame(width: 20, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(sort == .manual ? "Sort tasks" : "Sorted by \(sort.title.lowercased())")
    }
}

private struct ColumnView: View {
    @EnvironmentObject var store: AppStore
    let column: BoardColumn
    let decor: TaskDecor
    let showProject: Bool
    @State private var targeted = false
    @State private var renaming = false
    @State private var sort: ColumnSort = .manual

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, 4)
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(sort.apply(column.tasks)) { task in
                        TaskCard(task: task, decor: decor, showProject: showProject)
                    }
                    if let make = column.newTask {
                        AddTaskButton(make: make, compact: true)
                    }
                }
                .padding(2)
                .padding(.bottom, 20)
            }
        }
        .padding(8)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(targeted ? Theme.accentSoft : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(targeted ? Theme.accent.opacity(0.5) : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
        .dropDestination(for: String.self) { ids, _ in
            handleColumnDrop(ids, column: column, store: store)
        } isTargeted: { targeted = $0 && (column.onDrop != nil || column.reordersSections) }
        .onAppear { sort = ColumnSort.stored(column.id) }
        .onChange(of: sort) { _, new in ColumnSort.store(new, for: column.id) }
    }

    @ViewBuilder private var header: some View {
        if let section = column.section {
            HStack(spacing: 6) {
                SectionTitle(section: section, editing: $renaming)
                Text("\(column.tasks.count)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Spacer()
                ColumnSortMenu(sort: $sort)
                SectionMenu(section: section, horizontal: true) { renaming = true }
            }
            .contentShape(Rectangle())
            .draggable(SectionDrag.payload(section.id)) { DragPreview(title: section.name) }
            .contextMenu { SectionMenuItems(section: section, horizontal: true) { renaming = true } }
        } else {
            HStack(spacing: 6) {
                if let color = column.color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(column.title.isEmpty ? "Tasks" : column.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(column.tasks.count)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Spacer()
                ColumnSortMenu(sort: $sort)
            }
        }
    }
}

/// List with a header per group, in a readable centered column.
struct GroupedListView: View {
    let columns: [BoardColumn]
    let decor: TaskDecor
    var showProject = false
    /// Indentation for subtasks; nil when tasks are shown flat.
    var depth: ((TaskItem) -> Int)?
    var footer: AnyView?
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            ReadableColumn {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(columns) { column in
                        GroupSection(column: column, decor: decor, showProject: showProject, depth: depth,
                                     showHeader: columns.count > 1 || !column.title.isEmpty,
                                     collapsed: Binding(get: { collapsed.contains(column.id) },
                                                        set: { if $0 { collapsed.insert(column.id) } else { collapsed.remove(column.id) } }))
                    }
                    if let footer { footer }
                }
                .padding(.bottom, 40)
            }
        }
    }
}

private struct GroupSection: View {
    @EnvironmentObject var store: AppStore
    let column: BoardColumn
    let decor: TaskDecor
    let showProject: Bool
    let depth: ((TaskItem) -> Int)?
    let showHeader: Bool
    @Binding var collapsed: Bool
    @State private var targeted = false
    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let section = column.section {
                SectionHeader(title: section.name, count: column.tasks.count, collapsed: $collapsed,
                              titleView: AnyView(SectionTitle(section: section, editing: $renaming)),
                              trailing: AnyView(SectionMenu(section: section, horizontal: false) { renaming = true }))
                    .contentShape(Rectangle())
                    .draggable(SectionDrag.payload(section.id)) { DragPreview(title: section.name) }
                    .contextMenu { SectionMenuItems(section: section, horizontal: false) { renaming = true } }
            } else if showHeader {
                SectionHeader(title: column.title.isEmpty ? "No section" : column.title,
                              count: column.tasks.count, collapsed: $collapsed)
            }
            if !collapsed {
                ForEach(column.tasks) { task in
                    TaskRow(task: task, decor: decor, depth: depth?(task) ?? 0, showProject: showProject)
                }
                if let make = column.newTask {
                    AddTaskButton(make: make)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(targeted ? Theme.accentSoft.opacity(0.5) : .clear))
        .dropDestination(for: String.self) { ids, _ in
            handleColumnDrop(ids, column: column, store: store)
        } isTargeted: { targeted = $0 && (column.onDrop != nil || column.reordersSections) }
    }
}
