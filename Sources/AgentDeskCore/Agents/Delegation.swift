import Foundation
import GRDB

/// `agentId` may call `delegateId` as a sub-agent.
public struct AgentDelegate: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var agentId: ID
    public var delegateId: ID
    public init(agentId: ID, delegateId: ID) { self.agentId = agentId; self.delegateId = delegateId }
}

/// Sub-agents run as full AgentDesk agents (own folder, memory, skills, secrets), not as
/// Claude Code in-process subagents. The parent sees one tool, `mcp__agentdesk__delegate`,
/// served by the app over the stream-json control channel (an "sdk" MCP server).
/// A call creates a sub-task assigned to the delegate, runs it, and returns its final answer.
public enum Delegation {
    public static let serverName = "agentdesk"
    public static let toolName = "delegate"
    public static var qualifiedToolName: String { "mcp__\(serverName)__\(toolName)" }
    /// Longest allowed chain of agents calling agents.
    public static let maxDepth = 4

    public static func delegates(_ db: Database, of agentId: ID) throws -> [Agent] {
        try Agent.fetchAll(db, sql: """
            SELECT a.* FROM agent a JOIN agentDelegate d ON d.delegateId = a.id
            WHERE d.agentId = ? ORDER BY a.name
            """, arguments: [agentId])
    }

    /// `--mcp-config` value declaring the app-served server.
    public static var mcpConfig: String {
        #"{"mcpServers":{"\#(serverName)":{"type":"sdk","name":"\#(serverName)"}}}"#
    }

    public static func toolDefinition(_ delegates: [Agent]) -> [String: Any] {
        [
            "name": toolName,
            "description": """
                Hand a task to another agent and wait for its final answer. The agent works in its own \
                workspace with its own memory, skills and secrets, so include all context it needs in `task`. \
                Available agents:
                """ + "\n" + delegates.map { "- \($0.name): \($0.description.isEmpty ? "no description" : $0.description)" }
                .joined(separator: "\n"),
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent": ["type": "string", "enum": delegates.map(\.name), "description": "Agent to call"],
                    "title": ["type": "string", "description": "Short task title (shown as a sub-task)"],
                    "task": ["type": "string", "description": "Complete instructions and context for the agent"],
                ],
                "required": ["agent", "task"],
            ] as [String: Any],
        ]
    }

    /// Text appended to the parent's system prompt.
    public static func promptSection(_ delegates: [Agent]) -> String {
        """
        ## Other agents
        You can delegate work with the `\(qualifiedToolName)` tool. Each call runs the chosen agent on a new sub-task \
        and returns its final answer. Agents you can call:
        \(delegates.map { "- \($0.name)" + ($0.description.isEmpty ? "" : ": \($0.description)") }.joined(separator: "\n"))
        """
    }

    /// Agents already working up the sub-task chain of `taskId` (including its own agent).
    /// Used to refuse cycles like A → B → A.
    public static func agentChain(_ db: Database, taskId: ID) throws -> [ID] {
        try String.fetchAll(db, sql: """
            WITH RECURSIVE chain(id, parentId, agentId, depth) AS (
                SELECT id, parentId, agentId, 0 FROM task WHERE id = ?
                UNION ALL
                SELECT t.id, t.parentId, t.agentId, c.depth + 1 FROM task t JOIN chain c ON t.id = c.parentId
                WHERE c.depth < 50
            )
            SELECT agentId FROM chain WHERE agentId IS NOT NULL ORDER BY depth
            """, arguments: [taskId])
    }

    public enum CallError: LocalizedError {
        case notAllowed(String)
        case cycle(String)
        case tooDeep

        public var errorDescription: String? {
            switch self {
            case .notAllowed(let name): "Agent \(name) is not in the list of agents you may call."
            case .cycle(let name): "Agent \(name) is already working on this task chain; calling it again would loop."
            case .tooDeep: "Too many nested agent calls (max \(Delegation.maxDepth))."
            }
        }
    }

    /// Resolves and validates a delegate call from the agent working on `parentTaskId`.
    public static func validate(_ db: Database, callerId: ID, parentTaskId: ID, agentName: String) throws -> Agent {
        guard let target = try delegates(db, of: callerId)
            .first(where: { $0.name.caseInsensitiveCompare(agentName) == .orderedSame })
        else { throw CallError.notAllowed(agentName) }
        let chain = try agentChain(db, taskId: parentTaskId)
        if chain.contains(target.id) { throw CallError.cycle(target.name) }
        if chain.count >= maxDepth { throw CallError.tooDeep }
        return target
    }
}
