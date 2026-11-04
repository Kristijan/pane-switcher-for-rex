import Testing
@testable import PaneSwitchCore

struct PaneDiscoverySnapshotTests {
    @Test func availabilityClearsStalePanesAndRemovedHostsWithoutChangingFrozenSnapshot() {
        let local = RexHost(id: "local", label: "This Mac", server: nil)
        let remote = RexHost(id: "remote", label: "Remote", server: "Remote")
        let pane = pane("one", host: remote)
        var latest = PaneDiscoverySnapshot()
        latest.receive(.hosts([remote, local]))
        #expect(latest.hostStates["local"] == .connecting)
        latest.receive(.panes(remote, [pane]))
        let frozen = latest
        latest.receive(.failed(remote, "Connection lost"))
        #expect(latest.inventories["remote"] == nil)
        #expect(latest.hostStates["remote"] == .unavailable("Connection lost"))
        #expect(frozen.inventories["remote"] == [pane])
        #expect(frozen.hostStates["remote"] == .ready)
        latest.receive(.panes(remote, []))
        #expect(latest.hostStates["remote"] == .ready)
        #expect(latest.inventories["remote"]?.isEmpty == true)
        latest.receive(.hosts([local]))
        #expect(latest.hosts["remote"] == nil)
        #expect(latest.hostStates["remote"] == nil)
        #expect(latest.inventories["remote"] == nil)
    }

    @Test func browsingGroupsSameNamedHostsOnceAndKeepsPickerSessionTabPaneOrder() {
        let local = RexHost(id: "local", label: "This Mac", server: nil)
        let alpha = RexHost(id: "alpha", label: "alpha", server: "alpha")
        let beta = RexHost(id: "beta", label: "Beta", server: "Beta")
        let otherAlpha = RexHost(id: "alpha-two", label: "alpha", server: "other")
        var snapshot = PaneDiscoverySnapshot()
        snapshot.receive(.hosts([beta, otherAlpha, alpha, local]))
        snapshot.receive(.panes(alpha, [pane("z", host: alpha, session: "Z"), pane("a", host: alpha, session: "A")]))
        snapshot.receive(.panes(otherAlpha, [pane("b", host: otherAlpha, session: "B")]))
        snapshot.receive(.panes(local, [pane("local", host: local)]))
        let list = snapshot.browsingList
        #expect(list.rows == [.host(local), .pane(index: 0), .host(alpha), .pane(index: 1), .pane(index: 2),
                              .host(otherAlpha), .pane(index: 3)])
        #expect(list.panes.map(\.blockID) == ["local", "a", "z", "b"])
    }

    @Test func browsingOmitsConnectingUnavailableAndReadyEmptyHosts() {
        let local = RexHost(id: "local", label: "This Mac", server: nil)
        let remote = RexHost(id: "remote", label: "Remote", server: "Remote")
        var snapshot = PaneDiscoverySnapshot()
        snapshot.receive(.hosts([local, remote]))
        #expect(snapshot.browsingList.rows.isEmpty)
        snapshot.receive(.panes(local, []))
        #expect(snapshot.browsingList.rows.isEmpty)
        snapshot.receive(.failed(remote, "Offline"))
        #expect(snapshot.browsingList.rows.isEmpty)
        snapshot.receive(.panes(local, [pane("one", host: local)]))
        #expect(snapshot.browsingList.rows == [.host(local), .pane(index: 0)])
        snapshot.receive(.panes(local, []))
        #expect(snapshot.browsingList.rows.isEmpty)
    }

    @Test func hostDiscoveryWarningsAreReplacedWithoutLosingMetadataWarning() {
        var snapshot = PaneDiscoverySnapshot()
        snapshot.receive(.warning("Pane metadata is unavailable"))
        snapshot.receive(.hostDiscoveryWarnings(["Host lookup failed"]))
        snapshot.receive(.hostDiscoveryWarnings([]))
        snapshot.receive(.finished)
        #expect(snapshot.hostDiscoveryWarnings.isEmpty)
        #expect(snapshot.warning == "Pane metadata is unavailable")
        #expect(!snapshot.isDiscovering)
    }

    private func pane(_ id: String, host: RexHost, session: String = "Work") -> Pane {
        Pane(host: host, sessionID: session, sessionLabel: session, windowID: "tab", windowLabel: "Shell",
             blockID: id, label: id, title: "", command: "", directory: "")
    }
}
