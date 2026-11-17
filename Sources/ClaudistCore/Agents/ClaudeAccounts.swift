import Foundation
import GRDB

/// Another Claude to run on: a subscription (a `claude setup-token` token) or an API key.
/// The secret lives in the Keychain; Claude Code takes it from the environment, which wins
/// over this Mac's own login.
public struct ClaudeAccount: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case subscription, apiKey

        public var title: String { self == .subscription ? "Subscription" : "API key" }
    }

    public var id: ID = newID()
    public var name: String
    public var kind: Kind
    public var itemOrder = 0
    public var createdAt = LocalDate.stamp(Date())

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public var secretId: String { "claudist.account.\(id)" }
}

public enum ClaudeAccounts {
    /// `agent.accountId` value for this Mac's own login (nil there means "the default").
    public static let macLogin = "mac"
    /// UserDefaults key of the default account id; unset or `macLogin` = this Mac's login.
    public static let defaultKey = "accounts.default"

    public static var defaultId: ID? {
        let id = UserDefaults.standard.string(forKey: defaultKey)
        return id == macLogin ? nil : id
    }

    /// The account an agent runs on; nil = this Mac's login (or, in a container, the container token).
    public static func resolve(_ db: Database, agent: Agent?) throws -> ClaudeAccount? {
        let id = agent?.accountId ?? defaultId
        guard let id, id != macLogin else { return nil }
        // A deleted account falls back to the default, then to the Mac's login.
        if let account = try ClaudeAccount.fetchOne(db, key: id) { return account }
        if let fallback = defaultId, fallback != id { return try ClaudeAccount.fetchOne(db, key: fallback) }
        return nil
    }

    /// The account boundary an agent lives in: an account id, or `macLogin`.
    public static func scope(_ db: Database, agent: Agent) throws -> String {
        try resolve(db, agent: agent)?.id ?? macLogin
    }

    /// Agents on other accounts: their tasks, folders and memory are out of this agent's reach.
    public static func otherAccountAgents(_ db: Database, of agent: Agent) throws -> [Agent] {
        let own = try scope(db, agent: agent)
        return try Agent.fetchAll(db).filter { $0.id != agent.id }.filter { try scope(db, agent: $0) != own }
    }

    /// Paths an agent must not read or write: other accounts' agent folders, their container homes
    /// and Claude Code project folders (sessions, auto-memory), and the app's database.
    public static func foreignPaths(_ others: [Agent], own: Agent, paths: AppPaths, hostConfig: URL) -> [String] {
        guard !others.isEmpty else { return [] }
        let mine = URL(fileURLWithPath: own.folderPath).standardizedFileURL.path
        var out: [String] = []
        for other in others {
            let folder = URL(fileURLWithPath: other.folderPath).standardizedFileURL.path
            // A folder above the agent's own would lock the agent out of itself; sharing one is refused at launch.
            if folder != mine && !mine.hasPrefix(folder + "/") { out.append(folder) }
            let key = SessionFiles.projectKey(URL(fileURLWithPath: other.folderPath))
            out.append(paths.root.appendingPathComponent("containers/homes/\(key)").path)
            out.append(hostConfig.appendingPathComponent("projects/\(key)").path)
        }
        return Array(Set(out)).sorted()
    }

    /// Variables that make Claude Code use the account.
    public static func environment(_ account: ClaudeAccount?, secrets: SecretStore) throws -> [String: String] {
        guard let account else { return [:] }
        guard let value = try secrets.value(for: account.secretId), !value.isEmpty else {
            throw ClaudistError.invalid("The Claude account “\(account.name)” has no token; add it again in Settings → Claude accounts")
        }
        return account.kind == .subscription ? ["CLAUDE_CODE_OAUTH_TOKEN": value] : ["ANTHROPIC_API_KEY": value]
    }

    public static func save(_ db: Database, _ account: ClaudeAccount, secret: String, secrets: SecretStore) throws {
        let value = DockerEngine.cleanToken(secret)
        guard !value.isEmpty else { throw ClaudistError.invalid("Paste the token or key") }
        try secrets.setValue(value, for: account.secretId)
        try account.save(db)
    }

    /// Removes the account; its agents go back to the default.
    public static func remove(_ db: Database, _ account: ClaudeAccount, secrets: SecretStore) throws {
        try db.execute(sql: "UPDATE agent SET accountId = NULL WHERE accountId = ?", arguments: [account.id])
        _ = try account.delete(db)
        try? secrets.remove(account.secretId)
        if UserDefaults.standard.string(forKey: defaultKey) == account.id { UserDefaults.standard.removeObject(forKey: defaultKey) }
    }

    /// The default account's variables; set by the app (it holds the database and the Keychain).
    nonisolated(unsafe) public static var defaultAccountEnvironment: @Sendable () -> [String: String] = { [:] }

    /// For Claude Code calls that aren't an agent's (assistant, generators): the default account.
    public static func defaultHostEnvironment() -> [String: String] {
        hostEnvironment(defaultAccountEnvironment())
    }

    /// Claude Code's host environment on an account: the account's credential replaces any other.
    public static func hostEnvironment(_ accountEnv: [String: String]) -> [String: String] {
        var env = ClaudeCLI.environment()
        if !accountEnv.isEmpty {
            env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
        }
        return env.merging(accountEnv) { _, new in new }
    }
}

extension UsageLimits {
    /// The latest report for one account (nil = this Mac's login); the assistant's chats count
    /// for the account that is the default.
    public static func latest(_ db: Database, accountId: ID?) throws -> UsageLimits? {
        var rows = try Row.fetchAll(db, sql: """
            SELECT e.json, e.createdAt FROM runEvent e JOIN run r ON r.id = e.runId
             WHERE e.kind = 'rate_limit_event' AND r.accountId IS ? ORDER BY e.seq DESC LIMIT 1
            """, arguments: [accountId])
        if accountId == ClaudeAccounts.defaultId {
            rows += try Row.fetchAll(db, sql: "SELECT json, createdAt FROM assistantEvent WHERE kind = 'rate_limit_event' ORDER BY seq DESC LIMIT 1")
        }
        return rows.compactMap { UsageLimits(json: $0["json"], observedAt: $0["createdAt"]) }.max { $0.observedAt < $1.observedAt }
    }

    /// The probe on an account.
    public static func probe(environment: [String: String]) throws -> UsageLimits? {
        let r = try ClaudeCLI.runSync(try ClaudeCLI.executable(), probeArguments(), env: ClaudeAccounts.hostEnvironment(environment),
                                      cwd: FileManager.default.temporaryDirectory)
        if let limits = fromStream(r.out, observedAt: LocalDate.stamp(Date())) { return limits }
        if r.status != 0 { throw ClaudistError.invalid(r.err.isEmpty ? "Claude Code exited with code \(r.status)" : r.err) }
        return nil
    }
}
