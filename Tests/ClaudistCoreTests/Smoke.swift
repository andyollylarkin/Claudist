import Testing
@testable import ClaudistCore

@Test func migrates() throws {
    let db = try AppDatabase.inMemory()
    try db.writer.write { db in
        let p = Project(name: "Work")
        try p.insert(db)
        try TaskItem(projectId: p.id, content: "x").insert(db)
    }
}
