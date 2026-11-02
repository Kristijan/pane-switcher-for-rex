import Darwin
import Foundation
import Testing
@testable import PaneSwitchCore

struct RexConnectionTests {
    @Test func successfulRequestsAndLuaErrorsReuseOneWorker() async throws {
        let fixture = try Fixture(loop(#"""
        case "$request" in
            *fail-request*) printf '%s\n' "{\"id\":\"$id\",\"ok\":false,\"error\":\"Lua request failed\"}" ;;
            *) respond "{\\\"pid\\\":$$,\\\"count\\\":$count}" ;;
        esac
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let first = try await connection.execute("first")
        do {
            _ = try await connection.execute("fail-request")
            Issue.record("A Lua failure must fail its request.")
        } catch let error as RexConnectionError {
            guard case .requestFailed(let message) = error else { throw error }
            #expect(message == "Lua request failed")
        }
        let third = try await connection.execute("third")
        #expect(first["pid"] as? Int == third["pid"] as? Int)
        #expect(first["count"] as? Int == 1)
        #expect(third["count"] as? Int == 3)
    }

    @Test func concurrentRequestsHaveCorrelatedSerializedReplies() async throws {
        let fixture = try Fixture(loop(#"""
        respond "{\\\"pid\\\":$$,\\\"count\\\":$count}"
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let tasks = (0..<20).map { index in Task { try await connection.execute("request-\(index)") } }
        var counts = Set<Int>()
        var pids = Set<Int>()
        for task in tasks {
            let reply = try await task.value
            counts.insert(try #require(reply["count"] as? Int))
            pids.insert(try #require(reply["pid"] as? Int))
        }
        #expect(counts == Set(1...20))
        #expect(pids.count == 1)
    }

    @Test func nullIsEmptyAndNonObjectResultDoesNotDisconnectWorker() async throws {
        let fixture = try Fixture(loop(#"""
        case "$request" in
            *null-result*) respond 'null' ;;
            *array-result*) respond '[1,2]' ;;
            *) respond "{\\\"count\\\":$count}" ;;
        esac
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        #expect(try await connection.execute("null-result").isEmpty)
        do {
            _ = try await connection.execute("array-result")
            Issue.record("An array must not masquerade as an object response.")
        } catch let error as RexConnectionError {
            guard case .requestFailed = error else { throw error }
        }
        let reply = try await connection.execute("object-result")
        #expect(reply["count"] as? Int == 3)
    }

    @Test func queuedCancellationAndDeadlineDoNotInterruptActiveRequest() async throws {
        let fixture = try Fixture(loop(#"""
        case "$request" in
            *hold-request*)
                : > "$directory/active"
                /bin/sleep 0.4
                ;;
        esac
        respond "{\\\"pid\\\":$$,\\\"count\\\":$count}"
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let active = Task { try await connection.execute("hold-request", timeout: 2) }
        try await fixture.waitForFile("active")
        let cancelled = Task { try await connection.execute("cancelled-request") }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("A canceled queued call must not be sent.")
        } catch is CancellationError {}
        let expired = Task { try await connection.execute("expired-request", timeout: 0.03) }
        #expect(isDisconnected(await expired.result))
        let first = try await active.value
        let second = try await connection.execute("next-request")
        #expect(first["pid"] as? Int == second["pid"] as? Int)
        #expect(second["count"] as? Int == 2)
    }

    @Test func inFlightCancellationResetsWorkerAndCanReconnect() async throws {
        let fixture = try Fixture(loop(#"""
        case "$request" in
            *hang-request*)
                printf '%s' "$$" > "$directory/active"
                trap '' TERM
                exec /bin/sleep 30
                ;;
        esac
        respond "{\\\"pid\\\":$$}"
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let active = Task { try await connection.execute("hang-request") }
        try await fixture.waitForFile("active")
        active.cancel()
        #expect(isDisconnected(await active.result))
        let oldPID = try fixture.pid(in: "active")
        try await waitForExit(oldPID)
        let reply = try await connection.execute("fresh-request")
        #expect(reply["pid"] as? Int != Int(oldPID))
    }

    @Test func inFlightDeadlineResetsWorkerAndKillsUnresponsiveProcess() async throws {
        let fixture = try Fixture(loop(#"""
        case "$request" in
            *hang-request*)
                printf '%s' "$$" > "$directory/active"
                trap '' TERM
                exec /bin/sleep 30
                ;;
        esac
        respond "{\\\"pid\\\":$$}"
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let warm = try await connection.execute("warm-request")
        let request = Task { try await connection.execute("hang-request", timeout: 1) }
        try await fixture.waitForFile("active")
        #expect(isDisconnected(await request.result))
        let oldPID = try fixture.pid(in: "active")
        #expect(warm["pid"] as? Int == Int(oldPID))
        try await waitForExit(oldPID)
        let reply = try await connection.execute("fresh-request")
        #expect(reply["pid"] as? Int != Int(oldPID))
    }

    @Test func eofAndMalformedFramesFailRequestsAndPermitFreshWorker() async throws {
        for body in ["exit 0", "printf '%s\\n' 'not-json'", "printf '%s' '{\"unfinished\":'"] {
            let fixture = try Fixture(loop(#"""
            case "$request" in
                *broken-request*)
                    \#(body)
                    exit 0
                    ;;
            esac
            respond "{\\\"ok\\\":true}"
            """#))
            let connection = fixture.connection()
            defer { connection.shutdown() }
            let failure = Task { try await connection.execute("broken-request", timeout: 1) }
            #expect(isDisconnected(await failure.result))
            let reply = try await connection.execute("fresh-request")
            #expect(reply["ok"] as? Bool == true)
        }
    }

    @Test func stderrBeyondCaptureLimitIsDrainedWithoutBlockingReplies() async throws {
        let fixture = try Fixture(loop(#"""
        i=0
        while [ "$i" -lt 4096 ]; do
            printf '%s\n' 'diagnostic diagnostic diagnostic diagnostic diagnostic diagnostic' >&2
            i=$((i + 1))
        done
        respond '{\"ok\":true}'
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let reply = try await connection.execute("noisy-request", timeout: 3)
        #expect(reply["ok"] as? Bool == true)
    }

    @Test func eventWorkerRemainsResponsiveWhileCommandWorkerIsBlocked() async throws {
        let fixture = try Fixture(#"""
        events=no
        for argument in "$@"; do
            if [ "$argument" = --all ]; then events=yes; fi
        done
        if [ "$events" = yes ]; then
            printf '%s\n' '{"type":"ready","payload":{}}'
            while [ ! -e "$directory/active" ]; do /bin/sleep 0.01; done
            printf '%s\n' '{"type":"terminal.title_changed","session_id":"session:new","block_id":"block:new","payload":{"title":"Fresh"}}'
            while IFS= read -r ignored; do :; done
            exit 0
        fi
        """# + loop(#"""
        : > "$directory/active"
        while [ ! -e "$directory/release" ]; do /bin/sleep 0.01; done
        respond '{\"ok\":true}'
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let events = Task { try await collectEvents(connection.events(), count: 2) }
        let command = Task { try await connection.execute("held-request", timeout: 3) }
        let received = try await events.value
        #expect(received.map(\.type) == ["ready", "terminal.title_changed"])
        #expect(received.last?.sessionID == "session:new")
        #expect(received.last?.blockID == "block:new")
        #expect(received.last?.payload["title"] as? String == "Fresh")
        try Data().write(to: fixture.directory.appendingPathComponent("release"))
        #expect(try await command.value["ok"] as? Bool == true)
    }

    @Test func shutdownIsIdempotentAndReapsBothWorkersWithKillFallback() async throws {
        let fixture = try Fixture(#"""
        events=no
        for argument in "$@"; do
            if [ "$argument" = --all ]; then events=yes; fi
        done
        if [ "$events" = yes ]; then
            printf '%s\n' "{\"type\":\"ready\",\"payload\":{\"pid\":$$}}"
            trap '' TERM
            exec /bin/sleep 30
        fi
        """# + loop(#"""
        respond "{\\\"pid\\\":$$}"
        trap '' TERM
        exec /bin/sleep 30
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        var iterator = connection.events().makeAsyncIterator()
        let ready = try #require(try await iterator.next())
        let eventPID = Int32(try #require(ready.payload["pid"] as? Int))
        let reply = try await connection.execute("first-request")
        let commandPID = Int32(try #require(reply["pid"] as? Int))
        #expect(eventPID != commandPID)
        connection.shutdown()
        connection.shutdown()
        #expect(Darwin.kill(eventPID, 0) == -1 && errno == ESRCH)
        #expect(Darwin.kill(commandPID, 0) == -1 && errno == ESRCH)
        let later = Task { try await connection.execute("after-shutdown") }
        #expect(isDisconnected(await later.result))
        do {
            _ = try await iterator.next()
            Issue.record("Shutdown must finish the active event subscription with a transport error.")
        } catch let error as RexConnectionError {
            guard case .disconnected = error else { throw error }
        }
    }

    @Test func shutdownResolvesAllConcurrentPendingRequests() async throws {
        let fixture = try Fixture(loop(#"""
        : > "$directory/active"
        trap '' TERM
        exec /bin/sleep 30
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let requests = (0..<20).map { _ in Task { try await connection.execute("pending-request") } }
        try await fixture.waitForFile("active")
        connection.shutdown()
        for request in requests { #expect(isDisconnected(await request.result)) }
    }

    @Test func oversizedUnterminatedOutputDisconnectsWithoutWaitingForDeadline() async throws {
        let fixture = try Fixture(loop("exec /bin/dd if=/dev/zero bs=1048576 count=64"))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let request = Task { try await connection.execute("oversized-output", timeout: 3) }
        guard case .failure(let error) = await request.result,
              let error = error as? RexConnectionError,
              case .disconnected(let message) = error else {
            Issue.record("Oversized unframed output must disconnect the worker.")
            return
        }
        #expect(message.contains("safe read limit"))
    }

    @Test func eventEOFEndsSubscriptionWithoutDiscardingCommandWorker() async throws {
        let fixture = try Fixture(#"""
        for argument in "$@"; do
            if [ "$argument" = --all ]; then
                printf '%s\n' '{"type":"ready","payload":{}}'
                exit 4
            fi
        done
        """# + loop(#"""
        respond "{\\\"pid\\\":$$,\\\"count\\\":$count}"
        """#))
        let connection = fixture.connection()
        defer { connection.shutdown() }
        let before = try await connection.execute("before-events")
        do {
            _ = try await collectEvents(connection.events(), count: 2)
            Issue.record("Event EOF must end the subscription with an error.")
        } catch let error as RexConnectionError {
            guard case .disconnected = error else { throw error }
        }
        let after = try await connection.execute("after-events")
        #expect(before["pid"] as? Int == after["pid"] as? Int)
        #expect(after["count"] as? Int == 2)
    }

    private func loop(_ body: String) -> String {
        #"""

        respond() {
            printf '%s\n' "{\"id\":\"$id\",\"ok\":true,\"result_json\":\"$1\"}"
        }
        count=0
        while IFS= read -r request; do
            id=${request#*\"id\":\"}
            id=${id%%\"*}
            count=$((count + 1))
            \#(body)
        done
        """#
    }

    private func isDisconnected(_ result: Result<[String: Any], Error>) -> Bool {
        guard case .failure(let error) = result,
              let error = error as? RexConnectionError,
              case .disconnected = error else { return false }
        return true
    }

    private func waitForExit(_ pid: Int32) async throws {
        for _ in 0..<200 {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw FixtureError("Rex worker \(pid) survived transport teardown.")
    }

    private func collectEvents(_ stream: AsyncThrowingStream<RexStreamEvent, Error>, count: Int) async throws -> [RexStreamEvent] {
        try await withThrowingTaskGroup(of: [RexStreamEvent].self) { group in
            group.addTask {
                var events: [RexStreamEvent] = []
                for try await event in stream {
                    events.append(event)
                    if events.count == count { return events }
                }
                return events
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw FixtureError("Rex events did not arrive before the command was released.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let executable: URL

        init(_ body: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            executable = directory.appendingPathComponent("rex-fixture")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(("#!/bin/sh\nset -eu\ndirectory=${0%/*}\n" + body + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func connection() -> RexConnection {
            RexConnection(executable: executable, host: RexHost(id: "local", label: "Local", server: nil))
        }

        func waitForFile(_ name: String) async throws {
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw FixtureError("Rex fixture did not start its active request.")
        }

        func pid(in name: String) throws -> Int32 {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            return try #require(Int32(text))
        }
    }

    private struct FixtureError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
