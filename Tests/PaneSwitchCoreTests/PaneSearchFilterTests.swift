import Foundation
import Testing
@testable import PaneSwitchCore

struct PaneSearchFilterTests {
    private let local = RexHost(id: "local", label: "Mac", server: nil)
    private let docker = RexHost(id: "docker", label: "Docker Production", server: "docker")
    private let unicode = RexHost(id: "unicode", label: "MÜNCHEN 日本 Lab", server: "lab")

    private func pane(_ id: String, host: RexHost, title: String = "Terminal") -> Pane {
        Pane(host: host, sessionID: "session", sessionLabel: "Work",
             windowID: "window", windowLabel: "Editor", blockID: id,
             label: "Shell", title: title, command: "zsh", directory: "/projects")
    }

    @Test func shorthandFiltersPreserveScopeRankingAndHighlights() {
        let panes = [pane("local", host: local, title: "logs"),
                     pane("remote", host: docker, title: "logs")]
        #expect(PaneSearch.results(panes, query: "l:logs").map(\.blockID) == ["local"])
        #expect(PaneSearch.results(panes, query: "r: h:\"Docker Production\" logs").map(\.blockID) == ["remote"])
        #expect(PaneSearch.results(panes, query: "l: r:").isEmpty)
        #expect(PaneSearch.Query("H:\"munchen 日本\"").matches(unicode))
        #expect(!PaneSearch.Query("h:docker").hasText)
        #expect(PaneSearch.Highlighter(query: "r: h:docker logs").ranges(in: "Docker logs") == [NSRange(location: 7, length: 4)])
    }

    @Test func locationOperatorsFilterByConnectionRatherThanHostName() {
        let misleadingRemote = RexHost(id: "remote", label: "Local", server: "remote")
        #expect(PaneSearch.Query("local:").matches(local))
        #expect(!PaneSearch.Query("local:").matches(misleadingRemote))
        #expect(PaneSearch.Query("remote:").matches(misleadingRemote))
        #expect(!PaneSearch.Query("remote:").matches(local))
        #expect(!PaneSearch.Query("local: remote:").matches(local))
        #expect(!PaneSearch.Query("local: remote:").matches(docker))
        #expect(!PaneSearch.Query("local: \n remote:").hasText)
    }

    @Test func hostFiltersAreUnicodeInsensitiveSubstringsAndSupportQuotedNames() {
        #expect(PaneSearch.Query("host:docker").matches(docker))
        #expect(!PaneSearch.Query("host:dkr").matches(docker))
        #expect(!PaneSearch.Query("host:docker").matches(local))
        #expect(PaneSearch.Query("HOST:\"munchen 日本\"").matches(unicode))
        #expect(PaneSearch.Query("host:\"MU\u{308}NCHEN 日本\" host:lab remote:").matches(unicode))
        let quoted = RexHost(id: "quoted", label: "Build \"Blue\"", server: "build")
        #expect(PaneSearch.Query("host:\"Build \\\"Blue\\\"\"").matches(quoted))
    }

    @Test func multipleHostsIncludeTheirUnionAndKeepOtherRestrictions() {
        let piHole = RexHost(id: "pihole", label: "PiHole", server: "pihole")
        let panes = [pane("docker", host: docker, title: "logs"),
                     pane("pihole", host: piHole, title: "logs"),
                     pane("other", host: unicode, title: "logs"),
                     pane("mac", host: local, title: "logs"),
                     pane("unmatched", host: docker, title: "terminal")]
        #expect(Set(PaneSearch.results(panes, query: "host:Docker host:PiHole logs").map(\.blockID))
                == ["docker", "pihole"])
        #expect(Set(PaneSearch.results(panes, query: "h:\"Docker Production\" h:PiHole r: logs").map(\.blockID))
                == ["docker", "pihole"])
        #expect(PaneSearch.results(panes, query: "host:Docker host:PiHole local:").isEmpty)
        #expect(!PaneSearch.Query("host:Docker host:PiHole").matches(unicode))
        #expect(PaneSearch.Query("host:Docker host:Docker").matches(docker))
    }

    @Test func locationSuffixesRemainFuzzySearchText() {
        let compact = pane("compact", host: local, title: "abc")
        let scattered = pane("scattered", host: local, title: "a___b___c")
        let excluded = pane("excluded", host: docker, title: "abc")
        let query = PaneSearch.Query("local:abc")
        #expect(query.text == "abc")
        #expect(query.hasText)
        #expect(PaneSearch.results([excluded, scattered, compact], query: "local:abc").map(\.id)
                == [compact.id, scattered.id])
        #expect(PaneSearch.results([compact, excluded], query: "remote:abc host:docker").map(\.id)
                == [excluded.id])
    }

    @Test func filterOnlyBrowsingRetainsNormalOrderingAndIndexDoesNotRetainFilters() {
        let alpha = pane("alpha", host: docker, title: "Alpha")
        let beta = pane("beta", host: docker, title: "Beta")
        let onMac = pane("mac", host: local)
        let index = PaneSearch.Index([beta, onMac, alpha])
        #expect(index.results(query: "host:docker").map(\.id) == [alpha.id, beta.id])
        #expect(index.results(query: "local:").map(\.id) == [onMac.id])
        #expect(index.results(query: "host:missing").isEmpty)
        #expect(index.results(query: "").map(\.id) == [onMac.id, alpha.id, beta.id])
    }

    @Test func plainQueriesRetainTextTokensRankingAndLiteralPunctuation() {
        let raw = " \t ABC\n日本  "
        #expect(PaneSearch.Query(raw).text == raw)
        #expect(PaneSearch.Query(raw).hasText)
        #expect(PaneSearch.Query(raw).matches(local))
        #expect(!PaneSearch.Query(" \n\t ").hasText)
        let compact = pane("compact", host: docker, title: "abc 日本")
        let scattered = pane("scattered", host: local, title: "a___b___c 日本")
        #expect(PaneSearch.results([scattered, compact], query: raw).map(\.id)
                == [compact.id, scattered.id])
        let literal = pane("literal", host: local, title: "https://example host: \"hello\"")
        #expect(PaneSearch.results([literal], query: "https://example").map(\.id) == [literal.id])
        #expect(PaneSearch.Query("host:").text == "host:")
        #expect(PaneSearch.Query("host:\"unfinished").text == "host:\"unfinished")
        #expect(PaneSearch.Query("\"hello\"").text == "\"hello\"")
    }

    @Test func highlightsExcludeOperatorsAndHostArgumentsButKeepUnicodeSuffixes() {
        #expect(PaneSearch.Highlighter(query: "host:docker local:")
            .ranges(in: "host docker local").isEmpty)
        #expect(PaneSearch.Highlighter(query: "host:\"München 日本\" remote:CAFE")
            .ranges(in: "🚀 Café") == [NSRange(location: 3, length: 4)])
        #expect(PaneSearch.Highlighter(query: "local:abc host:docker")
            .ranges(in: "local docker a_b_c") == [
                NSRange(location: 13, length: 1),
                NSRange(location: 15, length: 1),
                NSRange(location: 17, length: 1),
            ])
    }
}
