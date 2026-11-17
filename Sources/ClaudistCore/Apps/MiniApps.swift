import Foundation
import GRDB
import UniformTypeIdentifiers

/// A client-only web app made in the App Builder and run inside Claudist.
///
/// The files live in `apps/<id>/` (`index.html` plus any JS, CSS and assets next to it). The
/// policy — whether the app may load code from CDNs and whether it may reach the internet — is
/// set by the user in the wizard and kept here, out of the builder's reach.
public struct MiniApp: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: ID = newID()
    public var name: String
    /// One emoji.
    public var icon = ""
    public var summary = ""
    /// Everything the app needs is in its folder: no libraries, fonts or images from CDNs.
    public var offline = true
    /// `fetch`, XHR and WebSockets to the internet are allowed.
    public var network = false
    /// With `network`: only these hosts (comma or space separated, `*.example.com` allowed); empty = any.
    public var networkHosts = ""
    public var itemOrder = 0
    public var createdAt = LocalDate.stamp(Date())
    public var updatedAt = LocalDate.stamp(Date())

    public static let databaseTableName = "miniApp"

    public init(name: String) { self.name = name }

    public var displayName: String { name.isEmpty ? "Untitled app" : name }
    public var displayIcon: String { icon.isEmpty ? "🧩" : icon }

    public var hosts: [String] {
        networkHosts.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { h in
                var h = h
                for p in ["https://", "http://", "wss://", "ws://"] where h.hasPrefix(p) { h.removeFirst(p.count) }
                return h.split(separator: "/").first.map(String.init) ?? h
            }
            .filter { !$0.isEmpty }
    }
}

/// A conversation in the App Builder; it works on one app.
public struct AppBuilderChat: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: ID = newID()
    public var appId: ID
    public var title = "New chat"
    /// Claude account id, or `ClaudeAccounts.macLogin`.
    public var accountId = ClaudeAccounts.macLogin
    public var model = ""
    public var sessionId: String?
    public var createdAt = LocalDate.stamp(Date())
    public var updatedAt = LocalDate.stamp(Date())

    public init(appId: ID) { self.appId = appId }
}

/// One stream-json line (or app event) of a builder chat; same shape as `assistantEvent`.
public struct AppBuilderEvent: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public var seq: Int64?
    public var chatId: ID
    public var kind: String
    public var json: String
    public var createdAt = LocalDate.stamp(Date())

    public init(chatId: ID, kind: String, json: String) {
        self.chatId = chatId
        self.kind = kind
        self.json = json
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        seq = inserted.rowID
    }
}

public enum MiniApps {
    public static let scheme = "claudist-app"
    public static let entry = "index.html"
    /// Name, icon and description, written by the builder.
    public static let metaFile = "app.json"

    public static func folder(_ paths: AppPaths, _ id: ID) -> URL {
        paths.apps.appendingPathComponent(id, isDirectory: true)
    }

    public static func url(_ id: ID) -> URL { URL(string: "\(scheme)://\(id)/\(entry)")! }

    public static func isBuilt(_ paths: AppPaths, _ id: ID) -> Bool {
        FileManager.default.fileExists(atPath: folder(paths, id).appendingPathComponent(entry).path)
    }

    // MARK: Lifecycle

    /// Inserts the app and makes its folder with a starting `app.json`.
    public static func create(_ db: Database, _ app: inout MiniApp, paths: AppPaths) throws {
        app.itemOrder = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(itemOrder), -1) + 1 FROM miniApp")) ?? 0
        try app.insert(db)
        try FileManager.default.createDirectory(at: folder(paths, app.id), withIntermediateDirectories: true)
        try writeMeta(app, paths: paths)
    }

    public static func writeMeta(_ app: MiniApp, paths: AppPaths) throws {
        let meta = ["name": app.name, "icon": app.icon, "description": app.summary]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: folder(paths, app.id).appendingPathComponent(metaFile))
    }

    public static func delete(_ db: Database, _ app: MiniApp, paths: AppPaths) throws {
        _ = try app.delete(db)
        try? FileManager.default.removeItem(at: folder(paths, app.id))
    }

    /// Copies name, icon and description from `app.json` into the database. Returns true on a change.
    @discardableResult
    public static func syncMeta(_ db: Database, appId: ID, paths: AppPaths) throws -> Bool {
        guard var app = try MiniApp.fetchOne(db, key: appId) else { return false }
        let file = folder(paths, appId).appendingPathComponent(metaFile)
        var changed = false
        if let data = try? Data(contentsOf: file), let meta = JSONValue.parse(String(decoding: data, as: UTF8.self)) {
            if let n = meta["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, n != app.name {
                app.name = String(n.prefix(60)); changed = true
            }
            if let i = meta["icon"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !i.isEmpty {
                let first = String(i.first!)
                if first != app.icon { app.icon = first; changed = true }
            }
            if let d = meta["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), d != app.summary, !d.isEmpty {
                app.summary = String(d.prefix(400)); changed = true
            }
        }
        app.updatedAt = LocalDate.stamp(Date())
        try app.update(db)
        return changed
    }

    // MARK: Serving

    /// The file for a request path, or nil when it leaves the app folder or doesn't exist.
    public static func file(_ paths: AppPaths, appId: ID, path: String) -> URL? {
        let dir = folder(paths, appId)
        var rel = path.removingPercentEncoding ?? path
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty || rel.hasSuffix("/") { rel += entry }
        guard !rel.split(separator: "/").contains("..") else { return nil }
        let url = dir.appendingPathComponent(rel)
        guard SkillGenerator.isInside(url.path, dir) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            let index = url.appendingPathComponent(entry)
            return FileManager.default.fileExists(atPath: index.path) ? index : nil
        }
        return url
    }

    public static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        case "txt", "md": return "text/plain"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    /// Content Security Policy that enforces the app's offline and network settings.
    public static func contentSecurityPolicy(_ app: MiniApp) -> String {
        let local = "'self' \(scheme): data: blob:"
        let cdn = app.offline ? "" : " https:"
        var net = ""
        if app.network {
            let hosts = app.hosts
            net = hosts.isEmpty ? " https: http: wss: ws:"
                : " " + hosts.flatMap { ["https://\($0)", "http://\($0)", "wss://\($0)", "ws://\($0)"] }.joined(separator: " ")
        }
        return [
            "default-src \(local)\(cdn)",
            "script-src \(local) 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'\(cdn)",
            "style-src \(local) 'unsafe-inline'\(cdn)",
            "font-src \(local)\(cdn)",
            "img-src \(local)\(cdn)\(net)",
            "media-src \(local)\(cdn)\(net)",
            "connect-src \(local)\(net)",
            "worker-src \(local)",
            "frame-src \(local)\(net)",
            "form-action \(local)",
        ].joined(separator: "; ")
    }

    /// HTML with the policy as the first thing in `<head>`, so it applies before any script runs.
    public static func injectPolicy(_ html: String, csp: String) -> String {
        let escaped = csp.replacingOccurrences(of: "\"", with: "&quot;")
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escaped)\">"
        if let r = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: r, with: html[r] + meta)
        }
        if let r = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: r, with: html[r] + "<head>" + meta + "</head>")
        }
        return "<head>" + meta + "</head>" + html
    }

    /// Shown while the builder hasn't written `index.html` yet.
    public static let placeholder = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>body{font:14px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;color:#888}</style>
        </head><body><div>The app is being built…</div></body></html>
        """
}

// MARK: Builder session

/// Command line and policy of the App Builder's Claude Code process.
///
/// Claude works in the app's folder: `--restricted` confines its file tools there and drops
/// Bash/WebFetch; `--safe-mode` keeps the user's skills, CLAUDE.md, plugins and hooks out; every
/// permission request is checked again by the app (`decide`).
public enum AppBuilder {
    public static let tools = ["Read", "Write", "Edit", "Glob", "Grep"]

    public static func arguments(_ app: MiniApp, model: String?, resume sessionId: String?) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-prompt-tool", "stdio",
            "--safe-mode",
            "--restricted",
            "--strict-mcp-config",
            "--permission-mode", "acceptEdits",
            "--tools", tools.joined(separator: ","),
            "--append-system-prompt", systemPrompt(app),
        ]
        if let model, !model.isEmpty { args += ["--model", model] }
        if let sessionId { args += ["--resume", sessionId] }
        return args
    }

    public static func decide(tool: String, input: JSONValue, folder: URL) -> SkillGenerator.Decision {
        guard tools.contains(tool) || tool == "MultiEdit" else { return .deny("\(tool) is not available in the App Builder") }
        let key = ["file_path", "path"].first { input[$0]?.string != nil }
        guard let key, let path = input[key]?.string else { return .allow }
        return SkillGenerator.isInside(path, folder) ? .allow : .deny("Only the app's folder is available")
    }

    public static func systemPrompt(_ app: MiniApp) -> String {
        let dependencies = app.offline
            ? """
              - The app must work fully offline. Do NOT load anything from the internet: no CDN scripts, \
              stylesheets, web fonts or images. Write plain HTML, CSS and modern JavaScript (ES modules are \
              fine) yourself; use system fonts, inline SVG and emoji for graphics. Anything loaded from \
              `https:` is blocked by the app's Content Security Policy.
              """
            : """
              - Libraries, fonts and images may be loaded from CDNs over `https:` (pin exact versions, e.g. \
              `https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js`). Prefer few, well-known ones.
              """
        let network: String
        if app.network {
            let hosts = app.hosts
            network = hosts.isEmpty
                ? "- The app may call internet APIs with `fetch`, XHR or WebSockets (the server must allow CORS)."
                : "- The app may call only these hosts with `fetch`, XHR or WebSockets: \(hosts.joined(separator: ", ")). Requests to other hosts are blocked (the server must allow CORS)."
        } else {
            network = "- The app has NO network access: `fetch`, XHR and WebSockets to any server are blocked. Keep all data local."
        }
        return """
            # You build small client-side web apps

            The current working directory is the app's folder. Write every file there and nowhere else. \
            Claudist shows the app in its built-in browser (WebKit) at `\(MiniApps.scheme)://<app>/index.html`.

            ## Rules
            - Client-only: static files, no server, no build step, no npm. The entry point is `index.html`; \
            other files (JS, CSS, images) sit next to it and are referenced with relative paths. A small app \
            can be one self-contained `index.html`.
            \(dependencies)
            \(network)
            - Persist the user's data in `localStorage` or IndexedDB; they are private to this app and kept \
            between launches. Forms must not submit to a server.
            - `alert`, `confirm`, `prompt`, file inputs and downloads (`<a download>`, blob URLs) work.
            - These rules are enforced by Claudist; you cannot change them. If a request needs something they \
            forbid, say so and build the closest thing that works.

            ## Design
            Make it look like a polished native macOS utility: system font (`-apple-system`), generous \
            spacing, clear hierarchy, rounded controls, responsive layout that fills the window, and both \
            light and dark themes via `prefers-color-scheme`. No placeholder or lorem-ipsum content.

            ## app.json
            Keep `app.json` up to date: `{"name": "…", "icon": "<one emoji>", "description": "<one sentence>"}`. \
            Keep an existing non-empty name unless the user asks to rename the app. Claudist lists the app \
            under that name and icon.

            ## Finish
            Re-read your files and fix mistakes: broken references, syntax errors, missing handlers. Then \
            reply with a short summary of what the app does and how to use it. Don't paste the code.
            """
    }

    /// The first message of a new app.
    public static func firstMessage(request: String) -> String {
        """
        Build a new app in the current folder.

        What it should do:
        \(request)
        """
    }

    /// Errors the app reported at runtime, as a request to fix them.
    public static func fixMessage(errors: [String]) -> String {
        "The app shows these errors when it runs. Find the causes and fix them:\n\n"
            + errors.prefix(20).map { "- " + $0 }.joined(separator: "\n")
    }
}
