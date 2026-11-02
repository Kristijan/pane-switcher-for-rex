import Darwin
import Foundation

struct RexStreamEvent: @unchecked Sendable {
    let type: String
    let sessionID: String?
    let blockID: String?
    let payload: [String: Any]
}

enum RexConnectionError: Error, LocalizedError {
    case disconnected(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .disconnected(let message), .requestFailed(let message): return message
        }
    }
}

// All connection state belongs to queue. Blocking pipe reads and backpressured writes
// belong to the workers, so an idle command reader cannot starve the event worker.
final class RexConnection: @unchecked Sendable {
    private let executable: URL
    private let host: RexHost
    private let queue = DispatchQueue(label: "PaneSwitch.RexConnection")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stopped = false
    private var commandWorker: RexStdioWorker?
    private var requests: [String: Request] = [:]
    private var waiting: [String] = []
    private var waitingIndex = 0
    private var active: Request?
    private var eventWorker: RexStdioWorker?
    private var eventConsumer: AsyncThrowingStream<RexStreamEvent, Error>.Continuation?
    private var eventConsumerID: UUID?
    private var eventReady = false
    private var eventDeadline: DispatchWorkItem?

    init(executable: URL, host: RexHost) {
        self.executable = executable
        self.host = host
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { shutdown() }

    func execute(_ script: String, arguments: [String: Any] = [:], timeout: TimeInterval = 8) async throws -> [String: Any] {
        let startedAt = DispatchTime.now()
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0,
              timeout * 1_000_000_000 < Double(UInt64.max - startedAt.uptimeNanoseconds) else {
            throw RexConnectionError.requestFailed("Rex request timeout must be positive, finite, and representable.")
        }
        let deadline = DispatchTime(uptimeNanoseconds: startedAt.uptimeNanoseconds + UInt64(timeout * 1_000_000_000))
        let request = Request(expires: deadline)
        let frame: Data
        do {
            var encoded = try JSONSerialization.data(withJSONObject: [
                "id": request.id, "script": script, "arguments": arguments,
            ], options: [.sortedKeys])
            guard encoded.count <= RexStdioWorker.lineLimit else {
                throw RexConnectionError.requestFailed("Rex request exceeds the safe message size.")
            }
            encoded.append(0x0A)
            frame = encoded
        } catch let error as RexConnectionError { throw error }
        catch { throw RexConnectionError.requestFailed("Rex request arguments are not JSON: \(error.localizedDescription)") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if stopped {
                        continuation.resume(throwing: RexConnectionError.disconnected("Rex connection was shut down."))
                    } else if request.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if DispatchTime.now() >= deadline {
                        continuation.resume(throwing: RexConnectionError.disconnected("Rex request timed out before it could be sent."))
                    } else {
                        request.continuation = continuation
                        request.frame = frame
                        requests[request.id] = request
                        waiting.append(request.id)
                        let requestID = request.id
                        let timer = DispatchWorkItem { [weak self] in self?.timeoutRequest(requestID) }
                        request.deadline = timer
                        queue.asyncAfter(deadline: deadline, execute: timer)
                        sendNext()
                    }
                }
            }
        } onCancel: {
            request.cancel()
            self.queue.async { [weak self] in self?.cancelRequest(request.id) }
        }
    }

    func events() -> AsyncThrowingStream<RexStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1_024)) { continuation in
            let consumerID = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.eventConsumerID == consumerID else { return }
                    self.stopEvents(error: nil)
                }
            }
            queue.async { [self] in
                guard !stopped else {
                    continuation.finish(throwing: RexConnectionError.disconnected("Rex connection was shut down."))
                    return
                }
                guard eventConsumer == nil else {
                    continuation.finish(throwing: RexConnectionError.requestFailed("Rex events already have a consumer."))
                    return
                }
                eventConsumer = continuation
                eventConsumerID = consumerID
                eventReady = false
                do {
                    let worker = try makeWorker(events: true)
                    eventWorker = worker
                    try worker.start()
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self, self.eventConsumerID == consumerID, !self.eventReady else { return }
                        self.stopEvents(error: RexConnectionError.disconnected("Rex event subscription did not become ready."))
                    }
                    eventDeadline = timer
                    queue.asyncAfter(deadline: .now() + 8, execute: timer)
                } catch {
                    stopEvents(error: RexConnectionError.disconnected("Could not start Rex events: \(error.localizedDescription)"))
                }
            }
        }
    }

    func shutdown() {
        var workers: [RexStdioWorker] = []
        let stop = { [self] in
            guard !stopped else { return }
            stopped = true
            workers = [commandWorker, eventWorker].compactMap { $0 }
            resetCommands("Rex connection was shut down.")
            stopEvents(error: RexConnectionError.disconnected("Rex connection was shut down."))
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { stop() }
        else { queue.sync(execute: stop) }
        // The application may exit immediately after this call. A kill scheduled
        // on its dispatch queues would otherwise die with it and orphan a worker.
        for worker in workers { worker.waitForExit() }
    }

    private func makeWorker(events: Bool) throws -> RexStdioWorker {
        let workerID = UUID()
        var arguments = ["--autostart=false", "--timeout", "2s", "--color", "never"]
        if let server = host.server { arguments += ["-S", server] }
        arguments += ["do"]
        if events { arguments += ["--all", "--fail-fast"] }
        arguments += ["-e", events ? Self.eventScript : Self.commandScript]
        return try RexStdioWorker(id: workerID, executable: executable, arguments: arguments) { [weak self] line in
            guard let self else { return }
            // Backpressure happens at the pipe, not in an unbounded queue of event closures.
            self.queue.sync {
                if events { self.receiveEvent(line, workerID: workerID) }
                else { self.receiveReply(line, workerID: workerID) }
            }
        } onFailure: { [weak self] message in
            self?.queue.async { [weak self] in
                guard let self else { return }
                if events {
                    guard self.eventWorker?.id == workerID else { return }
                    self.stopEvents(error: RexConnectionError.disconnected(message))
                } else {
                    guard self.commandWorker?.id == workerID else { return }
                    self.resetCommands(message)
                }
            }
        }
    }

    private func sendNext() {
        guard active == nil, !stopped else { return }
        while waitingIndex < waiting.count {
            let id = waiting[waitingIndex]
            waitingIndex += 1
            guard let request = requests[id] else { continue }
            if request.isCancelled {
                finish(request, error: CancellationError())
                continue
            }
            if DispatchTime.now() >= request.expires {
                finish(request, error: RexConnectionError.disconnected("Rex request timed out before it could be sent."))
                continue
            }
            active = request
            do {
                if commandWorker == nil {
                    let worker = try makeWorker(events: false)
                    commandWorker = worker
                    try worker.start()
                }
                commandWorker?.write(request.frame)
            } catch {
                resetCommands("Could not start Rex: \(error.localizedDescription)")
            }
            break
        }
        if waitingIndex == waiting.count {
            waiting.removeAll(keepingCapacity: true)
            waitingIndex = 0
        }
    }

    private func cancelRequest(_ id: String) {
        guard let request = requests[id] else { return }
        if active === request {
            resetCommands("Rex request was canceled while in flight; its outcome is unknown.")
        } else {
            finish(request, error: CancellationError())
        }
    }

    private func timeoutRequest(_ id: String) {
        guard let request = requests[id] else { return }
        if active === request {
            resetCommands("Rex request timed out; its outcome is unknown.")
        } else {
            // An unsent request cannot have changed server state. Do not interrupt
            // an unrelated in-flight focus operation just because its queue is full.
            finish(request, error: RexConnectionError.disconnected("Rex request timed out before it could be sent."))
        }
    }

    private func receiveReply(_ line: Data, workerID: UUID) {
        guard commandWorker?.id == workerID else { return }
        do {
            guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = reply["id"] as? String,
                  let request = active, request.id == id,
                  let ok = reply["ok"] as? Bool else {
                resetCommands("Rex returned an invalid or uncorrelated response.")
                return
            }
            if request.isCancelled {
                resetCommands("Rex request was canceled while in flight; its outcome is unknown.")
                return
            }
            if !ok {
                guard let message = reply["error"] as? String else {
                    resetCommands("Rex returned an invalid request error.")
                    return
                }
                finish(request, error: RexConnectionError.requestFailed(message))
            } else {
                guard let json = reply["result_json"] as? String else {
                    resetCommands("Rex returned a response without a result.")
                    return
                }
                let result = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
                if let object = result as? [String: Any] { finish(request, result: object) }
                else if result is NSNull { finish(request, result: [:]) }
                else { finish(request, error: RexConnectionError.requestFailed("Rex returned an unexpected non-object result.")) }
            }
            sendNext()
        } catch {
            resetCommands("Rex returned invalid response JSON: \(error.localizedDescription)")
        }
    }

    private func receiveEvent(_ line: Data, workerID: UUID) {
        guard eventWorker?.id == workerID else { return }
        do {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  (type == "ready" || Self.eventNames.contains(type)) else {
                stopEvents(error: RexConnectionError.disconnected("Rex returned an invalid event."))
                return
            }
            if type == "ready" {
                guard !eventReady else {
                    stopEvents(error: RexConnectionError.disconnected("Rex sent a duplicate event-ready marker."))
                    return
                }
                eventReady = true
                eventDeadline?.cancel()
                eventDeadline = nil
            } else if !eventReady {
                stopEvents(error: RexConnectionError.disconnected("Rex sent an event before its subscription was ready."))
                return
            }
            let event = RexStreamEvent(type: type, sessionID: object["session_id"] as? String,
                                       blockID: object["block_id"] as? String, payload: payload)
            if let consumer = eventConsumer {
                switch consumer.yield(event) {
                case .enqueued: break
                case .dropped:
                    stopEvents(error: RexConnectionError.disconnected("Rex events exceeded the consumer buffer; inventory must be resynchronized."))
                case .terminated: stopEvents(error: nil)
                @unknown default:
                    stopEvents(error: RexConnectionError.disconnected("Rex event delivery failed."))
                }
            }
        } catch {
            stopEvents(error: RexConnectionError.disconnected("Rex returned invalid event JSON: \(error.localizedDescription)"))
        }
    }

    private func finish(_ request: Request, result: [String: Any]? = nil, error: Error? = nil) {
        guard requests.removeValue(forKey: request.id) != nil else { return }
        request.deadline?.cancel()
        request.deadline = nil
        if active === request { active = nil }
        let continuation = request.continuation
        request.continuation = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: result ?? [:]) }
    }

    private func resetCommands(_ message: String) {
        let worker = commandWorker
        commandWorker = nil
        worker?.stop()
        while let request = requests.values.first {
            finish(request, error: RexConnectionError.disconnected(message))
        }
        waiting.removeAll(keepingCapacity: true)
        waitingIndex = 0
    }

    private func stopEvents(error: Error?) {
        let worker = eventWorker
        let consumer = eventConsumer
        eventWorker = nil
        eventConsumer = nil
        eventConsumerID = nil
        eventReady = false
        eventDeadline?.cancel()
        eventDeadline = nil
        worker?.stop()
        consumer?.finish(throwing: error)
    }

    private final class Request: @unchecked Sendable {
        let id = UUID().uuidString
        let expires: DispatchTime
        var continuation: CheckedContinuation<[String: Any], Error>?
        var frame = Data()
        var deadline: DispatchWorkItem?
        private let lock = NSLock()
        private var cancelled = false
        init(expires: DispatchTime) { self.expires = expires }
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private static let eventNames: Set<String> = [
        "session_created", "session_destroyed", "session_moved", "session_view_changed", "session_label_changed",
        "window_created", "window_closed", "window_label_changed", "block_created", "block_closed", "hosts_changed",
        "terminal.title_changed", "terminal.pwd_changed", "terminal.process_changed", "terminal.child_exited",
    ]

    private static let commandScript = #"""
    local function encode(value)
      local ok, text, err = pcall(rex.json.encode, value)
      if not ok then return nil, tostring(text) end
      return text, err
    end
    local function emit(value)
      local text, err = encode(value)
      if not text then error(tostring(err), 0) end
      io.write(text, "\n")
      io.flush()
    end
    for line in io.lines() do
      local decoded, request, decode_error = pcall(rex.json.decode, line)
      if not decoded or type(request) ~= "table" or type(request.id) ~= "string"
          or type(request.script) ~= "string" or type(request.arguments) ~= "table" then
        emit({protocol_error = tostring(decode_error or request or "invalid request")})
        break
      end
      local chunk, compile_error = loadstring(request.script, "pane-switch-request")
      if not chunk then
        emit({id = request.id, ok = false, error = tostring(compile_error)})
      else
        local previous_args = rex.args
        rex.args = request.arguments
        local ok, result, rpc_error = pcall(chunk)
        rex.args = previous_args
        if not ok or (result == nil and rpc_error ~= nil) then
          emit({id = request.id, ok = false, error = tostring(ok and rpc_error or result)})
        else
          local json, encode_error
          if result == nil then json = "null" else json, encode_error = encode(result) end
          if not json then
            emit({id = request.id, ok = false, error = tostring(encode_error or "result cannot be encoded")})
          else
            emit({id = request.id, ok = true, result_json = json})
          end
        end
      end
    end
    """#

    private static let eventScript = #"""
    local function emit(value)
      local text, err = rex.json.encode(value)
      if not text then error(tostring(err), 0) end
      io.write(text, "\n")
      io.flush()
    end
    local function register(name)
      rex.on(name, function(ctx, ev)
        local payload = ev.payload or {}
        local created_session = type(payload.session) == "table" and payload.session.session_id or nil
        emit({type = name, session_id = ctx.session_id or ev.session_id or created_session,
              block_id = ctx.block_id or ev.block_id, payload = payload})
      end)
    end
    local names = {
      "session_created", "session_destroyed", "session_moved", "session_view_changed", "session_label_changed",
      "window_created", "window_closed", "window_label_changed", "block_created", "block_closed", "hosts_changed",
      "terminal.title_changed", "terminal.pwd_changed", "terminal.process_changed", "terminal.child_exited"
    }
    for _, name in ipairs(names) do register(name) end
    emit({type = "ready", payload = {}})
    """#
}

// A worker owns exactly one supported CLI process. Its stdin is private NDJSON;
// stdout is framed and bounded; stderr is always drained but only a prefix is kept.
private final class RexStdioWorker: @unchecked Sendable {
    static let lineLimit = 16 * 1_024 * 1_024
    let id: UUID
    private let lock = NSLock()
    private let exitGroup = DispatchGroup()
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let writes = DispatchQueue(label: "PaneSwitch.RexStdin")
    private let onLine: @Sendable (Data) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var started = false
    private var stopped = false
    private var errorOutput = Data()
    private var errorsTruncated = false

    init(id: UUID, executable: URL, arguments: [String],
         onLine: @escaping @Sendable (Data) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        self.id = id
        self.onLine = onLine
        self.onFailure = onFailure
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("REX_") }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let descriptor = stdin.fileHandleForWriting.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
              Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            throw RexConnectionError.disconnected("Could not configure the Rex request pipe.")
        }
    }

    deinit { stop() }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw RexConnectionError.disconnected("Rex worker was stopped before launch.") }
        try process.run()
        started = true
        exitGroup.enter()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        DispatchQueue.global(qos: .userInitiated).async { [self] in readOutput() }
        DispatchQueue.global(qos: .utility).async { [self] in readErrors() }
        DispatchQueue.global(qos: .utility).async { [self] in
            process.waitUntilExit()
            lock.lock()
            started = false
            lock.unlock()
            exitGroup.leave()
            // Normally stdout EOF reports the loss first. This also handles a
            // child that exits while a descendant accidentally retains stdout.
            fail("Rex exited with status \(process.terminationStatus).")
        }
    }

    func write(_ frame: Data) {
        writes.async { [self] in
            var offset = 0
            while offset < frame.count {
                lock.lock()
                guard started, !stopped else { lock.unlock(); return }
                let descriptor = stdin.fileHandleForWriting.fileDescriptor
                let written = frame.withUnsafeBytes { bytes in
                    Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
                }
                let failure = errno
                lock.unlock()
                if written > 0 { offset += written; continue }
                if written < 0, failure == EINTR { continue }
                if written < 0, failure == EAGAIN || failure == EWOULDBLOCK {
                    var descriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&descriptor, 1, 50)
                    continue
                }
                fail("Rex closed its request pipe.")
                return
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        // Lua can be blocked in io.lines(). EOF must precede termination, since
        // SIGTERM alone does not interrupt that Lua read in the supported CLI.
        try? stdin.fileHandleForWriting.close()
        if !started {
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        let running = started && process.isRunning
        if running { Darwin.kill(process.processIdentifier, SIGTERM) }
        lock.unlock()
        if running {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [self] in
                lock.lock()
                if started && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                lock.unlock()
            }
        }
    }

    func waitForExit() {
        guard exitGroup.wait(timeout: .now() + 0.25) == .timedOut else { return }
        lock.lock()
        if started && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        lock.unlock()
        _ = exitGroup.wait(timeout: .now() + 0.25)
    }

    private func readOutput() {
        let handle = stdout.fileHandleForReading
        defer { try? handle.close() }
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        do {
            while true {
                let count = try readChunk(handle.fileDescriptor, into: &bytes)
                guard count > 0 else { break }
                var scan = buffer.endIndex
                buffer.append(contentsOf: bytes.prefix(count))
                var lineStart = buffer.startIndex
                while let end = buffer[scan...].firstIndex(of: 0x0A) {
                    guard end - lineStart <= Self.lineLimit else {
                        fail("Rex returned a message larger than the safe read limit.")
                        return
                    }
                    onLine(Data(buffer[lineStart..<end]))
                    lineStart = end + 1
                    scan = lineStart
                }
                if lineStart != buffer.startIndex { buffer.removeSubrange(..<lineStart) }
                guard buffer.count <= Self.lineLimit else {
                    fail("Rex returned a message larger than the safe read limit.")
                    return
                }
            }
            fail(buffer.isEmpty ? "Rex closed its output stream." : "Rex closed its output in the middle of a message.")
        } catch {
            fail("Could not read Rex output: \(error.localizedDescription)")
        }
    }

    private func readErrors() {
        let handle = stderr.fileHandleForReading
        defer { try? handle.close() }
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
        do {
            while true {
                let count = try readChunk(handle.fileDescriptor, into: &bytes)
                guard count > 0 else { break }
                lock.lock()
                let remaining = 64 * 1_024 - errorOutput.count
                errorOutput.append(contentsOf: bytes.prefix(min(remaining, count)))
                if count > remaining { errorsTruncated = true }
                lock.unlock()
            }
        } catch {
            fail("Could not read Rex diagnostics: \(error.localizedDescription)")
        }
    }

    // FileHandle.read(upToCount:) waits for the requested count or EOF on macOS.
    // A persistent worker instead needs each flushed pipe write as it arrives.
    private func readChunk(_ descriptor: Int32, into bytes: inout [UInt8]) throws -> Int {
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count >= 0 { return count }
            let code = errno
            if code == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func fail(_ message: String) {
        lock.lock()
        let ignore = stopped
        let diagnostics = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = errorsTruncated ? " (diagnostics truncated)" : ""
        lock.unlock()
        if !ignore { onFailure(diagnostics.isEmpty ? message : "\(message) \(diagnostics)\(suffix)") }
    }
}
