import Foundation
import GRDB

/// An audio recording and its transcript. Files live in `<data>/recordings/<id>/`:
/// `mic.m4a` (the user), `system.m4a` (the other side of a call) or an imported file.
public struct Recording: Codable, Sendable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public enum Status: String, Codable, Sendable {
        case recording, recorded, transcribing, done, failed
    }

    public var id: ID = newID()
    public var title: String
    public var createdAt = LocalDate.stamp(Date())
    public var duration: Double = 0
    /// The app whose sound was recorded, or "System" for all of it.
    public var sourceApp: String?
    /// File names inside the recording's folder.
    public var micFile: String?
    public var systemFile: String?
    public var status = Status.recorded
    public var error: String?
    public var transcript: String?
    /// Notes-relative path of the transcript note.
    public var notePath: String?
    public var model: String?

    public init(title: String) { self.title = title }

    public static func folder(_ paths: AppPaths, id: ID) -> URL {
        paths.root.appendingPathComponent("recordings/\(id)", isDirectory: true)
    }

    public func folder(_ paths: AppPaths) -> URL { Self.folder(paths, id: id) }

    /// Tracks to transcribe with their speaker labels.
    public func tracks(_ paths: AppPaths) -> [(speaker: String?, url: URL)] {
        let dir = folder(paths)
        let both = micFile != nil && systemFile != nil
        var out: [(String?, URL)] = []
        if let micFile { out.append((both ? "Me" : nil, dir.appendingPathComponent(micFile))) }
        if let systemFile { out.append((both ? "Others" : nil, dir.appendingPathComponent(systemFile))) }
        return out
    }

    /// The transcript note: title, source, then the text.
    public func noteText(_ body: String) -> String {
        var head = "---\ntags: [transcript]\nrecorded: \(createdAt)\n"
        if let sourceApp { head += "source: \(sourceApp)\n" }
        if let model { head += "model: \(model)\n" }
        head += "---\n\n# \(title)\n\n"
        return head + body + "\n"
    }
}
