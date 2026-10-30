import AgentDeskCore
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
    }
}

private struct ColumnView: View {
    @EnvironmentObject var store: AppStore
    let column: BoardColumn
    let decor: TaskDecor
    let showProject: Bool
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let color = column.color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(column.title.isEmpty ? "Tasks" : column.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(column.tasks.count)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(column.tasks) { task in
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
            guard let apply = column.onDrop else { return false }
            store.write { db in
                for id in ids {
                    guard var task = try TaskItem.fetchOne(db, key: id) else { continue }
                    apply(&task)
                    try task.update(db)
                }
            }
            return true
        } isTargeted: { targeted = $0 && column.onDrop != nil }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
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
            guard let apply = column.onDrop else { return false }
            store.write { db in
                for id in ids {
                    guard var task = try TaskItem.fetchOne(db, key: id) else { continue }
                    apply(&task)
                    try task.update(db)
                }
            }
            return true
        } isTargeted: { targeted = $0 && column.onDrop != nil }
    }
}
