import ClaudistCore
import GRDB
import SwiftUI

/// Calendar layout of a project or filter: a month grid of tasks by due date. Drag a task onto
/// another day to reschedule it; the selected day's tasks are listed below the grid.
struct TaskCalendar: View {
    @EnvironmentObject var store: AppStore
    let tasks: [TaskItem]
    let decor: TaskDecor
    var showProject = false
    /// A new task for the given title and day, or nil when the view can't add tasks.
    var newTask: ((String, String) -> TaskItem?)?
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var selectedDay = LocalDate.day(Date())
    @State private var dropTarget: String?

    private var calendar: Calendar { Calendar.current }

    /// 6 weeks starting on the week's first day, covering the month.
    private var days: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: month)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    private var byDay: [String: [TaskItem]] {
        Dictionary(grouping: tasks.filter { $0.dueDate != nil }, by: { $0.dueDate! })
            .mapValues { $0.sorted { ($0.isCompleted ? 1 : 0, $0.dueTime ?? "99", $0.priority) < ($1.isCompleted ? 1 : 0, $1.dueTime ?? "99", $1.priority) } }
    }

    var body: some View {
        let grouped = byDay
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(undated: tasks.filter { $0.dueDate == nil && !$0.isCompleted }.count)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            Text(calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + i) % 7].uppercased())
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                    }
                    let weeks = stride(from: 0, to: 42, by: 7).map { Array(days[$0..<$0 + 7]) }
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            ForEach(week, id: \.self) { date in
                                dayCell(date, tasks: grouped[LocalDate.day(date)] ?? [])
                            }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))

                dayList(grouped[selectedDay] ?? [])
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 12)
        }
    }

    private func header(undated: Int) -> some View {
        HStack(spacing: 10) {
            Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
            if undated > 0 {
                Text("\(undated) without a date").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            IconButton(icon: "chevron.left", help: "Previous month") { shift(-1) }
            Button("Today") {
                month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
                selectedDay = LocalDate.day(Date())
            }
            .buttonStyle(AccentButtonStyle(prominent: false))
            IconButton(icon: "chevron.right", help: "Next month") { shift(1) }
        }
    }

    private func dayCell(_ date: Date, tasks: [TaskItem]) -> some View {
        let day = LocalDate.day(date)
        let inMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(date)
        let selected = day == selectedDay
        let shown = 4
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 12, weight: isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? .white : inMonth ? Theme.text : Theme.tertiary)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(isToday ? Theme.accent : .clear))
                Spacer()
            }
            ForEach(tasks.prefix(shown)) { task in
                CalendarChip(task: task, status: decor.runStatus[task.id])
            }
            if tasks.count > shown {
                Text("+\(tasks.count - shown) more").font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
        .background(dropTarget == day ? Theme.accentSoft : selected ? Theme.hover : inMonth ? Color.clear : Theme.background.opacity(0.5))
        .overlay(Rectangle().strokeBorder(Theme.divider, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { selectedDay = day }
        .dropDestination(for: String.self) { ids, _ in
            reschedule(ids, to: day)
            return true
        } isTargeted: { on in
            if on { dropTarget = day } else if dropTarget == day { dropTarget = nil }
        }
    }

    private func dayList(_ items: [TaskItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let date = LocalDate.parse(selectedDay) ?? Date()
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            ForEach(items) { task in
                TaskRow(task: task, decor: decor, showProject: showProject)
            }
            if let newTask {
                let day = selectedDay
                AddTaskButton(make: { newTask($0, day) })
            }
        }
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month)!
    }

    /// Moves tasks to another day, keeping their time.
    private func reschedule(_ ids: [String], to day: String) {
        store.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE task SET dueDate = ? WHERE id = ? AND dueDate IS NOT ?", arguments: [day, id, day])
            }
        }
        selectedDay = day
    }
}

/// A task in a day cell: priority bar, time, title; draggable to another day.
private struct CalendarChip: View {
    @EnvironmentObject var store: AppStore
    let task: TaskItem
    let status: RunStatus?

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.priority(task.priority)).frame(width: 3)
            if let time = task.dueTime {
                Text(time).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            Text(task.content).font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(task.isCompleted ? Theme.tertiary : Theme.text)
                .strikethrough(task.isCompleted, color: Theme.tertiary)
            Spacer(minLength: 0)
            if task.isRecurring { Image(systemName: "repeat").font(.system(size: 8)).foregroundStyle(Theme.tertiary) }
            if task.agentId != nil {
                Circle().fill(color).frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(store.selectedTaskId == task.id ? Theme.accentSoft : Theme.background))
        .contentShape(Rectangle())
        .onTapGesture { store.selectedTaskId = task.id }
        .draggable(task.id) { DragPreview(title: task.content) }
        .help(task.content)
    }

    private var color: Color {
        switch status {
        case .running?, .queued?: return Theme.accent
        case .waiting?: return .orange
        case .failed?: return Theme.red
        case .done?: return Theme.green
        default: return Theme.tertiary
        }
    }
}
