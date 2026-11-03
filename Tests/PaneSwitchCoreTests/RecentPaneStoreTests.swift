import Foundation
import Testing
@testable import PaneSwitchCore

struct RecentPaneStoreTests {
    private let local = RexHost(id: "local", label: "Mac", server: nil)
    private let remote = RexHost(id: "remote", label: "Remote", server: "remote")

    private func pane(_ id: String, host: RexHost) -> Pane {
        Pane(host: host, sessionID: "session", sessionLabel: "Work",
             windowID: "window", windowLabel: "Editor", blockID: id,
             label: "Shell", title: id, command: "zsh", directory: "/projects")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func absentHistoryStartsEmptyAndPersistsSelectionsAcrossInstances() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/recent.json")
        let store = RecentPaneStore(url: url)
        #expect(store.loadError == nil)
        #expect(store.snapshot().isEmpty)
        let first = pane("first", host: local)
        let second = pane("second", host: remote)
        try store.record(first)
        try store.record(second)
        try store.record(first)
        #expect(store.snapshot() == [first.id, second.id])
        let reloaded = RecentPaneStore(url: url)
        #expect(reloaded.loadError == nil)
        #expect(reloaded.snapshot() == [first.id, second.id])
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)) == [first.id, second.id])
    }

    @Test func historyIsBoundedToTheLatestHundredDistinctPaneIDs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent.json")
        let store = RecentPaneStore(url: url)
        for number in 0...100 { try store.record(pane("\(number)", host: local)) }
        #expect(store.snapshot().count == 100)
        #expect(store.snapshot().first == "local/100")
        #expect(store.snapshot().last == "local/1")
        #expect(!store.snapshot().contains("local/0"))
        try store.record(pane("50", host: local))
        #expect(Array(store.snapshot().prefix(3)) == ["local/50", "local/100", "local/99"])
        #expect(store.snapshot().count == 100)
        #expect(RecentPaneStore(url: url).snapshot() == store.snapshot())
    }

    @Test func existingDuplicateAndOversizedHistoryIsNormalizedWithoutInventingInventory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent.json")
        let ids = ["stale/id", "local/first", "stale/id", "local/first"] + (0...100).map { "remote/\($0)" }
        try JSONEncoder().encode(ids).write(to: url)
        let store = RecentPaneStore(url: url)
        #expect(store.snapshot().count == 100)
        #expect(Array(store.snapshot().prefix(4)) == ["stale/id", "local/first", "remote/0", "remote/1"])
        #expect(store.snapshot().last == "remote/97")
        try store.record(pane("first", host: local))
        #expect(Array(store.snapshot().prefix(3)) == ["local/first", "stale/id", "remote/0"])
        #expect(RecentPaneStore(url: url).snapshot() == store.snapshot())
    }

    @Test func corruptHistoryIsReportedAndNeverSilentlyOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recent.json")
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: url)
        let store = RecentPaneStore(url: url)
        #expect(store.loadError != nil)
        #expect(store.snapshot().isEmpty)
        #expect(throws: (any Error).self) { try store.record(pane("first", host: local)) }
        #expect(try Data(contentsOf: url) == corrupt)
        #expect(store.snapshot().isEmpty)
    }

    @Test func failedPersistenceDoesNotChangeTheInMemoryOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("nested")
        let url = parent.appendingPathComponent("recent.json")
        let store = RecentPaneStore(url: url)
        let first = pane("first", host: local)
        try store.record(first)
        try FileManager.default.removeItem(at: parent)
        try Data("blocks the history directory".utf8).write(to: parent)
        #expect(throws: (any Error).self) { try store.record(pane("second", host: local)) }
        #expect(store.snapshot() == [first.id])
    }

    @Test func recencyReordersOnlyWithinEachExistingContiguousHostGroup() {
        let a = pane("a", host: local)
        let b = pane("b", host: local)
        let c = pane("c", host: local)
        let d = pane("d", host: local)
        let e = pane("e", host: remote)
        let f = pane("f", host: remote)
        let g = pane("g", host: local)
        let h = pane("h", host: local)
        let inventory = [a, b, c, d, e, f, g, h]
        let recent = [h.id, "stale/id", c.id, f.id, b.id, c.id, g.id]
        #expect(RecentPaneStore.order(inventory, recentIDs: recent).map(\.id)
                == [c.id, b.id, a.id, d.id, f.id, e.id, h.id, g.id])
        #expect(RecentPaneStore.order(inventory, recentIDs: []).map(\.id) == inventory.map(\.id))
        #expect(RecentPaneStore.order(inventory, recentIDs: ["stale/id"]).map(\.id) == inventory.map(\.id))
        #expect(RecentPaneStore.order([], recentIDs: recent).isEmpty)
    }

    @Test func groupingUsesHostIdentityAndRepeatedInventoryIDsRemainStable() {
        let sameLabel = RexHost(id: "another", label: local.label, server: nil)
        let a = pane("a", host: local)
        let b = pane("b", host: local)
        let other = pane("other", host: sameLabel)
        #expect(RecentPaneStore.order([a, a, b, other], recentIDs: [other.id, b.id, b.id]).map(\.id)
                == [b.id, a.id, a.id, other.id])
    }
}
