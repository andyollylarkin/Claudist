import Foundation

/// A loaded graph.json, indexed for traversal.
public struct CodeGraphData: Sendable {
    public struct Node: Sendable {
        public var id: String
        public var label: String
        public var community: Int?
        public var communityName: String?
        /// Relative to the graph's root folder; nil for things outside it (library types).
        public var file: String?
        public var line: Int?
        public var kind: String
    }

    public struct Edge: Sendable {
        public var source: Int
        public var target: Int
        public var relation: String
        public var confidence: String
    }

    public var root: String
    public var builtAt: Date
    public var nodes: [Node] = []
    public var edges: [Edge] = []
    public var index: [String: Int] = [:]
    /// Edge indices leaving / entering each node.
    public var outgoing: [[Int]] = []
    public var incoming: [[Int]] = []

    public var communityCount: Int { Set(nodes.compactMap(\.community)).count }

    public func degree(_ n: Int) -> Int { outgoing[n].count + incoming[n].count }

    public static func load(_ url: URL, root: String) throws -> CodeGraphData {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudistError.invalid("graph.json is not an object")
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        var g = CodeGraphData(root: root, builtAt: modified)
        for raw in json["nodes"] as? [[String: Any]] ?? [] {
            guard let id = raw["id"] as? String, g.index[id] == nil else { continue }
            let file = (raw["source_file"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let location = raw["source_location"] as? String
            let label = raw["label"] as? String ?? id
            let kind: String
            if file == nil { kind = "external" }
            else if raw["_callable_class"] as? Bool == true { kind = "type" }
            else if raw["_callable"] as? Bool == true { kind = label.hasPrefix(".") || label.hasSuffix(")") ? "function" : "type" }
            else if let f = file, (f as NSString).lastPathComponent == label { kind = "file" }
            else { kind = raw["file_type"] as? String == "code" ? "symbol" : (raw["file_type"] as? String ?? "symbol") }
            g.index[id] = g.nodes.count
            g.nodes.append(Node(id: id, label: label,
                                community: raw["community"] as? Int,
                                communityName: raw["community_name"] as? String,
                                file: file,
                                line: location.flatMap { Int($0.drop { !$0.isNumber }.prefix { $0.isNumber }) },
                                kind: kind))
        }
        g.outgoing = Array(repeating: [], count: g.nodes.count)
        g.incoming = Array(repeating: [], count: g.nodes.count)
        for raw in (json["links"] ?? json["edges"]) as? [[String: Any]] ?? [] {
            guard let s = (raw["source"] as? String).flatMap({ g.index[$0] }),
                  let t = (raw["target"] as? String).flatMap({ g.index[$0] }), s != t else { continue }
            let e = g.edges.count
            g.edges.append(Edge(source: s, target: t, relation: raw["relation"] as? String ?? "related",
                                confidence: raw["confidence"] as? String ?? "EXTRACTED"))
            g.outgoing[s].append(e)
            g.incoming[t].append(e)
        }
        return g
    }

    // MARK: Finding nodes

    /// Nodes matching words of `text`, best first.
    public func match(_ text: String, limit: Int = 12) -> [Int] {
        let phrase = Self.norm(text)
        guard !phrase.isEmpty else { return [] }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." && $0 != "/" })
            .map { Self.norm(String($0)) }.filter { $0.count >= 3 }
        var scored: [(Int, Double)] = []
        for (i, n) in nodes.enumerated() {
            let label = Self.norm(n.label)
            let file = n.file?.lowercased() ?? ""
            var score = 0.0
            if label == phrase { score += 10 }
            else if label.contains(phrase) && phrase.count >= 3 { score += 4 }
            for w in words {
                if label == w { score += 5 }
                else if label.hasPrefix(w) { score += 2.5 }
                else if label.contains(w) { score += 1.5 }
                else if file.contains(w) { score += 0.5 }
            }
            guard score > 0 else { continue }
            // Prefer the project's own, well-connected things over library types and leaves.
            if n.kind == "external" { score *= 0.5 }
            score += min(Double(degree(i)), 50) / 100
            scored.append((i, score))
        }
        scored.sort { $0.1 > $1.1 }
        guard let best = scored.first?.1 else { return [] }
        // Keep the clear matches, not everything that shares a substring.
        return scored.prefix { $0.1 >= best * 0.35 }.prefix(limit).map(\.0)
    }

    /// The single best node for a name.
    public func resolve(_ name: String) throws -> Int {
        guard let n = match(name, limit: 1).first else {
            throw ClaudistError.invalid("Nothing in the graph matches “\(name)”; use names of types, functions or files")
        }
        return n
    }

    static func norm(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(".") { t.removeFirst() }
        if t.hasSuffix("()") { t.removeLast(2) }
        return t
    }

    // MARK: Traversal

    public enum Direction: Sendable { case both, incoming }

    public func neighbors(_ n: Int, _ direction: Direction = .both) -> [Int] {
        var out = incoming[n].map { edges[$0].source }
        if direction == .both { out += outgoing[n].map { edges[$0].target } }
        return out
    }

    /// Breadth-first from `seeds`, best-connected first at each level, up to `cap` nodes.
    public func expand(_ seeds: [Int], depth: Int, cap: Int, direction: Direction = .both, skipExternal: Bool = false) -> [Int: Int] {
        var distance: [Int: Int] = [:]
        var frontier: [Int] = []
        for s in seeds where distance[s] == nil && distance.count < cap {
            distance[s] = 0
            frontier.append(s)
        }
        var level = 0
        while level < depth && !frontier.isEmpty && distance.count < cap {
            level += 1
            var next = Set<Int>()
            for n in frontier { for m in neighbors(n, direction) where distance[m] == nil { next.insert(m) } }
            // The project's own code first; library types (String, View…) only fill what's left.
            let ordered = next.filter { !skipExternal || nodes[$0].kind != "external" }
                .sorted { (nodes[$0].kind == "external" ? 1 : 0, -degree($0)) < (nodes[$1].kind == "external" ? 1 : 0, -degree($1)) }
            frontier = []
            for m in ordered {
                guard distance.count < cap else { break }
                distance[m] = level
                frontier.append(m)
            }
        }
        return distance
    }

    /// Shortest path ignoring edge direction.
    public func shortestPath(_ from: Int, _ to: Int) -> [Int]? {
        if from == to { return [from] }
        var previous: [Int: Int] = [from: from]
        var queue = [from]
        var head = 0
        while head < queue.count {
            let n = queue[head]
            head += 1
            for m in neighbors(n) where previous[m] == nil {
                previous[m] = n
                if m == to {
                    var path = [to]
                    var cur = to
                    while cur != from { cur = previous[cur]!; path.append(cur) }
                    return path.reversed()
                }
                queue.append(m)
            }
        }
        return nil
    }

    /// The edge between two nodes, in either direction.
    public func edge(_ a: Int, _ b: Int) -> Edge? {
        if let e = outgoing[a].first(where: { edges[$0].target == b }) { return edges[e] }
        if let e = outgoing[b].first(where: { edges[$0].target == a }) { return edges[e] }
        return nil
    }

    public func describe(_ n: Int) -> String {
        let node = nodes[n]
        guard let file = node.file else { return "\(node.label) (external)" }
        return "\(node.label) — \(file)" + (node.line.map { ":\($0)" } ?? "")
    }
}

/// What a graph view shows: a snapshot kept for the chat widget.
public struct CodeGraphView: Codable, Sendable {
    public struct Node: Codable, Sendable {
        public var id: String
        public var label: String
        public var community: Int?
        public var communityName: String?
        public var file: String?
        public var line: Int?
        public var kind: String
        /// Connections in the whole graph, not only in this view.
        public var degree: Int
        /// seed, path, changed or affected; nil for context.
        public var role: String?
        /// Drawn graphs: shown when the node is clicked.
        public var description: String? = nil
        /// Drawn graphs: https URL, absolute file path or task:<id>.
        public var link: String? = nil
    }

    public struct Edge: Codable, Sendable {
        public var s: Int
        public var t: Int
        public var relation: String
        public var confidence: String
        public var onPath: Bool?
        /// Drawn graphs: false for a plain line.
        public var directed: Bool? = nil
    }

    public struct Stats: Codable, Sendable {
        public var nodes: Int
        public var edges: Int
        public var communities: Int
    }

    public var id: String
    public var title: String
    public var root: String
    public var mode: String
    public var query: String?
    public var createdAt: String
    public var builtAt: String
    public var graph: Stats
    /// Nodes left out because the view was capped.
    public var truncated: Int = 0
    public var nodes: [Node]
    public var edges: [Edge]
    /// Layout saved by the viewer after the first render, so reopening is instant and stable.
    public var positions: [String: [Double]]?

    public var summary: String {
        "\(nodes.count) of \(graph.nodes) nodes · \(edges.count) links"
    }
}

/// Builds views and text answers from a graph.
public enum CodeGraphQuery {
    public enum Mode: String, CaseIterable, Sendable { case overview, focus, path, explain, changes }

    public struct Request: Sendable {
        public var mode: Mode
        public var query: String?
        public var from: String?
        public var to: String?
        public var depth: Int?
        public var title: String?
        /// For `changes`: files changed, relative to the graph's root.
        public var changedFiles: [String] = []
        public var changesNote: String?

        public init(mode: Mode, query: String? = nil, from: String? = nil, to: String? = nil, depth: Int? = nil, title: String? = nil) {
            self.mode = mode
            self.query = query
            self.from = from
            self.to = to
            self.depth = depth
            self.title = title
        }
    }

    public static let overviewCap = 2500
    public static let focusCap = 400

    /// Selected nodes with their roles, and the path when there is one.
    struct Selection {
        var members = Set<Int>()
        var roles: [Int: String] = [:]
        var path: [Int] = []

        mutating func add(_ n: Int, role: String? = nil) {
            members.insert(n)
            if let role { roles[n] = role }
        }
        var truncated = 0
        var notes: [String] = []
    }

    static func select(_ g: CodeGraphData, _ r: Request) throws -> Selection {
        var sel = Selection()
        switch r.mode {
        case .overview:
            let own = g.nodes.indices.filter { g.nodes[$0].kind != "external" }
            let ranked = own.count > overviewCap ? Array(own.sorted { g.degree($0) > g.degree($1) }.prefix(overviewCap)) : own
            sel.truncated = own.count - ranked.count
            for n in ranked { sel.add(n) }
        case .focus, .explain:
            guard let q = r.query, !q.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ClaudistError.invalid("Give `query`: the names or concepts to center the graph on")
            }
            let seeds = r.mode == .explain ? [try g.resolve(q)] : g.match(q)
            guard !seeds.isEmpty else {
                throw ClaudistError.invalid("Nothing in the graph matches “\(q)”; use names of types, functions or files")
            }
            let depth = max(1, min(r.depth ?? (r.mode == .explain || seeds.count > 4 ? 1 : 2), 3))
            let reach = g.expand(seeds, depth: depth, cap: focusCap)
            for (n, d) in reach { sel.add(n, role: d == 0 ? "seed" : nil) }
            sel.truncated = max(0, Set(seeds.flatMap { g.neighbors($0) }).count - reach.count)
        case .path:
            guard let from = r.from, let to = r.to else { throw ClaudistError.invalid("Give `from` and `to` for a path") }
            let a = try g.resolve(from), b = try g.resolve(to)
            guard let path = g.shortestPath(a, b) else {
                throw ClaudistError.invalid("“\(g.nodes[a].label)” and “\(g.nodes[b].label)” are not connected in the graph")
            }
            sel.path = path
            // A little context around the path: the best-connected neighbors of each hop.
            for n in path {
                for m in g.neighbors(n).sorted(by: { g.degree($0) > g.degree($1) }).prefix(6) { sel.add(m) }
            }
            for n in path { sel.add(n, role: "path") }
        case .changes:
            let files = Set(r.changedFiles)
            guard !files.isEmpty else { throw ClaudistError.invalid(r.changesNote ?? "No changed files") }
            let changed = g.nodes.indices.filter { g.nodes[$0].file.map(files.contains) ?? false }
            guard !changed.isEmpty else {
                throw ClaudistError.invalid("None of the changed files are code the graph knows: " + files.sorted().prefix(10).joined(separator: ", "))
            }
            // What depends on the changed code: callers, importers, subclasses… (reverse edges).
            let reach = g.expand(changed, depth: max(1, min(r.depth ?? 2, 3)), cap: 600, direction: .incoming, skipExternal: true)
            for (n, d) in reach { sel.add(n, role: d == 0 ? "changed" : "affected") }
            sel.truncated = max(0, changed.count - reach.filter { $0.value == 0 }.count)
            if let note = r.changesNote { sel.notes.append(note) }
        }
        return sel
    }

    /// A snapshot for the widget.
    public static func view(_ g: CodeGraphData, _ r: Request, id: String = newID()) throws -> (CodeGraphView, String) {
        let sel = try select(g, r)
        let order = sel.members.sorted()
        var position: [Int: Int] = [:]
        for (i, n) in order.enumerated() { position[n] = i }
        let pathEdges = Set(zip(sel.path, sel.path.dropFirst()).flatMap { [Pair($0, $1), Pair($1, $0)] })
        var edges: [CodeGraphView.Edge] = []
        for e in g.edges {
            guard let s = position[e.source], let t = position[e.target] else { continue }
            let on = pathEdges.contains(Pair(e.source, e.target))
            edges.append(.init(s: s, t: t, relation: e.relation, confidence: e.confidence, onPath: on ? true : nil))
        }
        let nodes = order.map { n -> CodeGraphView.Node in
            let x = g.nodes[n]
            return .init(id: x.id, label: x.label, community: x.community, communityName: x.communityName,
                         file: x.file, line: x.line, kind: x.kind, degree: g.degree(n), role: sel.roles[n])
        }
        let stamp = ISO8601DateFormatter()
        let view = CodeGraphView(
            id: id,
            title: r.title?.isEmpty == false ? r.title! : defaultTitle(g, r),
            root: g.root, mode: r.mode.rawValue,
            query: r.query ?? [r.from, r.to].compactMap { $0 }.joined(separator: " → "),
            createdAt: stamp.string(from: Date()), builtAt: stamp.string(from: g.builtAt),
            graph: .init(nodes: g.nodes.count, edges: g.edges.count, communities: g.communityCount),
            truncated: sel.truncated, nodes: nodes, edges: edges)
        return (view, summary(g, r, sel, view: view))
    }

    /// A text answer, without a widget.
    public static func answer(_ g: CodeGraphData, _ r: Request) throws -> String {
        let sel = try select(g, r)
        var lines = [header(g)]
        lines += sel.notes
        switch r.mode {
        case .explain:
            let n = sel.roles.first { $0.value == "seed" }!.key
            lines.append("\(g.describe(n)) · \(g.degree(n)) connections · community: \(g.nodes[n].communityName ?? "?")")
            for e in g.outgoing[n].prefix(60) { let x = g.edges[e]; lines.append("  --\(x.relation)--> \(g.describe(x.target)) [\(x.confidence)]") }
            for e in g.incoming[n].prefix(60) { let x = g.edges[e]; lines.append("  <--\(x.relation)-- \(g.describe(x.source)) [\(x.confidence)]") }
        case .path:
            lines.append(pathText(g, sel.path))
        default:
            let ranked = sel.members.sorted { (sel.roles[$0] != nil ? 0 : 1, -g.degree($0)) < (sel.roles[$1] != nil ? 0 : 1, -g.degree($1)) }
            if r.mode == .overview { lines.append(communities(g, Array(sel.members))) }
            for n in ranked.prefix(80) {
                let role = sel.roles[n].map { "[\($0)] " } ?? ""
                lines.append("- \(role)\(g.describe(n)) · \(g.degree(n)) links")
            }
            if ranked.count > 80 { lines.append("… and \(ranked.count - 80) more") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Text

    static func header(_ g: CodeGraphData) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Code graph of \(g.root) (updated \(f.string(from: g.builtAt))): \(g.nodes.count) nodes, \(g.edges.count) links, \(g.communityCount) subsystems."
    }

    static func defaultTitle(_ g: CodeGraphData, _ r: Request) -> String {
        let name = (g.root as NSString).lastPathComponent
        switch r.mode {
        case .overview: return name
        case .focus: return "\(name): \(r.query ?? "")"
        case .explain: return r.query ?? name
        case .path: return "\(r.from ?? "?") → \(r.to ?? "?")"
        case .changes: return "\(name): changes and their impact"
        }
    }

    static func communities(_ g: CodeGraphData, _ nodes: [Int]) -> String {
        var counts: [String: Int] = [:]
        for n in nodes { counts[g.nodes[n].communityName ?? "Community \(g.nodes[n].community ?? -1)", default: 0] += 1 }
        let top = counts.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) (\($0.value))" }
        return "Subsystems: " + top.joined(separator: ", ")
    }

    static func pathText(_ g: CodeGraphData, _ path: [Int]) -> String {
        guard let first = path.first else { return "" }
        var s = "Path (\(path.count - 1) hops): \(g.nodes[first].label)"
        for (a, b) in zip(path, path.dropFirst()) {
            let e = g.edge(a, b)
            let forward = e.map { $0.source == a } ?? true
            s += forward ? " --\(e?.relation ?? "?")--> " : " <--\(e?.relation ?? "?")-- "
            s += g.nodes[b].label
        }
        return s + "\n" + path.map { "  " + g.describe($0) }.joined(separator: "\n")
    }

    static func summary(_ g: CodeGraphData, _ r: Request, _ sel: Selection, view: CodeGraphView) -> String {
        var lines = [header(g), "Shown to the user as an interactive graph “\(view.title)”: \(view.nodes.count) nodes, \(view.edges.count) links."
                     + (sel.truncated > 0 ? " \(sel.truncated) more left out." : "")]
        lines += sel.notes
        let roles = Dictionary(grouping: sel.roles.keys) { sel.roles[$0]! }
        if let seeds = roles["seed"] { lines.append("Centered on: " + seeds.prefix(12).map { g.describe($0) }.joined(separator: "; ")) }
        if !sel.path.isEmpty { lines.append(pathText(g, sel.path)) }
        if let changed = roles["changed"] {
            lines.append("Changed (\(changed.count)): " + changed.sorted { g.degree($0) > g.degree($1) }.prefix(20).map { g.nodes[$0].label }.joined(separator: ", "))
        }
        if let affected = roles["affected"] {
            lines.append("Depends on the changes (\(affected.count)): " + affected.sorted { g.degree($0) > g.degree($1) }.prefix(25).map { g.describe($0) }.joined(separator: "; "))
        }
        lines.append(communities(g, Array(sel.members)))
        let hubs = sel.members.filter { g.nodes[$0].kind != "external" }.sorted { g.degree($0) > g.degree($1) }.prefix(10)
        lines.append("Most connected: " + hubs.map { "\(g.nodes[$0].label) (\(g.degree($0)))" }.joined(separator: ", "))
        lines.append("Don't repeat the graph in text; point out what matters in it.")
        return lines.joined(separator: "\n")
    }

    struct Pair: Hashable {
        var a: Int, b: Int
        init(_ a: Int, _ b: Int) { self.a = a; self.b = b }
    }
}
