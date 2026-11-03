import Foundation

/// Manages only Pane Switcher for Rex's existing LaunchAgent file for the next login.
/// It never loads or unloads a job, so changing this preference cannot launch a
/// duplicate process or terminate the app currently managed by launchd.
public struct LaunchAtLogin {
    public static let label = "com.kristijan.paneswitch"
    private let plistURL: URL
    private let executableURL: URL
    private let ownedExecutablePaths: Set<String>

    public init(plistURL: URL, executableURL: URL, legacyExecutableURLs: [URL] = []) {
        self.plistURL = plistURL
        self.executableURL = executableURL
        self.ownedExecutablePaths = Set(([executableURL] + legacyExecutableURLs).map { $0.standardizedFileURL.path })
    }

    public func isEnabled() throws -> Bool {
        try readAgent()?.object["RunAtLoad"] as? Bool == true
    }

    /// Migrates an owned legacy executable without changing whether the agent is
    /// enabled or any other launchd keys. No agent is created if none exists.
    public func migrateLegacyExecutable(persist: () throws -> Void = {}) throws {
        let previous = try readAgent()
        guard let previous, needsMigration(previous.object) else {
            try persist()
            return
        }
        var object = previous.object
        object["ProgramArguments"] = [executableURL.path]
        try updateAgent(object, previous: previous, persist: persist)
    }

    /// Persists preferences after changing the agent, restoring its exact prior
    /// contents if preference persistence fails. An unchanged current-path agent
    /// is never rewritten; legacy paths migrate while preserving other keys.
    public func setEnabled(_ enabled: Bool, persist: () throws -> Void = {}) throws {
        let previous = try readAgent()
        let wasEnabled = previous?.object["RunAtLoad"] as? Bool == true
        guard enabled != wasEnabled || (!enabled && previous != nil)
                || (enabled && previous.map { needsMigration($0.object) } == true) else {
            try persist()
            return
        }

        var object: [String: Any]?
        if enabled {
            var enabledObject = previous?.object ?? [:]
            enabledObject["Label"] = Self.label
            enabledObject["ProgramArguments"] = [executableURL.path]
            enabledObject["RunAtLoad"] = true
            object = enabledObject
        }
        try updateAgent(object, previous: previous, persist: persist)
    }

    private func needsMigration(_ object: [String: Any]) -> Bool {
        (object["ProgramArguments"] as? [String]) != [executableURL.path]
    }

    private func updateAgent(_ object: [String: Any]?,
                             previous: (data: Data, object: [String: Any])?,
                             persist: () throws -> Void) throws {
        let updatedData: Data?
        if let object {
            let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
            updatedData = data
        } else {
            try FileManager.default.removeItem(at: plistURL)
            updatedData = nil
        }

        do {
            try persist()
        } catch {
            let persistenceError = error
            do {
                // Do not overwrite a job changed by another writer during save.
                guard try readAgent()?.data == updatedData else { throw AgentError.unrecognized(plistURL.path) }
                if let previous {
                    try previous.data.write(to: plistURL, options: .atomic)
                } else {
                    try FileManager.default.removeItem(at: plistURL)
                }
            } catch {
                throw AgentError.rollbackFailed(persistenceError.localizedDescription, error.localizedDescription)
            }
            throw persistenceError
        }
    }

    private func readAgent() throws -> (data: Data, object: [String: Any])? {
        let attributes: [FileAttributeKey: Any]
        do {
            // URL resource values cache metadata across file replacement. Always
            // inspect the current path, without following a symbolic link.
            attributes = try FileManager.default.attributesOfItem(atPath: plistURL.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AgentError.unrecognized(plistURL.path)
        }
        let data = try Data(contentsOf: plistURL)
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              object["Label"] as? String == Self.label,
              let arguments = object["ProgramArguments"] as? [String], arguments.count == 1,
              arguments[0].hasPrefix("/"),
              ownedExecutablePaths.contains(URL(fileURLWithPath: arguments[0]).standardizedFileURL.path),
              object["Program"] == nil,
              object["RunAtLoad"] == nil || object["RunAtLoad"] is Bool,
              object["KeepAlive"] == nil || (object["KeepAlive"] as? Bool == false) else {
            throw AgentError.unrecognized(plistURL.path)
        }
        return (data, object)
    }

    private enum AgentError: LocalizedError {
        case unrecognized(String)
        case rollbackFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unrecognized(let path):
                return "The login agent at \(path) is not a recognized Pane Switcher for Rex agent. It was left unchanged."
            case .rollbackFailed(let save, let rollback):
                return "Could not save settings: \(save) Restoring the previous login setting also failed: \(rollback)"
            }
        }
    }
}
