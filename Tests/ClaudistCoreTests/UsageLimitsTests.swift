import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct UsageLimitsTests {
    static let event = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793617800,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false,"unifiedWindows":{"seven_day":{"utilization":0.19,"resetsAt":1793617200,"status":"allowed"},"five_hour":{"utilization":0.1,"resetsAt":1793617800,"status":"allowed"},"seven_day_opus":{"utilization":0.95,"resetsAt":1793617200,"status":"rejected"}}}}"#

    @Test func parsesWindows() throws {
        let u = try #require(UsageLimits(json: Self.event, observedAt: "2026-11-02 12:24"))
        #expect(u.windows.map(\.name) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(u.windows.map(\.title) == ["5-hour session", "Week", "Week (Opus)"])
        #expect(u.windows[0].utilization == 0.1)
        #expect(u.windows[0].resetsAt == Date(timeIntervalSince1970: 1793617800))
        #expect(u.worst?.name == "seven_day_opus" && u.worst?.limited == true)
        #expect(u.overageStatus == "rejected" && !u.isUsingOverage)
        #expect(UsageLimits.fromStream("{\"type\":\"system\"}\n" + Self.event + "\n{\"type\":\"result\"}", observedAt: "x")?.windows.count == 3)
    }

    @Test func latestFromRunsAndAssistant() throws {
        let app = try AppDatabase.inMemory()
        try app.writer.write { db in
            let p = Project(name: "P")
            try p.insert(db)
            let t = TaskItem(projectId: p.id, content: "t")
            try t.insert(db)
            let run = Run(taskId: t.id, agentId: nil)
            try run.insert(db)
            var e = RunEvent(runId: run.id, kind: "rate_limit_event", json: Self.event)
            e.createdAt = "2026-11-02 10:00"
            try e.insert(db)
            let chat = AssistantChat()
            try chat.insert(db)
            var a = AssistantEvent(chatId: chat.id, kind: "rate_limit_event",
                                   json: Self.event.replacingOccurrences(of: "0.19", with: "0.25"))
            a.createdAt = "2026-11-02 11:00"
            try a.insert(db)
        }
        let latest = try #require(try app.writer.read { try UsageLimits.latest($0) })
        #expect(latest.windows.first { $0.name == "seven_day" }?.utilization == 0.25)
    }
}

/// Run with: CLAUDIST_E2E=1 swift test --filter UsageProbeE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1"))
struct UsageProbeE2ETests {
    @Test(.timeLimit(.minutes(2))) func probeReportsLimits() throws {
        let limits = try #require(try UsageLimits.probe())
        print("windows:", limits.windows.map { "\($0.name) \($0.utilization) \($0.resetsAt.map(String.init(describing:)) ?? "-")" })
        #expect(!limits.windows.isEmpty)
    }
}
