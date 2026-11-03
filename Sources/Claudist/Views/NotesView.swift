import AppKit
import ClaudistCore
import SwiftUI

/// Notes: Markdown files in Obsidian's format, edited here or written by agents.
@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var vault: NotesVault
    @Published private(set) var notes: [NotesVault.Note] = []
    @Published var query = ""
    @Published var selected: String?
    @Published var text = ""
    @Published private(set) var dirty = false
    @Published var error: String?
    private var loadedModified: Date?
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private let paths: AppPaths

    init(paths: AppPaths) {
        self.paths = paths
        vault = NotesVault.configured(paths: paths)
        refresh()
        // Agents write notes while the screen is open: pick up new files and outside changes.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    var shown: [NotesVault.Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        return vault.search(q)
    }

    func refresh() {
        let list = vault.list()
        if list != notes { notes = list }
        guard let selected else { return }
        guard let note = list.first(where: { $0.path == selected }) else {
            if !dirty { self.selected = nil; text = "" }
            return
        }
        if !dirty, note.modified != loadedModified { load(selected) }
    }

    func open(_ path: String?) {
        flush()
        selected = path
        if let path { load(path) } else { text = "" }
    }

    private func load(_ path: String) {
        text = (try? vault.read(path)) ?? ""
        loadedModified = notes.first { $0.path == path }?.modified
            ?? (try? vault.url(path)).flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        dirty = false
    }

    /// Typing: saved shortly after the last keystroke.
    func edited(_ value: String) {
        guard value != text || dirty else { return }
        text = value
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func flush() {
        saveWork?.cancel()
        guard dirty, let selected else { return }
        do {
            try vault.write(selected, text)
            dirty = false
            loadedModified = (try? vault.url(selected))
                .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            notes = vault.list()
        } catch { self.error = error.localizedDescription }
    }

    func create(_ name: String = "Untitled", in folder: String = "", text: String = "") {
        flush()
        let path = vault.newPath(name, in: folder)
        do {
            try vault.write(path, text)
            notes = vault.list()
            open(path)
        } catch { self.error = error.localizedDescription }
    }

    func rename(_ path: String, to title: String) {
        let name = title.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return }
        flush()
        let folder = (path as NSString).deletingLastPathComponent
        do {
            let moved = try vault.move(path, to: (folder.isEmpty ? "" : folder + "/") + name + ".md")
            notes = vault.list()
            if selected == path { selected = moved }
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ path: String) {
        do {
            // To the Trash, so a mistake can be undone in Finder.
            try FileManager.default.trashItem(at: try vault.url(path), resultingItemURL: nil)
            if selected == path { selected = nil; text = ""; dirty = false }
            notes = vault.list()
        } catch { self.error = error.localizedDescription }
    }

    /// Follows a `[[link]]`: the note, or a new one with that name (as Obsidian does).
    func follow(_ link: String) {
        if let note = vault.resolve(link: link) { open(note.path) } else {
            let name = link.split(separator: "#").first.map(String.init) ?? link
            create((name as NSString).lastPathComponent, in: (name as NSString).deletingLastPathComponent)
        }
    }

    func useFolder(_ url: URL?) {
        flush()
        if let url { UserDefaults.standard.set(url.path, forKey: NotesVault.folderKey) } else {
            UserDefaults.standard.removeObject(forKey: NotesVault.folderKey)
        }
        vault = NotesVault.configured(paths: paths)
        selected = nil
        text = ""
        notes = vault.list()
    }

    /// Notes linking to `path` with `[[Title]]`.
    func backlinks(_ path: String) -> [NotesVault.Note] {
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let plain = (path as NSString).deletingPathExtension
        return notes.filter { $0.path != path }.filter { note in
            guard let t = try? vault.read(note.path) else { return false }
            return t.range(of: "[[\(title)", options: .caseInsensitive) != nil || t.range(of: "[[\(plain)", options: .caseInsensitive) != nil
        }
    }
}

struct NotesView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var model: NotesModel
    @AppStorage("notesReading") private var reading = true
    @State private var asking = false

    init(paths: AppPaths) { _model = StateObject(wrappedValue: NotesModel(paths: paths)) }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 260).frame(maxHeight: .infinity, alignment: .top)
            Divider()
            if let path = model.selected {
                editor(path)
            } else {
                ContentUnavailableView {
                    SwiftUI.Label("Notes", systemImage: "note.text")
                } description: {
                    Text("Markdown notes in Obsidian's format. Write them here or ask an agent to.")
                } actions: {
                    Button("New note") { model.create(); reading = false }.buttonStyle(AccentButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .navigationTitle("")
        .onDisappear { model.flush() }
        .sheet(isPresented: $asking) {
            if let path = model.selected { AskAgentAboutNote(path: path) }
        }
        .alert("Notes", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Menu {
                    Text(model.vault.root.path)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.vault.root]) }
                    Button("Use another folder (e.g. an Obsidian vault)…") { chooseFolder() }
                    if UserDefaults.standard.string(forKey: NotesVault.folderKey) != nil {
                        Button("Use the default folder") { model.useFolder(nil) }
                    }
                } label: {
                    Image(systemName: "folder").foregroundStyle(Theme.secondary).frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Notes folder")
                IconButton(icon: "square.and.pencil", help: "New note") { model.create(); reading = false }
            }
            BoxedField(placeholder: "Search or #tag", text: $model.query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.shown) { note in
                        noteRow(note)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.sidebar)
    }

    private func noteRow(_ note: NotesVault.Note) -> some View {
        let selected = model.selected == note.path
        return VStack(alignment: .leading, spacing: 2) {
            Text(note.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1)
            HStack(spacing: 4) {
                if !note.folder.isEmpty {
                    Image(systemName: "folder").font(.system(size: 9))
                    Text(note.folder).lineLimit(1)
                    Text("·")
                }
                Text(RunHistoryView.when(LocalDate.stamp(note.modified)))
            }
            .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accentSoft : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.open(note.path) }
        .contextMenu {
            Button("Show in Finder") { if let u = try? model.vault.url(note.path) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
            Divider()
            Button("Move to Trash", role: .destructive) { model.delete(note.path) }
        }
    }

    private func editor(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                NoteTitleField(path: path) { model.rename(path, to: $0) }
                Spacer()
                if model.dirty { Text("Saving…").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                Picker("", selection: $reading) {
                    Text("Read").tag(true)
                    Text("Edit").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 120).labelsHidden()
                Button { asking = true } label: { SwiftUI.Label("Ask an agent", systemImage: "sparkles") }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                Menu {
                    Button("Show in Finder") { if let u = try? model.vault.url(path) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("[[\(((path as NSString).lastPathComponent as NSString).deletingPathExtension)]]", forType: .string)
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.delete(path) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.secondary).frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            if reading {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        NoteMarkdown(text: model.text, vault: model.vault)
                        backlinks(path)
                    }
                    .padding(28)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .environment(\.openURL, OpenURLAction { url in
                    switch url.scheme {
                    case "claudist-note":
                        model.follow(NoteLinks.target(url))
                        return .handled
                    case "claudist-tag":
                        model.query = "#" + NoteLinks.target(url)
                        return .handled
                    default:
                        return .systemAction
                    }
                })
            } else {
                TextEditor(text: Binding(get: { model.text }, set: { model.edited($0) }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder private func backlinks(_ path: String) -> some View {
        let links = model.backlinks(path)
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Linked from").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                ForEach(links) { note in
                    Button(note.title) { model.open(note.path) }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = Finder.openPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Folder for notes; an Obsidian vault works as is"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.useFolder(url)
    }
}

/// The note's file name, renamed on Return or when focus leaves.
private struct NoteTitleField: View {
    let path: String
    let rename: (String) -> Void
    @State private var title = ""
    @FocusState private var focused: Bool

    private var current: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    var body: some View {
        TextField("Title", text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .bold))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, on in if !on { commit() } }
            .onAppear { title = current }
            .onChange(of: path) { _, _ in title = current }
    }

    private func commit() {
        if title != current { rename(title) }
    }
}

/// Obsidian syntax turned into Markdown the renderer understands: links, embeds, tags, frontmatter.
enum NoteLinks {
    static func target(_ url: URL) -> String {
        let s = url.absoluteString
        guard let colon = s.firstIndex(of: ":") else { return s }
        return String(s[s.index(after: colon)...]).removingPercentEncoding ?? ""
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private static let embed = try! NSRegularExpression(pattern: "!\\[\\[([^\\]|]+)(?:\\|[^\\]]*)?\\]\\]")
    private static let wiki = try! NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]")
    private static let tag = try! NSRegularExpression(pattern: "(^|\\s)#([\\p{L}\\p{N}_/-]*\\p{L}[\\p{L}\\p{N}_/-]*)")
    private static let highlight = try! NSRegularExpression(pattern: "==([^=\\n]+)==")

    static func markdown(_ body: String, vault: NotesVault) -> String {
        var out: [String] = []
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); out.append(line); continue }
            if inFence { out.append(line); continue }
            var s = line
            s = replace(embed, in: s) { groups in
                let name = groups[1]
                let url = vault.root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path), ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased()) {
                    return "![\(name)](\(url.absoluteString))"
                }
                return "[\(name)](claudist-note:\(encode(name)))"
            }
            s = replace(wiki, in: s) { groups in
                let shown = groups[2].isEmpty ? groups[1] : groups[2]
                return "[\(shown)](claudist-note:\(encode(groups[1])))"
            }
            // Headings start with "# "; a tag has no space after "#".
            s = replace(tag, in: s) { groups in "\(groups[1])[#\(groups[2])](claudist-tag:\(encode(groups[2])))" }
            s = replace(highlight, in: s) { groups in "**\(groups[1])**" }
            out.append(s)
        }
        return out.joined(separator: "\n")
    }

    private static func replace(_ re: NSRegularExpression, in s: String, _ make: ([String]) -> String) -> String {
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += make(groups)
            last = m.range.location + m.range.length
        }
        return result + ns.substring(from: last)
    }
}

/// A note rendered: frontmatter as properties, then the body.
struct NoteMarkdown: View {
    let text: String
    let vault: NotesVault

    var body: some View {
        let (properties, body) = NotesVault.frontmatter(text)
        VStack(alignment: .leading, spacing: 14) {
            if !properties.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(properties.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .top, spacing: 10) {
                            Text(p.0).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary).frame(width: 110, alignment: .leading)
                            Text(p.1).font(.system(size: 12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebar))
            }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Empty note. Switch to Edit to write.").font(.system(size: 13)).foregroundStyle(Theme.tertiary)
            } else {
                MarkdownText(text: NoteLinks.markdown(body, vault: vault), size: 14)
            }
        }
    }
}

/// Hands a note to an agent as a task: the agent reads and writes it with the note tools.
private struct AskAgentAboutNote: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var runs: RunManager
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var agentId: ID?
    @State private var request = ""

    private var agent: Agent? { store.agent(agentId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ask an agent about “\(((path as NSString).lastPathComponent as NSString).deletingPathExtension)”")
                .font(.system(size: 16, weight: .bold)).padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    InlineMenu(value: agent?.name ?? "Choose…", options: store.agents.map { ($0.id, $0.name) }) { agentId = $0 }
                    if let agent, agent.notesAccess != .rw {
                        Text(agent.notesAccess == nil ? "\(agent.name) has no access to notes. Give it in Agents → Notes."
                                                      : "\(agent.name) can only read notes. Give write access in Agents → Notes to let it change this one.")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("What to do").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                    BoxedEditor(text: $request, minHeight: 110, monospaced: false)
                }
                Text("Creates a task for the agent and starts it; the task mentions this note.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            .padding(20)
            Divider()
            DialogButtons(confirm: "Start", disabled: agent == nil || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: start)
        }
        .frame(width: 480)
        .onAppear { agentId = store.agents.first { $0.notesAccess == .rw }?.id ?? store.agents.first?.id }
    }

    private func start() {
        guard let agent, let project = store.projectTree.first?.project else { return }
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(text.split(separator: "\n").first ?? "").prefix(80)
        var task = TaskItem(projectId: project.id, content: "Note: \(title)")
        task.description = "Note `\(path)` (read it with read_note, save changes with write_note).\n\n\(text)"
        task.agentId = agent.id
        store.write { try task.insert($0) }
        runs.start(task)
        dismiss()
    }
}
