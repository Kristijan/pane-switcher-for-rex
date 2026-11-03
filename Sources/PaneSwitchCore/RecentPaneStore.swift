import Foundation

/// Successful pane selections, stored independently of the current pane inventory.
/// The owner records only after a switch succeeds and reports `loadError` to the user.
public final class RecentPaneStore {
    private static let limit = 100
    private let url: URL
    private var ids: [String] = []

    /// A malformed or unreadable history is left untouched, including on subsequent records.
    public let loadError: Error?

    public convenience init(storage: ApplicationStorage = ApplicationStorage()) {
        self.init(url: storage.recentPanesURL)
    }

    public init(url: URL) {
        self.url = url
        do {
            let data = try Data(contentsOf: url)
            ids = Self.boundedUnique(try JSONDecoder().decode([String].self, from: data))
            loadError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loadError = nil
        } catch {
            loadError = error
        }
    }

    public func snapshot() -> [String] { ids }

    /// Commit memory only after the atomic file replacement succeeds.
    public func record(_ pane: Pane) throws {
        if let loadError { throw loadError }
        let id = pane.id
        var updated = [id]
        updated.reserveCapacity(Self.limit)
        for existing in ids where existing != id {
            guard updated.count < Self.limit else { break }
            updated.append(existing)
        }
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        ids = updated
    }

    /// Preserve the incoming host groups (including repeated groups), changing only their pane order.
    public static func order(_ panes: [Pane], recentIDs: [String]) -> [Pane] {
        guard panes.count > 1, !recentIDs.isEmpty else { return panes }
        var ranks: [String: Int] = [:]
        for (rank, id) in recentIDs.enumerated() where ranks[id] == nil { ranks[id] = rank }
        // Cache identity lookups once per pane, rather than rebuilding IDs in the sort comparator.
        var ranked = panes.enumerated().map {
            (index: $0.offset, pane: $0.element, rank: ranks[$0.element.id] ?? Int.max)
        }
        var start = 0
        while start < ranked.count {
            let hostID = ranked[start].pane.host.id
            var end = start + 1
            while end < ranked.count, ranked[end].pane.host.id == hostID { end += 1 }
            ranked[start..<end].sort {
                $0.rank == $1.rank ? $0.index < $1.index : $0.rank < $1.rank
            }
            start = end
        }
        return ranked.map(\.pane)
    }

    private static func boundedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(min(limit, values.count))
        for id in values where seen.insert(id).inserted {
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }
}
