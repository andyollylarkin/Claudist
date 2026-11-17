import AppKit
import ClaudistCore
import SwiftUI
import WebKit

/// Shows code graph views (experimental) in WebKit: the bundled viewer and the saved view's data
/// are served over `claudist-graph://viewer/`. Web views are kept for a while so a graph doesn't
/// lay itself out again every time the chat scrolls past it.
@MainActor
final class CodeGraphHost: NSObject, ObservableObject {
    static let shared = CodeGraphHost()
    static let scheme = "claudist-graph"

    enum Mode: String { case inline, full }

    /// The view open in the large window.
    @Published var expanded: ExpandedGraph?
    /// Whole-graph rebuild in progress (view id it was asked from).
    @Published var building: String?
    @Published var lastError: String?

    struct ExpandedGraph: Identifiable {
        let id: String
        let title: String
        let root: String
        /// Fixed when opened: measuring while the sheet is up would measure the sheet itself.
        var size: CGSize
    }

    /// Most of Claudist's main window (never a sheet's).
    static func sheetSize() -> CGSize {
        let window = NSApp.windows.first { $0.isMainWindow && $0.sheetParent == nil }
            ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) }
        let frame = window?.frame.size ?? CGSize(width: 1300, height: 860)
        return CGSize(width: max(900, frame.width * 0.94), height: max(600, frame.height * 0.9))
    }

    private(set) var paths = AppPaths()
    var engine: CodeGraphEngine { CodeGraphEngine(paths: paths) }

    /// Puts text into the composer of the chat a view belongs to.
    var askHandlers: [String: (String) -> Void] = [:]
    /// Opens a Claudist task (links `task:<id>` in drawn graphs).
    var openTask: ((ID) -> Void)?

    private var views: [String: GraphWebView] = [:]
    private var order: [String] = []
    private var keys: [ObjectIdentifier: (view: String, mode: Mode)] = [:]
    private lazy var schemeHandler = SchemeHandler(host: self)
    private let cacheSize = 8

    func configure(paths: AppPaths) { self.paths = paths }

    // MARK: Web views

    func webView(_ viewId: String, mode: Mode) -> GraphWebView {
        let key = "\(viewId)|\(mode.rawValue)"
        if let view = views[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return view
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)
        let controller = WKUserContentController()
        controller.add(WeakHandler(self), name: "graph")
        config.userContentController = controller
        let view = GraphWebView(frame: .zero, configuration: config)
        view.passesScroll = mode == .inline
        view.navigationDelegate = self
        view.isInspectable = true
        view.setValue(false, forKey: "drawsBackground")
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "viewer"
        components.path = "/index.html"
        components.queryItems = [URLQueryItem(name: "view", value: viewId), URLQueryItem(name: "mode", value: mode.rawValue)]
        view.load(URLRequest(url: components.url!))
        views[key] = view
        keys[ObjectIdentifier(view)] = (viewId, mode)
        order.append(key)
        // Forget the oldest graphs that aren't on screen (never the one just made).
        var i = 0
        while views.count > cacheSize && i < order.count - 1 {
            let old = order[i]
            if let v = views[old], v.window == nil {
                views[old] = nil
                keys[ObjectIdentifier(v)] = nil
                order.remove(at: i)
                v.stopLoading()
            } else {
                i += 1
            }
        }
        return view
    }

    func expand(_ viewId: String) {
        guard let view = try? CodeGraphViews.load(viewId, engine: engine) else { return }
        expanded = ExpandedGraph(id: viewId, title: view.title, root: view.root, size: Self.sheetSize())
    }

    /// Rebuilds the folder's graph and opens all of it.
    func openWhole(root: String, from viewId: String) {
        guard building == nil else { return }
        building = viewId
        lastError = nil
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CodeGraphViews.overview(of: root, engine: engine) }
            DispatchQueue.main.async {
                self.building = nil
                switch result {
                case .success(let view):
                    if let ask = self.askHandlers[viewId] { self.askHandlers[view.id] = ask }
                    self.expanded = ExpandedGraph(id: view.id, title: view.title, root: view.root, size: Self.sheetSize())
                case .failure(let error):
                    self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    // MARK: Messages from the viewer

    fileprivate func handle(_ body: Any, from webView: WKWebView?) {
        guard let message = body as? [String: Any], let type = message["type"] as? String,
              let webView, let key = keys[ObjectIdentifier(webView)] else { return }
        let viewId = key.view
        switch type {
        case "open", "reveal":
            if type == "reveal", let link = message["link"] as? String {
                if let url = Self.localFile(link) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                return
            }
            guard let file = message["file"] as? String, let url = fileURL(file, viewId: viewId) else { return }
            if type == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { Self.open(url, line: message["line"] as? Int ?? 0) }
        case "link":
            guard let link = message["link"] as? String else { return }
            openLink(link, line: message["line"] as? Int ?? 0)
            if key.mode == .full, link.hasPrefix("task:") { expanded = nil }
        case "ask":
            guard let text = message["text"] as? String else { return }
            if let ask = askHandlers[viewId] {
                ask(text)
                if key.mode == .full { expanded = nil }
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message["text"] as? String ?? "", forType: .string)
        case "positions":
            guard let raw = message["positions"] as? [String: [Double]] else { return }
            let engine = self.engine
            DispatchQueue.global(qos: .utility).async { try? CodeGraphViews.savePositions(viewId, raw, engine: engine) }
        case "expand":
            expand(viewId)
        case "overview":
            if let root = message["root"] as? String { openWhole(root: root, from: viewId) }
        case "error":
            NSLog("Code graph viewer: %@", message["text"] as? String ?? "?")
        default:
            break
        }
    }

    /// A file of the view's folder; nothing outside it.
    private func fileURL(_ file: String, viewId: String) -> URL? {
        guard let view = try? CodeGraphViews.load(viewId, engine: engine) else { return nil }
        let root = URL(fileURLWithPath: view.root, isDirectory: true)
        let url = root.appendingPathComponent(file).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// A link an agent put on a drawn graph's node. Links are agent-written, so nothing runs:
    /// web pages open in the browser, documents in their app, and programs or scripts are only
    /// shown in Finder.
    private func openLink(_ link: String, line: Int) {
        if link.hasPrefix("task:") {
            openTask?(String(link.dropFirst(5)))
        } else if let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        } else if let url = Self.localFile(link) {
            if Self.mayRun(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { Self.open(url, line: line) }
        }
    }

    static func localFile(_ link: String) -> URL? {
        let path = link.hasPrefix("file://") ? (URL(string: link)?.path ?? "") : (link as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Apps, folders, scripts, installers, executables: things that act when opened.
    static func mayRun(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { return true }
        let risky: Set<String> = ["app", "command", "sh", "zsh", "bash", "tool", "terminal", "workflow", "pkg", "mpkg", "dmg",
                                  "scpt", "applescript", "scptd", "jar", "action", "prefpane", "webloc", "inetloc", "fileloc",
                                  "shortcut", "mobileconfig", "py", "rb", "pl", "js", "dylib", "kext", "plugin"]
        if risky.contains(url.pathExtension.lowercased()) { return true }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Opens a file in its default app, at the line when the app is Xcode or a VS Code-like editor.
    static func open(_ url: URL, line: Int) {
        guard line > 0, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            NSWorkspace.shared.open(url)
            return
        }
        let bundleId = Bundle(url: app)?.bundleIdentifier
        let process = Process()
        if bundleId == "com.apple.dt.Xcode" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            process.arguments = ["--line", "\(line)", url.path]
        } else if case let cli = app.appendingPathComponent("Contents/Resources/app/bin/code"),
                  FileManager.default.isExecutableFile(atPath: cli.path) {
            // VS Code, Cursor, Windsurf…
            process.executableURL = cli
            process.arguments = ["-g", "\(url.path):\(line)"]
        } else {
            NSWorkspace.shared.open(url)
            return
        }
        do { try process.run() } catch { NSWorkspace.shared.open(url) }
    }

    // MARK: Files

    /// The bundled viewer: in the app's resources, or the source tree under `swift run`.
    static let viewerDirectory: URL? = {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("graph-viewer"), fm.fileExists(atPath: r.appendingPathComponent("index.html").path) {
            return r
        }
        var src = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { src.deleteLastPathComponent() }
        let dev = src.appendingPathComponent("Resources/graph-viewer")
        return fm.fileExists(atPath: dev.appendingPathComponent("index.html").path) ? dev : nil
    }()

    nonisolated static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }
}

extension CodeGraphHost: WKNavigationDelegate {
    /// The viewer stays on its page; links never navigate it.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == Self.scheme ? .allow : .cancel)
    }
}

/// Inline graphs let the chat scroll; ⌘-scroll zooms the graph.
final class GraphWebView: WKWebView {
    var passesScroll = false

    override func scrollWheel(with event: NSEvent) {
        if passesScroll && !event.modifierFlags.contains(.command) {
            nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var host: CodeGraphHost?
    init(_ host: CodeGraphHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let webView = message.webView
        MainActor.assumeIsolated { host?.handle(body, from: webView) }
    }
}

private final class SchemeHandler: NSObject, WKURLSchemeHandler {
    weak var host: CodeGraphHost?
    init(host: CodeGraphHost) { self.host = host }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let parts = url.path.split(separator: "/").map(String.init)
        var file: URL?
        if parts.count == 2, parts[0] == "data", parts[1].hasSuffix(".json"), let host {
            file = CodeGraphViews.file(String(parts[1].dropLast(5)), engine: host.engine)
        } else if parts.count == 1, !parts[0].hasPrefix("."), let dir = CodeGraphHost.viewerDirectory {
            file = dir.appendingPathComponent(parts[0])
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(response)
            task.didReceive(Data("Not found".utf8))
            task.didFinish()
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": CodeGraphHost.mimeType(file.lastPathComponent),
            "Cache-Control": "no-store",
            // The viewer only needs its own files: no network, no outside scripts.
            "Content-Security-Policy": "default-src 'self' \(CodeGraphHost.scheme): blob:; script-src 'self' \(CodeGraphHost.scheme): blob:; worker-src blob:; style-src 'self' 'unsafe-inline'; connect-src 'self' \(CodeGraphHost.scheme):; img-src 'self' data: blob:",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: SwiftUI

/// The graph web view inside SwiftUI.
struct GraphWebViewRepresentable: NSViewRepresentable {
    let viewId: String
    let mode: CodeGraphHost.Mode

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== CodeGraphHost.shared.webView(viewId, mode: mode) { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = CodeGraphHost.shared.webView(viewId, mode: mode)
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Inserts text into the composer of the chat around a view.
private struct ComposerInsertKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var composerInsert: ((String) -> Void)? {
        get { self[ComposerInsertKey.self] }
        set { self[ComposerInsertKey.self] = newValue }
    }
}
