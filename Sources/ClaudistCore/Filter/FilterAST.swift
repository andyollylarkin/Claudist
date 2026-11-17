import Foundation

/// A name with optional `*` wildcards (`Work*`, `*Work*`, `m* smith`). Matched case-insensitively.
public struct NamePattern: Equatable, Sendable, CustomStringConvertible {
    public enum Part: Equatable, Sendable {
        case literal(String)
        case wildcard
    }

    public var parts: [Part]

    public init(parts: [Part]) { self.parts = parts }

    /// Builds a pattern where every `*` is a wildcard.
    public init(_ text: String) {
        var parts: [Part] = []
        var lit = ""
        for ch in text {
            if ch == "*" {
                if !lit.isEmpty { parts.append(.literal(lit)); lit = "" }
                parts.append(.wildcard)
            } else {
                lit.append(ch)
            }
        }
        if !lit.isEmpty { parts.append(.literal(lit)) }
        self.parts = parts
    }

    public var isAnything: Bool { !parts.isEmpty && parts.allSatisfy { $0 == .wildcard } }

    public var description: String {
        parts.map {
            switch $0 {
            case .wildcard: return "*"
            case .literal(let s): return s.replacingOccurrences(of: "*", with: "\\*")
            }
        }.joined()
    }

    /// Lowercased SQL LIKE pattern, to be used with `ESCAPE '\'`.
    var likePattern: String {
        parts.map {
            switch $0 {
            case .wildcard: return "%"
            case .literal(let s):
                var out = ""
                for ch in s.lowercased() {
                    if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
                    out.append(ch)
                }
                return out
            }
        }.joined()
    }
}

/// Date-bearing task fields a date operator can apply to.
public enum DateField: String, Equatable, Sendable {
    /// `date:` / bare dates — the task's due date (and time).
    case date
    /// `due:` — the due date, falling back to the deadline when the task has no date.
    case due
    case deadline
    case created
    case completed
    /// Start time of the task's latest run.
    case run
}

public enum DateComparison: String, Equatable, Sendable {
    case on, before, after
}

/// Who a task is assigned to. Tasks are assigned to agents (`task.agentId`); "me" means
/// the task is not delegated to any agent.
public enum Assignee: Equatable, Sendable {
    case me
    case others
    case named(NamePattern)
}

/// Filter AST.
public indirect enum FilterExpr: Equatable, Sendable {
    case and(FilterExpr, FilterExpr)
    case or(FilterExpr, FilterExpr)
    case not(FilterExpr)

    /// `view all` / `all`.
    case all
    /// `#Name` (exact project) or `##Name` (project and all sub-projects).
    case project(NamePattern, includeSubprojects: Bool)
    /// `/Name`; `/*` = any section.
    case section(NamePattern)
    /// `@name` or `%name`.
    case label(NamePattern)
    case noLabels
    /// 1…4; `no priority` = 4.
    case priority(Int)
    /// `search: text` — substring of the task content.
    case search(String)

    /// Dates: `today`, `date before: May 5`, `deadline: today`, `created after: -30 days`, `5 days`…
    case date(DateField, DateComparison, DateExpr)
    case overdue
    case noDate
    /// Has a date but no time.
    case noTime
    case noDeadline
    case recurring
    /// Flagged by the user.
    case flagged

    case subtask
    /// Always false: Claudist has no shared projects.
    case shared
    /// Task delegated to an agent.
    case assigned
    case assignedTo(Assignee)
    /// Content starts with `* ` (Todoist's uncompletable tasks).
    case uncompletable

    /// Completed tasks. Mentioning `completed` anywhere disables the implicit "open tasks only" rule.
    case completed
    /// Latest run has this status; `run` alone (status nil) = has any run.
    case run(RunStatus?)
    /// An agent asked the user something or waits for a permission answer.
    case needsYou

    /// True if the expression explicitly talks about completed tasks.
    public var mentionsCompleted: Bool {
        switch self {
        case .and(let a, let b), .or(let a, let b): return a.mentionsCompleted || b.mentionsCompleted
        case .not(let a): return a.mentionsCompleted
        case .completed, .date(.completed, _, _): return true
        default: return false
        }
    }
}

public struct FilterGroupQuery: Equatable, Sendable {
    /// Source text of this comma-separated part, trimmed.
    public let title: String
    public let expr: FilterExpr

    public init(title: String, expr: FilterExpr) {
        self.title = title
        self.expr = expr
    }
}
