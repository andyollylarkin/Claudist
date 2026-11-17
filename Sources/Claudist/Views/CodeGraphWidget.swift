import AppKit
import ClaudistCore
import SwiftUI

/// A graph an agent or the assistant showed, as recorded in the conversation.
struct CodeGraphRef: Hashable {
    var viewId: String
    var title: String
    var root: String
    var mode: String
    var nodes: Int
    var edges: Int
    var total: Int

    init?(_ v: JSONValue) {
        guard let id = v["view"]?.string else { return nil }
        viewId = id
        title = v["title"]?.string ?? "Code graph"
        root = v["root"]?.string ?? ""
        mode = v["mode"]?.string ?? ""
        nodes = Int(v["nodes"]?.number ?? 0)
        edges = Int(v["edges"]?.number ?? 0)
        total = Int(v["total"]?.number ?? 0)
    }

    var folderName: String { (root as NSString).lastPathComponent }
    /// Composed by the agent with draw_graph, not mapped from a folder.
    var isDrawn: Bool { mode == "drawn" }

    var icon: String {
        switch mode {
        case "drawn": return "circle.grid.cross"
        case "path": return "point.topleft.down.to.point.bottomright.curvepath"
        case "changes": return "arrow.triangle.branch"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// The interactive graph inside a chat.
struct CodeGraphWidget: View {
    @ObservedObject private var host = CodeGraphHost.shared
    @Environment(\.composerInsert) private var insert
    let ref: CodeGraphRef

    private var exists: Bool {
        FileManager.default.fileExists(atPath: CodeGraphViews.file(ref.viewId, engine: host.engine).path)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: ref.icon).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(ref.isDrawn ? "\(ref.nodes) nodes · \(ref.edges) links · drawn by the agent"
                         : "\(ref.nodes) nodes · \(ref.edges) links · \(ref.folderName)" + (ref.total > ref.nodes ? " · \(ref.total) in the whole graph" : ""))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if host.building == ref.viewId {
                    ProgressView().controlSize(.small)
                    Text("Mapping the whole folder…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                if !ref.isDrawn {
                    Button { host.openWhole(root: ref.root, from: ref.viewId) } label: {
                        Image(systemName: "circle.hexagongrid")
                    }
                    .help("Whole graph of \(ref.folderName), rebuilt now")
                    .disabled(host.building != nil)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ref.root)]) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Show \(ref.root) in Finder")
                }
                Button { host.expand(ref.viewId) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Open large")
                .disabled(!exists)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            if exists {
                GraphWebViewRepresentable(viewId: ref.viewId, mode: .inline)
                    .frame(height: 420)
            } else {
                Text("This graph is no longer stored on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .padding(.leading, 30)
        .onAppear { if let insert { host.askHandlers[ref.viewId] = insert } }
        .alert("Couldn't map the folder", isPresented: Binding(get: { host.lastError != nil && host.expanded == nil }, set: { if !$0 { host.lastError = nil } })) {
            Button("OK") { host.lastError = nil }
        } message: {
            Text(host.lastError ?? "")
        }
    }
}

/// A graph in a large sheet.
struct ExpandedGraphSheet: View {
    @ObservedObject private var host = CodeGraphHost.shared
    @Environment(\.dismiss) private var dismiss
    let graph: CodeGraphHost.ExpandedGraph

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(graph.title).font(.system(size: 13, weight: .semibold))
                    Text(graph.root.isEmpty ? "Drawn by the agent" : graph.root).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if host.building != nil {
                    ProgressView().controlSize(.small)
                    Text("Mapping the whole folder…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                if !graph.root.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: graph.root)]) }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            GraphWebViewRepresentable(viewId: graph.id, mode: .full)
        }
        .frame(width: graph.size.width, height: graph.size.height)
    }
}

/// Settings → Experimental: the code graph.
struct CodeGraphSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(CodeGraph.enabledKey) private var enabled = false
    @State private var installing = false
    @State private var log = ""
    @State private var error: String?
    @State private var refresh = 0
    @State private var diskSize: String?

    private var engine: CodeGraphEngine { store.graphEngine }

    var body: some View {
        let _ = refresh
        Card(title: "Experimental",
             footer: "Agents and the assistant get graph tools: ask them to “show it as a graph” and an interactive graph appears in the chat. show_graph maps code; draw_graph draws anything else they gather (tasks, people, concepts of a document). Code graphs are built locally from code with graphify (tree-sitter, ~40 languages) in Claudist's own Python environment: no LLM, nothing leaves this Mac. They're stored in Claudist's data folder, never in your repositories. Agents map only the folders they work in.") {
            FieldRow(title: "Code graph", subtitle: "Map code into an interactive knowledge graph") {
                Toggle("", isOn: Binding(get: { enabled }, set: { on in
                    enabled = on
                    if on && !engine.isInstalled { install() }
                }))
                .toggleStyle(.switch).labelsHidden()
            }
            FieldRow(title: "Graph engine", subtitle: engineSubtitle, last: diskSize == nil) {
                HStack(spacing: 8) {
                    if installing { ProgressView().controlSize(.small) }
                    Button(engine.isInstalled && !engine.needsUpdate ? "Reinstall" : engine.needsUpdate ? "Update" : "Install") { install() }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .disabled(installing)
                }
            }
            if let diskSize {
                FieldRow(title: "Stored graphs", subtitle: diskSize, last: true) {
                    Button("Delete graphs") { deleteGraphs() }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .disabled(installing)
                }
            }
            if installing || error != nil {
                Text(error ?? log).font(.system(size: 11)).foregroundStyle(error == nil ? Theme.secondary : Theme.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .onAppear(perform: measure)
    }

    private var engineSubtitle: String {
        if installing { return "Installing graphify \(CodeGraph.graphifyVersion)…" }
        if let v = engine.installedVersion, engine.isInstalled {
            return v == CodeGraph.graphifyVersion ? "graphify \(v)" : "graphify \(v) — this Claudist expects \(CodeGraph.graphifyVersion)"
        }
        return "Not installed · needs Python 3.10+ · graphify \(CodeGraph.graphifyVersion) from PyPI"
    }

    private func install() {
        installing = true
        error = nil
        log = "Starting…"
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try engine.install { line in DispatchQueue.main.async { log = line } } }
            DispatchQueue.main.async {
                installing = false
                if case .failure(let e) = result { error = (e as? LocalizedError)?.errorDescription ?? "\(e)" }
                refresh += 1
                measure()
            }
        }
    }

    private func measure() {
        let root = engine.root.appendingPathComponent("folders")
        let views = engine.views
        DispatchQueue.global(qos: .utility).async {
            let bytes = [root, views].reduce(Int64(0)) { $0 + Self.size(of: $1) }
            let text = bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
            DispatchQueue.main.async { diskSize = text }
        }
    }

    private func deleteGraphs() {
        let alert = NSAlert()
        alert.messageText = "Delete all stored code graphs?"
        alert.informativeText = "Graphs shown in chats will no longer open. Folders are mapped again the next time a graph is asked for."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for dir in [engine.root.appendingPathComponent("folders"), engine.views] {
            try? FileManager.default.removeItem(at: dir)
        }
        measure()
    }

    nonisolated static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
