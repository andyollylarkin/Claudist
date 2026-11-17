import ClaudistCore
import Combine
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Live result of a database query, re-fetched whenever the tables it reads change.
@MainActor
final class Observed<T: Equatable>: ObservableObject {
    @Published private(set) var value: T
    @Published private(set) var error: String?
    private var cancellable: AnyDatabaseCancellable?

    init(_ initial: T) { value = initial }

    func observe(_ db: AppDatabase, _ fetch: @escaping @Sendable (Database) throws -> T) {
        cancellable = ValueObservation.tracking(fetch).removeDuplicates()
            .start(in: db.writer, scheduling: .immediate,
                   onError: { [weak self] in self?.error = "\($0)" },
                   onChange: { [weak self] in self?.value = $0; self?.error = nil })
    }
}

/// Per-task extras shown on rows and cards.
struct TaskDecor: Equatable {
    var labels: [ID: [String]] = [:]
    var runStatus: [ID: RunStatus] = [:]
    /// When the latest run ended (local stamp), for "Done at 14:05" on recurring tasks.
    var runEnded: [ID: String] = [:]
    var subtasks: [ID: (done: Int, total: Int)] = [:]
    var comments: [ID: Int] = [:]
    var attachments: [ID: Int] = [:]

    static func == (a: TaskDecor, b: TaskDecor) -> Bool {
        a.labels == b.labels && a.runStatus == b.runStatus && a.runEnded == b.runEnded && a.comments == b.comments && a.attachments == b.attachments
            && a.subtasks.mapValues { [$0.done, $0.total] } == b.subtasks.mapValues { [$0.done, $0.total] }
    }

    static func fetch(_ db: Database) throws -> TaskDecor {
        var d = TaskDecor()
        for row in try Row.fetchAll(db, sql: """
            SELECT tl.taskId, l.name FROM taskLabel tl JOIN label l ON l.id = tl.labelId ORDER BY l.name
            """) {
            d.labels[row[0], default: []].append(row[1])
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT taskId, status, endedAt FROM run r
            WHERE rowid = (SELECT rowid FROM run WHERE taskId = r.taskId ORDER BY startedAt DESC, rowid DESC LIMIT 1)
            """) {
            if let s = RunStatus(rawValue: row[1]) { d.runStatus[row[0]] = s }
            if let ended: String = row[2] { d.runEnded[row[0]] = ended }
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT parentId, SUM(isCompleted), COUNT(*) FROM task WHERE parentId IS NOT NULL GROUP BY parentId
            """) {
            d.subtasks[row[0]] = (row[1], row[2])
        }
        for row in try Row.fetchAll(db, sql: "SELECT taskId, COUNT(*) FROM comment GROUP BY taskId") {
            d.comments[row[0]] = row[1]
        }
        for row in try Row.fetchAll(db, sql: "SELECT taskId, COUNT(*) FROM taskAttachment GROUP BY taskId") {
            d.attachments[row[0]] = row[1]
        }
        return d
    }
}

extension TaskItem {
    /// "Today 09:00", "Tomorrow", "Friday", "3 Nov".
    var dueText: String? {
        guard let dueDate, let date = LocalDate.parse(dueDate) else { return nil }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: date).day ?? 0
        var s: String
        switch days {
        case 0: s = "Today"
        case 1: s = "Tomorrow"
        case -1: s = "Yesterday"
        case 2...6:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "EEEE"
            s = f.string(from: date)
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
            s = f.string(from: date)
        }
        if let dueTime { s += " \(dueTime)" }
        return s
    }

    var isOverdue: Bool {
        guard let at = dueAt else { return false }
        return dueTime == nil ? at < Calendar.current.startOfDay(for: Date()) : at < Date()
    }

    /// Date colors: overdue red, today green, tomorrow orange, this week purple, later gray.
    var dueColor: Color {
        guard let dueDate, let date = LocalDate.parse(dueDate) else { return Theme.tertiary }
        if isOverdue { return Theme.red }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: date).day ?? 0
        switch days {
        case 0: return Theme.green
        case 1: return Theme.orange
        case 2...6: return Theme.purple
        default: return Theme.secondary
        }
    }
}

extension RunStatus {
    var title: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .waiting: "Needs approval"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }

    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "circle.dotted"
        case .waiting: "hand.raised.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle"
        }
    }

    var color: Color {
        switch self {
        case .queued, .cancelled: Theme.tertiary
        case .running: Theme.blue
        case .waiting: .orange
        case .done: Theme.green
        case .failed: Theme.red
        }
    }
}

/// Round checkbox tinted by priority; shows a check on hover.
struct PriorityCheckbox: View {
    @EnvironmentObject var store: AppStore
    let task: TaskItem
    var size: CGFloat = 18
    @State private var hovering = false

    var body: some View {
        let color = Theme.priority(task.priority)
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(task.isCompleted ? color : color.opacity(task.priority < 4 ? 0.12 : 0))
                Circle()
                    .strokeBorder(color, lineWidth: task.priority < 4 ? 1.8 : 1.2)
                if task.isCompleted || hovering {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(task.isCompleted ? .white : color)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(task.isRecurring ? "Complete this occurrence" : task.isCompleted ? "Mark as open" : "Complete task")
    }

    /// Completing a recurring task moves it to the next occurrence.
    private func toggle() {
        var t = task
        if !t.isCompleted, t.isRecurring, let s = t.dueString {
            let ctx = FilterContext(now: Date())
            do {
                var due = try DueParser.parse(s, context: ctx)
                if let d = t.dueDate { due.date = d; due.time = t.dueTime }
                let next = try DueParser.next(due, after: Date(), context: ctx)
                t.dueDate = next.date
                t.dueTime = next.time
            } catch {
                store.report(error)
                return
            }
        } else {
            t.isCompleted.toggle()
            t.completedAt = t.isCompleted ? LocalDate.stamp(Date()) : nil
        }
        withAnimation(.easeOut(duration: 0.2)) { store.write { try t.update($0) } }
    }
}

/// Metadata line under the task title.
struct TaskMeta: View {
    @EnvironmentObject var store: AppStore
    let task: TaskItem
    let decor: TaskDecor

    var body: some View {
        // Wraps instead of truncating: dates and run times must stay readable in narrow rows and cards.
        FlowLayout(spacing: 10) {
            if let n = decor.subtasks[task.id] {
                Pill(text: "\(n.done)/\(n.total)", icon: "arrow.turn.down.right")
            }
            if let n = decor.comments[task.id] {
                Pill(text: "\(n)", icon: "bubble.left")
            }
            if let n = decor.attachments[task.id] {
                Pill(text: "\(n)", icon: "paperclip")
            }
            if let due = task.dueText {
                Pill(text: due, icon: task.isRecurring ? "arrow.triangle.2.circlepath" : "calendar", color: task.dueColor)
            }
            if let deadline = task.deadline {
                Pill(text: deadline, icon: "scope", color: Theme.secondary)
            }
            ForEach(decor.labels[task.id] ?? [], id: \.self) { label in
                Pill(text: label, icon: "tag", color: Theme.secondary)
            }
            if let agent = store.agent(task.agentId) {
                Pill(text: agent.name, icon: "person.crop.circle", color: Theme.secondary)
            }
            if task.attention != nil {
                Pill(text: "Needs you", icon: "hand.raised.fill", color: .orange)
            } else if let status = decor.runStatus[task.id] {
                Pill(text: Self.statusText(status, ended: task.isRecurring ? decor.runEnded[task.id] : nil),
                     icon: status.symbol, color: status.color)
            }
        }
    }

    /// A recurring task runs again and again: its last result needs a time ("Done at 14:05").
    static func statusText(_ status: RunStatus, ended: String?) -> String {
        guard let ended, [.done, .failed, .cancelled].contains(status), let date = LocalDate.parse(ended) else { return status.title }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d MMM HH:mm"
        return "\(status.title) \(f.string(from: date))"
    }

    static func isEmpty(_ task: TaskItem, _ decor: TaskDecor) -> Bool {
        task.attention == nil && task.dueDate == nil && task.deadline == nil && task.agentId == nil && decor.subtasks[task.id] == nil
            && decor.comments[task.id] == nil && decor.attachments[task.id] == nil && (decor.labels[task.id] ?? []).isEmpty && decor.runStatus[task.id] == nil
    }
}

/// List row: checkbox, title, description, metadata; project on the right in filters.
struct TaskRow: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    let task: TaskItem
    let decor: TaskDecor
    var depth = 0
    var showProject = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PriorityCheckbox(task: task)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if task.isLocked {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.tertiary).help("Locked task")
                    }
                    Text(task.content)
                        .font(.system(size: 14))
                        .foregroundStyle(task.isCompleted ? Theme.tertiary : Theme.text)
                        .strikethrough(task.isCompleted, color: Theme.tertiary)
                }
                // Locked tasks never preview their text in lists, open or not.
                if !task.description.isEmpty, !task.isLocked {
                    MarkdownPreview(text: task.description, lines: 2)
                }
                if !TaskMeta.isEmpty(task, decor) {
                    TaskMeta(task: task, decor: decor)
                }
            }
            Spacer(minLength: 8)
            if task.isFlagged || hovering {
                FlagButton(task: task)
            }
            if hovering, task.agentId != nil {
                IconButton(icon: runs.live[task.id] == nil ? "play.fill" : "stop.fill",
                           help: runs.live[task.id] == nil ? "Run agent" : "Stop agent") {
                    if runs.live[task.id] == nil { runs.start(task) } else { runs.stop(taskId: task.id) }
                }
            }
            if showProject, let p = store.project(task.projectId) {
                HStack(spacing: 3) {
                    Text(p.name).lineLimit(1)
                    Image(systemName: "number").foregroundStyle(Theme.color(p.color))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 28)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(store.selectedTaskId == task.id ? Theme.accentSoft.opacity(0.6) : hovering ? Theme.hover.opacity(0.6) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, CGFloat(depth) * 28 + 34) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.selectedTaskId = task.id }
        .draggable(task.id) { DragPreview(title: task.content) }
        .dropDestination(for: URL.self) { urls, _ in
            store.attach(urls, to: task.id)
            return true
        }
        .contextMenu { TaskContextMenu(task: task) }
    }
}

struct TaskCard: View {
    @EnvironmentObject var store: AppStore
    let task: TaskItem
    let decor: TaskDecor
    var showProject = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                PriorityCheckbox(task: task, size: 16)
                    .padding(.top, 1)
                if task.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary).padding(.top, 3)
                }
                Text(task.content)
                    .font(.system(size: 13))
                    .foregroundStyle(task.isCompleted ? Theme.tertiary : Theme.text)
                    .strikethrough(task.isCompleted, color: Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if task.isFlagged || hovering {
                    FlagButton(task: task, size: 11)
                }
            }
            if !task.description.isEmpty, !task.isLocked {
                MarkdownPreview(text: task.description, lines: 3)
                    .padding(.leading, 24)
            }
            if !TaskMeta.isEmpty(task, decor) {
                TaskMeta(task: task, decor: decor)
                    .padding(.leading, 24)
            }
            if showProject, let p = store.project(task.projectId) {
                HStack(spacing: 3) {
                    Spacer()
                    Text(p.name)
                    Image(systemName: "number").foregroundStyle(Theme.color(p.color))
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(store.selectedTaskId == task.id ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 6 : 2, y: 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.selectedTaskId = task.id }
        .draggable(task.id) { DragPreview(title: task.content) }
        .dropDestination(for: URL.self) { urls, _ in
            store.attach(urls, to: task.id)
            return true
        }
        .contextMenu { TaskContextMenu(task: task) }
    }
}

/// Flag toggle: filled orange when flagged, an outline to flag otherwise.
struct FlagButton: View {
    @EnvironmentObject var store: AppStore
    let task: TaskItem
    var size: CGFloat = 12

    var body: some View {
        Button { Self.toggle(task, store: store) } label: {
            Image(systemName: task.isFlagged ? "flag.fill" : "flag")
                .font(.system(size: size))
                .foregroundStyle(task.isFlagged ? Color.orange : Theme.tertiary)
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.isFlagged ? "Remove flag" : "Flag")
    }

    /// Changes only the flag, so a stale copy of the task can't overwrite other edits.
    static func toggle(_ task: TaskItem, store: AppStore) {
        let flagged = !task.isFlagged
        store.write { db in
            _ = try TaskItem.filter(key: task.id).updateAll(db, Column("isFlagged").set(to: flagged))
        }
    }
}

struct DragPreview: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 13))
            .padding(10)
            .frame(width: 240, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 1))
    }
}

struct TaskContextMenu: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    let task: TaskItem

    var body: some View {
        if task.agentId != nil {
            if runs.live[task.id] == nil {
                Button("Run agent") { runs.start(task) }
            } else {
                Button("Stop agent") { runs.stop(taskId: task.id) }
            }
            Divider()
        }
        Button("Open task") { store.selectedTaskId = task.id }
        Button("Open Full Screen") { store.selectedTaskId = task.id; store.taskExpanded = true }
        Button(task.isFlagged ? "Remove Flag" : "Flag") { FlagButton.toggle(task, store: store) }
        if task.isLocked {
            Button("Remove Lock…") { store.removeLock(task) }
        } else {
            Button("Lock with Password…") { store.lockTask(task) }
        }
        Menu("Priority") {
            ForEach(1...4, id: \.self) { p in
                Button("Priority \(p)") { var t = task; t.priority = p; store.write { try t.update($0) } }
            }
        }
        Menu("Assign agent") {
            Button("Unassigned") { var t = task; t.agentId = nil; store.write { try t.update($0) } }
            ForEach(store.agents) { agent in
                Button(agent.name) { var t = task; t.agentId = agent.id; store.write { try t.update($0) } }
            }
        }
        Menu("Due date") {
            Button("Today") { setDue(0) }
            Button("Tomorrow") { setDue(1) }
            Button("Next week") { setDue(7) }
            Button("No date") { var t = task; t.dueDate = nil; t.dueTime = nil; t.dueString = nil; t.isRecurring = false; store.write { try t.update($0) } }
        }
        Divider()
        Button("Delete task", role: .destructive) {
            if store.selectedTaskId == task.id { store.selectedTaskId = nil }
            store.write { _ = try task.delete($0) }
        }
    }

    private func setDue(_ days: Int) {
        var t = task
        t.dueDate = LocalDate.day(Calendar.current.date(byAdding: .day, value: days, to: Date())!)
        if !t.isRecurring { t.dueString = nil }
        store.write { try t.update($0) }
    }
}

/// "+ Add task" that expands into an inline composer with name and description.
struct AddTaskButton: View {
    @EnvironmentObject var store: AppStore
    let make: (String) -> TaskItem?
    var compact = false
    @State private var open = false
    @State private var hovering = false
    @State private var title = ""
    @State private var details = ""
    @FocusState private var focused: Bool

    var body: some View {
        if open {
            composer
        } else {
            Button { open = true; focused = true } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(hovering ? Theme.accent : .clear).frame(width: 18, height: 18)
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(hovering ? .white : Theme.accent)
                    }
                    Text("Add task").font(.system(size: 13)).foregroundStyle(hovering ? Theme.accent : Theme.tertiary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .onReceive(NotificationCenter.default.publisher(for: .newTask)) { _ in
                if !compact { open = true; focused = true }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Task name", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focused)
                    .onSubmit(add)
                // TextEditor: Return inserts a line break (a TextField would submit).
                ZStack(alignment: .topLeading) {
                    if details.isEmpty {
                        Text("Description (Markdown)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $details)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 22, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button("Add task", action: add)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .padding(.vertical, 6)
    }

    private func close() {
        open = false
        title = ""
        details = ""
    }

    private func add() {
        let content = title.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, var task = make(content) else { return }
        task.description = details.trimmingCharacters(in: .whitespacesAndNewlines)
        store.write { db in
            task.childOrder = (try Int.fetchOne(db, sql: "SELECT MAX(childOrder) FROM task WHERE projectId = ?",
                                                arguments: [task.projectId]) ?? 0) + 1
            try task.insert(db)
        }
        title = ""
        details = ""
        focused = true
    }
}
