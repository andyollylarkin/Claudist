import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct TaskReferencesTests {
    @Test func queryAtTheEnd() {
        #expect(TaskReferences.query(in: "see #") == "")
        #expect(TaskReferences.query(in: "see #депл") == "депл")
        #expect(TaskReferences.query(in: "#deploy prod") == "deploy prod")
        #expect(TaskReferences.query(in: "issue#12") == nil)
        #expect(TaskReferences.query(in: "#Deploy prod ") == nil)
        #expect(TaskReferences.query(in: "see # x") == nil)
        #expect(TaskReferences.query(in: "#a\nb") == nil)
        #expect(TaskReferences.complete("look at #dep", title: "Deploy prod") == "look at #Deploy prod ")
    }

    @Test func expandsPickedTasksWithSummaries() throws {
        let db = try AppDatabase.inMemory()
        let p = Project(name: "Gmoon")
        var other = TaskItem(projectId: p.id, content: "Deploy prod")
        other.description = "Update the addresses"
        let current = TaskItem(projectId: p.id, content: "Current")
        var run = Run(taskId: other.id, agentId: nil)
        run.status = .done
        try db.writer.write { db in
            try p.insert(db)
            try other.insert(db)
            try current.insert(db)
            try run.insert(db)
            var e = RunEvent(runId: run.id, kind: "result/success", json: #"{"result":"Deployed v2"}"#)
            try e.insert(db)
        }
        let found = try db.writer.read { try TaskReferences.suggestions($0, query: "dep pro", excluding: current.id) }
        #expect(found.map(\.id) == [other.id])
        #expect(try db.writer.read { try TaskReferences.suggestions($0, query: "", excluding: current.id) }.map(\.id) == [other.id])

        let text = try db.writer.read {
            try TaskReferences.expand($0, text: "Same as #Deploy prod please", picked: [("Deploy prod", other.id), ("Gone", current.id)])
        }
        #expect(TaskReferences.visible(text) == "Same as [#Deploy prod](claudist-task:\(other.id)) please")
        #expect(text.contains("project Gmoon"))
        #expect(text.contains("Update the addresses"))
        #expect(text.contains("Deployed v2"))
        #expect(!text.contains("Current"))
        #expect(TaskReferences.taskId(URL(string: TaskReferences.url(other.id))!) == other.id)
    }
}
