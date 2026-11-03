import AppKit
import ClaudistCore
import SwiftUI

/// What each agent remembers: its CLAUDE.md files and Claude Code's auto-memory, on the Mac and in Docker.
struct MemoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var agentId: ID?
    @State private var files: [AgentMemory.File] = []
    @State private var fileId: String?
    @State private var text = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var error: String?

    private var agent: Agent? { store.agent(agentId) }
    private var file: AgentMemory.File? { files.first { $0.id == fileId } }

    var body: some View {
        HStack(spacing: 0) {
            agentList.frame(width: 220).frame(maxHeight: .infinity, alignment: .top)
            Divider()
            if let agent {
                VStack(alignment: .leading, spacing: 0) {
                    header(agent)
                    Divider()
                    HStack(spacing: 0) {
                        fileList.frame(width: 240).frame(maxHeight: .infinity, alignment: .top)
                        Divider()
                        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("Pick an agent", systemImage: "brain")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .navigationTitle("")
        .onAppear {
            if agentId == nil { agentId = store.memoryAgentId ?? store.agents.first?.id }
            store.memoryAgentId = nil
            reload()
        }
        .onChange(of: agentId) { _, _ in fileId = nil; editing = false; reload() }
        .onChange(of: fileId) { _, _ in editing = false; loadText() }
        // Agents write memory while they work.
        .task(id: agentId) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !editing { reload() }
            }
        }
    }

    private var agentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text("Memory").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).padding(.bottom, 8)
                ForEach(store.agents) { a in
                    HStack(spacing: 8) {
                        Avatar(name: a.name, size: 20)
                        Text(a.name).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        if sharing(a).count > 0 {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                                .help("Shares its folder and memory with other agents")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(agentId == a.id ? Theme.accentSoft : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { agentId = a.id }
                }
            }
            .padding(12)
        }
        .background(Theme.sidebar)
    }

    private func sharing(_ a: Agent) -> [Agent] {
        store.agents.filter { $0.id != a.id && $0.folderPath == a.folderPath }
    }

    private func header(_ agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(agent.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: agent.folderPath)) }
                    .buttonStyle(AccentButtonStyle(prominent: false))
            }
            Text(agent.folderPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            let others = sharing(agent)
            if !others.isEmpty {
                Text("Shares this folder with \(others.map(\.name).joined(separator: ", ")): they read and write the same memory. Give each agent its own folder in Agents → Runtime → Folder.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if files.isEmpty {
                    Text("Nothing remembered yet. Claude Code saves memory as the agent works, and CLAUDE.md holds what it should always know.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                let groups = Dictionary(grouping: files) { "\($0.kind == .instructions ? "Instructions" : "Memory") · \($0.place)" }
                ForEach(groups.keys.sorted(by: { ($0.hasPrefix("Memory") ? 1 : 0, $0) < ($1.hasPrefix("Memory") ? 1 : 0, $1) }), id: \.self) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.leading, 8)
                        ForEach(groups[group] ?? []) { f in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(size: 12, weight: fileId == f.id ? .semibold : .regular)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(RunHistoryView.when(LocalDate.stamp(f.modified)) + " · " + ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(fileId == f.id ? Theme.accentSoft : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { fileId = f.id }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder private var content: some View {
        if let file {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(file.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    if editing {
                        Button("Cancel") { editing = false }.buttonStyle(AccentButtonStyle(prominent: false))
                        Button("Save") { save(file) }.buttonStyle(AccentButtonStyle())
                    } else {
                        Button("Edit") { draft = text; editing = true }.buttonStyle(AccentButtonStyle(prominent: false))
                        Menu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Divider()
                            Button("Forget (move to Trash)", role: .destructive) { forget(file) }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Theme.secondary).frame(width: 20, height: 20)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.red).padding(.horizontal, 20) }
                Divider()
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(16)
                } else {
                    ScrollView {
                        NoteMarkdown(text: text, vault: NotesVault(root: file.url.deletingLastPathComponent()))
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        // [[links]] in memory point to other memory files of the same folder.
                        if url.scheme == "claudist-note" {
                            let name = NoteLinks.target(url)
                            let wanted = name.hasSuffix(".md") ? name : name + ".md"
                            if let f = files.first(where: { $0.url.deletingLastPathComponent() == file.url.deletingLastPathComponent()
                                && $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { fileId = f.id }
                            return .handled
                        }
                        if url.isFileURL || url.scheme == nil {
                            let target = file.url.deletingLastPathComponent().appendingPathComponent(url.relativeString)
                            if let f = files.first(where: { $0.url.standardizedFileURL == target.standardizedFileURL }) { fileId = f.id; return .handled }
                        }
                        return url.scheme == "claudist-tag" ? .handled : .systemAction
                    })
                }
            }
        } else {
            ContentUnavailableView("Pick a file", systemImage: "doc.text")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload() {
        guard let agent else { files = []; return }
        let found = AgentMemory.files(agentFolder: agent.folderPath, paths: store.paths, environment: ProcessInfo.processInfo.environment)
        if found != files { files = found }
        if fileId == nil || !files.contains(where: { $0.id == fileId }) {
            fileId = files.first { $0.name == "MEMORY.md" }?.id ?? files.first?.id
        }
        loadText()
    }

    private func loadText() {
        guard !editing else { return }
        let t = file.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        if t != text { text = t }
    }

    private func save(_ file: AgentMemory.File) {
        do {
            try Data(draft.utf8).write(to: file.url, options: .atomic)
            editing = false
            error = nil
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func forget(_ file: AgentMemory.File) {
        let alert = NSAlert()
        alert.messageText = "Forget \(file.name)?"
        alert.informativeText = "The file goes to the Trash. If MEMORY.md lists it, the agent may notice it is gone."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
            fileId = nil
            reload()
        } catch { self.error = error.localizedDescription }
    }
}
