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

        m.registerMigration("v6-attention") { db in
            // Set when an agent can't continue without the user's decision.
            try db.alter(table: "task") { t in
                t.add(column: "attention", .text)
                t.add(column: "attentionOptions", .text)
                t.add(column: "attentionAt", .text)
            }
        }

        m.registerMigration("v7-databases") { db in
            // SQLite databases agents work with, linked to agents and tasks with an access level.
            try db.create(table: "userDatabase") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("path", .text).notNull()
                t.column("managed", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .text).notNull()
            }
            try db.create(table: "agentDatabase") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("databaseId", .text).notNull().indexed().references("userDatabase", onDelete: .cascade)
                t.column("access", .text).notNull().defaults(to: "ro")
                t.primaryKey(["agentId", "databaseId"])
            }
            try db.create(table: "taskDatabase") { t in
                t.column("taskId", .text).notNull().references("task", onDelete: .cascade)
                t.column("databaseId", .text).notNull().indexed().references("userDatabase", onDelete: .cascade)
                t.column("access", .text).notNull().defaults(to: "ro")
                t.primaryKey(["taskId", "databaseId"])
            }
        }

        m.registerMigration("v8-assistant") { db in
            // Conversations with the built-in assistant.
            try db.create(table: "assistantChat") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("sessionId", .text)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(table: "assistantEvent") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("chatId", .text).notNull().indexed().references("assistantChat", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("json", .text).notNull()
                t.column("createdAt", .text).notNull()
            }
        }

        m.registerMigration("v9-run-on-host") { db in
            // Tasks that need the host (disk, apps, system state) skip the isolation engine.
            try db.alter(table: "task") { t in
                t.add(column: "runOnHost", .boolean).notNull().defaults(to: false)
            }
        }

        m.registerMigration("v10-dashboards") { db in
            // Charts over the user's databases, made by the user, the assistant or agents.
            try db.create(table: "dashboard") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("itemOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
            }
            try db.create(table: "dashboardChart") { t in
                t.primaryKey("id", .text)
                t.column("dashboardId", .text).notNull().indexed().references("dashboard", onDelete: .cascade)
                t.column("databaseId", .text).notNull().indexed().references("userDatabase", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("sql", .text).notNull()
                t.column("wide", .boolean).notNull().defaults(to: false)
                t.column("itemOrder", .integer).notNull().defaults(to: 0)
                t.column("author", .text).notNull().defaults(to: "user")
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
        }

        m.registerMigration("v11-access-requests") { db in
            // Agents asking the user for folders or commands they lack.
            try db.create(table: "accessRequest") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed().references("task", onDelete: .cascade)
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("target", .text).notNull()
                t.column("access", .text).notNull().defaults(to: "ro")
                t.column("command", .text)
                t.column("reason", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("createdAt", .text).notNull()
                t.column("decidedAt", .text)
            }
        }

        m.registerMigration("v12-failed-runs") { db in
            // A failed run the user has seen and dismissed from "Failed".
            try db.alter(table: "run") { t in
                t.add(column: "dismissed", .boolean).notNull().defaults(to: false)
            }
        }

        m.registerMigration("v13-prompt-templates") { db in
            // Shared instructions merged into agents' system prompts.
            try db.create(table: "promptTemplate") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("content", .text).notNull().defaults(to: "")
                t.column("forAllAgents", .boolean).notNull().defaults(to: false)
                t.column("itemOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(table: "agentPromptTemplate") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("templateId", .text).notNull().indexed().references("promptTemplate", onDelete: .cascade)
                t.primaryKey(["agentId", "templateId"])
            }
        }

        m.registerMigration("v14-notes") { db in
            // Agents' access to the user's notes (none = NULL).
            try db.alter(table: "agent") { t in
                t.add(column: "notesAccess", .text).defaults(to: "rw")
            }
        }

        m.registerMigration("v15-reviewed-runs") { db in
            // Finished runs the user hasn't looked at; earlier runs count as seen.
            try db.alter(table: "run") { t in
                t.add(column: "reviewed", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE run SET reviewed = 1")
        }

        m.registerMigration("v16-integrations") { db in
            // Built-in integrations: on/off and a poll cursor; credentials live in the Keychain.
            try db.create(table: "integration") { t in
                t.primaryKey("id", .text)
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("cursor", .integer)
            }
            try db.create(table: "agentIntegration") { t in
                t.column("agentId", .text).notNull().references("agent", onDelete: .cascade)
                t.column("integrationId", .text).notNull().indexed()
                t.primaryKey(["agentId", "integrationId"])
            }
            try db.create(table: "telegramChat") { t in
                t.primaryKey("id", .integer)
                t.column("title", .text).notNull()
                t.column("type", .text).notNull()
                t.column("username", .text)
                t.column("allowed", .boolean).notNull().defaults(to: false)
                t.column("lastAt", .text)
            }
            try db.create(table: "telegramMessage") { t in
                t.column("chatId", .integer).notNull().references("telegramChat", onDelete: .cascade)
                t.column("messageId", .integer).notNull()
                t.column("sender", .text).notNull()
                t.column("text", .text).notNull()
                t.column("date", .text).notNull()
                t.column("outgoing", .boolean).notNull().defaults(to: false)
                t.column("replyTo", .integer)
                t.primaryKey(["chatId", "messageId"])
            }
        }

        m.registerMigration("v17-telegram-account") { db in
            // The bot gave way to the user's own account: chats carry per-chat access, messages are read live.
            try db.drop(table: "telegramMessage")
            try db.drop(table: "telegramChat")
            try db.create(table: "telegramChat") { t in
                t.primaryKey("id", .integer)
                t.column("title", .text).notNull()
                t.column("type", .text).notNull()
                t.column("access", .text)
                t.column("position", .integer).notNull().defaults(to: 0)
            }
        }

        m.registerMigration("v18-recordings") { db in
            try db.create(table: "recording") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .text).notNull()
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("sourceApp", .text)
                t.column("micFile", .text)
                t.column("systemFile", .text)
                t.column("status", .text).notNull()
                t.column("error", .text)
                t.column("transcript", .text)
                t.column("notePath", .text)
                t.column("model", .text)
            }
        }

        m.registerMigration("v19-claude-accounts") { db in
            try db.create(table: "claudeAccount") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("itemOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
            }
            try db.alter(table: "agent") { t in t.add(column: "accountId", .text) }
            try db.alter(table: "run") { t in t.add(column: "accountId", .text) }
        }
        m.registerMigration("v20-task-isolation") { db in
            try db.alter(table: "task") { t in t.add(column: "isolation", .text) }
        }
        m.registerMigration("v21-task-search") { db in
            // Full-text index of task titles and descriptions, kept in sync by triggers.
            try db.create(virtualTable: TaskSearch.table, using: FTS5()) { t in
                t.synchronize(withTable: "task")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("content")
                t.column("description")
            }
        }

        m.registerMigration("v22-task-flag") { db in
            try db.alter(table: "task") { t in t.add(column: "isFlagged", .boolean).notNull().defaults(to: false) }
            // A ready filter for them, unless the user already has one by that name.
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM filter WHERE name = 'Flagged' COLLATE NOCASE)") ?? false
            if !exists {
                let order = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(itemOrder), -1) + 1 FROM filter") ?? 0
                try db.execute(sql: """
                    INSERT INTO filter (id, name, query, color, isFavorite, viewStyle, groupBy, itemOrder)
                    VALUES (?, 'Flagged', 'flagged', 'orange', 1, 'list', 'none', ?)
                    """, arguments: [newID(), order])
            }
        }

        m.registerMigration("v23-mini-apps") { db in
            // Client-side apps made in the App Builder, and the builder's conversations.
            try db.create(table: "miniApp") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "")
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("offline", .boolean).notNull().defaults(to: true)
                t.column("network", .boolean).notNull().defaults(to: false)
                t.column("networkHosts", .text).notNull().defaults(to: "")
                t.column("itemOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(table: "appBuilderChat") { t in
                t.primaryKey("id", .text)
                t.column("appId", .text).notNull().indexed().references("miniApp", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("accountId", .text).notNull()
                t.column("model", .text).notNull().defaults(to: "")
                t.column("sessionId", .text)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(table: "appBuilderEvent") { t in
                t.autoIncrementedPrimaryKey("seq")
                t.column("chatId", .text).notNull().indexed().references("appBuilderChat", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("json", .text).notNull()
                t.column("createdAt", .text).notNull()
            }
        }

        m.registerMigration("v24-task-lock") { db in
            // Tasks locked with the master password.
            try TaskVault.migrate(db)
        }

        return m
    }
}
