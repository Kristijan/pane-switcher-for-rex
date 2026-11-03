import Foundation

/// A local-only, read-only check. It never starts the inventory or touches panes.
public enum RexSetupProbe {
    public static func appClients(executable: URL) async throws -> [RexClient] {
        let connection = RexConnection(executable: executable, host: RexHost(id: "local", label: "This Mac", server: nil))
        return try await appClients(connection: connection)
    }

    static func appClients(connection: any RexInventoryConnection) async throws -> [RexClient] {
        defer { connection.shutdown() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let object = try await connection.execute(clientsScript, arguments: [:], timeout: 5)
            try Task.checkCancellation()
            return try parseClients(object)
        } onCancel: { connection.shutdown() }
    }

    static let clientsScript = #"""
    local result, err = rex.call("client.list")
    if not result then error(err or "Could not list clients", 0) end
    return result
    """#

    static func parseClients(_ object: [String: Any]) throws -> [RexClient] {
        try rexArray(object["clients"], field: "clients").compactMap { value in
            guard let client = value as? [String: Any], let info = client["info"] as? [String: Any],
                  info["kind"] as? String == "app", info["platform"] as? String == "macos",
                  let id = rexNonempty(client["client_id"]) else { return nil }
            let principal = client["principal"] as? [String: Any]
            let pid = (principal?["pid"] as? NSNumber).flatMap { Int32(exactly: $0.int64Value) }
            return RexClient(id: id, label: rexNonempty(info["label"]) ?? rexNonempty(info["name"]) ?? id, pid: pid)
        }
    }
}
