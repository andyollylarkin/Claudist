import ClaudistCore
import AppKit
import GRDB
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    @State private var editingProject: Project?
    @State private var editingFilter: SavedFilter?
    @State private var filtersCollapsed = false
    @State private var projectsCollapsed = false
    @State private var dashboardsCollapsed = false
    @State private var appsCollapsed = false
    @State private var editingApp: MiniApp?
    @EnvironmentObject var builder: AppBuilderManager
    @EnvironmentObject var appHost: MiniAppHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                header
                SidebarSearchField()
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)

                SidebarRow(title: "Assistant", icon: "sparkles", iconColor: Theme.accent,
                           selected: store.selection == .assistant) {
                    store.selection = .assistant
                }
                SidebarRow(title: "Notes", icon: "note.text", iconColor: Color(hex: 0xB29104),
                           selected: store.selection == .notes) { store.selection = .notes }
                RecordingsSidebarRow(service: store.transcription)
                SidebarRow(title: "Needs you", icon: store.needsYouCount > 0 ? "hand.raised.fill" : "hand.raised",
                           iconColor: store.needsYouCount > 0 ? .orange : Theme.tertiary,
                           selected: store.selection == .needsYou,
                           trailing: store.needsYouCount > 0 ? AnyView(
                               Text("\(store.needsYouCount)")
                                   .font(.system(size: 11, weight: .bold))
                                   .foregroundStyle(.white)
                                   .padding(.horizontal, 6).padding(.vertical, 1)
                                   .background(Capsule().fill(Color.orange))) : nil) {
                    store.selection = .needsYou
                }
                SidebarRow(title: "To review", icon: store.reviewCount > 0 ? "checkmark.circle.fill" : "checkmark.circle",
                           iconColor: store.reviewCount > 0 ? Theme.accent : Theme.tertiary,
                           selected: store.selection == .review,
                           trailing: store.reviewCount > 0 ? AnyView(
                               Text("\(store.reviewCount)")
                                   .font(.system(size: 11, weight: .bold))
                                   .foregroundStyle(.white)
                                   .padding(.horizontal, 6).padding(.vertical, 1)
                                   .background(Capsule().fill(Theme.accent))) : nil) {
                    store.selection = .review
                }
                SidebarRow(title: "Failed", icon: "exclamationmark.triangle",
                           iconColor: store.failedCount > 0 ? Theme.red : Theme.tertiary,
                           selected: store.selection == .failed,
                           trailing: store.failedCount > 0 ? AnyView(
                               Text("\(store.failedCount)")
                                   .font(.system(size: 11, weight: .bold))
                                   .foregroundStyle(.white)
                                   .padding(.horizontal, 6).padding(.vertical, 1)
                                   .background(Capsule().fill(Theme.red))) : nil) {
                    store.selection = .failed
                }

                group("Filters", collapsed: $filtersCollapsed, add: { editingFilter = SavedFilter(name: "", query: "") }) {
                    ForEach(store.filters) { filter in
                        SidebarRow(title: filter.name, icon: "line.3.horizontal.decrease", iconColor: Theme.color(filter.color),
                                   selected: store.selection == .filter(filter.id),
                                   trailing: filter.isFavorite ? AnyView(Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)) : nil) {
                            store.selection = .filter(filter.id)
                        }
                        .contextMenu {
                            Button("Edit filter…") { editingFilter = filter }
                            Button(filter.isFavorite ? "Remove from favorites" : "Add to favorites") {
                                var f = filter
                                f.isFavorite.toggle()
                                store.write { try f.update($0) }
                            }
                            Divider()
                            Button("Delete filter", role: .destructive) { store.write { _ = try filter.delete($0) } }
                        }
                    }
                }

                group("My Projects", collapsed: $projectsCollapsed, add: { editingProject = Project(name: "") }) {
                    ForEach(store.projectTree, id: \.project.id) { item in
                        SidebarRow(title: item.project.name, icon: "number", iconColor: Theme.color(item.project.color),
                                   selected: store.selection == .project(item.project.id),
                                   count: store.projectCounts[item.project.id], depth: item.depth) {
                            store.selection = .project(item.project.id)
                        }
                        .contextMenu { projectMenu(item.project) }
                    }
                }

                group("Dashboards", collapsed: $dashboardsCollapsed, add: addDashboard) {
                    ForEach(store.dashboards) { dashboard in
                        SidebarRow(title: dashboard.name, icon: "chart.pie", iconColor: Theme.accent,
                                   selected: store.selection == .dashboard(dashboard.id)) {
                            store.selection = .dashboard(dashboard.id)
                        }
                        .contextMenu {
                            Button("Rename…") {
                                guard let name = DashboardNaming.ask(title: "Rename dashboard", suggested: dashboard.name) else { return }
                                var d = dashboard
                                d.name = name
                                store.write { try d.update($0) }
                            }
                            Divider()
                            Button("Delete dashboard", role: .destructive) { deleteDashboard(dashboard) }
                        }
                    }
                }

                group("Apps", collapsed: $appsCollapsed, add: { store.showingNewApp = true }) {
                    SidebarRow(title: "All apps", icon: "square.grid.2x2", iconColor: Theme.accent,
                               selected: store.selection == .apps,
                               count: store.miniApps.isEmpty ? nil : store.miniApps.count) { store.selection = .apps }
                    SidebarRow(title: "Builder", icon: "hammer", iconColor: Theme.purple,
                               selected: store.selection == .appBuilder,
                               trailing: builder.live.values.contains(where: \.busy) ? AnyView(ProgressView().controlSize(.mini)) : nil) {
                        store.selection = .appBuilder
                    }
                    ForEach(store.miniApps) { app in
                        SidebarRow(title: app.displayName, icon: "", emoji: app.displayIcon, iconColor: Theme.accent,
                                   selected: store.selection == .miniApp(app.id),
                                   trailing: builder.isBuilding(app.id) ? AnyView(ProgressView().controlSize(.mini))
                                       : appHost.runningIds.contains(app.id) ? AnyView(Circle().fill(Theme.green).frame(width: 6, height: 6)) : nil) {
                            store.selection = .miniApp(app.id)
                        }
                        .contextMenu {
                            MiniAppActions.menu(app, store: store, builder: builder, host: appHost) { editingApp = app }
                        }
                    }
                }

                group("Agents") {
                    SidebarRow(title: "Agents", icon: "person.2", iconColor: Theme.accent,
                               selected: store.selection == .agents,
                               count: store.agents.isEmpty ? nil : store.agents.count,
                               trailing: runs.live.isEmpty ? nil : AnyView(RunningBadge(count: runs.live.count, waiting: runs.waitingCount))) {
                        store.selection = .agents
                    }
                    SidebarRow(title: "Run log", icon: "list.bullet.rectangle", iconColor: Theme.accent,
                               selected: store.selection == .runLog) { store.selection = .runLog }
                    SidebarRow(title: "Statistics", icon: "chart.bar.xaxis", iconColor: Theme.accent,
                               selected: store.selection == .stats) { store.selection = .stats }
                    SidebarRow(title: "Memory", icon: "brain", iconColor: Theme.purple,
                               selected: store.selection == .memory) { store.selection = .memory }
                    SidebarRow(title: "Skills", icon: "wand.and.stars", iconColor: Theme.purple,
                               selected: store.selection == .skills,
                               count: store.skills.isEmpty ? nil : store.skills.count) { store.selection = .skills }
                    SidebarRow(title: "Prompts", icon: "text.quote", iconColor: Theme.accent,
                               selected: store.selection == .prompts,
                               count: store.promptTemplates.isEmpty ? nil : store.promptTemplates.count) { store.selection = .prompts }
                    SidebarRow(title: "Secrets", icon: "key", iconColor: Color(hex: 0xB29104),
                               selected: store.selection == .secrets,
                               count: store.secrets.isEmpty ? nil : store.secrets.count) { store.selection = .secrets }
                    SidebarRow(title: "Storage", icon: "externaldrive", iconColor: Theme.blue,
                               selected: store.selection == .storage,
                               count: store.storages.isEmpty ? nil : store.storages.count) { store.selection = .storage }
                    SidebarRow(title: "Databases", icon: "cylinder.split.1x2", iconColor: Theme.green,
                               selected: store.selection == .databases,
                               count: store.databases.isEmpty ? nil : store.databases.count) { store.selection = .databases }
                    SidebarRow(title: "Integrations", icon: "puzzlepiece.extension", iconColor: Theme.blue,
                               selected: store.selection == .integrations) { store.selection = .integrations }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                UsageIndicator()
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                HStack(spacing: 4) {
                    HelpLink(title: "Filter syntax") { store.syntaxHelp = .filters }
                    HelpLink(title: "Due dates") { store.syntaxHelp = .dueDates }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Theme.sidebar)
        }
        .background(Theme.sidebar)
        .sheet(item: $editingProject) { ProjectEditor(project: $0) }
        .sheet(item: $editingFilter) { FilterEditor(filter: $0) }
        .sheet(item: $editingApp) { AppSettingsSheet(app: $0) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            Text("Claudist").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            Menu {
                Button("New project") { editingProject = Project(name: "") }
                Button("New filter") { editingFilter = SavedFilter(name: "", query: "") }
                Button("New dashboard") { addDashboard() }
                Button("New app") { store.showingNewApp = true }
            } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, collapsed: Binding<Bool>? = nil, add: (() -> Void)? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        SidebarGroupHeader(title: title, collapsed: collapsed, add: add)
        if collapsed?.wrappedValue != true {
            content()
        }
    }

    private func addDashboard() {
        guard let name = DashboardNaming.ask(title: "New dashboard", suggested: "") else { return }
        var d = Dashboard(name: name)
        d.itemOrder = (store.dashboards.map(\.itemOrder).max() ?? 0) + 1
        store.write { try d.insert($0) }
        store.selection = .dashboard(d.id)
    }

    private func deleteDashboard(_ dashboard: Dashboard) {
        let alert = NSAlert()
        alert.messageText = "Delete dashboard “\(dashboard.name)”?"
        alert.informativeText = "Its charts are deleted too. The databases and their data stay."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.write { _ = try dashboard.delete($0) }
        if store.selection == .dashboard(dashboard.id) { store.selection = nil }
    }

    @ViewBuilder private func projectMenu(_ project: Project) -> some View {
        Button("Edit project…") { editingProject = project }
        Button("Add sub-project") { editingProject = Project(name: "", parentId: project.id) }
        Button(project.isFavorite ? "Remove from favorites" : "Add to favorites") {
            var p = project
            p.isFavorite.toggle()
            store.write { try p.update($0) }
        }
        Button("Archive") {
            var p = project
            p.isArchived = true
            store.write { try p.update($0) }
        }
        Divider()
        Button("Delete project", role: .destructive) {
            store.write { _ = try project.delete($0) }
            if store.selection == .project(project.id) { store.selection = nil }
        }
    }
}

private struct SidebarGroupHeader: View {
    let title: String
    var collapsed: Binding<Bool>?
    var add: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            Spacer()
            if hovering, let add {
                Button(action: add) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            }
            if let collapsed {
                Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.wrappedValue.toggle() } } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(collapsed.wrappedValue ? -90 : 0))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiary)
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct SidebarRow: View {
    let title: String
    let icon: String
    /// Shown instead of the SF Symbol (apps).
    var emoji: String? = nil
    var iconColor: Color = Theme.secondary
    var selected = false
    var count: Int?
    var depth = 0
    var trailing: AnyView?
    let action: () -> Void

    var body: some View {
        HoverRow(selected: selected) {
            HStack(spacing: 8) {
                Group {
                    if let emoji { Text(emoji).font(.system(size: 13)) } else { Image(systemName: icon) }
                }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing { trailing }
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.leading, 8 + CGFloat(depth) * 16)
            .padding(.trailing, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
        }
    }
}

private struct RunningBadge: View {
    let count: Int
    let waiting: Int

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(waiting > 0 ? Color.orange : Theme.green).frame(width: 6, height: 6)
            Text(waiting > 0 ? "\(waiting) waiting" : "\(count) running")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(waiting > 0 ? Color.orange : Theme.green)
    }
}

struct ProjectEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(project.name.isEmpty ? "Add project" : "Edit project")
                .font(.system(size: 16, weight: .bold))
                .padding(20)
            Divider()
            Form {
                TextField("Name", text: $project.name)
                Picker("Parent project", selection: $project.parentId) {
                    Text("No parent").tag(ID?.none)
                    ForEach(store.projectTree.filter { $0.project.id != project.id }, id: \.project.id) { item in
                        Text(String(repeating: "   ", count: item.depth) + item.project.name).tag(Optional(item.project.id))
                    }
                }
                ColorPicker(selection: $project.color)
                Toggle("Add to favorites", isOn: $project.isFavorite)
                Picker("Layout", selection: $project.viewStyle) {
                    SwiftUI.Label("List", systemImage: "list.bullet").tag(ViewStyle.list)
                    SwiftUI.Label("Board", systemImage: "rectangle.split.3x1").tag(ViewStyle.board)
                    SwiftUI.Label("Calendar", systemImage: "calendar").tag(ViewStyle.calendar)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            DialogButtons(confirm: "Save", disabled: project.name.trimmingCharacters(in: .whitespaces).isEmpty) {
                store.write { try project.save($0) }
                store.selection = .project(project.id)
                dismiss()
            }
        }
        .frame(width: 440)
    }
}

/// Cancel / primary pair at the bottom of dialogs.
struct DialogButtons: View {
    @Environment(\.dismiss) private var dismiss
    var confirm: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(AccentButtonStyle(prominent: false))
                .keyboardShortcut(.cancelAction)
            Button(confirm, action: action)
                .buttonStyle(AccentButtonStyle())
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

struct ColorPicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("Color", selection: $selection) {
            ForEach(Theme.colorNames, id: \.self) { name in
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(Theme.color(name))
                    Text(name.capitalized)
                }
                .tag(name)
            }
        }
    }
}

/// Small link at the bottom of the sidebar.
private struct HelpLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle").font(.system(size: 11))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(hovering ? Theme.accent : Theme.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.hover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Turns red while a recording runs, wherever the user is in the app.
private struct RecordingsSidebarRow: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var service: TranscriptionService

    var body: some View {
        let on = service.recordingId != nil
        SidebarRow(title: "Recordings", icon: on ? "record.circle.fill" : "waveform", iconColor: on ? Theme.red : Theme.purple,
                   selected: store.selection == .recordings) { store.selection = .recordings }
    }
}
