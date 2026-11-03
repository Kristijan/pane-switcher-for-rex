import Foundation

/// Shared settings and recent-pane history location.
public struct ApplicationStorage {
    private let directory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let support = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        directory = support.appendingPathComponent("Pane Switcher for Rex", isDirectory: true)
    }

    var settingsURL: URL { directory.appendingPathComponent("config.json") }
    var recentPanesURL: URL { directory.appendingPathComponent("recent-panes.json") }
}
