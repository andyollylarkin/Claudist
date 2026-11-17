import AppKit
import ClaudistCore
import Foundation
import GRDB

/// Runs the App Builder: one Claude Code process per active builder chat, working in the
/// chat's app folder on the Claude account the user picked.
@MainActor
final class AppBuilderManager: ObservableObject {
    @Published private(set) var live: [ID: LiveChat] = [:]   // by chatId

    static let accountKey = "builder.account"
    static let modelKey = "builder.model"
    private let idleTimeout: TimeInterval = 300

    private let store: AppStore
    private let host: MiniAppHost
    private var pendingReload: [ID: DispatchWorkItem] = [:]

    init(store: AppStore, host: MiniAppHost) {
        self.store = store
        self.host = host
    }

    /// Account for new chats: the last one picked, else the app's default.
    var defaultAccountId: String {
        let saved = UserDefaults.standard.string(forKey: Self.accountKey)
        if let saved, saved == ClaudeAccounts.macLogin || store.claudeAccounts.contains(where: { $0.id == saved }) { return saved }
        return ClaudeAccounts.defaultId ?? ClaudeAccounts.macLogin
    }

    func accountName(_ id: String) -> String {
        id == ClaudeAccounts.macLogin ? "This Mac's login" : store.claudeAccounts.first { $0.id == id }?.name ?? "Deleted account"
    }

    var accountOptions: [(String, String)] {
        [(ClaudeAccounts.macLogin, "This Mac's login")] + store.claudeAccounts.map { ($0.id, $0.name) }
    }

    // MARK: Apps

    struct NewApp {
        var request = ""
        var name = ""
        var offline = true
        var network = false
        var networkHosts = ""
        var accountId = ClaudeAccounts.macLogin
        var model = ""
    }

    /// Adds the app to the list and starts building it. Returns the builder chat.
    @discardableResult
    func create(_ spec: NewApp) -> AppBuilderChat? {
        var app = MiniApp(name: spec.name.trimmingCharacters(in: .whitespacesAndNewlines))
        app.offline = spec.offline
        app.network = spec.network
        app.networkHosts = spec.network ? spec.networkHosts : ""
        let paths = store.paths
        var created = false
        store.write { db in
            try MiniApps.create(db, &app, paths: paths)
            created = true
        }
        guard created else { return nil }
        let chat = newChat(appId: app.id, accountId: spec.accountId, model: spec.model)
        send(chat.id, text: AppBuilder.firstMessage(request: spec.request), shown: spec.request)
        return chat
    }

    func delete(_ app: MiniApp) {
        let chats = store.read { try AppBuilderChat.filter(Column("appId") == app.id).fetchAll($0) } ?? []
        for chat in chats { terminate(chat.id) }
        host.eraseData(app.id)
        let paths = store.paths
        store.write { try MiniApps.delete($0, app, paths: paths) }
    }

    func update(_ app: MiniApp) {
        var app = app
        app.updatedAt = LocalDate.stamp(Date())
        let paths = store.paths
        store.write { try app.update($0) }
        // The builder reads app.json; keep it in step so the user's name and icon stick.
        try? MiniApps.writeMeta(app, paths: paths)
        // The policy is served with each page; the builder learns it in its next process.
        host.reload(app.id)
        let chats = store.read { try AppBuilderChat.filter(Column("appId") == app.id).fetchAll($0) } ?? []
        for chat in chats where live[chat.id]?.busy == false { live[chat.id]?.process.closeInput() }
    }

    // MARK: Chats

    func newChat(appId: ID, accountId: String, model: String) -> AppBuilderChat {
        var chat = AppBuilderChat(appId: appId)
        chat.accountId = accountId
        chat.model = model
        store.write { try chat.insert($0) }
        UserDefaults.standard.set(accountId, forKey: Self.accountKey)
        UserDefaults.standard.set(model, forKey: Self.modelKey)
        return chat
    }

    func deleteChat(_ chatId: ID) {
        terminate(chatId)
        store.write { try $0.execute(sql: "DELETE FROM appBuilderChat WHERE id = ?", arguments: [chatId]) }
    }

    /// Account or model for the rest of the chat; takes effect with the next message.
    func configure(_ chatId: ID, accountId: String? = nil, model: String? = nil) {
        store.write { db in
            guard var chat = try AppBuilderChat.fetchOne(db, key: chatId) else { return }
            if let accountId { chat.accountId = accountId }
            if let model { chat.model = model }
            try chat.update(db)
        }
        if let accountId { UserDefaults.standard.set(accountId, forKey: Self.accountKey) }
        if let model { UserDefaults.standard.set(model, forKey: Self.modelKey) }
        if let current = live[chatId], !current.busy { current.process.closeInput() }
    }

    /// `shown` is what the transcript shows for the user's message when it differs from what Claude gets.
    func send(_ chatId: ID, text: String, shown: String? = nil) {
        guard var chat = store.read({ try AppBuilderChat.fetchOne($0, key: chatId) }) ?? nil else { return }
        record(chatId, "user/input", ["text": shown ?? text])
        if chat.title == "New chat" {
            let source = shown ?? text
            let line = source.split(separator: "\n").first.map(String.init) ?? source
            chat.title = String(line.prefix(60))
        }
        chat.updatedAt = LocalDate.stamp(Date())
        store.write { try chat.update($0) }

        let content: [[String: Any]] = [["type": "text", "text": text]]
        if let current = live[chatId], current.process.isRunning {
            current.idleClose?.cancel()
            current.busy = true
            current.process.send(content: content)
            return
        }
        launch(chat, message: content)
    }

    func stop(_ chatId: ID) {
        guard let current = live[chatId], current.busy else { return }
        current.process.interrupt()
    }

    private func terminate(_ chatId: ID) {
        live[chatId]?.idleClose?.cancel()
        live[chatId]?.process.terminate()
        live[chatId] = nil
    }

    // MARK: Process

    private func launch(_ chat: AppBuilderChat, message: [[String: Any]]) {
        let chatId = chat.id
        do {
            guard let app = store.read({ try MiniApp.fetchOne($0, key: chat.appId) }) ?? nil else {
                throw ClaudistError.invalid("The app of this chat was deleted")
            }
            let folder = MiniApps.folder(store.paths, app.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let environment = try self.environment(accountId: chat.accountId)
            let args = AppBuilder.arguments(app, model: chat.model, resume: chat.sessionId)
            let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: args,
                                       cwd: folder, environment: environment) { [weak self] event in
                DispatchQueue.main.async { self?.handle(event, chatId: chatId, appId: app.id, folder: folder, message: message) }
            }
            let current = LiveChat(process: process)
            current.appId = app.id
            current.resumed = chat.sessionId != nil
            live[chatId] = current
            try process.start()
            process.send(content: message)
        } catch {
            live[chatId] = nil
            record(chatId, "stderr", ["text": (error as? LocalizedError)?.errorDescription ?? "\(error)"])
        }
    }

    private func environment(accountId: String) throws -> [String: String] {
        guard accountId != ClaudeAccounts.macLogin else { return ClaudeAccounts.hostEnvironment([:]) }
        guard let account = store.read({ try ClaudeAccount.fetchOne($0, key: accountId) }) ?? nil else {
            throw ClaudistError.invalid("The Claude account of this chat was removed; pick another one above")
        }
        return ClaudeAccounts.hostEnvironment(try ClaudeAccounts.environment(account, secrets: store.secretStore))
    }

    private func handle(_ event: AgentProcess.Event, chatId: ID, appId: ID, folder: URL, message: [[String: Any]]) {
        guard let current = live[chatId] else { return }
        switch event {
        case .message(let kind, let json):
            store.write { db in
                var e = AppBuilderEvent(chatId: chatId, kind: kind, json: json)
                try e.insert(db)
            }
            if kind == "system/init", let sid = JSONValue.parse(json)?["session_id"]?.string {
                current.sawInit = true
                store.write { try $0.execute(sql: "UPDATE appBuilderChat SET sessionId = ? WHERE id = ?", arguments: [sid, chatId]) }
            }
            if kind == "user" { scheduleReload(appId) }   // a tool finished: files may have changed
            if kind.hasPrefix("result") {
                current.busy = false
                finished(appId)
                let work = DispatchWorkItem { [weak current] in current?.process.closeInput() }
                current.idleClose = work
                DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
            }

        case .permission(let request):
            switch AppBuilder.decide(tool: request.toolName, input: request.input, folder: folder) {
            case .allow:
                current.process.respond(request, .allow)
            case .deny(let reason):
                current.process.respond(request, .deny(reason))
                record(chatId, "permission", ["request_id": request.id, "tool": request.toolName, "input": request.inputJSON])
                record(chatId, "permission/answer", ["request_id": request.id, "allow": false])
            case .ask:
                current.process.respond(request, .deny("Not available in the App Builder"))
            }

        case .mcp:
            break

        case .stderr(let text):
            record(chatId, "stderr", ["text": text])

        case .exited(let code):
            current.idleClose?.cancel()
            live[chatId] = nil
            if code != 0 && current.busy {
                if current.resumed && !current.sawInit {
                    // The saved session is gone: start a fresh one; the app's files carry the work so far.
                    store.write { try $0.execute(sql: "UPDATE appBuilderChat SET sessionId = NULL WHERE id = ?", arguments: [chatId]) }
                    if let chat = store.read({ try AppBuilderChat.fetchOne($0, key: chatId) }) ?? nil {
                        let note = "(The earlier conversation could not be restored. The app's current files are in this folder; read them first.)"
                        launch(chat, message: [["type": "text", "text": note]] + message)
                    }
                    return
                }
                record(chatId, "stderr", ["text": "Claude Code exited with code \(code)"])
                finished(appId)
            }
        }
    }

    private func finished(_ appId: ID) {
        let paths = store.paths
        store.write { try MiniApps.syncMeta($0, appId: appId, paths: paths) }
        pendingReload[appId]?.cancel()
        host.reload(appId)
    }

    /// Live preview while the builder writes files.
    private func scheduleReload(_ appId: ID) {
        pendingReload[appId]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.host.reload(appId) }
        pendingReload[appId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func record(_ chatId: ID, _ kind: String, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        store.write { db in
            var e = AppBuilderEvent(chatId: chatId, kind: kind, json: String(decoding: data, as: UTF8.self))
            try e.insert(db)
        }
    }
}
