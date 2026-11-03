import AppKit
import Testing
import PaneSwitchCore
@testable import PaneSwitch

@Suite(.serialized)
@MainActor
struct PickerInteractionTests {
    @Test func childSuggestionAndNestedWindowsStayInsidePicker() throws {
        let fixture = try PickerFixture()
        defer { fixture.close() }
        let search = try #require(fixture.search)
        search.setHosts([RexHost(id: "test", label: "Test Host", server: nil)])
        let editor = try #require(search.currentEditor() as? NSTextView)
        editor.insertText("host:", replacementRange: editor.selectedRange())
        let visibleChild = fixture.panel.childWindows?.first { $0.isVisible }
        let suggestions = try #require(visibleChild)

        try sendMouseDown(to: suggestions)
        #expect(fixture.panel.isVisible)
        #expect(suggestions.isVisible)
        #expect(search.stringValue == "host:")

        let nested = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                             styleMask: .borderless, backing: .buffered, defer: false)
        suggestions.addChildWindow(nested, ordered: .above)
        defer { suggestions.removeChildWindow(nested); nested.orderOut(nil) }
        try sendMouseDown(to: nested)
        #expect(fixture.panel.isVisible)

        let unrelated = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                                styleMask: .borderless, backing: .buffered, defer: false)
        defer { unrelated.orderOut(nil) }
        try sendMouseDown(to: unrelated)
        #expect(!fixture.panel.isVisible)
        #expect(!suggestions.isVisible)
    }

    @Test func focusingVisiblePickerPreservesQueryAndEditingSelection() throws {
        let fixture = try PickerFixture()
        defer { fixture.close() }
        let search = try #require(fixture.search)
        search.stringValue = "keep this query"
        let editor = try #require(search.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 5, length: 4))

        #expect(fixture.picker.focusIfVisible())
        #expect(search.stringValue == "keep this query")
        #expect(editor.selectedRange() == NSRange(location: 5, length: 4))
        #expect(search.currentEditor() === editor)
        #expect(fixture.panel.isVisible)

        fixture.picker.dismissForSettings()
        #expect(!fixture.picker.focusIfVisible())
        #expect(!fixture.panel.isVisible)
    }

    private func sendMouseDown(to window: NSWindow) throws {
        // Middle-click avoids NSTableView's synchronous left-button tracking loop while
        // exercising the application's real local event monitor and window dispatch.
        let event = try #require(NSEvent.mouseEvent(with: .otherMouseDown,
            location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        NSApp.sendEvent(event)
    }
}

@MainActor
private struct PickerFixture {
    let backend: RexBackend
    let picker: PickerController
    let panel: NSWindow
    var search: HostFilterSearchField? { descendants(panel.contentView).compactMap { $0 as? HostFilterSearchField }.first }

    init() throws {
        _ = NSApplication.shared
        backend = RexBackend(executable: URL(fileURLWithPath: "/usr/bin/true"))
        // These interaction tests need no worker or live Rex instance.
        backend.shutdown()
        picker = PickerController(backend: backend, settings: PickerSettings(), openSettings: {})
        picker.show(clientID: "test", rexApp: NSRunningApplication.current, returningTo: nil)
        panel = try #require(NSApp.windows.first { $0.isVisible && $0.title == "Switch Rex Pane" })
    }

    func close() {
        picker.dismissForSettings()
        backend.shutdown()
    }
}

@MainActor
private func descendants(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { descendants($0) }
}
