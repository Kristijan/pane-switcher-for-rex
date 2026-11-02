import AppKit
import PaneSwitchCore

// Density changes spacing, not text size; Comfortable remains the default.
struct PickerLayout {
    let rowHeight: CGFloat
    let headingHeight: CGFloat
    let rowSpacing: CGFloat
    let rowSideInset: CGFloat
    let iconTextInset: CGFloat
    let iconSize: CGFloat
    let textTopInset: CGFloat
    let lineSpacing: CGFloat
    let searchTopInset: CGFloat
    let horizontalInset: CGFloat
    let listSideInset: CGFloat
    let searchListSpacing: CGFloat
    let searchHeight: CGFloat
    let listBottomSpacing: CGFloat
    let messageTopSpacing: CGFloat
    let footerBottomInset: CGFloat
    let legendSpace: CGFloat
    let debugSpace: CGFloat
    let messageHeight: CGFloat
    let messageSpace: CGFloat
    let controlSpacing: CGFloat
    let settingsButtonHeight: CGFloat

    init(_ density: PickerDensity) {
        let compact = density == .compact
        rowHeight = compact ? 46 : 58
        headingHeight = compact ? 22 : 28
        rowSpacing = compact ? 1 : 3
        rowSideInset = compact ? 10 : 12
        iconTextInset = rowSideInset + 16 + 10
        iconSize = 16
        textTopInset = compact ? 5 : 8
        lineSpacing = compact ? 2 : 4
        searchTopInset = compact ? 8 : 10
        horizontalInset = compact ? 12 : 16
        listSideInset = compact ? 6 : 8
        searchListSpacing = compact ? 6 : 8
        searchHeight = compact ? 28 : 32
        listBottomSpacing = compact ? 5 : 6
        messageTopSpacing = compact ? 6 : 8
        footerBottomInset = compact ? 8 : 10
        legendSpace = compact ? 22 : 24
        debugSpace = compact ? 160 : 180
        messageHeight = compact ? 28 : 30
        messageSpace = compact ? 30 : 32
        controlSpacing = compact ? 6 : 8
        settingsButtonHeight = 26
    }
}
@MainActor
final class PickerSurfaceView: NSVisualEffectView {
    let settings: PickerSettings
    let layout: PickerLayout
    private let highlightColor: NSColor
    let search = HostFilterSearchField()
    let table = NSTableView()
    let status = NSTextView()
    let message = NSTextField(wrappingLabelWithString: "")
    let empty = NSTextField(labelWithString: "Loading panes…")
    let spinner = NSProgressIndicator()
    let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                                  target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var hasFooterMessage = false
    private var legendWidth: CGFloat = 0
    private var wrappingLegendSpace: CGFloat = 0
    private var footerHeight: NSLayoutConstraint!
    private var messageHeight: NSLayoutConstraint!
    private var hostStates: [String: PickerHostState] = [:]
    private let headingViews = NSHashTable<HostHeadingView>.weakObjects()
    private var debug: Bool { settings.debug }

    init(settings: PickerSettings) {
        self.settings = settings
        self.layout = PickerLayout(settings.density)
        let hex = PickerHighlightColor.canonicalHex(settings.highlightColor) ?? PickerHighlightColor.defaultHex
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0x007AFF
        self.highlightColor = NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                                     green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                     blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        super.init(frame: .zero)
        _ = RexIconProvider.shared
        NotificationCenter.default.addObserver(self, selector: #selector(artworkDidChange),
                                               name: RexIconProvider.didUpdate, object: nil)
        let surface = self
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 14
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        updateSurfaceAppearance()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)

        search.placeholderString = "Search panes, commands, folders…"
        search.font = .systemFont(ofSize: 15)
        search.controlSize = .regular
        search.isBezeled = true
        search.drawsBackground = false
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.setAccessibilityLabel("Search Rex panes")
        search.toolTip = "Search across all hosts, sessions, tabs, titles, commands, and directories"

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = layout.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: layout.rowSpacing)
        table.style = .fullWidth
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.floatsGroupRows = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Matching Rex panes")
        let rows = NSScrollView()
        rows.documentView = table
        rows.hasVerticalScroller = true
        rows.autohidesScrollers = true
        rows.scrollerStyle = .overlay
        rows.verticalScroller?.controlSize = .small
        rows.drawsBackground = false

        empty.font = .systemFont(ofSize: 15)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.setAccessibilityLabel("Pane search status")
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2
        message.setAccessibilityLabel("Picker message")
        status.isEditable = false
        status.isSelectable = true
        status.drawsBackground = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .labelColor
        status.textContainerInset = .zero
        status.textContainer?.lineFragmentPadding = 0
        status.isVerticallyResizable = true
        status.isHorizontallyResizable = false
        status.autoresizingMask = [.width]
        status.textContainer?.widthTracksTextView = true
        status.setAccessibilityLabel("Host availability")
        let statusScroll = NSScrollView()
        statusScroll.documentView = status
        statusScroll.hasVerticalScroller = true
        statusScroll.autohidesScrollers = true
        statusScroll.scrollerStyle = .overlay
        statusScroll.verticalScroller?.controlSize = .small
        statusScroll.drawsBackground = false
        statusScroll.isHidden = !debug
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let legend = NSMutableAttributedString()
        func keycap(_ text: String) {
            legend.append(NSAttributedString(string: " \(text) ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .backgroundColor: NSColor.quaternaryLabelColor,
            ]))
        }
        func label(_ text: String) {
            legend.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        keycap("↓")
        label(" ")
        keycap("↑")
        label(" / ")
        keycap("⌃J")
        label(" ")
        keycap("⌃K")
        label("  Browse    ")
        keycap("↵")
        label("  Switch    ")
        keycap("esc")
        label("  Cancel")
        hint.attributedStringValue = legend
        hint.setAccessibilityLabel("Down arrow or Control J: next pane. Up arrow or Control K: previous pane. Return: switch. Escape: cancel.")
        hint.isHidden = !settings.showKeyboardLegend
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.image = settingsButton.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        settingsButton.image?.isTemplate = true
        settingsButton.toolTip = "Settings (⌘,)"
        settingsButton.setAccessibilityLabel("Open Pane Switcher for Rex Settings")
        let separator = NSBox()
        separator.boxType = .separator
        separator.isHidden = !settings.showKeyboardLegend
        for view in [search, rows, empty, separator, message, statusScroll, spinner, hint, settingsButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(view)
        }
        footerHeight = separator.bottomAnchor.constraint(equalTo: surface.bottomAnchor,
                                                        constant: -(debug ? layout.debugSpace + layout.legendSpace
                                                                    : layout.footerBottomInset + layout.legendSpace))
        messageHeight = message.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: surface.topAnchor, constant: layout.searchTopInset),
            search.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: layout.horizontalInset),
            search.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -layout.controlSpacing),
            search.heightAnchor.constraint(equalToConstant: layout.searchHeight),
            rows.topAnchor.constraint(equalTo: search.bottomAnchor, constant: layout.searchListSpacing),
            rows.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: layout.listSideInset),
            rows.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -layout.listSideInset),
            rows.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -layout.listBottomSpacing),
            empty.centerXAnchor.constraint(equalTo: rows.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: rows.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: layout.horizontalInset),
            separator.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -layout.horizontalInset),
            footerHeight,
            message.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: layout.messageTopSpacing),
            message.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: layout.horizontalInset),
            message.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -layout.horizontalInset),
            messageHeight,
            statusScroll.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 2),
            statusScroll.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            statusScroll.trailingAnchor.constraint(equalTo: message.trailingAnchor),
            hint.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: layout.horizontalInset),
            hint.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -layout.horizontalInset),
            hint.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -layout.footerBottomInset),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -layout.controlSpacing),
            spinner.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -layout.horizontalInset),
            settingsButton.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 30),
            settingsButton.heightAnchor.constraint(equalToConstant: layout.settingsButtonHeight),
        ])
        if debug {
            statusScroll.bottomAnchor.constraint(equalTo: settings.showKeyboardLegend ? hint.topAnchor : surface.bottomAnchor,
                                                 constant: settings.showKeyboardLegend ? -(layout.lineSpacing + 2) : -layout.footerBottomInset).isActive = true
        } else {
            statusScroll.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
    }

    required init?(coder: NSCoder) { return nil }

    func updateFooterLayout(hasMessage: Bool) {
        hasFooterMessage = hasMessage
        messageHeight.constant = hasMessage ? layout.messageHeight : 0
        let availableWidth = max(1, (bounds.width > 0 ? bounds.width : 760) - layout.horizontalInset * 2)
        if availableWidth != legendWidth {
            legendWidth = availableWidth
            hint.preferredMaxLayoutWidth = availableWidth
            let legendHeight = hint.attributedStringValue.boundingRect(
                with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            wrappingLegendSpace = max(0, ceil(legendHeight) - ceil(hint.attributedStringValue.size().height))
        }
        let legendSpace = settings.showKeyboardLegend ? layout.legendSpace + wrappingLegendSpace : 0
        footerHeight.constant = debug ? -(layout.debugSpace + legendSpace)
            : -(layout.footerBottomInset + legendSpace + (hasMessage ? layout.messageSpace : 0))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if footerHeight != nil { updateFooterLayout(hasMessage: hasFooterMessage) }
    }

    @objc private func artworkDidChange() {
        let visibleRows = table.rows(in: table.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaneRowView
            cell?.refreshArtwork()
        }
    }
    /// Update instantiated headings in place; future headings use the cached state.
    func setHostStates(_ states: [String: PickerHostState]) {
        hostStates = states
        for heading in headingViews.allObjects {
            heading.setState(states[heading.hostID] ?? .ready)
        }
    }


    /// Requires the same row layout and search query as the previous list.
    func refreshVisibleRows(in list: PaneGroupedList, previous: PaneGroupedList,
                            highlighter: PaneSearch.Highlighter) {
        let visibleRows = table.rows(in: table.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
        for row in visibleRows.location..<min(NSMaxRange(visibleRows), list.rows.count) {
            switch (list.rows[row], previous.rows[row]) {
            case (.host(let host), .host(let previousHost)):
                guard host != previousHost,
                      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HostHeadingView
                else { continue }
                cell.configure(host, state: hostStates[host.id] ?? .ready,
                               hasPanes: list.paneIndex(forRow: row + 1) != nil)
            case (.pane(let paneIndex), .pane(let previousPaneIndex)):
                let pane = list.panes[paneIndex]
                guard pane != previous.panes[previousPaneIndex],
                      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaneRowView
                else { continue }
                cell.configure(pane, jumpIndex: settings.showJumpLabels && paneIndex < 10 ? paneIndex : nil,
                               highlighter: highlighter)
            default:
                continue
            }
        }
    }

    func rowView(for list: PaneGroupedList, row: Int, highlighter: PaneSearch.Highlighter) -> NSView? {
        guard list.rows.indices.contains(row) else { return nil }
        switch list.rows[row] {
        case .host(let host):
            let identifier = NSUserInterfaceItemIdentifier("HostHeading")
            let cell = table.makeView(withIdentifier: identifier, owner: nil) as? HostHeadingView
                ?? HostHeadingView(showIcons: settings.showHostIcons, layout: layout)
            cell.identifier = identifier
            headingViews.add(cell)
            cell.configure(host, state: hostStates[host.id] ?? .ready,
                           hasPanes: list.paneIndex(forRow: row + 1) != nil)
            return cell
        case .pane(let paneIndex):
            let identifier = NSUserInterfaceItemIdentifier("PaneRow")
            let cell = table.makeView(withIdentifier: identifier, owner: nil) as? PaneRowView
                ?? PaneRowView(showIcons: settings.showPaneIcons, showWorkingDirectory: settings.showWorkingDirectory,
                               showJumpLabels: settings.showJumpLabels, highlightColor: highlightColor, layout: layout)
            cell.identifier = identifier
            cell.configure(list.panes[paneIndex],
                           jumpIndex: settings.showJumpLabels && paneIndex < 10 ? paneIndex : nil,
                           highlighter: highlighter)
            return cell
        }
    }

    func makeSelectionRowView() -> NSTableRowView {
        PickerSelectionRowView()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceAppearance()
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        updateSurfaceAppearance()
        table.needsDisplay = true
    }

    private func updateSurfaceAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            layer?.backgroundColor = (reduceTransparency ? NSColor.windowBackgroundColor : .clear).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// The native table still owns selection and scrolling; only its selection fill changes.
@MainActor
private final class PickerSelectionRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.labelColor.withAlphaComponent(increaseContrast ? 0.14 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}
@MainActor
private final class HostHeadingView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let hostIcon = NSImageView()
    private let statusDot = NSTextField(labelWithString: "●")
    private(set) var hostID = ""
    private var hostDescription = ""
    private var hasPanes = true
    private let showIcons: Bool

    init(showIcons: Bool, layout: PickerLayout) {
        self.showIcons = showIcons
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)
        textField = label
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        statusDot.font = .systemFont(ofSize: 8)
        statusDot.alignment = .center
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.setAccessibilityElement(false)
        statusDot.isHidden = true
        addSubview(statusDot)
        if showIcons {
            hostIcon.translatesAutoresizingMaskIntoConstraints = false
            hostIcon.imageScaling = .scaleProportionallyDown
            hostIcon.contentTintColor = .secondaryLabelColor
            hostIcon.setAccessibilityElement(false)
            addSubview(hostIcon)
            NSLayoutConstraint.activate([
                hostIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: layout.rowSideInset),
                hostIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
                hostIcon.widthAnchor.constraint(equalToConstant: 18),
                hostIcon.heightAnchor.constraint(equalToConstant: 18),
            ])
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: layout.rowSideInset + (showIcons ? 24 : 0)),
            label.trailingAnchor.constraint(equalTo: statusDot.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -layout.rowSideInset),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) {
        showIcons = true
        super.init(coder: coder)
    }

    func configure(_ host: RexHost, state: PickerHostState, hasPanes: Bool) {
        hostID = host.id
        self.hasPanes = hasPanes
        let location = host.server == nil ? "Local" : "Remote"
        label.stringValue = showIcons ? "· \(host.label)" : "\(location) · \(host.label)"
        if showIcons {
            let fallback = host.server == nil ? "laptopcomputer" : "server.rack"
            hostIcon.image = host.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
        }
        hostDescription = "\(location) host: \(host.label)"
        setState(state)
    }

    func setState(_ state: PickerHostState) {
        let description: String
        switch state {
        case .connecting:
            statusDot.isHidden = false
            statusDot.textColor = .tertiaryLabelColor
            description = "\(hostDescription). Connecting…"
        case .ready:
            statusDot.isHidden = true
            description = hasPanes ? hostDescription : "\(hostDescription). No panes available on this host."
        case .unavailable(let reason):
            statusDot.isHidden = false
            statusDot.textColor = .systemOrange.withAlphaComponent(0.75)
            description = "\(hostDescription). Unavailable: \(reason)"
        }
        toolTip = description
        label.toolTip = description
        statusDot.toolTip = description
        setAccessibilityLabel(description)
    }
}

@MainActor
private final class PaneRowView: NSTableCellView {
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let paneIcon = NSImageView()
    private let jumpLabel = NSTextField(labelWithString: "")
    private let showWorkingDirectory: Bool
    private let highlightColor: NSColor
    private var command = ""
    private var primaryText = NSMutableAttributedString()
    private var secondaryText = NSMutableAttributedString()
    private var primaryMatches: [NSRange] = []
    private var secondaryMatches: [NSRange] = []
    private var secondaryBasename: NSRange?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColors() }
    }

    init(showIcons: Bool, showWorkingDirectory: Bool, showJumpLabels: Bool,
         highlightColor: NSColor, layout: PickerLayout) {
        self.showWorkingDirectory = showWorkingDirectory
        self.highlightColor = highlightColor
        super.init(frame: .zero)
        primary.font = .systemFont(ofSize: 14, weight: .regular)
        primary.textColor = .labelColor
        secondary.font = .systemFont(ofSize: 12)
        secondary.textColor = .secondaryLabelColor
        paneIcon.translatesAutoresizingMaskIntoConstraints = false
        paneIcon.imageScaling = .scaleProportionallyDown
        paneIcon.contentTintColor = .secondaryLabelColor
        paneIcon.setAccessibilityElement(false)
        if showIcons { addSubview(paneIcon) }
        for label in [primary, secondary] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        jumpLabel.translatesAutoresizingMaskIntoConstraints = false
        jumpLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        jumpLabel.textColor = .tertiaryLabelColor
        jumpLabel.alignment = .right
        jumpLabel.setAccessibilityElement(false)
        jumpLabel.isHidden = !showJumpLabels
        addSubview(jumpLabel)
        textField = primary
        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18 + (showIcons ? layout.iconTextInset : layout.rowSideInset)),
            primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: showJumpLabels ? -(layout.rowSideInset + 34 + layout.lineSpacing + 4) : -layout.rowSideInset),
            primary.topAnchor.constraint(equalTo: topAnchor, constant: layout.textTopInset),
            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            secondary.trailingAnchor.constraint(equalTo: primary.trailingAnchor),
            secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: layout.lineSpacing),
            jumpLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -layout.rowSideInset),
            jumpLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            jumpLabel.widthAnchor.constraint(equalToConstant: 34),
        ])
        if showIcons {
            NSLayoutConstraint.activate([
                paneIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: layout.rowSideInset + 18),
                paneIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
                paneIcon.widthAnchor.constraint(equalToConstant: layout.iconSize),
                paneIcon.heightAnchor.constraint(equalToConstant: layout.iconSize),
            ])
        }
    }

    required init?(coder: NSCoder) {
        showWorkingDirectory = true
        highlightColor = NSColor(srgbRed: 0, green: 122.0 / 255, blue: 1, alpha: 1)
        super.init(coder: coder)
    }

    func configure(_ pane: Pane, jumpIndex: Int?, highlighter: PaneSearch.Highlighter) {
        var names = [pane.primaryText]
        if !pane.label.isEmpty, pane.label != pane.primaryText { names.append(pane.label) }
        if !pane.command.isEmpty {
            names.removeAll { $0 == "shell" }
            if !names.contains(pane.command) { names.append(pane.command) }
        }
        let primaryString = RexSymbolFont.shared.displayText(names.joined(separator: " — "))
        primaryMatches = highlighter.ranges(in: primaryString)
        primaryText = highlighted(primaryString, size: 14, weight: .regular, ranges: primaryMatches)
        secondaryBasename = nil
        command = pane.command
        refreshArtwork()
        if paneIcon.superview != nil {
            paneIcon.toolTip = pane.command.isEmpty ? "Terminal" : pane.command
        }
        let secondaryString = RexSymbolFont.shared.displayText(
            pane.displaySecondaryText(showWorkingDirectory: showWorkingDirectory))
        if showWorkingDirectory {
            let directory = RexSymbolFont.shared.displayText(pane.directory)
            let basename = (directory as NSString).lastPathComponent
            if !basename.isEmpty, basename != "/", secondaryString.hasSuffix(directory) {
                let range = (directory as NSString).range(of: basename, options: .backwards)
                if range.location != NSNotFound {
                    secondaryBasename = NSRange(
                        location: secondaryString.utf16.count - directory.utf16.count + range.location,
                        length: range.length)
                }
            }
        }
        secondaryMatches = highlighter.ranges(in: secondaryString)
        secondaryText = highlighted(secondaryString, size: 12, weight: .regular, ranges: secondaryMatches)
        updateTextColors()
        let jumpText = jumpIndex.map { "⌘\($0 == 9 ? 0 : $0 + 1)" } ?? ""
        jumpLabel.stringValue = jumpText
        let details = "\(primary.stringValue)\n\(secondary.stringValue)\nPane: \(pane.blockID)"
        toolTip = details
        primary.toolTip = details
        secondary.toolTip = details
        setAccessibilityElement(true)
        setAccessibilityLabel(primary.stringValue)
        setAccessibilityValue(secondary.stringValue + (jumpText.isEmpty ? "" : ". Jump shortcut: \(jumpText)"))
    }

    func refreshArtwork() {
        guard paneIcon.superview != nil else { return }
        let image = RexIconProvider.shared.image(forCommand: command)
        if paneIcon.image !== image { paneIcon.image = image }
    }


    private func highlighted(_ text: String, size: CGFloat, weight: NSFont.Weight,
                             ranges: [NSRange]) -> NSMutableAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .paragraphStyle: paragraph,
        ])
        let matchedFont = NSFont.systemFont(ofSize: size, weight: .bold)
        for range in ranges {
            value.addAttribute(.font, value: matchedFont, range: range)
        }
        RexSymbolFont.shared.apply(to: value, size: size)
        return value
    }

    private func updateTextColors() {
        let primaryColor = NSColor.labelColor
        let secondaryColor = NSColor.secondaryLabelColor
        primaryText.addAttribute(.foregroundColor, value: primaryColor, range: NSRange(location: 0, length: primaryText.length))
        secondaryText.addAttribute(.foregroundColor, value: secondaryColor, range: NSRange(location: 0, length: secondaryText.length))
        if let secondaryBasename {
            secondaryText.addAttribute(.foregroundColor,
                                       value: NSColor.labelColor.withAlphaComponent(0.72),
                                       range: secondaryBasename)
        }
        for range in primaryMatches {
            primaryText.addAttribute(.foregroundColor, value: highlightColor, range: range)
        }
        for range in secondaryMatches {
            secondaryText.addAttribute(.foregroundColor, value: highlightColor, range: range)
        }
        primary.attributedStringValue = primaryText
        secondary.attributedStringValue = secondaryText
        jumpLabel.textColor = .tertiaryLabelColor
        paneIcon.contentTintColor = secondaryColor
    }
}
