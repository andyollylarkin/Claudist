import Foundation
import GRDB

/// Shared instructions for agents: written once, merged into the system prompt of every agent that
/// uses them (or of all agents). The text may use `{{agent}}`, `{{description}}`, `{{folder}}` and `{{date}}`.
public struct PromptTemplate: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: ID = newID()
    public var name: String
    public var description = ""
    public var content = ""
    /// Every agent gets it, including agents added later.
    public var forAllAgents = false
    /// Order in the merged prompt.
    public var itemOrder = 0
    public var createdAt = LocalDate.stamp(Date())
    public var updatedAt = LocalDate.stamp(Date())

    public init(name: String, content: String = "") {
        self.name = name
        self.content = content
    }
}

public struct AgentPromptTemplate: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var agentId: ID
    public var templateId: ID
    public init(agentId: ID, templateId: ID) { self.agentId = agentId; self.templateId = templateId }
}

public enum PromptTemplates {
    /// Templates an agent's runs receive, in merge order.
    public static func resolve(_ db: Database, agentId: ID) throws -> [PromptTemplate] {
        try PromptTemplate.fetchAll(db, sql: """
            SELECT * FROM promptTemplate p
             WHERE p.forAllAgents = 1 OR p.id IN (SELECT templateId FROM agentPromptTemplate WHERE agentId = ?)
             ORDER BY p.itemOrder, p.name
            """, arguments: [agentId])
    }

    /// The agent's system prompt: shared templates first, then the agent's own prompt
    /// (more specific, so it comes last and wins where they disagree).
    public static func merge(_ templates: [PromptTemplate], into agent: Agent, now: Date = Date()) -> String {
        let shared = templates.map { fill($0.content, agent: agent, now: now).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (shared + [agent.prompt.trimmingCharacters(in: .whitespacesAndNewlines)])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func fill(_ text: String, agent: Agent, now: Date = Date()) -> String {
        guard text.contains("{{") else { return text }
        return text
            .replacingOccurrences(of: "{{agent}}", with: agent.name)
            .replacingOccurrences(of: "{{description}}", with: agent.description)
            .replacingOccurrences(of: "{{folder}}", with: agent.folderPath)
            .replacingOccurrences(of: "{{date}}", with: LocalDate.day(now))
    }
}
