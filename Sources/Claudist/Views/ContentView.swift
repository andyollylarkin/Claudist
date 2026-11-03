import ClaudistCore
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
        .sheet(item: $store.syntaxHelp) { SyntaxHelpView(tab: $0) }
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
        case .dashboard(let id):
            if let dashboard = store.dashboards.first(where: { $0.id == id }) {
                DashboardView(dashboard: dashboard).id(id)
            }
        case .agents:
            AgentsView()
        case .skills:
            SkillsView()
        case .storage:
            StorageView()
        case .secrets:
            SecretsView()
        case .databases:
            DatabasesView()
        case .assistant:
            AssistantView()
        case .runLog:
            RunLogView()
        case .needsYou:
            NeedsYouView()
        case .notes:
            NotesView(paths: store.paths)
        case .memory:
            MemoryView()
        case .prompts:
            PromptsView()
        case .stats:
            StatsView()
        case .integrations:
            IntegrationsView()
        case .review:
            ReviewView()
        case .failed:
            FailedView()
        case nil:
            ContentUnavailableView("Pick a project or a filter", systemImage: "sidebar.left")
        }
    }
}
