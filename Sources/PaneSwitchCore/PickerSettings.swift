import Foundation

public enum PickerDensity: String, Codable, Sendable {
    case comfortable
    case compact
}

public enum PickerHighlightColor {
    public static let defaultHex = "#007AFF"

    public static func canonicalHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...]
        guard digits.utf8.count == 6,
              digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return "#" + digits.uppercased()
    }
}

public struct PickerSettings: Codable, Equatable, Sendable {
    public var shortcut: String = "ctrl+cmd+p"
    public var globalShortcut: Bool = false
    public var recentPanesFirst: Bool = false
    public var launchAtLogin: Bool = false
    public var rexExecutable: String? = nil
    public var debug: Bool = false
    public var showMenuBarIcon: Bool = true
    public var showHostIcons: Bool = true
    public var showPaneIcons: Bool = true
    public var showWorkingDirectory: Bool = true
    public var showKeyboardLegend: Bool = true
    public var showJumpLabels: Bool = true
    public var density: PickerDensity = .comfortable
    public var highlightColor: String = PickerHighlightColor.defaultHex
    public var setupCompleted: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case shortcut, globalShortcut, rexExecutable, debug
        case recentPanesFirst, launchAtLogin
        case showMenuBarIcon, showHostIcons, showPaneIcons, showWorkingDirectory, showKeyboardLegend
        case showJumpLabels, density, highlightColor
        case setupCompleted
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case showResultIcons
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcut = try container.decodeIfPresent(String.self, forKey: .shortcut) ?? shortcut
        // A config written before setup existed belongs to an existing user.
        setupCompleted = try container.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? true
        globalShortcut = try container.decodeIfPresent(Bool.self, forKey: .globalShortcut) ?? globalShortcut
        recentPanesFirst = try container.decodeIfPresent(Bool.self, forKey: .recentPanesFirst) ?? recentPanesFirst
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        rexExecutable = try container.decodeIfPresent(String.self, forKey: .rexExecutable)
        debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? debug
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? showMenuBarIcon
        let legacyIcons: Bool?
        if !container.contains(.showHostIcons) || !container.contains(.showPaneIcons) {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            legacyIcons = try legacy.decodeIfPresent(Bool.self, forKey: .showResultIcons)
        } else {
            legacyIcons = nil
        }
        showHostIcons = container.contains(.showHostIcons)
            ? try container.decodeIfPresent(Bool.self, forKey: .showHostIcons) ?? showHostIcons
            : legacyIcons ?? showHostIcons
        showPaneIcons = container.contains(.showPaneIcons)
            ? try container.decodeIfPresent(Bool.self, forKey: .showPaneIcons) ?? showPaneIcons
            : legacyIcons ?? showPaneIcons
        showWorkingDirectory = try container.decodeIfPresent(Bool.self, forKey: .showWorkingDirectory) ?? showWorkingDirectory
        showKeyboardLegend = try container.decodeIfPresent(Bool.self, forKey: .showKeyboardLegend) ?? showKeyboardLegend
        showJumpLabels = try container.decodeIfPresent(Bool.self, forKey: .showJumpLabels) ?? showJumpLabels
        density = try container.decodeIfPresent(PickerDensity.self, forKey: .density) ?? density
        if let savedColor = try container.decodeIfPresent(String.self, forKey: .highlightColor) {
            guard let color = PickerHighlightColor.canonicalHex(savedColor) else {
                throw DecodingError.dataCorruptedError(forKey: .highlightColor, in: container,
                                                      debugDescription: "Expected a six-digit RGB hex colour.")
            }
            highlightColor = color
        }
    }
}

public struct SettingsStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(storage: ApplicationStorage = ApplicationStorage()) {
        self.url = storage.settingsURL
    }

    public func load() throws -> PickerSettings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            var settings = PickerSettings()
            settings.setupCompleted = false
            return settings
        }
        return try JSONDecoder().decode(PickerSettings.self, from: data)
    }

    public func save(_ settings: PickerSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
