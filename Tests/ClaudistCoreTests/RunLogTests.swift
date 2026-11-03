import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct RunLogTests {
    @Test func collectsSkillsAndSubagents() throws {
        let app = try AppDatabase.inMemory()
        try app.writer.write { db in
            let p = Project(name: "P")
            try p.insert(db)
            let boss = Agent(name: "Boss", folderPath: "/tmp/b")
            let helper = Agent(name: "Helper", folderPath: "/tmp/h")
            try boss.insert(db)
            try helper.insert(db)
            var parent = TaskItem(projectId: p.id, content: "Plan")
            parent.agentId = boss.id
            try parent.insert(db)
            var child = TaskItem(projectId: p.id, content: "Research")
            child.agentId = helper.id
            child.parentId = parent.id
            try child.insert(db)

            var r1 = Run(taskId: parent.id, agentId: boss.id, trigger: "schedule")
            r1.status = .done
            r1.startedAt = "2026-11-01 09:00:00"
            r1.costUsd = 0.5
            try r1.insert(db)
            func event(_ run: Run, _ kind: String, _ json: String) throws {
                var e = RunEvent(runId: run.id, kind: kind, json: json)
                try e.insert(db)
            }
            try event(r1, "assistant", #"{"message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"Skill","input":{"skill":"pdf"}},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#)
            try event(r1, "assistant", #"{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"pdf"}},{"type":"tool_use","name":"Task","input":{"subagent_type":"Explore","prompt":"x"}}]}}"#)
            try event(r1, "delegate", #"{"agent":"Helper","taskId":"x","title":"Research"}"#)
            try event(r1, "stderr", #"{"text":"warn"}"#)

            var r2 = Run(taskId: child.id, agentId: helper.id, trigger: "agent")
            r2.status = .failed
            r2.startedAt = "2026-11-01 09:01:00"
            try r2.insert(db)
            try event(r2, "assistant", #"{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"web"}}]}}"#)

            let all = try RunLog.entries(db, RunLog.Query())
            #expect(all.map(\.taskTitle) == ["Research", "Plan"])
            let plan = all[1]
            #expect(plan.skills.map(\.name) == ["pdf"] && plan.skills[0].count == 2)
            #expect(plan.delegates.map(\.name) == ["Helper"])
            #expect(plan.subagents.map(\.name) == ["Explore"])
            #expect(plan.toolCalls == 4)
            #expect(plan.agentName == "Boss")
            #expect(all[0].calledBy == "Boss")

            var q = RunLog.Query()
            q.skill = "web"
            #expect(try RunLog.entries(db, q).map(\.taskTitle) == ["Research"])
            q = RunLog.Query()
            q.agentId = boss.id
            #expect(try RunLog.entries(db, q).count == 1)
            q = RunLog.Query()
            q.status = .failed
            #expect(try RunLog.entries(db, q).map(\.taskTitle) == ["Research"])
            q = RunLog.Query()
            q.since = "2026-11-01 09:00:30"
            #expect(try RunLog.entries(db, q).count == 1)
            #expect(try RunLog.usedSkills(db) == ["pdf", "web"])
        }
    }
}
