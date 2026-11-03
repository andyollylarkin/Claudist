import AppKit
import Foundation
import Testing
@testable import ClaudistCore

enum AttachmentFixtures {
    /// A one-page PDF with `text` on it.
    static func pdf(_ text: String, at url: URL) throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: CGPoint(x: 20, y: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
        NSGraphicsContext.current = nil
        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: url)
    }

    /// A solid-color PNG.
    static func png(_ color: NSColor, at url: URL) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.current = nil
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

struct ChatAttachmentsTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(newID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @Test func buildsBlocksPerFileType() throws {
        let csv = dir.appendingPathComponent("ops.csv")
        try "day,amount\n2026-10-01,5\n".write(to: csv, atomically: true, encoding: .utf8)
        let png = dir.appendingPathComponent("red.png")
        try AttachmentFixtures.png(.red, at: png)
        let pdf = dir.appendingPathComponent("doc.pdf")
        try AttachmentFixtures.pdf("hello", at: pdf)
        let bin = dir.appendingPathComponent("x.bin")
        try Data([0, 1, 2, 0, 5]).write(to: bin)
        let db = dir.appendingPathComponent("b.sqlite")
        try SQLiteFile.create(at: db.path, ddl: "CREATE TABLE t (a INTEGER);")

        let blocks = ChatAttachments.content(text: "summarize", files: [csv, png, pdf, bin, db, dir.appendingPathComponent("gone.txt")])
        let types = blocks.map { $0["type"] as? String ?? "" }
        #expect(types == ["text", "text", "image", "text", "document", "text", "text", "text", "text"])
        #expect((blocks[0]["text"] as? String)?.contains("2026-10-01,5") == true)
        #expect((blocks[0]["text"] as? String)?.contains(csv.path) == true)
        #expect((blocks[5]["text"] as? String)?.contains("binary file") == true)
        #expect((blocks[6]["text"] as? String)?.contains("CREATE TABLE t") == true)
        #expect((blocks[7]["text"] as? String)?.contains("missing") == true)
        #expect(blocks.last?["text"] as? String == "summarize")
        #expect(ChatAttachments.content(text: " ", files: [csv]).last?["text"] as? String == "See the attached file.")

        let big = dir.appendingPathComponent("big.txt")
        try String(repeating: "line of text\n", count: 30_000).write(to: big, atomically: true, encoding: .utf8)
        guard case .text(_, let complete) = ChatAttachments.part(big) else { Issue.record("not text"); return }
        #expect(!complete)
    }
}

/// Run with: CLAUDIST_E2E=1 swift test --filter ChatAttachmentsE2E
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDIST_E2E"] == "1"))
struct ChatAttachmentsE2ETests {
    /// Claude Code takes image and PDF blocks over stream-json input with no tools.
    @Test(.timeLimit(.minutes(3))) func claudeSeesImageAndPDF() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attach-e2e-\(newID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("square.png")
        try AttachmentFixtures.png(.red, at: png)
        let pdf = dir.appendingPathComponent("note.pdf")
        try AttachmentFixtures.pdf("Code word: PELICAN", at: pdf)

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var process: AgentProcess?
            var text = ""
        }
        let box = Box()
        let done = AsyncStream<Void>.makeStream()
        let args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--strict-mcp-config", "--no-session-persistence", "--tools", "", "--model", "haiku"]
        let process = AgentProcess(executable: try ClaudeCLI.executable(), arguments: args, cwd: dir,
                                   environment: ClaudeCLI.environment()) { event in
            switch event {
            case .message(let k, let json) where k.hasPrefix("result"):
                box.lock.withLock { box.text = k + " " + (JSONValue.parse(json)?["result"]?.string ?? json) }
                box.lock.withLock { box.process }?.closeInput()
            case .exited: done.continuation.finish()
            default: break
            }
        }
        box.lock.withLock { box.process = process }
        try process.start()
        process.send(content: ChatAttachments.content(
            text: "Answer in one line: the color of the square, then the code word from the PDF.", files: [png, pdf]))
        for await _ in done.stream {}
        let text = box.lock.withLock { box.text }
        print("answer:", text)
        #expect(text.hasPrefix("result/success"))
        #expect(text.lowercased().contains("red"))
        #expect(text.uppercased().contains("PELICAN"))
    }
}
