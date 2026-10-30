import Foundation
import GRDB

public final class AppDatabase {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.migrator().migrate(writer)
    }

    /// On-disk database at `<appSupport>/AgentDesk/db.sqlite`.
    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabasePool(path: url.path, configuration: config))
    }

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }
}
