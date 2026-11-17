import ClaudistCore
import SwiftUI

/// What the master-password sheet is asked for.
struct VaultPrompt: Identifiable {
    enum Mode { case setup, open, change }
    let id = UUID()
    var mode: Mode
    /// Runs once the vault is open.
    var then: (() -> Void)?
}

extension AppStore {
    var vaultConfigured: Bool { read { try TaskVault.isConfigured($0) } ?? false }

    /// Runs `action` with the vault open, asking for the master password (or a new one) first.
    func withVault(_ action: @escaping () -> Void) {
        if TaskVault.isOpen { return action() }
        vaultPrompt = VaultPrompt(mode: vaultConfigured ? .open : .setup, then: action)
    }

    func lockTask(_ task: TaskItem) {
        withVault { [self] in write { try TaskVault.lock($0, taskId: task.id) } }
    }

    func removeLock(_ task: TaskItem) {
        let alert = NSAlert()
        alert.messageText = "Remove the lock from “\(task.content)”?"
        alert.informativeText = "Its description and comments will be stored unencrypted and shown without the master password."
        alert.addButton(withTitle: "Remove lock")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        withVault { [self] in write { try TaskVault.unlock($0, taskId: task.id) } }
    }

    /// Hides locked tasks' text again until the password is entered.
    func closeVault() {
        TaskVault.close()
        vaultOpen = false
    }
}

/// Sets, enters or changes the master password.
struct VaultSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let prompt: VaultPrompt
    @State private var password = ""
    @State private var confirm = ""
    @State private var old = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 16, weight: .bold))
            }
            Text(explanation).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if prompt.mode == .change {
                SecureField("Current password", text: $old).textFieldStyle(.roundedBorder)
            }
            SecureField(prompt.mode == .open ? "Master password" : "New password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if prompt.mode != .open {
                SecureField("Repeat the password", text: $confirm).textFieldStyle(.roundedBorder).onSubmit(submit)
            }
            if prompt.mode == .setup {
                Label("If you forget it, locked tasks can't be recovered — not by Claudist, not by anyone.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(prompt.mode == .open ? "Unlock" : prompt.mode == .setup ? "Set password" : "Change") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private var title: String {
        switch prompt.mode {
        case .setup: return "Set a master password"
        case .open: return "Enter the master password"
        case .change: return "Change the master password"
        }
    }

    private var explanation: String {
        switch prompt.mode {
        case .setup: return "Locked tasks keep their description and comments encrypted with this password. Titles stay visible."
        case .open: return "Locked tasks stay open until you quit Claudist or choose Lock Tasks Now."
        case .change: return "Locked tasks stay as they are; only the password that opens them changes."
        }
    }

    private func submit() {
        guard !password.isEmpty, !busy else { return }
        if prompt.mode != .open, password != confirm { error = "The passwords don't match"; return }
        busy = true
        error = nil
        let writer = store.db.writer
        let (mode, password, old) = (prompt.mode, password, old)
        // Key derivation takes a moment on purpose: keep the UI responsive.
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Error? = {
                do {
                    try writer.write { db in
                        switch mode {
                        case .setup: try TaskVault.configure(db, password: password)
                        case .open: try TaskVault.open(db, password: password)
                        case .change: try TaskVault.changePassword(db, old: old, new: password)
                        }
                    }
                    return nil
                } catch { return error }
            }()
            DispatchQueue.main.async {
                busy = false
                if let result {
                    error = (result as? LocalizedError)?.errorDescription ?? "\(result)"
                    return
                }
                store.vaultOpen = true
                dismiss()
                prompt.then?()
            }
        }
    }
}

/// Shown instead of a locked task's description, comments and agent while the vault is closed.
struct LockedTaskPanel: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(Theme.tertiary)
            Text("This task is locked").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Its description, comments and agent are behind the master password.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Button("Unlock…") { store.withVault {} }
                .buttonStyle(AccentButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// Settings card for the master password.
struct TaskLockSettings: View {
    @EnvironmentObject var store: AppStore
    @State private var prompt: VaultPrompt?

    var body: some View {
        Card(title: "Locked tasks",
             footer: "Lock a task from its context menu or the lock button in the task. Its description and comments are encrypted (AES-256) with a key only the master password opens; agents and the assistant can use it while it's unlocked. Agent conversations already stored aren't encrypted.") {
            FieldRow(title: "Master password") {
                HStack(spacing: 8) {
                    if store.vaultConfigured {
                        Button("Change…") { prompt = VaultPrompt(mode: .change) }.buttonStyle(AccentButtonStyle(prominent: false))
                    } else {
                        Button("Set…") { prompt = VaultPrompt(mode: .setup) }.buttonStyle(AccentButtonStyle(prominent: false))
                    }
                }
            }
            FieldRow(title: "Status", last: true) {
                HStack(spacing: 8) {
                    Image(systemName: store.vaultOpen ? "lock.open" : "lock").foregroundStyle(store.vaultOpen ? .orange : Theme.secondary)
                    Text(store.vaultOpen ? "Unlocked until Claudist quits" : "Locked").font(.system(size: 13))
                    if store.vaultOpen {
                        Button("Lock now") { store.closeVault() }.buttonStyle(AccentButtonStyle(prominent: false))
                    }
                }
            }
        }
        .sheet(item: $prompt) { VaultSheet(prompt: $0) }
    }
}
