import Testing
@testable import PaneSwitchCore

struct PaneSelectionTests {
    private func pane(_ id: String, host: String = "Local", title: String = "Terminal") -> Pane {
        Pane(host: RexHost(id: "host-\(id)", label: host, server: nil),
             sessionID: "session", sessionLabel: "Work", windowID: "window", windowLabel: "Shell",
             blockID: id, label: "Shell", title: title, command: "zsh", directory: "/Users/me")
    }

    @Test func automaticSelectionFollowsFirstRowAsHostsArrive() {
        var selection = PaneSelection()
        selection.resetForQuery()
        let beta = pane("beta", host: "Beta")
        let alpha = pane("alpha", host: "Alpha")
        #expect(selection.selectedRow(in: []) == nil)
        #expect(selection.selectedRow(in: [beta]) == 0)

        let arrivals = PaneSearch.results([beta, alpha], query: "")
        #expect(arrivals.map(\.blockID) == ["alpha", "beta"])
        #expect(selection.selectedRow(in: arrivals) == 0)
    }

    @Test func automaticSelectionFollowsMetadataRankingChanges() {
        var selection = PaneSelection()
        selection.resetForQuery()
        let original = pane("original", title: "a___b___c")
        let pending = pane("pending", title: "a________b________c")
        let initial = PaneSearch.results([pending, original], query: "abc")
        #expect(initial.map(\.blockID) == ["original", "pending"])
        #expect(selection.selectedRow(in: initial) == 0)

        let updated = pane("pending", title: "abc")
        let ranked = PaneSearch.results([original, updated], query: "abc")
        #expect(ranked.map(\.blockID) == ["pending", "original"])
        #expect(selection.selectedRow(in: ranked) == 0)
    }

    @Test func explicitSelectionPreservesIdentityAcrossInsertionsAndReordering() {
        var selection = PaneSelection()
        let alpha = pane("alpha", host: "Alpha")
        let beta = pane("beta", host: "Beta")
        let gamma = pane("gamma", host: "Gamma")
        selection.choose(beta)
        #expect(selection.selectedRow(in: [beta, gamma]) == 0)
        #expect(selection.selectedRow(in: [alpha, beta, gamma]) == 1)
        #expect(selection.selectedRow(in: [gamma, alpha, beta]) == 2)
        #expect(selection.selectedRow(in: [alpha, gamma]) == nil)
        #expect(selection.selectedRow(in: [beta, alpha, gamma]) == 0)
    }

    @Test func queryEditResetsManualSelectionToTopRankedResult() {
        var selection = PaneSelection()
        let exact = pane("exact", title: "abc")
        let spread = pane("spread", title: "a________b________c")
        selection.choose(spread)
        let ranked = PaneSearch.results([spread, exact], query: "abc")
        #expect(selection.selectedRow(in: ranked) == 1)

        selection.resetForQuery()
        #expect(selection.selectedRow(in: ranked) == 0)
        #expect(selection.selectedRow(in: []) == nil)
        #expect(selection.selectedRow(in: ranked) == 0)
    }

    @Test func failedSwitchRefreshNeverSelectsASubstituteUntilDeliberateInput() {
        var selection = PaneSelection()
        let failed = pane("failed")
        let replacement = pane("replacement")
        selection.choose(failed)
        selection.suspendAfterFailure()
        #expect(selection.selectedRow(in: [failed]) == nil)
        #expect(selection.selectedRow(in: []) == nil)
        #expect(selection.selectedRow(in: [replacement]) == nil)
        #expect(selection.selectedRow(in: [replacement, failed]) == nil)

        selection.choose(replacement)
        #expect(selection.selectedRow(in: [replacement, failed]) == 0)
        selection.suspendAfterFailure()
        #expect(selection.selectedRow(in: [replacement]) == nil)
        selection.resetForQuery()
        #expect(selection.selectedRow(in: [replacement]) == 0)
    }
}
