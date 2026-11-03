import Foundation

/// The current presentation of the backend's warm inventory. Consumers may keep a value copy
/// while interacting with it; receiving events never changes an already displayed snapshot.
public struct PaneDiscoverySnapshot: Sendable {
    public private(set) var hosts: [String: RexHost] = [:]
    public private(set) var hostStates: [String: PickerHostState] = [:]
    public private(set) var inventories: [String: [Pane]] = [:]
    public private(set) var warning: String?
    public private(set) var hostDiscoveryWarnings: [String] = []
    public private(set) var isDiscovering = true

    public init() {}

    public mutating func receive(_ event: DiscoveryEvent) {
        switch event {
        case .hosts(let discovered):
            let ids = Set(discovered.map(\.id))
            hosts = hosts.filter { ids.contains($0.key) }
            hostStates = hostStates.filter { ids.contains($0.key) }
            inventories = inventories.filter { ids.contains($0.key) }
            for host in discovered {
                hosts[host.id] = host
                if hostStates[host.id] == nil { hostStates[host.id] = .connecting }
            }
        case .panes(let host, let panes):
            hosts[host.id] = host
            hostStates[host.id] = .ready
            inventories[host.id] = panes
        case .failed(let host, let reason):
            hosts[host.id] = host
            hostStates[host.id] = .unavailable(reason)
            inventories[host.id] = nil
        case .warning(let warning):
            self.warning = warning
        case .hostDiscoveryWarnings(let warnings):
            hostDiscoveryWarnings = warnings
        case .finished:
            isDiscovering = false
        }
    }

    /// Available panes in the picker's stable browsing order, grouped once per host.
    public var browsingList: PaneGroupedList {
        let availableHosts = hosts.values.filter { inventories[$0.id]?.isEmpty == false }
        let orderedHosts = PaneGroupedList(rankedPanes: [], additionalHosts: availableHosts, browsing: true)
        let panesByHost = Dictionary(grouping: PaneSearch.results(inventories.values.flatMap { $0 }, query: ""),
                                     by: { $0.host.id })
        let panes = orderedHosts.rows.flatMap { row -> [Pane] in
            guard case .host(let host) = row else { return [] }
            return panesByHost[host.id] ?? []
        }
        return PaneGroupedList(rankedPanes: panes)
    }
}
