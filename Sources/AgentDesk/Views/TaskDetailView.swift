import AgentDeskCore
import GRDB
import SwiftUI

struct TaskDetailView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    let taskId: ID

    @StateObject private var observed = Observed<TaskItem?>(nil)
    @StateObject private var taskLabels = Observed<[ID]>([])
    @StateObject private var subtasks = Observed<[TaskItem]>([])
    @StateObject private var comments = Observed<[Comment]>([])
    @StateObject private var decor = Observed(TaskDecor())
    @State private var content = ""
    @State private var details = ""
    @State private var dueInput = ""
    @State private var dueError: String?
    @State private var newComment = ""
    @State private var tab = 0

    var body: some View {
        Group {
            if let task = observed.value {
                VStack(alignment: .leading, spacing: 0) {
                    topBar(task)
                    Divider()
                    header(task)
                    UnderlineTabs(titles: ["Details", "Agent" + (runs.live[task.id] != nil ? " •" : "")], selection: $tab)
                        .padding(.horizontal, 20)
                    if tab == 0 {
                        ScrollView { details(task).padding(20) }
                    } else {
                        AgentRunPanel(task: task)
                    }
                }
                .background(Theme.background)
            } else {
                ContentUnavailableView("Task deleted", systemImage: "trash")
            }
        }
        .onAppear(perform: observe)
    }

    private func observe() {
        let id = taskId
        observed.observe(store.db) { try TaskItem.fetchOne($0, key: id) }
        taskLabels.observe(store.db) { try String.fetchAll($0, sql: "SELECT labelId FROM taskLabel WHERE taskId = ?", arguments: [id]) }
        subtasks.observe(store.db) {
            try TaskItem.filter(Column("parentId") == id).order(Column("isCompleted"), Column("childOrder"), Column("createdAt")).fetchAll($0)
        }
        comments.observe(store.db) { try Comment.filter(Column("taskId") == id).order(Column("createdAt")).fetchAll($0) }
        decor.observe(store.db) { try TaskDecor.fetch($0) }
        if let t = store.read({ try TaskItem.fetchOne($0, key: id) }) ?? nil {
            content = t.content
            details = t.description
            dueInput = t.dueString ?? ""
            if t.agentId != nil, runs.live[t.id] != nil { tab = 1 }
        }
    }

    private func update(_ change: (inout TaskItem) -> Void) {
        guard var t = observed.value else { return }
        change(&t)
        store.write { try t.update($0) }
    }

    // MARK: Header

    private func topBar(_ task: TaskItem) -> some View {
        HStack(spacing: 6) {
            if let p = store.project(task.projectId) {
                Image(systemName: "number").foregroundStyle(Theme.color(p.color))
                Text(p.name)
                if let s = store.sections(of: p.id).first(where: { $0.id == task.sectionId }) {
                    Text("/").foregroundStyle(Theme.tertiary)
                    Text(s.name)
                }
            }
            if let parent = task.parentId, let parentTask = store.read({ try TaskItem.fetchOne($0, key: parent) }) ?? nil {
                Text("/").foregroundStyle(Theme.tertiary)
                Button(parentTask.content) { store.selectedTaskId = parent }
                    .buttonStyle(.plain).lineLimit(1)
            }
            Spacer()
            IconButton(icon: "trash", help: "Delete task") {
                store.selectedTaskId = nil
                store.write { _ = try task.delete($0) }
            }
            IconButton(icon: "xmark", help: "Close") { store.selectedTaskId = nil }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func header(_ task: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PriorityCheckbox(task: task, size: 20)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Task name", text: $content, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .onChange(of: content) { _, v in if !v.isEmpty { update { $0.content = v } } }
                TextField("Description", text: $details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1...10)
                    .onChange(of: details) { _, v in update { $0.description = v } }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: Details tab

    @ViewBuilder private func details(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                PropertyRow(icon: "number", title: "Project") {
                    Menu {
                        ForEach(store.projectTree, id: \.project.id) { item in
                            Button(String(repeating: "   ", count: item.depth) + item.project.name) {
                                update { $0.projectId = item.project.id; $0.sectionId = nil; $0.parentId = nil }
                            }
                        }
                    } label: {
                        ValueLabel(text: store.project(task.projectId)?.name ?? "—",
                                   color: Theme.color(store.project(task.projectId)?.color ?? "gray"))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                let sections = store.sections(of: task.projectId)
                if !sections.isEmpty {
                    PropertyRow(icon: "rectangle.split.3x1", title: "Section") {
                        Menu {
                            Button("No section") { update { $0.sectionId = nil } }
                            ForEach(sections) { s in Button(s.name) { update { $0.sectionId = s.id } } }
                        } label: {
                            ValueLabel(text: sections.first { $0.id == task.sectionId }?.name ?? "No section")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                PropertyRow(icon: "calendar", title: "Date") {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            TextField("", text: $dueInput, prompt: Text("e.g. tomorrow 9am, every weekday"))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .font(.system(size: 13))
                                .onSubmit { applyDue() }
                            if task.dueDate != nil {
                                Button { dueInput = ""; applyDue() } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if let dueError {
                            Text(dueError).font(.system(size: 11)).foregroundStyle(Theme.red)
                        } else if let text = task.dueText {
                            Pill(text: text + (task.isRecurring ? " · repeats" : ""),
                                 icon: task.isRecurring ? "arrow.triangle.2.circlepath" : "calendar", color: task.dueColor)
                        }
                    }
                }
                PropertyRow(icon: "scope", title: "Deadline") {
                    HStack(spacing: 6) {
                        if let deadline = task.deadline {
                            DatePicker("", selection: Binding(
                                get: { LocalDate.parse(deadline) ?? Date() },
                                set: { d in update { $0.deadline = LocalDate.day(d) } }), displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.field)
                            Button { update { $0.deadline = nil } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button("Add deadline") { update { $0.deadline = LocalDate.day(Date()) } }
                                .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                PropertyRow(icon: "flag", title: "Priority") {
                    Menu {
                        ForEach(1...4, id: \.self) { p in
                            Button { update { $0.priority = p } } label: {
                                SwiftUI.Label("Priority \(p)", systemImage: p < 4 ? "flag.fill" : "flag")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: task.priority < 4 ? "flag.fill" : "flag").foregroundStyle(Theme.priority(task.priority))
                            Text("P\(task.priority)").foregroundStyle(Theme.text)
                        }
                        .font(.system(size: 13))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                PropertyRow(icon: "tag", title: "Labels") { labelsValue }
                PropertyRow(icon: "person.crop.circle", title: "Agent") {
                    Menu {
                        Button("Unassigned") { update { $0.agentId = nil } }
                        ForEach(store.agents) { a in Button(a.name) { update { $0.agentId = a.id } } }
                    } label: {
                        ValueLabel(text: store.agent(task.agentId)?.name ?? "Unassigned",
                                   muted: task.agentId == nil)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebar))

            AttachmentsSection(taskId: task.id)
            subtasksSection(task)
            commentsSection(task)

            HStack {
                if let source = task.source {
                    Text("Imported from \(source)" + (task.externalId.map { " · \($0)" } ?? ""))
                }
                Spacer()
                Text("Created \(task.createdAt)")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
        }
    }

    private var labelsValue: some View {
        let selected = Set(taskLabels.value)
        return HStack(spacing: 6) {
            ForEach(store.labels.filter { selected.contains($0.id) }) { label in
                Text(label.name)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.color(label.color).opacity(0.15)))
                    .foregroundStyle(Theme.color(label.color))
            }
            Menu {
                ForEach(store.labels) { label in
                    Toggle(label.name, isOn: Binding(get: { selected.contains(label.id) }, set: { on in
                        store.write { db in
                            let link = TaskLabel(taskId: taskId, labelId: label.id)
                            if on { try link.save(db) } else { _ = try link.delete(db) }
                        }
                    }))
                }
                Divider()
                Button("New label…") { promptNewLabel() }
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func subtasksSection(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let done = subtasks.value.filter(\.isCompleted).count
            SectionHeader(title: "Sub-tasks", count: subtasks.value.isEmpty ? nil : done)
                .overlay(alignment: .topTrailing) {
                    if !subtasks.value.isEmpty {
                        Text("\(done)/\(subtasks.value.count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.top, 16)
                    }
                }
            ForEach(subtasks.value) { sub in
                TaskRow(task: sub, decor: decor.value)
            }
            AddTaskButton(make: { content in
                var t = TaskItem(projectId: task.projectId, content: content)
                t.parentId = task.id
                t.sectionId = task.sectionId
                return t
            }, compact: true)
        }
    }

    private func commentsSection(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Comments", count: comments.value.isEmpty ? nil : comments.value.count)
            ForEach(comments.value) { c in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: c.author == "user" ? "You" : c.author)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.author == "user" ? "You" : c.author).font(.system(size: 12, weight: .semibold))
                            Text(c.createdAt).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                        MarkdownText(text: c.content)
                    }
                }
                .contextMenu { Button("Delete comment", role: .destructive) { store.write { _ = try c.delete($0) } } }
            }
            HStack(alignment: .bottom) {
                TextField("Comment", text: $newComment, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .onSubmit { addComment(task) }
                Button { addComment(task) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundStyle(newComment.isEmpty ? Theme.tertiary : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(newComment.isEmpty)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }

    private func addComment(_ task: TaskItem) {
        let c = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        store.write { try Comment(taskId: task.id, content: c).insert($0) }
        newComment = ""
    }

    private func promptNewLabel() {
        let alert = NSAlert()
        alert.messageText = "New label"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "label_name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard !name.isEmpty else { return }
        store.write { db in
            let label = try AgentDeskCore.Label.filter(Column("name") == name).fetchOne(db) ?? {
                let l = AgentDeskCore.Label(name: name)
                try l.insert(db)
                return l
            }()
            try TaskLabel(taskId: taskId, labelId: label.id).save(db)
        }
    }

    private func applyDue() {
        let s = dueInput.trimmingCharacters(in: .whitespaces)
        dueError = nil
        if s.isEmpty {
            update { $0.dueDate = nil; $0.dueTime = nil; $0.dueString = nil; $0.isRecurring = false }
            return
        }
        do {
            let due = try DueParser.parse(s, context: FilterContext(now: Date()))
            update {
                $0.dueDate = due.date
                $0.dueTime = due.time
                $0.dueString = due.string
                $0.isRecurring = due.isRecurring
            }
        } catch {
            dueError = "\(error)"
        }
    }
}

/// One property line in the task panel: icon + title on the left, value on the right.
struct PropertyRow<Value: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.tertiary).frame(width: 16)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 12)
            value
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 38) }
    }
}

private struct ValueLabel: View {
    let text: String
    var color: Color?
    var muted = false

    var body: some View {
        HStack(spacing: 4) {
            if let color { Image(systemName: "number").foregroundStyle(color) }
            Text(text).foregroundStyle(muted ? Theme.tertiary : Theme.text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(Theme.tertiary)
        }
        .font(.system(size: 13))
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 24

    var body: some View {
        let initial = String(name.prefix(1)).uppercased()
        let palette: [Color] = [Theme.accent, Theme.blue, Theme.purple, Theme.green, Theme.orange]
        let color = palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
        Text(initial)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
    }
}


/// Host files and folders linked to the task by path. Nothing is copied.
private struct AttachmentsSection: View {
    @EnvironmentObject var store: AppStore
    let taskId: ID
    @StateObject private var items = Observed<[TaskAttachment]>([])
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Attachments", count: items.value.isEmpty ? nil : items.value.count)
                .overlay(alignment: .topTrailing) {
                    LinkButton(title: "Attach", icon: "paperclip") { choose() }.padding(.top, 14)
                }
            VStack(spacing: 0) {
                ForEach(Array(items.value.enumerated()), id: \.element.id) { i, a in
                    row(a, last: i == items.value.count - 1)
                }
                if items.value.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc")
                        Text("Drop files or folders here — they are linked, not copied")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Theme.accentSoft : Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Theme.accent : Theme.divider, style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: targeted ? [5] : [])))
            .dropDestination(for: URL.self) { urls, _ in
                store.attach(urls, to: taskId)
                return true
            } isTargeted: { targeted = $0 }
        }
        .onAppear {
            let id = taskId
            items.observe(store.db) { try TaskAttachment.filter(Column("taskId") == id).order(Column("createdAt")).fetchAll($0) }
        }
    }

    private func row(_ a: TaskAttachment, last: Bool) -> some View {
        let exists = a.exists
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: exists ? a.path : "/"))
                .resizable().frame(width: 22, height: 22)
                .opacity(exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).font(.system(size: 13)).foregroundStyle(exists ? Theme.text : Theme.tertiary)
                Text(exists ? a.path : "Missing: \(a.path)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(exists ? Theme.tertiary : Theme.red)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button {
                var x = a
                x.writable.toggle()
                store.write { try x.update($0) }
            } label: {
                Text(a.writable ? "Read & write" : "Read-only")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(a.writable ? Theme.accent : Theme.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(a.writable ? Theme.accentSoft : Theme.hover))
            }
            .buttonStyle(.plain)
            .help("Whether the agent may change it")
            IconButton(icon: "magnifyingglass", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)])
            }
            IconButton(icon: "xmark", help: "Remove attachment (the file stays on disk)") {
                store.write { _ = try a.delete($0) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if exists { NSWorkspace.shared.open(URL(fileURLWithPath: a.path)) } }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 42) } }
    }

    private func choose() {
        let panel = Finder.openPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Attach files or folders (linked by path, not copied)"
        guard panel.runModal() == .OK else { return }
        store.attach(panel.urls, to: taskId)
    }
}
