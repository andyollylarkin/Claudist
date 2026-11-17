import Foundation

/// A tool permission request coming from Claude Code (`control_request` / `can_use_tool`).
public struct PermissionRequest: Identifiable, Sendable {
    public var id: String
    public var toolName: String
    public var description: String?
    /// Raw tool input as JSON text.
    public var inputJSON: String
    public let input: JSONValue
}

public enum PermissionDecision: Sendable {
    case allow
    case deny(String)
}

/// One `claude -p` process speaking stream-json over stdio.
///
/// Lifecycle: `start()` → `send(_:)` the prompt → stream of events → after the
/// `result` message the caller closes input and the process exits.
/// Follow-up messages start a new process with `--resume <sessionId>`.
public final class AgentProcess: @unchecked Sendable {
    public enum Event: Sendable {
        /// Any stream-json line, parsed. `kind` is `type` or `type/subtype`.
        case message(kind: String, json: String)
        case permission(PermissionRequest)
        /// JSON-RPC message for an app-served ("sdk") MCP server. Answer with `respondMCP`.
        case mcp(requestId: String, server: String, message: JSONValue)
        case stderr(String)
        case exited(Int32)
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let queue = DispatchQueue(label: "AgentProcess.write")
    /// Guards the stdout buffer and the exit bookkeeping: the read handler and the termination
    /// handler run on different threads.
    private let readLock = NSLock()
    private var buffer = Data()
    private var stdoutClosed = false
    private var exitStatus: Int32?
    private var exitReported = false
    private let onEvent: @Sendable (Event) -> Void

    public init(executable: URL, arguments: [String], cwd: URL, environment: [String: String], onEvent: @escaping @Sendable (Event) -> Void) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.onEvent = onEvent
    }

    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            if data.isEmpty {
                h.readabilityHandler = nil
                self.readLock.withLock { self.stdoutClosed = true }
                self.reportExitIfDone()
            } else {
                self.readLock.withLock { self.consume(data) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.onEvent(.stderr(String(decoding: data, as: UTF8.self)))
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.readLock.withLock { self.exitStatus = p.terminationStatus }
            self.reportExitIfDone()
            // Normally stdout ends right after; a child still holding it open must not hide the exit.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.readLock.withLock { self.stdoutClosed = true }
                self.reportExitIfDone()
            }
        }
        try process.run()
    }

    /// The exit is reported once, after the last stdout line, so no event follows it.
    private func reportExitIfDone() {
        let status: Int32? = readLock.withLock {
            guard stdoutClosed, let exitStatus, !exitReported else { return nil }
            exitReported = true
            return exitStatus
        }
        if let status { onEvent(.exited(status)) }
    }

    public func send(_ text: String) {
        write(["type": "user", "message": ["role": "user", "content": text]])
    }

    /// A user message of content blocks (text, image, document).
    public func send(content: [[String: Any]]) {
        write(["type": "user", "message": ["role": "user", "content": content]])
    }

    public func respond(_ request: PermissionRequest, _ decision: PermissionDecision) {
        let response: [String: Any]
        switch decision {
        case .allow:
            response = ["behavior": "allow", "updatedInput": request.input.any]
        case .deny(let message):
            response = ["behavior": "deny", "message": message]
        }
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": request.id, "response": response]])
    }

    /// Asks Claude Code to stop the current turn.
    public func interrupt() {
        write(["type": "control_request", "request_id": newID(), "request": ["subtype": "interrupt"]])
    }

    /// Declares app-served MCP servers; must be sent before the first user message.
    public func initialize(sdkMcpServers: [String]) {
        write(["type": "control_request", "request_id": newID(),
               "request": ["subtype": "initialize", "sdkMcpServers": sdkMcpServers]])
    }

    /// Replies to an `mcp` event. `result` nil answers a notification.
    public func respondMCP(requestId: String, id: JSONValue?, result: [String: Any]?, error: (code: Int, message: String)? = nil) {
        var message: [String: Any] = ["jsonrpc": "2.0"]
        if let id { message["id"] = id.any }
        if let error {
            message["error"] = ["code": error.code, "message": error.message]
        } else {
            message["result"] = result ?? [:]
        }
        write(["type": "control_response",
               "response": ["subtype": "success", "request_id": requestId, "response": ["mcp_response": message]]])
    }

    public func closeInput() {
        queue.async { try? self.stdin.fileHandleForWriting.close() }
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        queue.async { try? self.stdin.fileHandleForWriting.write(contentsOf: data) }
    }

    /// Called under `readLock`.
    private func consume(_ data: Data) {
        guard !exitReported else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            onEvent(.stderr(String(decoding: line, as: UTF8.self)))
            return
        }
        let type = value["type"]?.string ?? "unknown"
        if type == "control_request", let req = value["request"], req["subtype"]?.string == "can_use_tool" {
            let input = req["input"] ?? .object([:])
            onEvent(.permission(PermissionRequest(
                id: value["request_id"]?.string ?? "",
                toolName: req["tool_name"]?.string ?? "?",
                description: req["description"]?.string,
                inputJSON: input.prettyJSON,
                input: input)))
            return
        }
        if type == "control_request", let req = value["request"], req["subtype"]?.string == "mcp_message" {
            onEvent(.mcp(requestId: value["request_id"]?.string ?? "",
                         server: req["server_name"]?.string ?? "",
                         message: req["message"] ?? .object([:])))
            return
        }
        // Acks of our own control requests (initialize, interrupt) carry no transcript content.
        if type == "control_response" { return }
        let kind = value["subtype"]?.string.map { "\(type)/\($0)" } ?? type
        onEvent(.message(kind: kind, json: String(decoding: line, as: UTF8.self)))
    }
}
