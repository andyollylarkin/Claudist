import ClaudistCore
import AppKit
import GRDB
import SwiftUI

/// Drag payload of a section header; task cards carry plain task ids.
enum SectionDrag {
    static let prefix = "section:"
    static func payload(_ id: ID) -> String { prefix + id }
    static func sectionId(_ payload: String) -> ID? {
        payload.hasPrefix(prefix) ? String(payload.dropFirst(prefix.count)) : nil
    }
}

/// Rename, reorder and delete project sections.
@MainActor
enum SectionActions {
    static func rename(_ section: ClaudistCore.Section, to name: String, store: AppStore) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != section.name else { return }
        var s = section
        s.name = n
        store.write { try s.update($0) }
    }

    /// Puts `sectionId` right before `target` (nil: at the start), renumbering the project's sections.
    static func move(_ sectionId: ID, before target: ID?, store: AppStore) {
        guard sectionId != target else { return }
        store.write { db in
            guard let moved = try ClaudistCore.Section.fetchOne(db, key: sectionId) else { return }
            var list = try ClaudistCore.Section.filter(Column("projectId") == moved.projectId)
                .order(Column("sectionOrder"), Column("name")).fetchAll(db)
            list.removeAll { $0.id == sectionId }
            let index = target.flatMap { t in list.firstIndex { $0.id == t } } ?? 0
            list.insert(moved, at: index)
            try renumber(list, db)
        }
    }

    /// Moves a section one place left/up (-1) or right/down (+1).
    static func shift(_ section: ClaudistCore.Section, by delta: Int, store: AppStore) {
        store.write { db in
            var list = try ClaudistCore.Section.filter(Column("projectId") == section.projectId)
                .order(Column("sectionOrder"), Column("name")).fetchAll(db)
            guard let i = list.firstIndex(where: { $0.id == section.id }) else { return }
            let j = i + delta
            guard list.indices.contains(j) else { return }
            list.swapAt(i, j)
            try renumber(list, db)
        }
    }

    private static func renumber(_ list: [ClaudistCore.Section], _ db: Database) throws {
        for (i, var s) in list.enumerated() where s.sectionOrder != i + 1 {
            s.sectionOrder = i + 1
            try s.update(db)
        }
    }

    static func delete(_ section: ClaudistCore.Section, store: AppStore) {
        let count = (store.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM task WHERE sectionId = ?", arguments: [section.id])
        } ?? nil) ?? 0
        if count == 0 {
            store.write { _ = try section.delete($0) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete section “\(section.name)”?"
        alert.informativeText = "It has \(count) task\(count == 1 ? "" : "s") (including completed ones)."
        alert.addButton(withTitle: "Keep tasks")
        alert.addButton(withTitle: "Delete with tasks")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.write { db in
                try db.execute(sql: "UPDATE task SET sectionId = NULL WHERE sectionId = ?", arguments: [section.id])
                _ = try section.delete(db)
            }
        case .alertSecondButtonReturn:
            store.write { db in
                try db.execute(sql: "DELETE FROM task WHERE sectionId = ?", arguments: [section.id])
                _ = try section.delete(db)
            }
        default:
            break
        }
    }
}

/// Section name that turns into a text field on double click or "Rename".
struct SectionTitle: View {
    @EnvironmentObject var store: AppStore
    let section: ClaudistCore.Section
    @Binding var editing: Bool
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("Section name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .bold))
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent))
                .focused($focused)
                .onAppear { name = section.name; focused = true }
                .onSubmit(commit)
                .onExitCommand { editing = false }
                .onChange(of: focused) { if !focused && editing { commit() } }
                .frame(maxWidth: 260)
        } else {
            Text(section.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .onTapGesture(count: 2) { editing = true }
                .help("Double-click to rename, drag to reorder")
        }
    }

    private func commit() {
        SectionActions.rename(section, to: name, store: store)
        editing = false
    }
}

/// "…" menu of a section header; the same items serve as its context menu.
struct SectionMenu: View {
    @EnvironmentObject var store: AppStore
    let section: ClaudistCore.Section
    /// Board columns move left/right, list sections up/down.
    let horizontal: Bool
    let rename: () -> Void

    var body: some View {
        Menu {
            SectionMenuItems(section: section, horizontal: horizontal, rename: rename)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.tertiary).frame(width: 20, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SectionMenuItems: View {
    @EnvironmentObject var store: AppStore
    let section: ClaudistCore.Section
    let horizontal: Bool
    let rename: () -> Void

    var body: some View {
        Button("Rename section", action: rename)
        Button(horizontal ? "Move left" : "Move up") { SectionActions.shift(section, by: -1, store: store) }
        Button(horizontal ? "Move right" : "Move down") { SectionActions.shift(section, by: 1, store: store) }
        Divider()
        Button("Delete section…", role: .destructive) { SectionActions.delete(section, store: store) }
    }
}

/// Button that shows or hides completed tasks of a view.
struct CompletedToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "checkmark.circle")
                Text(isOn ? "Hide completed" : "Show completed")
            }
            .font(.system(size: 12))
            .foregroundStyle(isOn ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Theme.accentSoft : Theme.hover))
        }
        .buttonStyle(.plain)
        .help("Completed tasks appear after open ones")
    }
}

/// Applies a drop on a column: sections are reordered, tasks are moved into the column.
@MainActor
func handleColumnDrop(_ payloads: [String], column: BoardColumn, store: AppStore) -> Bool {
    let sections = payloads.compactMap(SectionDrag.sectionId)
    if !sections.isEmpty {
        // Only sections of the same project can be reordered; "No section" means: to the start.
        guard column.reordersSections else { return false }
        for id in sections { SectionActions.move(id, before: column.section?.id, store: store) }
        return true
    }
    guard let apply = column.onDrop else { return false }
    store.write { db in
        for id in payloads {
            guard var task = try TaskItem.fetchOne(db, key: id) else { continue }
            apply(&task)
            try task.update(db)
        }
    }
    return true
}
