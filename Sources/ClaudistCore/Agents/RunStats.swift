import Foundation
import GRDB

/// What agents did on one day: runs by outcome, per agent and per task.
public struct RunStats: Sendable, Equatable {
    public struct Counts: Sendable, Equatable {
        public var runs = 0
        public var done = 0
        public var failed = 0
        public var cancelled = 0
        /// Queued, running or waiting.
        public var active = 0
        public var cost = 0.0
        public var tokens = 0
        public var minutes = 0

        /// Share of finished runs that succeeded; nil when none finished.
        public var successRate: Double? {
            let finished = done + failed
            return finished == 0 ? nil : Double(done) / Double(finished)
        }

        mutating func add(_ run: Run) {
            runs += 1
            switch run.status {
            case .done: done += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            default: active += 1
            }
            cost += run.costUsd ?? 0
            tokens += (run.inputTokens ?? 0) + (run.outputTokens ?? 0)
            if let start = LocalDate.parse(run.startedAt), let end = run.endedAt.flatMap({ LocalDate.parse($0) }) {
                minutes += max(0, Int(end.timeIntervalSince(start) / 60))
            }
        }
    }

    public struct AgentRow: Sendable, Equatable, Identifiable {
        public var id: String { agentId ?? "" }
        public var agentId: ID?
        public var counts = Counts()
    }

    public struct TaskRow: Sendable, Equatable, Identifiable {
        public var id: ID { task.id }
        public var task: TaskItem
        public var counts = Counts()
        public var lastStatus: RunStatus
        public var first: String
        public var last: String
        /// Started by another agent (a sub-task).
        public var delegated: Bool
    }

    public var day: String
    public var total = Counts()
    /// Runs started in each hour 0…23, by outcome.
    public var hours = Array(repeating: Counts(), count: 24)
    public var agents: [AgentRow] = []
    public var tasks: [TaskRow] = []

    public init(day: String) { self.day = day }

    public static func load(_ db: Database, day: String) throws -> RunStats {
        var stats = RunStats(day: day)
        let runs = try Run.filter(sql: "substr(startedAt, 1, 10) = ?", arguments: [day])
            .order(Column("startedAt"), Column("rowid")).fetchAll(db)
        let tasks = Dictionary(uniqueKeysWithValues: try TaskItem.fetchAll(db, keys: Set(runs.map(\.taskId))).map { ($0.id, $0) })
        var agentRows: [String: AgentRow] = [:]
        var taskRows: [ID: TaskRow] = [:]
        var taskOrder: [ID] = []
        for run in runs {
            stats.total.add(run)
            if let hour = Int(run.startedAt.dropFirst(11).prefix(2)), (0..<24).contains(hour) { stats.hours[hour].add(run) }
            agentRows[run.agentId ?? "", default: AgentRow(agentId: run.agentId)].counts.add(run)
            guard let task = tasks[run.taskId] else { continue }
            if taskRows[task.id] == nil {
                taskOrder.append(task.id)
                taskRows[task.id] = TaskRow(task: task, lastStatus: run.status, first: run.startedAt, last: run.startedAt,
                                            delegated: run.trigger == "agent")
            }
            taskRows[task.id]!.counts.add(run)
            taskRows[task.id]!.lastStatus = run.status
            taskRows[task.id]!.last = run.startedAt
        }
        stats.agents = agentRows.values.sorted { $0.counts.runs > $1.counts.runs }
        stats.tasks = taskOrder.compactMap { taskRows[$0] }.sorted { $0.last > $1.last }
        return stats
    }
}
