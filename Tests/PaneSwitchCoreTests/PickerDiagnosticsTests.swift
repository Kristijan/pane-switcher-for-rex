import Foundation
import Testing
@testable import PaneSwitchCore

struct PickerDiagnosticsTests {
    @Test func latestTimingsStayBoundedAndSurviveTheNextLaunch() {
        var rpc = RexSwitchTimings()
        rpc.record(.milliseconds(3), remote: false)
        rpc.record(.milliseconds(7), remote: true)
        rpc.record(.milliseconds(2), remote: false)
        rpc.record(.milliseconds(11), remote: true)
        #expect(rpc.localRPC == .milliseconds(5))
        #expect(rpc.remoteRPC == .milliseconds(18))
        #expect(rpc.localRequests == 2)
        #expect(rpc.remoteRequests == 2)

        var diagnostics = PickerDiagnostics()
        diagnostics.recordLaunch(.milliseconds(9))
        diagnostics.recordSwitch(total: .milliseconds(30), nativeActivation: .milliseconds(6), rpc: rpc)
        for value in 1...100 { diagnostics.recordQuery(.milliseconds(value)) }
        // A successful switch dismisses the picker; reopening updates launch, not the last switch.
        diagnostics.recordLaunch(.milliseconds(12))
        #expect(diagnostics.lines == [
            "Launch request → visible: 12.00 ms", "Query update: 100.00 ms", "Switch total: 30.00 ms",
            "Native Rex activation: 6.00 ms", "Local RPC: 5.00 ms", "Remote RPC: 18.00 ms"
        ])
    }

    @Test func activationFailureDoesNotDisplayAnEarlierSwitchsRPCTimings() {
        var rpc = RexSwitchTimings()
        rpc.record(.milliseconds(10), remote: true)
        var diagnostics = PickerDiagnostics()
        diagnostics.recordSwitch(total: .milliseconds(15), nativeActivation: .milliseconds(5), rpc: rpc)
        diagnostics.recordSwitch(total: .milliseconds(20), nativeActivation: .milliseconds(20), rpc: nil)
        #expect(diagnostics.lines == ["Switch total: 20.00 ms", "Native Rex activation: 20.00 ms"])
    }

    @Test func measuredAndNormalSwitchesUseTheSameLocalAndRemoteRequests() async throws {
        let recorder = SwitchRequestRecorder()
        let clock = SwitchTestClock()
        let local = DiagnosticsConnection(hostID: "local", recorder: recorder)
        let remote = DiagnosticsConnection(hostID: "remote", recorder: recorder)
        let remoteHost = RexHost(id: "remote", label: "Remote", server: "Remote")
        let backend = RexBackend(connectionFactory: { $0.server == nil ? local : remote },
                                 hostLookup: { RexHostInventory(hosts: [remoteHost], warnings: []) },
                                 switchClock: { clock.now() })
        defer { backend.shutdown() }
        let panes = await inventory(backend)
        let localPane = try #require(panes.first { $0.host.server == nil })
        let remotePane = try #require(panes.first { $0.host.server != nil })

        let localMeasurement = await backend.measuredSwitchTo(localPane, clientID: "client")
        try localMeasurement.result.get()
        #expect(localMeasurement.timings.localRequests == 1)
        #expect(localMeasurement.timings.remoteRequests == 0)
        #expect(localMeasurement.timings.localRPC == .milliseconds(2))
        #expect(localMeasurement.timings.remoteRPC == .zero)
        #expect(recorder.take() == ["local:switch"])
        try await backend.switchTo(localPane, clientID: "client")
        #expect(recorder.take() == ["local:switch"])

        let remoteMeasurement = await backend.measuredSwitchTo(remotePane, clientID: "client")
        try remoteMeasurement.result.get()
        #expect(remoteMeasurement.timings.localRequests == 2)
        #expect(remoteMeasurement.timings.remoteRequests == 2)
        #expect(remoteMeasurement.timings.localRPC == .milliseconds(4))
        #expect(remoteMeasurement.timings.remoteRPC == .milliseconds(4))
        #expect(recorder.take() == ["remote:validate", "local:client", "remote:focus", "local:client"])
        try await backend.switchTo(remotePane, clientID: "client")
        #expect(recorder.take() == ["remote:validate", "local:client", "remote:focus", "local:client"])
        #expect(clock.readCount == 10)
    }

    @Test func failedRemoteValidationIsMeasuredAndNeverRepeatsTheMutation() async throws {
        let recorder = SwitchRequestRecorder()
        let clock = SwitchTestClock()
        let local = DiagnosticsConnection(hostID: "local", recorder: recorder)
        let remote = DiagnosticsConnection(hostID: "remote", recorder: recorder)
        let remoteHost = RexHost(id: "remote", label: "Remote", server: "Remote")
        let backend = RexBackend(connectionFactory: { $0.server == nil ? local : remote },
                                 hostLookup: { RexHostInventory(hosts: [remoteHost], warnings: []) },
                                 switchClock: { clock.now() })
        defer { backend.shutdown() }
        let panes = await inventory(backend)
        let pane = try #require(panes.first { $0.host.server != nil })
        remote.failNextSwitch()
        let measurement = await backend.measuredSwitchTo(pane, clientID: "client")
        #expect(throws: RexBackendError.self) { try measurement.result.get() }
        #expect(measurement.timings.remoteRequests == 1)
        #expect(measurement.timings.localRequests == 0)
        #expect(measurement.timings.remoteRPC == .milliseconds(2))
        #expect(measurement.timings.localRPC == .zero)
        #expect(clock.readCount == 2)
        #expect(recorder.take() == ["remote:validate"])
    }

    private func inventory(_ backend: RexBackend) async -> [Pane] {
        var hosts: [String: [Pane]] = [:]
        for await event in backend.discover() {
            switch event {
            case .panes(let host, let panes): hosts[host.id] = panes
            case .finished: return hosts.values.flatMap { $0 }
            default: break
            }
        }
        return hosts.values.flatMap { $0 }
    }
}

private final class SwitchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var reads = 0

    var readCount: Int { lock.withLock { reads } }

    func now() -> ContinuousClock.Instant {
        lock.withLock {
            defer { reads += 1 }
            return base + .milliseconds(reads * 2)
        }
    }
}

private final class SwitchRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    func append(_ request: String) { lock.withLock { requests.append(request) } }
    func take() -> [String] {
        lock.withLock {
            let result = requests
            requests.removeAll(keepingCapacity: true)
            return result
        }
    }
}

private final class DiagnosticsConnection: RexInventoryConnection, @unchecked Sendable {
    private let hostID: String
    private let recorder: SwitchRequestRecorder
    private let lock = NSLock()
    private var shouldFail = false
    private let stream: AsyncThrowingStream<RexStreamEvent, Error>
    private let continuation: AsyncThrowingStream<RexStreamEvent, Error>.Continuation

    init(hostID: String, recorder: SwitchRequestRecorder) {
        self.hostID = hostID
        self.recorder = recorder
        let pair = AsyncThrowingStream<RexStreamEvent, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func failNextSwitch() { lock.withLock { shouldFail = true } }
    func shutdown() { continuation.finish() }
    func events() -> AsyncThrowingStream<RexStreamEvent, Error> {
        continuation.yield(RexStreamEvent(type: "ready", sessionID: nil, blockID: nil, payload: [:]))
        return stream
    }

    func execute(_ script: String, arguments: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if arguments["action"] as? String == "session.select" {
            recorder.append(hostID + ":client")
            return [:]
        }
        if arguments["block_id"] != nil {
            recorder.append(hostID + ":" + (arguments["phase"] as? String ?? "switch"))
            let fails = lock.withLock {
                let value = shouldFail
                shouldFail = false
                return value
            }
            if fails { throw RexBackendError("Pane disappeared") }
            return [:]
        }
        if arguments["panes"] != nil { return ["items": [], "unavailable": 0] }
        if arguments["sessions"] != nil {
            return ["views": [["session_id": "session", "label": "Work", "windows": [
                ["window_id": "window", "layers": [["layout": ["block_id": "block"],
                                                        "blocks": [["block_id": "block", "label": "Shell"]]]]]
            ]]], "errors": []]
        }
        return ["sessions": [["session_id": "session"]]]
    }
}
