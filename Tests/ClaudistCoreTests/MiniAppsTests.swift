import Foundation
import GRDB
import Testing
@testable import ClaudistCore

struct MiniAppsTests {
    let db: AppDatabase
    let paths: AppPaths

    init() throws {
        db = try AppDatabase.inMemory()
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(newID())"))
        try paths.ensure()
    }

    private func make(_ name: String = "Calc") throws -> MiniApp {
        var app = MiniApp(name: name)
        try db.writer.write { try MiniApps.create($0, &app, paths: paths) }
        return app
    }

    @Test func createMakesFolderAndMeta() throws {
        let app = try make()
        let meta = MiniApps.folder(paths, app.id).appendingPathComponent(MiniApps.metaFile)
        #expect(FileManager.default.fileExists(atPath: meta.path))
        #expect(!MiniApps.isBuilt(paths, app.id))
        try "<html></html>".write(to: MiniApps.folder(paths, app.id).appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        #expect(MiniApps.isBuilt(paths, app.id))
    }

    @Test func syncMetaTakesBuilderNameIconAndDescription() throws {
        let app = try make("")
        let meta = #"{"name": "Mortgage", "icon": "🏠✨", "description": "Monthly payments"}"#
        try meta.write(to: MiniApps.folder(paths, app.id).appendingPathComponent("app.json"), atomically: true, encoding: .utf8)
        let changed = try db.writer.write { try MiniApps.syncMeta($0, appId: app.id, paths: paths) }
        #expect(changed)
        let saved = try db.writer.read { try MiniApp.fetchOne($0, key: app.id) }
        #expect(saved?.name == "Mortgage")
        #expect(saved?.icon == "🏠")
        #expect(saved?.summary == "Monthly payments")
    }

    @Test func filesStayInsideTheAppFolder() throws {
        let app = try make()
        let dir = MiniApps.folder(paths, app.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("js"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "y".write(to: dir.appendingPathComponent("js/app.js"), atomically: true, encoding: .utf8)
        try "secret".write(to: paths.root.appendingPathComponent("db-like.txt"), atomically: true, encoding: .utf8)

        #expect(MiniApps.file(paths, appId: app.id, path: "/")?.lastPathComponent == "index.html")
        #expect(MiniApps.file(paths, appId: app.id, path: "/js/app.js")?.lastPathComponent == "app.js")
        #expect(MiniApps.file(paths, appId: app.id, path: "/../../db-like.txt") == nil)
        #expect(MiniApps.file(paths, appId: app.id, path: "/%2E%2E/%2E%2E/db-like.txt") == nil)
        #expect(MiniApps.file(paths, appId: app.id, path: "/missing.js") == nil)
    }

    @Test func policyFollowsOfflineAndNetworkSettings() {
        var app = MiniApp(name: "A")
        var csp = MiniApps.contentSecurityPolicy(app)
        #expect(!csp.contains("https:"))
        #expect(csp.contains("connect-src 'self' claudist-app: data: blob:;"))

        app.offline = false
        csp = MiniApps.contentSecurityPolicy(app)
        #expect(csp.contains("script-src 'self' claudist-app: data: blob: 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https:"))
        #expect(csp.contains("connect-src 'self' claudist-app: data: blob:;"))

        app.network = true
        app.networkHosts = "https://api.github.com/, *.example.org"
        #expect(app.hosts == ["api.github.com", "*.example.org"])
        csp = MiniApps.contentSecurityPolicy(app)
        #expect(csp.contains("connect-src 'self' claudist-app: data: blob: https://api.github.com http://api.github.com wss://api.github.com ws://api.github.com https://*.example.org"))

        app.networkHosts = ""
        #expect(MiniApps.contentSecurityPolicy(app).contains("connect-src 'self' claudist-app: data: blob: https: http: wss: ws:"))
    }

    @Test func policyGoesFirstInHead() {
        let html = MiniApps.injectPolicy("<!doctype html><HTML lang=en><Head><script>x()</script></head></html>", csp: "default-src 'self'")
        #expect(html.contains(#"<Head><meta http-equiv="Content-Security-Policy" content="default-src 'self'"><script>"#))
        let bare = MiniApps.injectPolicy("<p>hi</p>", csp: "a")
        #expect(bare.hasPrefix("<head><meta"))
    }

    @Test func builderOnlyTouchesTheAppFolder() throws {
        let app = try make()
        let dir = MiniApps.folder(paths, app.id)
        func input(_ json: String) -> JSONValue { JSONValue.parse(json)! }
        #expect(AppBuilder.decide(tool: "Write", input: input(#"{"file_path": "\#(dir.path)/index.html"}"#), folder: dir) == .allow)
        #expect(AppBuilder.decide(tool: "Read", input: input(#"{"file_path": "/etc/passwd"}"#), folder: dir) != .allow)
        #expect(AppBuilder.decide(tool: "Edit", input: input(#"{"file_path": "../other/index.html"}"#), folder: dir) != .allow)
        #expect(AppBuilder.decide(tool: "Bash", input: input(#"{"command": "ls"}"#), folder: dir) != .allow)
        #expect(AppBuilder.decide(tool: "WebFetch", input: input(#"{"url": "https://x"}"#), folder: dir) != .allow)
    }

    @Test func builderPromptStatesThePolicy() {
        var app = MiniApp(name: "A")
        #expect(AppBuilder.systemPrompt(app).contains("must work fully offline"))
        #expect(AppBuilder.systemPrompt(app).contains("NO network access"))
        app.offline = false
        app.network = true
        app.networkHosts = "api.github.com"
        let prompt = AppBuilder.systemPrompt(app)
        #expect(prompt.contains("CDNs"))
        #expect(prompt.contains("only these hosts"))
        let args = AppBuilder.arguments(app, model: "sonnet", resume: "s1")
        #expect(args.contains("--restricted"))
        #expect(args.contains("Read,Write,Edit,Glob,Grep"))
        #expect(args.suffix(4) == ["--model", "sonnet", "--resume", "s1"])
    }

    @Test func deletingAnAppRemovesItsChats() throws {
        let app = try make()
        try db.writer.write { db in
            let chat = AppBuilderChat(appId: app.id)
            try chat.insert(db)
            var e = AppBuilderEvent(chatId: chat.id, kind: "user/input", json: "{}")
            try e.insert(db)
            try MiniApps.delete(db, app, paths: paths)
            #expect(try AppBuilderChat.fetchCount(db) == 0)
            #expect(try AppBuilderEvent.fetchCount(db) == 0)
        }
        #expect(!FileManager.default.fileExists(atPath: MiniApps.folder(paths, app.id).path))
    }
}
