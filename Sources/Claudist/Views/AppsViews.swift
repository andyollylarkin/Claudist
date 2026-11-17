import AppKit
import ClaudistCore
import GRDB
import SwiftUI

private let builderModels = [("", "Default"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku"), ("fable", "Fable")]

/// The app's emoji in a rounded tile.
struct MiniAppIcon: View {
    let app: MiniApp
    var size: CGFloat = 40

    var body: some View {
        Text(app.displayIcon)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24).fill(Theme.accentSoft))
    }
}

/// Badges for an app's policy.
private struct PolicyBadges: View {
    let app: MiniApp

    var body: some View {
        HStack(spacing: 4) {
            badge(app.offline ? "Offline" : "CDN", app.offline ? "airplane" : "shippingbox",
                  app.offline ? "Everything is in the app; nothing is loaded from the internet" : "May load libraries from CDNs")
            if app.network {
                badge(app.hosts.isEmpty ? "Internet" : app.hosts.count == 1 ? app.hosts[0] : "\(app.hosts.count) hosts", "network",
                      app.hosts.isEmpty ? "May call any server" : "May call: " + app.hosts.joined(separator: ", "))
            }
        }
    }

    private func badge(_ title: String, _ icon: String, _ help: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.hover))
            .help(help)
    }
}

/// Actions shared by the gallery, the sidebar and the app screen.
@MainActor
enum MiniAppActions {
    static func open(_ app: MiniApp, store: AppStore) { store.selection = .miniApp(app.id) }

    /// Opens the builder on the app: its latest chat, or a new one.
    static func improve(_ app: MiniApp, store: AppStore) {
        let latest = store.read {
            try AppBuilderChat.filter(Column("appId") == app.id).order(Column("updatedAt").desc).fetchOne($0)
        } ?? nil
        store.builderFocus = latest?.id ?? "app:\(app.id)"
        store.selection = .appBuilder
    }

    /// Sends the app's runtime errors to its latest builder chat.
    static func fix(_ app: MiniApp, errors: [String], store: AppStore, builder: AppBuilderManager, host: MiniAppHost) {
        let latest = store.read {
            try AppBuilderChat.filter(Column("appId") == app.id).order(Column("updatedAt").desc).fetchOne($0)
        } ?? nil
        let chat = latest ?? builder.newChat(appId: app.id, accountId: builder.defaultAccountId,
                                             model: UserDefaults.standard.string(forKey: AppBuilderManager.modelKey) ?? "")
        builder.send(chat.id, text: AppBuilder.fixMessage(errors: errors))
        host.clearErrors(app.id)
        store.builderFocus = chat.id
        store.selection = .appBuilder
    }

    static func delete(_ app: MiniApp, store: AppStore, builder: AppBuilderManager) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(app.displayName)”?"
        alert.informativeText = "Its files, the data it saved and its builder chats are deleted. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if store.selection == .miniApp(app.id) { store.selection = .apps }
        if store.expandedAppId == app.id { store.expandedAppId = nil }
        builder.delete(app)
    }

    static func showInFinder(_ app: MiniApp, store: AppStore) {
        Finder.open(MiniApps.folder(store.paths, app.id))
    }

    @ViewBuilder
    static func menu(_ app: MiniApp, store: AppStore, builder: AppBuilderManager, host: MiniAppHost,
                     edit: @escaping () -> Void) -> some View {
        Button("Open") { open(app, store: store) }
        Button("Improve in Builder") { improve(app, store: store) }
        Button("Settings…", action: edit)
        Button("Show in Finder") { showInFinder(app, store: store) }
        if host.runningIds.contains(app.id) {
            Divider()
            Button("Quit app") { host.quit(app.id) }
        }
        Divider()
        Button("Erase app data…") {
            let alert = NSAlert()
            alert.messageText = "Erase the data “\(app.displayName)” saved?"
            alert.informativeText = "Everything it keeps in localStorage, IndexedDB and cookies is deleted. The app itself stays."
            alert.addButton(withTitle: "Erase")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { host.eraseData(app.id) }
        }
        Button("Delete app…", role: .destructive) { delete(app, store: store, builder: builder) }
    }
}

// MARK: Gallery

struct AppsGalleryView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var builder: AppBuilderManager
    @EnvironmentObject var host: MiniAppHost
    @State private var editing: MiniApp?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Small apps that run inside Claudist. Describe one and Claude builds it.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button { store.selection = .appBuilder } label: { Label("Builder", systemImage: "hammer") }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                Button { store.showingNewApp = true } label: { Label("New app", systemImage: "plus") }
                    .buttonStyle(AccentButtonStyle())
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if store.miniApps.isEmpty {
                ContentUnavailableView {
                    Label("No apps yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("A mortgage calculator, a habit tracker, a JSON formatter… Describe what you need.")
                } actions: {
                    Button("Create an app") { store.showingNewApp = true }.buttonStyle(AccentButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)], spacing: 14) {
                        ForEach(store.miniApps) { app in card(app) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .sheet(item: $editing) { AppSettingsSheet(app: $0) }
    }

    private func card(_ app: MiniApp) -> some View {
        let building = builder.isBuilding(app.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                MiniAppIcon(app: app, size: 44)
                Spacer()
                if building {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Building").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                } else if host.runningIds.contains(app.id) {
                    Circle().fill(Theme.green).frame(width: 7, height: 7).help("Running")
                }
            }
            Text(app.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text(app.summary.isEmpty ? " " : app.summary)
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .lineLimit(2, reservesSpace: true)
            PolicyBadges(app: app)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .onTapGesture { MiniAppActions.open(app, store: store) }
        .contextMenu { MiniAppActions.menu(app, store: store, builder: builder, host: host) { editing = app } }
    }
}

extension AppBuilderManager {
    /// A builder chat is working on the app right now.
    func isBuilding(_ appId: ID) -> Bool {
        live.contains { $0.value.busy && $0.value.appId == appId }
    }
}

// MARK: Running an app

struct MiniAppScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var builder: AppBuilderManager
    @EnvironmentObject var host: MiniAppHost
    let app: MiniApp
    @State private var editing: MiniApp?
    @State private var showingErrors = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MiniAppIcon(app: app, size: 26)
                Text(app.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if builder.isBuilding(app.id) {
                    ProgressView().controlSize(.small)
                    Text("Building…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                ErrorsButton(app: app, showing: $showingErrors)
                IconButton(icon: "arrow.clockwise", help: "Reload") { host.reload(app.id) }
                IconButton(icon: "hammer", help: "Improve in Builder") { MiniAppActions.improve(app, store: store) }
                IconButton(icon: "slider.horizontal.3", help: "Settings") { editing = app }
                IconButton(icon: "arrow.up.left.and.arrow.down.right", help: "Full screen") { store.expandedAppId = app.id }
                Menu {
                    MiniAppActions.menu(app, store: store, builder: builder, host: host) { editing = app }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            MiniAppWebView(appId: app.id)
        }
        .sheet(item: $editing) { AppSettingsSheet(app: $0) }
    }
}

/// Errors the app reported, with a way to hand them to the builder.
private struct ErrorsButton: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var builder: AppBuilderManager
    @EnvironmentObject var host: MiniAppHost
    let app: MiniApp
    @Binding var showing: Bool

    var body: some View {
        let errors = host.errors[app.id] ?? []
        if !errors.isEmpty {
            Button { showing.toggle() } label: {
                Label("\(errors.count)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.red)
            }
            .buttonStyle(.plain)
            .help("JavaScript errors")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Errors in “\(app.displayName)”").font(.system(size: 13, weight: .semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(errors, id: \.self) { e in
                                Text(e).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    HStack {
                        Button("Dismiss") { host.clearErrors(app.id); showing = false }
                            .buttonStyle(AccentButtonStyle(prominent: false))
                        Spacer()
                        Button("Ask Builder to fix") {
                            showing = false
                            MiniAppActions.fix(app, errors: errors, store: store, builder: builder, host: host)
                        }
                        .buttonStyle(AccentButtonStyle())
                    }
                }
                .padding(14)
                .frame(width: 420)
            }
        }
    }
}

/// An app filling the whole window, in macOS full screen.
struct ExpandedMiniAppView: View {
    @EnvironmentObject var store: AppStore
    let app: MiniApp
    @State private var hovering = false
    @State private var enteredFullScreen = false

    var body: some View {
        MiniAppWebView(appId: app.id)
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button { store.expandedAppId = nil } label: {
                    Label("Exit full screen", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(hovering ? 1 : 0.0)
                .padding(10)
                .onHover { hovering = $0 }
                .help("Exit full screen (Esc)")
            }
            .onAppear {
                guard let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
                enteredFullScreen = true
            }
            .onDisappear {
                guard enteredFullScreen, let window = NSApp.windows.first(where: { $0.styleMask.contains(.fullScreen) }) else { return }
                window.toggleFullScreen(nil)
            }
    }
}

// MARK: Builder

struct AppBuilderView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var builder: AppBuilderManager
    @StateObject private var chats = Observed<[AppBuilderChat]>([])
    @AppStorage("builder.selectedChat") private var selected = ""
    /// App of a chat that doesn't exist yet.
    @State private var draftAppId: ID?

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 230)
            Divider()
            Group {
                if let chat = chats.value.first(where: { $0.id == selected }) {
                    BuilderPane(chat: chat, appId: chat.appId).id(chat.id)
                } else {
                    BuilderPane(chat: nil, appId: draftAppId ?? store.miniApps.last?.id, pickApp: { draftAppId = $0 }) { appId, text, account, model in
                        let chat = builder.newChat(appId: appId, accountId: account, model: model)
                        selected = chat.id
                        builder.send(chat.id, text: text)
                    }
                    .id("draft-\(draftAppId ?? "")")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            chats.observe(store.db) { try AppBuilderChat.order(Column("updatedAt").desc).fetchAll($0) }
            applyFocus()
        }
        .onChange(of: store.builderFocus) { applyFocus() }
    }

    private func applyFocus() {
        guard let focus = store.builderFocus else { return }
        store.builderFocus = nil
        if focus.hasPrefix("app:") {
            draftAppId = String(focus.dropFirst(4))
            selected = ""
        } else {
            selected = focus
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("App Builder").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                IconButton(icon: "plus.app", help: "New app") { store.showingNewApp = true }
                IconButton(icon: "square.and.pencil", help: "New chat about an existing app") { selected = "" }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(chats.value) { chat in
                        let app = store.miniApp(chat.appId)
                        HoverRow(selected: selected == chat.id) {
                            HStack(spacing: 8) {
                                Text(app?.displayIcon ?? "🧩").font(.system(size: 14))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chat.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text((app?.displayName ?? "Deleted app") + " · " + RunHistoryView.when(chat.updatedAt))
                                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if builder.live[chat.id]?.busy == true { ProgressView().controlSize(.mini) }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = chat.id }
                        }
                        .contextMenu {
                            Button("Delete chat", role: .destructive) {
                                builder.deleteChat(chat.id)
                                if selected == chat.id { selected = "" }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .background(Theme.sidebar)
    }
}

private struct BuilderPane: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var builder: AppBuilderManager
    @EnvironmentObject var host: MiniAppHost
    let chat: AppBuilderChat?
    let appId: ID?
    var pickApp: ((ID) -> Void)?
    /// Sends the first message of a chat that doesn't exist yet: app, text, account, model.
    var start: ((ID, String, String, String) -> Void)?

    @StateObject private var events = Observed<[AppBuilderEvent]>([])
    @AppStorage(AppBuilderManager.modelKey) private var draftModel = ""
    @State private var draftAccount = ""
    @State private var message = ""
    @AppStorage("builder.showPreview") private var showPreview = true

    private var app: MiniApp? { store.miniApp(appId) }
    private var liveChat: LiveChat? { chat.flatMap { builder.live[$0.id] } }
    private var accountId: String { chat?.accountId ?? (draftAccount.isEmpty ? builder.defaultAccountId : draftAccount) }
    private var model: String { chat?.model ?? draftModel }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                header
                Divider()
                if chat == nil || events.value.isEmpty { welcome } else { transcript }
                input
            }
            .frame(minWidth: 360, maxHeight: .infinity)
            if showPreview, let app {
                preview(app).frame(minWidth: 320, maxHeight: .infinity)
            }
        }
        .onAppear {
            guard let id = chat?.id else { return }
            events.observe(store.db) { try AppBuilderEvent.filter(Column("chatId") == id).order(Column("seq")).fetchAll($0) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let chat {
                Text(chat.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            } else {
                Text("New chat").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            }
            Spacer()
            InlineMenu(value: builder.accountName(accountId), options: builder.accountOptions) { id in
                if let chat { builder.configure(chat.id, accountId: id) } else { draftAccount = id }
            }
            .help("Claude account the builder runs on")
            InlineMenu(value: builderModels.first { $0.0 == model }?.1 ?? model, options: builderModels) { m in
                if let chat { builder.configure(chat.id, model: m) } else { draftModel = m }
            }
            .help("Model")
            IconButton(icon: showPreview ? "sidebar.right" : "rectangle", help: showPreview ? "Hide preview" : "Show preview") {
                showPreview.toggle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "hammer").font(.system(size: 28)).foregroundStyle(Theme.accent)
            if store.miniApps.isEmpty {
                Text("Build your first app").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Describe what it should do; Claude writes it and adds it to your apps.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("New app…") { store.showingNewApp = true }.buttonStyle(AccentButtonStyle())
            } else {
                Text(app.map { "Improve “\($0.displayName)”" } ?? "Pick an app").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Ask for a feature, a fix or a new look. Or make a new app instead.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("New app…") { store.showingNewApp = true }.buttonStyle(AccentButtonStyle(prominent: false))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var items: [TranscriptItem] {
        guard let chat else { return [] }
        let run = Run(taskId: chat.id, agentId: nil)
        let runEvents = events.value.map { e -> RunEvent in
            var r = RunEvent(runId: run.id, kind: e.kind, json: e.json)
            r.seq = e.seq
            return r
        }
        return TranscriptItem.build(runs: [run], events: runEvents, agentName: "Builder").filter {
            if case .runHeader = $0.kind { return false }
            return true
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { TranscriptRow(item: $0).id($0.id) }
                    if liveChat?.busy == true {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Building…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                        .id("progress")
                    }
                }
                .padding(18)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(items.last?.id, anchor: .bottom) }
            .onChange(of: events.value.count) {
                withAnimation { proxy.scrollTo(liveChat?.busy == true ? "progress" : items.last?.id, anchor: .bottom) }
            }
        }
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && app != nil
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 8) {
            if chat == nil, !store.miniApps.isEmpty {
                HStack(spacing: 6) {
                    Text("App:").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    InlineMenu(value: app.map { "\($0.displayIcon) \($0.displayName)" } ?? "Choose…",
                               options: store.miniApps.map { ($0.id, "\($0.displayIcon) \($0.displayName)") }) { pickApp?($0) }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(app.map { "What should change in \($0.displayName)?" } ?? "Pick an app first", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .shiftReturnInsertsNewline()
                    .onSubmit(send)
                    .disabled(app == nil)
                if liveChat?.busy == true {
                    Button { if let id = chat?.id { builder.stop(id) } } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundStyle(canSend ? Theme.accent : Theme.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .frame(maxWidth: 760)
        .padding(14)
    }

    private func preview(_ app: MiniApp) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MiniAppIcon(app: app, size: 20)
                Text(app.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                PolicyBadges(app: app)
                Spacer()
                if let errors = host.errors[app.id], !errors.isEmpty {
                    Button {
                        MiniAppActions.fix(app, errors: errors, store: store, builder: builder, host: host)
                    } label: {
                        Label("Fix \(errors.count) error\(errors.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(liveChat?.busy == true)
                    .help(errors.joined(separator: "\n"))
                }
                IconButton(icon: "arrow.clockwise", help: "Reload") { host.reload(app.id) }
                IconButton(icon: "arrow.up.forward.app", help: "Open app") { MiniAppActions.open(app, store: store) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            MiniAppWebView(appId: app.id)
        }
        .background(Theme.background)
    }

    private func send() {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let app else { return }
        if let chat { builder.send(chat.id, text: t) } else { start?(app.id, t, accountId, model) }
        message = ""
    }
}

// MARK: Wizard and settings

/// Creating an app: what it does, then what it may use.
struct NewAppWizard: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var builder: AppBuilderManager
    @Environment(\.dismiss) private var dismiss
    @State private var spec = AppBuilderManager.NewApp()
    @State private var step = 0

    private static let examples = [
        "Mortgage calculator: amount, rate, term; monthly payment, total interest and a yearly amortization table",
        "Pomodoro timer with a task list and daily statistics",
        "JSON formatter and validator with syntax highlighting",
        "Habit tracker with a month grid and streaks",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New app").font(.system(size: 17, weight: .bold))
                Spacer()
                Text("Step \(step + 1) of 2").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            .padding(.bottom, 14)

            if step == 0 { describe } else { permissions }

            Spacer(minLength: 16)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step == 1 { Button("Back") { step = 0 } }
                if step == 0 {
                    Button("Next") { step = 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(spec.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Create app") { create() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 520)
        .onAppear {
            spec.accountId = builder.defaultAccountId
            spec.model = UserDefaults.standard.string(forKey: AppBuilderManager.modelKey) ?? ""
        }
    }

    private var describe: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should the app do?").font(.system(size: 13, weight: .semibold))
            TextEditor(text: $spec.request)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                .frame(height: 170)
            FlowLayout(spacing: 6) {
                ForEach(Self.examples, id: \.self) { e in
                    Button { spec.request = e } label: {
                        Text(e.components(separatedBy: ":").first ?? e)
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accentSoft))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Name").font(.system(size: 13, weight: .semibold)).padding(.top, 6)
            TextField("Optional — Claude picks one", text: $spec.name).textFieldStyle(.roundedBorder)
            Text("Apps are client-only: HTML, CSS and JavaScript that run inside Claudist and keep their data on this Mac.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            PolicyFields(offline: $spec.offline, network: $spec.network, hosts: $spec.networkHosts)
            Divider()
            HStack {
                Text("Build with").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $spec.accountId) {
                    ForEach(builder.accountOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .frame(width: 200)
                Picker("", selection: $spec.model) {
                    ForEach(builderModels, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            Text("The Claude account and model that write the app. You can switch them later in the Builder.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }

    private func create() {
        guard let chat = builder.create(spec) else { return }
        dismiss()
        store.builderFocus = chat.id
        store.selection = .appBuilder
    }
}

/// The offline and internet settings, as in the wizard and the app's settings.
private struct PolicyFields: View {
    @Binding var offline: Bool
    @Binding var network: Bool
    @Binding var hosts: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $offline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Works fully offline").font(.system(size: 13, weight: .semibold))
                    Text("All code and assets are written into the app. Off: it may load libraries, fonts and images from CDNs.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: $network) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow internet access").font(.system(size: 13, weight: .semibold))
                    Text("The app may call web APIs (fetch, WebSockets). Off: every request to a server is blocked.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            .toggleStyle(.switch)
            if network {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Only these hosts, e.g. api.github.com, *.openweathermap.org", text: $hosts)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave empty to allow any host.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                .padding(.leading, 4)
            }
        }
    }
}

struct AppSettingsSheet: View {
    @EnvironmentObject var builder: AppBuilderManager
    @Environment(\.dismiss) private var dismiss
    @State var app: MiniApp

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App settings").font(.system(size: 17, weight: .bold))
            HStack(spacing: 10) {
                TextField("Icon", text: $app.icon)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                    .help("One emoji")
                TextField("Name", text: $app.name).textFieldStyle(.roundedBorder)
            }
            TextField("Description", text: $app.summary, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Divider()
            PolicyFields(offline: $app.offline, network: $app.network, hosts: $app.networkHosts)
            Text("Changes apply when the app reloads. The Builder follows the new settings from its next message.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.icon = app.icon.trimmingCharacters(in: .whitespaces).first.map { String($0) } ?? ""
                    builder.update(app)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500, height: 480)
    }
}
