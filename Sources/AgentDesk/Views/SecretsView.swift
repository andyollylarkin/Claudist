import AgentDeskCore
import AppKit
import GRDB
import SwiftUI

/// Who secrets are linked to.
enum SecretOwner: Equatable {
    case agent(ID)
    case skill(String)
}

/// Where each secret is used: agent names and skill names.
private struct SecretUsage: Equatable {
    var agents: [ID: [String]] = [:]
    var skills: [ID: [String]] = [:]

    static func fetch(_ db: Database) throws -> SecretUsage {
        var u = SecretUsage()
        for row in try Row.fetchAll(db, sql: """
            SELECT l.secretId, a.name FROM agentSecret l JOIN agent a ON a.id = l.agentId ORDER BY a.name
            """) { u.agents[row[0], default: []].append(row[1]) }
        for row in try Row.fetchAll(db, sql: "SELECT secretId, skillName FROM skillSecret ORDER BY skillName") {
            u.skills[row[0], default: []].append(row[1])
        }
        return u
    }
}

struct SecretsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var usage = Observed(SecretUsage())
    @State private var editing: Secret?
    @State private var isNew = false

    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Secrets", subtitle: "Stored in your Keychain, passed to agents as environment variables") {
                        Button { isNew = true; editing = Secret(name: "") } label: { SwiftUI.Label("Add secret", systemImage: "plus") }
                            .buttonStyle(AccentButtonStyle())
                    }
                    if store.secrets.isEmpty {
                        ContentUnavailableView("No secrets yet", systemImage: "key",
                                               description: Text("Add API tokens and passwords once, then give them to agents and skills"))
                            .padding(.top, 40)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.secrets.enumerated()), id: \.element.id) { i, secret in
                                row(secret, last: i == store.secrets.count - 1)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .sheet(item: $editing) { SecretEditor(secret: $0, isNew: isNew) }
        .onAppear { usage.observe(store.db) { try SecretUsage.fetch($0) } }
    }

    private func row(_ secret: Secret, last: Bool) -> some View {
        HoverRow(cornerRadius: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0xB29104).opacity(0.15))
                    Image(systemName: "key.fill").font(.system(size: 12)).foregroundStyle(Color(hex: 0xB29104))
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(secret.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                        if secret.asFile {
                            Text("file").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.blue)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.blue.opacity(0.12)))
                        }
                    }
                    if !secret.description.isEmpty {
                        Text(secret.description).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    usageLine(secret)
                }
                Spacer()
                Text("•••••••").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tertiary)
                Menu {
                    Button("Edit…") { edit(secret) }
                    Button("Copy value") { copy(secret) }
                    Divider()
                    Button("Delete", role: .destructive) { delete(secret) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.secondary).frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { edit(secret) }
        }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 54) } }
    }

    private func usageLine(_ secret: Secret) -> some View {
        let agents = usage.value.agents[secret.id] ?? []
        let skills = usage.value.skills[secret.id] ?? []
        return HStack(spacing: 10) {
            if agents.isEmpty && skills.isEmpty {
                Text("Not used").foregroundStyle(Theme.tertiary)
            }
            if !agents.isEmpty { Pill(text: agents.joined(separator: ", "), icon: "person.2") }
            if !skills.isEmpty { Pill(text: skills.joined(separator: ", "), icon: "wand.and.stars", color: Theme.purple) }
        }
        .font(.system(size: 11))
    }

    private func edit(_ secret: Secret) {
        isNew = false
        editing = secret
    }

    private func copy(_ secret: Secret) {
        do {
            guard let value = try store.secretStore.value(for: secret.id) else {
                store.errorMessage = "\(secret.name) has no value"
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } catch { store.report(error) }
    }

    private func delete(_ secret: Secret) {
        let users = (usage.value.agents[secret.id] ?? []) + (usage.value.skills[secret.id] ?? []).map { "skill \($0)" }
        let alert = NSAlert()
        alert.messageText = "Delete \(secret.name)?"
        alert.informativeText = users.isEmpty ? "The value will be removed from your Keychain."
            : "It will no longer be passed to: \(users.joined(separator: ", ")). The value will be removed from your Keychain."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.secretStore.remove(secret.id)
            store.write { _ = try secret.delete($0) }
        } catch { store.report(error) }
    }
}

struct SecretEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var secret: Secret
    let isNew: Bool
    /// Called after a successful save, e.g. to link a just-created secret.
    var onSave: ((Secret) -> Void)?

    @State private var value = ""
    @State private var reveal = false
    @State private var error: String?

    private var nameError: String? {
        let name = secret.name
        if name.isEmpty { return nil }
        if !Secret.isValidName(name) { return "Use letters, digits and _; don't start with a digit" }
        if Secret.reservedNames.contains(name.uppercased()) { return "\(name) is reserved and can't be overridden" }
        if store.secrets.contains(where: { $0.id != secret.id && $0.name == name }) { return "\(name) already exists" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add secret" : "Edit secret").font(.system(size: 16, weight: .bold)).padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Variable name").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    BoxedField(placeholder: "GITHUB_TOKEN", text: $secret.name, monospaced: true)
                        .onChange(of: secret.name) { _, v in
                            let up = v.uppercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
                            if up != v { secret.name = up }
                        }
                    if let nameError { Text(nameError).font(.system(size: 11)).foregroundStyle(Theme.red) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    BoxedField(placeholder: "What it is for and where it came from", text: $secret.description)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Value").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 6) {
                        Group {
                            if reveal {
                                TextField("", text: $value, prompt: Text(isNew ? "" : "unchanged"))
                            } else {
                                SecureField("", text: $value, prompt: Text(isNew ? "" : "unchanged"))
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        IconButton(icon: reveal ? "eye.slash" : "eye", help: isNew ? "Show" : "Show current value") { toggleReveal() }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                }
                Card {
                    CheckRow(title: "Provide as a file",
                             subtitle: "For SSH keys and certificates. The agent gets $\(secret.name.isEmpty ? "NAME" : secret.name) = path to a private temp file (0600) that is deleted after the run.",
                             last: true, isOn: $secret.asFile)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.red) }
                Text("The value is kept in your Keychain and only reaches the agent's process environment. Run history shows it as ‹\(secret.name.isEmpty ? "NAME" : secret.name)›.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            DialogButtons(confirm: "Save", disabled: secret.name.isEmpty || nameError != nil || (isNew && value.isEmpty), action: save)
        }
        .frame(width: 460)
    }

    private func toggleReveal() {
        if !reveal && !isNew && value.isEmpty {
            do { value = try store.secretStore.value(for: secret.id) ?? "" } catch { self.error = error.localizedDescription }
        }
        reveal.toggle()
    }

    private func save() {
        do {
            if !value.isEmpty { try store.secretStore.setValue(value, for: secret.id) }
            secret.updatedAt = LocalDate.stamp(Date())
            try store.db.writer.write { try secret.save($0) }
            onSave?(secret)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// Secret checkboxes for an agent or a skill, with "New secret" right there.
struct SecretLinks: View {
    @EnvironmentObject var store: AppStore
    let owner: SecretOwner
    @StateObject private var linked = Observed<[ID]>([])
    @StateObject private var inherited = Observed<[ID: [String]]>([:])
    @State private var creating: Secret?

    var body: some View {
        Card(title: "Secrets", footer: footer,
             trailing: AnyView(LinkButton(title: "New secret") { creating = Secret(name: "") })) {
            if store.secrets.isEmpty {
                CardEmpty(text: "No secrets yet")
            }
            ForEach(Array(store.secrets.enumerated()), id: \.element.id) { i, secret in
                let fromSkills = inherited.value[secret.id] ?? []
                CheckRow(title: secret.name, subtitle: secret.description,
                         note: fromSkills.isEmpty ? nil : "Also provided by skill: " + fromSkills.joined(separator: ", "),
                         monospaced: true, last: i == store.secrets.count - 1,
                         isOn: Binding(get: { linked.value.contains(secret.id) }, set: { set(secret, $0) }))
            }
        }
        .sheet(item: $creating) { secret in
            SecretEditor(secret: secret, isNew: true) { set($0, true) }
        }
        .onAppear(perform: observe)
    }

    private var footer: String {
        switch owner {
        case .agent: "Passed to the agent as environment variables ($NAME). Secrets of enabled skills are added automatically."
        case .skill: "Every agent with this skill receives these variables. Mention them in SKILL.md so the agent knows how to use them."
        }
    }

    private func observe() {
        switch owner {
        case .agent(let id):
            linked.observe(store.db) { try String.fetchAll($0, sql: "SELECT secretId FROM agentSecret WHERE agentId = ?", arguments: [id]) }
            inherited.observe(store.db) { db in
                var map: [ID: [String]] = [:]
                for row in try Row.fetchAll(db, sql: """
                    SELECT k.secretId, k.skillName FROM skillSecret k JOIN agentSkill g ON g.skillName = k.skillName
                    WHERE g.agentId = ? ORDER BY k.skillName
                    """, arguments: [id]) {
                    map[row[0], default: []].append(row[1])
                }
                return map
            }
        case .skill(let name):
            linked.observe(store.db) { try String.fetchAll($0, sql: "SELECT secretId FROM skillSecret WHERE skillName = ?", arguments: [name]) }
        }
    }

    private func set(_ secret: Secret, _ on: Bool) {
        store.write { db in
            switch owner {
            case .agent(let id):
                let link = AgentSecret(agentId: id, secretId: secret.id)
                if on { try link.save(db) } else { _ = try link.delete(db) }
            case .skill(let name):
                let link = SkillSecret(skillName: name, secretId: secret.id)
                if on { try link.save(db) } else { _ = try link.delete(db) }
            }
        }
    }
}
