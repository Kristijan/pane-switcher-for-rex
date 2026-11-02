import Testing
@testable import PaneSwitchCore

struct PaneGroupedListTests {
    private let local = RexHost(id: "local", label: "Work", server: nil)
    private let alpha = RexHost(id: "alpha", label: "Shared", server: "alpha")
    private let beta = RexHost(id: "beta", label: "Shared", server: "beta")

    private func pane(_ id: String, host: RexHost, title: String = "Terminal") -> Pane {
        Pane(host: host, sessionID: "session", sessionLabel: "Work", windowID: "window",
             windowLabel: "Shell", blockID: id, label: "Shell", title: title,
             command: "zsh", directory: "/work")
    }

    @Test func statusOnlyHostsRemainVisibleAndNonselectable() {
        let list = PaneGroupedList(rankedPanes: [], additionalHosts: [beta, local, alpha, beta], browsing: true)
        #expect(list.panes.isEmpty)
        #expect(list.rows == [.host(local), .host(alpha), .host(beta)])
        for row in list.rows.indices { #expect(list.paneIndex(forRow: row) == nil) }
        #expect(list.row(forPaneIndex: 0) == nil)
    }

    @Test func pendingLocalHostPrecedesRemotePanesWhenBrowsing() {
        let list = PaneGroupedList(rankedPanes: [pane("remote", host: alpha)],
                                   additionalHosts: [beta, local, alpha], browsing: true)
        #expect(list.rows == [.host(local), .host(alpha), .pane(index: 0), .host(beta)])
        #expect(list.row(forPaneIndex: 0) == 2)
    }

    @Test func statusHeadingsNeverInterruptRankedPaneResults() {
        let ranked = [pane("best", host: beta), pane("next", host: alpha), pane("weak", host: beta)]
        let list = PaneGroupedList(rankedPanes: ranked, additionalHosts: [local, alpha, beta])
        #expect(list.panes == ranked)
        #expect(list.rows == [.host(beta), .pane(index: 0), .host(alpha), .pane(index: 1),
                              .host(beta), .pane(index: 2), .host(local)])
    }

    @Test func disappearingInventoryKeepsTheFailedHostHeading() {
        let populated = PaneGroupedList(rankedPanes: [pane("one", host: alpha)], additionalHosts: [alpha])
        let failed = PaneGroupedList(rankedPanes: [], additionalHosts: [alpha])
        #expect(failed.rows == [.host(alpha)])
        #expect(!failed.hasSameLayout(as: populated))
        let renamed = RexHost(id: alpha.id, label: "Offline", server: alpha.server)
        #expect(failed.hasSameLayout(as: PaneGroupedList(rankedPanes: [], additionalHosts: [renamed])))
    }

    @Test func metadataChangesPreserveLayout() {
        let original = PaneGroupedList(rankedPanes: [pane("one", host: alpha)])
        let renamedHost = RexHost(id: alpha.id, label: "Renamed", server: "new-server", icon: "desktop")
        let updatedPane = Pane(host: renamedHost, sessionID: "other-session", sessionLabel: "Updated session",
                               windowID: "other-window", windowLabel: "Updated window", blockID: "one",
                               label: "Editor", title: "Editing", command: "vim", directory: "/other")
        let updated = PaneGroupedList(rankedPanes: [updatedPane])
        #expect(original.hasSameLayout(as: updated))
        #expect(updated.hasSameLayout(as: original))
    }

    @Test func reorderingInsertingOrRemovingPanesChangesLayout() {
        let one = pane("one", host: local)
        let two = pane("two", host: local)
        let original = PaneGroupedList(rankedPanes: [one, two])
        #expect(original.hasSameLayout(as: PaneGroupedList(rankedPanes: [one, two])))
        #expect(!original.hasSameLayout(as: PaneGroupedList(rankedPanes: [two, one])))
        #expect(!original.hasSameLayout(as: PaneGroupedList(rankedPanes: [one, pane("new", host: local), two])))
        #expect(!original.hasSameLayout(as: PaneGroupedList(rankedPanes: [one])))
    }

    @Test func identicalBlockIDsOnDifferentHostsDoNotShareLayoutIdentity() {
        let original = PaneGroupedList(rankedPanes: [pane("shared-block", host: alpha)])
        let moved = PaneGroupedList(rankedPanes: [pane("shared-block", host: beta)])
        #expect(!original.hasSameLayout(as: moved))
    }

    @Test func interleavedHostHeadingsRetainTheirRowPositions() {
        let first = pane("first", host: alpha)
        let middle = pane("middle", host: beta)
        let last = pane("last", host: alpha)
        let original = PaneGroupedList(rankedPanes: [first, middle, last])
        let renamedAlpha = RexHost(id: alpha.id, label: "Renamed", server: alpha.server, icon: "desktop")
        let metadataUpdate = PaneGroupedList(rankedPanes: [
            pane("first", host: renamedAlpha), middle, pane("last", host: renamedAlpha),
        ])
        #expect(original.hasSameLayout(as: metadataUpdate))
        #expect(!original.hasSameLayout(as: PaneGroupedList(rankedPanes: [last, middle, first])))
        #expect(!original.hasSameLayout(as: PaneGroupedList(rankedPanes: [first, last, middle])))
    }

    @Test func emptyListsShareLayoutOnlyWithEmptyLists() {
        let empty = PaneGroupedList(rankedPanes: [])
        let populated = PaneGroupedList(rankedPanes: [pane("one", host: local)])
        #expect(empty.hasSameLayout(as: PaneGroupedList(rankedPanes: [])))
        #expect(!empty.hasSameLayout(as: populated))
        #expect(!populated.hasSameLayout(as: empty))
    }

    @Test func headingsMapOnlyPaneRowsAndNeverConsumePaneIndexes() {
        let list = PaneGroupedList(rankedPanes: [pane("one", host: local), pane("two", host: local),
                                               pane("three", host: alpha)])
        #expect(list.rows == [.host(local), .pane(index: 0), .pane(index: 1),
                              .host(alpha), .pane(index: 2)])
        #expect(list.paneIndex(forRow: 0) == nil)
        #expect(list.paneIndex(forRow: 1) == 0)
        #expect(list.paneIndex(forRow: 2) == 1)
        #expect(list.paneIndex(forRow: 3) == nil)
        #expect(list.paneIndex(forRow: 4) == 2)
        #expect(list.row(forPaneIndex: 0) == 1)
        #expect(list.row(forPaneIndex: 1) == 2)
        #expect(list.row(forPaneIndex: 2) == 4)
        #expect(list.paneIndex(forRow: -1) == nil)
        #expect(list.paneIndex(forRow: 5) == nil)
        #expect(list.row(forPaneIndex: -1) == nil)
        #expect(list.row(forPaneIndex: 3) == nil)
        let empty = PaneGroupedList(rankedPanes: [])
        #expect(empty.rows.isEmpty)
        #expect(empty.panes.isEmpty)
        #expect(empty.paneIndex(forRow: 0) == nil)
        #expect(empty.row(forPaneIndex: 0) == nil)
    }

    @Test func headingsDoNotPromoteWeakerMatchesFromPreviouslySeenHosts() {
        let inventory = [pane("alpha-weak", host: alpha, title: "a_____b_____c"),
                         pane("beta-middle", host: beta, title: "a_b_c"),
                         pane("alpha-best", host: alpha, title: "abc")]
        let list = PaneGroupedList(rankedPanes: PaneSearch.results(inventory, query: "abc"))
        #expect(list.panes.map(\.blockID) == ["alpha-best", "beta-middle", "alpha-weak"])
        #expect(list.rows == [.host(alpha), .pane(index: 0),
                              .host(beta), .pane(index: 1),
                              .host(alpha), .pane(index: 2)])
    }

    @Test func searchRankingDeterminesGroupOrderAndPreservesRankingWithinEachHost() {
        let inventory = [pane("alpha-spread", host: alpha, title: "a_____b_____c"),
                         pane("beta-best", host: beta, title: "abc"),
                         pane("alpha-next", host: alpha, title: "a_b_c"),
                         pane("beta-next", host: beta, title: "ab__c"),
                         pane("excluded", host: local, title: "Terminal")]
        let filtered = PaneGroupedList(rankedPanes: PaneSearch.results(inventory, query: "abc"))
        #expect(filtered.panes.map(\.blockID) == ["beta-best", "beta-next", "alpha-next", "alpha-spread"])
        #expect(filtered.rows.first == .host(beta))
        #expect(filtered.rows.count == 6)
        let unfiltered = PaneGroupedList(rankedPanes: PaneSearch.results(inventory, query: ""))
        #expect(unfiltered.rows.first == .host(local))
        #expect(unfiltered.panes.map(\.blockID) == ["excluded", "alpha-spread", "alpha-next", "beta-next", "beta-best"])
    }

    @Test func selectionTracksPaneIdentityWhenGroupsArriveAndMetadataChanges() {
        let chosen = pane("chosen", host: beta, title: "a_b_c")
        let initial = PaneGroupedList(rankedPanes: [chosen])
        var selection = PaneSelection()
        #expect(selection.selectedRow(in: initial.panes).flatMap(initial.row(forPaneIndex:)) == 1)
        selection.choose(chosen)
        let updated = pane("chosen", host: beta, title: "abc")
        let changed = PaneGroupedList(rankedPanes: [pane("local", host: local), pane("alpha", host: alpha), updated])
        #expect(selection.selectedRow(in: changed.panes).flatMap(changed.row(forPaneIndex:)) == 5)
        let removed = PaneGroupedList(rankedPanes: [pane("local", host: local)])
        #expect(selection.selectedRow(in: removed.panes) == nil)
        #expect(selection.selectedRow(in: changed.panes).flatMap(changed.row(forPaneIndex:)) == 5)
        selection.suspendAfterFailure()
        #expect(selection.selectedRow(in: changed.panes) == nil)
        selection.resetForQuery()
        #expect(selection.selectedRow(in: changed.panes).flatMap(changed.row(forPaneIndex:)) == 1)
    }
}
