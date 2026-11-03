import Foundation

public enum UpdateAvailability: Equatable, Sendable {
    case upToDate
    case updateAvailable(version: String)
}

/// Checks release metadata only; installing an update remains a manual action.
public struct GitHubUpdateChecker: Sendable {
    private let session: URLSession
    private static let releaseURL = URL(string: "https://api.github.com/repos/Kristijan/pane-switcher-for-rex/releases/latest")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(installedVersion: String) async throws -> UpdateAvailability {
        try Task.checkCancellation()
        guard let installed = StableVersion(installedVersion, allowsTagPrefix: false) else {
            throw UpdateCheckError.invalidInstalledVersion
        }

        var request = URLRequest(url: Self.releaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PaneSwitcherForRex", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease,
              let latest = StableVersion(release.tagName, allowsTagPrefix: true) else {
            throw UpdateCheckError.invalidRelease
        }
        return installed < latest ? .updateAvailable(version: String(latest.rawValue)) : .upToDate
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
        }
    }
}

/// Canonical stable SemVer components, compared without fixed-width integer limits.
private struct StableVersion: Comparable {
    let rawValue: Substring
    private let components: [Substring]

    init?(_ value: String, allowsTagPrefix: Bool) {
        let rawValue = allowsTagPrefix && value.hasPrefix("v") ? value.dropFirst() : value[...]
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ component in
            !component.isEmpty
                && (component.count == 1 || component.first != "0")
                && component.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }) else { return nil }
        self.rawValue = rawValue
        self.components = components
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) {
            if left.count != right.count { return left.count < right.count }
            if left != right { return left.lexicographicallyPrecedes(right) }
        }
        return false
    }
}

private enum UpdateCheckError: LocalizedError {
    case invalidInstalledVersion
    case invalidResponse
    case httpStatus(Int)
    case invalidRelease

    var errorDescription: String? {
        switch self {
        case .invalidInstalledVersion:
            return "The installed app version is not a valid stable MAJOR.MINOR.PATCH version."
        case .invalidResponse:
            return "GitHub returned an invalid response while checking for updates."
        case .httpStatus(404):
            return "No published release was found."
        case .httpStatus(403), .httpStatus(429):
            return "GitHub refused the update check (access denied or rate limit reached)."
        case .httpStatus(let status):
            return "GitHub returned HTTP \(status) while checking for updates."
        case .invalidRelease:
            return "GitHub did not return a valid published stable release."
        }
    }
}
