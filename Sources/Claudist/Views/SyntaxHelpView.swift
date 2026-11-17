import ClaudistCore
import AppKit
import SwiftUI

enum SyntaxHelpTab: Int, Identifiable {
    case filters, dueDates
    var id: Int { rawValue }
}

/// Reference for the filter language and due dates. Examples match what the parsers accept.
struct SyntaxHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State var tab: SyntaxHelpTab
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Syntax help").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            UnderlineTabs(titles: ["Filters", "Due dates"], selection: Binding(get: { tab.rawValue }, set: { tab = SyntaxHelpTab(rawValue: $0) ?? .filters }))
                .padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(tab == .filters
                         ? "Filters select tasks with Todoist's filter language (English). Completed tasks and archived projects are left out unless a query mentions `completed`."
                         : "Type a due date in plain English on a task. Recurring dates repeat when the task is completed. A task with an agent runs by itself when it comes due: a recurring one every time, a one-off one once.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(tab == .filters ? Self.filters : Self.dueDates, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(section.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text).padding(.bottom, 6)
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { i, row in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Button { copy(row.0) } label: {
                                        Text(row.0)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(copied == row.0 ? Theme.green : Theme.accent)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy")
                                    .frame(width: 250, alignment: .leading)
                                    Text(row.1).font(.system(size: 12)).foregroundStyle(Theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, 10)
                                .background(i % 2 == 0 ? Theme.sidebar : Color.clear)
                            }
                        }
                    }
                    Text("Click an example to copy it.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                .padding(20)
            }
        }
        .frame(width: 720, height: 640)
        .background(Theme.background)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = text
    }

    struct Section {
        let title: String
        let rows: [(String, String)]
    }

    static let filters: [Section] = [
        Section(title: "Combining", rows: [
            ("today & p1", "& — both conditions"),
            ("today | overdue", "| — either condition"),
            ("!subtask", "! — not"),
            ("(today | overdue) & #Work", "( ) — grouping"),
            ("today, tomorrow, no date", "Comma — separate groups (board columns / list sections)"),
        ]),
        Section(title: "Dates", rows: [
            ("today · tomorrow · yesterday", "Due on that day"),
            ("overdue  or  od", "Due before now"),
            ("7 days  or  next 7 days", "Due within the next 7 days (including today)"),
            ("-3 days", "Due in the last 3 days"),
            ("no date · no time", "Without a due date / without a due time"),
            ("date: next week", "Due within next week (also: this week, next month)"),
            ("date before: sat", "Due before Saturday (also: date after: Nov 5)"),
            ("date before: +4 hours", "Due within the next 4 hours"),
            ("date: today at 18:00", "Due today at that time"),
            ("Nov 5 · 11/5 · 2026-11-05", "Due on that date"),
            ("deadline: today · no deadline", "By deadline (also deadline before:/after:)"),
            ("created: -7 days", "Created in the last 7 days (also created before:/after:)"),
            ("recurring", "Recurring tasks"),
            ("flagged", "Tasks you flagged"),
        ]),
        Section(title: "Projects, sections, labels", rows: [
            ("#Work", "Tasks in the project Work"),
            ("##Work", "Work and its subprojects"),
            ("/Doing", "Tasks in sections named Doing (any project)"),
            ("#Work & /Doing", "One section of one project"),
            ("@urgent  ·  no labels", "With the label / without any label"),
            ("#Client*  ·  @home*", "* matches any text in names"),
            ("#My\\ Project", "\\ escapes special characters"),
        ]),
        Section(title: "Priority and content", rows: [
            ("p1 · p2 · p3 · p4", "Priority (p4 = no priority)"),
            ("search: invoice", "Title or description contains the text"),
            ("subtask", "Only subtasks"),
        ]),
        Section(title: "Agents (Claudist)", rows: [
            ("agent: Researcher", "Assigned to that agent (also: assigned to: Researcher)"),
            ("assigned", "Has an agent"),
            ("run: running", "Latest run status: queued, running, waiting, done, failed, cancelled"),
            ("run: none", "Never run"),
            ("run after: -1 day", "Ran in the last day (also run before:)"),
            ("needs you", "An agent waits for your answer or approval"),
        ]),
        Section(title: "Completed", rows: [
            ("completed", "Completed tasks"),
            ("completed after: -7 days", "Completed in the last 7 days"),
            ("completed & #Work", "Completed tasks of a project"),
            ("view all", "Every open task"),
        ]),
    ]

    static let dueDates: [Section] = [
        Section(title: "One-off", rows: [
            ("today · tod · tomorrow · tom", "That day"),
            ("monday · next monday · fri", "The next such weekday"),
            ("tomorrow 9am · fri 7pm · today at 17:30", "With a time"),
            ("at 5pm  or  17:30", "Today at that time (tomorrow if it has passed)"),
            ("Jan 3 · 3 Jan 2027 · 2026-11-05 · 1/3/2027", "A date"),
            ("27th", "The next 27th of a month"),
            ("in 3 days · +2 weeks · in 1 month", "Relative"),
            ("next week", "Next Monday"),
            ("next month", "The same day next month"),
            ("this weekend", "This Saturday"),
            ("end of month · mid january", "Named points"),
            ("tomorrow morning · today evening", "morning 9:00, afternoon 12:00, evening 19:00, night 22:00, noon, midnight"),
        ]),
        Section(title: "Recurring", rows: [
            ("every day  or  daily", "Every day"),
            ("every weekday  or  every workday", "Monday to Friday"),
            ("every weekend", "Saturday and Sunday"),
            ("every monday · every mon, fri", "On these weekdays"),
            ("every wed and fri", "Same: lists take commas or \"and\""),
            ("every mon, fri at 9am", "With a time"),
            ("every wed and fri at 18:00", "Several weekdays with a time"),
            ("every week · weekly", "Every week from the start date"),
            ("every 2 weeks · every other day", "Intervals"),
            ("every other fri", "Every second Friday"),
            ("every month · every 15th", "Monthly; on a day of the month"),
            ("every 2, 15, 27", "Several days of the month"),
            ("every 1st and 15th", "Same, with \"and\""),
            ("every last day", "Last day of each month"),
            ("every quarter · every year · every jan 3", "Longer periods"),
            ("every hour · every 3 hours", "Hourly"),
            ("every monday starting jan 5", "Starts later (also: from <date>)"),
        ]),
        Section(title: "Repeat after completion", rows: [
            ("every! 3 days", "Next date counts from when you complete the task"),
            ("after 2 weeks", "Same: two weeks after completion"),
        ]),
        Section(title: "Clearing", rows: [
            ("(empty)", "Clear the field to remove the due date"),
        ]),
    ]
}
