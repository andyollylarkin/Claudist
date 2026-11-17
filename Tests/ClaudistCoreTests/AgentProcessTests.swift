import Foundation
import Testing
@testable import ClaudistCore

struct AgentProcessTests {
    /// Output written right before the process exits arrives in full, and the exit comes once, last.
    @Test func exitFollowsTheLastLine() async throws {
        final class Events: @unchecked Sendable {
            let lock = NSLock()
            var kinds: [String] = []
            var exits = 0
            var exitedAfter = -1
        }
        let events = Events()
        let done = DispatchSemaphore(value: 0)
        let script = "i=0; while [ $i -lt 2000 ]; do echo '{\"type\":\"assistant\",\"n\":'$i'}'; i=$((i+1)); done"
        let process = AgentProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                   cwd: FileManager.default.temporaryDirectory, environment: [:]) { event in
            events.lock.withLock {
                switch event {
                case .message(let kind, _): events.kinds.append(kind)
                case .exited:
                    events.exits += 1
                    events.exitedAfter = events.kinds.count
                    done.signal()
                default: break
                }
            }
        }
        try process.start()
        #expect(done.wait(timeout: .now() + 10) == .success)
        // Anything late (a second exit, lines after it) would show up here.
        try await Task.sleep(for: .seconds(2.5))
        events.lock.withLock {
            #expect(events.exits == 1)
            #expect(events.kinds.count == 2000)
            #expect(events.exitedAfter == 2000)
        }
    }
}
