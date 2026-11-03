import Foundation
import Testing
@testable import PaneSwitchCore

struct DiscoveryTests {
    @Test(arguments: [false, true])
    func refreshRetriesFailedAndUnprocessedSessionsWithoutLosingNewEvents(malformed: Bool) async throws {
        let connection = FixtureConnection(views: [
            view("session:a", blocks: ["block:a"]),
            view("session:b", blocks: ["block:b"]),
            view("session:c", blocks: ["block:c"])
        ])
        let backend = RexBackend(connectionFactory: { _ in connection },
                                 hostLookup: { RexHostInventory(hosts: [], warnings: []) })
        defer { backend.shutdown() }
        _ = await settledSnapshot(backend)
        connection.setViews([
            view("session:a", label: "First update", blocks: ["block:a"]),
            view("session:b", label: "Updated", blocks: ["block:b"]),
            view("session:c", label: "Updated", blocks: ["block:c"])
        ])
        connection.failNextView("session:b", malformed: malformed)
        let gate = connection.holdNextView()
        connection.emit("session_moved")
        try await waitUntil { await gate.hasArrived }
        connection.setViews([
            view("session:a", label: "Newest", blocks: ["block:a-new"]),
            view("session:b", label: "Updated", blocks: ["block:b"]),
            view("session:c", label: "Updated", blocks: ["block:c"])
        ])
        connection.emit("session_label_changed", session: "session:a", payload: ["label": "Newest"])
        _ = try await eventuallySnapshot(backend) {
            $0.panes["local"]?.first(where: { $0.sessionID == "session:a" })?.sessionLabel == "Newest"
        }
        await gate.release()
        let snapshot = try await eventuallySnapshot(backend) {
            let labels = Dictionary(uniqueKeysWithValues: ($0.panes["local"] ?? []).map { ($0.sessionID, $0.sessionLabel) })
            return labels == ["session:a": "Newest", "session:b": "Updated", "session:c": "Updated"]
                && $0.panes["local"]?.contains(where: { $0.blockID == "block:a-new" }) == true
        }
        #expect(snapshot.failures.isEmpty)
        #expect(connection.shutdownCount == 0)
    }

    @Test(arguments: [false, true])
    func refreshRetriesListingFailureWithoutAnotherEvent(malformed: Bool) async throws {
        let connection = FixtureConnection(views: [view("session:old", blocks: ["block:old"])])
        let backend = RexBackend(connectionFactory: { _ in connection },
                                 hostLookup: { RexHostInventory(hosts: [], warnings: []) })
        defer { backend.shutdown() }
        _ = await settledSnapshot(backend)
        connection.setViews([view("session:new", blocks: ["block:new"])])
        connection.failNextListing(malformed: malformed)
        connection.emit("session_moved")
        let snapshot = try await eventuallySnapshot(backend) {
            $0.panes["local"]?.map(\.blockID) == ["block:new"]
        }
        #expect(snapshot.failures.isEmpty)
        #expect(connection.shutdownCount == 0)
    }

    @Test func listingInvalidationDuringRefreshIsNotClearedByOlderSuccess() async throws {
        let connection = FixtureConnection(views: [view("session:old", blocks: ["block:old"])])
        let backend = RexBackend(connectionFactory: { _ in connection },
                                 hostLookup: { RexHostInventory(hosts: [], warnings: []) })
        defer { backend.shutdown() }
        _ = await settledSnapshot(backend)
        let gate = connection.holdNextListing()
        connection.emit("session_moved")
        try await waitUntil { await gate.hasArrived }
        connection.setViews([
            view("session:old", label: "Changed", blocks: ["block:old"]),
            view("session:new", blocks: ["block:new"])
        ])
        connection.emit("session_moved")
        connection.emit("session_label_changed", session: "session:old", payload: ["label": "Changed"])
        _ = try await eventuallySnapshot(backend) {
            $0.panes["local"]?.first?.sessionLabel == "Changed"
        }
        await gate.release()
        _ = try await eventuallySnapshot(backend) {
            Set(($0.panes["local"] ?? []).map(\.blockID)) == ["block:old", "block:new"]
        }
        #expect(connection.shutdownCount == 0)
    }

    @Test func metadataFailureKeepsAllPlacedPanesAndRemoteFailureIsIsolated() async throws {
        let local = FixtureConnection(views: [view("session:local", blocks: ["block:placed"])], metadataFails: true)
        let remote = FixtureConnection(views: [], listingFails: true)
        let configured = RexHost(id: "remote", label: "Remote", server: "Remote")
        let factory = FixtureFactory(local: local, remotes: [remote])
        let backend = RexBackend(connectionFactory: { factory.connection($0) },
                                 hostLookup: { RexHostInventory(hosts: [configured], warnings: []) },
                                 reconnectDelay: { _ in 60_000_000_000 })
        defer { backend.shutdown() }
        let snapshot = await settledSnapshot(backend)
        #expect(snapshot.hosts.map(\.id) == ["local", "remote"])
        #expect(snapshot.panes["local"]?.map(\.blockID) == ["block:placed"])
        #expect(snapshot.panes["local"]?.first?.sessionLabel == "Work")
        #expect(snapshot.panes["local"]?.first?.windowLabel == "Editor")
        #expect(snapshot.failures["remote"] != nil)
        #expect(snapshot.warnings.contains { $0.contains("metadata") })
        #expect(remote.shutdownCount > 0)
    }

    @Test func hostLookupRecoveryResolvesLiveAndReplayedWarningsWithoutClearingMetadataWarnings() async throws {
        let local = FixtureConnection(views: [view("session:local", blocks: ["block:local"])], metadataFails: true)
        let remote = FixtureConnection(views: [view("session:remote", blocks: ["block:remote"])])
        let configured = RexHost(id: "remote", label: "Remote", server: "Remote")
        let factory = FixtureFactory(local: local, remotes: [remote])
        let lookup = FixtureHosts([])
        lookup.fail("Server is offline")
        let backend = RexBackend(connectionFactory: { factory.connection($0) }, hostLookup: { try lookup.read() })
        defer { backend.shutdown() }
        let recorder = EventRecorder()
        let observer = Task { for await event in backend.discover() { await recorder.record(event) } }
        defer { observer.cancel() }
        try await waitUntil { await recorder.snapshot().finished }
        let failed = await recorder.snapshot()
        #expect(failed.warnings.contains { $0.contains("Server is offline") })
        #expect(failed.warnings.contains { $0.contains("metadata") })
        #expect(await settledSnapshot(backend).warnings.contains { $0.contains("Server is offline") })

        // An unrelated successful pane refresh must not resolve host lookup failure.
        local.setViews([view("session:local", label: "Updated", blocks: ["block:local"])])
        local.emit("session_view_changed", session: "session:local")
        try await waitUntil { await recorder.snapshot().panes["local"]?.first?.sessionLabel == "Updated" }
        #expect(await recorder.snapshot().warnings.contains { $0.contains("Server is offline") })

        lookup.set([configured])
        local.emit("hosts_changed")
        try await waitUntil { await recorder.snapshot().panes["remote"]?.count == 1 }
        let recovered = await recorder.snapshot()
        #expect(!recovered.warnings.contains { $0.contains("Server is offline") })
        #expect(recovered.warnings.contains { $0.contains("metadata") })
        #expect(recovered.panes["local"]?.count == 1)

        observer.cancel()
        await observer.value
        let reopened = await settledSnapshot(backend)
        #expect(!reopened.warnings.contains { $0.contains("Server is offline") })
        #expect(reopened.warnings.contains { $0.contains("metadata") })
        #expect(reopened.panes["remote"]?.count == 1)
    }

    @Test func hostLookupResultWarningsAreReplacedAndResolvedByLaterResults() async throws {
        let local = FixtureConnection(views: [])
        let lookup = FixtureHosts([], warnings: ["First remote is unavailable"])
        let backend = RexBackend(connectionFactory: { _ in local }, hostLookup: { try lookup.read() })
        defer { backend.shutdown() }
        let recorder = EventRecorder()
        let observer = Task { for await event in backend.discover() { await recorder.record(event) } }
        defer { observer.cancel() }
        try await waitUntil { await recorder.snapshot().finished }
        #expect(await recorder.snapshot().warnings == ["First remote is unavailable"])

        lookup.set([], warnings: ["Second remote needs authentication"])
        local.emit("hosts_changed")
        try await waitUntil { await recorder.snapshot().warnings.contains("Second remote needs authentication") }
        #expect(await recorder.snapshot().warnings == ["Second remote needs authentication"])
        #expect(await settledSnapshot(backend).warnings == ["Second remote needs authentication"])

        lookup.set([])
        local.emit("hosts_changed")
        let replay = try await eventuallySnapshot(backend) { $0.warnings.isEmpty }
        #expect(replay.warnings.isEmpty)
        try await waitUntil { await recorder.snapshot().warnings.isEmpty }
    }

    @Test func layoutFilteringIncludesEveryWindowAndLayerButNotDetachedBlocks() throws {
        let host = RexHost(id: "local", label: "This Mac", server: nil)
        var cache = RexPaneInventory(host: host)
        let snapshot: [String: Any] = ["session_id": "session:s", "windows": [
            ["window_id": "window:one", "layers": [
                ["layout": ["split": ["before": ["block_id": "block:a"], "after": ["block_id": "block:b"]]],
                 "blocks": [["block_id": "block:a"], ["block_id": "block:b"], ["block_id": "block:detached"]]],
                ["layout": ["block_id": "block:float"], "blocks": [["block_id": "block:float"]]]
            ]],
            ["window_id": "window:two", "layers": [
                ["layout": ["block_id": "block:c"], "blocks": [["block_id": "block:c"]]]
            ]]
        ]]
        #expect(try cache.replace(view: snapshot, since: 0))
        #expect(cache.panes.map(\.blockID) == ["block:a", "block:b", "block:float", "block:c"])
    }

    @Test func cachedReplayDoesNotDiscoverAgainAndEventsContinueWithoutObservers() async throws {
        let connection = FixtureConnection(views: [view("session:one", blocks: ["block:one"])])
        let factory = FixtureFactory(local: connection)
        let lookup = FixtureHosts([])
        let backend = RexBackend(connectionFactory: { factory.connection($0) }, hostLookup: { try lookup.read() })
        defer { backend.shutdown() }
        backend.start()
        let first = await settledSnapshot(backend)
        #expect(first.panes["local"]?.count == 1)
        let initialCalls = connection.executeCount
        let replay = await settledSnapshot(backend)
        #expect(replay.panes["local"] == first.panes["local"])
        #expect(connection.executeCount == initialCalls)
        #expect(factory.createdCount == 1)
        #expect(lookup.readCount == 1)
        #expect(connection.shutdownCount == 0)

        let metadataReads = connection.metadataReadCount
        connection.setViews([view("session:one", label: "Renamed", blocks: ["block:one", "block:new"])])
        connection.emit("session_view_changed", session: "session:one")
        let updated = try await eventuallySnapshot(backend) { $0.panes["local"]?.count == 2 }
        #expect(updated.panes["local"]?.allSatisfy { $0.sessionLabel == "Renamed" } == true)
        try await waitUntil { connection.metadataReadCount > metadataReads }
        let callsAfterEvent = connection.executeCount
        _ = await settledSnapshot(backend)
        #expect(connection.executeCount == callsAfterEvent)
        #expect(factory.createdCount == 1)
        #expect(lookup.readCount == 1)
        #expect(connection.shutdownCount == 0)
    }

    @Test func newDestroyedSessionsAndBlockClosureUpdateTheWarmCache() async throws {
        let connection = FixtureConnection(views: [view("session:one", blocks: ["block:one"])])
        let backend = RexBackend(connectionFactory: { _ in connection }, hostLookup: { RexHostInventory(hosts: [], warnings: []) })
        defer { backend.shutdown() }
        _ = await settledSnapshot(backend)
        connection.setViews([view("session:one", blocks: ["block:one"]), view("session:new", blocks: ["block:new"])])
        connection.emit("session_created", payload: ["session": ["session_id": "session:new", "label": "New"]])
        _ = try await eventuallySnapshot(backend) { $0.panes["local"]?.count == 2 }
        connection.setViews([view("session:new", blocks: ["block:new"])])
        connection.emit("session_destroyed", session: "session:one")
        let destroyed = try await eventuallySnapshot(backend) { $0.panes["local"]?.map(\.blockID) == ["block:new"] }
        #expect(destroyed.panes["local"]?.first?.sessionID == "session:new")
        connection.setViews([view("session:new", blocks: [])])
        connection.emit("block_closed", session: "session:new", block: "block:new")
        _ = try await eventuallySnapshot(backend) { $0.panes["local"]?.isEmpty == true }
    }

    @Test func terminalMetadataEventsPatchAndClearWithoutRPCs() async throws {
        let connection = FixtureConnection(views: [view("session:one", blocks: ["block:one"])])
        connection.setMetadata([metadata("block:one")])
        let backend = RexBackend(connectionFactory: { _ in connection }, hostLookup: { RexHostInventory(hosts: [], warnings: []) })
        defer { backend.shutdown() }
        let first = await settledSnapshot(backend)
        #expect(first.panes["local"]?.first?.title == "Original")
        #expect(first.panes["local"]?.first?.directory == "/reported")
        let calls = connection.executeCount
        connection.emit("terminal.title_changed", session: "session:one", block: "block:one", payload: ["title": ""])
        connection.emit("terminal.pwd_changed", session: "session:one", block: "block:one", payload: ["pwd": ""])
        connection.emit("terminal.process_changed", session: "session:one", block: "block:one", payload: ["foreground": NSNull()])
        let cleared = try await eventuallySnapshot(backend) {
            $0.panes["local"]?.first?.title == "" && $0.panes["local"]?.first?.command == "zsh"
        }
        #expect(cleared.panes["local"]?.first?.directory == "/child")
        connection.emit("terminal.child_exited", session: "session:one", block: "block:one")
        let exited = try await eventuallySnapshot(backend) { $0.panes["local"]?.first?.command == "" }
        #expect(exited.panes["local"]?.first?.directory == "")
        #expect(connection.executeCount == calls)
    }

    @Test func lateMetadataAndViewSnapshotsCannotOverwriteNewerEvents() throws {
        let host = RexHost(id: "local", label: "This Mac", server: nil)
        var cache = RexPaneInventory(host: host)
        #expect(try cache.replace(view: view("session:one", blocks: ["block:one"]), since: 0))
        let metadataVersion = cache.version
        cache.applyTerminalEvent(RexStreamEvent(type: "terminal.title_changed", sessionID: "session:one", blockID: "block:one", payload: ["title": "Newest"]))
        cache.applyTerminalEvent(RexStreamEvent(type: "terminal.pwd_changed", sessionID: "session:one", blockID: "block:one", payload: ["pwd": ""]))
        cache.applyTerminalEvent(RexStreamEvent(type: "terminal.process_changed", sessionID: "session:one", blockID: "block:one", payload: ["foreground": NSNull()]))
        cache.applyMetadata([metadata("block:one")], since: metadataVersion)
        #expect(cache.panes.first?.title == "Newest")
        #expect(cache.panes.first?.command == "zsh")
        #expect(cache.panes.first?.directory == "/child")
        let viewVersion = cache.version
        cache.invalidate(sessionID: "session:one")
        cache.renameSession("session:one", label: "Newest label")
        #expect(try !cache.replace(view: view("session:one", label: "Old", blocks: ["block:one"]), since: viewVersion))
        #expect(cache.panes.first?.sessionLabel == "Newest label")
        cache.removeSession("session:one")
        #expect(try !cache.replace(view: view("session:one", blocks: ["block:one"]), since: viewVersion))
        #expect(cache.panes.isEmpty)
    }

    @Test func focusOnlyViewRefreshDoesNotRepeatMetadata() async throws {
        let connection = FixtureConnection(views: [view("session:one", blocks: ["block:one"])])
        let backend = RexBackend(connectionFactory: { _ in connection }, hostLookup: { RexHostInventory(hosts: [], warnings: []) })
        defer { backend.shutdown() }
        _ = await settledSnapshot(backend)
        let metadataReads = connection.metadataReadCount
        let viewReads = connection.viewReadCount
        for _ in 0..<20 { connection.emit("session_view_changed", session: "session:one") }
        try await waitUntil { connection.viewReadCount > viewReads }
        _ = await settledSnapshot(backend)
        #expect(connection.metadataReadCount == metadataReads)
    }

    @Test func inFlightStartupViewIsReconciledAfterNewerStructuralEvents() async throws {
        let connection = FixtureConnection(views: [view("session:one", blocks: ["block:one"])])
        let gate = connection.holdNextView()
        let backend = RexBackend(connectionFactory: { _ in connection }, hostLookup: { RexHostInventory(hosts: [], warnings: []) })
        defer { backend.shutdown() }
        let recorder = EventRecorder()
        let observer = Task { for await event in backend.discover() { await recorder.record(event) } }
        defer { observer.cancel() }
        do { try await waitUntil { await gate.hasArrived } }
        catch { await gate.release(); throw error }
        connection.setViews([view("session:one", label: "Newest", blocks: ["block:one", "block:new"])])
        connection.emit("session_label_changed", session: "session:one", payload: ["label": "Newest"])
        connection.emit("session_view_changed", session: "session:one")
        await gate.release()
        try await waitUntil {
            let snapshot = await recorder.snapshot()
            return snapshot.finished && snapshot.panes["local"]?.count == 2
        }
        #expect(await recorder.snapshot().panes["local"]?.allSatisfy { $0.sessionLabel == "Newest" } == true)
    }

    @Test func eventEOFImmediatelyInvalidatesPreviouslySelectableRemotePanes() async throws {
        let local = FixtureConnection(views: [view("session:local", blocks: ["block:local"])])
        let remote = FixtureConnection(views: [view("session:remote", blocks: ["block:remote"])])
        let host = RexHost(id: "remote", label: "Remote", server: "Remote")
        let factory = FixtureFactory(local: local, remotes: [remote])
        let backend = RexBackend(connectionFactory: { factory.connection($0) },
                                 hostLookup: { RexHostInventory(hosts: [host], warnings: []) },
                                 reconnectDelay: { _ in 60_000_000_000 })
        defer { backend.shutdown() }
        let recorder = EventRecorder()
        let observer = Task { for await event in backend.discover() { await recorder.record(event) } }
        defer { observer.cancel() }
        try await waitUntil { await recorder.snapshot().finished }
        #expect(await recorder.snapshot().panes["remote"]?.count == 1)
        remote.disconnect()
        try await waitUntil { await recorder.snapshot().failures["remote"] != nil }
        #expect(await recorder.snapshot().panes["remote"] == nil)
        #expect(await recorder.snapshot().panes["local"]?.count == 1)
        #expect(remote.shutdownCount > 0)
        #expect(local.shutdownCount == 0)
    }

    @Test func remoteReconnectsIndependentlyAndDeletedHostsAreTornDown() async throws {
        let local = FixtureConnection(views: [view("session:local", blocks: ["block:local"])])
        let failed = FixtureConnection(views: [], listingFails: true)
        let recovered = FixtureConnection(views: [view("session:remote", blocks: ["block:remote"])])
        let remote = RexHost(id: "remote", label: "Remote", server: "Remote")
        let factory = FixtureFactory(local: local, remotes: [failed, recovered])
        let lookup = FixtureHosts([remote])
        let backend = RexBackend(connectionFactory: { factory.connection($0) }, hostLookup: { try lookup.read() }, reconnectDelay: { _ in 50_000_000 })
        defer { backend.shutdown() }
        let recorder = EventRecorder()
        let observer = Task { for await event in backend.discover() { await recorder.record(event) } }
        defer { observer.cancel() }
        try await waitUntil {
            let snapshot = await recorder.snapshot()
            return snapshot.finished && snapshot.panes["remote"]?.count == 1
        }
        #expect(await recorder.failedIDs().contains("remote"))
        #expect(await recorder.snapshot().panes["local"]?.count == 1)
        #expect(failed.shutdownCount > 0)
        #expect(local.shutdownCount == 0)
        let localCalls = local.executeCount
        lookup.set([])
        local.emit("hosts_changed")
        try await waitUntil { await recorder.snapshot().hosts.map(\.id) == ["local"] }
        #expect(recovered.shutdownCount > 0)
        #expect(local.executeCount == localCalls)
        #expect(factory.createdCount == 3)
    }

    @Test func homeHostChangesAndReconnectReconcileConfiguredHosts() async throws {
        let local = FixtureConnection(views: [view("session:local", blocks: ["block:local"])])
        let recoveredLocal = FixtureConnection(views: [view("session:local", blocks: ["block:local"])])
        let home = RexHost(id: "home:remote", label: "Home", server: "https://home.example")
        let remote = RexHost(id: "remote", label: "Remote", server: "Remote")
        let homeConnection = FixtureConnection(views: [])
        let remoteConnection = FixtureConnection(views: [view("session:remote", blocks: ["block:remote"])])
        let factory = FixtureFactory(local: local, recoveringLocal: recoveredLocal,
                                     remotes: [homeConnection, remoteConnection])
        let lookup = FixtureHosts([home])
        let backend = RexBackend(connectionFactory: { factory.connection($0) }, hostLookup: { try lookup.read() },
                                 reconnectDelay: { _ in 50_000_000 })
        defer { backend.shutdown() }
        let recorder = EventRecorder()
        let observer = Task { for await event in backend.discover() { await recorder.record(event) } }
        defer { observer.cancel() }
        try await waitUntil { await recorder.snapshot().finished }

        lookup.set([home, remote])
        homeConnection.emit("hosts_changed")
        try await waitUntil { await recorder.snapshot().panes[remote.id]?.count == 1 }

        // Changes missed while disconnected have no replay event on the new stream.
        lookup.set([home])
        local.disconnect()
        try await waitUntil {
            let snapshot = await recorder.snapshot()
            return snapshot.hosts.map(\.id) == ["local", home.id] && snapshot.panes["local"]?.count == 1
        }
        #expect(remoteConnection.shutdownCount > 0)
        #expect(homeConnection.shutdownCount == 0)
    }

    @Test func observerCancellationLeavesWorkersWarmAndShutdownIsSynchronous() async throws {
        let connection = FixtureConnection(views: [])
        let factory = FixtureFactory(local: connection)
        let backend = RexBackend(connectionFactory: { factory.connection($0) }, hostLookup: { RexHostInventory(hosts: [], warnings: []) })
        let recorder = EventRecorder()
        let observer = Task { for await event in backend.discover() { await recorder.record(event) } }
        try await waitUntil { await recorder.snapshot().finished }
        observer.cancel()
        await observer.value
        #expect(connection.shutdownCount == 0)
        backend.shutdown()
        #expect(connection.shutdownCount > 0)
        let count = factory.createdCount
        backend.start()
        for await _ in backend.discover() { Issue.record("A stopped backend must not restart discovery") }
        #expect(factory.createdCount == count)
    }

    @Test func homeServerIsIncludedAndConfiguredEndpointIsNotDuplicated() async throws {
        let home: [String: Any] = ["this_machine": false, "label": "Main Server", "endpoint": "https://home.example"]
        let inventory = try RexBackend.parseHosts(["home": home, "hosts": [], "warnings": []])
        #expect(inventory.hosts.count == 1)
        #expect(inventory.hosts.first?.server == "https://home.example")
        #expect(inventory.hosts.first?.label == "Main Server")
        let local = FixtureConnection(views: [])
        let remote = FixtureConnection(views: [view("session:home", blocks: ["block:home"])])
        let factory = FixtureFactory(local: local, remotes: [remote])
        let backend = RexBackend(connectionFactory: { factory.connection($0) }, hostLookup: { inventory })
        defer { backend.shutdown() }
        let snapshot = await settledSnapshot(backend)
        #expect(snapshot.hosts.map(\.server) == [nil, "https://home.example"])
        #expect(snapshot.panes["home:https://home.example"]?.first?.blockID == "block:home")
        let configured = try RexBackend.parseHosts(["home": home, "hosts": [
            ["host": ["id": "home", "label": "Configured", "endpoints": ["https://home.example"], "icon": "house"]]
        ], "warnings": []])
        #expect(configured.hosts.count == 1)
        #expect(configured.hosts.first?.server == "Configured")
        #expect(configured.hosts.first?.icon == "house")
    }

    private func settledSnapshot(_ backend: RexBackend) async -> InventorySnapshot {
        var consumer: Task<Void, Never>?
        let snapshot: InventorySnapshot = await withCheckedContinuation { continuation in
            consumer = Task {
                var value = InventorySnapshot()
                var delivered = false
                for await event in backend.discover() {
                    value.apply(event)
                    if case .finished = event, !delivered {
                        delivered = true
                        continuation.resume(returning: value)
                    }
                }
                if !delivered { continuation.resume(returning: value) }
            }
        }
        consumer?.cancel()
        await consumer?.value
        return snapshot
    }

    private func eventuallySnapshot(_ backend: RexBackend, matching predicate: (InventorySnapshot) -> Bool) async throws -> InventorySnapshot {
        for _ in 0..<200 {
            let snapshot = await settledSnapshot(backend)
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RexBackendError("Warm cache did not reach the expected state")
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RexBackendError("Expected discovery event did not arrive")
    }

    private func view(_ session: String, label: String = "Work", blocks: [String]) -> [String: Any] {
        func layout(_ ids: ArraySlice<String>) -> [String: Any] {
            guard let first = ids.first else { return [:] }
            if ids.count == 1 { return ["block_id": first] }
            return ["split": ["before": ["block_id": first], "after": layout(ids.dropFirst())]]
        }
        return ["session_id": session, "label": label, "windows": [
            ["window_id": "window:" + session, "label": "Editor", "layers": [
                ["layout": layout(blocks[...]), "blocks": (blocks + ["block:detached"]).map { ["block_id": $0, "label": "Shell"] }]
            ]]
        ]]
    }

    private func metadata(_ block: String) -> [String: Any] {
        ["block_id": block, "title": ["title": "Original"], "pwd": ["pwd": "file:///reported"],
         "process": ["foreground": ["name": "vim", "cwd": "/foreground"], "child": ["name": "zsh", "cwd": "/child"]]]
    }
}

private struct InventorySnapshot {
    var hosts: [RexHost] = []
    var panes: [String: [Pane]] = [:]
    var failures: [String: String] = [:]
    private var otherWarnings: [String] = []
    private var hostDiscoveryWarnings: [String] = []
    var warnings: [String] { otherWarnings + hostDiscoveryWarnings }
    var finished = false
    mutating func apply(_ event: DiscoveryEvent) {
        switch event {
        case .hosts(let values):
            hosts = values
            let ids = Set(values.map(\.id))
            panes = panes.filter { ids.contains($0.key) }
            failures = failures.filter { ids.contains($0.key) }
        case .panes(let host, let values): panes[host.id] = values; failures.removeValue(forKey: host.id)
        case .failed(let host, let message): panes.removeValue(forKey: host.id); failures[host.id] = message
        case .warning(let message): otherWarnings.append(message)
        case .hostDiscoveryWarnings(let messages): hostDiscoveryWarnings = messages
        case .finished: finished = true
        }
    }
}

private actor EventRecorder {
    private var value = InventorySnapshot()
    private var failed = Set<String>()
    func record(_ event: DiscoveryEvent) {
        value.apply(event)
        if case .failed(let host, _) = event { failed.insert(host.id) }
    }
    func snapshot() -> InventorySnapshot { value }
    func failedIDs() -> Set<String> { failed }
}

private final class FixtureConnection: RexInventoryConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var views: [[String: Any]]
    private var metadata: [[String: Any]] = []
    private let metadataFails: Bool
    private let listingFails: Bool
    private var calls = 0
    private var metadataReads = 0
    private var viewReads = 0
    private var shutdowns = 0
    private var nextViewGate: FixtureRequestGate?
    private var nextListingGate: FixtureRequestGate?
    private var viewFailures: [String: Bool] = [:]
    private var listingFailure: Bool?
    private let stream: AsyncThrowingStream<RexStreamEvent, Error>
    private let continuation: AsyncThrowingStream<RexStreamEvent, Error>.Continuation

    init(views: [[String: Any]], metadataFails: Bool = false, listingFails: Bool = false) {
        self.views = views
        self.metadataFails = metadataFails
        self.listingFails = listingFails
        var continuation: AsyncThrowingStream<RexStreamEvent, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    var executeCount: Int { lock.withLock { calls } }
    var metadataReadCount: Int { lock.withLock { metadataReads } }
    var viewReadCount: Int { lock.withLock { viewReads } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    func setViews(_ values: [[String: Any]]) { lock.withLock { views = values } }
    func setMetadata(_ values: [[String: Any]]) { lock.withLock { metadata = values } }
    func failNextView(_ session: String, malformed: Bool) { lock.withLock { viewFailures[session] = malformed } }
    func failNextListing(malformed: Bool) { lock.withLock { listingFailure = malformed } }
    func holdNextView() -> FixtureRequestGate {
        lock.withLock {
            let gate = FixtureRequestGate()
            nextViewGate = gate
            return gate
        }
    }
    func holdNextListing() -> FixtureRequestGate {
        lock.withLock {
            let gate = FixtureRequestGate()
            nextListingGate = gate
            return gate
        }
    }
    func disconnect() { continuation.finish(throwing: RexConnectionError.disconnected("Event connection lost")) }
    func emit(_ type: String, session: String? = nil, block: String? = nil, payload: [String: Any] = [:]) {
        continuation.yield(RexStreamEvent(type: type, sessionID: session, blockID: block, payload: payload))
    }
    func events() -> AsyncThrowingStream<RexStreamEvent, Error> {
        emit("ready")
        return stream
    }
    func shutdown() {
        lock.withLock { shutdowns += 1 }
        continuation.finish()
    }
    func execute(_ script: String, arguments: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let (object, gate) = try lock.withLock { () throws -> ([String: Any], FixtureRequestGate?) in
            calls += 1
            if arguments["panes"] != nil {
                metadataReads += 1
                if metadataFails { throw RexConnectionError.requestFailed("Metadata owner unavailable") }
                return (["items": metadata, "unavailable": 0], nil)
            }
            if let sessions = arguments["sessions"] as? [String] {
                viewReads += 1
                if let session = sessions.first, let malformed = viewFailures.removeValue(forKey: session) {
                    if malformed { return (["views": ["invalid"], "errors": []], nil) }
                    throw RexConnectionError.requestFailed("Temporary session view failure")
                }
                let selected = views.filter { sessions.contains($0["session_id"] as? String ?? "") }
                let present = Set(selected.compactMap { $0["session_id"] as? String })
                let gate = nextViewGate
                nextViewGate = nil
                return (["views": selected, "errors": sessions.filter { !present.contains($0) }.map {
                    ["session_id": $0, "message": "Session no longer exists"]
                }], gate)
            }
            if let malformed = listingFailure {
                listingFailure = nil
                if malformed { return (["sessions": ["invalid"]], nil) }
                throw RexConnectionError.requestFailed("Temporary session listing failure")
            }
            if listingFails { throw RexConnectionError.disconnected("Remote is unreachable") }
            let gate = nextListingGate
            nextListingGate = nil
            return (["sessions": views.map { ["session_id": $0["session_id"] as? String ?? ""] }], gate)
        }
        if let gate { await gate.wait() }
        return object
    }
}

private actor FixtureRequestGate {
    private(set) var hasArrived = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        hasArrived = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private final class FixtureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var locals: [FixtureConnection]
    private var remotes: [FixtureConnection]
    private var count = 0
    init(local: FixtureConnection, recoveringLocal: FixtureConnection? = nil, remotes: [FixtureConnection] = []) {
        locals = [local] + (recoveringLocal.map { [$0] } ?? [])
        self.remotes = remotes
    }
    var createdCount: Int { lock.withLock { count } }
    func connection(_ host: RexHost) -> FixtureConnection {
        lock.withLock {
            count += 1
            if host.server == nil { return locals.count > 1 ? locals.removeFirst() : locals[0] }
            return remotes.count > 1 ? remotes.removeFirst() : remotes[0]
        }
    }
}

private final class FixtureHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [RexHost]
    private var warnings: [String]
    private var failure: String?
    private var reads = 0
    init(_ hosts: [RexHost], warnings: [String] = []) {
        self.hosts = hosts
        self.warnings = warnings
    }
    var readCount: Int { lock.withLock { reads } }
    func set(_ values: [RexHost], warnings: [String] = []) {
        lock.withLock { hosts = values; self.warnings = warnings; failure = nil }
    }
    func fail(_ message: String) { lock.withLock { failure = message } }
    func read() throws -> RexHostInventory {
        try lock.withLock {
            reads += 1
            if let failure { throw RexBackendError(failure) }
            return RexHostInventory(hosts: hosts, warnings: warnings)
        }
    }
}
