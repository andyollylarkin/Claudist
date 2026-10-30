import AgentDeskCore
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                header

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

                group("Agents") {
                    SidebarRow(title: "Agents", icon: "person.2", iconColor: Theme.accent,
                               selected: store.selection == .agents,
                               count: store.agents.isEmpty ? nil : store.agents.count,
                               trailing: runs.live.isEmpty ? nil : AnyView(RunningBadge(count: runs.live.count, waiting: runs.waitingCount))) {
                        store.selection = .agents
                    }
                    SidebarRow(title: "Skills", icon: "wand.and.stars", iconColor: Theme.purple,
                               selected: store.selection == .skills,
                               count: store.skills.isEmpty ? nil : store.skills.count) { store.selection = .skills }
                    SidebarRow(title: "Secrets", icon: "key", iconColor: Color(hex: 0xB29104),
                               selected: store.selection == .secrets,
                               count: store.secrets.isEmpty ? nil : store.secrets.count) { store.selection = .secrets }
                    SidebarRow(title: "Storage", icon: "externaldrive", iconColor: Theme.blue,
                               selected: store.selection == .storage,
                               count: store.storages.isEmpty ? nil : store.storages.count) { store.selection = .storage }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .background(Theme.sidebar)
        .sheet(item: $editingProject) { ProjectEditor(project: $0) }
        .sheet(item: $editingFilter) { FilterEditor(filter: $0) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            Text("AgentDesk").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            Menu {
                Button("New project") { editingProject = Project(name: "") }
                Button("New filter") { editingFilter = SavedFilter(name: "", query: "") }
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
    var iconColor: Color = Theme.secondary
    var selected = false
    var count: Int?
    var depth = 0
    var trailing: AnyView?
    let action: () -> Void

    var body: some View {
        HoverRow(selected: selected) {
            HStack(spacing: 8) {
                Image(systemName: icon)
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
