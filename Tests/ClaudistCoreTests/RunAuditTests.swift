import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct RunAuditTests {
    @Test func collectsWhatRunsTouched() throws {
        let app = try AppDatabase.inMemory()
        let (parent, child) = try app.writer.write { db -> (TaskItem, TaskItem) in
            let p = Project(name: "P")
            try p.insert(db)
            let dev = Agent(name: "Dev", folderPath: "/agents/dev")
            let rev = Agent(name: "Reviewer", folderPath: "/agents/rev")
            try dev.insert(db)
            try rev.insert(db)
            try Secret(name: "GH_TOKEN").insert(db)
            var parent = TaskItem(projectId: p.id, content: "Build")
            parent.agentId = dev.id
            try parent.insert(db)
            var child = TaskItem(projectId: p.id, content: "Review")
            child.parentId = parent.id
            child.agentId = rev.id
            child.source = "agent"
            try child.insert(db)

            let run = Run(taskId: parent.id, agentId: dev.id)
            try run.insert(db)
            var access = RunAccess(agent: "Dev", folder: "/agents/dev", isolation: "Docker")
            access.secrets = [.init(name: "GH_TOKEN", access: nil)]
            access.storages = [.init(name: "/data/repo", access: "rw")]
            func event(_ runId: ID, _ kind: String, _ json: String) throws {
                var e = RunEvent(runId: runId, kind: kind, json: json)
                try e.insert(db)
            }
            try event(run.id, RunAccess.eventKind, String(decoding: try JSONEncoder().encode(access), as: UTF8.self))
            func use(_ id: String, _ name: String, _ input: String) -> String {
                #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}"#
            }
            try event(run.id, "assistant", #"{"message":{"content":[{"type":"text","text":"hi"},"#
                      + use("t1", "Read", #"{"file_path":"/data/repo/main.go"}"#) + ","
                      + use("t2", "Read", #"{"file_path":"/Users/x/.ssh/id_rsa"}"#) + ","
                      + use("t3", "Bash", #"{"command":"curl -H \"Authorization: $GH_TOKEN\" https://api.github.com"}"#) + ","
                      + use("t4", "mcp__claudist__db_query", #"{"database":"crm","sql":"SELECT 1"}"#) + ","
                      + use("t5", "Skill", #"{"skill":"pdf"}"#) + ","
                      + use("t6", "WebFetch", #"{"url":"https://example.com"}"#) + "]}}")
            try event(run.id, "user", #"{"message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"token ‹GH_TOKEN›"},{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"no"}]}}"#)
            try event(run.id, "delegate", #"{"agent":"Reviewer","taskId":"\#(child.id)","title":"Review"}"#)
            try event(run.id, "permission", #"{"request_id":"r1","tool":"Bash","description":"rm -rf build","input":"{}"}"#)
            try event(run.id, "permission/answer", #"{"request_id":"r1","allow":false}"#)

            let childRun = Run(taskId: child.id, agentId: rev.id)
            try childRun.insert(db)
            try event(childRun.id, "assistant", #"{"message":{"content":["# + use("c1", "Edit", #"{"file_path":"/agents/rev/notes.md"}"#) + "]}}")
            return (parent, child)
        }

        let (entries, access) = try app.writer.read { try RunAudit.entries($0, taskId: parent.id) }
        func find(_ c: AuditEntry.Category, _ target: String) -> AuditEntry? { entries.first { $0.category == c && $0.target == target } }
        #expect(access.count == 1)
        #expect(find(.file, "/data/repo/main.go")?.failed == true)
        #expect(find(.file, "/data/repo/main.go")?.warning == nil)
        #expect(find(.file, "/Users/x/.ssh/id_rsa")?.warning != nil)
        #expect(entries.contains { $0.category == .secret && $0.target == "GH_TOKEN" && $0.action == "used in Bash" })
        #expect(entries.contains { $0.category == .secret && $0.action == "value in output" && $0.warning != nil })
        #expect(find(.database, "crm")?.detail == "SELECT 1")
        #expect(find(.skill, "pdf") != nil)
        #expect(find(.web, "https://example.com") != nil)
        #expect(find(.subagent, "Reviewer")?.linkedTaskId == child.id)
        #expect(entries.first { $0.category == .permission }?.failed == true)
        let childEdit = try #require(find(.file, "/agents/rev/notes.md"))
        #expect(childEdit.agent == "Reviewer" && childEdit.action == "edited")

        let own = try app.writer.read { try RunAudit.entries($0, taskId: parent.id, subtasks: false) }.entries
        #expect(!own.contains { $0.agent == "Reviewer" })
    }

    @Test func secretReferences() {
        #expect(RunAudit.references("echo $GH_TOKEN", "GH_TOKEN"))
        #expect(RunAudit.references("x=${GH_TOKEN}", "GH_TOKEN"))
        #expect(!RunAudit.references("echo $GH_TOKEN_OLD", "GH_TOKEN"))
        #expect(!RunAudit.references("echo GH_TOKEN", "GH_TOKEN"))
    }
}

/// Run with: CLAUDIST_AUDIT_DB=<copy of db.sqlite> swift test --filter RunAuditRealData
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_AUDIT_DB"] != nil))
struct RunAuditRealDataTests {
    @Test func auditsEveryTask() throws {
        let queue = try DatabaseQueue(path: ProcessInfo.processInfo.environment["CLAUDIST_AUDIT_DB"]!)
        let tasks = try queue.read { try String.fetchAll($0, sql: "SELECT DISTINCT taskId FROM run") }
        var total = 0
        for id in tasks {
            let started = Date()
            let (entries, _) = try queue.read { try RunAudit.entries($0, taskId: id) }
            total += entries.count
            let title = try queue.read { try String.fetchOne($0, sql: "SELECT content FROM task WHERE id = ?", arguments: [id]) } ?? "?"
            var counts: [String: Int] = [:]
            for e in entries { counts[e.category.rawValue, default: 0] += 1 }
            print(String(format: "%.3fs", Date().timeIntervalSince(started)), title.prefix(40), counts.sorted { $0.key < $1.key },
                  "warnings:", entries.filter { $0.warning != nil }.map { "\($0.action) \($0.target.prefix(60))" }.prefix(3))
        }
        #expect(total > 0)
    }
}
