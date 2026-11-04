import AppKit
import PaneSwitchCore

/// Normal shortcut delivery belongs to Carbon; native tracking temporarily owns its
/// equivalent instead. Do not turn a detached status-menu equivalent into an app shortcut.
final class ShortcutDisplayMenu: NSMenu {
    var pickerShortcut: PickerShortcut?
    var ownsPickerShortcut = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !ownsPickerShortcut, pickerShortcut?.matchesMenuEvent(event) == true { return false }
        return super.performKeyEquivalent(with: event)
    }
}

extension PickerShortcut {
    func matchesMenuEvent(_ event: NSEvent) -> Bool {
        event.type == .keyDown && UInt32(event.keyCode) == keyCode
            && event.modifierFlags.intersection([.control, .option, .shift, .command]) == menuModifierMask
    }
}

@MainActor
final class PaneMenuController: NSObject, NSMenuDelegate {
    private let settings: PickerSettings
    private weak var rootMenu: NSMenu?
    private let panesMenu = NSMenu(title: "Panes")
    private let captureTarget: () -> RexApplicationTarget
    private let select: (Pane, RexApplicationTarget) -> Void
    private weak var pickerItem: NSMenuItem?
    private let shortcut: PickerShortcut?
    private let trackingChanged: (Bool) -> Void
    private var latest = PaneDiscoverySnapshot()
    private var observation: Task<Void, Never>?

    init(backend: RexBackend, settings: PickerSettings, menu: NSMenu,
         pickerItem: NSMenuItem? = nil, trackingChanged: @escaping (Bool) -> Void = { _ in },
         captureTarget: @escaping () -> RexApplicationTarget,
         select: @escaping (Pane, RexApplicationTarget) -> Void) {
        self.settings = settings
        self.rootMenu = menu
        self.captureTarget = captureTarget
        self.select = select
        self.pickerItem = pickerItem
        self.shortcut = try? PickerShortcut(settings.shortcut)
        self.trackingChanged = trackingChanged
        super.init()
        menu.autoenablesItems = false
        panesMenu.autoenablesItems = false
        let item = NSMenuItem(title: "Panes", action: nil, keyEquivalent: "")
        item.submenu = panesMenu
        menu.addItem(item)
        menu.delegate = self
        observation = Task { [weak self, backend] in
            for await event in backend.discover() {
                guard !Task.isCancelled, let self else { return }
                self.latest.receive(event)
                if case .panes(_, let panes) = event, settings.showPaneIcons {
                    RexIconProvider.shared.preload(commands: panes.map(\.command))
                }
            }
        }
    }

    deinit { observation?.cancel() }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === rootMenu else { return }
        // Capture both inventory and Rex application before submenu tracking can change focus.
        // Live events update only `latest`; never mutate any menu in a visible hierarchy.
        let target = captureTarget()
        pickerItem?.keyEquivalent = settings.globalShortcut || target.isRexFrontmost
            ? shortcut?.menuKeyEquivalent ?? "" : ""
        trackingChanged(true)
        (menu as? ShortcutDisplayMenu)?.ownsPickerShortcut = true
        rebuild(from: latest, target: target)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === rootMenu else { return }
        (menu as? ShortcutDisplayMenu)?.ownsPickerShortcut = false
        trackingChanged(false)
    }

    private func rebuild(from snapshot: PaneDiscoverySnapshot, target: RexApplicationTarget) {
        panesMenu.removeAllItems()
        guard target.isRexRunning else {
            addExplanation("Open Rex to browse panes", to: panesMenu)
            return
        }
        let list = snapshot.browsingList
        let panesByHost = Dictionary(grouping: list.panes, by: { $0.host.id })
        var labels: [String: (title: String, full: String)] = [:]
        for row in list.rows {
            switch row {
            case .host(let host):
                if !panesMenu.items.isEmpty { panesMenu.addItem(.separator()) }
                let heading = NSMenuItem.sectionHeader(title: truncated(host.label))
                heading.isEnabled = false
                heading.toolTip = host.label
                panesMenu.addItem(heading)
                labels = menuLabels(for: panesByHost[host.id] ?? [])
            case .pane(let index):
                let pane = list.panes[index]
                let label = labels[pane.id] ?? (title: truncated(pane.displayPrimaryText), full: pane.displayPrimaryText)
                let item = NSMenuItem(title: label.title, action: #selector(selectPane(_:)), keyEquivalent: "")
                if label.title.unicodeScalars.contains(where: { $0.properties.generalCategory == .privateUse }) {
                    let attributed = NSMutableAttributedString(string: label.title)
                    RexSymbolFont.shared.apply(to: attributed, size: NSFont.menuFont(ofSize: 0).pointSize)
                    item.attributedTitle = attributed
                }
                item.target = self
                item.representedObject = Selection(pane: pane, target: target)
                item.toolTip = [label.full, pane.secondaryText, pane.command].filter { !$0.isEmpty }.joined(separator: "\n")
                if settings.showPaneIcons {
                    let icon = RexIconProvider.shared.image(forCommand: pane.command).copy() as! NSImage
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                panesMenu.addItem(item)
            }
        }
        if panesMenu.items.isEmpty {
            let details = ([snapshot.warning].compactMap { $0 } + snapshot.hostDiscoveryWarnings).joined(separator: "\n")
            addExplanation(snapshot.isDiscovering ? "Connecting to Rex…" : "No panes available",
                           detail: details.isEmpty ? nil : details, to: panesMenu)
        }
    }

    private func menuLabels(for panes: [Pane]) -> [String: (title: String, full: String)] {
        var labels = panes.map { RexSymbolFont.shared.displayText($0.displayPrimaryText) }
        let primaryCounts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        for index in panes.indices where primaryCounts[labels[index], default: 0] > 1 {
            let context = RexSymbolFont.shared.displayText(panes[index].displaySecondaryText(showWorkingDirectory: false))
            if !context.isEmpty { labels[index] += " — " + context }
        }
        let contextCounts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        for index in panes.indices where contextCounts[labels[index], default: 0] > 1 && !panes[index].directory.isEmpty {
            labels[index] += " · " + RexSymbolFont.shared.displayText(panes[index].directory)
        }
        let displayed = labels.map(truncated)
        let displayedCounts = Dictionary(displayed.map { ($0, 1) }, uniquingKeysWith: +)
        var ordinals: [String: Int] = [:]
        var result: [String: (title: String, full: String)] = [:]
        for index in panes.indices {
            var title = displayed[index]
            var full = labels[index]
            if displayedCounts[title, default: 0] > 1 {
                ordinals[title, default: 0] += 1
                let suffix = " [\(ordinals[title]!)]"
                title = String(title.prefix(72 - suffix.count)) + suffix
                full += suffix
            }
            result[panes[index].id] = (title, full)
        }
        return result
    }

    @objc private func selectPane(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? Selection else { return }
        rootMenu?.cancelTracking()
        // Leave the native tracking loop before activating Rex or presenting a selection error.
        let select = select
        DispatchQueue.main.async { select(selection.pane, selection.target) }
    }

    private func truncated(_ text: String) -> String {
        text.count > 72 ? String(text.prefix(71)) + "…" : text
    }

    private func addExplanation(_ title: String, detail: String? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = detail ?? title
        menu.addItem(item)
    }

    private final class Selection {
        let pane: Pane
        let target: RexApplicationTarget
        init(pane: Pane, target: RexApplicationTarget) { self.pane = pane; self.target = target }
    }
}
