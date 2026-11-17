import ClaudistCore
import AppKit
import GRDB
import SwiftUI

struct StorageView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var usage = Observed<[ID: [String]]>([:])
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            ReadableColumn {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: "Storage", subtitle: "Host folders you can give agents access to") {
                        Button { add() } label: { SwiftUI.Label("Add folder", systemImage: "plus") }
                            .buttonStyle(AccentButtonStyle())
                    }
                    VStack(spacing: 0) {
                        if store.storages.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "externaldrive.badge.plus").font(.system(size: 28))
                                Text("Drop folders here or use Add folder").font(.system(size: 12))
                            }
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                        ForEach(Array(store.storages.enumerated()), id: \.element.id) { i, storage in
                            row(storage, last: i == store.storages.count - 1)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(dropTargeted ? Theme.accentSoft : Theme.sidebar))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(dropTargeted ? Theme.accent : Theme.divider,
                                      style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [6] : [])))
                    .dropDestination(for: URL.self) { urls, _ in
                        insert(urls)
                        return true
                    } isTargeted: { dropTargeted = $0 }
                    Text("Per agent you choose None, Read or Read & write for each folder (Agents → Storage).")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .onAppear {
            usage.observe(store.db) { db in
                var map: [ID: [String]] = [:]
                for row in try Row.fetchAll(db, sql: """
                    SELECT s.storageId, a.name || CASE s.access WHEN 'rw' THEN ' (rw)' ELSE ' (ro)' END
                    FROM agentStorage s JOIN agent a ON a.id = s.agentId ORDER BY a.name
                    """) {
                    map[row[0], default: []].append(row[1])
                }
                return map
            }
        }
    }

    private func row(_ storage: Storage, last: Bool) -> some View {
        let exists = FileManager.default.fileExists(atPath: storage.path)
        return HoverRow(cornerRadius: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill((exists ? Theme.blue : Theme.red).opacity(0.12))
                    Image(systemName: exists ? "folder.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(exists ? Theme.blue : Theme.red)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Name", text: Binding(get: { storage.name }, set: { name in
                        var s = storage
                        s.name = name
                        store.write { try s.update($0) }
                    }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    Text(storage.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                    let agents = usage.value[storage.id] ?? []
                    Pill(text: agents.isEmpty ? "No agent has access" : agents.joined(separator: ", "), icon: "person.2",
                         color: agents.isEmpty ? Theme.tertiary : Theme.secondary)
                }
                Spacer()
                IconButton(icon: "arrow.up.forward.app", help: "Open in Finder") { Finder.open(URL(fileURLWithPath: storage.path)) }
                IconButton(icon: "trash", help: "Remove from storage") { store.write { _ = try storage.delete($0) } }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 54) } }
    }

    private func add() {
        let panel = Finder.openPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        insert(panel.urls)
    }

    private func insert(_ urls: [URL]) {
        store.write { db in
            for url in urls where url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if try Storage.filter(Column("path") == url.path).fetchCount(db) == 0 {
                    try Storage(name: url.lastPathComponent, path: url.path).insert(db)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    @State private var status: ClaudeCLI.AuthStatus?
    @State private var cliPath: String?
    @State private var busy = false
    @State private var error: String?
    @State private var showHidden = Finder.showsHiddenFiles

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Card(title: "Claude account") {
                FieldRow(title: "Claude Code CLI") {
                    Text(cliPath ?? "not found").font(.system(size: 11, design: .monospaced)).foregroundStyle(cliPath == nil ? Theme.red : Theme.secondary)
                }
                FieldRow(title: "Status") {
                    HStack(spacing: 5) {
                        Circle().fill(status?.loggedIn == true ? Theme.green : Theme.red).frame(width: 7, height: 7)
                        Text(status == nil ? "checking…" : status!.loggedIn ? "Signed in" : "Signed out")
                            .font(.system(size: 13))
                    }
                }
                if let email = status?.email { FieldRow(title: "Account") { Text(email).font(.system(size: 13)) } }
                if let org = status?.orgName { FieldRow(title: "Organization") { Text(org).font(.system(size: 13)) } }
                if let sub = status?.subscriptionType { FieldRow(title: "Plan") { Text(sub.capitalized).font(.system(size: 13)) } }
                HStack(spacing: 8) {
                    if status?.loggedIn == true {
                        Button("Sign out") { run { try ClaudeCLI.logout() } }.buttonStyle(AccentButtonStyle(prominent: false))
                    } else {
                        Button("Sign in with browser") { run { try ClaudeCLI.login() } }.buttonStyle(AccentButtonStyle())
                    }
                    Button("Refresh") { refresh() }.buttonStyle(AccentButtonStyle(prominent: false))
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .padding(14)
            }
            if let method = status?.authMethod, method != "claude.ai" {
                Text("Using \(method) instead of a claude.ai subscription").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.red) }

            AccountsSettings()

            TaskLockSettings()

            IsolationSettings()

            TranscriptionSettings()

            CodeGraphSettings()

            Card(title: "Finder", footer: "Agent folders keep settings and skills in .claude/. This switches Finder's global setting and restarts Finder. ⌘⇧. toggles it once in any Finder window.") {
                FieldRow(title: "Show hidden files in Finder", last: true) {
                    Toggle("", isOn: Binding(get: { showHidden }, set: { Finder.setShowsHiddenFiles($0); showHidden = $0 }))
                        .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                }
            }

            Card(title: "Data", footer: "Export packs projects, tasks, agents with their folders and memory, skills with attached files and secrets (optionally, encrypted) into one .zip. Import replaces the current configuration after saving a backup.") {
                FieldRow(title: "Configuration") {
                    HStack(spacing: 8) {
                        Button("Export…") { store.showingExport = true }.buttonStyle(AccentButtonStyle(prominent: false))
                        Button("Import…") { ArchiveActions.importConfiguration(store: store, runs: runs) }
                            .buttonStyle(AccentButtonStyle(prominent: false))
                    }
                }
                FieldRow(title: "App folder", last: true) {
                    Button(store.paths.root.path) { NSWorkspace.shared.open(store.paths.root) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(24)
        }
        .frame(width: 600)
        .frame(minHeight: 420, idealHeight: 720, maxHeight: 900)
        .background(Theme.background)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        cliPath = try? ClaudeCLI.executable().path
        Task.detached {
            let s = try? ClaudeCLI.authStatus()
            await MainActor.run { status = s }
        }
    }

    private func run(_ action: @escaping @Sendable () throws -> Void) {
        busy = true
        error = nil
        Task.detached {
            var message: String?
            do { try action() } catch { message = error.localizedDescription }
            let result = message
            await MainActor.run {
                busy = false
                error = result
                refresh()
            }
        }
    }
}
