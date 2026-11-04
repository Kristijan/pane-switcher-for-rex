import AppKit
import Testing
@testable import PaneSwitchCore
@testable import PaneSwitch

@Suite(.serialized)
@MainActor
struct PaneMenuTests {
    @Test func openMenuFreezesWhileReopeningReplaysWarmCacheAcrossPickerAndMenu() async throws {
        let connection = MenuConnection(panes: [MenuPane("one", title: "Original")])
        let probe = MenuBackendProbe(local: connection)
        let fixture = MenuFixture(probe: probe)
        defer { fixture.close() }
        try await fixture.wait { !fixture.snapshot.isDiscovering }
        try await fixture.waitForMenu { _ in fixture.paneItems.first?.title == "Original" }
        let original = try #require(fixture.paneItems.first)
        let initialQueries = connection.queryCount
        #expect(probe.connectionCount == 1)
        #expect(probe.lookupCount == 1)
        connection.emit("terminal.title_changed", session: "session", block: "one", payload: ["title": "Updated live"])
        try await fixture.wait { fixture.snapshot.inventories["local"]?.first?.primaryText == "Updated live" }
        #expect(fixture.paneItems.first === original)
        #expect(original.title == "Original")
        try await fixture.waitForMenu { _ in fixture.paneItems.first?.title == "Updated live — Original" }
        #expect(connection.queryCount == initialQueries)

        let switcher = PaneSwitcher(backend: fixture.backend, recentStore: RecentPaneStore(url: fixture.historyURL))
        let picker = PickerController(backend: fixture.backend, switcher: switcher, settings: PickerSettings(), openSettings: {})
        picker.show(clientID: "client", rexApp: .current, returningTo: nil)
        defer { picker.dismissForSettings() }
        try await fixture.wait {
            NSApp.windows.first { $0.isVisible && $0.title == "Switch Rex Pane" }?.contentView
                .flatMap { $0 as? PickerSurfaceView }?.table.numberOfRows == 2
        }
        picker.dismissForSettings()
        let secondMenu = ShortcutDisplayMenu()
        let secondController = PaneMenuController(backend: fixture.backend, settings: fixture.settings, menu: secondMenu,
            captureTarget: { RexApplicationTarget(frontmost: .current, running: [.current]) }, select: { _, _ in })
        try await fixture.wait {
            secondController.menuWillOpen(secondMenu)
            return secondMenu.items.first?.submenu?.items.first(where: { $0.action != nil })?.title == "Updated live — Original"
        }
        #expect(probe.connectionCount == 1)
        #expect(probe.lookupCount == 1)
        #expect(connection.queryCount == initialQueries)
        #expect(connection.shutdownCount == 0)
    }

    @Test func flatMenuListsOnlyHostsWithAvailablePanesAndDisambiguatesDuplicateTitles() async throws {
        let longTitle = String(repeating: "Long title ", count: 12)
        let connection = MenuConnection(panes: [
            MenuPane("second", session: "second", sessionLabel: "Second", title: "Shell", directory: "/second"),
            MenuPane("first", session: "first", sessionLabel: "First", title: "Shell", directory: "/first"),
            MenuPane("unique", session: "unique", sessionLabel: "Third", title: longTitle, directory: "/a/very/long/path")
        ])
        let alpha = RexHost(id: "alpha", label: "alpha", server: "alpha")
        let beta = RexHost(id: "beta", label: "Beta", server: "beta")
        let gamma = RexHost(id: "gamma", label: "Gamma", server: "gamma")
        let delta = RexHost(id: "delta", label: "Delta", server: "delta")
        let probe = MenuBackendProbe(local: connection, remotes: [
            (delta, MenuConnection(panes: [MenuPane("remote", title: "Remote pane")])),
            (gamma, MenuConnection(panes: [], ready: false)),
            (beta, MenuConnection(panes: [], listingFailure: "Remote is offline")),
            (alpha, MenuConnection(panes: []))
        ])
        let fixture = MenuFixture(probe: probe)
        defer { fixture.close() }
        try await fixture.wait {
            fixture.snapshot.hostStates["local"] == .ready && fixture.snapshot.hostStates["alpha"] == .ready
                && fixture.snapshot.hostStates["beta"] == .unavailable("Remote is offline")
                && fixture.snapshot.hostStates["gamma"] == .connecting
                && fixture.snapshot.inventories["delta"]?.first?.title == "Remote pane"
                && fixture.snapshot.inventories["local"]?.allSatisfy { !$0.title.isEmpty } == true
        }
        fixture.controller.menuWillOpen(fixture.menu)
        let hosts = try #require(fixture.panesMenu)
        #expect(hosts.items.filter(\.isSectionHeader).map(\.title) == ["This Mac", "Delta"])
        #expect(hosts.items.filter(\.isSeparatorItem).count == 1)
        #expect(hosts.items.allSatisfy { $0.submenu == nil })
        #expect(hosts.items.filter(\.isSectionHeader).allSatisfy { !$0.isEnabled && $0.action == nil })
        let localItems = Array(fixture.paneItems.prefix(3))
        #expect(localItems[0].title == "Shell — First · Tab")
        #expect(localItems[1].title == "Shell — Second · Tab")
        #expect(localItems[2].title.count == 72)
        #expect(localItems[2].title.hasSuffix("…"))
        #expect(localItems[2].toolTip?.contains(longTitle) == true)
        #expect(localItems[2].toolTip?.contains("/a/very/long/path") == true)
        #expect(localItems.allSatisfy { $0.image == nil })
        #expect(hosts.items.count == 7)
        #expect(hosts.items[4].isSeparatorItem)
        #expect(hosts.items[5].isSectionHeader)
        #expect(hosts.items[6].title == "Remote pane")

        fixture.target.value = RexApplicationTarget(frontmost: nil, running: [])
        fixture.controller.menuWillOpen(fixture.menu)
        #expect(fixture.panesMenu?.items.map(\.title) == ["Open Rex to browse panes"])
        #expect(fixture.panesMenu?.items.first?.isEnabled == false)
    }

    @Test func renderedTitlesMatchPickerAndRemainingCollisionsUseDirectoryThenStableOrdinal() async throws {
        let connection = MenuConnection(panes: [
            MenuPane("b", title: "shell", directory: "/b", command: "zsh"),
            MenuPane("a", title: "shell", directory: "/a", command: "zsh"),
            MenuPane("same-two", title: "shell", directory: "/same", command: "zsh"),
            MenuPane("same-one", title: "shell", directory: "/same", command: "zsh"),
            MenuPane("custom", session: "custom", sessionLabel: "Other", title: "Build", label: "Task", command: "make")
        ])
        let fixture = MenuFixture(probe: MenuBackendProbe(local: connection))
        defer { fixture.close() }
        try await fixture.wait { !fixture.snapshot.isDiscovering }
        fixture.controller.menuWillOpen(fixture.menu)
        let items = fixture.paneItems
        #expect(items.map(\.title) == ["Build — Task — make", "zsh — Work · Tab · /a", "zsh — Work · Tab · /b",
                                     "zsh — Work · Tab · /same [1]", "zsh — Work · Tab · /same [2]"])
        fixture.controller.menuDidClose(fixture.menu)
        fixture.controller.menuWillOpen(fixture.menu)
        #expect(fixture.paneItems.map(\.title) == items.map(\.title))
    }

    @Test func readyEmptyInventoryUsesGlobalEmptyExplanationRatherThanExtraHost() async throws {
        let fixture = MenuFixture(probe: MenuBackendProbe(local: MenuConnection(panes: [])))
        defer { fixture.close() }
        try await fixture.wait { !fixture.snapshot.isDiscovering }
        try await fixture.waitForMenu { $0.items.first?.title == "No panes available" }
        #expect(fixture.panesMenu?.items.first?.isEnabled == false)
        #expect(fixture.panesMenu?.items.first?.submenu == nil)
    }

    @Test func exactMenuActionKeepsOpeningTargetAndHonorsPaneIcons() async throws {
        let connection = MenuConnection(panes: [MenuPane("one", title: "One"), MenuPane("two", title: "Two")])
        let probe = MenuBackendProbe(local: connection)
        var received: Pane?
        var receivedPID: pid_t?
        var settings = PickerSettings()
        settings.showPaneIcons = true
        let fixture = MenuFixture(probe: probe, settings: settings) { pane, target in
            received = pane
            receivedPID = try? target.resolve().processIdentifier
        }
        defer { fixture.close() }
        try await fixture.waitForMenu { _ in fixture.paneItems.count == 2 }
        let item = try #require(fixture.paneItems.last)
        #expect(item.image != nil)
        fixture.target.value = RexApplicationTarget(frontmost: nil, running: [])
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(received == nil) // Selection runs only after native menu tracking has ended.
        try await fixture.wait { received != nil }
        #expect(received?.blockID == "two")
        #expect(received?.sessionID == "session")
        #expect(received?.windowID == "tab")
        #expect(receivedPID == NSRunningApplication.current.processIdentifier)
        #expect(connection.mutations.isEmpty)
    }

    @Test func staleFrozenMenuSelectionFailsWithoutMutationRetryOrSubstitutePane() async throws {
        let connection = MenuConnection(panes: [MenuPane("one", title: "One"), MenuPane("two", title: "Two")])
        let probe = MenuBackendProbe(local: connection)
        var outcome: PaneSwitcher.Outcome?
        var selected: Pane?
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recent = RecentPaneStore(url: directory.appendingPathComponent("history.json"))
        let backend = probe.makeBackend()
        var activations = 0
        let switcher = PaneSwitcher(backend: backend, recentStore: recent) { _ in activations += 1 }
        let fixture = MenuFixture(probe: probe, backend: backend) { pane, target in
            selected = pane
            Task {
                do {
                    let client = try await target.client(in: backend)
                    outcome = await switcher.switchTo(pane, clientID: client.id, rexApp: client.application, measured: false)
                } catch {
                    Issue.record(error)
                }
            }
        }
        defer { fixture.close() }
        try await fixture.wait { !fixture.snapshot.isDiscovering }
        try await fixture.waitForMenu { _ in fixture.paneItems.count == 2 }
        let stale = try #require(fixture.paneItems.first)
        connection.remove("one")
        connection.emit("block_closed", session: "session", block: "one")
        try await fixture.wait { fixture.snapshot.inventories["local"]?.map(\.blockID) == ["two"] }
        #expect(stale.title == "One")
        #expect(NSApp.sendAction(try #require(stale.action), to: stale.target, from: stale))
        try await fixture.wait { outcome != nil }
        if case .success? = outcome?.result { Issue.record("A stale pane must not be selected") }
        #expect(activations == 1)
        #expect(selected?.blockID == "one")
        #expect(connection.mutations.isEmpty)
        #expect(recent.snapshot().isEmpty)
    }

    @Test func sharedSwitchPathRecordsOnlySuccessAndTreatsHistoryFailureAsWarning() async throws {
        let connection = MenuConnection(panes: [MenuPane("one", title: "One"), MenuPane("two", title: "Two")])
        let probe = MenuBackendProbe(local: connection)
        let fixture = MenuFixture(probe: probe)
        defer { fixture.close() }
        try await fixture.wait { !fixture.snapshot.isDiscovering }
        let pane = try #require(fixture.snapshot.inventories["local"]?.first { $0.blockID == "one" })
        let otherPane = try #require(fixture.snapshot.inventories["local"]?.first { $0.blockID == "two" })
        let recent = RecentPaneStore(url: fixture.historyURL)
        var mutationsAtActivation: [Int] = []
        let activate: @MainActor (NSRunningApplication) async throws -> Void = { _ in
            mutationsAtActivation.append(connection.mutations.count)
        }
        let switcher = PaneSwitcher(backend: fixture.backend, recentStore: recent, activate: activate)
        let success = await switcher.switchTo(pane, clientID: "specific-client", rexApp: .current, measured: true)
        try success.result.get()
        #expect(success.rpc?.localRequests == 1)
        #expect(success.recentWarning == nil)
        #expect(switcher.recentIDs == ["local/one"])
        #expect(connection.mutations == [MenuMutation(session: "session", window: "tab", block: "one", client: "specific-client")])

        let malformed = fixture.directory.appendingPathComponent("malformed.json")
        try Data("not JSON".utf8).write(to: malformed)
        let failingHistory = PaneSwitcher(backend: fixture.backend, recentStore: RecentPaneStore(url: malformed),
                                         activate: activate)
        let warning = await failingHistory.switchTo(pane, clientID: "specific-client", rexApp: .current, measured: false)
        try warning.result.get()
        #expect(warning.recentWarning != nil)
        #expect(connection.mutations.count == 2)
        #expect(try String(contentsOf: malformed, encoding: .utf8) == "not JSON")

        let queriesBeforeFailure = connection.queryCount
        connection.failSwitch()
        let failed = await switcher.switchTo(otherPane, clientID: "specific-client", rexApp: .current, measured: false)
        if case .success = failed.result { Issue.record("The Rex mutation should fail") }
        try await fixture.wait { connection.queryCount > queriesBeforeFailure + 1 }
        #expect(connection.mutations.count == 3)
        #expect(switcher.recentIDs == ["local/one"])
        #expect(failed.recentWarning == nil)
        #expect(mutationsAtActivation == [0, 1, 2])

        let activationFailure = PaneSwitcher(backend: fixture.backend, recentStore: recent,
            activate: { _ in throw MenuActivationFailure.denied })
        let rejected = await activationFailure.switchTo(pane, clientID: "specific-client", rexApp: .current, measured: false)
        if case .failure(let error) = rejected.result {
            #expect(error as? MenuActivationFailure == .denied)
        } else {
            Issue.record("Failed native activation must prevent pane selection")
        }
        #expect(connection.mutations.count == 3)
        #expect(activationFailure.recentIDs == ["local/one"])
    }

    @Test func displayedShortcutDoesNotDispatchAnAppLocalAction() throws {
        _ = NSApplication.shared
        let menu = ShortcutDisplayMenu()
        let shortcut = try PickerShortcut("ctrl+cmd+p")
        menu.pickerShortcut = shortcut
        let target = MenuActionTarget()
        let item = NSMenuItem(title: "Switch Pane…", action: #selector(MenuActionTarget.invoke),
                              keyEquivalent: shortcut.menuKeyEquivalent)
        item.target = target
        item.keyEquivalentModifierMask = shortcut.menuModifierMask
        menu.addItem(item)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shortcut.menuModifierMask, timestamp: 0, windowNumber: 0, context: nil,
            characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        #expect(!menu.performKeyEquivalent(with: event))
        #expect(target.invocations == 0)
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuActionTarget.invoke), keyEquivalent: ",")
        settings.target = target
        menu.addItem(settings)
        let settingsEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
        #expect(menu.performKeyEquivalent(with: settingsEvent))
        #expect(target.invocations == 1)
    }

    @Test func nativeTrackingHandsOffOneShortcutAndDoesNotClaimInactiveRexOnlyScope() throws {
        _ = NSApplication.shared
        let backend = RexBackend(executable: URL(fileURLWithPath: "/usr/bin/true"))
        backend.shutdown()
        let menu = ShortcutDisplayMenu()
        let shortcut = try PickerShortcut("ctrl+cmd+p")
        menu.pickerShortcut = shortcut
        let action = MenuActionTarget()
        let pickerItem = NSMenuItem(title: "Switch Pane…", action: #selector(MenuActionTarget.invoke),
                                    keyEquivalent: shortcut.menuKeyEquivalent)
        pickerItem.keyEquivalentModifierMask = shortcut.menuModifierMask
        pickerItem.target = action
        menu.addItem(pickerItem)
        var transitions: [Bool] = []
        var carbonEnabled = true
        let target = MenuTarget()
        var settings = PickerSettings()
        settings.shortcut = "ctrl+cmd+p"
        settings.globalShortcut = false
        let controller = PaneMenuController(backend: backend, settings: settings, menu: menu, pickerItem: pickerItem,
            trackingChanged: { tracking in transitions.append(tracking); carbonEnabled = !tracking },
            captureTarget: { target.value }, select: { _, _ in })
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shortcut.menuModifierMask, timestamp: 0, windowNumber: 0, context: nil,
            characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        controller.menuWillOpen(menu)
        #expect(!carbonEnabled)
        #expect(pickerItem.keyEquivalent == "p")
        #expect(menu.performKeyEquivalent(with: event))
        controller.menuDidClose(menu)
        #expect(carbonEnabled)
        #expect(action.invocations == 1)
        #expect(!menu.performKeyEquivalent(with: event))
        #expect(action.invocations == 1)
        #expect(transitions == [true, false])
        target.value = RexApplicationTarget(frontmost: nil, running: [.current])
        controller.menuWillOpen(menu)
        #expect(pickerItem.keyEquivalent.isEmpty)
        #expect(pickerItem.isEnabled) // An ordinary menu click still opens the picker.
        #expect(!menu.performKeyEquivalent(with: event))
        #expect(action.invocations == 1)
        #expect(NSApp.sendAction(try #require(pickerItem.action), to: pickerItem.target, from: pickerItem))
        #expect(action.invocations == 2)
        controller.menuDidClose(menu)
        settings.globalShortcut = true
        let global = PaneMenuController(backend: backend, settings: settings, menu: menu, pickerItem: pickerItem,
            captureTarget: { target.value }, select: { _, _ in })
        global.menuWillOpen(menu)
        #expect(pickerItem.keyEquivalent == "p")
        #expect(menu.performKeyEquivalent(with: event))
        #expect(action.invocations == 3)
        global.menuDidClose(menu)
    }
}

private enum MenuActivationFailure: Error, Equatable {
    case denied
}

@MainActor
private final class MenuActionTarget: NSObject {
    var invocations = 0
    @objc func invoke() { invocations += 1 }
}

@MainActor
private final class MenuTarget {
    var value = RexApplicationTarget(frontmost: .current, running: [.current])
}

@MainActor
private final class MenuFixture {
    let backend: RexBackend
    let settings: PickerSettings
    let menu: ShortcutDisplayMenu
    let target: MenuTarget
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var historyURL: URL { directory.appendingPathComponent("history.json") }
    let controller: PaneMenuController
    var snapshot = PaneDiscoverySnapshot()
    private var observer: Task<Void, Never>?
    var panesMenu: NSMenu? { menu.items.first?.submenu }
    var paneItems: [NSMenuItem] { panesMenu?.items.filter { $0.action != nil } ?? [] }

    init(probe: MenuBackendProbe, backend: RexBackend? = nil, settings: PickerSettings? = nil,
         select: @escaping (Pane, RexApplicationTarget) -> Void = { _, _ in }) {
        _ = NSApplication.shared
        let sharedBackend = backend ?? probe.makeBackend()
        self.backend = sharedBackend
        var value = settings ?? PickerSettings()
        if settings == nil { value.showPaneIcons = false }
        self.settings = value
        let menu = ShortcutDisplayMenu()
        let target = MenuTarget()
        self.menu = menu
        self.target = target
        controller = PaneMenuController(backend: sharedBackend, settings: value, menu: menu,
                                       captureTarget: { target.value }, select: select)
        observer = Task { [weak self, backend = self.backend] in
            for await event in backend.discover() {
                guard !Task.isCancelled, let self else { return }
                self.snapshot.receive(event)
            }
        }
    }

    func close() {
        observer?.cancel()
        backend.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RexBackendError("Expected pane-menu state did not arrive")
    }

    func waitForMenu(_ predicate: (NSMenu) -> Bool) async throws {
        try await wait {
            controller.menuWillOpen(menu)
            return panesMenu.map(predicate) ?? false
        }
    }
}

private struct MenuPane: Sendable {
    let block: String
    let session: String
    let sessionLabel: String
    let title: String
    let label: String
    let command: String
    let directory: String
    init(_ block: String, session: String = "session", sessionLabel: String = "Work", title: String,
         directory: String = "/work", label: String? = nil, command: String = "") {
        self.block = block; self.session = session; self.sessionLabel = sessionLabel
        self.title = title; self.directory = directory; self.label = label ?? title; self.command = command
    }
}

private struct MenuMutation: Equatable, Sendable {
    let session: String
    let window: String
    let block: String
    let client: String
}

private final class MenuConnection: RexInventoryConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var panes: [MenuPane]
    private let ready: Bool
    private let listingFailure: String?
    private var switchFails = false
    private var queries = 0
    private var shutdowns = 0
    private var recordedMutations: [MenuMutation] = []
    private let stream: AsyncThrowingStream<RexStreamEvent, Error>
    private let continuation: AsyncThrowingStream<RexStreamEvent, Error>.Continuation

    init(panes: [MenuPane], ready: Bool = true, listingFailure: String? = nil) {
        self.panes = panes; self.ready = ready; self.listingFailure = listingFailure
        let pair = AsyncThrowingStream<RexStreamEvent, Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    var queryCount: Int { lock.withLock { queries } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    var mutations: [MenuMutation] { lock.withLock { recordedMutations } }
    func failSwitch() { lock.withLock { switchFails = true } }
    func remove(_ block: String) { lock.withLock { panes.removeAll { $0.block == block } } }
    func emit(_ type: String, session: String? = nil, block: String? = nil, payload: [String: Any] = [:]) {
        continuation.yield(RexStreamEvent(type: type, sessionID: session, blockID: block, payload: payload))
    }
    func events() -> AsyncThrowingStream<RexStreamEvent, Error> {
        if ready { emit("ready") }
        return stream
    }
    func shutdown() { lock.withLock { shutdowns += 1 }; continuation.finish() }

    func execute(_ script: String, arguments: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try lock.withLock {
            queries += 1
            if script == RexSetupProbe.clientsScript {
                return ["clients": [["client_id": "client", "principal": ["pid": ProcessInfo.processInfo.processIdentifier],
                                     "info": ["kind": "app", "platform": "macos"]]]]
            }
            if let block = arguments["block_id"] as? String {
                let client = arguments["client"] as? [String: Any]
                recordedMutations.append(MenuMutation(session: arguments["session_id"] as? String ?? "",
                    window: arguments["window_id"] as? String ?? "", block: block, client: client?["client_id"] as? String ?? ""))
                if switchFails { throw RexConnectionError.requestFailed("Exact pane is unavailable") }
                return [:]
            }
            if let requests = arguments["panes"] as? [[String: Any]] {
                let ids = Set(requests.compactMap { $0["block_id"] as? String })
                return ["items": panes.filter { ids.contains($0.block) }.map { pane in
                    ["block_id": pane.block, "title": ["title": pane.title], "pwd": ["pwd": pane.directory],
                     "process": ["foreground": ["name": pane.command]]] as [String: Any]
                }, "unavailable": 0]
            }
            if let sessions = arguments["sessions"] as? [String] {
                return ["views": sessions.map { session in
                    let selected = panes.filter { $0.session == session }
                    return ["session_id": session, "label": selected.first?.sessionLabel ?? session, "windows": [
                        ["window_id": "tab", "label": "Tab", "layers": selected.map { pane in
                            ["layout": ["block_id": pane.block], "blocks": [["block_id": pane.block, "label": pane.label]]]
                        }]
                    ]] as [String: Any]
                }, "errors": []]
            }
            if let listingFailure { throw RexConnectionError.disconnected(listingFailure) }
            return ["sessions": Set(panes.map(\.session)).sorted().map { ["session_id": $0] }]
        }
    }
}

private final class MenuBackendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let local: MenuConnection
    private let remotes: [(RexHost, MenuConnection)]
    private var connections = 0
    private var lookups = 0
    init(local: MenuConnection, remotes: [(RexHost, MenuConnection)] = []) { self.local = local; self.remotes = remotes }
    var connectionCount: Int { lock.withLock { connections } }
    var lookupCount: Int { lock.withLock { lookups } }
    func makeBackend() -> RexBackend {
        RexBackend(connectionFactory: { host in
            self.lock.withLock {
                self.connections += 1
                return host.server == nil ? self.local : self.remotes.first { $0.0.id == host.id }!.1
            }
        }, hostLookup: {
            self.lock.withLock {
                self.lookups += 1
                return RexHostInventory(hosts: self.remotes.map { $0.0 }, warnings: [])
            }
        }, reconnectDelay: { _ in 60_000_000_000 })
    }
}
