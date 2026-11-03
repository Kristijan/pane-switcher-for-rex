import AppKit
import PaneSwitchCore

@MainActor
final class PickerController: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let backend: RexBackend
    private let settings: PickerSettings
    private let recentStore: RecentPaneStore
    private let surface: PickerSurfaceView
    private var layout: PickerLayout { surface.layout }
    private let openSettings: () -> Void
    private var debug: Bool { settings.debug }
    private let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                    styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private var search: HostFilterSearchField { surface.search }
    private var table: NSTableView { surface.table }
    private var status: NSTextView { surface.status }
    private var message: NSTextField { surface.message }
    private var empty: NSTextField { surface.empty }
    private var spinner: NSProgressIndicator { surface.spinner }
    private var hosts: [String: RexHost] = [:]
    private var hostStates: [String: PickerHostState] = [:]
    private var unavailableHosts = Set<String>()
    private var inventories: [String: [Pane]] = [:]
    private var index = PaneSearch.Index([])
    private var list = PaneGroupedList(rankedPanes: [])
    private var highlighter = PaneSearch.Highlighter(query: "")
    private var highlightQuery = ""
    private var isRestoringSelection = false
    private var isLiveScrolling = false
    private var pendingResultsRefresh = false
    private var discoveryTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    private var invocation = UUID()
    private var discovery = UUID()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var clientID = ""
    private var rexApp: NSRunningApplication?
    private var returningTo: NSRunningApplication?
    private var isDiscovering = false
    private var isSwitching = false
    private var selection = PaneSelection()
    private var errorMessage: String?
    private var warningMessage: String?
    private var recentIDs: [String] = []
    private var recentWarningMessage: String?
    private var diagnostics = PickerDiagnostics()

    init(backend: RexBackend, settings: PickerSettings, openSettings: @escaping () -> Void) {
        self.backend = backend
        self.settings = settings
        self.surface = PickerSurfaceView(settings: settings)
        self.recentStore = RecentPaneStore()
        self.openSettings = openSettings
        super.init()
        configurePanel()
    }

    func show(clientID: String, rexApp: NSRunningApplication, returningTo: NSRunningApplication?,
              requestedAt: ContinuousClock.Instant? = nil) {
        close(restoreActivation: false)
        invocation = UUID()
        self.clientID = clientID
        self.rexApp = rexApp
        self.returningTo = returningTo
        search.stringValue = ""
        search.isEnabled = true
        selection.resetForQuery()
        errorMessage = nil
        warningMessage = nil
        recentIDs = recentStore.snapshot()
        if let error = recentStore.loadError {
            recentWarningMessage = "Could not load recent panes: \(error.localizedDescription)"
        }
        isSwitching = false
        message.stringValue = ""
        startDiscovery(clearInventory: true)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Discovery starts with an empty inventory; keep the shell stable as results arrive.
            let size = NSSize(width: min(700, visible.width - 24), height: min(500, visible.height - 24))
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                  width: size.width, height: size.height), display: true)
        }
        installOutsideMonitors()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        if debug, let requestedAt {
            diagnostics.recordLaunch(requestedAt.duration(to: .now))
            updateFooter()
        }
    }

    /// Reuse the current session, including its query, selection, and return application.
    @discardableResult
    func focusIfVisible() -> Bool {
        guard panel.isVisible else { return false }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if search.isEnabled, panel.firstResponder !== search.currentEditor() {
            panel.makeFirstResponder(search)
        }
        return true
    }

    func dismiss() {
        close(restoreActivation: true)
    }

    func dismissForSettings() {
        close(restoreActivation: false)
    }

    @objc private func showSettings() {
        openSettings()
    }

    private func close(restoreActivation: Bool) {
        invocation = UUID()
        discovery = UUID()
        discoveryTask?.cancel()
        discoveryTask = nil
        switchTask?.cancel()
        switchTask = nil
        isSwitching = false
        isLiveScrolling = false
        pendingResultsRefresh = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        search.dismissHostSuggestions()
        panel.orderOut(nil)
        if restoreActivation, let returningTo, !returningTo.isTerminated {
            returningTo.activate(options: [])
        }
        returningTo = nil
        rexApp = nil
    }

    private func configurePanel() {
        panel.delegate = self
        panel.onKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
        panel.title = "Switch Rex Pane"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.setAccessibilityLabel("Rex pane picker")

        panel.contentView = surface
        table.dataSource = self
        surface.settingsButton.target = self
        surface.settingsButton.action = #selector(showSettings)
        search.delegate = self
        table.delegate = self
        table.target = self
        table.action = #selector(focusSearchAfterSelection)
        table.doubleAction = #selector(acceptClickedPane)
        if let scroll = table.enclosingScrollView {
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(liveScrollStarted),
                               name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(liveScrollEnded),
                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(scrollBoundsChanged),
                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
    }

    private func startDiscovery(clearInventory: Bool) {
        discoveryTask?.cancel()
        discovery = UUID()
        let run = invocation
        let refresh = discovery
        isDiscovering = true
        if clearInventory {
            hosts.removeAll()
            search.setHosts([])
            hostStates.removeAll()
            unavailableHosts.removeAll()
            inventories.removeAll()
            surface.setHostStates(hostStates)
            rebuildResults(resetViewport: true)
        }
        warningMessage = nil
        updateFooter()
        discoveryTask = Task { [weak self, backend] in
            for await event in backend.discover() {
                guard !Task.isCancelled, let self, self.invocation == run, self.discovery == refresh else { return }
                self.receive(event)
            }
            guard !Task.isCancelled, let self, self.invocation == run, self.discovery == refresh else { return }
            self.isDiscovering = false
            self.updateFooter()
        }
    }

    private func receive(_ event: DiscoveryEvent) {
        switch event {
        case .hosts(let discovered):
            let hostIDs = Set(discovered.map(\.id))
            let removed = Set(hosts.keys).subtracting(hostIDs)
            for id in removed {
                hosts[id] = nil
                hostStates[id] = nil
                inventories[id] = nil
                unavailableHosts.remove(id)
            }
            for host in discovered {
                hosts[host.id] = host
                if hostStates[host.id] == nil { hostStates[host.id] = .connecting }
            }
            surface.setHostStates(hostStates)
            updateHostSuggestions()
            rebuildResults()
        case .panes(let host, let panes):
            let previouslyHadPanes = inventories[host.id]?.isEmpty == false
            let sameHost = hosts[host.id] == host
            hosts[host.id] = host
            unavailableHosts.remove(host.id)
            hostStates[host.id] = .ready
            inventories[host.id] = panes
            if !sameHost || previouslyHadPanes != (panes.isEmpty == false) { updateHostSuggestions() }
            surface.setHostStates(hostStates)
            RexIconProvider.shared.preload(commands: panes.map(\.command))
            rebuildResults()
        case .failed(let host, let reason):
            let previouslyHadPanes = inventories[host.id]?.isEmpty == false
            hosts[host.id] = host
            unavailableHosts.insert(host.id)
            hostStates[host.id] = .unavailable(reason)
            inventories[host.id] = nil
            if previouslyHadPanes { updateHostSuggestions() }
            surface.setHostStates(hostStates)
            rebuildResults()
        case .warning(let warning):
            warningMessage = warning
        case .finished:
            isDiscovering = false
        }
        updateFooter()
    }

    private func updateHostSuggestions() {
        let available = hosts.values.filter { inventories[$0.id]?.isEmpty == false }.sorted {
            if ($0.server == nil) != ($1.server == nil) { return $0.server == nil }
            return ($0.label, $0.id) < ($1.label, $1.id)
        }
        search.setHosts(available)
    }

    private func rebuildResults(resetViewport: Bool = false) {
        index = PaneSearch.Index(inventories.values.flatMap { $0 })
        filterResults(resetViewport: resetViewport)
    }

    private func filterResults(resetViewport: Bool = false) {
        let query = search.stringValue
        let parsed = PaneSearch.Query(query)
        var results = index.results(query: query)
        if settings.recentPanesFirst, !parsed.hasText {
            results = RecentPaneStore.order(results, recentIDs: recentIDs)
        }
        let statusHosts = hosts.values.filter { host in
            guard parsed.matches(host) else { return false }
            switch hostStates[host.id] {
            case .connecting?, .unavailable?: return true
            default: return false
            }
        }
        let next = PaneGroupedList(rankedPanes: results, additionalHosts: statusHosts, browsing: !parsed.hasText)
        if !resetViewport && list.hasSameLayout(as: next) {
            let previous = list
            list = next
            pendingResultsRefresh = false
            if query != highlightQuery {
                highlighter = PaneSearch.Highlighter(query: query)
                highlightQuery = query
            }
            surface.refreshVisibleRows(in: list, previous: previous, highlighter: highlighter)
            updateFooter()
            return
        }
        if !resetViewport && (isLiveScrolling || isElasticScrolling) {
            // Keep the displayed snapshot coherent until native scrolling settles;
            // the index continues receiving the latest inventory in the meantime.
            pendingResultsRefresh = true
            return
        }
        pendingResultsRefresh = false
        let viewport = resetViewport ? nil : captureViewport()
        list = next
        if query != highlightQuery {
            highlighter = PaneSearch.Highlighter(query: query)
            highlightQuery = query
        }
        isRestoringSelection = true
        table.reloadData()
        if let paneIndex = selection.selectedRow(in: list.panes),
           let row = list.row(forPaneIndex: paneIndex) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        updateFooter()
        surface.layoutSubtreeIfNeeded()
        restoreViewport(viewport)
        isRestoringSelection = false
    }

    private var isElasticScrolling: Bool {
        guard let clip = table.enclosingScrollView?.contentView else { return false }
        return clip.bounds.origin != clip.constrainBoundsRect(clip.bounds).origin
    }

    @objc private func liveScrollStarted(_ notification: Notification) {
        guard panel.isVisible else { return }
        isLiveScrolling = true
    }

    @objc private func liveScrollEnded(_ notification: Notification) {
        isLiveScrolling = false
        applyPendingResults()
    }

    @objc private func scrollBoundsChanged(_ notification: Notification) {
        applyPendingResults()
    }

    private func applyPendingResults() {
        guard panel.isVisible, pendingResultsRefresh, !isLiveScrolling, !isElasticScrolling else { return }
        filterResults()
    }

    private struct Viewport {
        let origin: NSPoint
        let anchor: (hostID: String, blockID: String, offset: CGFloat)?
    }

    private func captureViewport() -> Viewport? {
        guard let clip = table.enclosingScrollView?.contentView else { return nil }
        let visible = table.rows(in: clip.bounds)
        if visible.location != NSNotFound {
            for row in visible.location..<min(NSMaxRange(visible), list.rows.count) {
                guard let index = list.paneIndex(forRow: row) else { continue }
                let pane = list.panes[index]
                return Viewport(origin: clip.bounds.origin,
                                anchor: (pane.host.id, pane.blockID,
                                         table.rect(ofRow: row).minY - clip.bounds.minY))
            }
        }
        return Viewport(origin: clip.bounds.origin, anchor: nil)
    }

    private func restoreViewport(_ viewport: Viewport?) {
        guard let scroll = table.enclosingScrollView else { return }
        let clip = scroll.contentView
        var origin = viewport?.origin ?? .zero
        if let anchor = viewport?.anchor,
           let index = list.panes.firstIndex(where: {
               $0.host.id == anchor.hostID && $0.blockID == anchor.blockID
           }), let row = list.row(forPaneIndex: index) {
            origin.y = table.rect(ofRow: row).minY - anchor.offset
        }
        // Preserve browsing independently of selection. A removed anchor falls
        // back to the prior offset, constrained to the remaining document.
        let bounds = NSRect(origin: origin, size: clip.bounds.size)
        let constrained = clip.constrainBoundsRect(bounds).origin
        guard constrained != clip.bounds.origin else { return }
        clip.scroll(to: constrained)
        scroll.reflectScrolledClipView(clip)
    }

    private func updateFooter() {
        let emptyText: String
        let hasInventory = inventories.values.contains { !$0.isEmpty }
        let query = PaneSearch.Query(search.stringValue)
        let hasPendingHosts = hosts.values.contains { hostStates[$0.id] == .connecting && query.matches($0) }
        if hasPendingHosts || (!hasInventory && hosts.isEmpty && isDiscovering) {
            emptyText = "Connecting to hosts…"
        } else if !hasInventory {
            emptyText = "No panes available"
        } else {
            emptyText = "No matching panes"
        }
        if isSwitching {
            message.stringValue = "Switching to selected pane…"
            message.textColor = .secondaryLabelColor
        } else if let errorMessage {
            message.stringValue = errorMessage
            message.textColor = .systemRed
        } else if let recentWarningMessage {
            message.stringValue = recentWarningMessage
            message.textColor = .secondaryLabelColor
        } else if let warningMessage {
            message.stringValue = warningMessage
            message.textColor = .secondaryLabelColor
        } else if !unavailableHosts.isEmpty {
            message.stringValue = "Some hosts are unavailable."
            message.textColor = .secondaryLabelColor
        } else {
            message.stringValue = debug ? "\(list.panes.count) matching \(list.panes.count == 1 ? "pane" : "panes")" + (isDiscovering ? " · Discovering hosts…" : "") : ""
            message.textColor = .secondaryLabelColor
        }
        if list.panes.isEmpty, !list.rows.isEmpty {
            message.stringValue = emptyText + (message.stringValue.isEmpty ? "" : " · \(message.stringValue)")
        }
        message.toolTip = message.stringValue
        surface.updateFooterLayout(hasMessage: !message.stringValue.isEmpty)
        if debug {
            let ordered = hosts.values.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
            let hostLines = ordered.map { host in
                let state: String
                switch hostStates[host.id] {
                case .ready?: state = "\(inventories[host.id]?.count ?? 0) panes"
                case .unavailable(let reason)?: state = "Unavailable — \(reason)"
                default: state = "Connecting…"
                }
                return "\(host.label): \(state)"
            }
            status.string = (diagnostics.lines + hostLines).joined(separator: "\n")
            status.toolTip = status.string
            status.sizeToFit()
        }
        if isSwitching || isDiscovering { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        empty.isHidden = !list.rows.isEmpty
        empty.stringValue = emptyText
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isSwitching else { return }
        let started = debug ? ContinuousClock.now : nil
        selection.resetForQuery()
        filterResults(resetViewport: true)
        if let started {
            diagnostics.recordQuery(started.duration(to: .now))
            updateFooter()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)): acceptSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    private func selectPane(at paneIndex: Int) {
        guard let row = list.row(forPaneIndex: paneIndex) else { return }
        selection.choose(list.panes[paneIndex])
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func moveSelection(by offset: Int) {
        guard !isSwitching, !list.panes.isEmpty else { return }
        let current = list.paneIndex(forRow: table.selectedRow)
        let next = current.map { ($0 + offset + list.panes.count) % list.panes.count }
            ?? (offset > 0 ? 0 : list.panes.count - 1)
        selectPane(at: next)
    }

    @objc private func focusSearchAfterSelection() {
        guard !isSwitching else { return }
        if list.paneIndex(forRow: table.selectedRow) != nil {
            table.scrollRowToVisible(table.selectedRow)
        }
        panel.makeFirstResponder(search)
    }

    @objc private func acceptClickedPane() {
        guard !isSwitching, let paneIndex = list.paneIndex(forRow: table.clickedRow) else { return }
        selectPane(at: paneIndex)
        acceptSelection()
    }

    @objc private func acceptSelection() {
        guard !isSwitching, let paneIndex = list.paneIndex(forRow: table.selectedRow) else { return }
        let pane = list.panes[paneIndex]
        let run = invocation
        let client = clientID
        let started = debug ? ContinuousClock.now : nil
        isSwitching = true
        search.isEnabled = false
        updateFooter()
        switchTask = Task { [weak self, backend] in
            var activationDuration: Duration = .zero
            var rpcTimings: RexSwitchTimings?
            do {
                if let app = self?.rexApp, !app.isActive {
                    let activationStarted = started == nil ? nil : ContinuousClock.now
                    defer {
                        if let activationStarted { activationDuration = activationStarted.duration(to: .now) }
                    }
                    // Rex must be active before selecting its terminal first responder.
                    NSApp.yieldActivation(to: app)
                    guard app.activate(options: []) else { throw PickerError("Could not activate Rex.") }
                    let deadline = ContinuousClock.now + .seconds(2)
                    while !app.isActive {
                        try Task.checkCancellation()
                        guard !app.isTerminated, ContinuousClock.now < deadline else {
                            throw PickerError("Rex did not become active.")
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                if started != nil {
                    let measurement = await backend.measuredSwitchTo(pane, clientID: client)
                    rpcTimings = measurement.timings
                    try measurement.result.get()
                } else {
                    try await backend.switchTo(pane, clientID: client)
                }
                guard !Task.isCancelled, let self, self.invocation == run else { return }
                if let started {
                    self.diagnostics.recordSwitch(total: started.duration(to: .now),
                                                  nativeActivation: activationDuration, rpc: rpcTimings)
                }
                // Persistence is independent of switching: failure must never repeat a mutation
                // or reopen a picker after Rex has already selected the requested pane.
                do {
                    try self.recentStore.record(pane)
                    self.recentWarningMessage = nil
                } catch {
                    self.recentWarningMessage = "Could not save recent panes: \(error.localizedDescription)"
                }
                self.close(restoreActivation: false)
            } catch {
                guard !Task.isCancelled, let self, self.invocation == run else { return }
                if let started {
                    self.diagnostics.recordSwitch(total: started.duration(to: .now),
                                                  nativeActivation: activationDuration, rpc: rpcTimings)
                }
                self.isSwitching = false
                self.search.isEnabled = true
                self.errorMessage = "Could not switch: \(error.localizedDescription) Refreshing inventory; choose an available pane."
                self.selection.suspendAfterFailure()
                self.table.deselectAll(nil)
                self.startDiscovery(clearInventory: true)
                // Do not reclaim application focus if another application became active meanwhile.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == self.rexApp?.processIdentifier {
                    NSApp.activate(ignoringOtherApps: true)
                    self.panel.makeKeyAndOrderFront(nil)
                }
                if self.panel.isKeyWindow { self.panel.makeFirstResponder(self.search) }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { list.rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        surface.makeSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        surface.rowView(for: list, row: row, highlighter: highlighter)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isSwitching && list.paneIndex(forRow: row) != nil
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        list.rows.indices.contains(row) && list.paneIndex(forRow: row) == nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        list.paneIndex(forRow: row) == nil ? layout.headingHeight : layout.rowHeight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection, !isSwitching,
              let paneIndex = list.paneIndex(forRow: table.selectedRow) else { return }
        selection.choose(list.panes[paneIndex])
    }


    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.keyCode == 43 { showSettings(); return true }
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        if modifiers == .control, event.keyCode == 32 {
            search.deleteToLineStart()
            return true
        }
        if modifiers == .control, event.keyCode == 13 {
            search.deletePreviousWord()
            return true
        }
        if search.handleSuggestionKey(event) { return true }
        if event.keyCode == 53 { dismiss(); return true }
        if settings.showJumpLabels, modifiers == .command,
           let characters = event.charactersIgnoringModifiers, characters.count == 1,
           let digit = Int(characters), (0...9).contains(digit) {
            let paneIndex = digit == 0 ? 9 : digit - 1
            guard !isSwitching, list.panes.indices.contains(paneIndex) else { return true }
            selectPane(at: paneIndex)
            acceptSelection()
            return true
        }
        if modifiers == .control {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "j" || event.keyCode == 38 { moveSelection(by: 1); return true }
            if key == "k" || event.keyCode == 40 { moveSelection(by: -1); return true }
        }
        if event.keyCode == 36 || event.keyCode == 76 { acceptSelection(); return true }
        if modifiers.isEmpty {
            if event.keyCode == 125 { moveSelection(by: 1); return true }
            if event.keyCode == 126 { moveSelection(by: -1); return true }
        }
        return false
    }

    private func containsInteractionWindow(_ window: NSWindow?) -> Bool {
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent
        }
        return false
    }

    private func containsInteractionPoint(_ point: NSPoint, in window: NSWindow) -> Bool {
        if window.isVisible, window.frame.contains(point) { return true }
        return window.childWindows?.contains { containsInteractionPoint(point, in: $0) } ?? false
    }

    private func installOutsideMonitors() {
        let run = invocation
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.invocation == run else { return event }
            if !self.containsInteractionWindow(event.window), !self.isSwitching {
                self.close(restoreActivation: false)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.invocation == run, !self.isSwitching else { return }
                if !self.containsInteractionPoint(NSEvent.mouseLocation, in: self.panel) {
                    self.close(restoreActivation: false)
                }
            }
        }
    }
}

@MainActor
private final class PickerPanel: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

