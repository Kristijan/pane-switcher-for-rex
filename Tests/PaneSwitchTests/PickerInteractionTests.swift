import AppKit
import Testing
@testable import PaneSwitchCore
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

    @Test func recoveredHostLookupRemovesFooterWarningLiveAndWhenReopened() async throws {
        let connection = PickerWarningConnection()
        let lookup = PickerHostLookup()
        let backend = RexBackend(connectionFactory: { _ in connection }, hostLookup: { try await lookup.read() })
        let fixture = try PickerFixture(backend: backend)
        defer { fixture.close() }
        let surface = try #require(fixture.panel.contentView as? PickerSurfaceView)
        try await waitUntil { surface.message.toolTip?.contains("Server is offline") == true }
        #expect(!surface.message.stringValue.contains("Server is offline"))
        try await waitUntil { surface.table.numberOfRows > 0 }

        await lookup.recover()
        connection.hostsChanged()
        try await waitUntil {
            surface.message.stringValue.contains("metadata")
                && surface.message.toolTip?.contains("Server is offline") == false
        }
        #expect(surface.table.numberOfRows > 0)

        fixture.picker.dismissForSettings()
        fixture.picker.show(clientID: "test", rexApp: .current, returningTo: nil)
        try await waitUntil { surface.message.stringValue.contains("metadata") }
        #expect(surface.message.toolTip?.contains("Server is offline") == false)
        #expect(surface.table.numberOfRows > 0)
        #expect(await lookup.readCount == 2)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RexBackendError("Expected picker state did not arrive")
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

    init(backend suppliedBackend: RexBackend? = nil) throws {
        _ = NSApplication.shared
        if let suppliedBackend {
            backend = suppliedBackend
        } else {
            backend = RexBackend(executable: URL(fileURLWithPath: "/usr/bin/true"))
            // These interaction tests need no worker or live Rex instance.
            backend.shutdown()
        }
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

private actor PickerHostLookup {
    private var isAvailable = false
    private(set) var readCount = 0
    func recover() { isAvailable = true }
    func read() throws -> RexHostInventory {
        readCount += 1
        if !isAvailable { throw RexBackendError("Server is offline") }
        return RexHostInventory(hosts: [], warnings: [])
    }
}

private final class PickerWarningConnection: RexInventoryConnection, @unchecked Sendable {
    private let stream: AsyncThrowingStream<RexStreamEvent, Error>
    private let continuation: AsyncThrowingStream<RexStreamEvent, Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<RexStreamEvent, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func hostsChanged() {
        continuation.yield(RexStreamEvent(type: "hosts_changed", sessionID: nil, blockID: nil, payload: [:]))
    }
    func events() -> AsyncThrowingStream<RexStreamEvent, Error> {
        continuation.yield(RexStreamEvent(type: "ready", sessionID: nil, blockID: nil, payload: [:]))
        return stream
    }
    func shutdown() { continuation.finish() }
    func execute(_ script: String, arguments: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        if arguments["panes"] != nil { throw RexBackendError("Metadata owner unavailable") }
        if arguments["sessions"] != nil {
            return ["views": [["session_id": "session", "label": "Work", "windows": [
                ["window_id": "window", "layers": [["layout": ["block_id": "block"],
                    "blocks": [["block_id": "block", "label": "Shell"]]]]]
            ]]], "errors": []]
        }
        return ["sessions": [["session_id": "session"]]]
    }
}
