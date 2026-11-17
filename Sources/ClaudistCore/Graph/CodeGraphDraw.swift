import Foundation

/// `draw_graph`: a graph the agent composes itself (tasks, people, concepts, a plan…), shown
/// with the same viewer as code graphs.
public enum DrawnGraph {
    public static let maxNodes = 3000
    public static let maxEdges = 12000

    static var schema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Short title shown above the graph"],
                "nodes": [
                    "type": "array",
                    "description": "Things to show (up to \(maxNodes))",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "description": "Unique id, used by edges"],
                            "label": ["type": "string", "description": "Name shown on the graph (default: id)"],
                            "group": ["type": "string", "description": "Category; groups get colors and a legend filter"],
                            "description": ["type": "string", "description": "A sentence or two shown when the node is clicked"],
                            "link": ["type": "string", "description": "Opened on double-click: an https URL, an absolute file path, or task:<id> for a Claudist task"],
                            "line": ["type": "integer", "description": "Line in the linked file"],
                        ],
                        "required": ["id"],
                    ] as [String: Any],
                ] as [String: Any],
                "edges": [
                    "type": "array",
                    "description": "Connections between node ids",
                    "items": [
                        "type": "object",
                        "properties": [
                            "from": ["type": "string"],
                            "to": ["type": "string"],
                            "label": ["type": "string", "description": "Kind of connection, e.g. blocks, works with, part of"],
                            "directed": ["type": "boolean", "description": "Draw an arrow from → to (default true)"],
                        ],
                        "required": ["from", "to"],
                    ] as [String: Any],
                ] as [String: Any],
                "highlight": ["type": "array", "items": ["type": "string"], "description": "Node ids to emphasize"],
            ] as [String: Any],
            "required": ["title", "nodes"],
        ]
    }

    static var definition: [String: Any] {
        [
            "name": CodeGraphTools.draw,
            "description": """
                Draw an interactive graph in the chat from nodes and edges you compose: tasks and what blocks them, \
                people and organizations, concepts of a document, a plan, an architecture described in words — anything \
                that isn't code in a folder (use show_graph for that). The user can search, filter groups, click nodes \
                for details, trace paths and open links. Keep labels short; put detail in descriptions.
                """,
            "inputSchema": schema,
        ]
    }

    /// Builds the view; returns it with a summary for the model.
    public static func view(_ args: JSONValue?, id: String = newID()) throws -> (CodeGraphView, String) {
        guard let title = args?["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw ClaudistError.invalid("Give the graph a `title`")
        }
        let rawNodes = args?["nodes"]?.array ?? []
        guard !rawNodes.isEmpty else { throw ClaudistError.invalid("Give at least one node in `nodes`") }
        guard rawNodes.count <= maxNodes else { throw ClaudistError.invalid("Too many nodes (\(rawNodes.count)); the limit is \(maxNodes)") }

        var nodes: [CodeGraphView.Node] = []
        var index: [String: Int] = [:]
        var groups: [String] = []
        var duplicates: [String] = []
        let anyGroup = rawNodes.contains { ($0["group"]?.string ?? "").isEmpty == false }
        for raw in rawNodes {
            guard let nodeId = (raw["id"]?.string ?? raw["id"]?.number.map { String(Int($0)) }), !nodeId.isEmpty else { continue }
            if index[nodeId] != nil { duplicates.append(nodeId); continue }
            let group = clean(raw["group"]?.string, 80) ?? (anyGroup ? "Other" : title)
            if !groups.contains(group) { groups.append(group) }
            let label = clean(raw["label"]?.string, 120) ?? nodeId
            index[nodeId] = nodes.count
            nodes.append(.init(id: nodeId, label: label, community: groups.firstIndex(of: group), communityName: group,
                               file: nil, line: raw["line"]?.number.map { Int($0) }, kind: group, degree: 0, role: nil,
                               description: clean(raw["description"]?.string, 2000), link: clean(raw["link"]?.string, 2000)))
        }

        var edges: [CodeGraphView.Edge] = []
        var dropped: [String] = []
        for raw in (args?["edges"]?.array ?? []).prefix(maxEdges) {
            let from = raw["from"]?.string ?? "", to = raw["to"]?.string ?? ""
            guard let s = index[from], let t = index[to], s != t else {
                dropped.append("\(from)→\(to)")
                continue
            }
            edges.append(.init(s: s, t: t, relation: clean(raw["label"]?.string, 60) ?? "related", confidence: "STATED",
                               onPath: nil, directed: raw["directed"]?.bool ?? true))
            nodes[s].degree += 1
            nodes[t].degree += 1
        }
        let highlighted = (args?["highlight"]?.array ?? []).compactMap(\.string).filter { index[$0] != nil }
        for h in highlighted { nodes[index[h]!].role = "seed" }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let view = CodeGraphView(id: id, title: String(title.prefix(120)), root: "", mode: "drawn", query: nil,
                                 createdAt: stamp, builtAt: stamp,
                                 graph: .init(nodes: nodes.count, edges: edges.count, communities: groups.count),
                                 nodes: nodes, edges: edges)
        var summary = ["Shown to the user as an interactive graph “\(view.title)”: \(nodes.count) nodes, \(edges.count) links, \(groups.count) groups."]
        if !duplicates.isEmpty { summary.append("Skipped duplicate node ids: " + duplicates.prefix(10).joined(separator: ", ")) }
        if !dropped.isEmpty { summary.append("Skipped \(dropped.count) edges with unknown or identical ends: " + dropped.prefix(10).joined(separator: ", ")) }
        let isolated = nodes.filter { $0.degree == 0 }.count
        if isolated > 0 && !edges.isEmpty { summary.append("\(isolated) nodes have no links.") }
        summary.append("Don't repeat the graph in text; point out what matters in it.")
        return (view, summary.joined(separator: "\n"))
    }

    private static func clean(_ s: String?, _ max: Int) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(max))
    }
}
