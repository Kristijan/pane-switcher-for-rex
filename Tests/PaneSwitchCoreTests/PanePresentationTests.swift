import Foundation
import Testing
@testable import PaneSwitchCore

struct PanePresentationTests {
    private func pane(server: String? = nil, session: String = "Development",
                      window: String = "Deploy logs", directory: String = "/srv/services/api",
                      windowID: String = "7") -> Pane {
        Pane(host: RexHost(id: "host", label: "Workstation", server: server),
             sessionID: "session", sessionLabel: session, windowID: windowID, windowLabel: window,
             blockID: "block", label: "Shell", title: "Terminal", command: "zsh", directory: directory)
    }

    @Test func rowContextOmitsHostAndLocationButKeepsSessionTabAndPath() {
        let servers: [String?] = [nil, "remote.example"]
        for server in servers {
            let target = pane(server: server)
            #expect(target.displaySecondaryText() == "Development · Deploy logs · /srv/services/api")
            #expect(target.secondaryText == "Workstation · Development · Deploy logs · /srv/services/api")
        }
    }

    @Test func syntheticWindowLabelsAreHiddenWithoutHidingMeaningfulTabs() {
        for label in ["7", "Window 7", ""] {
            #expect(pane(window: label).displaySecondaryText() == "Development · /srv/services/api")
        }
        for label in ["Window shopping", "Window 8", "Logs"] {
            #expect(pane(window: label).displaySecondaryText() == "Development · \(label) · /srv/services/api")
        }
    }

    @Test func generatedShortWindowIDIsHiddenWhileCustomWindowNamesRemain() {
        let windowID = "window:01a19088-4c76-71c9-a314-ddcfd76c0d37"
        for label in ["Window d76c0d37", "Window D76C0D37"] {
            let target = pane(window: label, windowID: windowID)
            #expect(target.displaySecondaryText() == "Development · /srv/services/api")
            #expect(target.windowLabel == label)
            #expect(target.searchText.contains(label))
            #expect(PaneSearch.results([target], query: label).map(\.id) == [target.id])
        }
        let custom = pane(window: "Window Planning", windowID: windowID)
        #expect(custom.displaySecondaryText() == "Development · Window Planning · /srv/services/api")
    }

    @Test func directorySettingOnlyAffectsDisplayAndKeepsSearchMetadata() {
        let target = pane(window: "Window 7")
        let originalSearch = target.searchText
        #expect(target.displaySecondaryText(showWorkingDirectory: false) == "Development")
        #expect(target.searchText == originalSearch)
        #expect(target.directory == "/srv/services/api")
        #expect(target.windowLabel == "Window 7")
        for query in ["Workstation", "Window 7", "/srv/services/api"] {
            #expect(PaneSearch.results([target], query: query).map(\.id) == [target.id])
        }
    }

    @Test func emptyMetadataDoesNotLeaveSeparatorsOrRestoreHostPrefix() {
        let target = pane(session: "", window: "", directory: "")
        #expect(target.displaySecondaryText().isEmpty)
        #expect(target.displaySecondaryText(showWorkingDirectory: false).isEmpty)
        #expect(pane(session: "", window: "", directory: "/").displaySecondaryText() == "/")
    }

    @Test func displayedUnicodeKeepsUTF16HighlightOffsetsAndRawSymbols() {
        let directory = "/Users/\u{F0000}team/cafe\u{301}"
        let target = pane(session: "🧭 Work", window: "Logs", directory: directory)
        let text = target.displaySecondaryText()
        #expect(text == "🧭 Work · Logs · \(directory)")
        let ranges = PaneSearch.Highlighter(query: "cafe").ranges(in: text)
        #expect(ranges == [(text as NSString).range(of: "cafe\u{301}")])
        #expect(target.directory == directory)
        #expect(target.searchText.contains("\u{F0000}"))
    }

    @Test func availabilityPreservesFailureDetailsAndDistinctStates() {
        #expect(PickerHostState.connecting != .ready)
        #expect(PickerHostState.unavailable("Timed out") == .unavailable("Timed out"))
        #expect(PickerHostState.unavailable("Timed out") != .unavailable("Disconnected"))
    }
}
