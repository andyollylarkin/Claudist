import AVFoundation
import ClaudistCore
import Foundation
import GRDB

/// Recording sound and turning it into text: model downloads, the recorder and a one-at-a-time
/// transcription queue. Transcripts become notes in the Transcripts folder.
@MainActor
final class TranscriptionService: NSObject, ObservableObject {
    static let modelKey = "whisper.model"
    static let languageKey = "whisper.language"

    /// Model id → download progress 0…1.
    @Published var downloads: [String: Double] = [:]
    @Published var downloadError: String?
    /// Bumped when models appear or disappear on disk.
    @Published var modelsChanged = 0
    /// The recording in progress.
    @Published var recordingId: ID?
    @Published var recordingStarted: Date?
    @Published var transcribing: ID?

    let hardware = Whisper.Hardware.current
    private let db: AppDatabase
    private let paths: AppPaths
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var mic: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var queue: [ID] = []

    init(db: AppDatabase, paths: AppPaths) {
        self.db = db
        self.paths = paths
        super.init()
        // A recording cut off by a quit is kept as is; an interrupted transcription can be run again.
        try? db.writer.write { db in
            try db.execute(sql: "UPDATE recording SET status = 'recorded' WHERE status IN ('recording', 'transcribing')")
        }
    }

    var recommended: Whisper.Model { Whisper.recommended(for: hardware) }

    /// The model in use: the chosen one if downloaded, else any downloaded, best first.
    var activeModel: Whisper.Model? {
        let chosen = UserDefaults.standard.string(forKey: Self.modelKey).flatMap(Whisper.model) ?? recommended
        if Whisper.isDownloaded(chosen, paths: paths) { return chosen }
        return Whisper.models.reversed().first { Whisper.isDownloaded($0, paths: paths) }
    }

    func isDownloaded(_ model: Whisper.Model) -> Bool { Whisper.isDownloaded(model, paths: paths) }

    // MARK: Models

    func download(_ model: Whisper.Model) {
        guard tasks[model.id] == nil else { return }
        downloadError = nil
        let task = session.downloadTask(with: model.url)
        task.taskDescription = model.id
        tasks[model.id] = task
        downloads[model.id] = 0
        task.resume()
    }

    func cancelDownload(_ model: Whisper.Model) {
        tasks.removeValue(forKey: model.id)?.cancel()
        downloads[model.id] = nil
    }

    func delete(_ model: Whisper.Model) {
        try? FileManager.default.removeItem(at: Whisper.file(model, paths: paths))
        modelsChanged += 1
    }

    fileprivate func finished(_ modelId: String, file: URL?, error: Error?) {
        tasks[modelId] = nil
        downloads[modelId] = nil
        guard let model = Whisper.model(modelId) else { return }
        if let error {
            if (error as? URLError)?.code != .cancelled { downloadError = "\(model.title): \(error.localizedDescription)" }
            return
        }
        guard let file else { return }
        do {
            let dest = Whisper.file(model, paths: paths)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: file, to: dest)
            guard Whisper.isDownloaded(model, paths: paths) else {
                try? FileManager.default.removeItem(at: dest)
                throw ClaudistError.invalid("the download is incomplete")
            }
            if UserDefaults.standard.string(forKey: Self.modelKey) == nil { UserDefaults.standard.set(model.id, forKey: Self.modelKey) }
        } catch {
            downloadError = "\(model.title): \(error.localizedDescription)"
        }
        modelsChanged += 1
    }

    // MARK: Recording

    struct Sources: Equatable {
        var microphone = true
        /// nil = the default input.
        var micDevice: AudioDeviceID?
        var systemSound = true
        /// nil = every app; otherwise one app's audio processes.
        var app: AudioSources.App?
    }

    func start(_ sources: Sources) async throws {
        guard recordingId == nil else { return }
        guard sources.microphone || sources.systemSound else { throw ClaudistError.invalid("Choose what to record") }
        if sources.microphone {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw ClaudistError.invalid("Claudist has no access to the microphone: allow it in System Settings → Privacy & Security → Microphone") }
        }
        var recording = Recording(title: "Recording " + Date().formatted(date: .abbreviated, time: .shortened))
        recording.status = .recording
        recording.sourceApp = sources.systemSound ? (sources.app?.name ?? "System") : nil
        let dir = recording.folder(paths)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            if sources.microphone {
                let capture = MicrophoneCapture()
                try capture.start(device: sources.micDevice, to: dir.appendingPathComponent("mic.m4a"))
                mic = capture
                recording.micFile = "mic.m4a"
            }
            if sources.systemSound {
                let capture = SystemAudioCapture()
                try capture.start(processes: sources.app?.processes ?? [], to: dir.appendingPathComponent("system.m4a"))
                system = capture
                recording.systemFile = "system.m4a"
            }
        } catch {
            mic?.stop(); mic = nil
            system?.stop(); system = nil
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        try await db.writer.write { [recording] in try recording.insert($0) }
        recordingId = recording.id
        recordingStarted = Date()
    }

    func stop() {
        guard let id = recordingId else { return }
        // A track with no sound is dropped, with the reason shown on the recording.
        let micEmpty = mic?.emptyReason
        mic?.stop(); mic = nil
        system?.stop()
        let empty = system?.emptyReason
        system = nil
        let duration = recordingStarted.map { Date().timeIntervalSince($0) } ?? 0
        recordingId = nil
        recordingStarted = nil
        try? db.writer.write { db in
            try db.execute(sql: "UPDATE recording SET status = 'recorded', duration = ? WHERE id = ?", arguments: [duration, id])
            guard let r = try Recording.fetchOne(db, key: id) else { return }
            var problems: [String] = []
            if let micEmpty, let name = r.micFile {
                try? FileManager.default.removeItem(at: r.folder(self.paths).appendingPathComponent(name))
                try db.execute(sql: "UPDATE recording SET micFile = NULL WHERE id = ?", arguments: [id])
                problems.append("Nothing was recorded from the microphone: \(micEmpty).")
            }
            if let empty, let name = r.systemFile {
                try? FileManager.default.removeItem(at: r.folder(self.paths).appendingPathComponent(name))
                try db.execute(sql: "UPDATE recording SET systemFile = NULL WHERE id = ?", arguments: [id])
                problems.append("Nothing was recorded from \(r.sourceApp ?? "the apps"): \(empty).")
            }
            if !problems.isEmpty {
                try db.execute(sql: "UPDATE recording SET error = ? WHERE id = ?", arguments: [problems.joined(separator: " "), id])
            }
        }
    }

    /// An audio or video file the user brings in; copied into the recording's folder.
    func importFile(_ url: URL) throws {
        var recording = Recording(title: url.deletingPathExtension().lastPathComponent)
        let dir = recording.folder(paths)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "source." + (url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased())
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
        recording.micFile = name
        recording.duration = AVURLAsset(url: url).duration.seconds.isFinite ? AVURLAsset(url: url).duration.seconds : 0
        try db.writer.write { try recording.insert($0) }
    }

    func delete(_ recording: Recording) {
        if recordingId == recording.id { stop() }
        queue.removeAll { $0 == recording.id }
        try? FileManager.default.removeItem(at: recording.folder(paths))
        try? db.writer.write { _ = try recording.delete($0) }
    }

    // MARK: Transcription

    func transcribe(_ id: ID) {
        guard !queue.contains(id), transcribing != id else { return }
        queue.append(id)
        try? db.writer.write { db in
            try db.execute(sql: "UPDATE recording SET status = 'transcribing', error = NULL WHERE id = ?", arguments: [id])
        }
        runNext()
    }

    private func runNext() {
        guard transcribing == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard let model = activeModel else {
            fail(id, "Download a transcription model in Settings → Transcription")
            runNext()
            return
        }
        guard let recording = (try? db.writer.read { try Recording.fetchOne($0, key: id) }) ?? nil else { runNext(); return }
        transcribing = id
        let modelURL = Whisper.file(model, paths: paths)
        let language = UserDefaults.standard.string(forKey: Self.languageKey) ?? "auto"
        let tracks = recording.tracks(paths)
        let vault = NotesVault.configured(paths: paths)
        let paths = paths
        Task.detached(priority: .utility) {
            let result: Result<(String, String?), Error> = Result {
                let vad = Whisper.vadModel(paths: paths)
                var parts: [(speaker: String?, segments: [Whisper.Segment])] = []
                // Empty tracks (an app that played nothing) are skipped, not an error.
                let usable = tracks.filter { ((try? AVAudioFile(forReading: $0.url))?.length ?? 0) > 0 }
                guard !usable.isEmpty else { throw ClaudistError.invalid("The recording has no sound") }
                for track in usable {
                    parts.append((usable.count > 1 ? track.speaker : nil, try Whisper.transcribe(track.url, model: modelURL, vad: vad, language: language)))
                }
                let text = Whisper.markdown(Whisper.merge(parts))
                var done = recording
                done.model = model.id
                let body = text.isEmpty ? "_No speech recognized._" : text
                let path = recording.notePath ?? vault.newPath(Self.noteName(recording), in: "Transcripts")
                // The note is written only if the notes folder can take it; the transcript stays in the app either way.
                let notePath: String? = (try? vault.write(path, done.noteText(body))) != nil ? path : nil
                return (text, notePath)
            }
            await MainActor.run {
                switch result {
                case .success(let (text, notePath)):
                    try? self.db.writer.write { db in
                        try db.execute(sql: "UPDATE recording SET status = 'done', transcript = ?, notePath = ?, model = ?, error = NULL WHERE id = ?",
                                       arguments: [text, notePath, model.id, id])
                    }
                case .failure(let error):
                    self.fail(id, (error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
                self.transcribing = nil
                self.runNext()
            }
        }
    }

    nonisolated static func noteName(_ r: Recording) -> String {
        r.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
    }

    private func fail(_ id: ID, _ message: String) {
        try? db.writer.write { db in
            try db.execute(sql: "UPDATE recording SET status = 'failed', error = ? WHERE id = ?", arguments: [message, id])
        }
    }
}

extension TranscriptionService: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (Whisper.model(id)?.bytes ?? 1)
        let progress = Double(totalBytesWritten) / Double(expected)
        MainActor.assumeIsolated { if self.downloads[id] != nil { self.downloads[id] = progress } }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // The file is gone once this returns: keep it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-download-\(UUID().uuidString)")
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        MainActor.assumeIsolated {
            if status != 200 {
                try? FileManager.default.removeItem(at: kept)
                self.finished(id, file: nil, error: ClaudistError.invalid("server answered \(status)"))
            } else {
                self.finished(id, file: moved ? kept : nil, error: moved ? nil : ClaudistError.invalid("could not keep the file"))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        MainActor.assumeIsolated { self.finished(id, file: nil, error: error) }
    }
}
