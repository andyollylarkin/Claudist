import Foundation
import GRDB

public enum FilterSQL {
    /// WHERE-clause SQL over table `task` aliased as `t`, with bound arguments.
    ///
    /// Besides the expression itself the clause keeps Todoist's implicit rules:
    /// - only open tasks, unless the expression mentions `completed` / `completed before|after|:`;
    /// - tasks of archived projects are never returned.
    /// `includeCompleted` drops the first rule (the "show completed" switch of a view).
    public static func compile(_ expr: FilterExpr, context: FilterContext, includeCompleted: Bool = false) throws -> (sql: String, arguments: StatementArguments) {
        var c = FilterSQLCompiler(ctx: context)
        var sql = "(" + c.sql(expr) + ")"
        if !expr.mentionsCompleted && !includeCompleted { sql += " AND t.isCompleted = 0" }
        sql += " AND NOT EXISTS (SELECT 1 FROM project ap WHERE ap.id = t.projectId AND ap.isArchived = 1)"
        return (sql, StatementArguments(c.args))
    }
}

public enum FilterEngine {
    /// Ordering used for filter results: date (no date last), time (no time last), priority, manual order.
    public static let orderBy = "t.dueDate IS NULL, t.dueDate, t.dueTime IS NULL, t.dueTime, t.priority, t.childOrder, t.rowid"

    /// Parses `query`, compiles every comma-separated group and fetches its tasks.
    public static func tasks(_ db: Database, query: String, context: FilterContext,
                             includeCompleted: Bool = false) throws -> [(title: String, tasks: [TaskItem])] {
        try FilterQuery.parse(query).map { group in
            let (sql, args) = try FilterSQL.compile(group.expr, context: context, includeCompleted: includeCompleted)
            // Completed tasks go after open ones.
            let order = includeCompleted ? "t.isCompleted, " + orderBy : orderBy
            let tasks = try TaskItem.fetchAll(db, sql: "SELECT t.* FROM task t WHERE \(sql) ORDER BY \(order)", arguments: args)
            return (group.title, tasks)
        }
    }
}

struct FilterSQLCompiler {
    let ctx: FilterContext
    var args: [(any DatabaseValueConvertible)?] = []

    init(ctx: FilterContext) { self.ctx = ctx }

    mutating func bind(_ v: any DatabaseValueConvertible) -> String {
        args.append(v)
        return "?"
    }

    mutating func like(_ column: String, _ p: NamePattern) -> String {
        "swiftLowercaseString(\(column)) LIKE \(bind(p.likePattern)) ESCAPE '\\'"
    }

    static let latestRun = "(SELECT r.%@ FROM run r WHERE r.taskId = t.id ORDER BY r.startedAt DESC, r.rowid DESC LIMIT 1)"

    mutating func sql(_ e: FilterExpr) -> String {
        switch e {
        case .and(let a, let b): return "(\(sql(a)) AND \(sql(b)))"
        case .or(let a, let b): return "(\(sql(a)) OR \(sql(b)))"
        // NULL counts as "no match", so NOT is a set complement.
        case .not(let a): return "((\(sql(a))) IS NOT 1)"
        case .all: return "1"

        case .project(let p, let sub):
            let match = like("name", p)
            if !sub { return "t.projectId IN (SELECT id FROM project WHERE \(match))" }
            return """
            t.projectId IN (WITH RECURSIVE sub(id) AS (SELECT id FROM project WHERE \(match) \
            UNION SELECT p.id FROM project p JOIN sub ON p.parentId = sub.id) SELECT id FROM sub)
            """
        case .section(let p):
            if p.isAnything { return "t.sectionId IS NOT NULL" }
            return "t.sectionId IN (SELECT id FROM section WHERE \(like("name", p)))"
        case .label(let p):
            return "EXISTS (SELECT 1 FROM taskLabel tl JOIN label l ON l.id = tl.labelId WHERE tl.taskId = t.id AND \(like("l.name", p)))"
        case .noLabels:
            return "NOT EXISTS (SELECT 1 FROM taskLabel tl WHERE tl.taskId = t.id)"
        case .priority(let n):
            return "t.priority = \(bind(n))"
        case .search(let s):
            let p = NamePattern(parts: [.wildcard, .literal(s), .wildcard])
            return like("t.content", p)

        case .overdue:
            let today = ctx.today
            let now = LocalDate.time(ctx.now, calendar: ctx.calendar)
            return "(t.dueDate < \(bind(today)) OR (t.dueDate = \(bind(today)) AND t.dueTime IS NOT NULL AND t.dueTime < \(bind(now))))"
        case .noDate: return "t.dueDate IS NULL"
        case .noTime: return "(t.dueDate IS NOT NULL AND t.dueTime IS NULL)"
        case .noDeadline: return "t.deadline IS NULL"
        case .recurring: return "(t.isRecurring = 1 AND t.dueDate IS NOT NULL)"
        case .needsYou: return Attention.sqlCondition
        case .subtask: return "t.parentId IS NOT NULL"
        case .shared: return "0"
        case .assigned: return "t.agentId IS NOT NULL"
        case .assignedTo(let who):
            switch who {
            case .me: return "t.agentId IS NULL"
            case .others: return "t.agentId IS NOT NULL"
            case .named(let p):
                if p.parts == [.literal(ctx.currentUser)] || p.description.lowercased() == ctx.currentUser.lowercased() {
                    return "t.agentId IS NULL"
                }
                return "EXISTS (SELECT 1 FROM agent a WHERE a.id = t.agentId AND \(like("a.name", p)))"
            }
        case .uncompletable: return "t.content LIKE '* %'"
        case .completed: return "t.isCompleted = 1"
        case .run(nil): return "EXISTS (SELECT 1 FROM run r WHERE r.taskId = t.id)"
        case .run(let status?):
            return String(format: Self.latestRun, "status") + " = \(bind(status.rawValue))"

        case .date(let field, let cmp, let expr):
            return date(field, cmp, expr)
        }
    }

    mutating func date(_ field: DateField, _ cmp: DateComparison, _ expr: DateExpr) -> String {
        let past = field == .created || field == .completed || field == .run
        let r = expr.resolve(ctx, preferPast: past)
        let d: String, tm: String?
        var guardSQL = ""
        switch field {
        case .date: d = "t.dueDate"; tm = "t.dueTime"
        case .due: d = "COALESCE(t.dueDate, t.deadline)"; tm = "t.dueTime"
        case .deadline: d = "t.deadline"; tm = nil
        case .created: d = "substr(t.createdAt, 1, 10)"; tm = "substr(t.createdAt, 12, 5)"
        case .completed:
            d = "substr(t.completedAt, 1, 10)"; tm = "substr(t.completedAt, 12, 5)"
            guardSQL = "t.isCompleted = 1 AND "
        case .run:
            let s = String(format: Self.latestRun, "startedAt")
            d = "substr(\(s), 1, 10)"; tm = "substr(\(s), 12, 5)"
        }
        let body: String
        if let time = r.time, let tm {
            let day = r.start.description, t = time.description
            switch cmp {
            case .on: body = "(\(d) = \(bind(day)) AND \(tm) = \(bind(t)))"
            case .before: body = "(\(d) < \(bind(day)) OR (\(d) = \(bind(day)) AND \(tm) IS NOT NULL AND \(tm) < \(bind(t))))"
            case .after: body = "(\(d) > \(bind(day)) OR (\(d) = \(bind(day)) AND \(tm) IS NOT NULL AND \(tm) > \(bind(t))))"
            }
        } else {
            switch cmp {
            case .on where r.start == r.end: body = "\(d) = \(bind(r.start.description))"
            case .on: body = "(\(d) BETWEEN \(bind(r.start.description)) AND \(bind(r.end.description)))"
            case .before: body = "\(d) < \(bind(r.start.description))"
            case .after: body = "\(d) > \(bind(r.end.description))"
            }
        }
        return "(" + guardSQL + body + ")"
    }
}
