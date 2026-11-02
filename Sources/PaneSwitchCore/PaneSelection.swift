public struct PaneSelection: Sendable {
    private enum Mode: Sendable {
        case automatic
        case explicit(String)
        case suspended
    }

    private var mode: Mode = .automatic

    public init() {}

    public mutating func resetForQuery() {
        mode = .automatic
    }

    public mutating func choose(_ pane: Pane) {
        mode = .explicit(pane.id)
    }

    public mutating func suspendAfterFailure() {
        mode = .suspended
    }

    public func selectedRow(in results: [Pane]) -> Int? {
        switch mode {
        case .automatic:
            return results.isEmpty ? nil : 0
        case .explicit(let id):
            return results.firstIndex { $0.id == id }
        case .suspended:
            return nil
        }
    }
}
