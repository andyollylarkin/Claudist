import Foundation
import GRDB

/// Subscription limits as Claude Code reports them: every stream carries `rate_limit_event`
/// lines with the utilization of each window (5-hour session, week, …) and when it resets.
public struct UsageLimits: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable, Identifiable {
        public var id: String { name }
        /// `five_hour`, `seven_day`, `seven_day_opus` …
        public var name: String
        /// 0…1
        public var utilization: Double
        public var resetsAt: Date?
        /// `allowed`, `allowed_warning`, `rejected`
        public var status: String

        public var title: String {
            switch name {
            case "five_hour": return "5-hour session"
            case "seven_day": return "Week"
            default:
                let parts = name.split(separator: "_")
                if parts.starts(with: ["seven", "day"]) {
                    return "Week (" + parts.dropFirst(2).joined(separator: " ").capitalized + ")"
                }
                return name.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        public var short: String {
            switch name {
            case "five_hour": return "5h"
            case "seven_day": return "Week"
            default: return title
            }
        }

        public var limited: Bool { status == "rejected" }
    }

    public var windows: [Window]
    /// Overall status of the latest request.
    public var status: String
    /// Extra usage beyond the plan: `allowed` / `rejected`, and whether it is in use now.
    public var overageStatus: String?
    public var isUsingOverage: Bool
    /// Local stamp of when Claude Code reported it.
    public var observedAt: String

    public init?(json: String, observedAt: String) {
        guard let info = JSONValue.parse(json)?["rate_limit_info"] else { return nil }
        var windows: [Window] = []
        if case .object(let unified)? = info["unifiedWindows"] {
            for (name, w) in unified {
                windows.append(Window(name: name, utilization: w["utilization"]?.number ?? 0,
                                      resetsAt: w["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) },
                                      status: w["status"]?.string ?? "allowed"))
            }
        } else if let type = info["rateLimitType"]?.string {
            // Older streams: only the window that applies, without utilization.
            windows.append(Window(name: type, utilization: info["utilization"]?.number ?? 0,
                                  resetsAt: info["resetsAt"]?.number.map { Date(timeIntervalSince1970: $0) },
                                  status: info["status"]?.string ?? "allowed"))
        }
        let order = ["five_hour", "seven_day"]
        self.windows = windows.sorted { (order.firstIndex(of: $0.name) ?? 9, $0.name) < (order.firstIndex(of: $1.name) ?? 9, $1.name) }
        status = info["status"]?.string ?? "allowed"
        overageStatus = info["overageStatus"]?.string
        isUsingOverage = info["isUsingOverage"]?.bool ?? false
        self.observedAt = observedAt
    }

    /// The most limiting window.
    public var worst: Window? { windows.max { $0.utilization < $1.utilization } }

    /// The latest report from agent runs or the assistant.
    public static func latest(_ db: Database) throws -> UsageLimits? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM (SELECT json, createdAt FROM runEvent WHERE kind = 'rate_limit_event' ORDER BY seq DESC LIMIT 1)
            UNION ALL
            SELECT * FROM (SELECT json, createdAt FROM assistantEvent WHERE kind = 'rate_limit_event' ORDER BY seq DESC LIMIT 1)
            """)
        return rows.compactMap { UsageLimits(json: $0["json"], observedAt: $0["createdAt"]) }
            .max { $0.observedAt < $1.observedAt }
    }

    /// A minimal Claude Code call that only makes it report the limits (a few tokens of Haiku).
    public static func probeArguments() -> [String] {
        ["-p", "--output-format", "stream-json", "--verbose", "--tools", "", "--strict-mcp-config",
         "--no-session-persistence", "--model", "haiku", "--max-turns", "1", "Reply with: ok"]
    }

    /// Runs the probe (blocking; seconds) in a scratch folder.
    public static func probe() throws -> UsageLimits? {
        let r = try ClaudeCLI.runSync(try ClaudeCLI.executable(), probeArguments(), env: ClaudeCLI.environment(),
                                      cwd: FileManager.default.temporaryDirectory)
        if let limits = fromStream(r.out, observedAt: LocalDate.stamp(Date())) { return limits }
        if r.status != 0 { throw ClaudistError.invalid(r.err.isEmpty ? "Claude Code exited with code \(r.status)" : r.err) }
        return nil
    }

    /// Reads the limits from a probe's stream-json output.
    public static func fromStream(_ output: String, observedAt: String) -> UsageLimits? {
        output.split(separator: "\n").reversed().lazy.compactMap { line -> UsageLimits? in
            line.contains("\"rate_limit_event\"") ? UsageLimits(json: String(line), observedAt: observedAt) : nil
        }.first
    }
}
