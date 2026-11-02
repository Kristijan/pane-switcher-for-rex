import Foundation
import Testing
@testable import PaneSwitchCore

struct PaneSearchTests {
    private func pane(_ id: String, host: String = "Local", session: String = "Work",
                      window: String = "Editor", label: String = "Shell", title: String = "Terminal",
                      command: String = "zsh", directory: String = "/Users/me") -> Pane {
        Pane(host: RexHost(id: "host-\(id)", label: host, server: "server-\(id)"),
             sessionID: "session-\(id)", sessionLabel: session,
             windowID: "window-\(id)", windowLabel: window, blockID: id,
             label: label, title: title, command: command, directory: directory)
    }

    private func localPane(_ id: String, hostLabel: String = "Local", title: String = "Terminal") -> Pane {
        Pane(host: RexHost(id: "host-\(id)", label: hostLabel, server: nil),
             sessionID: "session-\(id)", sessionLabel: "Work",
             windowID: "window-\(id)", windowLabel: "Editor", blockID: id,
             label: "Shell", title: title, command: "zsh", directory: "/Users/me")
    }

    @Test func everyMetadataFieldIsSearchable() {
        let target = pane("block-unique", host: "Orion", session: "Aurora", window: "Nebula",
                          label: "Comet", title: "Meteor", command: "saturn", directory: "/pluto")
        for query in ["Orion", "Aurora", "Nebula", "Comet", "Meteor", "saturn", "pluto"] {
            #expect(PaneSearch.results([target], query: query).map(\.id) == [target.id], "Query: \(query)")
        }
    }

    @Test func multipleTokensCanMatchDifferentFieldsInAnyOrder() {
        let target = pane("target", host: "Build Server", session: "Release", command: "swift", directory: "/projects/rex")
        let other = pane("other", host: "Build Server", session: "Personal")
        #expect(PaneSearch.results([other, target], query: "REX build swi rel").map(\.id) == [target.id])
        #expect(PaneSearch.results([target], query: "swift nonexistent").isEmpty)
    }

    @Test func contiguousMatchesOutrankWideSubsequences() {
        let compact = pane("compact", title: "abc")
        let spread = pane("spread", title: "a________b________c")
        #expect(PaneSearch.results([spread, compact], query: "abc").map(\.id) == [compact.id, spread.id])
    }

    @Test func wordBoundaryMatchesOutrankInteriorMatches() {
        let boundary = pane("boundary", title: "run build")
        let interior = pane("interior", title: "run xbuild")
        #expect(PaneSearch.results([interior, boundary], query: "build").map(\.id) == [boundary.id, interior.id])
    }

    @Test func caseDiacriticsAndUnicodeAreSearchable() {
        let target = pane("unicode", host: "MÜNCHEN", title: "Café 日本語", directory: "/Équipe")
        #expect(PaneSearch.results([target], query: "mUnChEn CAFE 日本 equipe").map(\.id) == [target.id])
    }

    @Test func emptyQueryUsesStableHostSessionWindowAndPaneOrder() {
        let a = pane("a", host: "Alpha", session: "Alpha", window: "Alpha", label: "Alpha")
        let b = pane("b", host: "Alpha", session: "Alpha", window: "Alpha", label: "Beta")
        let c = pane("c", host: "Alpha", session: "Alpha", window: "Beta")
        let d = pane("d", host: "Alpha", session: "Beta")
        let e = pane("e", host: "Beta")
        let input = [e, c, b, d, a]
        // Distinct host IDs break ties only after the human-readable hierarchy.
        #expect(PaneSearch.results(input, query: " \n ").map(\.blockID) == ["a", "b", "c", "d", "e"])
    }

    @Test func scoreTiesDoNotDependOnDiscoveryOrder() {
        let alpha = pane("alpha", host: "Alpha")
        let beta = pane("beta", host: "Beta")
        let expected = [alpha.id, beta.id]
        #expect(PaneSearch.results([beta, alpha], query: "Terminal").map(\.id) == expected)
        #expect(PaneSearch.results([alpha, beta], query: "Terminal").map(\.id) == expected)
    }

    @Test func emptyQueryPlacesLocalHostsBeforeRemoteRegardlessOfLabels() {
        let localAlpha = localPane("local-alpha", hostLabel: "Yankee")
        let localBeta = localPane("local-beta", hostLabel: "Zulu")
        let remoteAlpha = pane("remote-alpha", host: "Alpha")
        let remoteLocal = pane("remote-local", host: "Local")
        let expected = [localAlpha.id, localBeta.id, remoteAlpha.id, remoteLocal.id]
        let input = [remoteLocal, localBeta, remoteAlpha, localAlpha]
        #expect(PaneSearch.results(input, query: "").map(\.id) == expected)
        #expect(PaneSearch.results(Array(input.reversed()), query: " \n ").map(\.id) == expected)
    }

    @Test func searchRanksByMatchQualityAcrossLocations() {
        let localSpread = localPane("local-spread", hostLabel: "Zulu", title: "a________b________c")
        let localCompact = localPane("local-compact", hostLabel: "Zulu", title: "abc")
        let remoteSpread = pane("remote-spread", host: "Local", title: "a________b________c")
        let remoteCompact = pane("remote-compact", host: "Local", title: "abc")
        let expected = [localCompact.id, remoteCompact.id, localSpread.id, remoteSpread.id]
        let input = [remoteCompact, localSpread, remoteSpread, localCompact]
        #expect(PaneSearch.results(input, query: "abc").map(\.id) == expected)
        #expect(PaneSearch.results(Array(input.reversed()), query: "abc").map(\.id) == expected)
    }

    @Test func exactRemoteHostMatchOutranksScatteredLocalMatch() {
        let local = localPane("local", title: "d__o__c__k__e__r")
        let remote = pane("remote", host: "Docker")
        let ranked = PaneSearch.results([local, remote], query: "docker")
        #expect(ranked.map(\.id) == [remote.id, local.id])
        let displayed = PaneGroupedList(rankedPanes: ranked)
        #expect(displayed.panes.map(\.id) == [remote.id, local.id])
        #expect(displayed.rows.first == .host(remote.host))
    }

    @Test func localAndRemoteScoreTiesAreDeterministicWithinTheirGroups() {
        let localAlpha = localPane("local-alpha", hostLabel: "Yankee")
        let localBeta = localPane("local-beta", hostLabel: "Zulu")
        let remoteAlpha = pane("remote-alpha", host: "Alpha")
        let remoteBeta = pane("remote-beta", host: "Beta")
        let expected = [localAlpha.id, localBeta.id, remoteAlpha.id, remoteBeta.id]
        let input = [remoteBeta, localBeta, remoteAlpha, localAlpha]
        #expect(PaneSearch.results(input, query: "Terminal").map(\.id) == expected)
        #expect(PaneSearch.results(Array(input.reversed()), query: "Terminal").map(\.id) == expected)
    }

    @Test func remoteMatchesRemainAvailableWhenNoLocalPaneMatches() {
        let local = localPane("local", hostLabel: "Zulu", title: "Terminal")
        let remoteSpread = pane("remote-spread", host: "Local", title: "a________b________c")
        let remoteCompact = pane("remote-compact", host: "Local", title: "abc")
        #expect(PaneSearch.results([remoteSpread, local, remoteCompact], query: "abc").map(\.id)
                == [remoteCompact.id, remoteSpread.id])
    }

    @Test func unmatchedQueryReturnsNoResults() {
        #expect(PaneSearch.results([pane("one")], query: "🚀never-present").isEmpty)
        #expect(PaneSearch.results([], query: "anything").isEmpty)
    }

    @Test func reusableIndexSupportsChangingQueriesWithoutStaleMatches() {
        let alpha = pane("alpha", title: "Alpha")
        let beta = pane("beta", title: "Beta")
        let index = PaneSearch.Index([alpha, beta])
        #expect(index.results(query: "Alpha").map(\.id) == [alpha.id])
        #expect(index.results(query: "Beta").map(\.id) == [beta.id])
        #expect(index.results(query: "").count == 2)
    }

    @Test func highlighterMarksSeparatedFuzzyCharacters() {
        let highlighter = PaneSearch.Highlighter(query: "abc")
        #expect(highlighter.ranges(in: "a_b_c") == [
            NSRange(location: 0, length: 1),
            NSRange(location: 2, length: 1),
            NSRange(location: 4, length: 1),
        ])
    }

    @Test func highlighterPrefersTheBestContiguousOccurrenceOverAnEarlySubsequence() {
        #expect(PaneSearch.Highlighter(query: "abc").ranges(in: "a___b___c abc")
                == [NSRange(location: 10, length: 3)])
    }

    @Test func highlighterUsesWordBoundaryScoringRatherThanTheFirstSubstring() {
        #expect(PaneSearch.Highlighter(query: "abc").ranges(in: "xabc abc")
                == [NSRange(location: 5, length: 3)])
    }

    @Test func highlighterSortsAndMergesAdjacentAndOverlappingTokens() {
        #expect(PaneSearch.Highlighter(query: "c a").ranges(in: "abc")
                == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
        #expect(PaneSearch.Highlighter(query: "bc a ab").ranges(in: "abc")
                == [NSRange(location: 0, length: 3)])
    }

    @Test func highlighterMatchesTokensIndependentlyOnEachDisplayedLine() {
        let target = pane("target", title: "Swift compiler", directory: "/projects/rex")
        #expect(PaneSearch.results([target], query: "swift rex").map(\.id) == [target.id])
        let highlighter = PaneSearch.Highlighter(query: "swift rex")
        #expect(highlighter.ranges(in: target.title) == [NSRange(location: 0, length: 5)])
        #expect(highlighter.ranges(in: target.directory) == [NSRange(location: 10, length: 3)])
        #expect(highlighter.ranges(in: "unrelated").isEmpty)
        #expect(highlighter.ranges(in: "SWIFT") == [NSRange(location: 0, length: 5)])
    }

    @Test func highlighterNeverMarksPartialOrEmptyQueries() {
        #expect(PaneSearch.Highlighter(query: "").ranges(in: "abc").isEmpty)
        #expect(PaneSearch.Highlighter(query: " \n\t ").ranges(in: "abc").isEmpty)
        #expect(PaneSearch.Highlighter(query: "abc").ranges(in: "ab").isEmpty)
        #expect(PaneSearch.Highlighter(query: "abc").ranges(in: "").isEmpty)
        #expect(PaneSearch.Highlighter(query: "abc").ranges(in: "acb").isEmpty)
    }

    @Test func highlighterMapsCaseAndDiacriticsToOriginalUTF16Ranges() {
        let highlighter = PaneSearch.Highlighter(query: "CAFE")
        #expect(highlighter.ranges(in: "🚀 Café") == [NSRange(location: 3, length: 4)])
        #expect(highlighter.ranges(in: "🚀 Cafe\u{301}") == [NSRange(location: 3, length: 5)])
        #expect(PaneSearch.Highlighter(query: "é").ranges(in: "e\u{301}")
                == [NSRange(location: 0, length: 2)])
    }

    @Test func highlighterDoesNotSplitEmojiOrFoldedExpansionGraphemes() {
        #expect(PaneSearch.Highlighter(query: "👩🏽‍💻").ranges(in: "x 👩🏽‍💻")
                == [NSRange(location: 2, length: 7)])
        #expect(PaneSearch.Highlighter(query: "ss").ranges(in: "Straße")
                == [NSRange(location: 4, length: 1)])
        #expect(PaneSearch.Highlighter(query: "s").ranges(in: "ß")
                == [NSRange(location: 0, length: 1)])
        #expect(PaneSearch.Highlighter(query: "ffi").ranges(in: "oﬃce")
                == [NSRange(location: 1, length: 1)])
    }
}
