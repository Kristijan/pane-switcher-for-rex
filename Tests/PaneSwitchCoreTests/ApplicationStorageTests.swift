import Foundation
import Testing
@testable import PaneSwitchCore

struct ApplicationStorageTests {
    private func withHome(_ body: (URL, ApplicationStorage) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home, ApplicationStorage(homeDirectory: home))
    }

    private func current(_ home: URL, _ name: String) -> URL {
        home.appendingPathComponent("Library/Application Support/Pane Switcher for Rex/\(name)")
    }

    private var selectedPane: Pane {
        Pane(host: RexHost(id: "local", label: "Mac", server: nil),
             sessionID: "session", sessionLabel: "Work", windowID: "window", windowLabel: "Editor",
             blockID: "selected", label: "Shell", title: "Shell", command: "zsh", directory: "/projects")
    }

    @Test func newInstallReadsDefaultsAndWritesOnlyToTheNewDirectory() throws {
        try withHome { home, storage in
            let store = SettingsStore(storage: storage)
            var settings = try store.load()
            let recent = RecentPaneStore(storage: storage)
            #expect(!settings.setupCompleted)
            #expect(recent.loadError == nil)
            #expect(recent.snapshot().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: current(home, "").path))
            settings.shortcut = "ctrl+alt+space"
            try store.save(settings)
            try recent.record(selectedPane)
            #expect(try SettingsStore(url: current(home, "config.json")).load() == settings)
            #expect(RecentPaneStore(url: current(home, "recent-panes.json")).snapshot() == ["local/selected"])
        }
    }
}
