import Foundation

/// Speech-to-text on this Mac with whisper.cpp (`whisper-cli`) and a downloaded ggml model.
public enum Whisper {
    public struct Model: Identifiable, Sendable, Hashable {
        /// ggml file name part: `ggml-<id>.bin`.
        public var id: String
        public var title: String
        public var bytes: Int64
        public var note: String
        /// Least memory for the model to run comfortably next to everything else.
        public var minMemoryGB: Int

        public var fileName: String { "ggml-\(id).bin" }
        public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    }

    public static let models: [Model] = [
        Model(id: "base", title: "Base", bytes: 147_951_465, note: "Fast, rough; quick notes in English", minMemoryGB: 4),
        Model(id: "small", title: "Small", bytes: 487_601_967, note: "Decent for clear speech", minMemoryGB: 4),
        Model(id: "large-v3-turbo-q5_0", title: "Large v3 Turbo (compressed)", bytes: 574_041_195,
              note: "Nearly full Turbo quality at a third of the size", minMemoryGB: 8),
        Model(id: "large-v3-turbo", title: "Large v3 Turbo", bytes: 1_624_555_275,
              note: "Best balance of quality and speed; strong in Russian", minMemoryGB: 16),
        Model(id: "large-v3", title: "Large v3", bytes: 3_095_033_483,
              note: "Slightly more accurate, several times slower", minMemoryGB: 32),
    ]

    public static func model(_ id: String) -> Model? { models.first { $0.id == id } }

    /// What this Mac is, for picking a model.
    public struct Hardware: Sendable, Equatable {
        public var chip: String
        public var memoryGB: Int
        public var appleSilicon: Bool

        public init(chip: String, memoryGB: Int, appleSilicon: Bool) {
            self.chip = chip
            self.memoryGB = memoryGB
            self.appleSilicon = appleSilicon
        }

        public static var current: Hardware {
            func sysctl(_ name: String) -> String? {
                var size = 0
                guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
                var buffer = [CChar](repeating: 0, count: size)
                guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
                return String(cString: buffer)
            }
            var arm: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let isArm = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
            return Hardware(chip: sysctl("machdep.cpu.brand_string") ?? "Mac",
                            memoryGB: Int((ProcessInfo.processInfo.physicalMemory + (1 << 29)) >> 30), appleSilicon: isArm)
        }
    }

    /// The preferred tier: the best model that runs well here. Intel Macs have no Metal speed-up
    /// for whisper.cpp worth the large models; Apple Silicon with 16 GB takes Turbo in full.
    public static func recommended(for hw: Hardware) -> Model {
        let id: String
        if !hw.appleSilicon {
            id = hw.memoryGB >= 16 ? "small" : "base"
        } else if hw.memoryGB >= 16 {
            id = "large-v3-turbo"
        } else if hw.memoryGB >= 8 {
            id = "large-v3-turbo-q5_0"
        } else {
            id = "small"
        }
        return model(id)!
    }

    // MARK: Models on disk

    public static func folder(_ paths: AppPaths) -> URL {
        paths.root.appendingPathComponent("models/whisper", isDirectory: true)
    }

    public static func file(_ model: Model, paths: AppPaths) -> URL {
        folder(paths).appendingPathComponent(model.fileName)
    }

    public static func isDownloaded(_ model: Model, paths: AppPaths) -> Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file(model, paths: paths).path))?[.size] as? NSNumber)?.int64Value ?? 0
        return size > model.bytes / 2
    }

    /// Silero voice activity model: silence and noise never reach whisper, which invents text there.
    public static let vadFileName = "ggml-silero-v6.2.0.bin"
    static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/\(vadFileName)")!
    static let vadBytes: Int64 = 885_098

    /// The VAD model, downloaded on first use (under a megabyte); nil when it can't be had.
    public static func vadModel(paths: AppPaths) -> URL? {
        let url = folder(paths).appendingPathComponent(vadFileName)
        let size = { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        if size() == vadBytes { return url }
        try? FileManager.default.createDirectory(at: folder(paths), withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: vadURL), Int64(data.count) == vadBytes,
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    // MARK: Running

    public static var cliSearchPaths: [String] {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
    }

    public static var cli: URL? {
        cliSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public struct Segment: Sendable, Equatable {
        /// Milliseconds from the start.
        public var start: Int
        public var end: Int
        public var text: String
        public var speaker: String?

        public init(start: Int, end: Int, text: String, speaker: String? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }
    }

    /// Any audio file → 16 kHz mono WAV, what whisper.cpp reads.
    public static func convert(_ input: URL, to output: URL) throws {
        try run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, output.path])
    }

    /// Transcribes one audio file; `language` is a code like "ru" or "auto".
    public static func transcribe(_ audio: URL, model: URL, vad: URL? = nil, language: String,
                                  threads: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)) throws -> [Segment] {
        guard let cli else { throw ClaudistError.invalid("whisper.cpp is not installed: brew install whisper-cpp") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("whisper-\(newID())", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let wav = work.appendingPathComponent("audio.wav")
        try convert(audio, to: wav)
        let out = work.appendingPathComponent("out")
        // No text context between windows (-mc 0): with it one misheard phrase can repeat for minutes.
        var args = ["-m", model.path, "-f", wav.path, "-l", language, "-t", String(threads), "-oj", "-of", out.path, "-np",
                    "-mc", "0", "-sns"]
        if let vad { args += ["--vad", "-vm", vad.path] }
        do {
            try run(cli, args)
        } catch {
            // Metal can fail where the GPU isn't reachable (sandboxes, some Macs); the CPU always works, slower.
            try run(cli, args + ["-ng"])
        }
        let data = try Data(contentsOf: out.appendingPathExtension("json"))
        return parse(data)
    }

    /// whisper-cli's JSON: `transcription[].offsets.from/to` (ms) and `text`.
    public static func parse(_ data: Data) -> [Segment] {
        // whisper.cpp may cut a multi-byte character at a segment edge; decode leniently.
        guard let value = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { return [] }
        var out: [Segment] = []
        for s in value["transcription"]?.array ?? [] {
            let text = collapseRepeats((s["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            guard !text.isEmpty, text != "[BLANK_AUDIO]" else { continue }
            // A segment that only repeats the two before it is the decoder looping, not speech.
            if out.count >= 2, out.suffix(2).allSatisfy({ $0.text == text }), text.count > 12 { continue }
            out.append(Segment(start: Int(s["offsets"]?["from"]?.number ?? 0), end: Int(s["offsets"]?["to"]?.number ?? 0), text: text))
        }
        return out
    }

    /// A sentence repeated three or more times in a row is kept once ("Yes. Yes." stays).
    static func collapseRepeats(_ text: String) -> String {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!…".contains(ch) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
        var out: [String] = []
        var i = 0
        while i < sentences.count {
            var j = i
            while j + 1 < sentences.count, sentences[j + 1] == sentences[i] { j += 1 }
            let run = j - i + 1
            out += Array(repeating: sentences[i], count: run >= 3 ? 1 : run)
            i = j + 1
        }
        return out.joined(separator: " ")
    }

    /// Segments of several tracks in time order; neighbouring segments of one speaker join into one paragraph.
    public static func merge(_ tracks: [(speaker: String?, segments: [Segment])]) -> [Segment] {
        let all = tracks.flatMap { t in t.segments.map { var s = $0; s.speaker = t.speaker; return s } }
            .sorted { ($0.start, $0.speaker ?? "") < ($1.start, $1.speaker ?? "") }
        var out: [Segment] = []
        for s in all {
            if var last = out.last, last.speaker == s.speaker, s.start - last.end < 2000 {
                last.text += " " + s.text
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// The transcript as Markdown lines: `**[01:02] Me:** text`.
    public static func markdown(_ segments: [Segment]) -> String {
        segments.map { s in
            "**[\(timestamp(s.start))]" + (s.speaker.map { " \($0):" } ?? "") + "** " + s.text
        }.joined(separator: "\n\n")
    }

    public static func timestamp(_ ms: Int) -> String {
        let total = ms / 1000
        let (h, m, sec) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    private static func run(_ exe: URL, _ args: [String]) throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        // Homebrew's ggml 0.28 embeds Metal kernels whose bfloat code doesn't compile on macOS 15 and older;
        // whisper models don't use bfloat, and without it the GPU works.
        var environment = ProcessInfo.processInfo.environment
        environment["GGML_METAL_BF16_DISABLE"] = "1"
        p.environment = environment
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let tail = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: tail.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClaudistError.invalid("\(exe.lastPathComponent) failed: \(message.isEmpty ? "exit \(p.terminationStatus)" : message)")
        }
    }
}
