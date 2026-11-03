import ClaudistCore
import AppKit
import SwiftUI

/// Settings card: the isolation engine every agent runs in, its status and setup.
struct IsolationSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(Isolation.settingKey) private var engineId = Isolation.defaultEngine
    @State private var status: EngineStatus?
    @State private var hasToken = false
    @State private var token = ""
    @State private var building = false
    @State private var log: [String] = []

    private var engines: [any IsolationEngine] { Isolation.engines(paths: store.paths, credentials: store.secretStore) }
    private var engine: (any IsolationEngine)? { engines.first { $0.id == engineId } }

    var body: some View {
        Card(title: "Isolation",
             footer: "Applies to every agent run, including scheduled ones and sub-agents. The assistant chat and the skill and schema generators run on the host; they have no shell unless you approve each command.") {
            FieldRow(title: "Engine", subtitle: engine?.summary ?? "Agents run directly on this Mac with your user's access; only Claude Code's permission rules restrict them.") {
                InlineMenu(value: engine?.title ?? "None", options: [(Isolation.none, "None")] + engines.map { ($0.id, $0.title) }) {
                    engineId = $0
                    refresh()
                }
                .fixedSize()
            }
            if engineId != Isolation.none {
                FieldRow(title: "Status") {
                    HStack(spacing: 6) {
                        if let status {
                            Circle().fill(color(status)).frame(width: 7, height: 7)
                            Text(status.message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.trailing)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
            if engineId == DockerEngine.engineId {
                FieldRow(title: "Subscription token",
                         subtitle: "Containers can't use this Mac's login. Run `claude setup-token` (valid for a year) and paste the token here; it is stored in the Keychain.") {
                    VStack(alignment: .trailing, spacing: 6) {
                        if hasToken {
                            HStack(spacing: 6) {
                                SwiftUI.Label("Saved", systemImage: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(Theme.green)
                                Button("Remove") { setToken(nil) }.buttonStyle(AccentButtonStyle(prominent: false))
                            }
                        } else {
                            SecureField("sk-ant-oat…", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onSubmit { setToken(token) }
                            HStack(spacing: 6) {
                                Button("Get token…") { openSetupToken() }.buttonStyle(AccentButtonStyle(prominent: false))
                                Button("Save") { setToken(token) }.buttonStyle(AccentButtonStyle())
                                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                FieldRow(title: "Agent image", subtitle: "Debian with Node, Claude Code, git, Python, ripgrep, sqlite3. Built once per Claude Code version.",
                         last: log.isEmpty) {
                    HStack(spacing: 6) {
                        if building { ProgressView().controlSize(.small) }
                        Button(building ? "Building…" : "Build now") { build() }
                            .buttonStyle(AccentButtonStyle(prominent: false))
                            .disabled(building)
                    }
                }
                if !log.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(log.suffix(400).joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .id("end")
                        }
                        .frame(height: 140)
                        .onChange(of: log.count) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func color(_ status: EngineStatus) -> Color {
        switch status {
        case .ready: Theme.green
        case .needsPreparation: .orange
        case .unavailable: Theme.red
        }
    }

    private func refresh() {
        hasToken = ((try? store.secretStore.value(for: DockerEngine.tokenSecretId)) ?? nil) != nil
        status = nil
        guard let engine else { return }
        Task.detached {
            let s = engine.status()
            await MainActor.run { status = s }
        }
    }

    private func setToken(_ value: String?) {
        do {
            if let value {
                let t = DockerEngine.cleanToken(value)
                guard !t.isEmpty else { return }
                try store.secretStore.setValue(t, for: DockerEngine.tokenSecretId)
            } else {
                try store.secretStore.remove(DockerEngine.tokenSecretId)
            }
            token = ""
        } catch { store.report(error) }
        refresh()
    }

    /// Opens Terminal with `claude setup-token`: it needs a browser and prints the token.
    private func openSetupToken() {
        let script = store.paths.root.appendingPathComponent("containers/setup-token.command")
        do {
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            let claude = (try? ClaudeCLI.executable().path) ?? "claude"
            let text = """
                #!/bin/zsh -l
                echo "Sign in in the browser, then copy the token printed below into Claudist → Settings → Isolation."
                echo
                '\(claude.replacingOccurrences(of: "'", with: "'\\''"))' setup-token
                echo
                # Terminal may close the window as soon as the script ends; keep it open for copying.
                read -s -k 1 "?Copy the token, then press any key to close this window…"
                echo
                """
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch { store.report(error) }
    }

    private func build() {
        guard let engine else { return }
        building = true
        log = []
        Task.detached {
            let result = Result { try engine.prepare { line in Task { @MainActor in log.append(line) } } }
            await MainActor.run {
                building = false
                if case .failure(let error) = result { log.append("Error: \(error.localizedDescription)") }
                refresh()
            }
        }
    }
}
