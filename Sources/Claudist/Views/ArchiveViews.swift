import ClaudistCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export / import of the whole configuration as a .zip.
@MainActor
enum ArchiveActions {
    static func importConfiguration(store: AppStore, runs: RunManager) {
        guard runs.live.isEmpty else {
            store.errorMessage = "Stop all running agents before importing a configuration."
            return
        }
        let panel = Finder.openPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose an Claudist configuration export (.zip)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let manifest: ConfigArchive.Manifest
        do { manifest = try ConfigArchive.inspect(url) } catch { store.report(error); return }

        let confirm = NSAlert()
        confirm.messageText = "Replace the current configuration?"
        confirm.informativeText = """
            Export from \(manifest.exportedAt) with \(manifest.agents.count) agent(s). \
            Projects, tasks, filters, agents, skills, storage and secret names will be replaced. \
            Your current configuration is saved to a backup first.
            """
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        var password: String?
        if manifest.encryptedSecrets {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Password for secret values (optional)"
            confirm.accessoryView = field
            confirm.window.initialFirstResponder = field
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            password = field.stringValue.isEmpty ? nil : field.stringValue
        } else {
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        let archive = ConfigArchive(db: store.db, paths: store.paths, secretStore: store.secretStore)
        do {
            let report = try archive.importArchive(from: url, secretsPassword: password)
            store.selection = nil
            store.selectedTaskId = nil
            store.reloadSkills()
            showReport(report)
        } catch {
            store.report(error)
        }
    }

    private static func showReport(_ r: ConfigArchive.ImportReport) {
        let alert = NSAlert()
        alert.messageText = "Configuration imported"
        var lines = ["\(r.projects) projects, \(r.tasks) tasks, \(r.agents) agents, \(r.skills) skills."]
        if r.secretsRestored > 0 { lines.append("\(r.secretsRestored) secret values restored to your Keychain.") }
        if r.secretsWithoutValue > 0 { lines.append("\(r.secretsWithoutValue) secrets have no value here — set them in Secrets.") }
        if !r.keptFolders.isEmpty {
            lines.append("These agent folders already existed and were left as they are:\n" + r.keptFolders.joined(separator: "\n"))
        }
        if let backup = r.backup { lines.append("Backup of the previous configuration:\n\(backup.path)") }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        if let backup = r.backup {
            alert.addButton(withTitle: "Show Backup")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([backup])
            }
        } else {
            alert.runModal()
        }
    }
}

struct ExportSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var agentFolders = true
    @State private var runHistory = true
    @State private var databases = true
    @State private var includeSecrets = false
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?

    private var passwordProblem: String? {
        guard includeSecrets else { return nil }
        if password.count < 8 { return "Use at least 8 characters" }
        if password != confirm { return "Passwords don't match" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export configuration").font(.system(size: 16, weight: .bold)).padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("Projects, tasks, filters, labels, agents, the skill library with attached files, storage and attachment paths are always included.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Card {
                    CheckRow(title: "Agent folders and memory",
                             subtitle: "CLAUDE.md, .claude/ and Claude Code's auto-memory of each agent",
                             isOn: $agentFolders)
                    CheckRow(title: "Run history", subtitle: "Conversations, tool calls and costs of past runs", isOn: $runHistory)
                    CheckRow(title: "Databases", subtitle: "Databases created in Claudist, with their data. Added files are referenced by path only", isOn: $databases)
                    CheckRow(title: "Secret values", subtitle: "Encrypted with a password. Without it only secret names are exported.",
                             last: true, isOn: $includeSecrets)
                }
                if includeSecrets {
                    VStack(alignment: .leading, spacing: 6) {
                        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                        SecureField("Repeat password", text: $confirm).textFieldStyle(.roundedBorder)
                        if let passwordProblem, !password.isEmpty {
                            Text(passwordProblem).font(.system(size: 11)).foregroundStyle(Theme.red)
                        }
                    }
                }
                Text("Files in storage folders and task attachments stay on this Mac; only their paths are exported.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.red) }
            }
            .padding(20)
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small); Text("Exporting…").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(AccentButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
                Button("Export…", action: export)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(busy || passwordProblem != nil)
                    .opacity(busy || passwordProblem != nil ? 0.5 : 1)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 500)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Claudist-\(f.string(from: Date())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var options = ConfigArchive.Options()
        options.agentFolders = agentFolders
        options.runHistory = runHistory
        options.databases = databases
        options.secretsPassword = includeSecrets ? password : nil
        let archive = ConfigArchive(db: store.db, paths: store.paths, secretStore: store.secretStore)
        busy = true
        error = nil
        Task.detached {
            var message: String?
            do { try archive.export(to: url, options: options) } catch { message = error.localizedDescription }
            let result = message
            await MainActor.run {
                busy = false
                if let result {
                    error = result
                } else {
                    dismiss()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}
