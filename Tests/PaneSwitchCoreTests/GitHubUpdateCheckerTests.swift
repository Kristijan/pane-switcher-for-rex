import Foundation
import Testing
import PaneSwitchCore

@Suite(.serialized)
struct GitHubUpdateCheckerTests {
    @Test func newerStableReleaseOffersItsVersionWithoutTheTagPrefix() async throws {
        let fixture = UpdateHTTPFixture(.response(status: 200, body: #"{"tag_name":"v1.2.0","draft":false,"prerelease":false}"#))
        defer { fixture.close() }

        let availability = try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: "1.0.0")

        #expect(availability == .updateAvailable(version: "1.2.0"))
    }

    @Test func versionComponentsAreComparedNumericallyRatherThanAsText() async throws {
        let cases = [
            ("1.9.9", "1.10.0", "1.10.0"),
            ("1.0.9", "1.0.10", "1.0.10"),
            ("1.99.99", "2.0.0", "2.0.0"),
            ("0.0.0", "v0.0.1", "0.0.1"),
            ("1.0.0", "1.2.3", "1.2.3"),
            ("99999999999999999999.0.0", "100000000000000000000.0.0", "100000000000000000000.0.0")
        ]
        for (installed, tag, offered) in cases {
            let fixture = UpdateHTTPFixture(.response(status: 200, body: try releaseJSON(tag)))
            defer { fixture.close() }

            let availability = try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: installed)

            #expect(availability == .updateAvailable(version: offered))
        }
    }

    @Test func equalOrOlderReleasesNeverOfferADowngrade() async throws {
        let cases = [
            ("1.0.0", "v1.0.0"),
            ("1.0.0", "1.0.0"),
            ("10.0.0", "v9.99.99"),
            ("1.10.0", "1.9.999"),
            ("1.0.10", "v1.0.9"),
            ("1.0.0", "0.99.99")
        ]
        for (installed, tag) in cases {
            let fixture = UpdateHTTPFixture(.response(status: 200, body: try releaseJSON(tag)))
            defer { fixture.close() }

            let availability = try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: installed)

            #expect(availability == .upToDate)
        }
    }

    @Test func unrelatedReleaseMetadataDoesNotAffectAvailability() async throws {
        let fixture = UpdateHTTPFixture(.response(status: 200, body: """
        {"tag_name":"v2.0.0","draft":false,"prerelease":false,
         "assets":[{"name":"app.zip"}],"body":{"unexpected":"shape"},"html_url":42}
        """))
        defer { fixture.close() }

        let availability = try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: "1.0.0")

        #expect(availability == .updateAvailable(version: "2.0.0"))
    }

    @Test func onlyCanonicalStableReleaseVersionsAreAccepted() async throws {
        for tag in [
            "", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "v01.2.3",
            "V1.2.3", "vv1.2.3", "1.2.3-beta.1", "1.2.3+build", " 1.2.3", "1.2.3\n",
            "1.-2.3", "1..3", "١.2.3", "１.2.3"
        ] {
            let fixture = UpdateHTTPFixture(.response(status: 200, body: try releaseJSON(tag)))
            defer { fixture.close() }

            await #expect(throws: (any Error).self) {
                try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: "1.0.0")
            }
        }
    }

    @Test func invalidInstalledVersionsRemainErrorsInsteadOfReportingCurrent() async throws {
        for installed in [
            "", "1", "1.0", "v1.0.0", "01.0.0", "1.00.0", "1.0.00", "1.0.0-beta",
            "1.0.0+build", "1.0.0.1", " 1.0.0", "1.0.0\n", "-1.0.0", "１.0.0"
        ] {
            let fixture = UpdateHTTPFixture(.response(status: 200, body: try releaseJSON("v2.0.0")))
            defer { fixture.close() }

            await #expect(throws: (any Error).self) {
                try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: installed)
            }
        }
    }

    @Test func draftsPrereleasesAndMalformedReleaseDocumentsAreErrors() async {
        for body in [
            #"{"tag_name":"v2.0.0","draft":true,"prerelease":false}"#,
            #"{"tag_name":"v2.0.0","draft":false,"prerelease":true}"#,
            #"{"tag_name":"v2.0.0","draft":false}"#,
            #"{"tag_name":"v2.0.0","prerelease":false}"#,
            #"{"tag_name":"v2.0.0","draft":"false","prerelease":false}"#,
            #"{"tag_name":"v2.0.0","draft":false,"prerelease":null}"#,
            #"{"tag_name":null,"draft":false,"prerelease":false}"#,
            #"{"tag_name":2,"draft":false,"prerelease":false}"#,
            #"{"draft":false,"prerelease":false}"#,
            #"{"message":"Not Found"}"#,
            "{}", "[]", "null", "not JSON", ""
        ] {
            let fixture = UpdateHTTPFixture(.response(status: 200, body: body))
            defer { fixture.close() }

            await #expect(throws: (any Error).self) {
                try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: "1.0.0")
            }
        }
    }

    @Test func unsuccessfulHTTPStatusesCannotMasqueradeAsAValidRelease() async throws {
        for status in [204, 301, 401, 403, 404, 429, 500, 503] {
            let fixture = UpdateHTTPFixture(.response(status: status, body: try releaseJSON("v1.0.0")))
            defer { fixture.close() }

            await #expect(throws: (any Error).self) {
                try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: "1.0.0")
            }
        }
    }


    @Test func nonHTTPResponsesAreNotAcceptedAsReleaseChecks() async {
        let fixture = UpdateHTTPFixture(.nonHTTP)
        defer { fixture.close() }

        await #expect(throws: (any Error).self) {
            try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: "1.0.0")
        }
    }

    @Test func connectivityAndTimeoutErrorsPreserveTheirCause() async throws {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cancelled] {
            let fixture = UpdateHTTPFixture(.failure(code))
            defer { fixture.close() }

            do {
                _ = try await GitHubUpdateChecker(session: fixture.session).check(installedVersion: "1.0.0")
                Issue.record("Transport failures must not report an update status.")
            } catch let error as URLError {
                #expect(error.code == code)
            }
        }
    }

    @Test func anAlreadyCancelledCheckRemainsCancelled() async {
        let fixture = UpdateHTTPFixture(.response(status: 200, body: #"{"tag_name":"v1.0.0","draft":false,"prerelease":false}"#))
        defer { fixture.close() }
        let checker = GitHubUpdateChecker(session: fixture.session)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await checker.check(installedVersion: "1.0.0")
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellingAnInFlightRequestRemainsCancellation() async {
        let fixture = UpdateHTTPFixture(.suspended)
        defer { fixture.close() }
        let checker = GitHubUpdateChecker(session: fixture.session)
        let task = Task { try await checker.check(installedVersion: "1.0.0") }
        for await _ in fixture.started { break }

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private func releaseJSON(_ tag: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "prerelease": false])
    return String(decoding: data, as: UTF8.self)
}

private final class UpdateHTTPFixture {
    enum Reply {
        case response(status: Int, body: String)
        case nonHTTP
        case failure(URLError.Code)
        case suspended
    }

    let reply: Reply
    let session: URLSession
    let started: AsyncStream<Void>
    private let start: AsyncStream<Void>.Continuation

    init(_ reply: Reply) {
        self.reply = reply
        let stream = AsyncStream<Void>.makeStream()
        started = stream.stream
        start = stream.continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateTestURLProtocol.self]
        session = URLSession(configuration: configuration)
        UpdateTestURLProtocol.lock.withLock { UpdateTestURLProtocol.fixture = self }
    }

    func close() {
        session.invalidateAndCancel()
        start.finish()
        UpdateTestURLProtocol.lock.withLock { UpdateTestURLProtocol.fixture = nil }
    }

    func receive(_ request: URLRequest, protocol urlProtocol: URLProtocol) {
        start.yield(())
        guard let url = request.url else {
            urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: URLError(.badURL))
            return
        }
        switch reply {
        case .response(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
            urlProtocol.client?.urlProtocol(urlProtocol, didLoad: Data(body.utf8))
            urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
        case .nonHTTP:
            let response = URLResponse(url: url, mimeType: "application/json", expectedContentLength: 0, textEncodingName: nil)
            urlProtocol.client?.urlProtocol(urlProtocol, didReceive: response, cacheStoragePolicy: .notAllowed)
            urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
        case .failure(let code):
            urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: URLError(code))
        case .suspended:
            break
        }
    }
}

private final class UpdateTestURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var fixture: UpdateHTTPFixture?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixture }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        fixture.receive(request, protocol: self)
    }

    override func stopLoading() {}
}
