import Foundation
import GRDB

/// Services built into the app (Telegram first) that agents use through Claudist's own MCP tools.
/// Credentials stay in the app (Keychain); agents get tools, never tokens, and only when the user
/// turns the integration on and grants it to the agent.
public enum Integrations {
    public struct Info: Sendable, Identifiable, Hashable {
        public var id: String
        public var title: String
        public var summary: String
        public var icon: String
    }

    public static let catalog: [Info] = [
        Info(id: Telegram.id, title: "Telegram",
             summary: "Your Telegram account: agents read the chats you open to them, and write where you allow it.",
             icon: "paperplane.fill"),
    ]

    public static func info(_ id: String) -> Info? { catalog.first { $0.id == id } }

    /// Integrations that are on and granted to the agent.
    public static func granted(_ db: Database, agentId: ID) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT a.integrationId FROM agentIntegration a JOIN integration i ON i.id = a.integrationId
             WHERE a.agentId = ? AND i.enabled = 1 ORDER BY a.integrationId
            """, arguments: [agentId])
    }

    public static func isEnabled(_ db: Database, _ id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT enabled FROM integration WHERE id = ?", arguments: [id]) ?? false
    }

    public static func setEnabled(_ db: Database, _ id: String, _ on: Bool) throws {
        try db.execute(sql: """
            INSERT INTO integration (id, enabled) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled
            """, arguments: [id, on])
    }

    public static func setGranted(_ db: Database, agentId: ID, _ id: String, _ on: Bool) throws {
        if on {
            try db.execute(sql: "INSERT OR IGNORE INTO agentIntegration (agentId, integrationId) VALUES (?, ?)", arguments: [agentId, id])
        } else {
            try db.execute(sql: "DELETE FROM agentIntegration WHERE agentId = ? AND integrationId = ?", arguments: [agentId, id])
        }
    }

    public static func agents(_ db: Database, _ id: String) throws -> Set<ID> {
        Set(try String.fetchAll(db, sql: "SELECT agentId FROM agentIntegration WHERE integrationId = ?", arguments: [id]))
    }

    /// Tool names an agent may call, unqualified.
    public static func toolNames(_ granted: [String]) -> [String] {
        granted.contains(Telegram.id) ? Telegram.toolNames : []
    }

    public static func promptSection(_ granted: [String]) -> String? {
        granted.contains(Telegram.id) ? Telegram.promptSection : nil
    }

    public static func toolDefinitions(_ granted: [String]) -> [[String: Any]] {
        granted.contains(Telegram.id) ? Telegram.toolDefinitions : []
    }

    public static func qualified(_ tool: String) -> String { "mcp__\(Delegation.serverName)__\(tool)" }
}
