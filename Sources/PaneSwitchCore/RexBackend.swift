import Foundation
import Darwin

protocol RexInventoryConnection: AnyObject, Sendable {
    func execute(_ script: String, arguments: [String: Any], timeout: TimeInterval) async throws -> [String: Any]
    func events() -> AsyncThrowingStream<RexStreamEvent, Error>
    func shutdown()
}

extension RexConnection: RexInventoryConnection {}

struct RexHostInventory: Sendable {
    let hosts: [RexHost]
    let warnings: [String]
}

public final class RexBackend: @unchecked Sendable {
    private let lifetime: RexBackendLifetime
    private let inventory: RexInventory

    public convenience init(executable: URL) {
        self.init(connectionFactory: { RexConnection(executable: executable, host: $0) },
                  hostLookup: { try await Self.hostInventory(executable: executable) })
    }

    // The same connection/cache seam is exercised by event-driven discovery tests.
    init(connectionFactory: @escaping @Sendable (RexHost) -> any RexInventoryConnection,
         hostLookup: @escaping @Sendable () async throws -> RexHostInventory,
         reconnectDelay: @escaping @Sendable (Int) -> UInt64 = { attempt in
             UInt64(min(8.0, 0.25 * pow(2.0, Double(min(attempt, 5)))) * 1_000_000_000)
         },
         switchClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        let lifetime = RexBackendLifetime()
        self.lifetime = lifetime
        inventory = RexInventory(lifetime: lifetime, connectionFactory: connectionFactory,
                                 hostLookup: hostLookup, reconnectDelay: reconnectDelay, switchClock: switchClock)
    }

    public func start() {
        let inventory = inventory
        lifetime.launch { await inventory.start() }
    }

    public func shutdown() {
        // Close every worker and cancel host lookup/reconnect work before returning. Actor cleanup
        // alone is insufficient when AppKit is about to terminate the application's event loop.
        lifetime.shutdown()
        let inventory = inventory
        Task { await inventory.shutdown() }
    }

    deinit { shutdown() }

    public func discover() -> AsyncStream<DiscoveryEvent> {
        let inventory = inventory
        let lifetime = lifetime
        return AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                lifetime.cancel(id)
                Task { await inventory.unsubscribe(id) }
            }
            let task = Task { await inventory.subscribe(id, continuation: continuation) }
            if !lifetime.track(id: id, cancel: { task.cancel(); continuation.finish() }) { continuation.finish() }
        }
    }

    public func appClients() async throws -> [RexClient] {
        try await inventory.appClients()
    }

    public func switchTo(_ pane: Pane, clientID: String) async throws {
        let measurement = await inventory.switchTo(pane, clientID: clientID, measured: false)
        try measurement.result.get()
    }

    /// Includes completed and failed RPC waits without changing the underlying switch error.
    public func measuredSwitchTo(_ pane: Pane, clientID: String) async -> RexSwitchMeasurement {
        await inventory.switchTo(pane, clientID: clientID, measured: true)
    }

    static func parseHosts(_ object: [String: Any]) throws -> RexHostInventory {
        var hosts: [RexHost] = []
        var endpoints = Set<String>()
        for value in try rexArray(object["hosts"], field: "hosts") {
            guard let entry = value as? [String: Any], let host = entry["host"] as? [String: Any],
                  let id = rexNonempty(host["id"]), let label = rexNonempty(host["label"]) else {
                throw RexBackendError("Rex returned an invalid host entry.")
            }
            if hosts.contains(where: { $0.id == id }) { continue }
            hosts.append(RexHost(id: id, label: label, server: label, icon: rexNonempty(host["icon"])))
            for endpoint in (host["endpoints"] as? [String]) ?? [] { endpoints.insert(endpoint) }
        }
        if let home = object["home"] as? [String: Any], home["this_machine"] as? Bool == false,
           let endpoint = rexNonempty(home["endpoint"]), !endpoints.contains(endpoint) {
            hosts.insert(RexHost(id: "home:" + endpoint, label: rexNonempty(home["label"]) ?? "Home", server: endpoint), at: 0)
        }
        let warnings = try rexArray(object["warnings"], field: "warnings", absentIsEmpty: true).map { value in
            if let text = value as? String { return text }
            if let value = value as? [String: Any], let text = value["message"] as? String { return text }
            return String(describing: value)
        }
        return RexHostInventory(hosts: hosts, warnings: warnings)
    }

    private static func hostInventory(executable: URL) async throws -> RexHostInventory {
        let invocation = CLIInvocation(executable: executable, arguments: [
            "--autostart=false", "--timeout", "2s", "--color", "never", "hosts", "--json"
        ])
        let data = try await withTaskCancellationHandler {
            let data = try await invocation.run(timeout: 8)
            try Task.checkCancellation()
            return data
        } onCancel: { invocation.cancel() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RexBackendError("Rex returned an unexpected host inventory.")
        }
        return try parseHosts(object)
    }
}

// This registry is deliberately synchronous: it is also the start-after-shutdown gate, and owns
// cancellation independently of actor scheduling or the lifetime of a discovery observer.
private final class RexBackendLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    @discardableResult
    func track(id: UUID, cancel: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if stopped { lock.unlock(); cancel(); return false }
        cancellations[id] = cancel
        lock.unlock()
        return true
    }

    func remove(_ id: UUID) {
        lock.lock(); cancellations.removeValue(forKey: id); lock.unlock()
    }

    func cancel(_ id: UUID) {
        lock.lock()
        let action = cancellations.removeValue(forKey: id)
        lock.unlock()
        action?()
    }

    func launch(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        let task = Task { await operation(); self.remove(id) }
        _ = track(id: id, cancel: { task.cancel() })
    }

    func shutdown() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let actions = Array(cancellations.values)
        cancellations.removeAll()
        lock.unlock()
        for action in actions { action() }
    }
}

private actor RexInventory {
    private let local = RexHost(id: "local", label: "This Mac", server: nil)
    private let lifetime: RexBackendLifetime
    private let connectionFactory: @Sendable (RexHost) -> any RexInventoryConnection
    private let hostLookup: @Sendable () async throws -> RexHostInventory
    private let reconnectDelay: @Sendable (Int) -> UInt64
    private let switchClock: @Sendable () -> ContinuousClock.Instant
    private var started = false
    private var hosts: [RexHost] = []
    private var states: [String: HostState] = [:]
    private var observers: [UUID: AsyncStream<DiscoveryEvent>.Continuation] = [:]
    private var hostLookupRunning = false
    private var hostLookupAgain = false
    private var hostLookupSettled = false
    private var settled = false
    private var warnings: [String] = []

    init(lifetime: RexBackendLifetime,
         connectionFactory: @escaping @Sendable (RexHost) -> any RexInventoryConnection,
         hostLookup: @escaping @Sendable () async throws -> RexHostInventory,
         reconnectDelay: @escaping @Sendable (Int) -> UInt64,
         switchClock: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.lifetime = lifetime
        self.connectionFactory = connectionFactory
        self.hostLookup = hostLookup
        self.reconnectDelay = reconnectDelay
        self.switchClock = switchClock
    }

    func start() {
        guard !started, !lifetime.isStopped else { return }
        started = true
        hosts = [local]
        states[local.id] = HostState(host: local)
        broadcast(.hosts(hosts))
        connect(local.id)
        requestHosts()
    }

    func subscribe(_ id: UUID, continuation: AsyncStream<DiscoveryEvent>.Continuation) {
        guard !lifetime.isStopped, !Task.isCancelled else {
            lifetime.remove(id)
            continuation.finish()
            return
        }
        start()
        observers[id] = continuation
        continuation.yield(.hosts(hosts))
        for host in hosts {
            guard let state = states[host.id] else { continue }
            if let failure = state.failure { continuation.yield(.failed(host, failure)) }
            else if state.hasSnapshot { continuation.yield(.panes(host, state.cache.panes)) }
        }
        for warning in warnings { continuation.yield(.warning(warning)) }
        if settled { continuation.yield(.finished) }
    }

    func unsubscribe(_ id: UUID) {
        observers.removeValue(forKey: id)
        lifetime.remove(id)
    }

    func shutdown() {
        for state in states.values { state.cancelTasks(); state.connection?.shutdown() }
        states.removeAll()
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    func appClients() async throws -> [RexClient] {
        start()
        let object = try await execute(local.id, script: RexSetupProbe.clientsScript)
        return try RexSetupProbe.parseClients(object)
    }

    func switchTo(_ pane: Pane, clientID: String, measured: Bool) async -> RexSwitchMeasurement {
        var timings = RexSwitchTimings()
        do {
            try await performSwitch(pane, clientID: clientID, measured: measured, timings: &timings)
            return RexSwitchMeasurement(result: .success(()), timings: timings)
        } catch {
            return RexSwitchMeasurement(result: .failure(error), timings: timings)
        }
    }

    private func performSwitch(_ pane: Pane, clientID: String, measured: Bool,
                               timings: inout RexSwitchTimings) async throws {
        start()
        guard let state = states[pane.host.id], state.ready, state.failure == nil, state.cache.contains(pane) else {
            throw RexBackendError("This pane is no longer available. Choose it again after the inventory refreshes.")
        }
        let request: [String: Any] = [
            "client_id": clientID, "action": "session.select", "block_id": pane.blockID, "origin": "api",
            // Remote session/window IDs belong only in args; block_id is the action context.
            "args": ["session_id": pane.sessionID, "window_id": pane.windowID]
        ]
        var arguments: [String: Any] = ["session_id": pane.sessionID, "window_id": pane.windowID, "block_id": pane.blockID]
        do {
            if state.host.server == nil {
                arguments["client"] = request
                try await switchRPC(state.host.id, script: Self.switchScript, arguments: arguments,
                                    measured: measured, timings: &timings)
            } else {
                // First display can restore Rex's default remote pane responder.
                // Validate before revealing, then focus the mounted layout and recheck it.
                arguments["phase"] = "validate"
                try await switchRPC(state.host.id, script: Self.switchScript, arguments: arguments,
                                    measured: measured, timings: &timings)
                try await switchRPC(local.id, script: Self.clientPerformScript, arguments: request,
                                    measured: measured, timings: &timings)
                arguments["phase"] = "focus"
                try await switchRPC(state.host.id, script: Self.switchScript, arguments: arguments,
                                    measured: measured, timings: &timings)
                try await switchRPC(local.id, script: Self.clientPerformScript, arguments: request,
                                    measured: measured, timings: &timings)
            }
        } catch {
            // A logical failure invalidates just this session. A disconnected execute has already
            // cleared the whole failed host; neither kind of failure blindly repeats a mutation.
            if let current = states[pane.host.id], current.connection != nil {
                current.cache.invalidate(sessionID: pane.sessionID)
                current.dirty.insert(pane.sessionID)
                scheduleRefresh(current)
            }
            throw error
        }
    }

    private func switchRPC(_ hostID: String, script: String, arguments: [String: Any],
                           measured: Bool, timings: inout RexSwitchTimings) async throws {
        guard measured else {
            _ = try await execute(hostID, script: script, arguments: arguments)
            return
        }
        let started = switchClock()
        defer { timings.record(started.duration(to: switchClock()), remote: hostID != local.id) }
        _ = try await execute(hostID, script: script, arguments: arguments)
    }

    private func connect(_ hostID: String) {
        guard !lifetime.isStopped, let state = states[hostID], state.connection == nil else { return }
        let connection = connectionFactory(state.host)
        let epoch = UUID()
        guard lifetime.track(id: epoch, cancel: { connection.shutdown() }) else { return }
        state.epoch = epoch
        state.connection = connection
        state.ready = false
        let stream = connection.events()
        let task = Task { [weak self] in
            do {
                for try await event in stream {
                    try Task.checkCancellation()
                    await self?.receive(event, hostID: hostID, epoch: epoch)
                }
                if !Task.isCancelled { await self?.failed(hostID, epoch: epoch, message: "Rex event connection closed.") }
            } catch {
                if !Task.isCancelled { await self?.failed(hostID, epoch: epoch, message: error.localizedDescription) }
            }
        }
        state.eventTask = task
        track(task, id: state.eventTaskID)
    }

    private func receive(_ event: RexStreamEvent, hostID: String, epoch: UUID) {
        guard !lifetime.isStopped, let state = states[hostID], state.epoch == epoch, state.connection != nil else { return }
        if event.type == "ready" {
            guard !state.ready else { return }
            state.ready = true
            // Event streams do not replay configuration changes missed while disconnected.
            if state.failure != nil { requestHosts() }
            state.refreshTask = Task { [weak self] in await self?.bootstrap(hostID, epoch: epoch) }
            if let task = state.refreshTask { track(task, id: state.refreshTaskID) }
            return
        }
        if event.type == "hosts_changed" {
            requestHosts()
            return
        }
        if event.type.hasPrefix("terminal.") {
            if state.cache.applyTerminalEvent(event) { publish(state) }
            return
        }
        let session = event.sessionID ?? rexNonempty(event.payload["session_id"])
            ?? (event.payload["session"] as? [String: Any]).flatMap { rexNonempty($0["session_id"]) }
        guard let session else {
            // session_moved has no documented payload. Reconcile the listing if its scope is absent.
            state.needsListing = true
            scheduleRefresh(state)
            return
        }
        state.cache.invalidate(sessionID: session)
        switch event.type {
        case "session_destroyed":
            state.cache.removeSession(session)
            state.dirty.remove(session)
            publish(state)
            return
        case "block_closed":
            if let block = event.blockID ?? rexNonempty(event.payload["block_id"]) {
                state.cache.removeBlock(block, sessionID: session)
                publish(state)
            }
        case "window_closed":
            if let window = rexNonempty(event.payload["window_id"]) {
                state.cache.removeWindow(window, sessionID: session)
                publish(state)
            }
        case "session_label_changed":
            state.cache.renameSession(session, label: event.payload["label"] as? String ?? "")
            publish(state)
        case "window_label_changed":
            if let window = rexNonempty(event.payload["window_id"]) {
                state.cache.renameWindow(window, sessionID: session, label: event.payload["label"] as? String ?? "")
                publish(state)
            }
        default: break
        }
        state.dirty.insert(session)
        scheduleRefresh(state)
    }

    private func bootstrap(_ hostID: String, epoch: UUID) async {
        guard let state = current(hostID, epoch), state.ready else { return }
        do {
            state.needsListing = true
            state.hasSnapshot = true
            try await refresh(state, epoch: epoch)
            guard current(hostID, epoch) != nil else { return }
            // Reconcile startup invalidations before publishing settled status. Continued events
            // remain queued for the normal coalesced refresh rather than starving startup forever.
            if !state.dirty.isEmpty || state.needsListing {
                try await refresh(state, epoch: epoch)
                guard current(hostID, epoch) != nil else { return }
            }
            // Placement is usable before optional metadata finishes; every switch still validates
            // the target on the server. Slow metadata must not disable already valid panes.
            state.bootstrapped = true
            state.failure = nil
            publish(state)
            await enrich(state, epoch: epoch)
            guard current(hostID, epoch) != nil, !Task.isCancelled else { return }
            state.initialSettled = state.dirty.isEmpty && !state.needsListing
            state.retryAttempt = 0
            state.refreshTask = nil
            lifetime.remove(state.refreshTaskID)
            publish(state)
            finishIfSettled()
            scheduleRefresh(state)
        } catch {
            if current(hostID, epoch) != nil, !Task.isCancelled {
                failed(hostID, epoch: epoch, message: error.localizedDescription)
            }
        }
    }

    private func scheduleRefresh(_ state: HostState) {
        guard state.bootstrapped, state.ready, state.connection != nil, state.refreshTask == nil,
              !state.dirty.isEmpty || state.needsListing, !lifetime.isStopped else { return }
        let hostID = state.host.id
        let epoch = state.epoch
        let task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            await self?.drainRefreshes(hostID, epoch: epoch)
        }
        state.refreshTask = task
        track(task, id: state.refreshTaskID)
    }

    private func drainRefreshes(_ hostID: String, epoch: UUID) async {
        guard let state = current(hostID, epoch) else { return }
        do {
            try await refresh(state, epoch: epoch)
            guard current(hostID, epoch) != nil else { return }
            await enrich(state, epoch: epoch)
        } catch {
            guard current(hostID, epoch) != nil, !Task.isCancelled else { return }
            warn("\(state.host.label): could not refresh panes (\(error.localizedDescription)).")
        }
        guard current(hostID, epoch) != nil else { return }
        state.refreshTask = nil
        lifetime.remove(state.refreshTaskID)
        if state.dirty.isEmpty && !state.needsListing {
            state.initialSettled = true
            finishIfSettled()
        }
        scheduleRefresh(state)
    }

    private func refresh(_ state: HostState, epoch: UUID) async throws {
        if state.needsListing {
            state.needsListing = false
            let version = state.cache.version
            let listing = try await execute(state.host.id, script: Self.listingScript)
            guard current(state.host.id, epoch) != nil else { return }
            var listed = Set<String>()
            for value in try rexArray(listing["sessions"], field: "sessions") {
                guard let session = value as? [String: Any], let id = rexNonempty(session["session_id"]) else {
                    throw RexBackendError("Rex returned a session without an ID.")
                }
                listed.insert(id)
            }
            for id in state.cache.sessionIDs.subtracting(listed) where !state.cache.changed(id, since: version) {
                state.cache.removeSession(id)
            }
            state.dirty.formUnion(listed)
        }
        let sessions = Array(state.dirty).sorted()
        state.dirty.removeAll()
        for session in sessions {
            try Task.checkCancellation()
            let version = state.cache.version
            // One session per request leaves room for interactive client/switch requests in the
            // persistent worker queue, even when a host contains a very large inventory.
            let snapshot = try await execute(state.host.id, script: Self.viewsScript,
                                             arguments: ["sessions": [session]])
            guard current(state.host.id, epoch) != nil else { return }
            try apply(snapshot, to: state, since: version)
            publish(state)
        }
        publish(state)
    }

    private func apply(_ snapshot: [String: Any], to state: HostState, since version: UInt64) throws {
        for value in try rexArray(snapshot["views"], field: "views") {
            guard let view = value as? [String: Any], let id = rexNonempty(view["session_id"]) else {
                throw RexBackendError("Rex returned an invalid session view.")
            }
            if try !state.cache.replace(view: view, since: version) { state.dirty.insert(id) }
        }
        for value in try rexArray(snapshot["errors"], field: "errors") {
            guard let error = value as? [String: Any], let id = rexNonempty(error["session_id"]) else {
                throw RexBackendError("Rex returned an invalid session inspection error.")
            }
            if state.cache.changed(id, since: version) { state.dirty.insert(id) }
            else { state.cache.removeSession(id) }
            warn("\(state.host.label): \(rexNonempty(error["message"]) ?? "A session is unavailable.")")
        }
    }

    private func enrich(_ state: HostState, epoch: UUID) async {
        let panes = state.cache.takeMetadataRequests()
        var changedSincePublish = false
        // One pane bounds the batch even when every block.method hits the CLI's 2s network
        // deadline. Foreground operations can interleave between these requests.
        for (offset, pane) in panes.enumerated() {
            guard current(state.host.id, epoch) != nil, !Task.isCancelled else { return }
            guard state.cache.contains(pane) else { continue }
            let version = state.cache.version
            do {
                let result = try await execute(state.host.id, script: Self.metadataScript, arguments: [
                    "panes": [["session_id": pane.sessionID, "block_id": pane.blockID]]
                ], timeout: 10)
                guard current(state.host.id, epoch) != nil else { return }
                state.cache.applyMetadata(try rexArray(result["items"], field: "items"), since: version)
                changedSincePublish = true
                if offset % 8 == 7 || offset == panes.count - 1 {
                    publish(state)
                    changedSincePublish = false
                }
                if (result["unavailable"] as? NSNumber)?.intValue ?? 0 > 0 {
                    warn("\(state.host.label): some pane metadata is unavailable; placed panes are still listed.")
                }
            } catch {
                guard current(state.host.id, epoch) != nil, !Task.isCancelled else { return }
                warn("\(state.host.label): pane metadata is unavailable (\(error.localizedDescription)). Placed panes are still listed.")
            }
        }
        if changedSincePublish { publish(state) }
    }

    private func execute(_ hostID: String, script: String, arguments: [String: Any] = [:],
                         timeout: TimeInterval = 8) async throws -> [String: Any] {
        guard !lifetime.isStopped, let state = states[hostID], let connection = state.connection else {
            throw RexConnectionError.disconnected("Rex is reconnecting. Try again when its inventory is available.")
        }
        let epoch = state.epoch
        do {
            let result = try await connection.execute(script, arguments: arguments, timeout: timeout)
            guard current(hostID, epoch) != nil, !lifetime.isStopped else {
                throw RexConnectionError.disconnected("The Rex connection changed during the request.")
            }
            return result
        } catch {
            if case RexConnectionError.disconnected(let message) = error {
                failed(hostID, epoch: epoch, message: message)
            }
            throw error
        }
    }

    private func failed(_ hostID: String, epoch: UUID, message: String) {
        guard !lifetime.isStopped, let state = current(hostID, epoch) else { return }
        state.cancelTasks()
        state.connection?.shutdown()
        state.connection = nil
        lifetime.remove(epoch)
        lifetime.remove(state.eventTaskID)
        lifetime.remove(state.refreshTaskID)
        state.cache = RexPaneInventory(host: state.host)
        state.hasSnapshot = false
        state.bootstrapped = false
        state.ready = false
        state.dirty.removeAll()
        state.needsListing = false
        state.failure = message
        state.initialSettled = true
        broadcast(.panes(state.host, []))
        broadcast(.failed(state.host, message))
        finishIfSettled()
        let delay = reconnectDelay(state.retryAttempt)
        state.retryAttempt += 1
        state.retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.reconnect(hostID, epoch: epoch)
        }
        if let task = state.retryTask { track(task, id: state.retryTaskID) }
    }

    private func reconnect(_ hostID: String, epoch: UUID) {
        guard !lifetime.isStopped, let state = states[hostID], state.epoch == epoch, state.connection == nil else { return }
        lifetime.remove(state.retryTaskID)
        state.retryTask = nil
        connect(hostID)
    }

    private func requestHosts() {
        guard !lifetime.isStopped else { return }
        if hostLookupRunning { hostLookupAgain = true; return }
        hostLookupRunning = true
        lifetime.launch { [weak self] in await self?.loadHosts() }
    }

    private func loadHosts() async {
        repeat {
            hostLookupAgain = false
            do {
                let result = try await hostLookup()
                guard !lifetime.isStopped, !Task.isCancelled else { return }
                reconcileHosts(result.hosts)
                for warning in result.warnings { warn(warning) }
            } catch {
                guard !lifetime.isStopped, !Task.isCancelled else { return }
                warn("Could not list remote hosts: \(error.localizedDescription)")
            }
            hostLookupSettled = true
            finishIfSettled()
        } while hostLookupAgain
        hostLookupRunning = false
    }

    private func reconcileHosts(_ remotes: [RexHost]) {
        let values = [local] + remotes.filter { $0.id != local.id }
        let ids = Set(values.map(\.id))
        for id in Array(states.keys) where !ids.contains(id) {
            if let state = states.removeValue(forKey: id) { stop(state) }
        }
        var added: [String] = []
        for host in values {
            if let old = states[host.id], old.host == host { continue }
            if let old = states.removeValue(forKey: host.id) {
                stop(old)
                broadcast(.panes(host, []))
            }
            states[host.id] = HostState(host: host)
            added.append(host.id)
        }
        hosts = values
        if !added.isEmpty { settled = false }
        broadcast(.hosts(hosts))
        for id in added { connect(id) }
    }

    private func stop(_ state: HostState) {
        state.cancelTasks()
        state.connection?.shutdown()
        for id in [state.epoch, state.eventTaskID, state.refreshTaskID, state.retryTaskID] { lifetime.remove(id) }
    }

    private func current(_ hostID: String, _ epoch: UUID) -> HostState? {
        guard let state = states[hostID], state.epoch == epoch, state.connection != nil else { return nil }
        return state
    }

    private func track(_ task: Task<Void, Never>, id: UUID) {
        _ = lifetime.track(id: id, cancel: { task.cancel() })
    }

    private func publish(_ state: HostState) {
        guard state.hasSnapshot, state.failure == nil, !observers.isEmpty else { return }
        broadcast(.panes(state.host, state.cache.panes))
    }

    private func warn(_ message: String) {
        guard !warnings.contains(message) else { return }
        warnings.append(message)
        if warnings.count > 16 { warnings.removeFirst() }
        broadcast(.warning(message))
    }

    private func finishIfSettled() {
        guard !settled, hostLookupSettled, states.values.allSatisfy(\.initialSettled) else { return }
        settled = true
        broadcast(.finished)
    }

    private func broadcast(_ event: DiscoveryEvent) {
        for continuation in observers.values { continuation.yield(event) }
    }

    private final class HostState {
        let host: RexHost
        var cache: RexPaneInventory
        var connection: (any RexInventoryConnection)?
        var epoch = UUID()
        let eventTaskID = UUID()
        let refreshTaskID = UUID()
        let retryTaskID = UUID()
        var eventTask: Task<Void, Never>?
        var refreshTask: Task<Void, Never>?
        var retryTask: Task<Void, Never>?
        var dirty = Set<String>()
        var needsListing = false
        var ready = false
        var hasSnapshot = false
        var bootstrapped = false
        var initialSettled = false
        var failure: String?
        var retryAttempt = 0

        init(host: RexHost) { self.host = host; cache = RexPaneInventory(host: host) }
        func cancelTasks() {
            eventTask?.cancel(); eventTask = nil
            refreshTask?.cancel(); refreshTask = nil
            retryTask?.cancel(); retryTask = nil
        }
    }

    private static let clientPerformScript = #"""
    local result, err = rex.call("client.perform", rex.args)
    if not result then error(err or "Could not reveal the selected pane", 0) end
    return result
    """#

    private static let switchScript = #"""
    local a = rex.args
    local function call(method, args)
        local result, err = rex.call(method, args)
        if not result then error(err or ("Could not call " .. method), 0) end
        return result
    end
    local function contains(layout)
        if not layout then return false end
        if layout.block_id == a.block_id then return true end
        local split = layout.split
        return split and (contains(split.before) or contains(split.after)) or false
    end
    local function targetWindow(view)
        if not view or view.session_id ~= a.session_id then return nil end
        for _, window in ipairs(view.windows or {}) do
            if window.window_id == a.window_id then
                for _, layer in ipairs(window.layers or {}) do
                    if contains(layer.layout) then
                        for _, block in ipairs(layer.blocks or {}) do
                            if block.block_id == a.block_id then return window end
                        end
                    end
                end
            end
        end
        return nil
    end
    if a.phase ~= "focus" then
        local attached = call("session.attach", {session_id = a.session_id})
        if not targetWindow(attached.view) then
            error("This pane is no longer in the selected tab. Refresh the picker and choose it again.", 0)
        end
        if a.phase == "validate" then return {} end
    end
    call("session.focus_block", {session_id = a.session_id, block_id = a.block_id})
    local after = call("session.view", {session_id = a.session_id})
    local window = targetWindow(after)
    if not window or after.active_window_id ~= a.window_id or window.focused_block_id ~= a.block_id then
        error("The pane moved or became unavailable while switching. Refresh and try again.", 0)
    end
    if a.client then return call("client.perform", a.client) end
    return {}
    """#

    private static let listingScript = #"""
    local listing, err = rex.call("session.list")
    if not listing then error(err or "Could not list sessions", 0) end
    return listing
    """#

    private static let viewsScript = #"""
    local views, errors = {}, {}
    for _, id in ipairs(rex.args.sessions or {}) do
        local attached, problem = rex.call("session.attach", {session_id = id})
        if attached and attached.view then views[#views + 1] = attached.view
        else errors[#errors + 1] = {session_id = id, message = problem or "Could not inspect session"} end
    end
    return {views = views, errors = errors}
    """#

    private static let metadataScript = #"""
    local items, unavailable, attached = {}, 0, {}
    for _, pane in ipairs(rex.args.panes or {}) do
        if attached[pane.session_id] == nil then
            local result = rex.call("session.attach", {session_id = pane.session_id})
            attached[pane.session_id] = result ~= nil
        end
        local item = {block_id = pane.block_id}
        for _, method in ipairs({"title", "pwd", "process"}) do
            local value = rex.call("block.method", {session_id = pane.session_id, block_id = pane.block_id, method = method})
            if value then item[method] = value else unavailable = unavailable + 1 end
        end
        items[#items + 1] = item
    end
    return {items = items, unavailable = unavailable}
    """#
}

// Only the rare configured-host lookup remains a one-shot CLI invocation. Both output streams
// are drained off the main actor and capture is bounded even if the helper is noisy.
private final class CLIInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let stdin = Pipe()
    private var stopped: Error?
    private var started = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("REX_") }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
    }

    func run(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    lock.lock()
                    if let stopped { lock.unlock(); throw stopped }
                    do { try process.run(); started = true; lock.unlock() }
                    catch { lock.unlock(); throw error }
                    try? stdin.fileHandleForWriting.close()
                    try? stdin.fileHandleForReading.close()
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    let deadline = DispatchWorkItem { [self] in stop(RexBackendError("Rex did not respond within \(Int(timeout)) seconds.")) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    let output = PipeCapture(stdout.fileHandleForReading)
                    let errors = PipeCapture(stderr.fileHandleForReading)
                    let group = DispatchGroup()
                    for capture in [output, errors] {
                        group.enter()
                        DispatchQueue.global(qos: .userInitiated).async { capture.drain(); group.leave() }
                    }
                    process.waitUntilExit()
                    group.wait()
                    deadline.cancel()
                    lock.lock()
                    let failure = stopped
                    started = false
                    lock.unlock()
                    if let failure { throw failure }
                    guard process.terminationReason == .exit && process.terminationStatus == 0 else {
                        let text = String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw RexBackendError(text.isEmpty ? "Rex exited with status \(process.terminationStatus)." : text)
                    }
                    guard !output.truncated else { throw RexBackendError("Rex returned more data than the picker can safely read.") }
                    continuation.resume(returning: output.data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cancel() { stop(CancellationError()) }

    private func stop(_ error: Error) {
        lock.lock()
        guard stopped == nil else { lock.unlock(); return }
        stopped = error
        let shouldKill = started && process.isRunning
        try? stdin.fileHandleForWriting.close()
        if shouldKill { Darwin.kill(process.processIdentifier, SIGTERM) }
        lock.unlock()
        if shouldKill {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                lock.lock()
                if started && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                lock.unlock()
            }
        }
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var data = Data()
    private(set) var truncated = false
    init(_ handle: FileHandle) { self.handle = handle }
    func drain() {
        let limit = 16 * 1_024 * 1_024
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            let remaining = limit - data.count
            data.append(chunk.prefix(remaining))
            if chunk.count > remaining { truncated = true }
        }
        try? handle.close()
    }
}
