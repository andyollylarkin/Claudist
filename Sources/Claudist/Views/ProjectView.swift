import ClaudistCore
import GRDB
import SwiftUI

struct ProjectView: View {
    @EnvironmentObject var store: AppStore
    let project: Project
    @StateObject private var tasks = Observed<[TaskItem]>([])
    @StateObject private var decor = Observed(TaskDecor())
    @State private var showCompleted = false
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if project.viewStyle == .board {
                BoardView(columns: columns(subtasks: false), decor: decor.value, trailing: AnyView(AddSectionField(project: project).frame(width: 280)))
            } else if project.viewStyle == .calendar {
                let projectId = project.id
                TaskCalendar(tasks: tasks.value, decor: decor.value, newTask: { content, day in
                    var t = TaskItem(projectId: projectId, content: content)
                    t.dueDate = day
                    return t
                })
            } else {
                GroupedListView(columns: columns(subtasks: true), decor: decor.value, depth: depth,
                                footer: AnyView(AddSectionField(project: project).padding(.top, 18)))
            }
        }
        // Empty content must not let the header float to the middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("")
        .sheet(isPresented: $editing) { ProjectEditor(project: project) }
        .onAppear(perform: observe)
        .onChange(of: showCompleted) { observe() }
    }

    private var header: some View {
        Group {
            if project.viewStyle != .list {
                headerContent.padding(.horizontal, 36)
            } else {
                ReadableColumn { headerContent }
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 6)
    }

    private var headerContent: some View {
        PageHeader(title: project.name, subtitle: breadcrumb) {
            HStack(spacing: 4) {
                ViewStyleSwitch(style: Binding(get: { project.viewStyle }, set: { style in
                    var p = project
                    p.viewStyle = style
                    store.write { try p.update($0) }
                }))
                CompletedToggle(isOn: $showCompleted)
                IconButton(icon: "ellipsis", help: "Edit project") { editing = true }
            }
        }
    }

    private var breadcrumb: String? {
        var names: [String] = []
        var parent = project.parentId
        while let id = parent, let p = store.project(id) {
            names.insert(p.name, at: 0)
            parent = p.parentId
        }
        return names.isEmpty ? nil : names.joined(separator: " / ")
    }

    private func observe() {
        let projectId = project.id
        let completed = showCompleted
        tasks.observe(store.db) { db in
            try TaskItem
                .filter(Column("projectId") == projectId)
                .filter(completed || Column("isCompleted") == false)
                .order(Column("isCompleted"), Column("childOrder"), Column("createdAt"))
                .fetchAll(db)
        }
        decor.observe(store.db) { try TaskDecor.fetch($0) }
    }

    /// Tasks in tree order: each parent followed by its subtasks.
    private func ordered(_ list: [TaskItem]) -> [TaskItem] {
        let ids = Set(list.map(\.id))
        var out: [TaskItem] = []
        func walk(_ parent: ID?) {
            for t in list where t.parentId == parent || (parent == nil && t.parentId.map { !ids.contains($0) } == true) {
                out.append(t)
                walk(t.id)
            }
        }
        walk(nil)
        return out
    }

    private func depth(_ task: TaskItem) -> Int {
        var d = 0
        var parent = task.parentId
        while let p = parent, let t = tasks.value.first(where: { $0.id == p }) {
            d += 1
            parent = t.parentId
        }
        return d
    }

    private func columns(subtasks: Bool) -> [BoardColumn] {
        let all = tasks.value
        let visible = subtasks ? all : all.filter { $0.parentId == nil }
        let projectId = project.id
        let sections = store.sections(of: project.id)
        var cols = [BoardColumn(
            id: "none", title: sections.isEmpty ? "" : "No section",
            tasks: ordered(visible.filter { $0.sectionId == nil }),
            onDrop: { $0.sectionId = nil; $0.projectId = projectId },
            newTask: { TaskItem(projectId: projectId, content: $0) },
            reordersSections: true)]
        for section in sections {
            cols.append(BoardColumn(
                id: section.id, title: section.name,
                tasks: ordered(visible.filter { $0.sectionId == section.id }),
                onDrop: { $0.sectionId = section.id; $0.projectId = projectId },
                newTask: { var t = TaskItem(projectId: projectId, content: $0); t.sectionId = section.id; return t },
                section: section, reordersSections: true))
        }
        if cols[0].tasks.isEmpty, cols.count > 1 { cols.removeFirst() }
        return cols
    }
}

/// List / Board switch.
struct ViewStyleSwitch: View {
    @Binding var style: ViewStyle

    var body: some View {
        HStack(spacing: 0) {
            segment(.list, "list.bullet", "List")
            segment(.board, "rectangle.split.3x1", "Board")
            segment(.calendar, "calendar", "Calendar")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
    }

    private func segment(_ value: ViewStyle, _ icon: String, _ title: String) -> some View {
        Button { style = value } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: style == value ? .semibold : .regular))
            .foregroundStyle(style == value ? Theme.text : Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(style == value ? Theme.card : .clear)
                .shadow(color: .black.opacity(style == value ? 0.08 : 0), radius: 1, y: 1))
        }
        .buttonStyle(.plain)
    }
}

/// "Add section" that turns into a name field.
private struct AddSectionField: View {
    @EnvironmentObject var store: AppStore
    let project: Project
    @State private var open = false
    @State private var name = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        if open {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name this section", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    .focused($focused)
                    .onSubmit(add)
                HStack {
                    Button("Add section", action: add).buttonStyle(AccentButtonStyle())
                    Button("Cancel") { open = false; name = "" }.buttonStyle(AccentButtonStyle(prominent: false))
                }
            }
            .padding(.vertical, 8)
        } else {
            Button { open = true; focused = true } label: {
                HStack(spacing: 8) {
                    Rectangle().fill(hovering ? Theme.accent : Theme.divider).frame(height: 1)
                    Text("Add section").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.accent : Theme.tertiary)
                        .fixedSize()
                    Rectangle().fill(hovering ? Theme.accent : Theme.divider).frame(height: 1)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let order = (store.sections(of: project.id).map(\.sectionOrder).max() ?? 0) + 1
        store.write { try ClaudistCore.Section(projectId: project.id, name: n, sectionOrder: order).insert($0) }
        name = ""
        open = false
    }
}
