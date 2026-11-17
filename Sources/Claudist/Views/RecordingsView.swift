import AVFoundation
import ClaudistCore
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Record the microphone and other apps' sound, then transcribe on demand into a note.
struct RecordingsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var recordings = Observed<[Recording]>([])
    @State private var selected: ID?
    @State private var dropTargeted = false

    var body: some View {
        let service = store.transcription
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                RecorderPanel(service: service)
                Divider()
                list
            }
            .frame(width: 340)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.sidebar)
            Divider()
            Group {
                if let r = recordings.value.first(where: { $0.id == selected }) {
                    RecordingDetail(recording: r, service: service).id(r.id)
                } else {
                    ContentUnavailableView("No recording selected", systemImage: "waveform",
                                           description: Text("Record above, or drop an audio or video file on the list"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipped()
        .navigationTitle("")
        .onAppear {
            recordings.observe(store.db) { try Recording.order(Column("createdAt").desc).fetchAll($0) }
        }
        .onChange(of: service.recordingId) { _, id in if let id { selected = id } }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(recordings.value) { r in
                    HoverRow(selected: selected == r.id, cornerRadius: 8) {
                        HStack(spacing: 10) {
                            RecordingStatusIcon(status: r.status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Text([RunHistoryView.when(r.createdAt), r.duration > 0 ? Self.duration(r.duration) : nil, r.sourceApp]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = r.id }
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.folder(store.paths)]) }
                        Divider()
                        Button("Delete", role: .destructive) { store.transcription.delete(r) }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentSoft.opacity(0.7)))
                    .overlay(Text("Import audio").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent))
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                do { try store.transcription.importFile(url) } catch { store.report(error) }
            }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    static func duration(_ seconds: Double) -> String {
        Whisper.timestamp(Int(seconds * 1000))
    }
}

private struct RecordingStatusIcon: View {
    let status: Recording.Status

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.12))
            if status == .transcribing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var icon: String {
        switch status {
        case .recording: return "record.circle.fill"
        case .recorded: return "waveform"
        case .transcribing: return "text.bubble"
        case .done: return "text.bubble.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .recording, .failed: return Theme.red
        case .done: return Theme.green
        default: return Theme.accent
        }
    }
}

/// Source pickers and the record button.
private struct RecorderPanel: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var service: TranscriptionService
    @State private var sources = TranscriptionService.Sources()
    @State private var devices: [AudioSources.Device] = []
    @State private var apps: [AudioSources.App] = []
    @State private var error: String?
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recordings").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
            let recording = service.recordingId != nil
            VStack(spacing: 0) {
                sourceRow(icon: "mic.fill", title: "Microphone", isOn: $sources.microphone) {
                    Menu(devices.first { $0.id == sources.micDevice }?.name ?? "Default input") {
                        Button("Default input") { sources.micDevice = nil }
                        Divider()
                        ForEach(devices) { d in Button(d.name) { sources.micDevice = d.id } }
                    }
                }
                Divider().padding(.leading, 36)
                sourceRow(icon: "speaker.wave.2.fill", title: "Sound of", isOn: $sources.systemSound) {
                    Menu(sources.app?.name ?? "All apps") {
                        Button("All apps") { sources.app = nil }
                        Divider()
                        ForEach(apps) { a in Button(a.name) { sources.app = a } }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
            .disabled(recording)
            .opacity(recording ? 0.6 : 1)

            HStack(spacing: 10) {
                Button {
                    if recording { service.stop() } else { start() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: recording ? "stop.fill" : "record.circle")
                        Text(recording ? "Stop" : "Record")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!recording && !sources.microphone && !sources.systemSound)
                if let started = service.recordingStarted {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.red).frame(width: 8, height: 8)
                        Text(RecordingsView.duration(now.timeIntervalSince(started)))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                    }
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            }
            if sources.systemSound && !sources.microphone {
                Text("Only the apps' sound: your voice isn't recorded.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            } else if sources.microphone && !sources.systemSound {
                Text("Microphone only: with headphones on, the other side of a call isn't recorded.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .onAppear(perform: reloadSources)
        .task(id: service.recordingId) {
            while service.recordingId != nil && !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func sourceRow<Picker: View>(icon: String, title: String, isOn: Binding<Bool>, @ViewBuilder picker: () -> Picker) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: isOn).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 14)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            picker()
                .menuStyle(.borderlessButton).fixedSize()
                .font(.system(size: 12))
                .onTapGesture(perform: reloadSources)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func reloadSources() {
        devices = AudioSources.inputDevices()
        apps = AudioSources.apps()
        // The chosen app may have restarted with new audio processes.
        if let app = sources.app { sources.app = apps.first { $0.bundleId == app.bundleId } ?? app }
    }

    private func start() {
        error = nil
        reloadSources()
        Task {
            do { try await service.start(sources) } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        }
    }
}

private struct RecordingDetail: View {
    @EnvironmentObject var store: AppStore
    let recording: Recording
    @ObservedObject var service: TranscriptionService
    @State private var title = ""
    @State private var player: AVAudioPlayer?
    @State private var playing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .bold))
                    .onSubmit(rename)
                    .onChange(of: title) { _, _ in rename() }
                HStack(spacing: 8) {
                    ForEach(recording.tracks(store.paths), id: \.url) { track in
                        let key = track.url.lastPathComponent
                        Button {
                            toggle(track.url)
                        } label: {
                            SwiftUI.Label(track.speaker.map { "Play \($0 == "Me" ? "mine" : "others")" } ?? "Play",
                                          systemImage: playing == key ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                        .disabled(recording.status == .recording)
                    }
                    Spacer()
                    transcribeButton
                }
                if service.activeModel == nil {
                    Text("No transcription model yet: download one in Settings → Transcription.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                if let error = recording.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(recording.status == .failed ? Theme.red : .orange)
                        .textSelection(.enabled).lineLimit(4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider()
            ScrollView {
                if let text = recording.transcript, !text.isEmpty {
                    MarkdownText(text: text)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { title = recording.title }
        .onDisappear { player?.stop() }
    }

    @ViewBuilder private var transcribeButton: some View {
        switch recording.status {
        case .recording:
            EmptyView()
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(service.transcribing == recording.id ? "Transcribing…" : "Waiting…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        default:
            if let path = recording.notePath, recording.status == .done {
                Button("Open note") {
                    store.noteToOpen = path
                    store.selection = .notes
                }
                .buttonStyle(AccentButtonStyle(prominent: false))
            }
            Button(recording.status == .done ? "Transcribe again" : "Transcribe") { service.transcribe(recording.id) }
                .buttonStyle(AccentButtonStyle(prominent: recording.status != .done))
                .disabled(service.activeModel == nil)
        }
    }

    private var placeholder: String {
        switch recording.status {
        case .recording: return "Recording…"
        case .transcribing: return "The transcript appears here when it's ready. Long recordings take a few minutes."
        default: return "Press Transcribe to turn the recording into text. It runs on this Mac; the text is also saved as a note in Transcripts."
        }
    }

    private func rename() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != recording.title else { return }
        let id = recording.id
        store.write { try $0.execute(sql: "UPDATE recording SET title = ? WHERE id = ?", arguments: [t, id]) }
    }

    private func toggle(_ url: URL) {
        let key = url.lastPathComponent
        if playing == key {
            player?.pause()
            playing = nil
            return
        }
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        playing = player == nil ? nil : key
    }
}

/// Settings → Transcription: models to download, the preferred tier for this Mac, the language.
struct TranscriptionSettings: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(TranscriptionService.modelKey) private var chosen = ""
    @AppStorage(TranscriptionService.languageKey) private var language = "auto"

    private static let languages = [("auto", "Detect automatically"), ("ru", "Russian"), ("en", "English"), ("de", "German"),
                                    ("fr", "French"), ("es", "Spanish"), ("uk", "Ukrainian")]

    var body: some View {
        TranscriptionSettingsBody(service: store.transcription, chosen: $chosen, language: $language, languages: Self.languages)
    }
}

private struct TranscriptionSettingsBody: View {
    @ObservedObject var service: TranscriptionService
    @Binding var chosen: String
    @Binding var language: String
    let languages: [(String, String)]

    var body: some View {
        let hw = service.hardware
        let recommended = service.recommended
        let _ = service.modelsChanged
        Card(title: "Transcription", footer: "Recordings are transcribed on this Mac with whisper.cpp; audio never leaves it. Models come from Hugging Face (ggerganov/whisper.cpp) and live in the app folder.") {
            FieldRow(title: "This Mac", subtitle: "\(hw.chip) · \(hw.memoryGB) GB memory") {
                Text("Recommended: \(recommended.title)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if Whisper.cli == nil {
                FieldRow(title: "whisper.cpp is not installed", subtitle: "In Terminal: brew install whisper-cpp") {
                    EmptyView()
                }
            }
            FieldRow(title: "Language") {
                InlineMenu(value: languages.first { $0.0 == language }?.1 ?? language, options: languages) { language = $0 }
                    .fixedSize()
            }
            ForEach(Array(Whisper.models.enumerated()), id: \.element.id) { i, model in
                modelRow(model, recommended: model == recommended, last: i == Whisper.models.count - 1)
            }
            if let error = service.downloadError {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.red).padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
    }

    private func modelRow(_ model: Whisper.Model, recommended: Bool, last: Bool) -> some View {
        let downloaded = service.isDownloaded(model)
        let inUse = service.activeModel == model
        let size = ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)
        return FieldRow(title: model.title + (recommended ? " · recommended" : ""),
                        subtitle: "\(size) · \(model.note)" + (model.minMemoryGB > service.hardware.memoryGB ? " · needs \(model.minMemoryGB) GB, may be slow here" : ""),
                        last: last) {
            HStack(spacing: 8) {
                if let progress = service.downloads[model.id] {
                    ProgressView(value: progress).frame(width: 90)
                    Text("\(Int(progress * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                    Button("Cancel") { service.cancelDownload(model) }.buttonStyle(AccentButtonStyle(prominent: false))
                } else if downloaded {
                    if inUse {
                        Text("In use").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.green)
                    } else {
                        Button("Use") { chosen = model.id; service.modelsChanged += 1 }.buttonStyle(AccentButtonStyle(prominent: false))
                    }
                    Button("Delete") { service.delete(model) }.buttonStyle(AccentButtonStyle(prominent: false))
                } else {
                    Button("Download") {
                        chosen = model.id
                        service.download(model)
                    }
                    .buttonStyle(AccentButtonStyle(prominent: recommended))
                }
            }
        }
    }
}
