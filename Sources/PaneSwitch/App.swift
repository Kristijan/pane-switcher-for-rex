import AppKit
import PaneSwitchCore

struct PickerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func appLaunchAtLogin() -> LaunchAtLogin {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return LaunchAtLogin(
        plistURL: home.appendingPathComponent("Library/LaunchAgents/com.kristijan.paneswitch.plist"),
        executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        legacyExecutableURLs: [
            home.appendingPathComponent("Applications/Pane Switch.app/Contents/MacOS/PaneSwitch"),
            home.appendingPathComponent("Applications/Pane Switcher for Rex.app/Contents/MacOS/PaneSwitch"),
            URL(fileURLWithPath: "/Applications/Pane Switcher for Rex.app/Contents/MacOS/PaneSwitch")
        ]
    )
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let rexBundleID = "com.superlogical.rex"
    private let store = SettingsStore()
    private let launchAtLogin = appLaunchAtLogin()
    private var settings = PickerSettings()
    private var backend: RexBackend?
    private var backendExecutable: URL?
    private var picker: PickerController?
    private var hotKey: RexHotKey?
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsController?
    private var setupController: SetupController?
    private var opening: Task<Void, Never>?
    private var openingInvocation = UUID()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kristijan.paneswitch"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            let name = CommandLine.arguments.contains("--show") ? "com.kristijan.paneswitch.show" : "com.kristijan.paneswitch.settings"
            DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        _ = RexSymbolFont.shared
        installMainMenu()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPicker), name: .init("com.kristijan.paneswitch.show"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openSettings), name: .init("com.kristijan.paneswitch.settings"), object: nil)
        var configurationError: Error?
        do { settings = try store.load() }
        catch { configurationError = error }
        do {
            try launchAtLogin.migrateLegacyExecutable()
            // The agent remains authoritative even when settings need recovery.
            settings.launchAtLogin = try launchAtLogin.isEnabled()
            if let configurationError {
                updateStatusItem()
                openSetup(message: "The saved configuration could not be read: \(configurationError.localizedDescription) Your file is unchanged until you save a replacement.")
                return
            }
            if !settings.setupCompleted {
                updateStatusItem()
                openSetup()
                return
            }
            let shortcut = try PickerShortcut(settings.shortcut)
            try RexHotKey.validateAvailability(shortcut)
            configure(settings, shortcut: shortcut, executable: try executableURL(for: settings))
            if CommandLine.arguments.contains("--settings") { openSettings() }
            else if CommandLine.arguments.contains("--show") { showPicker() }
        } catch {
            updateStatusItem()
            openSetup(message: "The saved configuration could not be used: \(error.localizedDescription) Your file is unchanged until you save a replacement.")
        }
    }

    private func executableURL(for settings: PickerSettings) throws -> URL {
        if let override = settings.rexExecutable, !override.isEmpty {
            let path = NSString(string: override).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw PickerError("Rex executable must be an executable at an absolute path: \(path)")
            }
            return URL(fileURLWithPath: path)
        }
        let paths = ["/opt/homebrew/bin/rex", "/usr/local/bin/rex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/rex" }
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex").path,
               "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
               "/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw PickerError("Rex CLI not found. Choose its executable in Settings.")
        }
        return URL(fileURLWithPath: path)
    }

    private func configure(_ value: PickerSettings, shortcut: PickerShortcut, executable: URL) {
        cancelOpening()
        picker?.dismissForSettings()
        hotKey?.stop()
        let backend: RexBackend
        if let existing = self.backend, backendExecutable == executable {
            backend = existing
        } else {
            self.backend?.shutdown()
            backend = RexBackend(executable: executable)
            self.backend = backend
            backendExecutable = executable
        }
        backend.start()
        settings = value
        picker = PickerController(backend: backend, settings: value, openSettings: { [weak self] in self?.openSettings() })
        hotKey = RexHotKey(shortcut: shortcut, rexBundleID: rexBundleID, global: value.globalShortcut,
                           pressed: { [weak self] in self?.showPicker() },
                           failed: { [weak self] in self?.openSetup(message: $0) })
        updateStatusItem()
    }

    private func applySettings(_ value: PickerSettings) throws {
        let shortcut = try PickerShortcut(value.shortcut)
        let executable = try executableURL(for: value)
        if let hotKey { try hotKey.validateReplacement(shortcut) }
        else { try RexHotKey.validateAvailability(shortcut) }
        // Persist only after validation. A failed preferences write restores the
        // exact previous login agent and leaves the running configuration unchanged.
        if value.launchAtLogin != settings.launchAtLogin {
            try launchAtLogin.setEnabled(value.launchAtLogin) { try store.save(value) }
        } else {
            try store.save(value)
        }
        configure(value, shortcut: shortcut, executable: executable)
    }

    private func updateStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem); self.statusItem = nil }
        guard settings.showMenuBarIcon || backend == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Pane Switcher for Rex")
        let menu = NSMenu()
        let shortcut = try? PickerShortcut(settings.shortcut)
        let show = NSMenuItem(title: "Switch Pane…  \(shortcut?.display ?? "")", action: #selector(showPicker), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self; menu.addItem(preferences)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Pane Switcher for Rex", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let preferences = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self; appMenu.addItem(preferences)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Pane Switcher for Rex", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem)
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                     ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func cancelOpening() {
        openingInvocation = UUID()
        opening?.cancel()
        opening = nil
    }

    @objc private func showPicker() {
        let requestedAt = ContinuousClock.now
        guard opening == nil else { return }
        guard let backend, let picker else { openSetup(); return }
        if picker.focusIfVisible() { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        settingsController?.window?.orderOut(nil)
        setupController?.close()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: rexBundleID).filter { !$0.isTerminated }
        let app: NSRunningApplication
        if let frontmost, frontmost.bundleIdentifier == rexBundleID { app = frontmost }
        else if apps.count == 1 { app = apps[0] }
        else { report("Focus the Rex app you want to switch in, then press the shortcut."); return }
        let run = UUID()
        openingInvocation = run
        opening = Task { [weak self] in
            defer {
                if self?.openingInvocation == run { self?.opening = nil }
            }
            do {
                let clients = try await backend.appClients()
                guard !Task.isCancelled, let self, self.openingInvocation == run else { return }
                let matching = clients.filter { $0.pid == app.processIdentifier }
                guard matching.count == 1, let client = matching.first else {
                    throw PickerError("Cannot identify this Rex app's local client. Keep Rex and its local server running.")
                }
                guard !Task.isCancelled, !app.isTerminated else { return }
                picker.show(clientID: client.id, rexApp: app, returningTo: frontmost, requestedAt: requestedAt)
            } catch {
                if !Task.isCancelled, let self, self.openingInvocation == run {
                    self.report(error.localizedDescription)
                }
            }
        }
    }

    @objc private func openSettings() {
        cancelOpening()
        setupController?.close()
        picker?.dismissForSettings()
        if settingsController == nil {
            settingsController = SettingsController(settings: settings, apply: { [weak self] value in
                guard let self else { throw PickerError("Pane Switcher for Rex is no longer running.") }
                try self.applySettings(value)
            }, openSetup: { [weak self] in self?.openSetup() })
        }
        if settingsController?.window?.isVisible != true { settingsController?.update(settings) }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(nil)
        settingsController?.window?.deminiaturize(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    private func openSetup(message: String? = nil) {
        cancelOpening()
        picker?.dismissForSettings()
        settingsController?.close()
        if setupController?.window?.isVisible == true {
            setupController?.begin()
            return
        }
        setupController?.cancelChecks()
        setupController = SetupController(settings: settings, message: message,
            check: { [weak self] value in
                guard let self else { throw CancellationError() }
                return try await self.checkSetup(value)
            }, save: { [weak self] value in
                guard let self else { throw PickerError("Pane Switcher for Rex is no longer running.") }
                try self.applySettings(value)
                self.settingsController?.update(value)
            })
        setupController?.begin()
    }

    private func checkSetup(_ value: PickerSettings) async throws -> SetupReadiness {
        var readiness = SetupReadiness()
        do {
            let shortcut = try PickerShortcut(value.shortcut)
            if let hotKey { try hotKey.validateReplacement(shortcut) }
            else { try RexHotKey.validateAvailability(shortcut) }
            readiness.checks[.shortcut] = .passed("\(shortcut.display) is available. Change it in the Shortcut section above.")
        } catch {
            readiness.checks[.shortcut] = .failed("Choose an available shortcut.", detail: error.localizedDescription)
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: rexBundleID).filter { !$0.isTerminated }
        let installed = !apps.isEmpty || NSWorkspace.shared.urlForApplication(withBundleIdentifier: rexBundleID) != nil
        readiness.checks[.installed] = installed
            ? .passed("Rex is installed on this Mac.")
            : .failed("Install Rex, then recheck.", detail: "Download Rex from superlogical.com/rex.")
        readiness.checks[.running] = !apps.isEmpty
            ? .passed("Rex is running.")
            : .failed("Open Rex, then recheck.", detail: "Rex and its local server must be running before setup can finish.")
        let executable: URL
        do {
            executable = try executableURL(for: value)
            readiness.checks[.cli] = .passed("Rex's command-line tool was found at \(executable.path).")
        } catch {
            readiness.checks[.cli] = .failed("Open Rex or choose a valid custom CLI path.", detail: error.localizedDescription)
            readiness.checks[.connection] = .pending("Waiting for a valid Rex command-line tool.")
            return readiness
        }
        guard installed, !apps.isEmpty else {
            readiness.checks[.connection] = .pending("Waiting for Rex to run before checking its local connection.")
            return readiness
        }
        do {
            let clients = try await RexSetupProbe.appClients(executable: executable)
            try Task.checkCancellation()
            let pids = Set(apps.map(\.processIdentifier))
            let matched = clients.filter { $0.pid.map(pids.contains) ?? false }
            let identifiable = apps.allSatisfy { app in matched.filter { $0.pid == app.processIdentifier }.count == 1 }
            readiness.checks[.connection] = identifiable
                ? .passed("The local Rex server is reachable and each running Rex app has an identifiable client. This does not verify Remote Control.")
                : .failed("Restart Rex's local server, then recheck.", detail: "No unique local client was found for each running Rex app.")
        } catch {
            try Task.checkCancellation()
            readiness.checks[.connection] = .failed("Start Rex's local server, then recheck.", detail: error.localizedDescription)
        }
        return readiness
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Pane Switcher for Rex"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        setupController?.cancelChecks()
        cancelOpening(); picker?.dismissForSettings(); hotKey?.stop(); backend?.shutdown()
        DistributedNotificationCenter.default().removeObserver(self)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(); return false
    }
}

@main struct PaneSwitchApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--help") {
            print("Pane Switcher for Rex: native Rex pane picker. --show opens the picker; --settings opens native settings. Reopening the app also opens settings, even with the menu icon hidden.")
            return
        }
        // Installer-only operations finish before AppKit or backend workers start.
        if CommandLine.arguments.contains("--migrate-login-agent")
            || CommandLine.arguments.contains("--enable-login-agent") {
            do {
                let login = appLaunchAtLogin()
                if CommandLine.arguments.contains("--enable-login-agent") {
                    try login.setEnabled(true)
                } else {
                    try login.migrateLegacyExecutable()
                }
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
