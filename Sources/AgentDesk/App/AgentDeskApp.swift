import AgentDeskCore
import AppKit
import SwiftUI

@main
struct AgentDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: AppStore
    @StateObject private var runs: RunManager

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _runs = StateObject(wrappedValue: RunManager(store: store))
    }

    var body: some Scene {
        WindowGroup("AgentDesk") {
            ContentView()
                .environmentObject(store)
                .environmentObject(runs)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Export Configuration…") { store.showingExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import Configuration…") { ArchiveActions.importConfiguration(store: store, runs: runs) }
            }
            CommandGroup(after: .newItem) {
                Button("New Task") { NotificationCenter.default.post(name: .newTask, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(runs)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(store)
                .environmentObject(runs)
        } label: {
            Image(systemName: runs.waitingCount > 0 ? "exclamationmark.bubble.fill"
                  : runs.live.isEmpty ? "checklist" : "gearshape.2.fill")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let newTask = Notification.Name("AgentDesk.newTask")
}

struct MenuBarContent: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager

    var body: some View {
        if runs.live.isEmpty {
            Text("No agents running")
        } else {
            ForEach(Array(runs.live.values), id: \.runId) { liveRun in
                let task = store.read { try TaskItem.fetchOne($0, key: liveRun.taskId) } ?? nil
                Button((liveRun.pending.isEmpty ? "▶︎ " : "⚠︎ ") + (task?.content ?? "?")) {
                    store.selectedTaskId = liveRun.taskId
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        Divider()
        Button("Open AgentDesk") { NSApp.activate(ignoringOtherApps: true) }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
