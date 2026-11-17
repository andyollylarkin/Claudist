import Foundation
import Testing
@testable import ClaudistCore

struct WhisperTests {
    @Test func recommendsByHardware() {
        #expect(Whisper.recommended(for: .init(chip: "Apple M3 Pro", memoryGB: 18, appleSilicon: true)).id == "large-v3-turbo")
        #expect(Whisper.recommended(for: .init(chip: "Apple M1", memoryGB: 8, appleSilicon: true)).id == "large-v3-turbo-q5_0")
        #expect(Whisper.recommended(for: .init(chip: "Intel", memoryGB: 16, appleSilicon: false)).id == "small")
        #expect(Whisper.recommended(for: .init(chip: "Intel", memoryGB: 8, appleSilicon: false)).id == "base")
    }

    @Test func parsesAndMergesTracks() {
        let json = #"{"transcription": [{"offsets": {"from": 0, "to": 1500}, "text": " Hello"}, {"offsets": {"from": 1600, "to": 2500}, "text": " there"}, {"offsets": {"from": 9000, "to": 9500}, "text": "[BLANK_AUDIO]"}]}"#
        let me = Whisper.parse(Data(json.utf8))
        #expect(me.map(\.text) == ["Hello", "there"])
        let others = [Whisper.Segment(start: 3000, end: 4000, text: "Hi")]
        let merged = Whisper.merge([("Me", me), ("Others", others)])
        #expect(merged.map(\.text) == ["Hello there", "Hi"])
        #expect(Whisper.markdown(merged) == "**[00:00] Me:** Hello there\n\n**[00:03] Others:** Hi")
        #expect(Whisper.timestamp(3_723_000) == "1:02:03")
    }

    @Test func dropsDecoderLoops() {
        let loop = Array(repeating: "Do they have to manage the deadlines?", count: 40).joined(separator: " ")
        #expect(Whisper.collapseRepeats("Okay. Okay. But how? " + loop) == "Okay. Okay. But how? Do they have to manage the deadlines?")
        #expect(Whisper.collapseRepeats("Yes. Yes. No") == "Yes. Yes. No")
        let segment = #"{"offsets": {"from": 0, "to": 1}, "text": " The same long sentence."}"#
        let json = #"{"transcription": ["# + Array(repeating: segment, count: 5).joined(separator: ",") + "]}"
        #expect(Whisper.parse(Data(json.utf8)).count == 2)
    }

    /// Real whisper-cli run; set CLAUDIST_WHISPER_MODEL to a ggml model file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_WHISPER_MODEL"] != nil && Whisper.cli != nil))
    func transcribesSpeech() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", audio.path, "The release is planned for Friday. Please check the deployment."]
        try say.run()
        say.waitUntilExit()
        let segments = try Whisper.transcribe(audio, model: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDIST_WHISPER_MODEL"]!), language: "en")
        let text = segments.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("friday"))
        #expect(text.contains("deploy"))
    }
}
