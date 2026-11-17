import CommonCrypto
import CryptoKit
import Foundation
import GRDB

/// Locked tasks: their description and comments are encrypted with a key that only the
/// master password opens.
///
/// - The data key is a random 256-bit AES key. It is stored wrapped (AES-GCM) with a key derived
///   from the master password (PBKDF2-SHA256), so changing the password rewraps one key.
/// - Records encrypt and decrypt themselves on the way to and from the database
///   (`TaskItem`, `Comment`): while the vault is open the app works with plain text; while it is
///   closed it only ever holds the ciphertext. Triggers refuse plain text in a locked task.
/// - The vault opens with the password and stays open until Claudist quits or `close()`.
public enum TaskVault {
    public static let prefix = "enc:v1:"
    public static let defaultRounds = 600_000

    public enum VaultError: LocalizedError, Equatable {
        case notConfigured, alreadyConfigured, wrongPassword, closed, weakPassword

        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "Set a master password first"
            case .alreadyConfigured: return "A master password is already set"
            case .wrongPassword: return "Wrong master password"
            case .closed: return "Locked tasks are closed; enter the master password first"
            case .weakPassword: return "Use at least 6 characters for the master password"
            }
        }
    }

    private static let state = State()
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var key: SymmetricKey?
    }

    // MARK: Opening

    public static var isOpen: Bool { state.lock.withLock { state.key != nil } }

    public static func isConfigured(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM vault)") ?? false
    }

    /// Sets the master password the first time, and opens the vault.
    public static func configure(_ db: Database, password: String, rounds: Int = defaultRounds) throws {
        guard try !isConfigured(db) else { throw VaultError.alreadyConfigured }
        guard password.count >= 6 else { throw VaultError.weakPassword }
        let dataKey = SymmetricKey(size: .bits256)
        try store(db, dataKey: dataKey, password: password, rounds: rounds)
        state.lock.withLock { state.key = dataKey }
    }

    public static func open(_ db: Database, password: String) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT salt, rounds, wrappedKey FROM vault") else { throw VaultError.notConfigured }
        let kek = try derive(password, salt: row["salt"], rounds: row["rounds"])
        do {
            let box = try AES.GCM.SealedBox(combined: row["wrappedKey"] as Data)
            let raw = try AES.GCM.open(box, using: kek)
            state.lock.withLock { state.key = SymmetricKey(data: raw) }
        } catch {
            throw VaultError.wrongPassword
        }
    }

    public static func changePassword(_ db: Database, old: String, new: String, rounds: Int = defaultRounds) throws {
        guard new.count >= 6 else { throw VaultError.weakPassword }
        try open(db, password: old)
        guard let key = state.lock.withLock({ state.key }) else { throw VaultError.closed }
        try db.execute(sql: "DELETE FROM vault")
        try store(db, dataKey: key, password: new, rounds: rounds)
    }

    /// Forgets the key; locked tasks show only their titles again.
    public static func close() {
        state.lock.withLock { state.key = nil }
    }

    private static func store(_ db: Database, dataKey: SymmetricKey, password: String, rounds: Int) throws {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let kek = try derive(password, salt: salt, rounds: rounds)
        let wrapped = try AES.GCM.seal(dataKey.withUnsafeBytes { Data($0) }, using: kek).combined!
        try db.execute(sql: "INSERT INTO vault (id, salt, rounds, wrappedKey) VALUES (1, ?, ?, ?)",
                       arguments: [salt, rounds, wrapped])
    }

    static func derive(_ password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        let status = out.withUnsafeMutableBytes { outBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                     outBytes.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw ClaudistError.invalid("Key derivation failed") }
        return SymmetricKey(data: out)
    }

    // MARK: Text

    public static func isSealed(_ text: String) -> Bool { text.hasPrefix(prefix) }

    /// Ciphertext of `text` (empty stays empty). Throws when the vault is closed.
    public static func seal(_ text: String) throws -> String {
        guard !text.isEmpty, !isSealed(text) else { return text }
        guard let key = state.lock.withLock({ state.key }) else { throw VaultError.closed }
        return prefix + (try AES.GCM.seal(Data(text.utf8), using: key).combined!).base64EncodedString()
    }

    /// Plain text of `text`, or nil when the vault is closed or the text doesn't open with its key.
    public static func reveal(_ text: String) -> String? {
        guard isSealed(text) else { return text }
        guard let key = state.lock.withLock({ state.key }),
              let data = Data(base64Encoded: String(text.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    /// What tools and prompts show for text that stays sealed.
    public static let hiddenText = "[locked — the user must enter Claudist's master password to show this]"

    // MARK: Tasks

    /// Encrypts the task's description and comments.
    public static func lock(_ db: Database, taskId: ID) throws {
        guard isOpen else { throw try isConfigured(db) ? VaultError.closed : VaultError.notConfigured }
        guard var task = try TaskItem.fetchOne(db, key: taskId), !task.isLocked else { return }
        for var c in try Comment.filter(Column("taskId") == taskId).fetchAll(db) {
            c.isLocked = true
            try c.update(db)
        }
        task.isLocked = true
        try task.update(db)
    }

    /// Removes the lock: the description and comments are stored as plain text again.
    public static func unlock(_ db: Database, taskId: ID) throws {
        guard isOpen else { throw VaultError.closed }
        guard var task = try TaskItem.fetchOne(db, key: taskId), task.isLocked else { return }
        task.isLocked = false
        try task.update(db)
        for var c in try Comment.filter(Column("taskId") == taskId).fetchAll(db) {
            c.isLocked = false
            try c.update(db)
        }
    }

    public static func isLocked(_ db: Database, taskId: ID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT isLocked FROM task WHERE id = ?", arguments: [taskId]) ?? false
    }

    /// Schema: the vault row, lock flags, and triggers that keep plain text out of locked tasks.
    static func migrate(_ db: Database) throws {
        try db.create(table: "vault") { t in
            t.primaryKey("id", .integer).check { $0 == 1 }
            t.column("salt", .blob).notNull()
            t.column("rounds", .integer).notNull()
            t.column("wrappedKey", .blob).notNull()
        }
        try db.alter(table: "task") { t in t.add(column: "isLocked", .boolean).notNull().defaults(to: false) }
        try db.alter(table: "comment") { t in t.add(column: "isLocked", .boolean).notNull().defaults(to: false) }
        let plain = { (column: String) in "NEW.\(column) != '' AND substr(NEW.\(column), 1, \(prefix.count)) != '\(prefix)'" }
        let message = "'This task is locked: its text must be encrypted'"
        for event in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER task_locked_\(event.lowercased()) BEFORE \(event) ON task
                WHEN NEW.isLocked = 1 AND \(plain("description"))
                BEGIN SELECT RAISE(ABORT, \(message)); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER comment_locked_\(event.lowercased()) BEFORE \(event) ON comment
                WHEN (NEW.isLocked = 1 OR (SELECT isLocked FROM task WHERE id = NEW.taskId) = 1) AND \(plain("content"))
                BEGIN SELECT RAISE(ABORT, \(message)); END
                """)
        }
    }
}

// MARK: Records encrypt themselves

/// The record's stored form, with the Codable-based GRDB defaults.
private struct StoredRecord<T: Codable>: Codable, FetchableRecord, EncodableRecord {
    var value: T
    init(_ value: T) { self.value = value }
    init(from decoder: Decoder) throws { value = try T(from: decoder) }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension TaskItem {
    public init(row: Row) throws {
        self = try StoredRecord<TaskItem>(row: row).value
        if isLocked, let plain = TaskVault.reveal(description) { description = plain }
    }

    public func encode(to container: inout PersistenceContainer) throws {
        var stored = self
        if isLocked { stored.description = try TaskVault.seal(description) }
        try StoredRecord(stored).encode(to: &container)
    }

    /// The description is encrypted and the vault is closed.
    public var isSealed: Bool { isLocked && TaskVault.isSealed(description) }
}

extension Comment {
    public init(row: Row) throws {
        self = try StoredRecord<Comment>(row: row).value
        if isLocked, let plain = TaskVault.reveal(content) { content = plain }
    }

    public func encode(to container: inout PersistenceContainer) throws {
        var stored = self
        if isLocked { stored.content = try TaskVault.seal(content) }
        try StoredRecord(stored).encode(to: &container)
    }

    public var isSealed: Bool { isLocked && TaskVault.isSealed(content) }

    /// A new comment on the task, encrypted when the task is locked.
    public static func make(_ db: Database, taskId: ID, content: String, author: String = "user") throws -> Comment {
        var c = Comment(taskId: taskId, content: content, author: author)
        c.isLocked = try TaskVault.isLocked(db, taskId: taskId)
        return c
    }
}
