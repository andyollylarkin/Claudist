import Foundation
import GRDB

/// The graph tools served on the app's `claudist` MCP server, to agents and the assistant.
public enum CodeGraphTools {
    public static let show = "show_graph"
    public static let query = "graph_query"
    public static let draw = "draw_graph"
    public static let toolNames: [String] = [show, query, draw]

    public static func qualified(_ tool: String) -> String { "mcp__\(Delegation.serverName)__\(tool)" }

    /// A folder the caller may map.
    public struct Root: Sendable, Hashable {
        public var path: String
        public var label: String
        public init(path: String, label: String) {
            self.path = CodeGraphEngine.normalize(path)
            self.label = label
        }
    }

    /// An agent maps what it works on: the task's attached folders, its storage, its own folder.
    public static func roots(_ config: AgentLaunchConfig) -> [Root] {
        var out = config.attachments.filter { $0.isDirectory && $0.exists }.map { Root(path: $0.path, label: "attached to the task") }
        out += config.storages.map { Root(path: $0.storage.path, label: "storage “\($0.storage.name)”") }
        out.append(Root(path: config.agent.folderPath, label: "your agent folder"))
        return unique(out)
    }

    /// The assistant maps any folder Claudist knows: storage, agent folders, folders attached to tasks.
    public static func assistantRoots(_ db: Database) throws -> [Root] {
        var out = try Storage.fetchAll(db).map { Root(path: $0.path, label: "storage “\($0.name)”") }
        out += try TaskAttachment.filter(Column("isDirectory") == true).fetchAll(db).filter(\.exists)
            .map { Root(path: $0.path, label: "attached to a task") }
        out += try Agent.fetchAll(db).map { Root(path: $0.folderPath, label: "folder of agent \($0.name)") }
        return unique(out)
    }

    static func unique(_ roots: [Root]) -> [Root] {
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }

    /// The folder to map: `requested` when it is inside an allowed root, else the first root.
    public static func folder(_ requested: String?, roots: [Root]) throws -> String {
        guard let requested = requested?.trimmingCharacters(in: .whitespaces), !requested.isEmpty else {
            guard let first = roots.first else { throw ClaudistError.invalid("No folder to map") }
            return first.path
        }
        let path = CodeGraphEngine.normalize(requested)
        guard roots.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
            throw ClaudistError.invalid("\(requested) is outside the folders you can map: " + roots.map(\.path).joined(separator: ", "))
        }
        return path
    }

    // MARK: Definitions

    static func schema(widget: Bool) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Folder to map (absolute). Default: the first folder listed in your instructions"],
                "mode": ["type": "string", "enum": CodeGraphQuery.Mode.allCases.map(\.rawValue), "description": """
                    overview: the whole project's structure. focus: the code around `query` (names of types, functions, \
                    files or concepts). explain: one node and all its connections (`query` = its name). path: how `from` \
                    reaches `to`. changes: the code changed in git (uncommitted, or since `base`) and what depends on it
                    """],
                "query": ["type": "string", "description": "focus/explain: names or concepts to center on"],
                "from": ["type": "string", "description": "path: start node name"],
                "to": ["type": "string", "description": "path: end node name"],
                "base": ["type": "string", "description": "changes: git ref to compare with (e.g. the commit before your work). Default: uncommitted changes, or the last commit when there are none"],
                "depth": ["type": "integer", "minimum": 1, "maximum": 3, "description": "How many hops around the center (default 1–2)"],
            ].merging(widget ? ["title": ["type": "string", "description": "Short title shown above the graph"]] : [:]) { a, _ in a },
            "required": ["mode"],
        ]
    }

    public static func toolDefinitions() -> [[String: Any]] {
        [
            ["name": show,
             "description": """
                Show the user an interactive code graph in the chat (zoom, search, filters, click a node to open its file). \
                Use it whenever the user asks to show, draw, visualize or reflect something as a graph. Builds or refreshes \
                the folder's graph first (code only, local, no LLM). Returns a summary of what is shown.
                """,
             "inputSchema": schema(widget: true)],
            ["name": query,
             "description": """
                Ask the code graph a structural question without showing anything: what X connects to, how A reaches B, \
                what depends on changed code. Cheaper than reading many files to find relations.
                """,
             "inputSchema": schema(widget: false)],
            DrawnGraph.definition,
        ]
    }

    public static func promptSection(_ roots: [Root]) -> String {
        """
        ## Code graph (experimental)
        Claudist can map code into a knowledge graph (types, functions, files and how they call, import and inherit each other).
        - When the user asks to show, draw or reflect something as a graph ("покажи граф", "отрази в графе", "граф зависимостей", \
        "show it as a graph"), call `\(qualified(show))`: it puts an interactive graph in this chat. Don't draw graphs in text.
        - Pick the mode that answers the request: focus with a precise `query`, path, explain, changes (what you changed and \
        what it affects; pass `base` if you committed), overview only for the whole picture.
        - `\(qualified(query))` answers structural questions in text; use it before wide searches for "who calls / uses / depends on".
        - For a graph of anything that isn't code in a folder (tasks and what blocks them, people, concepts of a document, \
        a plan, an architecture described in words), gather the facts first, then call `\(qualified(draw))` with nodes and \
        edges you compose: short labels, groups for color, a description per node, links (https URL, absolute file path, \
        or task:<id> for a Claudist task) where useful. Only draw connections you have grounds for.
        Folders you can map:
        \(roots.map { "- `\($0.path)` (\($0.label))" }.joined(separator: "\n"))
        """
    }

    // MARK: Calls

    /// What a call produced: text for the model, and the view to show when `show_graph` succeeded.
    public struct Outcome: Sendable {
        public var text: String
        public var isError: Bool
        public var view: CodeGraphView?
    }

    /// Runs a graph tool. Builds/refreshes the graph first; slow work, call it off the main thread.
    public static func call(_ name: String, _ args: JSONValue?, engine: CodeGraphEngine, roots: [Root],
                            log: @escaping @Sendable (String) -> Void = { _ in }) -> Outcome {
        do {
            guard toolNames.contains(name) else { throw ClaudistError.invalid("Unknown tool \(name)") }
            if name == draw {
                let (view, summary) = try DrawnGraph.view(args)
                try CodeGraphViews.save(view, engine: engine)
                return Outcome(text: summary, isError: false, view: view)
            }
            let folder = try folder(args?["path"]?.string, roots: roots)
            guard let mode = CodeGraphQuery.Mode(rawValue: args?["mode"]?.string ?? "focus") else {
                throw ClaudistError.invalid("Unknown mode; use one of " + CodeGraphQuery.Mode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            var request = CodeGraphQuery.Request(mode: mode, query: args?["query"]?.string, from: args?["from"]?.string,
                                                 to: args?["to"]?.string, depth: args?["depth"]?.number.map { Int($0) },
                                                 title: args?["title"]?.string)
            if mode == .changes {
                let changes = try GitChanges.files(in: folder, base: args?["base"]?.string)
                request.changedFiles = changes.files
                request.changesNote = changes.note
            }
            if !engine.isInstalled || engine.needsUpdate {
                log("Installing the graph engine (once)…")
                try engine.install(log: log)
            }
            let file = try engine.build(folder: folder)
            let graph = try CodeGraphData.load(file, root: folder)
            if name == query {
                return Outcome(text: try CodeGraphQuery.answer(graph, request), isError: false, view: nil)
            }
            let (view, summary) = try CodeGraphQuery.view(graph, request)
            try CodeGraphViews.save(view, engine: engine)
            return Outcome(text: summary, isError: false, view: view)
        } catch {
            return Outcome(text: (error as? LocalizedError)?.errorDescription ?? "\(error)", isError: true, view: nil)
        }
    }

    /// Event payload for the chat widget.
    public static func eventPayload(_ view: CodeGraphView) -> [String: Any] {
        ["view": view.id, "title": view.title, "root": view.root, "mode": view.mode,
         "nodes": view.nodes.count, "edges": view.edges.count, "total": view.graph.nodes]
    }
}

/// Saved views (snapshots shown in chats).
public enum CodeGraphViews {
    public static func file(_ id: String, engine: CodeGraphEngine) -> URL {
        engine.views.appendingPathComponent("\(id.filter { $0.isLetter || $0.isNumber || $0 == "-" }).json")
    }

    public static func save(_ view: CodeGraphView, engine: CodeGraphEngine) throws {
        try FileManager.default.createDirectory(at: engine.views, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(view)
        try data.write(to: file(view.id, engine: engine), options: .atomic)
    }

    public static func load(_ id: String, engine: CodeGraphEngine) throws -> CodeGraphView {
        try JSONDecoder().decode(CodeGraphView.self, from: Data(contentsOf: file(id, engine: engine)))
    }

    /// Stores the layout the viewer computed, so the view opens the same way next time.
    public static func savePositions(_ id: String, _ positions: [String: [Double]], engine: CodeGraphEngine) throws {
        var view = try load(id, engine: engine)
        view.positions = positions
        try save(view, engine: engine)
    }

    /// The whole current graph of a view's folder, as a new view.
    public static func overview(of root: String, engine: CodeGraphEngine) throws -> CodeGraphView {
        let file = try engine.build(folder: root)
        let graph = try CodeGraphData.load(file, root: root)
        let (view, _) = try CodeGraphQuery.view(graph, .init(mode: .overview))
        try save(view, engine: engine)
        return view
    }
}

/// Files changed in git, relative to a folder.
public enum GitChanges {
    public static func files(in folder: String, base: String?) throws -> (files: [String], note: String?) {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        func run(_ args: [String]) throws -> String {
            let r = try Shell.run(git, ["-C", folder] + args, timeout: 60)
            guard r.status == 0 else { throw ClaudistError.invalid("git: " + CodeGraphEngine.tail(r.output, lines: 3)) }
            return r.output
        }
        let top = CodeGraphEngine.normalize(try run(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines))
        func list(_ text: String) -> [String] { text.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        var files: [String]
        var note: String?
        if let base, !base.isEmpty {
            guard !base.hasPrefix("-") else { throw ClaudistError.invalid("Bad git ref \(base)") }
            files = list(try run(["diff", "--name-only", base, "--"])) + list(try run(["ls-files", "--others", "--exclude-standard", "--full-name"]))
            note = "Changes since \(base)."
        } else {
            files = list(try run(["diff", "--name-only", "HEAD", "--"])) + list(try run(["ls-files", "--others", "--exclude-standard", "--full-name"]))
            note = "Uncommitted changes."
            if files.isEmpty {
                files = list(try run(["diff", "--name-only", "HEAD~1", "HEAD", "--"]))
                note = "No uncommitted changes: showing the last commit."
            }
        }
        // git lists paths from the repository top; the graph's are from the folder.
        let prefix = folder == top ? "" : String(folder.dropFirst(top.count + 1)) + "/"
        let relative = files.compactMap { f -> String? in
            prefix.isEmpty ? f : f.hasPrefix(prefix) ? String(f.dropFirst(prefix.count)) : nil
        }
        return (Array(Set(relative)).sorted(), note)
    }
}
