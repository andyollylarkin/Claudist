import AgentDeskCore
import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Skill library: import by drag and drop, SKILL.md editing, attached files and secrets.
struct SkillsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var usage = Observed<[String: [String]]>([:])
    @State private var selected: String?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Skills", subtitle: "One shared library — enable skills per agent") {
                HStack(spacing: 8) {
                    IconButton(icon: "arrow.clockwise", help: "Reload from disk") { store.reloadSkills() }
                    Button { importWithPanel() } label: { SwiftUI.Label("Import", systemImage: "square.and.arrow.down") }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    Button { create() } label: { SwiftUI.Label("Add skill", systemImage: "plus") }
                        .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 14)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 280)
                Divider()
                Group {
                    if let skill = store.skills.first(where: { $0.name == selected }) {
                        SkillDetail(skill: skill, agents: usage.value[skill.name] ?? []).id(skill.name)
                    } else {
                        ContentUnavailableView("No skill selected", systemImage: "wand.and.stars",
                                               description: Text("Drop a skill folder, a .zip/.skill archive or a .md file onto the list"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .onAppear {
            store.reloadSkills()
            if selected == nil { selected = store.skills.first?.name }
            usage.observe(store.db) { db in
                var map: [String: [String]] = [:]
                for row in try Row.fetchAll(db, sql: """
                    SELECT s.skillName, a.name FROM agentSkill s JOIN agent a ON a.id = s.agentId ORDER BY a.name
                    """) {
                    map[row[0], default: []].append(row[1])
                }
                return map
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.skills) { skill in
                    HoverRow(selected: selected == skill.name, cornerRadius: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7).fill(Theme.purple.opacity(0.12))
                                Image(systemName: "wand.and.stars").font(.system(size: 12)).foregroundStyle(Theme.purple)
                            }
                            .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(selected == skill.name ? Theme.accent : Theme.text)
                                if !skill.description.isEmpty {
                                    Text(skill.description).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                                }
                                let agents = usage.value[skill.name] ?? []
                                if !agents.isEmpty {
                                    Pill(text: agents.joined(separator: ", "), icon: "person.2", color: Theme.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = skill.name }
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.url]) }
                        Divider()
                        Button("Delete from library", role: .destructive) { delete(skill) }
                    }
                }
                if store.skills.isEmpty && !dropTargeted {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 28))
                        Text("Drop skills here").font(.system(size: 13, weight: .semibold))
                        Text("Folder with SKILL.md, .zip, .skill or .md").font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 60)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 400, alignment: .top)
        }
        .background(Theme.sidebar)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentSoft.opacity(0.7)))
                    .overlay(Text("Import into library").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent))
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importSkills(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func importSkills(_ urls: [URL]) {
        var errors: [String] = []
        var last: String?
        for url in urls {
            do { last = try store.workspace.library.importSkill(from: url).name }
            catch { errors.append((error as? LocalizedError)?.errorDescription ?? "\(error)") }
        }
        store.reloadSkills()
        if let last { selected = last }
        if !errors.isEmpty { store.errorMessage = errors.joined(separator: "\n") }
    }

    private func importWithPanel() {
        let panel = Finder.openPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .zip, UTType(filenameExtension: "skill") ?? .zip,
                                     UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "A skill folder with SKILL.md, a .zip/.skill archive or a .md file"
        guard panel.runModal() == .OK else { return }
        importSkills(panel.urls)
    }

    private func create() {
        let alert = NSAlert()
        alert.messageText = "New skill"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        stack.orientation = .vertical
        let name = NSTextField(string: "")
        name.placeholderString = "skill-name"
        let desc = NSTextField(string: "")
        desc.placeholderString = "When should the agent use it?"
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(desc)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn, !name.stringValue.isEmpty else { return }
        do {
            let skill = try store.workspace.library.create(name: name.stringValue, description: desc.stringValue)
            store.reloadSkills()
            selected = skill.name
        } catch { store.report(error) }
    }

    private func delete(_ skill: Skill) {
        let agents = usage.value[skill.name] ?? []
        let alert = NSAlert()
        alert.messageText = "Delete skill “\(skill.name)”?"
        alert.informativeText = agents.isEmpty ? "The skill folder and all attached files will be deleted."
            : "It will be removed from: \(agents.joined(separator: ", "))."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.workspace.library.delete(skill)
            store.write {
                try $0.execute(sql: "DELETE FROM agentSkill WHERE skillName = ?", arguments: [skill.name])
                try $0.execute(sql: "DELETE FROM skillSecret WHERE skillName = ?", arguments: [skill.name])
            }
            for agent in store.agents { store.syncSkills(for: agent) }
            store.reloadSkills()
            if selected == skill.name { selected = store.skills.first?.name }
        } catch { store.report(error) }
    }
}

private struct SkillDetail: View {
    @EnvironmentObject var store: AppStore
    let skill: Skill
    let agents: [String]

    @State private var text = ""
    @State private var saved = ""
    @State private var files: [SkillFile] = []
    @State private var tab = 0
    @State private var dropTargeted = false

    private var library: SkillLibrary { store.workspace.library }
    private static let folders = ["scripts", "references", "assets"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(skill.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                if !skill.description.isEmpty {
                    Text(skill.description).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                    Text(agents.isEmpty ? "Not enabled for any agent" : "Used by " + agents.joined(separator: ", "))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            UnderlineTabs(titles: ["Files (\(files.filter { !$0.isDirectory }.count))",
                                   "SKILL.md" + (text != saved ? " •" : ""),
                                   "Secrets"], selection: $tab)
                .padding(.horizontal, 24)
            switch tab {
            case 0: filesPane
            case 1: editor
            default:
                ScrollView { SecretLinks(owner: .skill(skill.name)).padding(24) }
            }
        }
        .onAppear {
            text = library.readSkillMD(skill)
            saved = text
            reload()
        }
    }

    // MARK: Files

    private var filesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Menu {
                        Button("To skill root") { attachWithPanel(nil) }
                        Divider()
                        ForEach(Self.folders, id: \.self) { f in Button("To \(f)/") { attachWithPanel(f) } }
                    } label: {
                        SwiftUI.Label("Attach files", systemImage: "paperclip")
                    } primaryAction: {
                        attachWithPanel(nil)
                    }
                    .fixedSize()
                    Spacer()
                    IconButton(icon: "folder", help: "Open skill folder") { NSWorkspace.shared.open(skill.url) }
                    IconButton(icon: "arrow.clockwise", help: "Reload") { reload() }
                }

                VStack(spacing: 0) {
                    if files.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.badge.plus").font(.system(size: 26))
                            Text("Drop scripts, references or assets here").font(.system(size: 12))
                        }
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    }
                    ForEach(Array(files.enumerated()), id: \.element.id) { i, file in
                        FileRow(file: file, last: i == files.count - 1)
                            .contextMenu { fileMenu(file) }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(skill.url.appendingPathComponent(file.path)) }
                            .dropDestination(for: URL.self) { urls, _ in
                                guard file.isDirectory else { return false }
                                attach(urls, into: file.path)
                                return true
                            }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(dropTargeted ? Theme.accentSoft : Theme.sidebar))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropTargeted ? Theme.accent : Theme.divider,
                                  style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: dropTargeted ? [6] : [])))
                .dropDestination(for: URL.self) { urls, _ in
                    attach(urls, into: nil)
                    return true
                } isTargeted: { dropTargeted = $0 }

                HStack(spacing: 10) {
                    Text("Drop into:").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    ForEach(Self.folders, id: \.self) { folder in
                        DropChip(title: "\(folder)/") { attach($0, into: folder) }
                    }
                }
                Text("Files dropped on the list go to the skill root, on a folder — inside it. Scripts become executable. Mention files in SKILL.md so the agent knows when to use them.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    @ViewBuilder private func fileMenu(_ file: SkillFile) -> some View {
        let url = skill.url.appendingPathComponent(file.path)
        Button("Open") { NSWorkspace.shared.open(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if !file.isDirectory {
            Button("Insert link into SKILL.md") {
                text += (text.hasSuffix("\n") ? "" : "\n") + "- [\(file.name)](\(file.path))\n"
                tab = 1
            }
            Button(file.isExecutable ? "Make not executable" : "Make executable") {
                perform { try library.setExecutable(file.path, in: skill, !file.isExecutable) }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { perform { try library.removeFile(file.path, from: skill) } }
    }

    private func attachWithPanel(_ folder: String?) {
        let panel = Finder.openPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = folder.map { "Attach to \($0)/" } ?? "Attach to skill"
        guard panel.runModal() == .OK else { return }
        attach(panel.urls, into: folder)
    }

    private func attach(_ urls: [URL], into folder: String?) {
        perform { try library.attach(urls, to: skill, subfolder: folder) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { store.report(error) }
        reload()
    }

    private func reload() {
        files = library.files(of: skill)
    }

    // MARK: SKILL.md

    private var editor: some View {
        VStack(spacing: 0) {
            BoxedEditor(text: $text, minHeight: 200)
                .padding(16)
            HStack {
                Text("Changes apply to every agent with this skill").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button("Revert") { text = saved }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                    .disabled(text == saved)
                Button("Save") { save() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(text == saved)
                    .opacity(text == saved ? 0.5 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    private func save() {
        do {
            try library.writeSkillMD(skill, text)
            saved = text
            store.reloadSkills()
        } catch { store.report(error) }
    }
}

private struct FileRow: View {
    let file: SkillFile
    let last: Bool

    var body: some View {
        HoverRow(cornerRadius: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.isDirectory ? "folder.fill" : file.isExecutable ? "terminal.fill" : "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(file.isDirectory ? Theme.blue : file.isExecutable ? Theme.green : Theme.tertiary)
                    .frame(width: 18)
                Text(file.name).font(.system(size: 13, design: file.isDirectory ? .default : .monospaced)).foregroundStyle(Theme.text)
                if file.isExecutable {
                    Text("executable").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.green)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.green.opacity(0.12)))
                }
                Spacer()
                if !file.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.leading, 14 + CGFloat(file.depth) * 20)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 40) } }
    }
}

/// Drop target for a conventional skill subfolder.
private struct DropChip: View {
    let title: String
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 10))
            Text(title).font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(targeted ? Theme.accent : Theme.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(targeted ? Theme.accentSoft : Theme.hover))
        .overlay(Capsule().strokeBorder(targeted ? Theme.accent : .clear, style: StrokeStyle(lineWidth: 1, dash: [3])))
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}
