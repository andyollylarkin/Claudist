import Foundation
import GRDB
import Security

/// A named secret. `name` is the environment variable the agent sees, e.g. GITHUB_TOKEN.
/// The value is kept in a `SecretStore` (Keychain), never in the database.
public struct Secret: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: ID = newID()
    public var name: String
    public var description = ""
    /// The variable holds a path to a private temp file with the value (for `ssh -i`, certificates)
    /// instead of the value itself.
    public var asFile = false
    public var createdAt = LocalDate.stamp(Date())
    public var updatedAt = LocalDate.stamp(Date())

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }

    /// Environment variable name rules: letters, digits, underscore; not starting with a digit.
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    /// Variables Claude Code or the system rely on; overriding them breaks runs or login.
    public static let reservedNames: Set<String> = [
        "PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR",
    ]
}

public struct AgentSecret: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var agentId: ID
    public var secretId: ID
    public init(agentId: ID, secretId: ID) { self.agentId = agentId; self.secretId = secretId }
}

public struct SkillSecret: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var skillName: String
    public var secretId: ID
    public init(skillName: String, secretId: ID) { self.skillName = skillName; self.secretId = secretId }
}

public protocol SecretStore: Sendable {
    func value(for id: ID) throws -> String?
    func setValue(_ value: String, for id: ID) throws
    func remove(_ id: ID) throws
}

/// All secrets in one generic-password item of the login Keychain (a JSON map id → value),
/// read once per app launch and kept in memory. macOS ties a Keychain item's access to the
/// app's exact build (cdhash) for self-signed apps, so every update asks for the password once
/// per item: one item means one prompt per update, not one per secret.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    static let vaultAccount = "vault"

    public init(service: String = "io.mindsw.agentdesk.secrets") {
        self.service = service
    }

    public func value(for id: ID) throws -> String? {
        try Vault.shared(service).withValues { $0[id] }
    }

    public func setValue(_ value: String, for id: ID) throws {
        try Vault.shared(service).change { $0[id] = value }
    }

    public func remove(_ id: ID) throws {
        try Vault.shared(service).change { $0[id] = nil }
    }

    /// The in-memory copy of one service's vault; loaded (and older per-secret items moved in) on first use.
    final class Vault: @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var vaults: [String: Vault] = [:]

        static func shared(_ service: String) -> Vault {
            lock.withLock {
                if let v = vaults[service] { return v }
                let v = Vault(service: service)
                vaults[service] = v
                return v
            }
        }

        let service: String
        private let lock = NSLock()
        private var values: [String: String]?

        init(service: String) { self.service = service }

        func withValues<T>(_ body: ([String: String]) -> T) throws -> T {
            try lock.withLock { body(try loaded()) }
        }

        func change(_ body: (inout [String: String]) -> Void) throws {
            try lock.withLock {
                var v = try loaded()
                body(&v)
                try write(v)
                values = v
            }
        }

        private func loaded() throws -> [String: String] {
            if let values { return values }
            var v: [String: String] = [:]
            if let data = try read(account: KeychainSecretStore.vaultAccount) {
                v = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            }
            // Items from before the vault: move them in, then drop them.
            let legacy = try legacyAccounts()
            if !legacy.isEmpty {
                for account in legacy where v[account] == nil {
                    if let data = try read(account: account) { v[account] = String(decoding: data, as: UTF8.self) }
                }
                try write(v)
                for account in legacy { _ = SecItemDelete(query(account) as CFDictionary) }
            }
            values = v
            return v
        }

        private func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }

        private func read(account: String) throws -> Data? {
            var q = query(account)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status) }
            return data
        }

        /// Accounts of the per-secret items (attributes only: listing them doesn't ask for access).
        private func legacyAccounts() throws -> [String] {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
            var out: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw KeychainError(status) }
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
                .filter { $0 != KeychainSecretStore.vaultAccount }
        }

        private func write(_ v: [String: String]) throws {
            let data = try JSONEncoder().encode(v)
            let status = SecItemUpdate(query(KeychainSecretStore.vaultAccount) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var q = query(KeychainSecretStore.vaultAccount)
                q[kSecValueData as String] = data
                q[kSecAttrLabel as String] = "Claudist secrets"
                let add = SecItemAdd(q as CFDictionary, nil)
                guard add == errSecSuccess else { throw KeychainError(add) }
            } else if status != errSecSuccess {
                throw KeychainError(status)
            }
        }
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public init(_ status: OSStatus) { self.status = status }
    public var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        return "Keychain: \(text)"
    }
}

/// In-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [ID: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func value(for id: ID) throws -> String? { lock.withLock { values[id] } }
    public func setValue(_ value: String, for id: ID) throws { lock.withLock { values[id] = value } }
    public func remove(_ id: ID) throws { _ = lock.withLock { values.removeValue(forKey: id) } }
}

public enum Secrets {
    /// Secrets an agent run receives: linked to the agent directly or to any of its skills.
    /// `via` lists where each secret comes from ("agent" or skill names).
    public static func resolve(_ db: Database, agentId: ID) throws -> [(secret: Secret, via: [String])] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.*, 'agent' AS via FROM secret s JOIN agentSecret a ON a.secretId = s.id WHERE a.agentId = ?
            UNION ALL
            SELECT s.*, k.skillName AS via FROM secret s
              JOIN skillSecret k ON k.secretId = s.id
              JOIN agentSkill g ON g.skillName = k.skillName
             WHERE g.agentId = ?
            """, arguments: [agentId, agentId])
        var order: [ID] = []
        var map: [ID: (Secret, [String])] = [:]
        for row in rows {
            let secret = try Secret(row: row)
            if map[secret.id] == nil { order.append(secret.id); map[secret.id] = (secret, []) }
            map[secret.id]!.1.append(row["via"])
        }
        return order.map { (map[$0]!.0, map[$0]!.1) }
            .sorted { $0.0.name < $1.0.name }
            .map { (secret: $0.0, via: $0.1) }
    }

    /// Environment variables for a run, and the raw values (for redaction).
    /// File secrets are written to `fileDir` (0600) and the variable holds the path;
    /// the caller deletes `fileDir` when the run ends. Throws if a secret has no value.
    public static func environment(_ secrets: [Secret], store: SecretStore, fileDir: URL? = nil) throws
        -> (env: [String: String], values: [String: String]) {
        var env: [String: String] = [:]
        var values: [String: String] = [:]
        for secret in secrets {
            guard let value = try store.value(for: secret.id) else {
                throw ClaudistError.invalid("Secret \(secret.name) has no value. Set it in Secrets.")
            }
            values[secret.name] = value
            if secret.asFile {
                guard let fileDir else { throw ClaudistError.invalid("No folder for secret files") }
                let fm = FileManager.default
                try fm.createDirectory(at: fileDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = fileDir.appendingPathComponent(secret.name)
                // OpenSSH rejects keys without a trailing newline.
                let text = value.hasSuffix("\n") ? value : value + "\n"
                fm.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
                env[secret.name] = file.path
            } else {
                env[secret.name] = value
            }
        }
        return (env, values)
    }

    /// Tells the agent which secrets it has, so it uses them instead of hunting for credentials.
    public static func promptSection(_ secrets: [Secret]) -> String? {
        guard !secrets.isEmpty else { return nil }
        let lines = secrets.map { s -> String in
            let what = s.asFile ? "path to a file with the value (e.g. `ssh -i \"$\(s.name)\"`)" : "the value"
            return "- `$\(s.name)` — \(what)" + (s.description.isEmpty ? "" : ". \(s.description)")
        }
        return """
            ## Credentials
            These environment variables are set for you. Use them for credentials and never look for keys, \
            passwords or tokens elsewhere on disk. Do not print their values.
            """ + "\n" + lines.joined(separator: "\n")
    }
}
