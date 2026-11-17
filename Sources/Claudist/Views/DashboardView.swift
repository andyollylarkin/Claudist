import AppKit
import Charts
import ClaudistCore
import GRDB
import SwiftUI

/// A dashboard: charts over the user's databases, redrawn when a database file changes.
struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    let dashboard: Dashboard
    @StateObject private var charts = Observed<[DashboardChart]>([])
    @StateObject private var loader = ChartLoader()
    @State private var editing: ChartDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: dashboard.name, subtitle: subtitle, icon: "chart.pie", iconColor: Theme.accent) {
                HStack(spacing: 8) {
                    Button { loader.reload() } label: { SwiftUI.Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .disabled(charts.value.isEmpty)
                    Button { addChart() } label: { SwiftUI.Label("Add chart", systemImage: "plus") }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(store.databases.isEmpty)
                        .help(store.databases.isEmpty ? "Create a database first" : "Chart a query on one of your databases")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 14)
            Divider()
            if charts.value.isEmpty {
                ContentUnavailableView("No charts yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Add a chart over one of your databases, or ask the Assistant or an agent with database access to build one"))
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(rows, id: \.self) { row in
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(row.ids, id: \.self) { id in
                                    if let chart = charts.value.first(where: { $0.id == id }) { card(chart) }
                                }
                                // Keep the cards of a short row at their usual width.
                                ForEach(row.ids.count..<row.capacity, id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("")
        .sheet(item: $editing) { ChartEditor(draft: $0) }
        .onAppear {
            let id = dashboard.id
            charts.observe(store.db) { try DashboardChart.filter(Column("dashboardId") == id).order(Column("itemOrder")).fetchAll($0) }
        }
        .onChange(of: charts.value, initial: true) { loader.update(charts.value, databases: store.databases) }
        .onChange(of: store.databases) { loader.update(charts.value, databases: store.databases) }
        .onDisappear { loader.stop() }
    }

    private var subtitle: String {
        let n = charts.value.count
        let databases = Set(charts.value.map(\.databaseId)).compactMap { id in store.databases.first { $0.id == id }?.name }.sorted()
        guard n > 0 else { return "Charts over your databases" }
        return "\(n) chart\(n == 1 ? "" : "s") · " + databases.joined(separator: ", ")
    }

    private struct Row: Hashable {
        var ids: [ID]
        var capacity: Int
    }

    /// Wide charts take a row; half-width ones pair up in order; numbers go up to four in a row.
    private var rows: [Row] {
        var rows: [Row] = []
        for chart in charts.value {
            let capacity = chart.wide ? 1 : chart.kind == .number ? 4 : 2
            if let last = rows.last, last.capacity == capacity, last.ids.count < capacity {
                rows[rows.count - 1].ids.append(chart.id)
            } else {
                rows.append(Row(ids: [chart.id], capacity: capacity))
            }
        }
        return rows
    }

    private func card(_ chart: DashboardChart) -> some View {
        ChartCard(chart: chart, database: store.databases.first { $0.id == chart.databaseId }, state: loader.states[chart.id],
                  edit: { editing = ChartDraft(chart: chart, isNew: false) }) {
            Button("Edit…") { editing = ChartDraft(chart: chart, isNew: false) }
            Button(chart.wide ? "Half width" : "Full width") {
                var c = chart
                c.wide.toggle()
                store.write { try c.update($0) }
            }
            Button("Move earlier") { move(chart, by: -1) }.disabled(charts.value.first?.id == chart.id)
            Button("Move later") { move(chart, by: 1) }.disabled(charts.value.last?.id == chart.id)
            Button("Duplicate") { duplicate(chart) }
            if let other = store.dashboards.filter({ $0.id != dashboard.id }).nilIfEmpty {
                Menu("Move to") {
                    ForEach(other) { d in Button(d.name) { moveTo(chart, d) } }
                }
            }
            Divider()
            Button("Delete chart", role: .destructive) { store.write { _ = try chart.delete($0) } }
        }
    }

    private func addChart() {
        guard let database = store.databases.first else { return }
        var chart = DashboardChart(dashboardId: dashboard.id, databaseId: database.id, title: "", kind: .bar, sql: "")
        chart.itemOrder = (charts.value.map(\.itemOrder).max() ?? 0) + 1
        editing = ChartDraft(chart: chart, isNew: true)
    }

    private func move(_ chart: DashboardChart, by offset: Int) {
        var list = charts.value
        guard let i = list.firstIndex(where: { $0.id == chart.id }), list.indices.contains(i + offset) else { return }
        list.swapAt(i, i + offset)
        store.write { db in
            for (n, var c) in list.enumerated() where c.itemOrder != n + 1 {
                c.itemOrder = n + 1
                try c.update(db)
            }
        }
    }

    private func duplicate(_ chart: DashboardChart) {
        var copy = DashboardChart(dashboardId: chart.dashboardId, databaseId: chart.databaseId, title: chart.title + " copy",
                                  kind: chart.kind, sql: chart.sql)
        copy.wide = chart.wide
        copy.itemOrder = (charts.value.map(\.itemOrder).max() ?? 0) + 1
        store.write { try copy.insert($0) }
    }

    private func moveTo(_ chart: DashboardChart, _ target: Dashboard) {
        var c = chart
        c.dashboardId = target.id
        store.write { db in
            c.itemOrder = (try Int.fetchOne(db, sql: "SELECT MAX(itemOrder) FROM dashboardChart WHERE dashboardId = ?", arguments: [target.id]) ?? 0) + 1
            try c.update(db)
        }
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

/// A chart being added or edited.
struct ChartDraft: Identifiable {
    var id: ID { chart.id }
    var chart: DashboardChart
    var isNew: Bool
}

// MARK: Loading

/// Runs chart queries off the main thread and reruns them when their database file changes
/// (agents write databases outside the app).
@MainActor
final class ChartLoader: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(ChartData)
        case failed(String)
    }

    @Published private(set) var states: [ID: State] = [:]
    private var charts: [DashboardChart] = []
    private var paths: [ID: String] = [:]
    private var stamps: [String: Date] = [:]
    private var timer: Timer?
    /// Bumped per load so a slow, outdated query doesn't overwrite a newer result.
    private var generation: [ID: Int] = [:]

    func update(_ charts: [DashboardChart], databases: [UserDatabase]) {
        let newPaths = Dictionary(databases.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        let changed = charts.filter { chart in
            guard let old = self.charts.first(where: { $0.id == chart.id }), states[chart.id] != nil else { return true }
            return old.sql != chart.sql || old.kind != chart.kind || old.databaseId != chart.databaseId || paths[chart.databaseId] != newPaths[chart.databaseId]
        }
        self.charts = charts
        paths = newPaths
        states = states.filter { id, _ in charts.contains { $0.id == id } }
        load(changed)
        stamps = currentStamps()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    func reload() { load(charts) }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func load(_ list: [DashboardChart]) {
        for chart in list {
            let id = chart.id
            guard let path = paths[chart.databaseId] else {
                states[id] = .failed("The database of this chart is gone")
                continue
            }
            if states[id] == nil { states[id] = .loading }
            let n = (generation[id] ?? 0) + 1
            generation[id] = n
            let sql = chart.sql
            let kind = chart.kind
            DispatchQueue.global(qos: .userInitiated).async {
                let state = ChartLoader.run(path: path, sql: sql, kind: kind)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation[id] == n else { return }
                    self.states[id] = state
                }
            }
        }
    }

    nonisolated static func run(path: String, sql: String, kind: ChartKind) -> State {
        guard FileManager.default.fileExists(atPath: path) else { return .failed("The database file is missing: \(path)") }
        do {
            return .loaded(try ChartData.load(path: path, sql: sql, kind: kind))
        } catch let error as DatabaseError {
            return .failed(error.message ?? error.localizedDescription)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func poll() {
        let now = currentStamps()
        let changed = Set(now.keys.filter { now[$0] != stamps[$0] })
        stamps = now
        guard !changed.isEmpty else { return }
        load(charts.filter { paths[$0.databaseId].map(changed.contains) ?? false })
    }

    /// Latest modification of each database file, counting its WAL.
    private func currentStamps() -> [String: Date] {
        var out: [String: Date] = [:]
        for path in Set(charts.compactMap { paths[$0.databaseId] }) {
            let dates = [path, path + "-wal"].compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
            }
            out[path] = dates.max() ?? .distantPast
        }
        return out
    }
}

// MARK: Card

private struct ChartCard<Actions: View>: View {
    let chart: DashboardChart
    let database: UserDatabase?
    let state: ChartLoader.State?
    let edit: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: chart.kind.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text(chart.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Menu { actions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Theme.secondary).frame(width: 22, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Group {
                switch state {
                case .loaded(let data): ChartBody(kind: chart.kind, data: data)
                case .failed(let message):
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(Theme.red)
                        Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center).lineLimit(5).textSelection(.enabled)
                        Button("Edit query", action: edit).buttonStyle(AccentButtonStyle(prominent: false))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loading, nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: chart.kind == .number ? 70 : 250)
            HStack(spacing: 10) {
                Pill(text: database?.name ?? "missing database", icon: "cylinder.split.1x2", color: Theme.tertiary)
                if chart.author != "user" { Pill(text: "by \(chart.author)", icon: "sparkles", color: Theme.tertiary) }
                Spacer()
                if case .loaded(let data) = state, data.truncated {
                    Text("first \(ChartData.maxRows) rows").font(.system(size: 10)).foregroundStyle(Theme.orange)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
        .contextMenu { actions }
    }
}

// MARK: Charts

enum ChartPalette {
    static let names = ["blue", "red", "green", "orange", "violet", "teal", "yellow", "magenta", "sky", "brown", "olive", "gray"]
    static func color(_ i: Int) -> Color { Theme.color(names[i % names.count]) }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...(abs(value) >= 100 ? 0 : 2))))
    }
}

struct ChartBody: View {
    let kind: ChartKind
    let data: ChartData

    var body: some View {
        if data.labels.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray").font(.system(size: 20)).foregroundStyle(Theme.tertiary)
                Text("The query returned no rows").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .number {
            VStack(alignment: .leading, spacing: 4) {
                Text(data.value.map(ChartPalette.format) ?? "—")
                    .font(.system(size: 32, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(data.series.first?.name ?? "").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if kind == .pie {
            PieChart(data: data)
        } else {
            XYChart(kind: kind, data: data)
        }
    }
}

private struct PieChart: View {
    let data: ChartData
    @State private var angle: Double?

    var body: some View {
        let slices = data.slices()
        let total = slices.map(\.value).reduce(0, +)
        let selected = selection(slices)
        if slices.isEmpty {
            Text("No positive values to draw").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 18) {
                Chart(Array(slices.enumerated()), id: \.offset) { i, slice in
                    SectorMark(angle: .value("Value", slice.value), innerRadius: .ratio(0.58), angularInset: 1.2)
                        .cornerRadius(3)
                        .foregroundStyle(ChartPalette.color(i))
                        .opacity(selected == nil || selected == i ? 1 : 0.35)
                }
                .chartAngleSelection(value: $angle)
                .chartBackground { proxy in
                    GeometryReader { geo in
                        if let anchor = proxy.plotFrame {
                            let frame = geo[anchor]
                            VStack(spacing: 2) {
                                Text(selected.map { slices[$0].label } ?? "Total")
                                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                                Text(ChartPalette.format(selected.map { slices[$0].value } ?? total))
                                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                                if let s = selected, total > 0 {
                                    Text(percent(slices[s].value / total)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                }
                            }
                            .frame(width: frame.width * 0.5)
                            .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(minWidth: 150)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(slices.enumerated()), id: \.offset) { i, slice in
                            HStack(spacing: 6) {
                                Circle().fill(ChartPalette.color(i)).frame(width: 8, height: 8)
                                Text(slice.label).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(ChartPalette.format(slice.value)).font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Theme.text)
                                Text(total > 0 ? percent(slice.value / total) : "").font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Theme.tertiary).frame(width: 38, alignment: .trailing)
                            }
                            .opacity(selected == nil || selected == i ? 1 : 0.5)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: 260)
            }
        }
    }

    private func selection(_ slices: [(label: String, value: Double)]) -> Int? {
        guard let angle else { return nil }
        var sum = 0.0
        for (i, s) in slices.enumerated() {
            sum += s.value
            if angle <= sum { return i }
        }
        return nil
    }

    private func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
    }
}

private struct XYChart: View {
    let kind: ChartKind
    let data: ChartData
    @State private var selected: String?

    private struct Point: Identifiable {
        var id: String { "\(series)\u{1}\(index)" }
        let index: Int
        let label: String
        let series: String
        let value: Double
    }

    var body: some View {
        let points = data.series.flatMap { s in
            data.labels.indices.compactMap { i in s.values[i].map { Point(index: i, label: data.labels[i], series: s.name, value: $0) } }
        }
        let names = data.series.map(\.name)
        Group {
            if kind == .bar {
                Chart {
                    ForEach(points) { p in
                        BarMark(x: .value(data.labelColumn, p.label), y: .value("Value", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                            .position(by: .value("Series", p.series))
                            .cornerRadius(3)
                            .opacity(selected == nil || selected == p.label ? 1 : 0.45)
                    }
                    selectionRule(points)
                }
            } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value(data.labelColumn, p.label), y: .value("Value", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value(data.labelColumn, p.label), y: .value("Value", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                            .symbolSize(data.labels.count > 40 ? 0 : 24)
                    }
                    selectionRule(points)
                }
            }
        }
        .chartForegroundStyleScale(domain: names, range: names.indices.map(ChartPalette.color))
        .chartLegend(names.count > 1 ? .visible : .hidden)
        .chartXScale(domain: unique(data.labels))
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(collisionResolution: .greedy)
            }
        }
    }

    @ChartContentBuilder
    private func selectionRule(_ points: [Point]) -> some ChartContent {
        if let selected {
            RuleMark(x: .value(data.labelColumn, selected))
                .foregroundStyle(Theme.tertiary.opacity(0.35))
                .zIndex(-1)
                .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                        ForEach(points.filter { $0.label == selected }) { p in
                            HStack(spacing: 5) {
                                Circle().fill(ChartPalette.color(data.series.firstIndex { $0.name == p.series } ?? 0)).frame(width: 7, height: 7)
                                if data.series.count > 1 { Text(p.series).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                                Text(ChartPalette.format(p.value)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text)
                            }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card).shadow(color: .black.opacity(0.12), radius: 4, y: 1))
                }
        }
    }

    private func unique(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }
    }
}

// MARK: Editor

/// Add or change a chart: database, kind and query, with a live preview.
struct ChartEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var chart: DashboardChart
    private let isNew: Bool
    @State private var preview: ChartLoader.State?
    @State private var pending: DispatchWorkItem?
    @State private var request = ""
    @StateObject private var writer = ChartQueryWriter()

    init(draft: ChartDraft) {
        _chart = State(initialValue: draft.chart)
        isNew = draft.isNew
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add chart" : "Edit chart").font(.system(size: 16, weight: .bold)).padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                Form {
                    Section {
                        TextField("", text: $request, prompt: Text(chart.sql.isEmpty
                                                                    ? "e.g. expenses by category this month"
                                                                    : "e.g. add an income line, only last 6 months"),
                                  axis: .vertical)
                            .lineLimit(2...4)
                            .labelsHidden()
                            .onSubmit(write)
                        HStack(spacing: 8) {
                            if writer.phase == .running {
                                ProgressView().controlSize(.small)
                                Text("Claude is writing the query…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                Spacer()
                                Button("Stop") { writer.cancel() }.buttonStyle(AccentButtonStyle(prominent: false))
                            } else {
                                if case .failed(let error) = writer.phase {
                                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.red).lineLimit(3)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button { write() } label: {
                                    SwiftUI.Label(chart.sql.isEmpty ? "Write query" : "Change query", systemImage: "sparkles")
                                }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .help("Claude reads the database schema and a few sample rows and writes the query")
                            }
                        }
                    } header: {
                        Text("Describe the chart")
                    }
                    Section {
                        TextField("Title", text: $chart.title)
                        Picker("Database", selection: $chart.databaseId) {
                            ForEach(store.databases) { Text($0.name).tag($0.id) }
                        }
                        Picker("Kind", selection: $chart.kind) {
                            ForEach(ChartKind.allCases, id: \.self) { kind in
                                SwiftUI.Label(kind.title, systemImage: kind.symbol).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Full width", isOn: $chart.wide)
                    }
                    Section {
                        TextEditor(text: $chart.sql)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 170)
                            .scrollContentBackground(.hidden)
                        HStack {
                            Text("First column: labels. Next columns: numbers, one series each; a pie uses the first. A number: one row, one value.")
                                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Example") { chart.sql = example() }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                                .help("Fill in a query over the first table")
                        }
                    } header: {
                        Text("Query (read-only SQL)")
                    }
                }
                .formStyle(.grouped)
                .frame(width: 420)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Group {
                        switch preview {
                        case .loaded(let data):
                            VStack(alignment: .leading, spacing: 8) {
                                ChartBody(kind: chart.kind, data: data)
                                Text(describe(data)).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            }
                        case .failed(let message):
                            Text(message).font(.system(size: 12)).foregroundStyle(Theme.red).textSelection(.enabled)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        case .loading:
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                        case nil:
                            Text("Write a query to see the chart").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                }
                .padding(20)
                .frame(width: 460, height: 400)
            }
            Divider()
            DialogButtons(confirm: isNew ? "Add" : "Save", disabled: !canSave) { save() }
        }
        .frame(width: 880)
        .onAppear { schedulePreview(delay: 0) }
        .onChange(of: chart.sql) { schedulePreview() }
        .onChange(of: chart.databaseId) { schedulePreview(delay: 0) }
        .onChange(of: chart.kind) { schedulePreview(delay: 0) }
        .onDisappear { writer.cancel() }
    }

    private func write() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, writer.phase != .running,
              let database = store.databases.first(where: { $0.id == chart.databaseId }) else { return }
        let current = chart.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
            : ChartQueryGenerator.Proposal(title: chart.title, kind: chart.kind, sql: chart.sql, wide: chart.wide)
        writer.start(request: text, database: database, current: current) { proposal in
            if chart.title.trimmingCharacters(in: .whitespaces).isEmpty || current == nil { chart.title = proposal.title }
            chart.kind = proposal.kind
            if current == nil { chart.wide = proposal.wide }
            chart.sql = proposal.sql
            request = ""
            schedulePreview(delay: 0)
        }
    }

    private var canSave: Bool {
        !chart.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !chart.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.databases.contains { $0.id == chart.databaseId }
    }

    private func save() {
        chart.title = chart.title.trimmingCharacters(in: .whitespaces)
        chart.updatedAt = LocalDate.stamp(Date())
        let c = chart
        store.write { try c.save($0) }
        dismiss()
    }

    private func schedulePreview(delay: Double = 0.5) {
        pending?.cancel()
        let sql = chart.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = chart.kind
        guard !sql.isEmpty, let path = store.databases.first(where: { $0.id == chart.databaseId })?.path else {
            preview = nil
            return
        }
        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .userInitiated).async {
                let state = ChartLoader.run(path: path, sql: sql, kind: kind)
                DispatchQueue.main.async {
                    // Only the latest query's answer counts.
                    if chart.sql.trimmingCharacters(in: .whitespacesAndNewlines) == sql { preview = state }
                }
            }
        }
        pending = work
        if preview == nil { preview = .loading }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func describe(_ data: ChartData) -> String {
        var text = "\(data.labels.count) row\(data.labels.count == 1 ? "" : "s") · labels: \(data.labelColumn) · "
        text += data.series.count == 1 ? "values: \(data.series[0].name)" : "series: \(data.series.map(\.name).joined(separator: ", "))"
        if chart.kind == .pie, data.series.count > 1 { text += " (a pie uses \(data.series[0].name))" }
        return text
    }

    /// A grouped count over the first table, as a starting point.
    private func example() -> String {
        guard let path = store.databases.first(where: { $0.id == chart.databaseId })?.path,
              let table = (try? SQLiteFile.tables(path))?.first else {
            return "SELECT category, SUM(amount) AS total\nFROM expenses\nGROUP BY category\nORDER BY total DESC"
        }
        let label = table.columns.first { $0.primaryKey == 0 && ($0.type.uppercased().contains("TEXT") || $0.type.isEmpty) }
            ?? table.columns.first { $0.primaryKey == 0 } ?? table.columns.first
        let number = table.columns.first { c in
            c.name != label?.name && c.primaryKey == 0 && ["REAL", "NUM", "INT", "DEC", "FLOAT", "DOUBLE"].contains { c.type.uppercased().contains($0) }
                && !c.name.lowercased().hasSuffix("id")
        }
        let l = SQLiteFile.quote(label?.name ?? "rowid")
        let value = number.map { "SUM(\(SQLiteFile.quote($0.name)))" } ?? "COUNT(*)"
        return "SELECT \(l), \(value) AS total\nFROM \(SQLiteFile.quote(table.name))\nGROUP BY 1\nORDER BY total DESC"
    }
}

// MARK: Naming

enum DashboardNaming {
    static func ask(title: String, suggested: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

// MARK: Writing queries with Claude

/// Asks Claude for a chart query from a description, checks it and asks again (once or twice) when it fails.
@MainActor
final class ChartQueryWriter: ObservableObject {
    enum Phase: Equatable { case idle, running, failed(String) }

    @Published private(set) var phase = Phase.idle
    private var process: AgentProcess?
    private var path = ""
    private var fixes = 0
    private var onDone: ((ChartQueryGenerator.Proposal) -> Void)?
    static let maxFixes = 2

    func start(request: String, database: UserDatabase, current: ChartQueryGenerator.Proposal?,
               onDone: @escaping (ChartQueryGenerator.Proposal) -> Void) {
        cancel()
        self.onDone = onDone
        path = database.path
        fixes = 0
        phase = .running
        let path = database.path
        let name = database.name
        DispatchQueue.global(qos: .userInitiated).async {
            let message = Result { try ChartQueryGenerator.context(path: path) }
                .map { ChartQueryGenerator.message(request: request, database: name, context: $0, current: current) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .running else { return }
                switch message {
                case .success(let text): self.launch(text)
                case .failure(let error): self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        if phase == .running { phase = .idle }
    }

    private func launch(_ message: String) {
        do {
            let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: ChartQueryGenerator.arguments(),
                                       cwd: FileManager.default.temporaryDirectory,
                                       environment: ClaudeAccounts.defaultHostEnvironment()) { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
            self.process = process
            try process.start()
            process.send(message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func handle(_ event: AgentProcess.Event) {
        switch event {
        case .message(let kind, let json):
            guard kind.hasPrefix("result") else { return }
            let text = JSONValue.parse(json)?["result"]?.string ?? ""
            guard kind == "result/success", let proposal = ChartQueryGenerator.parse(text) else {
                finish(.failed(text.isEmpty ? "Claude gave no query" : "Claude gave no query: \(text.prefix(300))"))
                return
            }
            check(proposal)
        case .permission(let request):
            process?.respond(request, .deny("No tools while writing a query"))
        case .mcp(let requestId, _, let message):
            process?.respondMCP(requestId: requestId, id: message["id"], result: nil, error: (-32601, "No MCP servers"))
        case .stderr:
            break
        case .exited(let code):
            process = nil
            if phase == .running { phase = .failed("Claude Code exited with code \(code)") }
        }
    }

    private func check(_ proposal: ChartQueryGenerator.Proposal) {
        let path = self.path
        DispatchQueue.global(qos: .userInitiated).async {
            let state = ChartLoader.run(path: path, sql: proposal.sql, kind: proposal.kind)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .running else { return }
                if case .failed(let error) = state {
                    if self.fixes < Self.maxFixes, let process = self.process {
                        self.fixes += 1
                        process.send(ChartQueryGenerator.fixMessage(error: error))
                    } else {
                        // Still useful: the user sees the query and the error in the preview.
                        self.onDone?(proposal)
                        self.finish(.failed(error))
                    }
                    return
                }
                self.onDone?(proposal)
                self.finish(.idle)
            }
        }
    }

    private func finish(_ phase: Phase) {
        self.phase = phase
        process?.closeInput()
        process?.terminate()
        process = nil
    }
}
