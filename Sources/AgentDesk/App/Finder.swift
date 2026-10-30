import AppKit

/// Finder and file panel helpers. Agent folders keep everything in `.claude/`,
/// which Finder and open panels hide by default.
enum Finder {
    static func openPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        return panel
    }

    /// Opens a folder in Finder; hidden folders like `.claude` open fine when targeted directly.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Finder's global "show hidden files" switch (same as ⌘⇧. in a Finder window).
    static var showsHiddenFiles: Bool {
        UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "AppleShowAllFiles") ?? false
    }

    static func setShowsHiddenFiles(_ on: Bool) {
        run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", on ? "true" : "false"])
        run("/usr/bin/killall", ["Finder"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}
