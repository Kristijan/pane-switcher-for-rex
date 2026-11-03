import AppKit
import Carbon

struct PickerShortcut {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String
    let value: String
    let menuKeyEquivalent: String

    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    private static let codes: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "space": 49,
    ]

    init(_ value: String) throws {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts == ["cmd", ","] || parts == ["command", ","] {
            throw PickerError("Command-comma is reserved for Settings. Choose another shortcut.")
        }
        guard let last = parts.last, let code = Self.codes[last], parts.count >= 2 else {
            throw PickerError("Shortcut must contain modifiers and a letter, digit, or space, e.g. ctrl+cmd+p.")
        }
        var flags: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": flags |= UInt32(controlKey)
            case "cmd", "command": flags |= UInt32(cmdKey)
            case "shift": flags |= UInt32(shiftKey)
            case "alt", "option": flags |= UInt32(optionKey)
            default: throw PickerError("Unknown shortcut modifier: \(part)")
            }
        }
        guard flags & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            throw PickerError("Shortcut needs Command, Control, or Option; Shift alone would intercept normal typing.")
        }
        guard !(code == 12 && flags == UInt32(cmdKey)) else {
            throw PickerError("Command-Q is reserved for quitting Pane Switcher for Rex. Choose another shortcut in Settings.")
        }
        keyCode = code; modifiers = flags
        display = (flags & UInt32(controlKey) != 0 ? "⌃" : "")
            + (flags & UInt32(optionKey) != 0 ? "⌥" : "")
            + (flags & UInt32(shiftKey) != 0 ? "⇧" : "")
            + (flags & UInt32(cmdKey) != 0 ? "⌘" : "") + last.uppercased()
        self.value = Self.canonicalValue(key: last, modifiers: flags)
        menuKeyEquivalent = last == "space" ? " " : last
    }

    init(event: NSEvent) throws {
        guard event.type == .keyDown else {
            throw PickerError("Press a letter, digit, or Space with Command, Control, or Option.")
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, event.keyCode == 43 {
            throw PickerError("Command-comma is reserved for Settings. Choose another shortcut.")
        }
        guard let key = Self.codes.first(where: { $0.value == UInt32(event.keyCode) })?.key else {
            throw PickerError("This key cannot be used as a shortcut. Choose a letter, digit, or Space.")
        }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        try self.init(Self.canonicalValue(key: key, modifiers: modifiers))
    }

    private static func canonicalValue(key: String, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

@MainActor
final class RexHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?
    private let shortcut: PickerShortcut
    private let rexBundleID: String
    private let global: Bool
    private var menuTracking = false
    private let pressed: () -> Void
    private let failed: (String) -> Void

    init(shortcut: PickerShortcut, rexBundleID: String, global: Bool = false,
         pressed: @escaping () -> Void, failed: @escaping (String) -> Void) {
        self.shortcut = shortcut; self.rexBundleID = rexBundleID
        self.global = global
        self.pressed = pressed; self.failed = failed
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<RexHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                // Recheck at delivery: the frontmost app may have changed since registration.
                if !owner.menuTracking,
                   owner.global || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == owner.rexBundleID {
                    owner.pressed()
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { failed("Cannot install shortcut handler (macOS status \(status)).") }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in MainActor.assumeIsolated {
            guard let self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.update(active: application?.bundleIdentifier == self.rexBundleID)
        } }
        update(active: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == rexBundleID)
    }

    func validateReplacement(_ candidate: PickerShortcut) throws {
        // Re-registering our own combination would report eventHotKeyExistsErr.
        if hotKey != nil, candidate.keyCode == shortcut.keyCode,
           candidate.modifiers == shortcut.modifiers { return }
        try Self.validateAvailability(candidate)
    }

    static func validateAvailability(_ shortcut: PickerShortcut) throws {
        var probe: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x50534E57, id: 2)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                        GetApplicationEventTarget(), 0, &probe)
        guard status == noErr, let probe else {
            throw PickerError("Cannot register \(shortcut.display) (macOS status \(status)). It may already be in use. Choose another shortcut in Settings.")
        }
        UnregisterEventHotKey(probe)
    }

    private func update(active: Bool) {
        let active = !menuTracking && (global || active)
        // frontmostApplication can still describe the previous app during an activation notification.
        if !active, let hotKey {
            UnregisterEventHotKey(hotKey); self.hotKey = nil
        } else if active, hotKey == nil {
            let id = EventHotKeyID(signature: 0x50534E57, id: 1)
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                            GetApplicationEventTarget(), 0, &hotKey)
            if status != noErr {
                failed("Cannot register \(shortcut.display) (macOS status \(status)). Choose another shortcut in Settings.")
            }
        }
    }

    /// Native menu tracking does not deliver Carbon hot-key events. Hand this one
    /// registration to the menu temporarily, rather than registering a second shortcut.
    func setMenuTracking(_ tracking: Bool) {
        guard menuTracking != tracking else { return }
        menuTracking = tracking
        update(active: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == rexBundleID)
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }
}
