import ClaudistCore
import GRDB
import SwiftUI

/// Search box at the top of the sidebar: typing opens the Search screen, ⌘F focuses it.
struct SidebarSearchField: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            TextField("Search tasks", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { store.selection = .search }
                .onExitCommand { clear() }
            if !store.searchText.isEmpty {
                Button { clear() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.accent.opacity(0.6) : .clear))
        .onChange(of: store.searchText) { _, text in
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, store.selection != .search { store.selection = .search }
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchTasks)) { _ in focused = true }
    }

    private func clear() {
        store.searchText = ""
        focused = false
        if store.selection == .search { store.selection = nil }
    }
}

/// Tasks whose title or description contain every typed word (word prefixes), best matches first.
struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var results = Observed<[TaskItem]>([])
    @StateObject private var decor = Observed(TaskDecor())

    private var query: String { store.searchText.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReadableColumn {
                PageHeader(title: "Search", subtitle: subtitle, icon: "magnifyingglass", iconColor: Theme.accent)
                    .padding(.top, 24)
                    .padding(.bottom, 8)
            }
            if query.isEmpty {
                ContentUnavailableView("Search tasks", systemImage: "magnifyingglass",
                                       description: Text("Type in the search box at the top of the sidebar (⌘F). Titles and descriptions are searched; words match by their beginning."))
            } else if results.value.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "magnifyingglass",
                                       description: Text("No task title or description contains “\(query)”."))
            } else {
                GroupedListView(columns: [BoardColumn(id: "results", title: "", tasks: results.value)],
                                decor: decor.value, showProject: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("")
        .onAppear(perform: observe)
        .onChange(of: query) { observe() }
    }

    private var subtitle: String? {
        guard !query.isEmpty, !results.value.isEmpty else { return nil }
        let n = results.value.count
        return n >= 200 ? "First 200 matches" : "\(n) \(n == 1 ? "task" : "tasks")"
    }

    private func observe() {
        let text = query
        results.observe(store.db) { db in try TaskSearch.tasks(db, text: text) }
        decor.observe(store.db) { try TaskDecor.fetch($0) }
    }
}
