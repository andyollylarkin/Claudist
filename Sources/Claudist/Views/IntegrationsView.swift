import ClaudistCore
import GRDB
import SwiftUI

/// Services built into the app that agents use through Claudist's tools. Telegram first.
struct IntegrationsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Integrations",
                               subtitle: "Built into Claudist: the app holds the credentials, agents get tools only when you allow them",
                               icon: "puzzlepiece.extension.fill", iconColor: Theme.accent)
                    TelegramSettings(telegram: store.telegram)
                }
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
    }
}

private struct TelegramState: Equatable {
    var enabled = false
    var chats: [TelegramChat] = []
    var agents: Set<ID> = []
}

private struct TelegramSettings: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var telegram: TelegramService
    @StateObject private var state = Observed(TelegramState())
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var search = ""
    @State private var openOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill").font(.system(size: 18)).foregroundStyle(Color(hex: 0x2AABEE))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Telegram").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                    Text(Integrations.info(Telegram.id)?.summary ?? "").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { state.value.enabled }, set: { telegram.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            if let error = telegram.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            if state.value.enabled {
                account
                if telegram.auth == .ready {
                    chats
                    agents
                }
            }
        }
        .onAppear {
            state.observe(store.db) { db in
                TelegramState(enabled: try Integrations.isEnabled(db, Telegram.id),
                              chats: try TelegramChat.order(Column("position")).fetchAll(db),
                              agents: try Integrations.agents(db, Telegram.id))
            }
        }
    }

    @ViewBuilder private var account: some View {
        switch telegram.auth {
        case .off, .starting:
            Card(title: "Account") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to Telegram…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .padding(14)
            }
        case .needsLibrary:
            Card(title: "Account", footer: "TDLib is Telegram's official client library; Claudist signs in to your account through it.") {
                FieldRow(title: "TDLib is not installed", subtitle: "In Terminal: brew install tdlib", last: true) {
                    Button("Check again") { telegram.restart() }.buttonStyle(AccentButtonStyle(prominent: false))
                }
            }
        case .needsKeys:
            Card(title: "Telegram app keys", footer: "Telegram lets a program use your account only with keys of your own: open my.telegram.org → API development tools, create an app (any name), and copy App api_id and App api_hash. They are kept in the Keychain.") {
                FieldRow(title: "api_id") {
                    TextField("1234567", text: $apiId).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                FieldRow(title: "api_hash", last: true) {
                    HStack(spacing: 6) {
                        SecureField("0123456789abcdef…", text: $apiHash).textFieldStyle(.roundedBorder).frame(width: 240)
                        Button("Save") {
                            if let id = Int(apiId.trimmingCharacters(in: .whitespaces)) { telegram.setKeys(apiId: id, apiHash: apiHash) }
                        }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(Int(apiId.trimmingCharacters(in: .whitespaces)) == nil || apiHash.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack {
                    Link("Open my.telegram.org", destination: URL(string: "https://my.telegram.org/apps")!).font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }
        case .phone:
            step("Sign in", "Your phone number in international format", footer: "Telegram sends a login code to your other Telegram apps (or by SMS).") {
                TextField("+7 999 123-45-67", text: $phone).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit { telegram.submitPhone(phone) }
                Button("Next") { telegram.submitPhone(phone) }.buttonStyle(AccentButtonStyle()).disabled(phone.count < 5)
            }
        case .code(let hint), .emailCode(let hint):
            step("Login code", hint, footer: "Never share this code with anyone else.") {
                TextField("12345", text: $code).textFieldStyle(.roundedBorder).frame(width: 120).onSubmit { telegram.submitCode(code); code = "" }
                Button("Sign in") { telegram.submitCode(code); code = "" }.buttonStyle(AccentButtonStyle()).disabled(code.isEmpty)
            }
        case .password(let hint):
            step("Two-step verification", hint.isEmpty ? "Your cloud password" : "Your cloud password (hint: \(hint))", footer: nil) {
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit { telegram.submitPassword(password); password = "" }
                Button("Sign in") { telegram.submitPassword(password); password = "" }.buttonStyle(AccentButtonStyle()).disabled(password.isEmpty)
            }
        case .unsupported(let why):
            Card(title: "Account") {
                FieldRow(title: why, last: true) {
                    Button("Try again") { telegram.restart() }.buttonStyle(AccentButtonStyle(prominent: false))
                }
            }
        case .ready:
            Card(title: "Account", footer: "The session is stored in Claudist's data folder, encrypted with a key from the Keychain. It shows up in Telegram → Settings → Devices as Claudist.") {
                FieldRow(title: telegram.me ?? "Signed in", subtitle: "Signed in", last: true) {
                    Button("Log out") { telegram.logOut() }.buttonStyle(AccentButtonStyle(prominent: false))
                }
            }
        }
    }

    private func step<Fields: View>(_ title: String, _ subtitle: String, footer: String?, @ViewBuilder fields: () -> Fields) -> some View {
        Card(title: "Account", footer: footer) {
            FieldRow(title: title, subtitle: subtitle, last: true) {
                HStack(spacing: 6) { fields() }
            }
        }
    }

    private var shownChats: [TelegramChat] {
        state.value.chats.filter { chat in
            (!openOnly || chat.access != nil) && (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search))
        }
    }

    private var chats: some View {
        let shown = shownChats
        let open = state.value.chats.filter { $0.access != nil }.count
        return Card(title: "Chats", footer: "Every chat starts closed. Read lets agents read and search it; Read & send also lets them write there under your name. Agents can't change this, and reading doesn't mark messages as read.") {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                TextField("Find a chat", text: $search).textFieldStyle(.plain)
                Toggle("Open only (\(open))", isOn: $openOnly).toggleStyle(.checkbox).font(.system(size: 12))
                Button { Task { await telegram.refreshChats() } } label: {
                    if telegram.loadingChats { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Reload the chat list")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if shown.isEmpty {
                CardEmpty(text: state.value.chats.isEmpty ? "Loading chats…" : "No chats match")
            }
            let visible = Array(shown.prefix(search.isEmpty ? 150 : 500))
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, chat in
                FieldRow(title: chat.title, subtitle: chat.type, last: i == visible.count - 1) {
                    AccessSwitch(value: chat.access?.rawValue ?? "none", writeTitle: "Read & send") { value in
                        store.write { try $0.execute(sql: "UPDATE telegramChat SET access = ? WHERE id = ?",
                                                     arguments: [StorageAccess(rawValue: value)?.rawValue, chat.id]) }
                    }
                }
            }
            if shown.count > visible.count {
                CardEmpty(text: "\(shown.count - visible.count) more — search to find them")
            }
        }
    }

    private var agents: some View {
        Card(title: "Agents", footer: "Agents with access get tools for the open chats: list them, read and search messages, send where allowed. Changes apply from the agent's next run.") {
            ForEach(Array(store.agents.enumerated()), id: \.element.id) { i, agent in
                CheckRow(title: agent.name, subtitle: agent.description, last: i == store.agents.count - 1,
                         isOn: Binding(get: { state.value.agents.contains(agent.id) }, set: { on in
                             store.write { try Integrations.setGranted($0, agentId: agent.id, Telegram.id, on) }
                         }))
            }
        }
    }
}

/// Integrations card in the agent editor.
struct AgentIntegrationsCard: View {
    @EnvironmentObject var store: AppStore
    let agentId: ID
    @StateObject private var state = Observed<[String: Bool]>([:])

    var body: some View {
        Card(title: "Integrations", footer: "Built-in services the agent may use through Claudist's tools. Turn them on and set them up in Integrations.") {
            ForEach(Array(Integrations.catalog.enumerated()), id: \.element.id) { i, info in
                let enabled = state.value[info.id] != nil
                CheckRow(title: info.title, subtitle: enabled ? info.summary : "Off — turn it on in Integrations",
                         last: i == Integrations.catalog.count - 1,
                         isOn: Binding(get: { state.value[info.id] == true }, set: { on in
                             store.write { try Integrations.setGranted($0, agentId: agentId, info.id, on) }
                         }))
                .disabled(!enabled)
            }
        }
        .onAppear {
            let id = agentId
            // integration id → granted, for integrations that are on.
            state.observe(store.db) { db in
                var map: [String: Bool] = [:]
                for info in Integrations.catalog where try Integrations.isEnabled(db, info.id) {
                    map[info.id] = try Integrations.agents(db, info.id).contains(id)
                }
                return map
            }
        }
    }
}
