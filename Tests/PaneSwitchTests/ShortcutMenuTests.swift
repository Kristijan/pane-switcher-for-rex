import AppKit
import Carbon
import Testing
@testable import PaneSwitch

struct ShortcutMenuTests {
    @Test func lettersDigitsAndSpaceUseNativeKeyEquivalents() throws {
        for key in "abcdefghijklmnopqrstuvwxyz0123456789" {
            let shortcut = try PickerShortcut("ctrl+\(key)")
            #expect(shortcut.menuKeyEquivalent == String(key))
            #expect(shortcut.menuModifierMask == .control)
        }
        let space = try PickerShortcut("option+space")
        #expect(space.menuKeyEquivalent == " ")
        #expect(space.menuModifierMask == .option)
    }

    @Test func everyValidModifierCombinationPreservesShiftAndCarbonFlags() throws {
        let modifiers: [(String, NSEvent.ModifierFlags, UInt32)] = [
            ("ctrl", .control, UInt32(controlKey)),
            ("option", .option, UInt32(optionKey)),
            ("shift", .shift, UInt32(shiftKey)),
            ("cmd", .command, UInt32(cmdKey)),
        ]
        for bits in 1..<16 where bits != 4 {
            var parts: [String] = []
            var nativeFlags: NSEvent.ModifierFlags = []
            var carbonFlags: UInt32 = 0
            for (index, modifier) in modifiers.enumerated() where bits & (1 << index) != 0 {
                parts.append(modifier.0)
                nativeFlags.insert(modifier.1)
                carbonFlags |= modifier.2
            }
            for (key, equivalent, code) in [("p", "p", UInt32(35)), ("1", "1", UInt32(18)), ("space", " ", UInt32(49))] {
                let shortcut = try PickerShortcut((parts + [key]).joined(separator: "+"))
                #expect(shortcut.menuKeyEquivalent == equivalent)
                #expect(shortcut.menuModifierMask == nativeFlags)
                #expect(shortcut.modifiers == carbonFlags)
                #expect(shortcut.keyCode == code)
            }
        }
    }

    @Test func uppercaseAndModifierAliasesUseCanonicalNativeRepresentation() throws {
        let shortcut = try PickerShortcut("CONTROL+ALT+SHIFT+COMMAND+P")
        #expect(shortcut.menuKeyEquivalent == "p")
        #expect(shortcut.menuModifierMask == [.control, .option, .shift, .command])
        #expect(shortcut.value == "ctrl+option+shift+cmd+p")
    }

    @Test func recordedShiftSpaceUsesTheSameNativeRepresentation() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        let shortcut = try PickerShortcut(event: event)
        #expect(shortcut.menuKeyEquivalent == " ")
        #expect(shortcut.menuModifierMask == [.control, .shift])
        #expect(shortcut.value == "ctrl+shift+space")
    }
}
