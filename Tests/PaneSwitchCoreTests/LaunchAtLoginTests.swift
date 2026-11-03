import Foundation
import Testing
@testable import PaneSwitchCore

struct LaunchAtLoginTests {
    private func withTemporaryAgent(_ body: (URL, URL, LaunchAtLogin) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneSwitchLoginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("LaunchAgents/com.kristijan.paneswitch.plist")
        let executable = directory.appendingPathComponent("Pane Switcher for Rex.app/Contents/MacOS/PaneSwitch")
        try body(plist, executable, LaunchAtLogin(plistURL: plist, executableURL: executable))
    }

    @Test func enablingCreatesOneShotLoginAgentAndDisablingRemovesIt() throws {
        try withTemporaryAgent { plist, executable, login in
            #expect(try !login.isEnabled())
            #expect(!FileManager.default.fileExists(atPath: plist.deletingLastPathComponent().path))
            try login.setEnabled(true)
            #expect(try login.isEnabled())
            let object = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
            #expect(object["Label"] as? String == "com.kristijan.paneswitch")
            #expect(object["ProgramArguments"] as? [String] == [executable.path])
            #expect(object["RunAtLoad"] as? Bool == true)
            #expect(object["KeepAlive"] == nil)
            try login.setEnabled(false)
            #expect(try !login.isEnabled())
            #expect(!FileManager.default.fileExists(atPath: plist.path))
        }
    }
    @Test func currentAgentAndUnchangedPreferencesPreserveExactBytes() throws {
        try withTemporaryAgent { plist, executable, login in
            let original = try writeAgent([
                "Label": "com.kristijan.paneswitch",
                "ProgramArguments": [executable.path],
                "RunAtLoad": true,
                "StandardOutPath": "/tmp/pane-switch.log"
            ], to: plist, format: .binary)
            #expect(try login.isEnabled())
            try login.migrateLegacyExecutable()
            #expect(try Data(contentsOf: plist) == original)
            var persisted = false
            try login.setEnabled(true) { persisted = true }
            #expect(persisted)
            #expect(try Data(contentsOf: plist) == original)
            try login.setEnabled(false)
            #expect(try !login.isEnabled())
        }
    }

    @Test func legacyMigrationPreservesLoginStateAndEveryOtherKey() throws {
        try withTemporaryAgent { plist, executable, _ in
            let legacy = executable.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Pane Switch.app/Contents/MacOS/PaneSwitch")
            let login = LaunchAtLogin(plistURL: plist, executableURL: executable, legacyExecutableURLs: [legacy])
            // Migration is not an opt-in: disabled and unspecified states stay so.
            for enabled in [true, false, nil] as [Bool?] {
                var original: [String: Any] = [
                    "Label": "com.kristijan.paneswitch",
                    "ProgramArguments": [legacy.path],
                    "KeepAlive": false,
                    "StandardOutPath": "/tmp/pane-switch.log",
                    "StandardErrorPath": "/tmp/pane-switch-errors.log",
                    "EnvironmentVariables": ["EXISTING": "preserved"],
                    "ProcessType": "Interactive"
                ]
                original["RunAtLoad"] = enabled
                _ = try writeAgent(original, to: plist, format: .binary)
                #expect(try login.isEnabled() == (enabled == true))
                try login.migrateLegacyExecutable()
                var expected = original
                expected["ProgramArguments"] = [executable.path]
                let migrated = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
                #expect(NSDictionary(dictionary: migrated).isEqual(to: expected))
                #expect(try login.isEnabled() == (enabled == true))
                let migratedBytes = try Data(contentsOf: plist)
                try login.migrateLegacyExecutable()
                #expect(try Data(contentsOf: plist) == migratedBytes)
            }
        }
    }

    @Test func enablingExistingLegacyRegistrationMigratesInsteadOfLeavingOldPath() throws {
        try withTemporaryAgent { plist, executable, _ in
            let legacy = plist.deletingLastPathComponent().appendingPathComponent("Pane Switch.app/Contents/MacOS/PaneSwitch")
            let login = LaunchAtLogin(plistURL: plist, executableURL: executable, legacyExecutableURLs: [legacy])
            _ = try writeAgent([
                "Label": "com.kristijan.paneswitch",
                "ProgramArguments": [legacy.path],
                "RunAtLoad": true,
                "KeepAlive": false,
                "EnvironmentVariables": ["EXISTING": "preserved"]
            ], to: plist)
            var persisted = false
            try login.setEnabled(true) { persisted = true }
            let migrated = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
            #expect(persisted)
            #expect(migrated["ProgramArguments"] as? [String] == [executable.path])
            #expect(migrated["RunAtLoad"] as? Bool == true)
            #expect(migrated["KeepAlive"] as? Bool == false)
            #expect(migrated["EnvironmentVariables"] as? [String: String] == ["EXISTING": "preserved"])
        }
    }

    @Test func failedMigrationRestoresExactLegacyBytesAndDoesNotClobberAnotherWriter() throws {
        try withTemporaryAgent { plist, executable, _ in
            let legacy = plist.deletingLastPathComponent().appendingPathComponent("Pane Switch.app/Contents/MacOS/PaneSwitch")
            let login = LaunchAtLogin(plistURL: plist, executableURL: executable, legacyExecutableURLs: [legacy])
            let original = try writeAgent([
                "Label": "com.kristijan.paneswitch",
                "ProgramArguments": [legacy.path],
                "RunAtLoad": true,
                "StandardOutPath": "/tmp/pane-switch.log"
            ], to: plist, format: .binary)
            #expect(throws: SaveFailure.self) {
                try login.migrateLegacyExecutable { throw SaveFailure() }
            }
            #expect(try Data(contentsOf: plist) == original)
            #expect(throws: SaveFailure.self) {
                try login.setEnabled(true) { throw SaveFailure() }
            }
            #expect(try Data(contentsOf: plist) == original)
            let otherWriter = Data("another writer's contents".utf8)
            #expect(throws: (any Error).self) {
                try login.migrateLegacyExecutable {
                    try otherWriter.write(to: plist, options: .atomic)
                    throw SaveFailure()
                }
            }
            #expect(try Data(contentsOf: plist) == otherWriter)
        }
    }

    @Test func migrationDoesNotCreateMissingAgent() throws {
        try withTemporaryAgent { plist, _, login in
            try login.migrateLegacyExecutable()
            #expect(!FileManager.default.fileExists(atPath: plist.path))
            #expect(!FileManager.default.fileExists(atPath: plist.deletingLastPathComponent().path))
        }
    }

    @Test func preferencesFailureRestoresExactPreviousAgentOrAbsence() throws {
        try withTemporaryAgent { plist, executable, login in
            #expect(throws: SaveFailure.self) {
                try login.setEnabled(true) { throw SaveFailure() }
            }
            #expect(!FileManager.default.fileExists(atPath: plist.path))

            let original = try writeAgent([
                "Label": "com.kristijan.paneswitch",
                "ProgramArguments": [executable.path],
                "RunAtLoad": true,
                "StandardErrorPath": "/tmp/pane-switch-errors.log"
            ], to: plist, format: .binary)
            #expect(throws: SaveFailure.self) {
                try login.setEnabled(false) { throw SaveFailure() }
            }
            #expect(try Data(contentsOf: plist) == original)
            #expect(try login.isEnabled())

            let disabled = try writeAgent([
                "Label": "com.kristijan.paneswitch",
                "ProgramArguments": [executable.path],
                "RunAtLoad": false,
                "StandardOutPath": "/tmp/pane-switch.log"
            ], to: plist, format: .binary)
            #expect(throws: SaveFailure.self) {
                try login.setEnabled(true) { throw SaveFailure() }
            }
            #expect(try Data(contentsOf: plist) == disabled)
            #expect(try !login.isEnabled())
        }
    }

    @Test func unrelatedOrUnsafeJobsAreNeverChangedAndPreferencesAreNotSaved() throws {
        try withTemporaryAgent { plist, executable, login in
            let jobs: [[String: Any]] = [
                ["Label": "another.job", "ProgramArguments": [executable.path], "RunAtLoad": true],
                ["Label": "com.kristijan.paneswitch", "ProgramArguments": ["/bin/echo"], "RunAtLoad": true],
                ["Label": "com.kristijan.paneswitch", "ProgramArguments": [executable.path, "--other"], "RunAtLoad": true],
                ["Label": "com.kristijan.paneswitch", "ProgramArguments": [executable.path], "Program": "/bin/echo", "RunAtLoad": true],
                ["Label": "com.kristijan.paneswitch", "ProgramArguments": [executable.path], "KeepAlive": true, "RunAtLoad": true],
            ]
            for job in jobs {
                let original = try writeAgent(job, to: plist)
                #expect(throws: (any Error).self) { try login.isEnabled() }
                #expect(throws: (any Error).self) { try login.migrateLegacyExecutable() }
                #expect(try Data(contentsOf: plist) == original)
                for enabled in [false, true] {
                    var persisted = false
                    #expect(throws: (any Error).self) {
                        try login.setEnabled(enabled) { persisted = true }
                    }
                    #expect(!persisted)
                    #expect(try Data(contentsOf: plist) == original)
                }
            }
        }
    }

    @Test func malformedPlistsAndSymlinksAreLeftUntouched() throws {
        try withTemporaryAgent { plist, executable, login in
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let malformed = Data("not a property list".utf8)
            try malformed.write(to: plist)
            #expect(throws: (any Error).self) { try login.setEnabled(true) }
            #expect(throws: (any Error).self) { try login.migrateLegacyExecutable() }
            #expect(try Data(contentsOf: plist) == malformed)
            try FileManager.default.removeItem(at: plist)

            let target = plist.deletingLastPathComponent().appendingPathComponent("another.plist")
            let original = try writeAgent([
                "Label": "com.kristijan.paneswitch",
                "ProgramArguments": [executable.path],
                "RunAtLoad": true
            ], to: target)
            try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: target)
            #expect(throws: (any Error).self) { try login.migrateLegacyExecutable() }
            for enabled in [false, true] {
                #expect(throws: (any Error).self) { try login.setEnabled(enabled) }
                #expect(try Data(contentsOf: target) == original)
                let attributes = try FileManager.default.attributesOfItem(atPath: plist.path)
                #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
            }
        }
    }

    @Test func agentWriteFailureDoesNotPersistPreferences() throws {
        try withTemporaryAgent { plist, executable, _ in
            let blocker = plist.deletingLastPathComponent()
            try Data("not a directory".utf8).write(to: blocker)
            let login = LaunchAtLogin(plistURL: plist, executableURL: executable)
            var persisted = false
            #expect(throws: (any Error).self) {
                try login.setEnabled(true) { persisted = true }
            }
            #expect(!persisted)
            #expect(try String(contentsOf: blocker, encoding: .utf8) == "not a directory")
        }
    }

    private struct SaveFailure: Error {}

    private func writeAgent(_ object: [String: Any], to url: URL,
                            format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
        try data.write(to: url)
        return data
    }
}
