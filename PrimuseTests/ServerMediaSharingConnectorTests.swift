import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class ServerMediaSharingConnectorTests: XCTestCase {
    func testCapabilityAndCreateShareUseStandardParametersAndExactPublicURL() async throws {
        let host = "share-success.invalid"
        let exactURL = "https://public.example/music/share/exact%2Fid?ref=a%20b"
        configureURLProtocol(
            host: host,
            mode: .success(publicURL: exactURL)
        )
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        let availability = try await source.serverMediaSharingAvailability()
        XCTAssertEqual(availability, .available(.openSubsonic))

        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000.25)
        let request = try ServerMediaShareRequest(
            itemIDs: ["song.a", "歌曲-2"],
            description: "For friends",
            expiresAt: expiresAt
        )
        let share = try await source.createServerMediaShare(request)

        XCTAssertEqual(share.publicURLString, exactURL)
        let requests = ServerMediaShareURLProtocol.requests(host: host)
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/rest/ping.view",
            "/rest/getShares.view",
            "/rest/createShare.view",
        ])
        let createURL = try XCTUnwrap(requests.last?.url)
        let query = URLComponents(url: createURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.filter { $0.name == "id" }.map(\.value), ["song.a", "歌曲-2"])
        XCTAssertEqual(query.first(where: { $0.name == "description" })?.value, "For friends")
        XCTAssertEqual(query.first(where: { $0.name == "expires" })?.value, "1800000000250")
        XCTAssertNotNil(query.first(where: { $0.name == "u" }))
        XCTAssertNotNil(query.first(where: { $0.name == "t" }))
        XCTAssertNotNil(query.first(where: { $0.name == "s" }))
        XCTAssertNil(query.first(where: { $0.name == "p" }))
        XCTAssertNil(query.first(where: { $0.name.lowercased().contains("password") }))
    }

    func testUnsupportedAndDisabledSharingAreCapabilityResults() async throws {
        for (host, mode) in [
            ("share-501.invalid", ServerMediaShareURLProtocol.Mode.http501),
            ("share-disabled.invalid", .sharingDisabled),
        ] {
            configureURLProtocol(host: host, mode: mode)
            let (source, session) = makeSource(host: host)
            defer { session.invalidateAndCancel() }

            let availability = try await source.serverMediaSharingAvailability()
            XCTAssertEqual(availability, .unsupported)
        }
    }

    func testPermissionAndAuthenticationRemainDistinct() async throws {
        let permissionHost = "share-permission.invalid"
        configureURLProtocol(host: permissionHost, mode: .permissionDenied)
        let (permissionSource, permissionSession) = makeSource(host: permissionHost)
        defer { permissionSession.invalidateAndCancel() }
        let permissionAvailability = try await permissionSource.serverMediaSharingAvailability()
        XCTAssertEqual(permissionAvailability, .permissionDenied)

        let authHost = "share-auth.invalid"
        configureURLProtocol(host: authHost, mode: .authenticationFailed)
        let (authSource, authSession) = makeSource(host: authHost)
        defer { authSession.invalidateAndCancel() }
        do {
            _ = try await authSource.serverMediaSharingAvailability()
            XCTFail("Expected authentication failure")
        } catch let sourceError as SourceError {
            guard case .authenticationFailed = sourceError else {
                return XCTFail("Unexpected source error: \(sourceError)")
            }
        }
    }

    func testCreateShareMapsHTTP501ToUnsupported() async throws {
        let host = "share-create-501.invalid"
        configureURLProtocol(host: host, mode: .createHTTP501)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }
        let request = try ServerMediaShareRequest(itemIDs: ["song-1"])

        do {
            _ = try await source.createServerMediaShare(request)
            XCTFail("Expected unsupported share endpoint")
        } catch let error as ServerMediaSharingError {
            XCTAssertEqual(error, .unsupported)
        }
    }

    func testIPv6HostPortAndBasePathSurviveRequestConstruction() async throws {
        let host = "share-base-path.invalid"
        configureURLProtocol(
            host: host,
            mode: .success(publicURL: "https://[2606:4700:4700::1111]:4533/public/share/abc")
        )
        let (source, session) = makeSource(
            host: host,
            port: 4533,
            basePath: "/music/base/"
        )
        defer { session.invalidateAndCancel() }

        _ = try await source.createServerMediaShare(
            ServerMediaShareRequest(itemIDs: ["song-1", "song-2"])
        )
        let requests = ServerMediaShareURLProtocol.requests(host: host)
        let createURL = try XCTUnwrap(requests.last?.url)
        XCTAssertEqual(createURL.scheme, "https")
        XCTAssertEqual(createURL.host, host)
        XCTAssertEqual(createURL.port, 4533)
        XCTAssertEqual(createURL.path, "/music/base/rest/createShare.view")

        let ipv6BaseURL = try XCTUnwrap(NetworkURLBuilder.baseURL(
            host: "2001:db8::77",
            scheme: "https",
            port: 4533
        ))
        XCTAssertEqual(ipv6BaseURL.scheme, "https")
        XCTAssertTrue(["2001:db8::77", "[2001:db8::77]"].contains(ipv6BaseURL.host ?? ""))
        XCTAssertEqual(ipv6BaseURL.port, 4533)
        XCTAssertTrue(ipv6BaseURL.absoluteString.hasPrefix("https://[2001:db8::77]:4533"))
    }

    func testUnsafeServerResponseIsRejectedInsteadOfShared() async throws {
        let host = "share-unsafe.invalid"
        configureURLProtocol(
            host: host,
            mode: .success(
                publicURL: "https://music.example/rest/stream.view?id=1&u=user&t=token&s=salt"
            )
        )
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await source.createServerMediaShare(
                ServerMediaShareRequest(itemIDs: ["song-1"])
            )
            XCTFail("Expected unsafe URL rejection")
        } catch let error as ServerMediaSharingError {
            XCTAssertEqual(error, .unsafePublicURL)
        }
    }

    func testCapabilityProbeHonorsTaskCancellation() async throws {
        let host = "share-cancel.invalid"
        configureURLProtocol(host: host, mode: .delayedCapability)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        let task = Task { try await source.serverMediaSharingAvailability() }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func makeSource(
        host: String,
        port: Int? = nil,
        basePath: String? = nil
    ) -> (SubsonicSource, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerMediaShareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (
            SubsonicSource(
                sourceID: "source-\(host)",
                sourceType: .navidrome,
                host: host,
                port: port,
                useSsl: true,
                basePath: basePath,
                username: "qa-user",
                password: "qa-password",
                session: session
            ),
            session
        )
    }

    private func configureURLProtocol(host: String, mode: ServerMediaShareURLProtocol.Mode) {
        ServerMediaShareURLProtocol.configure(host: host, mode: mode)
        addTeardownBlock {
            ServerMediaShareURLProtocol.reset(host: host)
        }
    }
}

extension ServerMediaSharingConnectorTests {
    func testMediaRelayImportDeepLinkRequiresSafeOneTimeEndpoint() throws {
        let ticket = String(repeating: "a", count: 32)
        let importURL = "https://share.example.com/i/\(ticket)"
        let encoded = try XCTUnwrap(importURL.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ))
        let request = try XCTUnwrap(MediaRelayImportRequest(
            url: try XCTUnwrap(URL(string: "primuse://import-share?url=\(encoded)"))
        ))
        XCTAssertEqual(request.importURL.absoluteString, importURL)

        for rawValue in [
            "primuse://import-share?url=http%3A%2F%2Fshare.example.com%2Fi%2F\(ticket)",
            "primuse://import-share?url=https%3A%2F%2Fshare.example.com%2Fs%2F\(ticket)",
            "primuse://import-share?url=https%3A%2F%2Fshare.example.com%2Fi%2Fshort",
            "primuse://import-share?url=https%3A%2F%2F127.0.0.1%2Fi%2F\(ticket)",
            "primuse://import-share?url=https%3A%2F%2Fshare.example.com%2Fi%2F\(ticket)%3Fcopy%3D1",
            "primuse://import-share?url=\(encoded)&source=browser",
            "primuse://pair?url=\(encoded)",
        ] {
            XCTAssertNil(MediaRelayImportRequest(url: try XCTUnwrap(URL(string: rawValue))))
        }
    }

    func testMediaRelayImportFileNameValidation() throws {
        XCTAssertEqual(
            try MediaRelayImportPolicy.validatedFileName("Night/Drive.FLAC"),
            "Night_Drive.FLAC"
        )
        XCTAssertThrowsError(try MediaRelayImportPolicy.validatedFileName("index.html"))
        XCTAssertThrowsError(try MediaRelayImportPolicy.validatedFileName(".secret.mp3"))
        XCTAssertThrowsError(try MediaRelayImportPolicy.validatedFileName(nil))
    }
}

private final class ServerMediaShareURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Equatable {
        case success(publicURL: String)
        case http501
        case createHTTP501
        case sharingDisabled
        case permissionDenied
        case authenticationFailed
        case delayedCapability
    }

    private struct State {
        let mode: Mode
        var requests: [URLRequest] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    private var delayedWorkItem: DispatchWorkItem?

    static func configure(host: String, mode: Mode) {
        lock.lock()
        states[normalizedHost(host)] = State(mode: mode)
        lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return states[normalizedHost(host)]?.requests ?? []
    }

    static func reset(host: String) {
        lock.lock()
        states.removeValue(forKey: normalizedHost(host))
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let rawHost = url.host else {
            fail(.badURL)
            return
        }
        let host = Self.normalizedHost(rawHost)
        Self.lock.lock()
        guard var state = Self.states[host] else {
            Self.lock.unlock()
            fail(.cannotFindHost)
            return
        }
        state.requests.append(request)
        Self.states[host] = state
        Self.lock.unlock()

        switch url.path {
        case let path where path.hasSuffix("/rest/ping.view"):
            respond(json: #"{"subsonic-response":{"status":"ok","type":"navidrome","openSubsonic":true}}"#)
        case let path where path.hasSuffix("/rest/getShares.view"):
            handleCapability(mode: state.mode)
        case let path where path.hasSuffix("/rest/createShare.view"):
            handleCreate(mode: state.mode)
        default:
            fail(.unsupportedURL)
        }
    }

    override func stopLoading() {
        delayedWorkItem?.cancel()
        delayedWorkItem = nil
    }

    private func handleCapability(mode: Mode) {
        switch mode {
        case .http501:
            respond(statusCode: 501, json: "{}")
        case .sharingDisabled:
            respond(json: failedResponse(code: 50, message: "Sharing is disabled"))
        case .permissionDenied:
            respond(json: failedResponse(code: 50, message: "User is not authorized"))
        case .authenticationFailed:
            respond(statusCode: 401, json: "{}")
        case .delayedCapability:
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.respond(json: #"{"subsonic-response":{"status":"ok","shares":{"share":[]}}}"#)
            }
            delayedWorkItem = workItem
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: workItem)
        case .success, .createHTTP501:
            respond(json: #"{"subsonic-response":{"status":"ok","shares":{"share":[]}}}"#)
        }
    }

    private func handleCreate(mode: Mode) {
        switch mode {
        case .createHTTP501, .http501:
            respond(statusCode: 501, json: "{}")
        case .sharingDisabled:
            respond(json: failedResponse(code: 50, message: "Sharing is disabled"))
        case .permissionDenied:
            respond(json: failedResponse(code: 50, message: "User is not authorized"))
        case .authenticationFailed:
            respond(statusCode: 401, json: "{}")
        case .delayedCapability:
            fail(.timedOut)
        case .success(let publicURL):
            let root: [String: Any] = [
                "subsonic-response": [
                    "status": "ok",
                    "shares": [
                        "share": [[
                            "id": "share-1",
                            "url": publicURL,
                            "created": "2026-09-01T00:00:00Z",
                        ]],
                    ],
                ],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: root),
                  let json = String(data: data, encoding: .utf8) else {
                fail(.cannotDecodeContentData)
                return
            }
            respond(json: json)
        }
    }

    private func failedResponse(code: Int, message: String) -> String {
        #"{"subsonic-response":{"status":"failed","error":{"code":\#(code),"message":"\#(message)"}}}"#
    }

    private func respond(statusCode: Int = 200, json: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            fail(.badServerResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }
}
