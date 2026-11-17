import AppKit
import ClaudistCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Runs the App Builder's apps in WebKit.
///
/// - Each app is served from its folder over `claudist-app://<id>/`, with a Content Security
///   Policy that enforces its offline and network settings.
/// - Each app has its own persistent website data store (localStorage, IndexedDB, cookies),
///   so apps can't see each other's data or the rest of Claudist.
/// - A running app keeps its web view while the user moves around Claudist, until it is quit.
@MainActor
final class MiniAppHost: NSObject, ObservableObject {
    /// Web views of the running apps, by app id.
    private(set) var running: [ID: WKWebView] = [:] {
        // Views ask for their web view while SwiftUI updates; publish afterwards.
        didSet { let ids = Set(running.keys); DispatchQueue.main.async { if self.runningIds != ids { self.runningIds = ids } } }
    }
    @Published private(set) var runningIds: Set<ID> = []
    /// JavaScript errors each app reported since its last load.
    @Published private(set) var errors: [ID: [String]] = [:]

    private let paths: AppPaths
    private let lookup: (ID) -> MiniApp?
    private lazy var schemeHandler = SchemeHandler(paths: paths, lookup: lookup)
    private var downloads: [WKDownload: URL] = [:]

    init(paths: AppPaths, lookup: @escaping (ID) -> MiniApp?) {
        self.paths = paths
        self.lookup = lookup
    }

    /// The app's web view, started on first use.
    func webView(for appId: ID) -> WKWebView {
        if let view = running[appId] { return view }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeId(appId))
        config.setURLSchemeHandler(schemeHandler, forURLScheme: MiniApps.scheme)
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.errorReporter, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakMessageHandler(self), name: "claudistError")
        config.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isInspectable = true
        view.allowsBackForwardNavigationGestures = false
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: MiniApps.url(appId)))
        running[appId] = view
        return view
    }

    func reload(_ appId: ID) {
        guard let view = running[appId] else { return }
        errors[appId] = nil
        // Back to the entry page: the app may have navigated to a page that no longer exists.
        view.load(URLRequest(url: MiniApps.url(appId), cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func quit(_ appId: ID) {
        guard let view = running.removeValue(forKey: appId) else { return }
        view.stopLoading()
        view.removeFromSuperview()
        errors[appId] = nil
    }

    /// Quits the app and erases everything it stored.
    func eraseData(_ appId: ID) {
        quit(appId)
        WKWebsiteDataStore.remove(forIdentifier: Self.storeId(appId)) { _ in }
    }

    func clearErrors(_ appId: ID) { errors[appId] = nil }

    /// App ids are UUID strings; anything else gets a stable UUID derived from it.
    static func storeId(_ appId: ID) -> UUID {
        if let uuid = UUID(uuidString: appId) { return uuid }
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in appId.utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        return NSUUID(uuidBytes: bytes) as UUID
    }

    fileprivate func appId(of webView: WKWebView) -> ID? {
        running.first { $0.value === webView }?.key
    }

    fileprivate func report(_ message: String, from webView: WKWebView) {
        guard let id = appId(of: webView) else { return }
        var list = errors[id] ?? []
        guard !list.contains(message) else { return }
        list.append(String(message.prefix(600)))
        errors[id] = Array(list.suffix(30))
    }

    /// Sends uncaught errors, rejected promises and `console.error` to the app.
    private static let errorReporter = """
        (() => {
          const post = (m) => { try { window.webkit.messageHandlers.claudistError.postMessage(String(m)); } catch (_) {} };
          window.addEventListener('error', (e) => {
            if (e.target && e.target !== window && (e.target.src || e.target.href)) {
              post('Failed to load ' + (e.target.src || e.target.href)); return;
            }
            const where = e.filename ? ' (' + e.filename.replace(/^claudist-app:\\/\\/[^/]+\\//, '') + ':' + e.lineno + ')' : '';
            post((e.message || 'Error') + where);
          }, true);
          window.addEventListener('unhandledrejection', (e) => post('Unhandled promise rejection: ' + (e.reason && e.reason.stack || e.reason)));
          document.addEventListener('securitypolicyviolation', (e) => post('Blocked by the app\\'s policy: ' + e.blockedURI + ' (' + e.violatedDirective + ')'));
          const orig = console.error;
          console.error = function (...args) {
            post(args.map(a => a instanceof Error ? (a.stack || a.message) : (typeof a === 'object' ? (() => { try { return JSON.stringify(a); } catch (_) { return String(a); } })() : String(a))).join(' '));
            return orig.apply(console, args);
          };
        })();
        """
}

// MARK: Serving files

private final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let paths: AppPaths
    let lookup: (ID) -> MiniApp?

    init(paths: AppPaths, lookup: @escaping (ID) -> MiniApp?) {
        self.paths = paths
        self.lookup = lookup
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let appId = url.host?.lowercased(), let app = lookup(appId) else {
            return fail(task, 404, "No such app")
        }
        let csp = MiniApps.contentSecurityPolicy(app)
        guard let file = MiniApps.file(paths, appId: appId, path: url.path) else {
            if url.path.isEmpty || url.path == "/" || url.path == "/\(MiniApps.entry)" {
                return respond(task, url: url, data: Data(MiniApps.placeholder.utf8), mime: "text/html", csp: csp)
            }
            return fail(task, 404, "Not found: \(url.path)")
        }
        guard var data = try? Data(contentsOf: file) else { return fail(task, 500, "Can't read \(url.path)") }
        let mime = MiniApps.mimeType(file)
        if mime == "text/html" {
            data = Data(MiniApps.injectPolicy(String(decoding: data, as: UTF8.self), csp: csp).utf8)
        }
        respond(task, url: url, data: data, mime: mime, csp: csp)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String, csp: String) {
        let type = mime.hasPrefix("text/") || mime.hasSuffix("json") || mime.hasSuffix("javascript") ? "\(mime); charset=utf-8" : mime
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            "Content-Length": "\(data.count)",
            "Content-Security-Policy": csp,
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "\(MiniApps.scheme)://\(url.host ?? "")",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, _ status: Int, _ message: String) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
        task.didReceive(response)
        task.didReceive(Data(message.utf8))
        task.didFinish()
    }
}

/// `WKUserContentController` retains its handlers; this keeps the host from being retained by every web view.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var host: MiniAppHost?
    init(_ host: MiniAppHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        let text = "\(message.body)"
        MainActor.assumeIsolated { host?.report(text, from: webView) }
    }
}

// MARK: Navigation, dialogs, downloads

extension MiniAppHost: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.cancel) }
        if action.shouldPerformDownload { return decisionHandler(.download) }
        switch scheme {
        case MiniApps.scheme:
            // An app stays inside its own folder.
            decisionHandler(url.host?.lowercased() == appId(of: webView) ? .allow : .cancel)
        case "about", "data", "blob":
            decisionHandler(.allow)
        case "http", "https":
            if action.targetFrame?.isMainFrame == false {
                let app = appId(of: webView).flatMap(lookup)
                decisionHandler(app?.network == true ? .allow : .cancel)
            } else {
                // Links leave the app for the default browser.
                if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        default:
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }   // mailto:, tel:…
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let id = appId(of: webView), errors[id] != nil { errors[id] = nil }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // window.open and target=_blank: external pages open in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        } else if let url = action.request.url, url.scheme == MiniApps.scheme {
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = dialog(webView, message)
        alert.addButton(withTitle: "OK")
        present(alert, webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = dialog(webView, message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = dialog(webView, prompt)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    private func dialog(_ webView: WKWebView, _ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = appId(of: webView).flatMap(lookup)?.displayName ?? "App"
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, _ webView: WKWebView, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return completionHandler(nil) }
        try? FileManager.default.removeItem(at: url)
        downloads[download] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloads.removeValue(forKey: download) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: download)
    }
}

// MARK: SwiftUI

/// Shows a running app's web view; the view survives this container (it's kept by the host).
struct MiniAppWebView: NSViewRepresentable {
    @EnvironmentObject var host: MiniAppHost
    let appId: ID

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== host.running[appId] { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = host.webView(for: appId)
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
