import Foundation

/// Talks to the local Codex CLI over `codex app-server` (newline-delimited JSON-RPC on stdio).
/// Uses whatever account Codex is logged into, so no API key lives in this app.
final class CodexClient: @unchecked Sendable {
    static let shared = CodexClient()

    enum ClientError: LocalizedError {
        case codexNotFound
        case processExited(String)
        case rpc(String)
        case turnFailed(String)

        var errorDescription: String? {
            switch self {
            case .codexNotFound: return "Couldn't find the `codex` CLI. Install it and run `codex login` in Terminal."
            case .processExited(let s): return "Codex stopped: \(s)"
            case .rpc(let s): return "Codex error: \(s)"
            case .turnFailed(let s): return s
            }
        }
    }

    /// Streamed events for a single turn.
    enum TurnEvent {
        case status(String)       // "Searching the web: …", commentary
        case delta(String)        // final-answer text chunk
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextId = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var listeners: [String: ([String: Any], String) -> Void] = [:] // threadId -> (params, method)
    private var startTask: Task<Void, Error>?
    private var stderrTail = ""

    var codexPathOverride: String?

    // MARK: Lifecycle

    func ensureStarted() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let t = startTask { return t }
            let t = Task { try await self.launch() }
            startTask = t
            return t
        }
        do { try await task.value } catch {
            lock.withLock { startTask = nil }
            throw error
        }
    }

    func shutdown() {
        lock.withLock {
            process?.terminate()
            process = nil
            startTask = nil
        }
    }

    private static let searchPath: [String] = {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin",
                "\(home)/.npm-global/bin", "/usr/bin", "/bin"]
    }()

    private func resolveCodex() -> String? {
        if let o = codexPathOverride, FileManager.default.isExecutableFile(atPath: o) { return o }
        for dir in Self.searchPath where FileManager.default.isExecutableFile(atPath: "\(dir)/codex") {
            return "\(dir)/codex"
        }
        return nil
    }

    private func launch() async throws {
        guard let codex = resolveCodex() else { throw ClientError.codexNotFound }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = ["app-server", "-c", "web_search=\"live\""]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Self.searchPath + [env["PATH"] ?? ""]).joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = BriefStore.workspaceURL

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let tail = self.lock.withLock { self.stderrTail }
            let err = ClientError.processExited("exit \(proc.terminationStatus). \(tail.suffix(300))")
            let waiting = self.lock.withLock { () -> [(Result<[String: Any], Error>) -> Void] in
                let w = Array(self.pending.values)
                self.pending.removeAll()
                self.process = nil
                self.startTask = nil
                return w
            }
            waiting.forEach { $0(.failure(err)) }
            let ls = self.lock.withLock { Array(self.listeners.values) }
            ls.forEach { $0(["error": ["message": err.localizedDescription]], "client/processExited") }
        }

        try p.run()
        lock.withLock {
            process = p
            stdinHandle = inPipe.fileHandleForWriting
        }
        startReader(outPipe.fileHandleForReading)
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            self.lock.withLock { self.stderrTail = String((self.stderrTail + s).suffix(2000)) }
        }

        _ = try await rawRequest("initialize", [
            "clientInfo": ["name": "elite-comms", "title": "elite-comms", "version": "0.1.0"],
            "capabilities": NSNull(),
        ])
        send(["jsonrpc": "2.0", "method": "initialized"])
    }

    private func startReader(_ handle: FileHandle) {
        let thread = Thread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        self?.handle(obj)
                    }
                }
            }
        }
        thread.name = "elite-comms-codex-reader"
        thread.start()
    }

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String
        if let method, let id = msg["id"] {
            // Server -> client request (approvals, auth refresh, user input). elite-comms never grants anything.
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "elite-comms does not handle \(method)"]])
            return
        }
        if let method {
            let params = msg["params"] as? [String: Any] ?? [:]
            if let tid = params["threadId"] as? String {
                let l = lock.withLock { listeners[tid] }
                l?(params, method)
            }
            return
        }
        guard let id = (msg["id"] as? NSNumber)?.intValue else { return }
        let cb = lock.withLock { pending.removeValue(forKey: id) }
        if let err = msg["error"] as? [String: Any] {
            cb?(.failure(ClientError.rpc(err["message"] as? String ?? "\(err)")))
        } else {
            cb?(.success(msg["result"] as? [String: Any] ?? [:]))
        }
    }

    private func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        lock.withLock { try? stdinHandle?.write(contentsOf: data) }
    }

    private func rawRequest(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            let id: Int = lock.withLock {
                let id = nextId; nextId += 1
                pending[id] = { cont.resume(with: $0) }
                return id
            }
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await ensureStarted()
        return try await rawRequest(method, params)
    }

    // MARK: Threads & turns

    func startThread(model: String, instructions: String) async throws -> String {
        let r = try await request("thread/start", [
            "model": model,
            "cwd": BriefStore.workspaceURL.path,
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "ephemeral": true,
            "developerInstructions": instructions,
        ])
        guard let thread = r["thread"] as? [String: Any], let id = thread["id"] as? String else {
            throw ClientError.rpc("thread/start returned no id")
        }
        return id
    }

    /// Runs one turn and streams events. Returns the full final answer.
    func runTurn(threadId: String, text: String, effort: String,
                 onEvent: @escaping @Sendable (TurnEvent) -> Void) async throws -> String {
        try await ensureStarted()
        final class State: @unchecked Sendable {
            var phases: [String: String] = [:]
            var finalText = ""
            var done = false
            var cont: CheckedContinuation<String, Error>?
        }
        let st = State()
        let stLock = NSLock()

        func finish(_ r: Result<String, Error>) {
            let c: CheckedContinuation<String, Error>? = stLock.withLock {
                guard !st.done else { return nil }
                st.done = true
                return st.cont
            }
            c?.resume(with: r)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                stLock.withLock { st.cont = cont }
                lock.withLock {
                    listeners[threadId] = { params, method in
                        switch method {
                        case "item/started":
                            guard let item = params["item"] as? [String: Any] else { return }
                            let type = item["type"] as? String
                            if type == "agentMessage", let id = item["id"] as? String {
                                stLock.withLock { st.phases[id] = item["phase"] as? String ?? "final_answer" }
                            } else if type == "webSearch" {
                                onEvent(.status("Searching the web…"))
                            }
                        case "item/completed":
                            guard let item = params["item"] as? [String: Any] else { return }
                            if item["type"] as? String == "webSearch",
                               let action = item["action"] as? [String: Any],
                               let q = action["query"] as? String ?? item["query"] as? String, !q.isEmpty {
                                onEvent(.status("Searched: \(q)"))
                            }
                        case "item/agentMessage/delta":
                            let id = params["itemId"] as? String ?? ""
                            let delta = params["delta"] as? String ?? ""
                            let phase = stLock.withLock { st.phases[id] ?? "final_answer" }
                            if phase == "commentary" {
                                onEvent(.status(delta))
                            } else {
                                stLock.withLock { st.finalText += delta }
                                onEvent(.delta(delta))
                            }
                        case "turn/completed":
                            let turn = params["turn"] as? [String: Any]
                            if (turn?["status"] as? String) == "failed" {
                                let e = (turn?["error"] as? [String: Any])?["message"] as? String ?? "Turn failed"
                                finish(.failure(ClientError.turnFailed(e)))
                            } else {
                                finish(.success(stLock.withLock { st.finalText }))
                            }
                        case "error":
                            let e = params["error"] as? [String: Any]
                            if (params["willRetry"] as? Bool) != true {
                                finish(.failure(ClientError.turnFailed(e?["message"] as? String ?? "Codex error")))
                            }
                        case "client/processExited":
                            let e = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex exited"
                            finish(.failure(ClientError.processExited(e)))
                        default: break
                        }
                    }
                }
                Task {
                    do {
                        _ = try await self.rawRequest("turn/start", [
                            "threadId": threadId,
                            "effort": effort,
                            "input": [["type": "text", "text": text, "text_elements": []]],
                        ])
                    } catch { finish(.failure(error)) }
                }
            }
        } onCancel: {
            Task { _ = try? await self.rawRequest("turn/interrupt", ["threadId": threadId]) }
            finish(.failure(CancellationError()))
        }
    }

    func forget(threadId: String) {
        lock.withLock { _ = listeners.removeValue(forKey: threadId) }
    }

    /// One-shot helper: fresh ephemeral thread, single turn.
    func oneShot(model: String, instructions: String, prompt: String, effort: String,
                 onEvent: @escaping @Sendable (TurnEvent) -> Void = { _ in }) async throws -> String {
        let tid = try await startThread(model: model, instructions: instructions)
        defer { forget(threadId: tid) }
        return try await runTurn(threadId: tid, text: prompt, effort: effort, onEvent: onEvent)
    }

    func listModels() async -> [String] {
        guard let r = try? await request("model/list", [:]) else { return [] }
        let items = (r["data"] as? [[String: Any]]) ?? (r["models"] as? [[String: Any]]) ?? []
        return items.compactMap { ($0["model"] as? String) ?? ($0["id"] as? String) ?? ($0["slug"] as? String) }
    }
}
