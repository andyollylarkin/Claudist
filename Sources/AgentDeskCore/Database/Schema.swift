import Foundation
import GRDB

/// Database schema. All ids are UUID strings.
///
/// Dates that take part in filters are stored as local calendar strings so that
/// `today`, `overdue` and friends compare lexicographically in SQL:
/// - `task.dueDate`  — "yyyy-MM-dd" (local), NULL when the task has no date
/// - `task.dueTime`  — "HH:mm" (local), NULL when the due date has no time
/// - `task.deadline` — "yyyy-MM-dd" (local)
/// - `task.createdAt`, `task.completedAt` — "yyyy-MM-dd HH:mm" (local)
/// Priority is stored the way it is displayed: 1 = p1 (highest) … 4 = p4 (none).
public enum Schema {
    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("color", .text).notNull().defaults(to: "gray")
                t.column("parentId", .text).references("project", onDelete: .cascade)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("childOrder", .integer).notNull().defaults(to: 0)
                t.column("viewStyle", .text).notNull().defaults(to: "list")
                t.column("createdAt", .text).notNull()
            }

            try db.create(table: "section") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull().indexed().references("project", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("sectionOrder", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "label") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique(onConflict: .abort).collate(.nocase)
                t.column("color", .text).notNull().defaults(to: "gray")
            }

            try db.create(table: "agent") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique().collate(.nocase)
                t.column("description", .text).notNull().defaults(to: "")
                t.column("prompt", .text).notNull().defaults(to: "")
                t.column("model", .text)
                t.column("tools", .text)
                t.column("folderPath", .text).notNull()
                t.column("permissionMode", .text).notNull().defaults(to: "manual")
                t.column("allowRules", .text).notNull().defaults(to: "[]")
                t.column("denyRules", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .text).notNull()
            }

            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull().indexed().references("project", onDelete: .cascade)
                t.column("sectionId", .text).indexed().references("section", onDelete: .setNull)
                t.column("parentId", .text).indexed().references("task", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("priority", .integer).notNull().defaults(to: 4)
                t.column("dueDate", .text).indexed()
                t.column("dueTime", .text)
                t.column("dueString", .text)
                t.column("isRecurring", .boolean).notNull().defaults(to: false)
                t.column("deadline", .text)
                t.column("durationMinutes", .integer)
                t.column("agentId", .text).indexed().references("agent", onDelete: .setNull)
                t.column("isCompleted", .boolean).notNull().defaults(to: false)
                t.column("completedAt", .text)
                t.column("childOrder", .integer).notNull().defaults(to: 0)
                t.column("source", .text)
                t.column("externalId", .text)
                t.column("createdAt", .text).notNull()
            }

            try db.create(table: "taskLabel") { t in
                t.column("taskId", .text).notNull().references("task", onDelete: .cascade)
                t.column("labelId", .text).notNull().indexed().references("label", onDelete: .cascade)
                t.primaryKey(["taskId", "labelId"])
            }

            try db.create(table: "comment") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed().references("task", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "user")
                t.column("createdAt", .text).notNull()
            }

            try db.create(table: "storage") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("path", .text).notNull().unique()
            }

            try db.create(table: "agentStorage") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("storageId", .text).notNull().references("storage", onDelete: .cascade)
                t.column("access", .text).notNull().defaults(to: "ro")
                t.primaryKey(["agentId", "storageId"])
            }

            try db.create(table: "agentSkill") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("skillName", .text).notNull()
                t.primaryKey(["agentId", "skillName"])
            }

            try db.create(table: "run") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed().references("task", onDelete: .cascade)
                t.column("agentId", .text).references("agent", onDelete: .setNull)
                t.column("sessionId", .text)
                t.column("status", .text).notNull()
                t.column("trigger", .text).notNull().defaults(to: "manual")
                t.column("startedAt", .text).notNull()
                t.column("endedAt", .text)
                t.column("costUsd", .double)
                t.column("inputTokens", .integer)
                t.column("outputTokens", .integer)
                t.column("error", .text)
            }

            try db.create(table: "runEvent") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("runId", .text).notNull().indexed().references("run", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("json", .text).notNull()
                t.column("createdAt", .text).notNull()
            }

            try db.create(table: "filter") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("query", .text).notNull()
                t.column("color", .text).notNull().defaults(to: "gray")
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("viewStyle", .text).notNull().defaults(to: "list")
                t.column("groupBy", .text).notNull().defaults(to: "none")
                t.column("itemOrder", .integer).notNull().defaults(to: 0)
            }
        }

        m.registerMigration("v2-secrets") { db in
            // Values live in the Keychain; the database only knows names and links.
            try db.create(table: "secret") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(table: "agentSecret") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("secretId", .text).notNull().indexed().references("secret", onDelete: .cascade)
                t.primaryKey(["agentId", "secretId"])
            }
            try db.create(table: "skillSecret") { t in
                t.column("skillName", .text).notNull()
                t.column("secretId", .text).notNull().indexed().references("secret", onDelete: .cascade)
                t.primaryKey(["skillName", "secretId"])
            }
        }

        m.registerMigration("v3-delegates") { db in
            // Which agents an agent may call as sub-agents.
            try db.create(table: "agentDelegate") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("delegateId", .text).notNull().indexed().references("agent", onDelete: .cascade)
                t.primaryKey(["agentId", "delegateId"])
            }
        }

        m.registerMigration("v4-attachments") { db in
            // Host files and folders referenced by a task; nothing is copied.
            try db.create(table: "taskAttachment") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed().references("task", onDelete: .cascade)
                t.column("path", .text).notNull()
                t.column("isDirectory", .boolean).notNull().defaults(to: false)
                t.column("writable", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .text).notNull()
                t.uniqueKey(["taskId", "path"])
            }
        }

        m.registerMigration("v5-secret-files") { db in
            // Secrets that tools need as a file (SSH keys, certificates).
            try db.alter(table: "secret") { t in
                t.add(column: "asFile", .boolean).notNull().defaults(to: false)
            }
        }

        return m
    }
}
