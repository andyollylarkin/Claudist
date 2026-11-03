import ClaudistCore
import Foundation
import GRDB

/// Where signing in to the user's Telegram account stands.
enum TelegramAuth: Equatable {
    case off
    /// libtdjson isn't installed.
    case needsLibrary
    /// api_id/api_hash from my.telegram.org are missing.
    case needsKeys
    case starting
    case phone
    /// A login code was sent; the text says where.
    case code(String)
    case emailCode(String)
    /// Two-step verification password, with its hint.
    case password(String)
    case ready
    /// A state Claudist can't complete (sign up, QR confirmation…).
    case unsupported(String)
}

/// The user's own Telegram account through TDLib. Its session lives in the app's data folder,
/// encrypted with a key from the Keychain; agents get tools for the chats the user opened, never the session.
@MainActor
final class TelegramService: ObservableObject {
    @Published var auth: TelegramAuth = .off
    @Published var error: String?
    /// The signed-in account's name.
    @Published var me: String?
    @Published var loadingChats = false

    private let db: AppDatabase
    private let secrets: SecretStore
    private let folder: URL
    private var client: TDLibClient?
    private var account: TDLibAccount?
    /// Updates of a replaced client are ignored.
    private var generation = UUID()

    init(db: AppDatabase, secrets: SecretStore, paths: AppPaths) {
        self.db = db
        self.secrets = secrets
        folder = paths.root.appendingPathComponent("telegram", isDirectory: true)
    }

    var enabled: Bool { (try? db.writer.read { try Integrations.isEnabled($0, Telegram.id) }) ?? false }

    struct AppKeys: Codable { var apiId: Int; var apiHash: String }

    /// Reads the Keychain: only when the integration is on, so a fresh install asks for nothing.
    private var appKeys: AppKeys? {
        guard let text = (try? secrets.value(for: Telegram.appKeysSecretId)) ?? nil else { return nil }
        return try? JSONDecoder().decode(AppKeys.self, from: Data(text.utf8))
    }

    func setEnabled(_ on: Bool) {
        try? db.writer.write { try Integrations.setEnabled($0, Telegram.id, on) }
        restart()
    }

    func restart() {
        client?.close()
        client = nil
        account = nil
        me = nil
        error = nil
        guard enabled else { auth = .off; return }
        guard TDLibClient.isAvailable else { auth = .needsLibrary; return }
        guard appKeys != nil else { auth = .needsKeys; return }
        auth = .starting
        let current = UUID()
        generation = current
        do {
            let client = try TDLibClient { [weak self] update in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.handle(update)
                }
            }
            self.client = client
            account = TDLibAccount(client: client)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func setKeys(apiId: Int, apiHash: String) {
        guard let data = try? JSONEncoder().encode(AppKeys(apiId: apiId, apiHash: apiHash.trimmingCharacters(in: .whitespaces))) else { return }
        do {
            try secrets.setValue(String(decoding: data, as: UTF8.self), for: Telegram.appKeysSecretId)
            restart()
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Signing in

    private func handle(_ update: JSONValue) {
        guard update["@type"]?.string == "updateAuthorizationState", let state = update["authorization_state"] else { return }
        switch state["@type"]?.string {
        case "authorizationStateWaitTdlibParameters":
            sendParameters()
        case "authorizationStateWaitPhoneNumber":
            auth = .phone
        case "authorizationStateWaitCode":
            let type = state["code_info"]?["type"]?["@type"]?.string ?? ""
            auth = .code(type.contains("TelegramMessage") ? "Telegram sent a code to your other devices"
                         : type.contains("Sms") ? "A code was sent by SMS" : type.contains("Call") ? "You'll get the code in a call"
                         : "Enter the login code")
        case "authorizationStateWaitEmailAddress":
            auth = .unsupported("Telegram asks to set a login email. Do it in a Telegram app first, then sign in here.")
        case "authorizationStateWaitEmailCode":
            auth = .emailCode("Telegram sent a code to your login email")
        case "authorizationStateWaitPassword":
            auth = .password(state["password_hint"]?.string ?? "")
        case "authorizationStateWaitRegistration":
            auth = .unsupported("This number has no Telegram account. Sign up in a Telegram app first.")
        case "authorizationStateWaitOtherDeviceConfirmation":
            auth = .unsupported("Confirm the login in another Telegram app.")
        case "authorizationStateReady":
            auth = .ready
            Task { await loadMe(); await refreshChats() }
        case "authorizationStateLoggingOut", "authorizationStateClosing":
            auth = .starting
        case "authorizationStateClosed":
            // After a log-out TDLib closes; a new client starts at the phone step.
            if enabled { restart() }
        default:
            break
        }
    }

    private func sendParameters() {
        guard let keys = appKeys, let client else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var key = (try? secrets.value(for: Telegram.databaseKeySecretId)) ?? nil
            if key == nil {
                var bytes = [UInt8](repeating: 0, count: 32)
                _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                key = Data(bytes).base64EncodedString()
                try secrets.setValue(key!, for: Telegram.databaseKeySecretId)
            }
            let params: [String: Any] = [
                "@type": "setTdlibParameters", "use_test_dc": false,
                "database_directory": folder.path, "files_directory": folder.appendingPathComponent("files").path,
                "database_encryption_key": key!, "use_file_database": false, "use_chat_info_database": true,
                "use_message_database": true, "use_secret_chats": false,
                "api_id": keys.apiId, "api_hash": keys.apiHash, "system_language_code": "en",
                "device_model": "Mac", "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "application_version": "Claudist",
            ]
            submit { try await client.call(params) }
        } catch { self.error = error.localizedDescription }
    }

    func submitPhone(_ phone: String) {
        submit { [client] in try await client?.call(["@type": "setAuthenticationPhoneNumber", "phone_number": phone.filter { !$0.isWhitespace }]) }
    }

    func submitCode(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespaces)
        if case .emailCode = auth {
            submit { [client] in try await client?.call(["@type": "checkAuthenticationEmailCode",
                                                         "code": ["@type": "emailAddressAuthenticationCode", "code": code]]) }
        } else {
            submit { [client] in try await client?.call(["@type": "checkAuthenticationCode", "code": code]) }
        }
    }

    func submitPassword(_ password: String) {
        submit { [client] in try await client?.call(["@type": "checkAuthenticationPassword", "password": password]) }
    }

    func logOut() {
        submit { [client] in try await client?.call(["@type": "logOut"]) }
        try? db.writer.write { try $0.execute(sql: "UPDATE telegramChat SET access = NULL") }
    }

    private func submit(_ request: @escaping () async throws -> JSONValue?) {
        error = nil
        Task {
            do { _ = try await request() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }

    // MARK: Chats

    private func loadMe() async {
        guard let client, let user = try? await client.call(["@type": "getMe"]) else { return }
        me = TDLibAccount.userName(user)
    }

    /// The account's chat list into the database; access of known chats stays.
    func refreshChats() async {
        guard auth == .ready, let client else { return }
        loadingChats = true
        defer { loadingChats = false }
        do {
            let list: [String: Any] = ["@type": "chatListMain"]
            // loadChats fills TDLib's cache in pages and answers 404 once everything is there.
            for _ in 0..<20 {
                do { _ = try await client.call(["@type": "loadChats", "chat_list": list, "limit": 200]) } catch { break }
            }
            let ids = try await client.call(["@type": "getChats", "chat_list": list, "limit": 2000])["chat_ids"]?.array?.compactMap(\.number) ?? []
            var chats: [TelegramChat] = []
            for id in ids {
                guard let chat = try? await client.call(["@type": "getChat", "chat_id": Int64(id)]) else { continue }
                chats.append(TelegramChat(id: Int64(id), title: chat["title"]?.string ?? "Untitled", type: Telegram.chatType(chat["type"])))
            }
            let found = chats
            try await db.writer.write { try Telegram.syncChats($0, found) }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// A tool call from an agent run.
    func call(_ tool: String, arguments: JSONValue?) async -> (text: String, isError: Bool) {
        guard enabled else { return ("Telegram is turned off in Integrations", true) }
        return await Telegram.call(tool, arguments: arguments, db: db.writer, account: auth == .ready ? account : nil)
    }
}

/// `TelegramAccount` over TDLib.
final class TDLibAccount: TelegramAccount, @unchecked Sendable {
    let client: TDLibClient
    private let lock = NSLock()
    private var names: [String: String] = [:]

    init(client: TDLibClient) { self.client = client }

    static func userName(_ user: JSONValue) -> String {
        let name = [user["first_name"]?.string, user["last_name"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        let username = user["usernames"]?["active_usernames"]?.array?.first?.string
        if let username { return name.isEmpty ? "@\(username)" : "\(name) (@\(username))" }
        return name.isEmpty ? "Deleted account" : name
    }

    private func name(_ sender: JSONValue?) async -> String {
        let key: String
        let request: [String: Any]
        if let user = sender?["user_id"]?.number {
            key = "u\(Int64(user))"
            request = ["@type": "getUser", "user_id": Int64(user)]
        } else if let chat = sender?["chat_id"]?.number {
            key = "c\(Int64(chat))"
            request = ["@type": "getChat", "chat_id": Int64(chat)]
        } else { return "unknown" }
        if let known = lock.withLock({ names[key] }) { return known }
        guard let value = try? await client.call(request) else { return "unknown" }
        let name = key.hasPrefix("u") ? Self.userName(value) : value["title"]?.string ?? "unknown"
        lock.withLock { names[key] = name }
        return name
    }

    private func messages(_ raw: [JSONValue]) async -> [TelegramMessageInfo] {
        var out: [TelegramMessageInfo] = []
        for m in raw {
            let sender = await name(m["sender_id"])
            out.append(Telegram.message(m) { _ in sender })
        }
        return out
    }

    func history(chatId: Int64, limit: Int, before: Int64?) async throws -> [TelegramMessageInfo] {
        var raw: [JSONValue] = []
        var from = before ?? 0
        // TDLib answers with what it has at hand; ask again from the oldest one until there are enough.
        for _ in 0..<10 where raw.count < limit {
            let page = try await client.call(["@type": "getChatHistory", "chat_id": chatId, "from_message_id": from,
                                              "offset": 0, "limit": limit - raw.count, "only_local": false])["messages"]?.array ?? []
            guard let last = page.last?["id"]?.number else { break }
            raw += page
            from = Int64(last)
        }
        return await messages(raw)
    }

    func search(chatId: Int64, query: String, limit: Int) async throws -> [TelegramMessageInfo] {
        let found = try await client.call(["@type": "searchChatMessages", "chat_id": chatId, "query": query,
                                           "from_message_id": 0, "offset": 0, "limit": limit])
        return await messages(found["messages"]?.array ?? [])
    }

    func send(chatId: Int64, text: String, replyTo: Int64?) async throws -> Int64 {
        var request: [String: Any] = ["@type": "sendMessage", "chat_id": chatId,
                                      "input_message_content": ["@type": "inputMessageText",
                                                                "text": ["@type": "formattedText", "text": text]]]
        if let replyTo { request["reply_to"] = ["@type": "inputMessageReplyToMessage", "message_id": replyTo] }
        let sent = try await client.call(request)
        return Int64(sent["id"]?.number ?? 0)
    }
}
