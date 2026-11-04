import AppKit
import PaneSwitchCore

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Section: Int, CaseIterable {
        case appearance, shortcuts, advanced, about

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .shortcuts: return "Shortcuts"
            case .advanced: return "Advanced"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "paintbrush"
            case .shortcuts: return "keyboard"
            case .advanced: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }

        var detail: String {
            switch self {
            case .appearance: return "Make the picker feel at home in your workflow."
            case .shortcuts: return "Bring your panes into focus without leaving the keyboard."
            case .advanced: return "Configure Rex discovery and diagnostic output."
            case .about: return "Pane Switcher for Rex — a native Rex pane picker."
            }
        }
    }

    private var settings: PickerSettings
    private let applySettings: (PickerSettings) throws -> Void
    private let openSetup: () -> Void
    private let updateChecker: GitHubUpdateChecker
    private let shortcut = ShortcutRecorderButton()
    private let globalShortcut = NSSwitch()
    private let executable = NSTextField()
    private let highlightHex = NSTextField()
    private let highlightWell = NSColorWell()
    private let highlightValidation = NSTextField(wrappingLabelWithString: "")
    private var validHighlightColor = PickerHighlightColor.defaultHex
    private let menuBarIcon = NSSwitch()
    private let hostIcons = NSSwitch()
    private let paneIcons = NSSwitch()
    private let workingDirectory = NSSwitch()
    private let keyboardLegend = NSSwitch()
    private let jumpLabels = NSSwitch()
    private let recentPanesFirst = NSSwitch()
    private let launchAtLogin = NSSwitch()
    private let debug = NSSwitch()
    private let density = NSSegmentedControl(labels: ["Comfortable", "Compact"],
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let sidebar = NSTableView()
    private let preview = PickerPreviewView()
    private var sectionViews: [Section: NSScrollView] = [:]
    private let updateStatus = SettingsUpdateStatusView()
    private var updateCheckTask: Task<Void, Never>?
    private var updateCheckGeneration: UInt64 = 0
    private let installedVersion: String? = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return version
    }()

    init(settings: PickerSettings, apply: @escaping (PickerSettings) throws -> Void,
         openSetup: @escaping () -> Void, updateChecker: GitHubUpdateChecker = GitHubUpdateChecker()) {
        self.settings = settings
        self.applySettings = apply
        self.openSetup = openSetup
        self.updateChecker = updateChecker
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = true
        window.contentView = SettingsMaterialView(frame: .zero)
        super.init(window: window)
        window.title = "Pane Switcher for Rex Settings"
        window.minSize = NSSize(width: 1000, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setAccessibilityLabel("Pane Switcher for Rex Settings")
        configureContent()
        update(settings)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(settings:apply:)") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        checkForUpdates()
    }

    private func checkForUpdates() {
        cancelUpdateCheck()
        guard let installedVersion else {
            updateStatus.setState(.failure("The installed app version is unavailable."))
            return
        }
        updateStatus.setState(.checking)
        let generation = updateCheckGeneration
        let checker = updateChecker
        updateCheckTask = Task { [weak self] in
            do {
                let availability = try await checker.check(installedVersion: installedVersion)
                guard !Task.isCancelled, let self,
                      self.updateCheckGeneration == generation,
                      self.window?.isVisible == true else { return }
                switch availability {
                case .upToDate:
                    self.updateStatus.setState(.upToDate)
                case let .updateAvailable(version):
                    self.updateStatus.setState(.updateAvailable(version))
                }
                self.updateCheckTask = nil
            } catch {
                guard !Task.isCancelled, let self,
                      self.updateCheckGeneration == generation,
                      self.window?.isVisible == true else { return }
                self.updateStatus.setState(.failure(error.localizedDescription))
                self.updateCheckTask = nil
            }
        }
    }

    private func cancelUpdateCheck() {
        updateCheckGeneration &+= 1
        updateCheckTask?.cancel()
        updateCheckTask = nil
    }

    func update(_ settings: PickerSettings) {
        self.settings = canonical(settings)
        highlightWell.deactivate()
        validHighlightColor = self.settings.highlightColor
        highlightHex.stringValue = validHighlightColor
        syncHighlightWell()
        shortcut.stopRecording()
        shortcut.value = self.settings.shortcut
        globalShortcut.state = self.settings.globalShortcut ? .on : .off
        executable.stringValue = self.settings.rexExecutable ?? ""
        menuBarIcon.state = settings.showMenuBarIcon ? .on : .off
        hostIcons.state = settings.showHostIcons ? .on : .off
        paneIcons.state = settings.showPaneIcons ? .on : .off
        workingDirectory.state = settings.showWorkingDirectory ? .on : .off
        keyboardLegend.state = settings.showKeyboardLegend ? .on : .off
        jumpLabels.state = settings.showJumpLabels ? .on : .off
        recentPanesFirst.state = settings.recentPanesFirst ? .on : .off
        launchAtLogin.state = settings.launchAtLogin ? .on : .off
        debug.state = settings.debug ? .on : .off
        density.selectedSegment = settings.density == .compact ? 1 : 0
        refreshDraft()
    }

    func windowWillClose(_ notification: Notification) {
        cancelUpdateCheck()
        update(settings)
    }

    func windowDidResignMain(_ notification: Notification) {
        highlightWell.deactivate()
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let navigation = SettingsMaterialView(frame: .zero)
        navigation.material = .sidebar
        navigation.blendingMode = .behindWindow
        navigation.state = .followsWindowActiveState
        add(navigation, to: content)
        let form = NSView()
        add(form, to: content)
        let previewColumn = NSView()
        add(previewColumn, to: content)
        let footer = NSView()
        add(footer, to: content)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            navigation.topAnchor.constraint(equalTo: content.topAnchor),
            navigation.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 180),
            form.leadingAnchor.constraint(equalTo: navigation.trailingAnchor),
            form.topAnchor.constraint(equalTo: content.topAnchor),
            form.trailingAnchor.constraint(equalTo: previewColumn.leadingAnchor),
            form.bottomAnchor.constraint(equalTo: footer.topAnchor),
            previewColumn.topAnchor.constraint(equalTo: content.topAnchor),
            previewColumn.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewColumn.bottomAnchor.constraint(equalTo: footer.topAnchor),
            previewColumn.widthAnchor.constraint(equalToConstant: 420),
            footer.leadingAnchor.constraint(equalTo: navigation.trailingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64)
        ])
        configureSidebar(in: navigation)
        configureControls()
        for section in Section.allCases {
            let scroll = makeSection(section)
            add(scroll, to: form)
            pin(scroll, to: form)
            scroll.isHidden = section != .appearance
            sectionViews[section] = scroll
        }
        configurePreview(in: previewColumn)
        configureFooter(in: footer)
    }

    private func configureSidebar(in view: NSView) {
        let name = NSTextField(wrappingLabelWithString: "Pane Switcher for Rex")
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        add(name, to: view)
        let caption = help("Settings")
        add(caption, to: view)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        add(scroll, to: view)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.backgroundColor = .clear
        sidebar.style = .fullWidth
        sidebar.rowHeight = 38
        sidebar.intercellSpacing = NSSize(width: 0, height: 4)
        sidebar.allowsEmptySelection = false
        sidebar.allowsMultipleSelection = false
        sidebar.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("Settings sections")
        sidebar.setAccessibilityHelp("Use the Up and Down arrow keys to choose a settings section.")
        scroll.documentView = sidebar
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            name.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            name.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            caption.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            caption.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 26),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        sidebar.reloadData()
        sidebar.selectRowIndexes(IndexSet(integer: Section.appearance.rawValue), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let section = Section(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        add(image, to: cell)
        add(label, to: cell)
        cell.imageView = image
        cell.textField = label
        cell.setAccessibilityLabel(section.title)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let selected = Section(rawValue: sidebar.selectedRow) else { return }
        shortcut.stopRecording()
        highlightWell.deactivate()
        for (section, view) in sectionViews { view.isHidden = section != selected }
        refreshApplyState()
    }

    private func configureControls() {
        shortcut.bezelStyle = .rounded
        shortcut.setAccessibilityLabel("Switcher shortcut")
        shortcut.setAccessibilityHelp("Press to record a shortcut. Escape cancels recording; Tab moves to the next control.")
        shortcut.onError = { [weak self] error in self?.showError(error) }
        shortcut.onChange = { [weak self] in self?.refreshDraft() }
        shortcut.onRecordingChange = { [weak self] in self?.refreshApplyState() }
        density.target = self
        density.action = #selector(controlChanged)
        density.setAccessibilityLabel("Display density")
        density.setAccessibilityHelp("Comfortable uses the original spacing. Compact fits more panes in the same window without reducing text size.")
        for toggle in [globalShortcut, menuBarIcon, hostIcons, paneIcons, workingDirectory, keyboardLegend, jumpLabels, recentPanesFirst, launchAtLogin, debug] {
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = #selector(controlChanged)
        }
        executable.placeholderString = "Automatic detection"
        executable.delegate = self
        executable.setAccessibilityLabel("Rex executable path")
        executable.setAccessibilityHelp("Optional path to the Rex executable. Leave blank for automatic detection.")
        executable.setContentHuggingPriority(.defaultLow, for: .horizontal)
        executable.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        highlightHex.delegate = self
        highlightHex.placeholderString = "#007AFF"
        highlightHex.setAccessibilityLabel("Match highlight hex colour")
        highlightHex.setAccessibilityHelp("Enter six hexadecimal RGB digits, optionally preceded by #.")
        highlightHex.widthAnchor.constraint(equalToConstant: 100).isActive = true
        highlightWell.target = self
        highlightWell.action = #selector(highlightColorChanged)
        highlightWell.supportsAlpha = false
        highlightWell.setAccessibilityLabel("Match highlight colour picker")
        highlightValidation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        highlightValidation.textColor = .systemRed
    }

    private func makeSection(_ section: Section) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.borderType = .noBorder
        scroll.setAccessibilityLabel("\(section.title) settings")
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        add(stack, to: document)
        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let introduction = vertical([title, help(section.detail)], spacing: 7)
        stack.addArrangedSubview(introduction)
        introduction.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let cards: [NSView]
        switch section {
        case .appearance:
            let densityRow = vertical([rowTitle("Display density"), help("Choose how much space each pane uses."), density], spacing: 9, inset: 16)
            density.widthAnchor.constraint(equalTo: densityRow.widthAnchor, constant: -32).isActive = true
            let resetColor = NSButton(title: "Reset to Blue", target: self, action: #selector(resetHighlightColor))
            resetColor.bezelStyle = .rounded
            let colorControls = NSStackView(views: [highlightWell, highlightHex, resetColor])
            colorControls.spacing = 8
            let colorRow = vertical([
                rowTitle("Match highlight colour"),
                help("Colour matched letters in pane titles and paths."),
                colorControls,
                highlightValidation
            ], spacing: 9, inset: 16)
            cards = [card([
                densityRow,
                colorRow,
                toggleRow("Recent panes first", detail: "Show recently selected panes first within each host when browsing without search text. Search ranking stays unchanged.", control: recentPanesFirst, accessibility: "Show recent panes first"),
                toggleRow("Header icons", detail: "Show local and remote host symbols in host headings.", control: hostIcons, accessibility: "Show host heading icons"),
                toggleRow("Pane icons", detail: "Show program logos beside pane titles, using installed Rex artwork when available.", control: paneIcons, accessibility: "Show pane program icons"),
                toggleRow("Working directories", detail: "Show the path for each pane.", control: workingDirectory, accessibility: "Show working directories")
            ]), card([
                toggleRow("Keyboard legend", detail: "Show navigation hints in the picker footer.", control: keyboardLegend, accessibility: "Show keyboard legend"),
                toggleRow("Command-number jumps", detail: "Use ⌘1–9 and ⌘0 to jump to filtered results.", control: jumpLabels, accessibility: "Enable Command-number jump labels")
            ]), card([
                toggleRow("Menu-bar icon", detail: "Keep Pane Switcher for Rex within easy reach. Settings also open with ⌘, in the picker.", control: menuBarIcon, accessibility: "Show menu-bar icon")
            ])]
        case .shortcuts:
            let reset = NSButton(title: "Reset to Default", target: self, action: #selector(resetShortcut))
            reset.bezelStyle = .rounded
            reset.setAccessibilityLabel("Reset switcher shortcut to Control Command P")
            let buttons = NSStackView(views: [shortcut, reset])
            buttons.spacing = 8
            shortcut.setContentHuggingPriority(.defaultLow, for: .horizontal)
            shortcut.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
            let contents = vertical([
                rowTitle("Switcher shortcut"),
                help("Open Pane Switcher for Rex while Rex is frontmost, or enable the global shortcut below."),
                buttons,
                help("Click to record, then press a key with ⌘, ⌃, or ⌥. Escape cancels; Tab leaves recording. ⌘, and ⌘Q are reserved.")
            ], spacing: 12, inset: 16)
            buttons.widthAnchor.constraint(equalTo: contents.widthAnchor, constant: -32).isActive = true
            cards = [card([contents]), card([
                toggleRow("Global shortcut", detail: "Open from any app without bringing Rex forward. Selecting a pane activates Rex; Escape returns to the original app. Pane Switcher for Rex and Rex must already be running.", control: globalShortcut, accessibility: "Enable global shortcut")
            ])]
        case .advanced:
            let browse = NSButton(title: "Choose…", target: self, action: #selector(chooseExecutable))
            browse.bezelStyle = .rounded
            browse.setAccessibilityLabel("Choose Rex executable")
            let pathRow = NSStackView(views: [executable, browse])
            pathRow.spacing = 8
            let automatic = NSButton(title: "Use Automatic Detection", target: self, action: #selector(useAutomaticExecutable))
            automatic.bezelStyle = .rounded
            automatic.setAccessibilityHelp("Clear the custom executable path. Takes effect only after Apply.")
            let contents = vertical([
                rowTitle("Rex executable"),
                help("Leave the path blank to find Rex automatically, or choose a custom executable."),
                pathRow,
                automatic
            ], spacing: 12, inset: 16)
            pathRow.widthAnchor.constraint(equalTo: contents.widthAnchor, constant: -32).isActive = true
            let setup = NSButton(title: "Revisit Setup…", target: self, action: #selector(revisitSetup))
            setup.bezelStyle = .rounded
            setup.setAccessibilityHelp("Recheck Rex and choose a shortcut without resetting your preferences.")
            let setupContents = vertical([
                rowTitle("Setup"),
                help("Recheck Rex and choose a shortcut without resetting your preferences."),
                setup
            ], spacing: 12, inset: 16)
            cards = [card([
                toggleRow("Launch at login", detail: "Start Pane Switcher for Rex at your next login. Quitting keeps it stopped until you open it again or log in next time.", control: launchAtLogin, accessibility: "Launch Pane Switcher for Rex at login"),
                toggleRow("Debug diagnostics", detail: "Show result counts, per-host connection status, and launch, query, switch activation, local, and remote timings in the picker.", control: debug, accessibility: "Enable debug diagnostics")
            ]), card([contents]), card([setupContents])]
        case .about:
            let icon = NSImageView()
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
                icon.image = NSImage(contentsOf: url)
            }
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.setAccessibilityLabel("Pane Switcher for Rex app icon")
            icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
            let link = NSButton(title: "View on GitHub ↗", target: self, action: #selector(openProject))
            link.bezelStyle = .rounded
            cards = [card([vertical([
                icon, rowTitle("Pane Switcher for Rex"),
                updateStatus,
                link, help("Updates are installed manually. Check website for upgrade instructions")
            ], spacing: 14, inset: 16)])]
            updateStatus.setVersion(installedVersion)
            updateStatus.widthAnchor.constraint(equalTo: cards[0].widthAnchor, constant: -32).isActive = true
        }
        for card in cards {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)
        let minimumHeight = document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        minimumHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            minimumHeight
        ])
        return scroll
    }

    private func configurePreview(in view: NSView) {
        let divider = separator()
        add(divider, to: view)
        let title = NSTextField(labelWithString: "Live preview")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        add(title, to: view)
        let detail = help("Sample panes · your changes are not saved until you choose Apply.")
        add(detail, to: view)
        add(preview, to: view)
        preview.setAccessibilityLabel("Live preview of unapplied settings using sample panes")
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            preview.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 20),
            preview.heightAnchor.constraint(equalToConstant: 450),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
    }

    private func configureFooter(in view: NSView) {
        let divider = separator()
        add(divider, to: view)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.setAccessibilityLabel("Settings status")
        status.setAccessibilityElement(true)
        add(status, to: view)
        let quit = NSButton(title: "Quit Pane Switcher for Rex", target: NSApp,
                            action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.bezelColor = .systemRed
        quit.contentTintColor = .white
        quit.setAccessibilityHelp("Quit immediately without applying draft changes. Release shortcuts and stop Pane Switcher for Rex workers. Open the app manually or log in again with Launch at login enabled to use it again.")
        add(quit, to: view)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelChanges))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(applyChanges)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityHelp("Save and apply your changes. Disabled when there are no changes or while recording a shortcut.")
        add(cancel, to: view)
        add(applyButton, to: view)
        // Only the status area should absorb spare footer width.
        for button in [quit, cancel, applyButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            applyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            applyButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            quit.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            quit.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: quit.trailingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -20),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: 10),
            status.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10)
        ])
    }

    private func toggleRow(_ title: String, detail: String, control: NSSwitch, accessibility: String) -> NSView {
        control.setAccessibilityLabel(accessibility)
        control.setAccessibilityHelp(detail + " Changes take effect only after Apply.")
        let labels = vertical([rowTitle(title), help(detail)], spacing: 4)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSView()
        add(labels, to: row)
        add(control, to: row)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            labels.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
            labels.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -12),
            labels.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualTo: control.heightAnchor, constant: 24)
        ])
        return row
    }

    private func card(_ rows: [NSView]) -> NSView {
        let card = SettingsCardView()
        let stack = vertical([], spacing: 0)
        add(stack, to: card)
        pin(stack, to: card)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let container = NSView()
                let line = separator()
                add(line, to: container)
                stack.addArrangedSubview(container)
                NSLayoutConstraint.activate([
                    container.widthAnchor.constraint(equalTo: stack.widthAnchor),
                    container.heightAnchor.constraint(equalToConstant: 1),
                    line.topAnchor.constraint(equalTo: container.topAnchor),
                    line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                    line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
                ])
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }

    private func vertical(_ views: [NSView], spacing: CGFloat, inset: CGFloat = 0) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        for view in views where view is NSTextField {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
        }
        return stack
    }

    private func rowTitle(_ title: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    private func help(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func add(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
    }

    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    private func canonical(_ value: PickerSettings) -> PickerSettings {
        var value = value
        let path = value.rexExecutable?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        value.rexExecutable = path.isEmpty ? nil : path
        if let color = PickerHighlightColor.canonicalHex(value.highlightColor) {
            value.highlightColor = color
        }
        return value
    }

    private func draftSettings() -> PickerSettings {
        var draft = settings
        draft.shortcut = shortcut.value
        draft.globalShortcut = globalShortcut.state == .on
        draft.rexExecutable = executable.stringValue
        draft.showMenuBarIcon = menuBarIcon.state == .on
        draft.showHostIcons = hostIcons.state == .on
        draft.showPaneIcons = paneIcons.state == .on
        draft.showWorkingDirectory = workingDirectory.state == .on
        draft.showKeyboardLegend = keyboardLegend.state == .on
        draft.showJumpLabels = jumpLabels.state == .on
        draft.recentPanesFirst = recentPanesFirst.state == .on
        draft.launchAtLogin = launchAtLogin.state == .on
        draft.debug = debug.state == .on
        draft.density = density.selectedSegment == 1 ? .compact : .comfortable
        draft.highlightColor = validHighlightColor
        return canonical(draft)
    }

    private func refreshApplyState() {
        applyButton.isEnabled = !shortcut.isRecording
            && PickerHighlightColor.canonicalHex(highlightHex.stringValue) != nil
            && draftSettings() != settings
    }

    private func refreshDraft() {
        let draft = draftSettings()
        refreshApplyState()
        guard PickerHighlightColor.canonicalHex(highlightHex.stringValue) != nil else {
            highlightValidation.stringValue = "Enter a six-digit RGB hex colour, such as #007AFF."
            status.textColor = .systemRed
            status.stringValue = "Fix the highlight colour before applying changes."
            return
        }
        preview.update(draft)
        highlightValidation.stringValue = ""
        status.textColor = .secondaryLabelColor
        status.stringValue = draft == settings ? "No unapplied changes." : "Unapplied changes · preview only"
    }

    @objc private func controlChanged(_ sender: NSControl) {
        shortcut.stopRecording()
        refreshDraft()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === highlightHex,
           let color = PickerHighlightColor.canonicalHex(highlightHex.stringValue) {
            validHighlightColor = color
            syncHighlightWell()
        }
        refreshDraft()
    }

    private func syncHighlightWell() {
        guard let rgb = UInt32(validHighlightColor.dropFirst(), radix: 16) else { return }
        highlightWell.color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                     green: CGFloat((rgb >> 8) & 255) / 255,
                                     blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    @objc private func highlightColorChanged(_ sender: NSColorWell) {
        guard window?.isVisible == true, sender.isActive,
              let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        func channel(_ value: CGFloat) -> Int {
            Int((min(1, max(0, value)) * 255).rounded())
        }
        validHighlightColor = String(format: "#%02X%02X%02X",
                                     channel(rgb.redComponent), channel(rgb.greenComponent),
                                     channel(rgb.blueComponent))
        highlightHex.stringValue = validHighlightColor
        syncHighlightWell()
        refreshDraft()
    }

    @objc private func resetHighlightColor() {
        highlightWell.deactivate()
        validHighlightColor = PickerHighlightColor.defaultHex
        highlightHex.stringValue = validHighlightColor
        syncHighlightWell()
        refreshDraft()
    }

    @objc private func resetShortcut() {
        shortcut.stopRecording()
        shortcut.value = PickerSettings().shortcut
        refreshDraft()
    }

    @objc private func useAutomaticExecutable() {
        shortcut.stopRecording()
        executable.stringValue = ""
        refreshDraft()
    }

    @objc private func chooseExecutable() {
        shortcut.stopRecording()
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Rex Executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.executable.stringValue = path
            self?.refreshDraft()
        }
    }

    @objc private func openProject() {
        guard let url = URL(string: "https://github.com/Kristijan/pane-switcher-for-rex") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revisitSetup() { openSetup() }

    @objc private func cancelChanges() {
        close()
    }

    @objc private func applyChanges() {
        guard !shortcut.isRecording,
              PickerHighlightColor.canonicalHex(highlightHex.stringValue) != nil else { return }
        window?.makeFirstResponder(nil)
        let draft = draftSettings()
        guard draft != settings else { return }
        do {
            try applySettings(draft)
            update(draft)
            status.textColor = .secondaryLabelColor
            status.stringValue = "Settings saved."
        } catch {
            refreshApplyState()
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        status.textColor = .systemRed
        status.stringValue = error.localizedDescription
    }
}

@MainActor
private final class SettingsUpdateStatusView: NSView {
    enum State {
        case checking
        case upToDate
        case updateAvailable(String)
        case failure(String)
    }

    private let version = NSTextField(wrappingLabelWithString: "Version unavailable")
    private let pill = SettingsUpdatePill()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        version.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        version.textColor = .secondaryLabelColor
        version.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        version.setContentCompressionResistancePriority(.required, for: .vertical)
        version.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true
        let row = NSStackView(views: [version, pill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func setVersion(_ installedVersion: String?) {
        version.stringValue = installedVersion.map { "Version \($0)" } ?? "Version unavailable"
        version.toolTip = version.stringValue
    }

    func setState(_ state: State) {
        pill.setState(state)
    }
}

@MainActor
private final class SettingsUpdatePill: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let indicator = SettingsUpdateIndicator()
    private var tint = NSColor.systemGray

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.setAccessibilityElement(false)
        indicator.setAccessibilityElement(false)
        for view in [spinner, indicator] {
            view.widthAnchor.constraint(equalToConstant: 14).isActive = true
            view.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }
        let contents = NSStackView(views: [spinner, indicator, label])
        contents.orientation = .horizontal
        contents.alignment = .centerY
        contents.spacing = 5
        contents.detachesHiddenViews = true
        contents.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contents.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contents.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            contents.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
        setState(.checking)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func setState(_ state: SettingsUpdateStatusView.State) {
        let title: String
        let explanation: String
        let checking: Bool
        switch state {
        case .checking:
            title = "Checking for updates…"
            explanation = "Checking the latest published release on GitHub."
            tint = .systemGray
            indicator.ink = .darkGray
            indicator.isFailure = false
            checking = true
        case .upToDate:
            title = "Up to date"
            explanation = "No newer published release was found on GitHub."
            tint = .systemGreen
            indicator.ink = NSColor(calibratedRed: 0.08, green: 0.40, blue: 0.18, alpha: 1)
            indicator.isFailure = false
            checking = false
        case let .updateAvailable(version):
            title = "Update available"
            explanation = "Version \(version) is available on GitHub. Updates are installed manually. Check website for upgrade instructions"
            tint = .systemYellow
            indicator.ink = NSColor(calibratedRed: 0.48, green: 0.30, blue: 0.02, alpha: 1)
            indicator.isFailure = false
            checking = false
        case let .failure(message):
            title = "Unable to check for updates"
            explanation = "Unable to check for updates. \(message)"
            tint = .systemRed
            indicator.ink = NSColor(calibratedRed: 0.68, green: 0.12, blue: 0.14, alpha: 1)
            indicator.isFailure = true
            checking = false
        }
        label.stringValue = title
        label.setAccessibilityLabel("Update status: \(title)")
        label.setAccessibilityHelp(explanation)
        toolTip = explanation
        label.toolTip = explanation
        spinner.isHidden = !checking
        indicator.isHidden = checking
        if checking { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SettingsUpdateIndicator: NSView {
    var isFailure = false { didSet { needsDisplay = true } }
    var ink = NSColor.darkGray { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        NSColor.white.setFill()
        circle.fill()
        ink.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        let glyph = NSBezierPath()
        glyph.lineWidth = 1.6
        glyph.lineCapStyle = .round
        if isFailure {
            glyph.move(to: NSPoint(x: 4.5, y: 4.5))
            glyph.line(to: NSPoint(x: 9.5, y: 9.5))
            glyph.move(to: NSPoint(x: 4.5, y: 9.5))
            glyph.line(to: NSPoint(x: 9.5, y: 4.5))
        } else {
            glyph.move(to: NSPoint(x: 3.5, y: 7))
            glyph.line(to: NSPoint(x: 6, y: 4.5))
            glyph.line(to: NSPoint(x: 10.5, y: 9.5))
        }
        glyph.stroke()
    }
}

@MainActor
private final class SettingsMaterialView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        wantsLayer = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateAccessibilityAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateAccessibilityAppearance()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAccessibilityAppearance()
    }

    @objc private func updateAccessibilityAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                ? NSColor.windowBackgroundColor : .clear).cgColor
        }
    }
}

@MainActor
private final class SettingsSelectionRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.labelColor.withAlphaComponent(contrast ? 0.14 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

@MainActor
private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsCardView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var value = "" { didSet { refreshTitle() } }
    var onError: ((Error) -> Void)?
    var onChange: (() -> Void)?
    var onRecordingChange: (() -> Void)?
    private var monitor: Any?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(startRecording)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    @objc private func startRecording() {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        isRecording = true
        refreshTitle()
        onRecordingChange?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording, event.window === self.window else { return event }
            if event.keyCode == 48 {
                self.stopRecording()
                return event
            }
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            do {
                let shortcut = try PickerShortcut(event: event)
                self.value = shortcut.value
                self.stopRecording()
                self.onChange?()
            } catch {
                self.onError?(error)
            }
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let wasRecording = isRecording
        isRecording = false
        refreshTitle()
        if wasRecording { onRecordingChange?() }
    }

    private func refreshTitle() {
        title = isRecording ? "Press shortcut…" : ((try? PickerShortcut(value).display) ?? "Choose Shortcut…")
        setAccessibilityValue(isRecording ? "Recording shortcut" : title)
    }
}
