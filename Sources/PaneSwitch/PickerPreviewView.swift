import AppKit
import PaneSwitchCore

/// A draft-only rendering of the real picker. It owns no backend, hot key, or window.
@MainActor
final class PickerPreviewView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Appearance: Equatable {
        let density: PickerDensity
        let highlightColor: String
        let hostIcons: Bool
        let paneIcons: Bool
        let directories: Bool
        let jumps: Bool
        let legend: Bool
        let debug: Bool

        init(_ settings: PickerSettings) {
            density = settings.density
            highlightColor = settings.highlightColor
            hostIcons = settings.showHostIcons
            paneIcons = settings.showPaneIcons
            directories = settings.showWorkingDirectory
            jumps = settings.showJumpLabels
            legend = settings.showKeyboardLegend
            debug = settings.debug
        }
    }

    private let menuBar = NSBox()
    private let menuIcon = NSImageView()
    private let menuState = NSTextField(labelWithString: "")
    private let shortcutHint = NSTextField(labelWithString: "")
    private let sampleHint = NSTextField(wrappingLabelWithString: "Sample panes · Scroll to explore. No panes or shortcuts are activated.")
    private let pickerContainer = NSView()
    private var surface: PickerSurfaceView?
    private var previewAppearance: Appearance?
    private static let sampleQuery = "o"
    private let highlighter = PaneSearch.Highlighter(query: PickerPreviewView.sampleQuery)
    private let list: PaneGroupedList = {
        let local = RexHost(id: "preview-local", label: "Mac", server: nil)
        let remote = RexHost(id: "preview-remote", label: "Lab", server: "sample.invalid")
        let panes = [
            Pane(host: local, sessionID: "dev", sessionLabel: "Development",
                 windowID: "window:01a19088-4c76-71c9-a314-ddcfd76c0d37",
                 windowLabel: "Window d76c0d37", blockID: "preview-omp", label: "", title: "OMP",
                 command: "omp", directory: "~/Projects/pane-switcher-for-rex"),
            Pane(host: remote, sessionID: "ops", sessionLabel: "Operations", windowID: "2",
                 windowLabel: "Deploy logs", blockID: "preview-shell", label: "", title: "Remote shell",
                 command: "zsh", directory: "/srv/services/api"),
        ]
        return PaneGroupedList(rankedPanes: PaneSearch.results(panes, query: PickerPreviewView.sampleQuery))
    }()

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Live settings preview. Sample panes, noninteractive; scrolling is available.")

        menuBar.boxType = .custom
        menuBar.titlePosition = .noTitle
        menuBar.borderWidth = 1
        menuBar.borderColor = .separatorColor
        menuBar.fillColor = .controlBackgroundColor
        menuBar.cornerRadius = 8
        menuBar.contentViewMargins = .zero
        menuBar.setAccessibilityLabel("Sample menu bar")

        let apple = NSImageView(image: NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)!)
        apple.contentTintColor = .labelColor
        let appName = NSTextField(labelWithString: "Rex")
        appName.font = .systemFont(ofSize: 12, weight: .semibold)
        let clock = NSTextField(labelWithString: "9:41")
        clock.font = .systemFont(ofSize: 11, weight: .medium)
        let wifi = NSImageView(image: NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)!)
        wifi.contentTintColor = .secondaryLabelColor
        menuIcon.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Pane Switcher for Rex menu bar icon")
        menuIcon.contentTintColor = .labelColor
        menuIcon.imageScaling = .scaleProportionallyDown
        let trailing = NSStackView(views: [menuIcon, wifi, clock])
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 12
        let menuContent = NSView()
        menuBar.contentView = menuContent
        for view in [apple, appName, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            menuContent.addSubview(view)
        }
        NSLayoutConstraint.activate([
            apple.leadingAnchor.constraint(equalTo: menuContent.leadingAnchor, constant: 12),
            apple.centerYAnchor.constraint(equalTo: menuContent.centerYAnchor),
            apple.widthAnchor.constraint(equalToConstant: 12),
            apple.heightAnchor.constraint(equalToConstant: 14),
            appName.leadingAnchor.constraint(equalTo: apple.trailingAnchor, constant: 10),
            appName.centerYAnchor.constraint(equalTo: menuContent.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: menuContent.trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: menuContent.centerYAnchor),
            menuIcon.widthAnchor.constraint(equalToConstant: 16),
            menuIcon.heightAnchor.constraint(equalToConstant: 16),
            wifi.widthAnchor.constraint(equalToConstant: 14),
            wifi.heightAnchor.constraint(equalToConstant: 14),
        ])

        menuState.font = .systemFont(ofSize: 11)
        menuState.textColor = .secondaryLabelColor
        shortcutHint.font = .systemFont(ofSize: 12, weight: .medium)
        shortcutHint.alignment = .center
        shortcutHint.lineBreakMode = .byTruncatingTail
        sampleHint.font = .systemFont(ofSize: 11)
        sampleHint.textColor = .secondaryLabelColor
        sampleHint.alignment = .center
        sampleHint.maximumNumberOfLines = 2
        for view in [menuBar, menuState, pickerContainer, shortcutHint, sampleHint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            menuBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            menuBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuBar.topAnchor.constraint(equalTo: topAnchor),
            menuBar.heightAnchor.constraint(equalToConstant: 32),
            menuState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            menuState.topAnchor.constraint(equalTo: menuBar.bottomAnchor, constant: 5),
            pickerContainer.topAnchor.constraint(equalTo: menuState.bottomAnchor, constant: 12),
            pickerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            pickerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            shortcutHint.topAnchor.constraint(equalTo: pickerContainer.bottomAnchor, constant: 12),
            shortcutHint.leadingAnchor.constraint(equalTo: leadingAnchor),
            shortcutHint.trailingAnchor.constraint(equalTo: trailingAnchor),
            sampleHint.topAnchor.constraint(equalTo: shortcutHint.bottomAnchor, constant: 5),
            sampleHint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            sampleHint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sampleHint.bottomAnchor.constraint(equalTo: bottomAnchor),
            pickerContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 450)
    }

    func update(_ settings: PickerSettings) {
        menuIcon.isHidden = !settings.showMenuBarIcon
        menuState.stringValue = settings.showMenuBarIcon ? "Menu bar icon shown" : "Menu bar icon hidden"
        let shortcut = (try? PickerShortcut(settings.shortcut))?.display ?? settings.shortcut
        shortcutHint.stringValue = "Open picker with \(shortcut)"
        shortcutHint.toolTip = "Draft shortcut: \(shortcut). Not registered by this preview."
        setAccessibilityValue("\(menuState.stringValue). Draft shortcut: \(shortcut).")

        let nextAppearance = Appearance(settings)
        guard previewAppearance != nextAppearance else { return }
        previewAppearance = nextAppearance
        surface?.removeFromSuperview()
        let sample = PickerSurfaceView(settings: settings)
        surface = sample
        sample.translatesAutoresizingMaskIntoConstraints = false
        pickerContainer.addSubview(sample)
        NSLayoutConstraint.activate([
            sample.leadingAnchor.constraint(equalTo: pickerContainer.leadingAnchor),
            sample.trailingAnchor.constraint(equalTo: pickerContainer.trailingAnchor),
            sample.topAnchor.constraint(equalTo: pickerContainer.topAnchor),
            sample.bottomAnchor.constraint(equalTo: pickerContainer.bottomAnchor),
        ])
        sample.search.isEnabled = false
        sample.search.stringValue = Self.sampleQuery
        sample.search.setAccessibilityLabel("Sample search: \(Self.sampleQuery), read-only")
        sample.settingsButton.isEnabled = false
        sample.settingsButton.setAccessibilityLabel("Sample settings button, disabled")
        sample.table.refusesFirstResponder = true
        sample.table.dataSource = self
        sample.table.delegate = self
        sample.table.setAccessibilityLabel("Sample panes. Noninteractive preview.")
        sample.empty.isHidden = true
        sample.setHostStates(["preview-local": .ready, "preview-remote": .connecting])
        sample.status.isSelectable = false
        sample.status.string = "Mac: 1 pane\nLab: reconnecting · 1 cached pane"
        sample.status.sizeToFit()
        sample.message.stringValue = settings.debug ? "2 matching panes" : ""
        sample.updateFooterLayout(hasMessage: settings.debug)
        sample.table.reloadData()
        if let row = list.row(forPaneIndex: 0) {
            sample.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // Keep the native scroll view interactive, without allowing table clicks to move selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let table = surface?.table, let hit, hit === table || hit.isDescendant(of: table) {
            return table.enclosingScrollView?.contentView
        }
        return hit
    }

    func numberOfRows(in tableView: NSTableView) -> Int { list.rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        surface?.makeSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        surface?.rowView(for: list, row: row, highlighter: highlighter)
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        list.rows.indices.contains(row) && list.paneIndex(forRow: row) == nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let layout = surface?.layout else { return tableView.rowHeight }
        return list.paneIndex(forRow: row) == nil ? layout.headingHeight : layout.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
