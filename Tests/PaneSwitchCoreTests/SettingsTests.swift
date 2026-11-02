import Foundation
import Testing
@testable import PaneSwitchCore

struct SettingsTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneSwitchSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func missingConfigurationReturnsDefaultsWithoutCreatingAFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("missing/config.json")
            let settings = try SettingsStore(url: url).load()
            #expect(settings.shortcut == "ctrl+cmd+p")
            #expect(!settings.setupCompleted)
            #expect(!settings.globalShortcut)
            #expect(!settings.recentPanesFirst)
            #expect(!settings.launchAtLogin)
            #expect(settings.rexExecutable == nil)
            #expect(settings.debug == false)
            #expect(settings.showMenuBarIcon)
            #expect(settings.showHostIcons)
            #expect(settings.showPaneIcons)
            #expect(settings.showWorkingDirectory)
            #expect(settings.showKeyboardLegend)
            #expect(settings.highlightColor == "#007AFF")
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }
    }

    @Test func legacyConfigurationPreservesExistingChoicesAndDefaultsNewOptions() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            try Data(#"{"shortcut":"alt+cmd+k","debug":true,"rexExecutable":"/custom/rex"}"#.utf8).write(to: url)
            let settings = try SettingsStore(url: url).load()
            #expect(settings.shortcut == "alt+cmd+k")
            #expect(settings.setupCompleted)
            #expect(!settings.globalShortcut)
            #expect(!settings.recentPanesFirst)
            #expect(!settings.launchAtLogin)
            #expect(settings.debug)
            #expect(settings.rexExecutable == "/custom/rex")
            #expect(settings.showMenuBarIcon)
            #expect(settings.showHostIcons)
            #expect(settings.showPaneIcons)
            #expect(settings.showWorkingDirectory)
            #expect(settings.showKeyboardLegend)
            #expect(settings.density == .comfortable)
            #expect(settings.highlightColor == "#007AFF")
        }
    }

    @Test func nullAndMissingKeysUseDefaults() throws {
        let empty = try JSONDecoder().decode(PickerSettings.self, from: Data("{}".utf8))
        #expect(empty == PickerSettings())
        let nulls = Data(#"{"shortcut":null,"debug":null,"rexExecutable":null,"showMenuBarIcon":null,"showResultIcons":null,"showHostIcons":null,"showPaneIcons":null,"showWorkingDirectory":null,"showKeyboardLegend":null,"showJumpLabels":null,"density":null,"highlightColor":null,"recentPanesFirst":null,"launchAtLogin":null}"#.utf8)
        #expect(try JSONDecoder().decode(PickerSettings.self, from: nulls) == PickerSettings())
    }

    @Test func setupCompletionPersistsOnlyWhenExplicitlySaved() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            let store = SettingsStore(url: url)
            var settings = try store.load()
            #expect(!settings.setupCompleted)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            settings.shortcut = "ctrl+option+k"
            settings.showMenuBarIcon = false
            try store.save(settings)
            #expect(!(try store.load()).setupCompleted)
            settings.setupCompleted = true
            try store.save(settings)
            #expect(try store.load() == settings)
        }
    }

    @Test func emptyAndMalformedShortcutsRemainAvailableForRecoveryWithoutRewriting() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            for shortcut in ["", "invalid", "cmd+q"] {
                let original = Data("{\"shortcut\":\"\(shortcut)\",\"showMenuBarIcon\":false,\"density\":\"compact\"}".utf8)
                try original.write(to: url)
                let settings = try SettingsStore(url: url).load()
                #expect(settings.shortcut == shortcut)
                #expect(!settings.showMenuBarIcon)
                #expect(settings.density == .compact)
                #expect(try Data(contentsOf: url) == original)
            }
        }
    }

    @Test func globalShortcutPersistsBothScopesAndPreservesShortcut() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            try Data(#"{"shortcut":"alt+cmd+k","debug":true}"#.utf8).write(to: url)
            let store = SettingsStore(url: url)
            var settings = try store.load()
            #expect(!settings.globalShortcut)
            for enabled in [true, false] {
                settings.globalShortcut = enabled
                try store.save(settings)
                let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                #expect(object["globalShortcut"] as? Bool == enabled)
                let loaded = try store.load()
                #expect(loaded == settings)
                #expect(loaded.shortcut == "alt+cmd+k")
                #expect(loaded.debug)
            }
        }
    }

    @Test func globalShortcutNullDefaultsOffAndInvalidTypesThrow() throws {
        let null = Data(#"{"globalShortcut":null}"#.utf8)
        #expect(try JSONDecoder().decode(PickerSettings.self, from: null) == PickerSettings())
        for value in ["\"true\"", "1", "[]", "{}"] {
            let data = Data("{\"globalShortcut\":\(value)}".utf8)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(PickerSettings.self, from: data)
            }
        }
    }

    @Test func recentOrderingAndLoginChoicesPersistIndependently() throws {
        try withTemporaryDirectory { directory in
            let store = SettingsStore(url: directory.appendingPathComponent("config.json"))
            for recent in [false, true] {
                for login in [false, true] {
                    var settings = PickerSettings()
                    settings.recentPanesFirst = recent
                    settings.launchAtLogin = login
                    try store.save(settings)
                    #expect(try store.load() == settings)
                }
            }
        }
    }

    @Test func invalidRecentOrderingAndLoginTypesThrow() throws {
        for key in ["recentPanesFirst", "launchAtLogin"] {
            for value in ["\"true\"", "1", "[]", "{}"] {
                let data = Data("{\"\(key)\":\(value)}".utf8)
                #expect(throws: (any Error).self) {
                    try JSONDecoder().decode(PickerSettings.self, from: data)
                }
            }
        }
    }

    @Test func highlightHexNormalizesOnlySixDigitRGBValues() {
        for input in ["#007aff", "007AFF", " \n#007aFf\t"] {
            #expect(PickerHighlightColor.canonicalHex(input) == "#007AFF")
        }
        #expect(PickerHighlightColor.canonicalHex("a1b2c3") == "#A1B2C3")
        #expect(PickerHighlightColor.canonicalHex("#000000") == "#000000")
        #expect(PickerHighlightColor.canonicalHex("#ffffff") == "#FFFFFF")
        for input in ["", "#", "#FFF", "12345", "1234567", "#12345678",
                      "##123456", "0x123456", "#12 456", "#GG1234", "１２３４５６"] {
            #expect(PickerHighlightColor.canonicalHex(input) == nil)
        }
    }

    @Test func highlightColorDecodesCanonicallyAndPersists() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            try Data(#"{"highlightColor":" \n a1b2c3\t","showPaneIcons":false}"#.utf8).write(to: url)
            let store = SettingsStore(url: url)
            let settings = try store.load()
            #expect(settings.highlightColor == "#A1B2C3")
            #expect(!settings.showPaneIcons)
            try store.save(settings)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["highlightColor"] as? String == "#A1B2C3")
            #expect(try store.load() == settings)
        }
    }

    @Test func invalidSavedHighlightColorsThrowWithoutChangingConfiguration() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            for value in ["\"\"", "\"#FFF\"", "\"#12345678\"", "\"#GG0000\"",
                          "\"blue\"", "123456", "false", "[]", "{}"] {
                let original = Data("{\"highlightColor\":\(value),\"debug\":true}".utf8)
                try original.write(to: url)
                #expect(throws: (any Error).self) { try SettingsStore(url: url).load() }
                #expect(try Data(contentsOf: url) == original)
            }
        }
    }

    @Test func legacyIconChoiceMigratesToBothIndependentOptions() throws {
        for visible in [false, true] {
            let data = Data("{\"showResultIcons\":\(visible)}".utf8)
            let settings = try JSONDecoder().decode(PickerSettings.self, from: data)
            #expect(settings.showHostIcons == visible)
            #expect(settings.showPaneIcons == visible)
        }
    }

    @Test func explicitIconChoicesTakePrecedenceAndOnlyMissingKeysMigrate() throws {
        let cases: [(String, Bool, Bool)] = [
            (#"{"showResultIcons":false,"showHostIcons":true}"#, true, false),
            (#"{"showResultIcons":false,"showPaneIcons":true}"#, false, true),
            (#"{"showResultIcons":true,"showHostIcons":false}"#, false, true),
            (#"{"showResultIcons":true,"showPaneIcons":false}"#, true, false),
            (#"{"showResultIcons":false,"showHostIcons":true,"showPaneIcons":true}"#, true, true),
            (#"{"showResultIcons":true,"showHostIcons":false,"showPaneIcons":false}"#, false, false),
            (#"{"showResultIcons":"obsolete","showHostIcons":true,"showPaneIcons":false}"#, true, false),
        ]
        for (json, hostIcons, paneIcons) in cases {
            let settings = try JSONDecoder().decode(PickerSettings.self, from: Data(json.utf8))
            #expect(settings.showHostIcons == hostIcons)
            #expect(settings.showPaneIcons == paneIcons)
        }
    }

    @Test func nullIconChoicesUseDefaultsInsteadOfLegacyValue() throws {
        let cases: [(String, Bool, Bool)] = [
            (#"{"showResultIcons":false,"showHostIcons":null}"#, true, false),
            (#"{"showResultIcons":false,"showPaneIcons":null}"#, false, true),
            (#"{"showResultIcons":false,"showHostIcons":null,"showPaneIcons":null}"#, true, true),
            (#"{"showResultIcons":null}"#, true, true),
            (#"{"showHostIcons":false,"showPaneIcons":null}"#, false, true),
            (#"{"showHostIcons":null,"showPaneIcons":false}"#, true, false),
        ]
        for (json, hostIcons, paneIcons) in cases {
            let settings = try JSONDecoder().decode(PickerSettings.self, from: Data(json.utf8))
            #expect(settings.showHostIcons == hostIcons)
            #expect(settings.showPaneIcons == paneIcons)
        }
    }

    @Test func migratingHiddenIconsSavesOnlyNewKeysAndPreservesOtherChoices() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            let original = Data(#"{"shortcut":"ctrl+cmd+p","showMenuBarIcon":false,"showResultIcons":false,"density":"compact","debug":false}"#.utf8)
            try original.write(to: url)
            let store = SettingsStore(url: url)
            let settings = try store.load()
            #expect(!settings.showHostIcons)
            #expect(!settings.showPaneIcons)
            #expect(!settings.showMenuBarIcon)
            #expect(settings.shortcut == "ctrl+cmd+p")
            #expect(settings.density == .compact)
            #expect(!settings.debug)
            try store.save(settings)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["showResultIcons"] == nil)
            #expect(object["showHostIcons"] as? Bool == false)
            #expect(object["showPaneIcons"] as? Bool == false)
            #expect(try store.load() == settings)
        }
    }

    @Test func independentIconChoicesRoundTripWithoutLegacyKeys() throws {
        for hostIcons in [false, true] {
            for paneIcons in [false, true] {
                var settings = PickerSettings()
                settings.showHostIcons = hostIcons
                settings.showPaneIcons = paneIcons
                let data = try JSONEncoder().encode(settings)
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(object["showResultIcons"] == nil)
                #expect(object["showHostIcons"] as? Bool == hostIcons)
                #expect(object["showPaneIcons"] as? Bool == paneIcons)
                #expect(try JSONDecoder().decode(PickerSettings.self, from: data) == settings)
            }
        }
    }

    @Test func incorrectIconFieldTypesThrowRatherThanResettingChoices() throws {
        for json in [
            #"{"showResultIcons":"false"}"#,
            #"{"showHostIcons":"false"}"#,
            #"{"showPaneIcons":0}"#,
        ] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(PickerSettings.self, from: Data(json.utf8))
            }
        }
    }

    @Test func savingCreatesDirectoriesAndRoundTripsEveryChoice() throws {
        try withTemporaryDirectory { directory in
            let store = SettingsStore(url: directory.appendingPathComponent("nested/settings/config.json"))
            var settings = PickerSettings()
            settings.shortcut = "ctrl+alt+space"
            settings.globalShortcut = true
            settings.recentPanesFirst = true
            settings.launchAtLogin = true
            settings.rexExecutable = "/Applications/Rex.app/Contents/MacOS/rex"
            settings.debug = true
            settings.showMenuBarIcon = false
            settings.showHostIcons = false
            settings.showPaneIcons = false
            settings.showWorkingDirectory = false
            settings.showKeyboardLegend = false
            settings.showJumpLabels = false
            settings.density = .compact
            settings.highlightColor = "#F08732"
            try store.save(settings)
            #expect(try store.load() == settings)

            settings.rexExecutable = nil
            settings.showMenuBarIcon = true
            settings.showHostIcons = true
            settings.showPaneIcons = true
            settings.density = .comfortable
            try store.save(settings)
            #expect(try store.load() == settings)
        }
    }

    @Test func corruptConfigurationThrowsWithoutChangingItsContents() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            let corrupt = Data("{not valid JSON".utf8)
            try corrupt.write(to: url)
            #expect(throws: (any Error).self) { try SettingsStore(url: url).load() }
            #expect(try Data(contentsOf: url) == corrupt)
        }
    }

    @Test func incorrectFieldTypesThrowRatherThanResettingChoices() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            let invalid = Data(#"{"debug":"true"}"#.utf8)
            try invalid.write(to: url)
            #expect(throws: (any Error).self) { try SettingsStore(url: url).load() }
            #expect(try Data(contentsOf: url) == invalid)
        }
    }

    @Test func unknownDensityDoesNotSilentlyResetSavedChoices() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("config.json")
            let invalid = Data(#"{"shortcut":"alt+cmd+k","density":"dense"}"#.utf8)
            try invalid.write(to: url)
            #expect(throws: (any Error).self) { try SettingsStore(url: url).load() }
            #expect(try Data(contentsOf: url) == invalid)
        }
    }

    @Test func filesystemFailuresAreNotTreatedAsMissingConfiguration() throws {
        try withTemporaryDirectory { directory in
            let blocker = directory.appendingPathComponent("not-a-directory")
            let original = Data("keep this file".utf8)
            try original.write(to: blocker)
            let store = SettingsStore(url: blocker.appendingPathComponent("config.json"))
            #expect(throws: (any Error).self) { try store.load() }
            #expect(throws: (any Error).self) { try store.save(PickerSettings()) }
            #expect(try Data(contentsOf: blocker) == original)
        }
    }
}
