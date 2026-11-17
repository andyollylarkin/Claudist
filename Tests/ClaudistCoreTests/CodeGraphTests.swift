import Foundation
import Testing
@testable import ClaudistCore

struct CodeGraphTests {
    /// A small graph in graphify's format.
    static let fixture = """
    {"directed": true, "multigraph": false, "graph": {"schema_version": 1},
     "nodes": [
      {"id": "store", "label": "AppStore", "_callable": true, "_callable_class": true, "community": 0, "community_name": "Store", "source_file": "App/AppStore.swift", "source_location": "L12", "file_type": "code"},
      {"id": "store_write", "label": ".write()", "_callable": true, "community": 0, "community_name": "Store", "source_file": "App/AppStore.swift", "source_location": "L40", "file_type": "code"},
      {"id": "runs", "label": "RunManager", "_callable": true, "_callable_class": true, "community": 1, "community_name": "Runs", "source_file": "App/RunManager.swift", "source_location": "L9", "file_type": "code"},
      {"id": "runs_start", "label": ".start()", "_callable": true, "community": 1, "community_name": "Runs", "source_file": "App/RunManager.swift", "source_location": "L100", "file_type": "code"},
      {"id": "panel", "label": "AgentRunPanel", "_callable": true, "_callable_class": true, "community": 2, "community_name": "Views", "source_file": "Views/AgentRunPanel.swift", "source_location": "L7", "file_type": "code"},
      {"id": "file_store", "label": "AppStore.swift", "community": 0, "source_file": "App/AppStore.swift", "file_type": "code"},
      {"id": "string", "label": "String", "community": 3, "file_type": "code"},
      {"id": "lonely", "label": "Lonely", "_callable": true, "_callable_class": true, "community": 4, "source_file": "Misc/Lonely.swift", "file_type": "code"}
     ],
     "links": [
      {"source": "store", "target": "store_write", "relation": "method", "confidence": "EXTRACTED"},
      {"source": "runs", "target": "runs_start", "relation": "method", "confidence": "EXTRACTED"},
      {"source": "runs_start", "target": "store_write", "relation": "calls", "confidence": "INFERRED"},
      {"source": "panel", "target": "runs", "relation": "references", "confidence": "EXTRACTED"},
      {"source": "file_store", "target": "store", "relation": "contains", "confidence": "EXTRACTED"},
      {"source": "store", "target": "string", "relation": "references", "confidence": "EXTRACTED"},
      {"source": "store", "target": "store", "relation": "references", "confidence": "EXTRACTED"},
      {"source": "store", "target": "missing", "relation": "calls", "confidence": "EXTRACTED"}
     ],
     "hyperedges": []}
    """

    func graph() throws -> CodeGraphData {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graph-\(UUID().uuidString).json")
        try Self.fixture.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try CodeGraphData.load(url, root: "/repo")
    }

    @Test func loadsNodesKindsAndEdges() throws {
        let g = try graph()
        #expect(g.nodes.count == 8)
        // Self-loops and edges to unknown nodes are dropped.
        #expect(g.edges.count == 6)
        let kind = { (id: String) in g.nodes[g.index[id]!].kind }
        #expect(kind("store") == "type")
        #expect(kind("store_write") == "function")
        #expect(kind("file_store") == "file")
        #expect(kind("string") == "external")
        #expect(g.nodes[g.index["runs_start"]!].line == 100)
        #expect(g.communityCount == 5)
    }

    @Test func matchesNamesBestFirst() throws {
        let g = try graph()
        #expect(g.nodes[g.match("AppStore").first!].id == "store")
        #expect(g.nodes[try g.resolve("start")].id == "runs_start")
        #expect(g.match("zzz").isEmpty)
        #expect(throws: (any Error).self) { try g.resolve("nothing like this") }
    }

    @Test func focusCentersOnTheQuery() throws {
        let g = try graph()
        let (view, summary) = try CodeGraphQuery.view(g, .init(mode: .focus, query: "RunManager", depth: 1))
        let roles = Dictionary(uniqueKeysWithValues: view.nodes.map { ($0.id, $0.role) })
        #expect(roles["runs"] == "seed")
        #expect(roles.keys.contains("runs_start") && roles.keys.contains("panel"))
        #expect(!roles.keys.contains("lonely"))
        // Edges point into the view's own node list.
        #expect(view.edges.allSatisfy { $0.s < view.nodes.count && $0.t < view.nodes.count })
        #expect(summary.contains("Centered on: RunManager"))
        #expect(view.title.contains("RunManager"))
    }

    @Test func pathFollowsLinksInEitherDirection() throws {
        let g = try graph()
        let (view, summary) = try CodeGraphQuery.view(g, .init(mode: .path, from: "AgentRunPanel", to: "AppStore"))
        let path = Set(view.nodes.filter { $0.role == "path" }.map(\.id))
        #expect(path == ["panel", "runs", "runs_start", "store_write", "store"])
        #expect(view.edges.filter { $0.onPath == true }.count == 4)
        #expect(summary.contains("4 hops"))
        #expect(throws: (any Error).self) { try CodeGraphQuery.view(g, .init(mode: .path, from: "Lonely", to: "AppStore")) }
    }

    @Test func changesShowWhatDependsOnThem() throws {
        let g = try graph()
        var r = CodeGraphQuery.Request(mode: .changes)
        r.changedFiles = ["App/AppStore.swift"]
        let (view, summary) = try CodeGraphQuery.view(g, r)
        let roles = Dictionary(uniqueKeysWithValues: view.nodes.map { ($0.id, $0.role) })
        #expect(roles["store"] == "changed" && roles["store_write"] == "changed")
        // RunManager.start calls the changed write(); RunManager owns start.
        #expect(roles["runs_start"] == "affected" && roles["runs"] == "affected")
        #expect(roles["string"] == nil)
        #expect(summary.contains("Depends on the changes"))
        r.changedFiles = ["README.md"]
        #expect(throws: (any Error).self) { try CodeGraphQuery.view(g, r) }
    }

    @Test func overviewLeavesOutLibraryTypes() throws {
        let g = try graph()
        let (view, _) = try CodeGraphQuery.view(g, .init(mode: .overview))
        #expect(view.nodes.count == 7)
        #expect(!view.nodes.contains { $0.kind == "external" })
    }

    @Test func explainListsConnections() throws {
        let text = try CodeGraphQuery.answer(try graph(), .init(mode: .explain, query: "AppStore"))
        #expect(text.contains("--method--> .write()"))
        #expect(text.contains("<--contains-- AppStore.swift"))
    }

    @Test func viewsRoundTripWithPositions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CodeGraphEngine(paths: AppPaths(root: root))
        let (view, _) = try CodeGraphQuery.view(try graph(), .init(mode: .overview))
        try CodeGraphViews.save(view, engine: engine)
        try CodeGraphViews.savePositions(view.id, ["store": [1, 2]], engine: engine)
        let back = try CodeGraphViews.load(view.id, engine: engine)
        #expect(back.nodes.count == view.nodes.count)
        #expect(back.positions?["store"] == [1, 2])
        // Ids can't climb out of the views folder.
        #expect(CodeGraphViews.file("../../x", engine: engine).deletingLastPathComponent() == engine.views)
    }

    @Test func foldersStayInsideTheAllowedRoots() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roots-\(UUID().uuidString)")
        let repo = tmp.appendingPathComponent("repo/Sources")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let roots = [CodeGraphTools.Root(path: tmp.appendingPathComponent("repo").path, label: "storage")]
        #expect(try CodeGraphTools.folder(nil, roots: roots) == roots[0].path)
        #expect(try CodeGraphTools.folder(repo.path, roots: roots) == CodeGraphEngine.normalize(repo.path))
        #expect(throws: (any Error).self) { try CodeGraphTools.folder(tmp.path, roots: roots) }
        #expect(throws: (any Error).self) { try CodeGraphTools.folder(repo.path + "/../../..", roots: roots) }
        #expect(throws: (any Error).self) { try CodeGraphTools.folder(roots[0].path + "-evil", roots: roots) }
    }

    @Test func agentRootsComeFromWhatItWorksIn() throws {
        let agent = Agent(name: "Coder", folderPath: "/tmp/agents/coder")
        var config = AgentLaunchConfig(agent: agent, skills: [], storages: [(Storage(name: "Code", path: "/tmp/code"), .rw)])
        config.codeGraph = true
        let roots = CodeGraphTools.roots(config)
        #expect(roots.map(\.path) == [CodeGraphEngine.normalize("/tmp/code"), CodeGraphEngine.normalize("/tmp/agents/coder")])
        let workspace = AgentWorkspace(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ws")))
        let allow = (workspace.settings(config)["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains(CodeGraphTools.qualified("show_graph")))
        config.codeGraph = false
        let off = (workspace.settings(config)["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(!off.contains(CodeGraphTools.qualified("show_graph")))
    }

    @Test func gitChangesAreRelativeToTheFolder() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
        let sub = repo.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ args: String...) throws {
            let r = try Shell.run(URL(fileURLWithPath: "/usr/bin/git"), ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + args, timeout: 30)
            #expect(r.status == 0, "\(r.output)")
        }
        try git("init", "-q")
        try "a".write(to: sub.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "r".write(to: repo.appendingPathComponent("root.swift"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "one")
        try "b".write(to: sub.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "new".write(to: sub.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
        try "r2".write(to: repo.appendingPathComponent("root.swift"), atomically: true, encoding: .utf8)

        let changes = try GitChanges.files(in: CodeGraphEngine.normalize(sub.path), base: nil)
        #expect(changes.files == ["a.swift", "new.swift"])
        let top = try GitChanges.files(in: CodeGraphEngine.normalize(repo.path), base: nil)
        #expect(top.files == ["pkg/a.swift", "pkg/new.swift", "root.swift"])

        try git("add", ".")
        try git("commit", "-qm", "two")
        let last = try GitChanges.files(in: CodeGraphEngine.normalize(repo.path), base: nil)
        #expect(last.note?.contains("last commit") == true)
        #expect(last.files.contains("root.swift"))
        #expect(throws: (any Error).self) { try GitChanges.files(in: repo.path, base: "--output=/tmp/x") }
    }

    /// End to end with a real graphify: set CLAUDIST_GRAPHIFY_VENV to a virtualenv that has it installed.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_GRAPHIFY_VENV"] != nil))
    func showGraphWithGraphify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cg-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CodeGraphEngine(paths: AppPaths(root: root))
        try FileManager.default.createDirectory(at: engine.runtime, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: engine.venv, withDestinationURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDIST_GRAPHIFY_VENV"]!))
        try CodeGraph.graphifyVersion.write(to: engine.versionFile, atomically: true, encoding: .utf8)

        // This package's own sources.
        var sources = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { sources.deleteLastPathComponent() }
        sources.appendPathComponent("Sources/ClaudistCore")
        let roots = [CodeGraphTools.Root(path: sources.path, label: "test")]
        let started = Date()
        let shown = CodeGraphTools.call("show_graph", JSONValue.parse(#"{"mode":"focus","query":"TaskVault"}"#), engine: engine, roots: roots)
        #expect(!shown.isError, "\(shown.text)")
        #expect(shown.view?.nodes.contains { $0.label == "TaskVault" && $0.role == "seed" } == true)
        print("show_graph took \(Date().timeIntervalSince(started))s:\n\(shown.text)")
        let path = CodeGraphTools.call("graph_query", JSONValue.parse(#"{"mode":"path","from":"AgentWorkspace","to":"CodeGraphTools"}"#), engine: engine, roots: roots)
        #expect(!path.isError, "\(path.text)")
        print(path.text)
        // Nothing is written into the mapped folder.
        #expect(!FileManager.default.fileExists(atPath: sources.appendingPathComponent("graphify-out").path))
    }
}

struct DrawnGraphTests {
    @Test func drawsNodesGroupsAndLinks() throws {
        let args = JSONValue.parse("""
        {"title": "Launch plan",
         "nodes": [{"id": "a", "label": "Design", "group": "Product", "description": "Mockups", "link": "task:T1"},
                   {"id": "b", "label": "Build", "group": "Engineering"},
                   {"id": "c", "group": "Engineering"},
                   {"id": "a", "label": "dup"},
                   {"id": "d"}],
         "edges": [{"from": "a", "to": "b", "label": "blocks"},
                   {"from": "b", "to": "c", "directed": false},
                   {"from": "b", "to": "zzz"},
                   {"from": "c", "to": "c"}],
         "highlight": ["b", "nope"]}
        """)
        let (view, summary) = try DrawnGraph.view(args)
        #expect(view.mode == "drawn" && view.root.isEmpty && view.title == "Launch plan")
        #expect(view.nodes.map(\.id) == ["a", "b", "c", "d"])
        #expect(view.nodes[0].description == "Mockups" && view.nodes[0].link == "task:T1")
        #expect(view.nodes[2].label == "c")
        // Ungrouped nodes go to "Other" when others have groups.
        #expect(view.nodes[3].communityName == "Other")
        #expect(view.nodes[1].community == view.nodes[2].community)
        #expect(view.nodes[1].role == "seed" && view.nodes[0].role == nil)
        #expect(view.edges.count == 2)
        #expect(view.edges[0].relation == "blocks" && view.edges[0].directed == true)
        #expect(view.edges[1].relation == "related" && view.edges[1].directed == false)
        #expect(view.nodes[1].degree == 2)
        #expect(summary.contains("duplicate node ids: a"))
        #expect(summary.contains("Skipped 2 edges"))
    }

    @Test func needsATitleAndNodes() {
        #expect(throws: (any Error).self) { try DrawnGraph.view(JSONValue.parse(#"{"nodes":[{"id":"a"}]}"#)) }
        #expect(throws: (any Error).self) { try DrawnGraph.view(JSONValue.parse(#"{"title":"x","nodes":[]}"#)) }
    }

    @Test func drawGoesThroughTheToolWithoutAnEngine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("draw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = CodeGraphEngine(paths: AppPaths(root: root))
        let out = CodeGraphTools.call("draw_graph", JSONValue.parse(#"{"title":"T","nodes":[{"id":"a"},{"id":"b"}],"edges":[{"from":"a","to":"b"}]}"#),
                                      engine: engine, roots: [])
        #expect(!out.isError, "\(out.text)")
        #expect(try CodeGraphViews.load(out.view!.id, engine: engine).nodes.count == 2)
        #expect(CodeGraphTools.toolDefinitions().contains { $0["name"] as? String == "draw_graph" })
    }
}
