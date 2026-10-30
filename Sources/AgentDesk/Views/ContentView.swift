import AgentDeskCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .inspector(isPresented: Binding(
                    get: { store.selectedTaskId != nil },
                    set: { if !$0 { store.selectedTaskId = nil } })) {
                    if let id = store.selectedTaskId {
                        TaskDetailView(taskId: id)
                            .id(id)
                            .inspectorColumnWidth(min: 380, ideal: 460, max: 720)
                    }
                }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $store.showingExport) { ExportSheet() }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onAppear {
            if store.selection == nil, let first = store.projectTree.first {
                store.selection = .project(first.project.id)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch store.selection {
        case .project(let id):
            if let project = store.project(id) {
                ProjectView(project: project).id(id)
            }
        case .filter(let id):
            if let filter = store.filters.first(where: { $0.id == id }) {
                FilterView(filter: filter).id(id)
            }
        case .agents:
            AgentsView()
        case .skills:
            SkillsView()
        case .storage:
            StorageView()
        case .secrets:
            SecretsView()
        case nil:
            ContentUnavailableView("Pick a project or a filter", systemImage: "sidebar.left")
        }
    }
}
