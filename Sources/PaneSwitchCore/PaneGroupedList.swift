import Foundation

public struct PaneGroupedList: Sendable {
    public enum Row: Equatable, Sendable {
        case host(RexHost)
        case pane(index: Int)
    }

    public let panes: [Pane]
    public let rows: [Row]
    private let paneRows: [Int]

    /// Preserves ranked pane order, adding a heading whenever the host changes.
    /// Hosts without panes remain visible as nonselectable status headings. In browsing mode
    /// those headings use local-first host order; ranked searches append them after all results.
    public init(rankedPanes: [Pane], additionalHosts: [RexHost] = [], browsing: Bool = false) {
        var seenHostIDs = Set<String>()
        if !additionalHosts.isEmpty {
            for pane in rankedPanes { seenHostIDs.insert(pane.host.id) }
        }
        var statusHosts: [HostOrder] = []
        statusHosts.reserveCapacity(additionalHosts.count)
        for host in additionalHosts where seenHostIDs.insert(host.id).inserted {
            statusHosts.append(HostOrder(host))
        }
        statusHosts.sort(by: Self.hostPrecedes)
        var nextStatusHost = 0
        var rows: [Row] = []
        var paneRows: [Int] = []
        rows.reserveCapacity(rankedPanes.count * 2 + statusHosts.count)
        paneRows.reserveCapacity(rankedPanes.count)
        var previousHostID: String?
        for (index, pane) in rankedPanes.enumerated() {
            if pane.host.id != previousHostID {
                if browsing, nextStatusHost < statusHosts.count {
                    let hostOrder = HostOrder(pane.host)
                    while nextStatusHost < statusHosts.count,
                          Self.hostPrecedes(statusHosts[nextStatusHost], hostOrder) {
                        rows.append(.host(statusHosts[nextStatusHost].host))
                        nextStatusHost += 1
                    }
                }
                rows.append(.host(pane.host))
                previousHostID = pane.host.id
            }
            paneRows.append(rows.count)
            rows.append(.pane(index: index))
        }
        for ordered in statusHosts.dropFirst(nextStatusHost) { rows.append(.host(ordered.host)) }
        self.panes = rankedPanes
        self.rows = rows
        self.paneRows = paneRows
    }

    private struct HostOrder {
        let host: RexHost
        let foldedLabel: String

        init(_ host: RexHost) {
            self.host = host
            foldedLabel = host.label.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                             locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    private static func hostPrecedes(_ lhs: HostOrder, _ rhs: HostOrder) -> Bool {
        if (lhs.host.server == nil) != (rhs.host.server == nil) { return lhs.host.server == nil }
        return (lhs.foldedLabel, lhs.host.label, lhs.host.id) < (rhs.foldedLabel, rhs.host.label, rhs.host.id)
    }

    /// Compares row kinds and host/pane identities in order, ignoring display metadata.
    public func hasSameLayout(as other: PaneGroupedList) -> Bool {
        guard rows.count == other.rows.count else { return false }
        for row in rows.indices {
            switch (rows[row], other.rows[row]) {
            case (.host(let host), .host(let otherHost)):
                guard host.id == otherHost.id else { return false }
            case (.pane(let index), .pane(let otherIndex)):
                let pane = panes[index]
                let otherPane = other.panes[otherIndex]
                guard pane.host.id == otherPane.host.id,
                      pane.blockID == otherPane.blockID else { return false }
            default:
                return false
            }
        }
        return true
    }

    public func paneIndex(forRow row: Int) -> Int? {
        guard rows.indices.contains(row), case .pane(let index) = rows[row] else { return nil }
        return index
    }

    public func row(forPaneIndex index: Int) -> Int? {
        guard paneRows.indices.contains(index) else { return nil }
        return paneRows[index]
    }
}
