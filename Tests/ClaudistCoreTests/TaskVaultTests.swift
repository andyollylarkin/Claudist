import Foundation
import GRDB
import Testing
@testable import ClaudistCore

/// The vault's key is process-wide, so these tests run one at a time.
@Suite(.serialized)
struct TaskVaultTests {
    let db: AppDatabase
    let task: TaskItem

    init() throws {
        TaskVault.close()
        db = try AppDatabase.inMemory()
        var t = TaskItem(projectId: "", content: "Bank access")
        t.description = "PIN is 4321"
        task = try db.writer.write { db in
            let p = Project(name: "Private")
            try p.insert(db)
            t.projectId = p.id
            try t.insert(db)
            try Comment(taskId: t.id, content: "Card ends in 0042").insert(db)
            return t
        }
    }

    private func rawDescription() throws -> String {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT description FROM task WHERE id = ?", arguments: [task.id])! }
    }

    private func rawComment() throws -> String {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT content FROM comment WHERE taskId = ?", arguments: [task.id])! }
    }

    private func setUpAndLock() throws {
        try db.writer.write { db in
            try TaskVault.configure(db, password: "correct horse", rounds: 1000)
            try TaskVault.lock(db, taskId: task.id)
        }
    }

    @Test func lockingEncryptsDescriptionAndComments() throws {
        try setUpAndLock()
        #expect(TaskVault.isSealed(try rawDescription()))
        #expect(!(try rawDescription()).contains("4321"))
        #expect(TaskVault.isSealed(try rawComment()))

        // Open vault: records read as plain text.
        let open = try db.writer.read { try TaskItem.fetchOne($0, key: task.id)! }
        #expect(open.description == "PIN is 4321")
        #expect(open.isLocked && !open.isSealed)
        #expect(try db.writer.read { try Comment.fetchOne($0)!.content } == "Card ends in 0042")
        TaskVault.close()
    }

    @Test func closedVaultShowsOnlyCiphertextAndKeepsIt() throws {
        try setUpAndLock()
        let sealed = try rawDescription()
        TaskVault.close()

        var t = try db.writer.read { try TaskItem.fetchOne($0, key: task.id)! }
        #expect(t.isSealed)
        #expect(t.content == "Bank access")
        // Changing something else keeps the ciphertext intact.
        t.priority = 1
        try db.writer.write { try t.update($0) }
        #expect(try rawDescription() == sealed)

        // New text can't be written without the password.
        t.description = "new secret"
        #expect(throws: TaskVault.VaultError.closed) { try db.writer.write { try t.update($0) } }
        #expect(throws: TaskVault.VaultError.closed) {
            try db.writer.write { try Comment.make($0, taskId: task.id, content: "more").insert($0) }
        }
    }

    @Test func triggersRefusePlainTextInLockedTasks() throws {
        try setUpAndLock()
        #expect(throws: DatabaseError.self) {
            try db.writer.write { try $0.execute(sql: "UPDATE task SET description = 'leak' WHERE id = ?", arguments: [task.id]) }
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { try Comment(taskId: task.id, content: "leak").insert($0) }
        }
        TaskVault.close()
    }

    @Test func passwordOpensAndChanges() throws {
        try setUpAndLock()
        TaskVault.close()
        #expect(throws: TaskVault.VaultError.wrongPassword) { try db.writer.read { try TaskVault.open($0, password: "nope") } }
        #expect(!TaskVault.isOpen)
        try db.writer.read { try TaskVault.open($0, password: "correct horse") }
        #expect(TaskVault.isOpen)

        try db.writer.write { try TaskVault.changePassword($0, old: "correct horse", new: "battery staple", rounds: 1000) }
        TaskVault.close()
        #expect(throws: TaskVault.VaultError.wrongPassword) { try db.writer.read { try TaskVault.open($0, password: "correct horse") } }
        try db.writer.read { try TaskVault.open($0, password: "battery staple") }
        #expect(try db.writer.read { try TaskItem.fetchOne($0, key: task.id)!.description } == "PIN is 4321")
        TaskVault.close()
    }

    @Test func removingTheLockRestoresPlainText() throws {
        try setUpAndLock()
        try db.writer.write { try TaskVault.unlock($0, taskId: task.id) }
        #expect(try rawDescription() == "PIN is 4321")
        #expect(try rawComment() == "Card ends in 0042")
        TaskVault.close()
        #expect(try db.writer.read { try TaskItem.fetchOne($0, key: task.id)!.isLocked } == false)
    }

    @Test func assistantSeesLockedTextOnlyWhileOpen() throws {
        try setUpAndLock()
        let open = try db.writer.read { try AssistantTools.getTask($0, id: task.id) }
        #expect(open.contains("PIN is 4321"))
        TaskVault.close()
        let closed = try db.writer.read { try AssistantTools.getTask($0, id: task.id) }
        #expect(!closed.contains("4321"))
        #expect(!closed.contains("0042"))
        #expect(!closed.contains(TaskVault.prefix))
        #expect(closed.contains("master password"))
    }

    @Test func lockingNeedsAPassword() throws {
        #expect(throws: TaskVault.VaultError.notConfigured) { try db.writer.write { try TaskVault.lock($0, taskId: task.id) } }
        #expect(throws: TaskVault.VaultError.weakPassword) { try db.writer.write { try TaskVault.configure($0, password: "123") } }
    }
}
