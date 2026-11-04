import Foundation

public struct RexHost: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let server: String?
    public let icon: String?
    public init(id: String, label: String, server: String?, icon: String? = nil) {
        self.id = id; self.label = label; self.server = server; self.icon = icon
    }
}

public struct Pane: Codable, Hashable, Sendable, Identifiable {
    public let host: RexHost
    public let sessionID: String
    public let sessionLabel: String
    public let windowID: String
    public let windowLabel: String
    public let blockID: String
    public let label: String
    public let title: String
    public let command: String
    public let directory: String
    public var id: String { host.id + "/" + blockID }
    public var primaryText: String {
        let name = title.isEmpty ? label : title
        return name.isEmpty ? (command.isEmpty ? blockID : command) : name
    }
    /// Primary row content shared by the picker and native pane menus.
    public var displayPrimaryText: String {
        let primary = primaryText
        var names = [primary]
        if !label.isEmpty, label != primary { names.append(label) }
        if !command.isEmpty {
            names.removeAll { $0 == "shell" }
            if !names.contains(command) { names.append(command) }
        }
        return names.joined(separator: " — ")
    }
    public var secondaryText: String {
        [host.label, sessionLabel, windowLabel, directory].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Row-only context; raw metadata and search text remain unchanged.
    public func displaySecondaryText(showWorkingDirectory: Bool = true) -> String {
        let generatedLabel = "Window \(windowID.suffix(8))"
        let synthetic = windowLabel == windowID || windowLabel == "Window \(windowID)"
            || windowLabel.caseInsensitiveCompare(generatedLabel) == .orderedSame
        let tab = synthetic ? "" : windowLabel
        return [sessionLabel, tab, showWorkingDirectory ? directory : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    public var searchText: String {
        [label, title, command, directory, host.label, sessionLabel, windowLabel].joined(separator: " ")
    }
    public init(host: RexHost, sessionID: String, sessionLabel: String, windowID: String,
                windowLabel: String, blockID: String, label: String, title: String,
                command: String, directory: String) {
        self.host = host; self.sessionID = sessionID; self.sessionLabel = sessionLabel
        self.windowID = windowID; self.windowLabel = windowLabel; self.blockID = blockID
        self.label = label; self.title = title; self.command = command; self.directory = directory
    }
}

public struct RexClient: Sendable {
    public let id: String
    public let label: String
    public let pid: Int32?
    public init(id: String, label: String, pid: Int32?) {
        self.id = id; self.label = label; self.pid = pid
    }
}

public enum DiscoveryEvent: Sendable {
    case hosts([RexHost])
    case panes(RexHost, [Pane])
    case failed(RexHost, String)
    case warning(String)
    /// Replaces warnings from the latest remote host lookup; an empty list resolves them.
    case hostDiscoveryWarnings([String])
    case finished
}

/// Availability shown beside existing host headings without changing list order.
public enum PickerHostState: Equatable, Sendable {
    case connecting
    case ready
    case unavailable(String)
}
