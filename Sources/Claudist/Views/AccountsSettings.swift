import AppKit
import ClaudistCore
import SwiftUI

/// Settings card: Claude accounts besides this Mac's login. Each agent picks one in its Runtime card.
struct AccountsSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(ClaudeAccounts.defaultKey) private var defaultId = ClaudeAccounts.macLogin
    @State private var adding = false
    @State private var name = ""
    @State private var kind = ClaudeAccount.Kind.subscription
    @State private var secret = ""
    @State private var error: String?
    /// Account id ("mac" for the login) → its last limits or a check's error.
    @State private var usage: [String: String] = [:]
    @State private var checking: Set<String> = []

    var body: some View {
        Card(title: "Claude accounts", footer: "Agents use the default account unless their Runtime card names another. A subscription account takes a token from `claude setup-token` (signed in to that account in the browser); an API key bills the Console. Tokens and keys are kept in the Keychain.") {
            row(id: ClaudeAccounts.macLogin, title: "This Mac's login", subtitle: "Claude Code's own sign-in", removable: nil)
            ForEach(store.claudeAccounts) { account in
                row(id: account.id, title: account.name, subtitle: account.kind.title, removable: account)
            }
            if adding {
                form
            } else {
                HStack {
                    Button { adding = true } label: { SwiftUI.Label("Add account", systemImage: "plus") }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    Spacer()
                }
                .padding(14)
            }
        }
        .onAppear(perform: loadUsage)
    }

    private func row(id: String, title: String, subtitle: String, removable: ClaudeAccount?) -> some View {
        let isDefault = (defaultId.isEmpty ? ClaudeAccounts.macLogin : defaultId) == id
        let agents = store.agents.filter { ($0.accountId ?? (isDefault ? "" : "-")) == id || ($0.accountId == nil && isDefault) }
        return FieldRow(title: title + (isDefault ? " · default" : ""),
                        subtitle: [subtitle, agents.isEmpty ? nil : "\(agents.count) agent\(agents.count == 1 ? "" : "s")", usage[id]]
                            .compactMap { $0 }.joined(separator: " · ")) {
            HStack(spacing: 6) {
                if checking.contains(id) { ProgressView().controlSize(.small) }
                Button("Check") { check(id) }.buttonStyle(AccentButtonStyle(prominent: false)).disabled(checking.contains(id))
                    .help("A tiny Haiku call that shows this account's limits")
                if !isDefault {
                    Button("Make default") {
                        defaultId = id
                        store.defaultAccountChanged += 1
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                }
                if let removable {
                    Button("Remove") { remove(removable) }.buttonStyle(AccentButtonStyle(prominent: false))
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name, e.g. Work", text: $name).textFieldStyle(.roundedBorder).frame(width: 160)
                Picker("", selection: $kind) {
                    ForEach(ClaudeAccount.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                SecureField(kind == .subscription ? "sk-ant-oat…" : "sk-ant-api…", text: $secret).textFieldStyle(.roundedBorder)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.red) }
            HStack(spacing: 8) {
                if kind == .subscription {
                    Button("Get token…") { SetupToken.open(store) }.buttonStyle(AccentButtonStyle(prominent: false))
                        .help("Opens Terminal with `claude setup-token`; sign in with the account you're adding")
                }
                Spacer()
                Button("Cancel") { reset() }.buttonStyle(AccentButtonStyle(prominent: false))
                Button("Add") { add() }.buttonStyle(AccentButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || secret.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if kind == .subscription {
                Text("In the browser that opens, sign in to the Claude account you are adding (use a private window if another account is signed in).")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(14)
    }

    private func add() {
        var account = ClaudeAccount(name: name.trimmingCharacters(in: .whitespaces), kind: kind)
        account.itemOrder = (store.claudeAccounts.map(\.itemOrder).max() ?? 0) + 1
        do {
            try store.db.writer.write { try ClaudeAccounts.save($0, account, secret: secret, secrets: store.secretStore) }
            reset()
            check(account.id)
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    private func remove(_ account: ClaudeAccount) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(account.name)”?"
        alert.informativeText = "Its token is deleted from the Keychain; agents on it go back to the default account."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.write { try ClaudeAccounts.remove($0, account, secrets: store.secretStore) }
        defaultId = UserDefaults.standard.string(forKey: ClaudeAccounts.defaultKey) ?? ClaudeAccounts.macLogin
        store.defaultAccountChanged += 1
    }

    private func reset() {
        adding = false
        name = ""
        secret = ""
        error = nil
        kind = .subscription
    }

    private func loadUsage() {
        for id in [ClaudeAccounts.macLogin] + store.claudeAccounts.map(\.id) {
            let key: ID? = id == ClaudeAccounts.macLogin ? nil : id
            if let limits = store.read({ try UsageLimits.latest($0, accountId: key) }) ?? nil { usage[id] = Self.describe(limits) }
        }
    }

    private func check(_ id: String) {
        let account = store.claudeAccounts.first { $0.id == id }
        let env: [String: String]
        do { env = try ClaudeAccounts.environment(account, secrets: store.secretStore) } catch {
            usage[id] = (error as? LocalizedError)?.errorDescription
            return
        }
        checking.insert(id)
        Task.detached {
            let result = Result { try UsageLimits.probe(environment: env) }
            await MainActor.run {
                checking.remove(id)
                switch result {
                case .success(let limits?): usage[id] = Self.describe(limits)
                case .success(nil): usage[id] = "works; no limits reported"
                case .failure(let e): usage[id] = "check failed: " + ((e as? LocalizedError)?.errorDescription ?? "\(e)").prefix(160)
                }
            }
        }
    }

    static func describe(_ limits: UsageLimits) -> String {
        limits.windows.map { "\($0.short) \(Int($0.utilization * 100))%" }.joined(separator: ", ")
    }
}
