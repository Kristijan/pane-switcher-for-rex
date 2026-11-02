import Foundation

public enum PaneSearch {
    /// Separates host/location operators from the text used for fuzzy ranking and highlighting.
    /// Host values may be double-quoted; repeated host filters are OR-combined.
    public struct Query: Sendable {
        public let text: String
        public var hasText: Bool { text.contains { !$0.isWhitespace } }

        private let hostTerms: [String]
        private let requiresLocal: Bool
        private let requiresRemote: Bool

        public init(_ raw: String) {
            guard raw.contains(":") else {
                text = raw
                hostTerms = []
                requiresLocal = false
                requiresRemote = false
                return
            }
            var terms: [String] = []
            var local = false
            var remote = false
            var remaining: [String] = []
            var hasFilters = false
            var position = raw.startIndex
            while position < raw.endIndex {
                if raw[position].isWhitespace {
                    raw.formIndex(after: &position)
                    continue
                }
                let start = position
                let end = raw[position...].firstIndex(where: \.isWhitespace) ?? raw.endIndex
                if let colon = raw[start..<end].firstIndex(of: ":") {
                    let name: String
                    switch raw[start..<colon].lowercased() {
                    case "h": name = "host"
                    case "l": name = "local"
                    case "r": name = "remote"
                    case let value: name = value
                    }
                    if name == "host" || name == "local" || name == "remote",
                       let value = Self.value(in: raw, from: raw.index(after: colon), wordEnd: end),
                       name != "host" || !value.text.isEmpty {
                        hasFilters = true
                        switch name {
                        case "host": terms.append(normalize(value.text))
                        case "local":
                            local = true
                            if !value.text.isEmpty { remaining.append(value.text) }
                        default:
                            remote = true
                            if !value.text.isEmpty { remaining.append(value.text) }
                        }
                        position = value.end
                        continue
                    }
                }
                remaining.append(String(raw[start..<end]))
                position = end
            }
            // In particular, quotes and punctuation in ordinary searches retain their old meaning.
            text = hasFilters ? remaining.joined(separator: " ") : raw
            hostTerms = terms
            requiresLocal = local
            requiresRemote = remote
        }

        public func matches(_ host: RexHost) -> Bool {
            matches(isLocal: host.server == nil, normalizedHostLabel: normalize(host.label))
        }

        fileprivate func matches(isLocal: Bool, normalizedHostLabel: String) -> Bool {
            if requiresLocal && !isLocal || requiresRemote && isLocal { return false }
            return hostTerms.isEmpty || hostTerms.contains { normalizedHostLabel.contains($0) }
        }

        private static func value(in raw: String, from start: String.Index,
                                  wordEnd: String.Index) -> (text: String, end: String.Index)? {
            guard start < raw.endIndex, raw[start] == "\"" else {
                return (String(raw[start..<wordEnd]), wordEnd)
            }
            var value = ""
            var position = raw.index(after: start)
            while position < raw.endIndex {
                let character = raw[position]
                raw.formIndex(after: &position)
                if character == "\"" {
                    guard position == raw.endIndex || raw[position].isWhitespace else { return nil }
                    return (value, position)
                }
                if character == "\\", position < raw.endIndex,
                   raw[position] == "\"" || raw[position] == "\\" {
                    value.append(raw[position])
                    raw.formIndex(after: &position)
                } else {
                    value.append(character)
                }
            }
            return nil
        }
    }

    public static func results(_ panes: [Pane], query: String) -> [Pane] {
        Index(panes).results(query: query)
    }

    /// Prepare once per query, then trace matches only in displayed text.
    public struct Highlighter: Sendable {
        private let tokens: [[Character]]
        private let maximumTokenLength: Int

        public init(query: String) {
            tokens = PaneSearch.tokens(in: Query(query).text)
            maximumTokenLength = tokens.reduce(0) { max($0, $1.count) }
        }

        public func ranges(in text: String) -> [NSRange] {
            guard !tokens.isEmpty else { return [] }
            let mapped = MappedText(text)
            let count = mapped.characters.count
            guard count > 0 else { return [] }
            let traceRows = maximumTokenLength <= count ? maximumTokenLength : tokens.reduce(0) {
                $1.count <= count ? max($0, $1.count) : $0
            }
            guard traceRows > 0 else { return [] }
            let boundaries = PaneSearch.boundaries(in: mapped.characters)
            var previous = Array(repeating: Int.min / 4, count: count)
            var current = previous
            var parents = Array(repeating: -1, count: traceRows * count)
            var ranges: [NSRange] = []
            for token in tokens {
                guard let best = score(token, in: mapped.characters, boundaries: boundaries,
                                       previous: &previous, current: &current, record: { row, column, parent in
                                           parents[row * count + column] = parent
                                       }),
                      var position = previous.firstIndex(of: best) else { continue }
                for row in token.indices.reversed() {
                    ranges.append(mapped.ranges[position])
                    if row > 0 { position = parents[row * count + position] }
                }
            }
            ranges.sort { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }
            var merged: [NSRange] = []
            for range in ranges {
                if let last = merged.last, range.location <= NSMaxRange(last) {
                    merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
                } else {
                    merged.append(range)
                }
            }
            return merged
        }
    }

    /// Reuse an index while the user types; only inventory changes require normalization again.
    public struct Index: Sendable {
        private let entries: [Entry]
        private let maximumTextLength: Int

        public init(_ panes: [Pane]) {
            entries = panes.map(Entry.init).sorted {
                if $0.isLocal != $1.isLocal { return $0.isLocal }
                return $0.sortKey.lexicographicallyPrecedes($1.sortKey)
            }
            maximumTextLength = entries.reduce(0) { max($0, $1.text.count) }
        }

        public func results(query: String) -> [Pane] {
            let parsed = Query(query)
            let tokens = PaneSearch.tokens(in: parsed.text)
            guard !tokens.isEmpty else {
                return entries.compactMap {
                    parsed.matches(isLocal: $0.isLocal, normalizedHostLabel: $0.hostLabel) ? $0.pane : nil
                }
            }
            var matches: [(index: Int, score: Int)] = []
            matches.reserveCapacity(entries.count)
            // Share scratch buffers across all entries and tokens, rather than allocating per match.
            var previous = Array(repeating: Int.min / 4, count: maximumTextLength)
            var current = previous
            for (index, entry) in entries.enumerated() {
                guard parsed.matches(isLocal: entry.isLocal, normalizedHostLabel: entry.hostLabel) else { continue }
                var total = 0
                var matched = true
                for token in tokens {
                    guard let score = score(token, in: entry.text, boundaries: entry.boundaries,
                                          previous: &previous, current: &current) else {
                        matched = false
                        break
                    }
                    total += score
                }
                if matched { matches.append((index, total)) }
            }
            matches.sort {
                return $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
            }
            return matches.map { entries[$0.index].pane }
        }
    }

    private struct Entry: Sendable {
        let pane: Pane
        let isLocal: Bool
        let hostLabel: String
        let text: [Character]
        let boundaries: [Bool]
        let sortKey: [String]

        init(_ pane: Pane) {
            self.pane = pane
            isLocal = pane.host.server == nil
            hostLabel = normalize(pane.host.label)
            let fields = [pane.label, pane.title, pane.command, pane.directory,
                          pane.host.label, pane.sessionLabel, pane.windowLabel]
            let characters = Array(normalize(fields.joined(separator: " ")))
            text = characters
            boundaries = PaneSearch.boundaries(in: characters)
            let order = [pane.host.label, pane.sessionLabel, pane.windowLabel,
                         pane.label, pane.title, pane.command, pane.directory,
                         pane.host.id, pane.sessionID, pane.windowID, pane.blockID]
            sortKey = order.map(normalize) + order
        }
    }

    /// Fold whole original graphemes and retain their UTF-16 spans, including expansions
    /// such as ß → ss. Re-segment the folded string so adjacent fragments still use the
    /// same Character boundaries as search, without ever highlighting part of a grapheme.
    private struct MappedText {
        let characters: [Character]
        let ranges: [NSRange]

        init(_ text: String) {
            var folded = ""
            var spans: [(end: Int, source: NSRange)] = []
            var sourceOffset = 0
            var foldedOffset = 0
            for character in text {
                let original = String(character)
                let length = original.utf16.count
                let fragment = normalize(original)
                if !fragment.isEmpty {
                    folded += fragment
                    foldedOffset += fragment.utf16.count
                    spans.append((foldedOffset, NSRange(location: sourceOffset, length: length)))
                }
                sourceOffset += length
            }
            characters = Array(folded)
            var mappedRanges: [NSRange] = []
            mappedRanges.reserveCapacity(characters.count)
            var spanIndex = 0
            foldedOffset = 0
            for character in characters {
                while spans[spanIndex].end <= foldedOffset { spanIndex += 1 }
                let start = spans[spanIndex].source.location
                foldedOffset += String(character).utf16.count
                while spans[spanIndex].end < foldedOffset { spanIndex += 1 }
                mappedRanges.append(NSRange(location: start, length: NSMaxRange(spans[spanIndex].source) - start))
            }
            ranges = mappedRanges
        }
    }

    private static func tokens(in query: String) -> [[Character]] {
        normalize(query).split(whereSeparator: { $0.isWhitespace }).map { Array($0) }
    }

    private static func boundaries(in characters: [Character]) -> [Bool] {
        characters.indices.map { index in
            index == 0 || !characters[index - 1].isLetter && !characters[index - 1].isNumber
        }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    // Ranking uses an empty recorder; only the visible-text highlighter allocates traceback storage.
    @inline(__always)
    private static func score(_ token: [Character], in text: [Character], boundaries: [Bool],
                              previous: inout [Int], current: inout [Int],
                              record: (_ row: Int, _ column: Int, _ parent: Int) -> Void = { _, _, _ in }) -> Int? {
        let count = text.count
        guard token.count <= count else { return nil }
        let impossible = Int.min / 4
        for tokenIndex in token.indices {
            var bestGap = impossible
            var bestGapPosition = -1
            for position in 0..<count {
                if tokenIndex > 0, position >= 2 {
                    let candidate = previous[position - 2] + position - 2
                    if candidate > bestGap {
                        bestGap = candidate
                        bestGapPosition = position - 2
                    }
                }
                guard text[position] == token[tokenIndex] else {
                    current[position] = impossible
                    continue
                }
                let boundary = boundaries[position] ? 12 : 0
                if tokenIndex == 0 {
                    current[position] = 20 + boundary - min(position, 30)
                    record(tokenIndex, position, -1)
                } else {
                    let adjacent = position > 0 ? previous[position - 1] + 18 : impossible
                    let gapped = bestGap - position + 1
                    let prefix = max(adjacent, gapped)
                    current[position] = prefix <= impossible / 2 ? impossible : prefix + 10 + boundary
                    record(tokenIndex, position, adjacent >= gapped ? position - 1 : bestGapPosition)
                }
            }
            swap(&previous, &current)
        }
        let best = previous.prefix(count).max() ?? impossible
        return best <= impossible / 2 ? nil : best
    }
}
