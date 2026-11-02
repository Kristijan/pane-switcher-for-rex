import AppKit
import PaneSwitchCore

struct SetupReadiness {
    enum Check: CaseIterable {
        case shortcut, installed, running, connection, cli

        var title: String {
            switch self {
            case .shortcut: return "Shortcut available"
            case .installed: return "Rex installed"
            case .running: return "Rex running"
            case .cli: return "Rex CLI"
            case .connection: return "Rex connection"
            }
        }
    }

    enum Result {
        case pending(String)
        case passed(String)
        case failed(String, detail: String)

        var detail: String {
            switch self {
            case .pending(let detail), .passed(let detail): return detail
            case .failed(_, let detail): return detail
            }
        }

        var status: String {
            switch self {
            case .pending: return "Not verified"
            case .passed: return "Passed"
            case .failed: return "Failed"
            }
        }
    }

    var checks: [Check: Result] = [:]

    var ready: Bool {
        Check.allCases.allSatisfy {
            if case .passed? = checks[$0] { return true }
            return false
        }
    }

    var firstIssue: String? {
        for check in Check.allCases {
            if case .failed(let message, _)? = checks[check] { return message }
        }
        return nil
    }
}

@MainActor
final class SetupController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private var settings: PickerSettings
    private let check: (PickerSettings) async throws -> SetupReadiness
    private let save: (PickerSettings) throws -> Void
    private let shortcut = ShortcutRecorderButton()
    private let global = NSButton(checkboxWithTitle: "Enable shortcut from every app (optional)", target: nil, action: nil)
    private let executable = NSTextField()
    private var checkRows: [SetupReadiness.Check: SetupCheckRow] = [:]
    private let pathControls = NSStackView()
    private let pathToggle = NSButton(title: "Custom CLI path", target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let finish = NSButton(title: "Finish Setup", target: nil, action: nil)
    private var checking: Task<Void, Never>?
    private var generation = UUID()
    private var ready = false

    init(settings: PickerSettings, message: String?,
         check: @escaping (PickerSettings) async throws -> SetupReadiness,
         save: @escaping (PickerSettings) throws -> Void) {
        self.settings = settings
        self.check = check
        self.save = save
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.title = "Set Up Pane Switcher for Rex"
        window.isReleasedWhenClosed = false
        window.delegate = self
        configureContent(message: message)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(settings:message:check:save:)") }

    func begin() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        recheck()
    }

    func cancelChecks() {
        generation = UUID()
        checking?.cancel()
        checking = nil
        shortcut.stopRecording()
    }

    func windowWillClose(_ notification: Notification) { cancelChecks() }

    private func configureContent(message: String?) {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.drawsBackground = false
        content.addSubview(scroll)
        let stack = SetupStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 16, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        func append(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        let title = NSTextField(labelWithString: "Set up your switcher")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let introduction = vertical([title, caption("Runs in the menu bar. Reopen the app anytime for Settings.")], spacing: 5)
        let header = NSView()
        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon.image = NSImage(contentsOf: url)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Pane Switcher for Rex app icon")
        for view in [introduction, icon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            introduction.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            introduction.trailingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -16),
            introduction.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            introduction.topAnchor.constraint(greaterThanOrEqualTo: header.topAnchor),
            introduction.bottomAnchor.constraint(lessThanOrEqualTo: header.bottomAnchor),
            icon.topAnchor.constraint(equalTo: header.topAnchor),
            icon.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            icon.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48)
        ])
        append(header)
        if let message {
            let warning = caption(message)
            warning.textColor = .systemOrange
            append(warning)
        }
        append(separator())

        shortcut.value = settings.shortcut
        shortcut.bezelStyle = .rounded
        shortcut.setAccessibilityLabel("Switcher shortcut")
        shortcut.setAccessibilityHelp("Click, then press a letter, digit, or Space with Command, Control, or Option. Escape cancels recording.")
        shortcut.onChange = { [weak self] in self?.invalidateCheck() }
        shortcut.onError = { [weak self] in self?.showError($0) }
        shortcut.onRecordingChange = { [weak self] in self?.refreshFinish() }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .rounded
        reset.toolTip = "Restore Control–Command–P."
        reset.setAccessibilityLabel("Reset shortcut to Control Command P")
        let shortcuts = NSStackView(views: [shortcut, reset])
        shortcuts.spacing = 8
        global.title = "Open from any app"
        global.state = settings.globalShortcut ? .on : .off
        global.target = self; global.action = #selector(changed)
        global.toolTip = "Off: the shortcut works only while Rex is frontmost. On: open the picker from any app; selecting a pane activates Rex."
        global.setAccessibilityHelp(global.toolTip)
        append(vertical([
            heading("Shortcut", help: "Click to record your shortcut, or keep Control–Command–P."),
            shortcuts, global
        ]))
        append(separator())

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 7
        for check in SetupReadiness.Check.allCases {
            let row = SetupCheckRow(check: check)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            checkRows[check] = row
        }
        executable.stringValue = settings.rexExecutable ?? ""
        executable.placeholderString = "Automatic detection"
        executable.delegate = self
        executable.setAccessibilityLabel("Rex executable path")
        executable.toolTip = "Leave blank to detect Rex automatically, or enter an absolute path to its executable."
        pathControls.orientation = .vertical
        pathControls.alignment = .leading
        pathControls.spacing = 5
        pathControls.addArrangedSubview(executable)
        executable.widthAnchor.constraint(equalTo: pathControls.widthAnchor).isActive = true
        pathControls.isHidden = executable.stringValue.isEmpty
        pathToggle.isBordered = false
        pathToggle.font = .systemFont(ofSize: 12)
        pathToggle.contentTintColor = .secondaryLabelColor
        pathToggle.imagePosition = .imageLeading
        pathToggle.target = self; pathToggle.action = #selector(togglePath)
        updatePathToggle()
        append(vertical([
            heading("Rex readiness", help: "Green: passed. Red: needs attention. Grey: pending or not checked. Hover over each question mark for details."),
            rows, pathToggle, pathControls
        ], spacing: 10))
        append(separator())

        let remoteControlHeading = NSTextField(labelWithString: "Remote Control")
        remoteControlHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        append(vertical([remoteControlHeading, remoteControlWarning()]))
        append(feedback)
        feedback.font = .systemFont(ofSize: 12)
        feedback.setAccessibilityLabel("Setup feedback")
        feedback.isHidden = true

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)
        let divider = separator()
        divider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(divider)
        let retry = NSButton(title: "Recheck", target: self, action: #selector(recheck))
        let later = NSButton(title: "Set Up Later", target: self, action: #selector(deferSetup))
        later.keyEquivalent = "\u{1b}"
        later.toolTip = "Close setup without saving. Reopen the app and visit Settings → About to return."
        finish.target = self; finish.action = #selector(finishSetup)
        finish.keyEquivalent = "\r"
        finish.setAccessibilityHelp("Recheck prerequisites and save the chosen shortcut. The Remote Control reminder does not require acknowledgement.")
        for button in [retry, later, finish] {
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            footer.addSubview(button)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64),
            divider.topAnchor.constraint(equalTo: footer.topAnchor),
            divider.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            divider.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            retry.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            retry.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            finish.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            finish.centerYAnchor.constraint(equalTo: retry.centerYAnchor),
            later.trailingAnchor.constraint(equalTo: finish.leadingAnchor, constant: -8),
            later.centerYAnchor.constraint(equalTo: retry.centerYAnchor)
        ])
        renderChecks(SetupReadiness())
        refreshFinish()
    }

    private func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views where view !== pathToggle {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func heading(_ title: String, help: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let row = NSStackView(views: [label, setupHelpIcon(help)])
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func remoteControlWarning() -> NSBox {
        let warning = NSBox()
        warning.boxType = .custom
        warning.titlePosition = .noTitle
        warning.borderWidth = 1
        warning.cornerRadius = 8
        warning.fillColor = NSColor.systemYellow.withAlphaComponent(0.10)
        warning.borderColor = NSColor.systemYellow.withAlphaComponent(0.35)
        warning.contentViewMargins = NSSize(width: 12, height: 12)
        warning.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        let symbol = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                               accessibilityDescription: "Required in Rex")!)
        symbol.contentTintColor = .systemYellow
        symbol.widthAnchor.constraint(equalToConstant: 16).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let text = caption("Enable Remote Control in Rex Settings → Server.")
        text.textColor = .labelColor
        let instruction = NSMutableAttributedString(string: text.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
        ])
        for phrase in ["Remote Control", "Settings", "Server"] {
            instruction.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12),
                                     range: (text.stringValue as NSString).range(of: phrase))
        }
        text.attributedStringValue = instruction
        let explanation = caption("We can’t reliably check this setting. You need to enable it manually.")
        explanation.textColor = .labelColor
        let row = NSStackView(views: [symbol, vertical([text, explanation], spacing: 5)])
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        if let content = warning.contentView {
            content.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                row.topAnchor.constraint(equalTo: content.topAnchor),
                row.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        return warning
    }

    private func separator() -> NSBox {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    @objc private func togglePath() {
        pathControls.isHidden.toggle()
        updatePathToggle()
        if !pathControls.isHidden { window?.makeFirstResponder(executable) }
    }

    private func updatePathToggle() {
        pathToggle.image = NSImage(systemSymbolName: pathControls.isHidden ? "chevron.right" : "chevron.down",
                                  accessibilityDescription: nil)
        pathToggle.setAccessibilityLabel(pathControls.isHidden ? "Show custom CLI path" : "Hide custom CLI path")
    }

    private func renderChecks(_ readiness: SetupReadiness, pending: String = "Not checked yet.") {
        for check in SetupReadiness.Check.allCases {
            checkRows[check]?.update(readiness.checks[check] ?? .pending(pending))
        }
    }

    private func setFeedback(_ message: String?, error: Bool = false) {
        feedback.stringValue = message ?? ""
        feedback.textColor = error ? .systemRed : .secondaryLabelColor
        feedback.isHidden = message?.isEmpty != false
    }

    private func draft() -> PickerSettings {
        var value = settings
        value.shortcut = shortcut.value
        value.globalShortcut = global.state == .on
        let path = executable.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.rexExecutable = path.isEmpty ? nil : path
        return value
    }

    private func invalidateCheck() {
        cancelChecks()
        ready = false
        renderChecks(SetupReadiness(), pending: "Settings changed. Choose Recheck.")
        setFeedback("Settings changed. Choose Recheck.")
        refreshFinish()
    }

    private func refreshFinish() {
        finish.isEnabled = ready && checking == nil && !shortcut.isRecording
    }

    @objc private func resetShortcut() {
        shortcut.value = PickerSettings().shortcut
        invalidateCheck()
    }
    @objc private func changed() { invalidateCheck() }
    func controlTextDidChange(_ obj: Notification) { invalidateCheck() }
    @objc private func deferSetup() { close() }
    @objc private func recheck() { runCheck(finishing: false) }
    @objc private func finishSetup() {
        guard !shortcut.isRecording else { return }
        runCheck(finishing: true)
    }

    private func runCheck(finishing: Bool) {
        cancelChecks()
        ready = false
        let token = generation
        let value = draft()
        renderChecks(SetupReadiness(), pending: "Checking…")
        setFeedback(nil)
        checking = Task { [weak self] in
            guard let self else { return }
            do {
                let readiness = try await check(value)
                guard !Task.isCancelled, token == generation else { return }
                renderChecks(readiness)
                let issue = readiness.firstIssue
                setFeedback(issue, error: issue != nil)
                ready = readiness.ready
                checking = nil
                if finishing, ready {
                    var completed = value
                    completed.setupCompleted = true
                    try save(completed)
                    settings = completed
                    close()
                }
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                checking = nil
                ready = false
                renderChecks(SetupReadiness(), pending: "The check could not finish. Choose Recheck.")
                showError(error)
            }
            refreshFinish()
        }
        refreshFinish()
    }

    private func showError(_ error: Error) {
        setFeedback(error.localizedDescription, error: true)
    }
}

@MainActor
private final class SetupStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private func setupHelpIcon(_ detail: String) -> NSImageView {
    let icon = NSImageView(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "More information")!)
    icon.contentTintColor = .secondaryLabelColor
    icon.toolTip = detail
    icon.setAccessibilityHelp(detail)
    icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
    return icon
}

@MainActor
private final class SetupCheckRow: NSStackView {
    private let check: SetupReadiness.Check
    private let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
    private let help = setupHelpIcon("Not checked yet.")

    init(check: SetupReadiness.Check) {
        self.check = check
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 9
        let label = NSTextField(labelWithString: check.title)
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [dot, label, help] { addArrangedSubview(view) }
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        dot.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        update(.pending("Not checked yet."))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(check:)") }

    func update(_ result: SetupReadiness.Result) {
        switch result {
        case .passed: dot.contentTintColor = .systemGreen
        case .failed: dot.contentTintColor = .systemRed
        case .pending: dot.contentTintColor = .tertiaryLabelColor
        }
        help.toolTip = result.detail
        help.setAccessibilityHelp(result.detail)
        toolTip = result.detail
        setAccessibilityLabel("\(check.title): \(result.status)")
        setAccessibilityHelp(result.detail)
    }
}
