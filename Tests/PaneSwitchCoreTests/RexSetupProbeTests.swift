import Foundation
import Testing
@testable import PaneSwitchCore

struct RexSetupProbeTests {
    @Test func localCheckIdentifiesOnlyMacApplicationClientsAndClosesWorker() async throws {
        let connection = SetupConnection(reply: ["clients": [
            ["client_id": "client:app", "info": ["kind": "app", "platform": "macos", "label": "Rex"], "principal": ["pid": 123]],
            ["client_id": "client:cli", "info": ["kind": "cli", "platform": "macos"]],
            ["client_id": "client:other", "info": ["kind": "app", "platform": "linux"]]
        ]])
        let clients = try await RexSetupProbe.appClients(connection: connection)
        #expect(clients.map(\.id) == ["client:app"])
        #expect(clients.first?.pid == 123)
        #expect(connection.shutdownCount > 0)
    }

    @Test func malformedReplyClosesWorkerAndRemainsAnError() async {
        let connection = SetupConnection(reply: ["clients": "invalid"])
        await #expect(throws: (any Error).self) {
            try await RexSetupProbe.appClients(connection: connection)
        }
        #expect(connection.shutdownCount > 0)
    }

    @Test func cancellationClosesTheIsolatedWorker() async {
        let connection = SetupConnection(reply: [:], suspended: true)
        let task = Task { try await RexSetupProbe.appClients(connection: connection) }
        for await _ in connection.started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connection.shutdownCount > 0)
    }
}

private final class SetupConnection: RexInventoryConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: [String: Any]
    private let suspended: Bool
    private let start: AsyncStream<Void>.Continuation
    let started: AsyncStream<Void>
    private var shutdowns = 0

    init(reply: [String: Any], suspended: Bool = false) {
        self.reply = reply
        self.suspended = suspended
        let stream = AsyncStream<Void>.makeStream()
        started = stream.stream
        start = stream.continuation
    }

    var shutdownCount: Int { lock.withLock { shutdowns } }

    func execute(_ script: String, arguments: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        start.yield(())
        if suspended { try await Task.sleep(for: .seconds(30)) }
        return reply
    }

    func events() -> AsyncThrowingStream<RexStreamEvent, Error> {
        return AsyncThrowingStream { $0.finish() }
    }

    func shutdown() { lock.withLock { shutdowns += 1 } }
}
