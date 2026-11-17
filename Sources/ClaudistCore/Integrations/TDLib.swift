import Foundation

/// TDLib, Telegram's client library, through its JSON interface (libtdjson), loaded at run time.
/// One client per process: `td_receive` serves every client, and the app needs one.
public final class TDLibClient: @unchecked Sendable {
    typealias CreateClient = @convention(c) () -> Int32
    typealias Send = @convention(c) (Int32, UnsafePointer<CChar>) -> Void
    typealias Receive = @convention(c) (Double) -> UnsafePointer<CChar>?
    typealias Execute = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?

    /// Where libtdjson is looked for: inside the app, then Homebrew.
    public static var searchPaths: [String] {
        [Bundle.main.privateFrameworksPath.map { $0 + "/libtdjson.dylib" },
         "/opt/homebrew/opt/tdlib/lib/libtdjson.dylib", "/opt/homebrew/lib/libtdjson.dylib",
         "/usr/local/opt/tdlib/lib/libtdjson.dylib", "/usr/local/lib/libtdjson.dylib"].compactMap { $0 }
    }

    public static var isAvailable: Bool { searchPaths.contains { FileManager.default.fileExists(atPath: $0) } }

    /// The library, loaded once, and the one thread that receives for every client.
    private final class Library: @unchecked Sendable {
        let create: CreateClient
        let send: Send
        let receive: Receive
        let lock = NSLock()
        var clients: [Int32: TDLibClientBox] = [:]
        /// Cleared at quit; the receive thread then ends and signals `ended`.
        var running = true
        let ended = DispatchSemaphore(value: 0)

        init() throws {
            guard let path = TDLibClient.searchPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
                  let lib = dlopen(path, RTLD_NOW) else {
                throw ClaudistError.invalid("TDLib is not installed. Install it with `brew install tdlib` and reopen Claudist.")
            }
            guard let create = dlsym(lib, "td_create_client_id"), let send = dlsym(lib, "td_send"),
                  let receive = dlsym(lib, "td_receive"), let execute = dlsym(lib, "td_execute") else {
                throw ClaudistError.invalid("libtdjson at \(path) is missing functions; update TDLib")
            }
            self.create = unsafeBitCast(create, to: CreateClient.self)
            self.send = unsafeBitCast(send, to: Send.self)
            self.receive = unsafeBitCast(receive, to: Receive.self)
            // Quiet: TDLib logs to stderr otherwise, and its log may name chats.
            _ = #"{"@type":"setLogVerbosityLevel","new_verbosity_level":0}"#.withCString { unsafeBitCast(execute, to: Execute.self)($0) }
            let thread = Thread { [unowned self] in
                while self.lock.withLock({ self.running }) {
                    guard let raw = self.receive(0.25) else { continue }
                    guard let value = JSONValue.parse(String(cString: raw)), let id = value["@client_id"]?.number else { continue }
                    let client = self.lock.withLock { self.clients[Int32(id)]?.client }
                    client?.dispatch(value)
                }
                self.ended.signal()
            }
            thread.name = "TDLib"
            thread.start()
        }

        nonisolated(unsafe) static var shared: Library?
        static let sharedLock = NSLock()
        static func load() throws -> Library {
            try sharedLock.withLock {
                if let shared { return shared }
                let lib = try Library()
                shared = lib
                return lib
            }
        }
    }

    /// Closes every client and stops the receive thread before the process exits: a thread still inside
    /// `td_receive` while static destructors run crashes the app on quit. Waits at most about 1.5 s.
    public static func shutdown() {
        guard let library = Library.sharedLock.withLock({ Library.shared }) else { return }
        let clients = library.lock.withLock { library.clients.values.compactMap(\.client) }
        for client in clients { client.close() }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, clients.contains(where: { !$0.isStopped }) { Thread.sleep(forTimeInterval: 0.05) }
        library.lock.withLock { library.running = false }
        _ = library.ended.wait(timeout: .now() + 0.5)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private final class TDLibClientBox { weak var client: TDLibClient?; init(_ c: TDLibClient) { client = c } }

    private let library: Library
    private let clientId: Int32
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var stopped = false
    /// Updates (anything not answering a request), on the receive thread.
    private let onUpdate: @Sendable (JSONValue) -> Void

    public init(onUpdate: @escaping @Sendable (JSONValue) -> Void) throws {
        library = try Library.load()
        self.onUpdate = onUpdate
        clientId = library.create()
        library.lock.withLock { library.clients[clientId] = TDLibClientBox(self) }
        // The first request starts the client; its updates then begin.
        fire(["@type": "getOption", "name": "version"])
    }

    deinit {
        library.lock.withLock { _ = library.clients.removeValue(forKey: clientId) }
    }

    fileprivate func dispatch(_ value: JSONValue) {
        if let extra = value["@extra"]?.string, let continuation = lock.withLock({ waiting.removeValue(forKey: extra) }) {
            if value["@type"]?.string == "error" {
                continuation.resume(throwing: ClaudistError.invalid("Telegram: " + (value["message"]?.string ?? "error")))
            } else {
                continuation.resume(returning: value)
            }
            return
        }
        onUpdate(value)
        if value["@type"]?.string == "updateAuthorizationState",
           value["authorization_state"]?["@type"]?.string == "authorizationStateClosed" {
            let pending = lock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
                stopped = true
                defer { waiting = [:] }
                return Array(waiting.values)
            }
            for c in pending { c.resume(throwing: ClaudistError.invalid("Telegram is disconnected")) }
        }
    }

    /// Sends a request without waiting for its answer.
    public func fire(_ request: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return }
        String(decoding: data, as: UTF8.self).withCString { library.send(clientId, $0) }
    }

    /// Sends a request and waits for its answer; TDLib errors are thrown.
    public func call(_ request: [String: Any]) async throws -> JSONValue {
        let extra = UUID().uuidString
        var request = request
        request["@extra"] = extra
        return try await withCheckedThrowingContinuation { continuation in
            let closed = lock.withLock { () -> Bool in
                if stopped { return true }
                waiting[extra] = continuation
                return false
            }
            if closed {
                continuation.resume(throwing: ClaudistError.invalid("Telegram is disconnected"))
                return
            }
            fire(request)
        }
    }

    /// Ends the session's process side (the login stays in TDLib's database).
    public func close() {
        fire(["@type": "close"])
    }
}
