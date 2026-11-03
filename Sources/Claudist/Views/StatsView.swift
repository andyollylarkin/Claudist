import Charts
import ClaudistCore
import GRDB
import SwiftUI

/// One day of agent work: how many runs, how they ended, by hour, by agent and by task.
struct StatsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var stats = Observed(RunStats(day: ""))
    @State private var date = Date()

    private var day: String { LocalDate.day(date) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                tiles
                if stats.value.total.runs == 0 {
                    ContentUnavailableView("No runs on this day", systemImage: "chart.bar",
                                           description: Text("Pick another day"))
                        .padding(.top, 30)
                } else {
                    hourChart
                    HStack(alignment: .top, spacing: 18) {
                        agentTable.frame(width: 300)
                        taskTable
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("")
        .onAppear(perform: observe)
        .onChange(of: date) { _, _ in observe() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 18)).foregroundStyle(Theme.accent)
            Text("Statistics").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            IconButton(icon: "chevron.left", help: "Previous day") { shift(-1) }
            DatePicker("", selection: $date, displayedComponents: .date).labelsHidden().datePickerStyle(.field).frame(width: 110)
            IconButton(icon: "chevron.right", help: "Next day") { shift(1) }
            Button("Today") { date = Date() }.buttonStyle(AccentButtonStyle(prominent: false))
                .disabled(Calendar.current.isDateInToday(date))
        }
    }

    private var tiles: some View {
        let t = stats.value.total
        return HStack(spacing: 12) {
            Tile(title: "Runs", value: "\(t.runs)", detail: t.active > 0 ? "\(t.active) in progress" : nil)
            Tile(title: "Succeeded", value: "\(t.done)", color: Theme.green,
                 detail: t.successRate.map { "\(Int(($0 * 100).rounded()))% of finished" })
            Tile(title: "Failed", value: "\(t.failed)", color: t.failed > 0 ? Theme.red : Theme.text)
            Tile(title: "Stopped", value: "\(t.cancelled)", color: Theme.secondary)
            Tile(title: "Tasks", value: "\(stats.value.tasks.count)")
            Tile(title: "Cost", value: String(format: "$%.2f", t.cost),
                 detail: t.tokens > 0 ? "\(t.tokens.formatted(.number.notation(.compactName))) tokens" : nil)
            Tile(title: "Agent time", value: t.minutes >= 60 ? "\(t.minutes / 60)h \(t.minutes % 60)m" : "\(t.minutes)m")
        }
    }

    private struct HourPoint: Identifiable {
        var id: String { "\(hour)-\(outcome)" }
        var hour: Int
        var outcome: String
        var runs: Int
    }

    private var hourChart: some View {
        let points = stats.value.hours.enumerated().flatMap { h, c in
            [HourPoint(hour: h, outcome: "Succeeded", runs: c.done), HourPoint(hour: h, outcome: "Failed", runs: c.failed),
             HourPoint(hour: h, outcome: "Stopped", runs: c.cancelled), HourPoint(hour: h, outcome: "In progress", runs: c.active)]
        }.filter { $0.runs > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Runs by hour").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
            Chart(points) { p in
                BarMark(x: .value("Hour", p.hour), y: .value("Runs", p.runs))
                    .foregroundStyle(by: .value("Outcome", p.outcome))
            }
            .chartForegroundStyleScale(["Succeeded": Theme.green, "Failed": Theme.red, "Stopped": Color.gray, "In progress": Theme.accent])
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis { AxisMarks(values: Array(stride(from: 0, through: 23, by: 3))) { v in
                AxisGridLine()
                AxisValueLabel { if let h = v.as(Int.self) { Text(String(format: "%02d:00", h)) } }
            } }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 160)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
        }
    }

    private var agentTable: some View {
        Card(title: "By agent") {
            ForEach(Array(stats.value.agents.enumerated()), id: \.element.id) { i, row in
                HStack(spacing: 8) {
                    Avatar(name: store.agent(row.agentId)?.name ?? "?", size: 20)
                    Text(store.agent(row.agentId)?.name ?? "Deleted agent").font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Outcomes(counts: row.counts)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    if i < stats.value.agents.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 12) }
                }
            }
        }
    }

    private var taskTable: some View {
        Card(title: "Tasks") {
            ForEach(Array(stats.value.tasks.enumerated()), id: \.element.id) { i, row in
                HStack(spacing: 10) {
                    StatusDot(status: row.lastStatus)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.task.content).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        HStack(spacing: 6) {
                            if let agent = store.agent(row.task.agentId) { Text(agent.name) }
                            if row.delegated { Text("· sub-task") }
                            Text("· " + (row.first == row.last ? String(row.first.suffix(5)) : "\(row.first.suffix(5))–\(row.last.suffix(5))"))
                            if row.counts.cost > 0 { Text(String(format: "· $%.2f", row.counts.cost)) }
                        }
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                    Outcomes(counts: row.counts)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { store.selectedTaskId = row.task.id }
                .overlay(alignment: .bottom) {
                    if i < stats.value.tasks.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 34) }
                }
            }
        }
    }

    private func shift(_ days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    private func observe() {
        let day = self.day
        stats.observe(store.db) { try RunStats.load($0, day: day) }
    }
}

private struct Tile: View {
    let title: String
    let value: String
    var color: Color = Theme.text
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(color)
            Text(detail ?? " ").font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
    }
}

/// "3 ✓  1 ✗  1 ■" for a row.
private struct Outcomes: View {
    let counts: RunStats.Counts

    var body: some View {
        HStack(spacing: 8) {
            if counts.done > 0 { item(counts.done, "checkmark.circle.fill", Theme.green, "succeeded") }
            if counts.failed > 0 { item(counts.failed, "xmark.circle.fill", Theme.red, "failed") }
            if counts.cancelled > 0 { item(counts.cancelled, "stop.circle.fill", Theme.tertiary, "stopped") }
            if counts.active > 0 { item(counts.active, "circle.dotted", Theme.accent, "in progress") }
        }
    }

    private func item(_ n: Int, _ icon: String, _ color: Color, _ what: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text("\(n)").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
        }
        .help("\(n) \(what)")
    }
}

private struct StatusDot: View {
    let status: RunStatus

    var body: some View {
        Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color).help(status.rawValue.capitalized)
    }

    private var icon: String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        default: return "circle.dotted"
        }
    }

    private var color: Color {
        switch status {
        case .done: return Theme.green
        case .failed: return Theme.red
        case .cancelled: return Theme.tertiary
        default: return Theme.accent
        }
    }
}
