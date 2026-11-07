import Foundation
import PrimuseKit
import XCTest
@testable import Primuse
#if os(iOS)
import CoreImage
import SwiftUI
#endif

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
    func testSongShareLinkPolicyPrefersNativeAndRequiresRelayConfirmationOnFallback() {
        let capabilities = SongShareLinkCapabilities(
            canTryMusicServer: true,
            canUsePrimuseRelay: true
        )

        XCTAssertEqual(
            SongShareLinkPolicy.availableMethods(for: capabilities),
            [.automatic, .musicServer, .primuseRelay]
        )
        XCTAssertEqual(
            SongShareLinkPolicy.decision(
                for: .automatic,
                nativeStatus: .checking,
                capabilities: capabilities
            ),
            .waitForMusicServer
        )
        XCTAssertEqual(
            SongShareLinkPolicy.decision(
                for: .automatic,
                nativeStatus: .available,
                capabilities: capabilities
            ),
            .useMusicServer
        )
        for unavailableStatus in [
            SongShareNativeCapabilityStatus.unsupported,
            .permissionDenied,
            .failed,
        ] {
            XCTAssertEqual(
                SongShareLinkPolicy.decision(
                    for: .automatic,
                    nativeStatus: unavailableStatus,
                    capabilities: capabilities
                ),
                .confirmPrimuseRelay
            )
        }
        XCTAssertEqual(
            SongShareLinkPolicy.decision(
                for: .primuseRelay,
                nativeStatus: .available,
                capabilities: capabilities
            ),
            .usePrimuseRelay
        )
        XCTAssertEqual(
            SongShareLinkPolicy.decision(
                for: .musicServer,
                nativeStatus: .failed,
                capabilities: capabilities
            ),
            .unavailable
        )
    }

    func testSongShareLinkPolicySupportsRelayOnlySongsWithoutSilentlyStartingUpload() {
        let capabilities = SongShareLinkCapabilities(
            canTryMusicServer: false,
            canUsePrimuseRelay: true
        )

        XCTAssertEqual(
            SongShareLinkPolicy.availableMethods(for: capabilities),
            [.automatic, .primuseRelay]
        )
        XCTAssertEqual(
            SongShareLinkPolicy.decision(
                for: .automatic,
                nativeStatus: .unsupported,
                capabilities: capabilities
            ),
            .confirmPrimuseRelay
        )
        XCTAssertEqual(
            SongShareLinkPolicy.decision(
                for: .primuseRelay,
                nativeStatus: .unsupported,
                capabilities: capabilities
            ),
            .usePrimuseRelay
        )
    }

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

@MainActor
final class ListeningShareExportTests: XCTestCase {
    func testPublicServerRadioAndPodcastExportDespiteInvalidItemsAndArtwork() async throws {
        let stream = "https://radio.example.org/live?token=public&key=channel"
        let stations = [
            RadioStation(name: "Public radio", streamURL: stream, logoData: Data([0, 1, 2]),
                         sourceID: "private-source", sourcePlaybackPath: "private-playback-path",
                         homepageURL: "javascript:invalid", remoteLogoURL: "https://user:secret@radio.example.org/logo.png?size=120"),
            RadioStation(name: "Unavailable radio", streamURL: "file:///private/radio.mp3")
        ]
        let podcasts = [PodcastShow(id: "public-feed", feedURL: URL(string: "https://podcast.example.org/feed?sig=public")!, title: "Podcast", subscribedAt: Date())]
        let exported = try await ListeningShareService.prepare(
            .init(title: "Collection", stations: stations, podcasts: podcasts), includeSettings: false
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: exported.directory) }

        XCTAssertEqual(exported.skippedItems, ["Unavailable radio"])
        XCTAssertEqual(exported.package.stations.map(\.streamURL), [stream])
        XCTAssertNil(exported.package.stations.first?.logo)
        XCTAssertNil(exported.package.stations.first?.homepageURL)
        XCTAssertEqual(exported.package.stations.first?.logoURL, "https://radio.example.org/logo.png?size=120")
        XCTAssertEqual(exported.package.podcasts.count, 1)
        let json = try Data(contentsOf: XCTUnwrap(exported.jsonURL))
        XCTAssertEqual(try ListeningShareJSON.decode(json), exported.package)
        XCTAssertEqual(try ListeningShareCode.decode(XCTUnwrap(exported.offlineCode)), exported.package)
        XCTAssertEqual(try ListeningShareArchive.read(exported.url).package, exported.package)
        let serialized = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(serialized.contains("private-source"))
        XCTAssertFalse(serialized.contains("private-playback-path"))
        XCTAssertFalse(serialized.contains("secret"))
    }

    func testUnavailableBookSourceAndLocalRadioDoNotBlockPublicExport() async throws {
        let missing = Song(id: "missing-chapter", title: "Unavailable chapter", fileFormat: .mp3,
                           filePath: "missing.mp3", sourceID: UUID().uuidString, fileSize: 100)
        let exported = try await ListeningShareService.prepare(
            .init(title: "Collection", stations: [
                RadioStation(name: "Public radio", streamURL: "https://radio.example.org/live"),
                RadioStation(name: "Local radio", streamURL: "http://192.168.1.2/live")
            ], bookSongs: [missing]), includeSettings: false, publicSharing: true
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: exported.directory) }
        XCTAssertEqual(exported.package.stations.map(\.name), ["Public radio"])
        XCTAssertTrue(exported.package.books.isEmpty)
        XCTAssertTrue(exported.package.assets.isEmpty)
        XCTAssertEqual(Set(exported.skippedItems), ["Unavailable chapter", "Local radio"])
        XCTAssertNoThrow(try exported.package.validated(publicSharing: true))
        XCTAssertEqual(try ListeningShareArchive.read(exported.url).package, exported.package)
    }

    func testAllUnavailableItemsReturnTheirNamesAndCancellationIsNotASkippedItem() async throws {
        let selection = ListeningShareSelection(title: "Collection", stations: [
            RadioStation(name: "Unavailable radio", streamURL: "https://radio.example.org/live?password=private")
        ])
        do {
            _ = try await ListeningShareService.prepare(selection, includeSettings: false) { _ in }
            XCTFail("Expected no shareable content")
        } catch let failure as ListeningShareService.NoShareableContent {
            XCTAssertEqual(failure.skippedItems, ["Unavailable radio"])
        }
        let task = Task { try await ListeningShareService.prepare(selection, includeSettings: false) { _ in } }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }
}

#if os(iOS)
@MainActor
final class MediaRelayQRCodeLayoutTests: XCTestCase {
    func testSharingFormKeepsQRCodeSquareScannableAndFollowingActionsVisible() async throws {
        for width: CGFloat in [320, 430, 768] {
            try await checkQRCode(width: width, compact: false)
        }
    }

    func testCompactMusicShareQRCodeRemainsScannable() async throws {
        try await checkQRCode(width: 390, compact: true)
    }

    private func checkQRCode(width: CGFloat, compact: Bool) async throws {
        let publicURL = try XCTUnwrap(URL(string: "https://share.example.invalid/s/123456#k=" + String(repeating: "A", count: 43)))
        let value = compact ? publicURL.absoluteString : try ListeningShareCode.appImportURL(for: publicURL).absoluteString
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 640)
        var actionFrame = CGRect.zero
        let host = UIHostingController(rootView: NavigationStack {
            Form {
                Section {
                    Text("Share link")
                    MediaRelayQRCodeView(value: value)
                        .frame(width: compact ? 172 : nil, height: compact ? 172 : nil)
                        .frame(maxWidth: .infinity)
                }
                Section {
                    Text("Export JSON")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { actionFrame = $0 }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
        }.preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "share-qr-\(Int(width))-\(compact ? "compact" : "regular")"
        attachment.lifetime = .keepAlways
        add(attachment)
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let features = detector.features(in: CIImage(cgImage: try XCTUnwrap(image.cgImage)))
        let result = try XCTUnwrap(features.compactMap { $0 as? CIQRCodeFeature }.first)
        XCTAssertEqual(result.messageString, value)
        if !compact {
            let request = try XCTUnwrap(ListeningShareCodeImportRequest(url: XCTUnwrap(URL(string: value))))
            XCTAssertEqual(request.reference.shareURL, publicURL)
        }
        let qrWidth = result.bounds.width / format.scale
        let qrHeight = result.bounds.height / format.scale
        XCTAssertEqual(qrWidth, qrHeight, accuracy: 2)
        XCTAssertLessThanOrEqual(qrWidth, compact ? 172 : 240)
        XCTAssertFalse(actionFrame.isEmpty)
        XCTAssertTrue(host.view.bounds.contains(actionFrame))
    }
}
#endif

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
