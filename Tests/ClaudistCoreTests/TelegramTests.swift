import Foundation
import GRDB
import Testing
@testable import ClaudistCore

private final class FakeAccount: TelegramAccount, @unchecked Sendable {
    var sent: [(Int64, String, Int64?)] = []
    func history(chatId: Int64, limit: Int, before: Int64?) async throws -> [TelegramMessageInfo] {
        [TelegramMessageInfo(id: 3, sender: "Ann", date: Date(timeIntervalSince1970: 200), text: "second", replyTo: 2),
         TelegramMessageInfo(id: 2, sender: "Me", date: Date(timeIntervalSince1970: 100), text: "first", outgoing: true)].prefix(limit).map { $0 }
    }
    func search(chatId: Int64, query: String, limit: Int) async throws -> [TelegramMessageInfo] { [] }
    func send(chatId: Int64, text: String, replyTo: Int64?) async throws -> Int64 {
        sent.append((chatId, text, replyTo))
        return Int64(sent.count)
    }
}

struct TelegramTests {
    private func database() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try Telegram.syncChats(db, [TelegramChat(id: 42, title: "Ann", type: "private"),
                                        TelegramChat(id: -100, title: "Team", type: "group"),
                                        TelegramChat(id: 7, title: "Bank", type: "private")])
        }
        return db
    }

    @Test func chatsStartClosedAndKeepAccessOnSync() throws {
        let db = try database()
        try db.writer.write { db in
            try db.execute(sql: "UPDATE telegramChat SET access = 'ro' WHERE id = 42")
            try Telegram.syncChats(db, [TelegramChat(id: 42, title: "Ann K", type: "private"), TelegramChat(id: 9, title: "New", type: "group")])
        }
        let chats = try db.writer.read { try TelegramChat.fetchAll($0) }
        #expect(chats.first { $0.id == 42 }?.access == .ro)
        #expect(chats.first { $0.id == 42 }?.title == "Ann K")
        #expect(chats.first { $0.id == 9 }?.access == nil)
    }

    @Test func toolsFollowPerChatAccess() async throws {
        let db = try database()
        let account = FakeAccount()
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE telegramChat SET access = 'ro' WHERE id = 42")
            try db.execute(sql: "UPDATE telegramChat SET access = 'rw' WHERE id = -100")
        }
        var (text, isError) = await Telegram.call(Telegram.listChats, arguments: nil, db: db.writer, account: account)
        #expect(!isError && text.contains("Ann") && text.contains("Team") && !text.contains("Bank"))

        // Closed chat: neither read nor send.
        (text, isError) = await Telegram.call(Telegram.readMessages, arguments: .object(["chat": .string("Bank")]), db: db.writer, account: account)
        #expect(isError && text.contains("No Telegram chat"))

        (text, isError) = await Telegram.call(Telegram.readMessages, arguments: .object(["chat": .string("42")]), db: db.writer, account: account)
        let messages = JSONValue.parse(text)?["messages"]?.array ?? []
        #expect(messages.map { $0["text"]?.string } == ["first", "second"])
        #expect(messages.first?["from"]?.string == "me (the user)")

        // Read-only chat refuses sending; read & send works.
        (text, isError) = await Telegram.call(Telegram.sendMessage, arguments: .object(["chat": .string("Ann"), "text": .string("hi")]), db: db.writer, account: account)
        #expect(isError && text.contains("read-only"))
        (_, isError) = await Telegram.call(Telegram.sendMessage, arguments: .object(["chat": .string("team"), "text": .string("hi"), "reply_to": .number(5)]), db: db.writer, account: account)
        #expect(!isError)
        #expect(account.sent.count == 1 && account.sent[0].0 == -100 && account.sent[0].2 == 5)

        (text, isError) = await Telegram.call(Telegram.readMessages, arguments: .object(["chat": .string("42")]), db: db.writer, account: nil)
        #expect(isError && text.contains("not signed in"))
    }

    @Test func readsTDLibMessages() {
        let m = JSONValue.parse(#"{"id": 5, "date": 100, "is_outgoing": false, "sender_id": {"@type": "messageSenderUser", "user_id": 1}, "content": {"@type": "messageDocument", "document": {"file_name": "a.pdf"}, "caption": {"text": "contract"}}, "reply_to": {"@type": "messageReplyToMessage", "message_id": 4}}"#)!
        let info = Telegram.message(m) { _ in "Ann" }
        #expect(info.text == "[document a.pdf] contract")
        #expect(info.replyTo == 4)
        #expect(Telegram.chatType(JSONValue.parse(#"{"@type": "chatTypeSupergroup", "is_channel": true}"#)) == "channel")
    }

    @Test func grantedOnlyWhenOnAndAllowedInSettings() throws {
        let db = try AppDatabase.inMemory()
        let agent = Agent(name: "Bot user", folderPath: "/tmp/bot-user")
        try db.writer.write { db in
            try agent.insert(db)
            try Integrations.setGranted(db, agentId: agent.id, Telegram.id, true)
        }
        #expect(try db.writer.read { try Integrations.granted($0, agentId: agent.id) }.isEmpty)
        try db.writer.write { try Integrations.setEnabled($0, Telegram.id, true) }
        let granted = try db.writer.read { try Integrations.granted($0, agentId: agent.id) }
        #expect(granted == [Telegram.id])

        var config = AgentLaunchConfig(agent: agent, skills: [], storages: [])
        config.integrations = granted
        let workspace = AgentWorkspace(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let allow = (workspace.settings(config)["permissions"] as? [String: Any])?["allow"] as? [String] ?? []
        #expect(allow.contains("mcp__claudist__telegram_send_message"))
        let args = workspace.arguments(config, settingsURL: URL(fileURLWithPath: "/tmp/s.json"), resume: nil)
        #expect(args.joined(separator: " ").contains("## Telegram"))
    }

    @Test func splitsLongText() {
        let line = String(repeating: "a", count: 3000)
        #expect(Telegram.split(line + "\n" + line) == [line, line])
        #expect(Telegram.split(String(repeating: "b", count: 5000)).map(\.count) == [4096, 904])
    }
}

struct TDLibSmokeTests {
    /// Loads libtdjson and asks for its version: no network, no account.
    @Test(.enabled(if: TDLibClient.isAvailable)) func libraryAnswers() async throws {
        let states = Locked<[String]>([])
        let client = try TDLibClient { update in
            if let s = update["authorization_state"]?["@type"]?.string { states.withLock { $0.append(s) } }
        }
        let version = try await client.call(["@type": "getOption", "name": "version"])
        #expect(version["value"]?.string?.isEmpty == false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(states.withLock { $0 }.contains("authorizationStateWaitTdlibParameters"))
        client.close()
    }
}

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}
