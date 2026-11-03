import Foundation

/// Files the user attaches to an assistant message.
///
/// The assistant has no file tools, so the app reads the files and puts them into the message:
/// images and PDFs as content blocks Claude sees directly, text as text, SQLite files as their
/// schema. Anything else is named with its path only.
public enum ChatAttachments {
    /// Text of one file put into the message at most.
    public static let maxTextBytes = 200_000
    public static let maxImageBytes = 5_000_000
    public static let maxPDFBytes = 20_000_000

    static let imageTypes: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                               "gif": "image/gif", "webp": "image/webp"]

    /// What becomes of one file.
    public enum Part: Equatable {
        case image(mediaType: String, data: Data)
        case pdf(Data)
        case text(String, complete: Bool)
        case note(String)
    }

    public static func part(_ url: URL) -> Part {
        let ext = url.pathExtension.lowercased()
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .note("the file is missing") }
        if isDir.boolValue {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
            return .text("Folder with \(names.count) item(s):\n" + names.prefix(300).joined(separator: "\n"), complete: names.count <= 300)
        }
        if let type = imageTypes[ext] {
            guard size <= maxImageBytes, let data = try? Data(contentsOf: url) else {
                return .note("image too large to include (\(size / 1_000_000) MB; at most \(maxImageBytes / 1_000_000) MB)")
            }
            return .image(mediaType: type, data: data)
        }
        if ext == "pdf" {
            guard size <= maxPDFBytes, let data = try? Data(contentsOf: url) else {
                return .note("PDF too large to include (\(size / 1_000_000) MB; at most \(maxPDFBytes / 1_000_000) MB)")
            }
            return .pdf(data)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .note("could not be read") }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxTextBytes + 1)) ?? Data()
        if data.starts(with: Data("SQLite format 3".utf8)) {
            let ddl = (try? SQLiteFile.schemaSQL(url.path)) ?? ""
            return .text("SQLite database; its schema:\n" + ddl, complete: false)
        }
        if data.prefix(8192).contains(0) {
            return .note("binary file (\(ext.isEmpty ? "unknown type" : ext.uppercased()), \(size) bytes); its contents can't be shown — export it as text, CSV or PDF")
        }
        var text = String(decoding: data.prefix(maxTextBytes), as: UTF8.self)
        // Don't end inside a multi-byte character cut by the limit.
        if data.count > maxTextBytes, let last = text.lastIndex(of: "\n") { text = String(text[..<last]) }
        return .text(text, complete: data.count <= maxTextBytes)
    }

    /// Content blocks of a user message: the files first, then the text.
    public static func content(text: String, files: [URL]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for url in files {
            let header = "Attached file `\(url.lastPathComponent)` (path: \(url.path))"
            switch part(url) {
            case .image(let type, let data):
                blocks.append(["type": "text", "text": header + ":"])
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": type, "data": data.base64EncodedString()]])
            case .pdf(let data):
                blocks.append(["type": "text", "text": header + ":"])
                blocks.append(["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()],
                               "title": url.lastPathComponent])
            case .text(let body, let complete):
                blocks.append(["type": "text", "text": "\(header)\(complete ? "" : ", beginning only"):\n```\n\(body)\n```"])
            case .note(let why):
                blocks.append(["type": "text", "text": "\(header): \(why)."])
            }
        }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        blocks.append(["type": "text", "text": message.isEmpty ? "See the attached file\(files.count == 1 ? "" : "s")." : message])
        return blocks
    }
}
