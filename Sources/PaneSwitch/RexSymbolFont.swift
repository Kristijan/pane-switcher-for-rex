import AppKit
import CoreText

/// Read-only use of Rex's private bundled font. No system-wide font registration.
/// Restart Pane Switcher for Rex after moving or updating Rex to rediscover the resource.
@MainActor
final class RexSymbolFont {
    static let shared = RexSymbolFont(fontURL: bundledFontURL())

    private enum Rendering { case system, symbol, omitted }
    private let font: CTFont?
    private let coverage: CharacterSet
    private let systemFont = NSFont.systemFont(ofSize: 14)
    private var rendering: [Unicode.Scalar: Rendering] = [:]
    private var sizes: [CGFloat: NSFont] = [:]

    init(fontURL: URL?) {
        if let fontURL,
           let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
           let descriptor = descriptors.first {
            let loaded = CTFontCreateWithFontDescriptor(descriptor, 14, nil)
            font = loaded
            coverage = CTFontCopyCharacterSet(loaded) as CharacterSet
        } else {
            font = nil
            coverage = CharacterSet()
        }
    }

    /// Filter only unrenderable private-use scalars, before calculating match ranges.
    func displayText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: Self.isPrivateUse) else { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if !Self.isPrivateUse(scalar) || resolve(scalar) != .omitted { result.append(scalar) }
        }
        return String(result)
    }

    /// Called after bold match styling, preserving all ranges and foreground colours.
    func apply(to text: NSMutableAttributedString, size: CGFloat) {
        guard let font else { return }
        var offset = 0
        for scalar in text.string.unicodeScalars {
            let length = scalar.utf16.count
            if Self.isPrivateUse(scalar), resolve(scalar) == .symbol {
                let sized: NSFont
                if let cached = sizes[size] { sized = cached }
                else {
                    sized = CTFontCreateCopyWithAttributes(font, size, nil, nil) as NSFont
                    sizes[size] = sized
                }
                text.addAttribute(.font, value: sized, range: NSRange(location: offset, length: length))
            }
            offset += length
        }
    }

    private func resolve(_ scalar: Unicode.Scalar) -> Rendering {
        if let cached = rendering[scalar] { return cached }
        let text = String(scalar)
        let fallback = CTFontCreateForString(systemFont, text as CFString,
                                             CFRange(location: 0, length: text.utf16.count))
        let name = CTFontCopyPostScriptName(fallback) as String
        let result: Rendering
        if !name.contains("LastResort") { result = .system }
        else if coverage.contains(scalar) { result = .symbol }
        else { result = .omitted }
        rendering[scalar] = result
        return result
    }

    private static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD: return true
        default: return false
        }
    }

    private static func bundledFontURL() -> URL? {
        let appURL = NSRunningApplication.runningApplications(withBundleIdentifier: "com.superlogical.rex")
            .compactMap(\.bundleURL).sorted { $0.path < $1.path }.first
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superlogical.rex")
        guard let appURL, let app = Bundle(url: appURL),
              app.bundleIdentifier == "com.superlogical.rex", let resources = app.resourceURL,
              let ghostty = Bundle(url: resources.appendingPathComponent("swift-ghostty_GhosttyRender.bundle")),
              let fontURL = ghostty.url(forResource: "SymbolsNerdFont-Regular", withExtension: "ttf") else { return nil }
        return fontURL
    }
}
