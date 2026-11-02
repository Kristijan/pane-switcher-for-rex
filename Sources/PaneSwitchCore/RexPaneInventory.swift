import Foundation

// Layout snapshots own placement and labels. Terminal events own independently versioned metadata,
// so a late view/metadata reply cannot undo a newer event (including an explicit clearing event).
struct RexPaneInventory {
    let host: RexHost
    private(set) var version: UInt64 = 0
    private var sessionVersions: [String: UInt64] = [:]
    private var sessions: [String: [Pane]] = [:]
    private var order: [String] = []
    private var metadata: [String: TerminalMetadata] = [:]
    private var metadataAttempted = Set<String>()

    init(host: RexHost) { self.host = host }

    var panes: [Pane] {
        order.flatMap { sessions[$0] ?? [] }.map { pane in
            guard let fields = metadata[pane.blockID] else { return pane }
            return replacing(pane, title: fields.title, command: fields.command, directory: fields.directory)
        }
    }

    var sessionIDs: Set<String> { Set(sessions.keys) }

    func contains(_ pane: Pane) -> Bool {
        sessions[pane.sessionID]?.contains { $0.blockID == pane.blockID && $0.windowID == pane.windowID } == true
    }

    mutating func invalidate(sessionID: String) {
        version &+= 1
        sessionVersions[sessionID] = version
    }

    func changed(_ sessionID: String, since snapshot: UInt64) -> Bool {
        (sessionVersions[sessionID] ?? 0) > snapshot
    }

    @discardableResult
    mutating func replace(view: [String: Any], since snapshot: UInt64) throws -> Bool {
        guard let id = rexNonempty(view["session_id"]) else { throw RexBackendError("Rex returned a session without an ID.") }
        guard !changed(id, since: snapshot) else { return false }
        let values = try placedPanes(in: view)
        let old = Set((sessions[id] ?? []).map(\.blockID))
        let current = Set(values.map(\.blockID))
        for removed in old.subtracting(current) {
            metadata.removeValue(forKey: removed)
            metadataAttempted.remove(removed)
        }
        if sessions[id] == nil { order.append(id) }
        sessions[id] = values
        return true
    }

    mutating func removeSession(_ id: String) {
        for pane in sessions.removeValue(forKey: id) ?? [] {
            metadata.removeValue(forKey: pane.blockID)
            metadataAttempted.remove(pane.blockID)
        }
        order.removeAll { $0 == id }
    }

    mutating func removeBlock(_ id: String, sessionID: String?) {
        for key in sessionID.map({ [$0] }) ?? order {
            sessions[key]?.removeAll { $0.blockID == id }
        }
        metadata.removeValue(forKey: id)
        metadataAttempted.remove(id)
    }

    mutating func removeWindow(_ id: String, sessionID: String) {
        let removed = sessions[sessionID]?.filter { $0.windowID == id } ?? []
        for pane in removed { removeBlock(pane.blockID, sessionID: sessionID) }
    }

    func sessionID(for blockID: String) -> String? {
        order.first { sessions[$0]?.contains { $0.blockID == blockID } == true }
    }

    mutating func renameSession(_ id: String, label: String) {
        sessions[id] = sessions[id]?.map { replacing($0, sessionLabel: label.isEmpty ? id : label) }
    }

    mutating func renameWindow(_ id: String, sessionID: String, label: String) {
        sessions[sessionID] = sessions[sessionID]?.map {
            $0.windowID == id ? replacing($0, windowLabel: label.isEmpty ? id : label) : $0
        }
    }

    mutating func takeMetadataRequests() -> [Pane] {
        let values = order.flatMap { sessions[$0] ?? [] }.filter { !metadataAttempted.contains($0.blockID) }
        for pane in values { metadataAttempted.insert(pane.blockID) }
        return values
    }

    mutating func applyMetadata(_ items: [Any], since snapshot: UInt64) {
        let placed = Set(order.flatMap { sessions[$0] ?? [] }.map(\.blockID))
        for value in items {
            guard let item = value as? [String: Any], let id = rexNonempty(item["block_id"]), placed.contains(id) else { continue }
            var fields = metadata[id] ?? TerminalMetadata()
            if fields.titleVersion <= snapshot, let title = item["title"] as? [String: Any] {
                fields.title = rexNonempty(title["title"]) ?? ""
            }
            if fields.pwdVersion <= snapshot, let pwd = item["pwd"] as? [String: Any] {
                fields.pwd = rexNonempty(pwd["pwd"]) ?? ""
            }
            if let process = item["process"] as? [String: Any] {
                if fields.foregroundVersion <= snapshot { fields.foreground = process["foreground"] as? [String: Any] ?? [:] }
                if fields.childVersion <= snapshot { fields.child = process["child"] as? [String: Any] ?? [:] }
            }
            metadata[id] = fields
        }
    }

    @discardableResult
    mutating func applyTerminalEvent(_ event: RexStreamEvent) -> Bool {
        guard let id = event.blockID ?? rexNonempty(event.payload["block_id"]) else { return false }
        version &+= 1
        var fields = metadata[id] ?? TerminalMetadata()
        switch event.type {
        case "terminal.title_changed":
            fields.title = rexNonempty(event.payload["title"]) ?? ""
            fields.titleVersion = version
        case "terminal.pwd_changed":
            fields.pwd = rexNonempty(event.payload["pwd"]) ?? ""
            fields.pwdVersion = version
        case "terminal.process_changed":
            fields.foreground = event.payload["foreground"] as? [String: Any] ?? [:]
            fields.foregroundVersion = version
        case "terminal.child_exited":
            fields.foreground = [:]
            fields.child = [:]
            fields.foregroundVersion = version
            fields.childVersion = version
        default: return false
        }
        metadata[id] = fields
        return sessionID(for: id) != nil
    }

    private func placedPanes(in view: [String: Any]) throws -> [Pane] {
        guard let sessionID = rexNonempty(view["session_id"]) else { throw RexBackendError("Rex returned a session without an ID.") }
        var result: [Pane] = []
        var seen = Set<String>()
        for value in try rexArray(view["windows"], field: "windows", absentIsEmpty: true) {
            guard let window = value as? [String: Any], let windowID = rexNonempty(window["window_id"]) else {
                throw RexBackendError("Rex returned a tab without an ID.")
            }
            for value in try rexArray(window["layers"], field: "layers", absentIsEmpty: true) {
                guard let layer = value as? [String: Any] else { throw RexBackendError("Rex returned an invalid tab layer.") }
                let placed = layoutBlocks(layer["layout"])
                for value in try rexArray(layer["blocks"], field: "blocks", absentIsEmpty: true) {
                    guard let block = value as? [String: Any], let id = rexNonempty(block["block_id"]) else {
                        throw RexBackendError("Rex returned a pane without an ID.")
                    }
                    guard placed.contains(id), seen.insert(id).inserted else { continue }
                    result.append(Pane(host: host, sessionID: sessionID,
                                       sessionLabel: rexNonempty(view["label"]) ?? sessionID,
                                       windowID: windowID, windowLabel: rexNonempty(window["label"]) ?? windowID,
                                       blockID: id, label: rexNonempty(block["label"]) ?? "",
                                       title: "", command: "", directory: ""))
                }
            }
        }
        return result
    }

    private func layoutBlocks(_ value: Any?) -> Set<String> {
        guard let layout = value as? [String: Any] else { return [] }
        if let id = rexNonempty(layout["block_id"]) { return [id] }
        guard let split = layout["split"] as? [String: Any] else { return [] }
        return layoutBlocks(split["before"]).union(layoutBlocks(split["after"]))
    }

    private func replacing(_ pane: Pane, sessionLabel: String? = nil, windowLabel: String? = nil,
                           title: String? = nil, command: String? = nil, directory: String? = nil) -> Pane {
        Pane(host: pane.host, sessionID: pane.sessionID, sessionLabel: sessionLabel ?? pane.sessionLabel,
             windowID: pane.windowID, windowLabel: windowLabel ?? pane.windowLabel, blockID: pane.blockID,
             label: pane.label, title: title ?? pane.title, command: command ?? pane.command,
             directory: directory ?? pane.directory)
    }

    private struct TerminalMetadata {
        var title = ""
        var pwd = ""
        var foreground: [String: Any] = [:]
        var child: [String: Any] = [:]
        var titleVersion: UInt64 = 0
        var pwdVersion: UInt64 = 0
        var foregroundVersion: UInt64 = 0
        var childVersion: UInt64 = 0
        var command: String { rexNonempty(foreground["name"]) ?? rexNonempty(child["name"]) ?? "" }
        var directory: String {
            let value = rexNonempty(pwd) ?? rexNonempty(foreground["cwd"]) ?? rexNonempty(child["cwd"]) ?? ""
            guard let url = URL(string: value), url.isFileURL else { return value }
            return url.path
        }
    }
}

struct RexBackendError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func rexNonempty(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
}

func rexArray(_ value: Any?, field: String, absentIsEmpty: Bool = false) throws -> [Any] {
    if let values = value as? [Any] { return values }
    if value is NSNull || (absentIsEmpty && value == nil) { return [] }
    // Lua serializes empty tables as {}, including empty result collections.
    if let object = value as? [String: Any], object.isEmpty { return [] }
    throw RexBackendError("Rex returned an invalid \(field) collection.")
}
