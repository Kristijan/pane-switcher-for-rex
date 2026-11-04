import AppKit
import PaneSwitchCore

@MainActor
struct RexApplicationTarget {
    private let application: NSRunningApplication?
    private let ambiguous: Bool
    let isRexFrontmost: Bool

    init(frontmost: NSRunningApplication?, running: [NSRunningApplication]) {
        let available = running.filter { !$0.isTerminated }
        let selected: NSRunningApplication?
        if let frontmost, available.contains(where: { $0.processIdentifier == frontmost.processIdentifier }) {
            selected = frontmost
            isRexFrontmost = true
        } else {
            selected = available.count == 1 ? available[0] : nil
            isRexFrontmost = false
        }
        application = selected
        ambiguous = selected == nil && available.count > 1
    }

    var isRexRunning: Bool { application != nil || ambiguous }

    func resolve() throws -> NSRunningApplication {
        guard let application else {
            throw PickerError(ambiguous
                ? "Focus the Rex app you want to switch in, then try again."
                : "Rex isn’t running. Open Rex, then try again.")
        }
        guard !application.isTerminated else { throw PickerError("The selected Rex app is no longer running.") }
        return application
    }

    func client(in backend: RexBackend) async throws -> (application: NSRunningApplication, id: String) {
        let app = try resolve()
        let matching = try await backend.appClients().filter { $0.pid == app.processIdentifier }
        try Task.checkCancellation()
        guard !app.isTerminated else { throw PickerError("The selected Rex app is no longer running.") }
        guard matching.count == 1, let client = matching.first else {
            throw PickerError("Cannot identify this Rex app's local client. Keep Rex and its local server running.")
        }
        return (app, client.id)
    }
}

/// One activation, exact backend selection and recent-history commit for every entry point.
/// Persistence failure is a warning after success, never a reason to repeat a Rex mutation.
@MainActor
final class PaneSwitcher {
    struct Outcome {
        let result: Result<Void, Error>
        let nativeActivation: Duration
        let rpc: RexSwitchTimings?
        let recentWarning: String?
    }

    private let backend: RexBackend
    private let recentStore: RecentPaneStore
    private let activate: @MainActor (NSRunningApplication) async throws -> Void
    private var recentSaveWarning: String?

    init(backend: RexBackend, recentStore: RecentPaneStore = RecentPaneStore(),
         activate: (@MainActor (NSRunningApplication) async throws -> Void)? = nil) {
        self.backend = backend
        self.recentStore = recentStore
        self.activate = activate ?? Self.activateRex
    }

    var recentIDs: [String] { recentStore.snapshot() }
    var recentWarning: String? {
        recentStore.loadError.map { "Could not load recent panes: \($0.localizedDescription)" } ?? recentSaveWarning
    }

    func switchTo(_ pane: Pane, clientID: String, rexApp: NSRunningApplication, measured: Bool) async -> Outcome {
        var activationDuration: Duration = .zero
        var rpcTimings: RexSwitchTimings?
        do {
            try Task.checkCancellation()
            guard !rexApp.isTerminated else { throw PickerError("The selected Rex app is no longer running.") }
            let activationStarted = measured ? ContinuousClock.now : nil
            do {
                defer {
                    if let activationStarted { activationDuration = activationStarted.duration(to: .now) }
                }
                try await activate(rexApp)
            }
            try Task.checkCancellation()
            if measured {
                let measurement = await backend.measuredSwitchTo(pane, clientID: clientID)
                rpcTimings = measurement.timings
                try measurement.result.get()
            } else {
                try await backend.switchTo(pane, clientID: clientID)
            }
            do {
                try recentStore.record(pane)
                recentSaveWarning = nil
            } catch {
                recentSaveWarning = "Could not save recent panes: \(error.localizedDescription)"
            }
            return Outcome(result: .success(()), nativeActivation: activationDuration,
                           rpc: rpcTimings, recentWarning: recentSaveWarning)
        } catch {
            return Outcome(result: .failure(error), nativeActivation: activationDuration,
                           rpc: rpcTimings, recentWarning: nil)
        }
    }

    private static func activateRex(_ app: NSRunningApplication) async throws {
        guard !app.isActive else { return }
        // Rex must be active before selecting its terminal first responder.
        NSApp.yieldActivation(to: app)
        guard app.activate(options: []) else { throw PickerError("Could not activate Rex.") }
        let deadline = ContinuousClock.now + .seconds(2)
        while !app.isActive {
            try Task.checkCancellation()
            guard !app.isTerminated, ContinuousClock.now < deadline else {
                throw PickerError("Rex did not become active.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
