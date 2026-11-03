import Foundation

/// The actual RPC waits for one switch, excluding native application activation.
public struct RexSwitchTimings: Equatable, Sendable {
    public private(set) var localRPC: Duration = .zero
    public private(set) var remoteRPC: Duration = .zero
    public private(set) var localRequests = 0
    public private(set) var remoteRequests = 0

    public init() {}

    mutating func record(_ duration: Duration, remote: Bool) {
        if remote {
            remoteRPC += duration
            remoteRequests += 1
        } else {
            localRPC += duration
            localRequests += 1
        }
    }
}

/// A switch's original result together with all RPC waits, including a failed final request.
public struct RexSwitchMeasurement: Sendable {
    public let result: Result<Void, any Error>
    public let timings: RexSwitchTimings
}

/// One latest sample per operation; retained by the picker across invocations.
/// Callers only collect samples when the user's debug setting is enabled.
public struct PickerDiagnostics: Equatable, Sendable {
    public private(set) var launch: Duration?
    public private(set) var query: Duration?
    public private(set) var switchTotal: Duration?
    public private(set) var nativeActivation: Duration?
    public private(set) var switchRPC: RexSwitchTimings?

    public init() {}

    public mutating func recordLaunch(_ duration: Duration) { launch = duration }
    public mutating func recordQuery(_ duration: Duration) { query = duration }

    public mutating func recordSwitch(total: Duration, nativeActivation: Duration, rpc: RexSwitchTimings?) {
        switchTotal = total
        self.nativeActivation = nativeActivation
        switchRPC = rpc
    }

    public var lines: [String] {
        var result: [String] = []
        if let launch { result.append("Launch request → visible: \(Self.milliseconds(launch))") }
        if let query { result.append("Query update: \(Self.milliseconds(query))") }
        if let switchTotal { result.append("Switch total: \(Self.milliseconds(switchTotal))") }
        if let nativeActivation { result.append("Native Rex activation: \(Self.milliseconds(nativeActivation))") }
        if let switchRPC {
            if switchRPC.localRequests > 0 { result.append("Local RPC: \(Self.milliseconds(switchRPC.localRPC))") }
            if switchRPC.remoteRequests > 0 { result.append("Remote RPC: \(Self.milliseconds(switchRPC.remoteRPC))") }
        }
        return result
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.2f ms", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
