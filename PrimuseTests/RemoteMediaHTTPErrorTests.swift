import Foundation
import Security
import PrimuseKit
import XCTest
@testable import Primuse

final class RemoteMediaHTTPErrorTests: XCTestCase {
    func testCloudReadErrorClearsAfterSuccessfulRead() throws {
        for explicitError in [false, true] {
            let input = CloudInputSourceObjC(
                url: URL(string: "primuse-cloud://fixture/read.bin"), totalLength: 8
            ) { offset, length, error in
                if offset < 4 {
                    if explicitError {
                        error?.pointee = URLError(.networkConnectionLost) as NSError
                        return nil
                    }
                    return Data()
                }
                return Data(repeating: 7, count: min(Int(length), 8 - Int(offset)))
            }
            try input.open()
            defer { try? input.close() }
            var bytes = [UInt8](repeating: 0, count: 4)
            XCTAssertThrowsError(try bytes.withUnsafeMutableBytes { try input.read($0.baseAddress!, length: 4) })
            XCTAssertNotNil(input.lastReadError)
            try input.seek(toOffset: 4)
            let count = try bytes.withUnsafeMutableBytes { try input.read($0.baseAddress!, length: 4) }
            XCTAssertEqual(count, 4)
            XCTAssertEqual(bytes, [7, 7, 7, 7])
            XCTAssertNil(input.lastReadError)
            let end = try bytes.withUnsafeMutableBytes { try input.read($0.baseAddress!, length: 4) }
            XCTAssertEqual(end, 0)
            XCTAssertNil(input.lastReadError)
        }
    }

    @MainActor
    func testWebDAVSeekReadFailureRecoversAtRequestedPosition() async throws {
        _ = AppServices.shared
        await Task.yield()
        let audioSession = AudioSessionManager.shared
        let previousBegan = audioSession.onInterruptionBegan
        let previousEnded = audioSession.onInterruptionEnded
        let previousConfiguration = audioSession.onConfigurationChange
        let modes = ListeningPlayModeStore.shared.ledger
        let historyWasSuspended = PlayHistoryStore.shared.isRecordingSuspended
        let scrobbleWasSuspended = ScrobbleService.shared.isSuspended
        PlayHistoryStore.shared.isRecordingSuspended = true
        ScrobbleService.shared.isSuspended = true
        defer {
            audioSession.onInterruptionBegan = previousBegan
            audioSession.onInterruptionEnded = previousEnded
            audioSession.onConfigurationChange = previousConfiguration
            ListeningPlayModeStore.shared.update { $0 = modes }
            PlayHistoryStore.shared.isRecordingSuspended = historyWasSuspended
            ScrobbleService.shared.isSuspended = scrobbleWasSuspended
        }

        for startPlaying in [false, true] {
            let source = MusicSource(id: UUID().uuidString, name: "WebDAV seek", type: .webdav)
            let failureOffset = Int64((startPlaying ? 14 : 10) * 1_024 * 1_024)
            let target = startPlaying ? Double(failureOffset - 44 - 32_768) / 192_000 : 75
            let connector = SeekReadFailureConnector(sourceID: source.id, failureOffset: failureOffset)
            let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = "WebDAVSeekTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = PlaybackSettingsStore(defaults: defaults)
            settings.outputMode = .effects
            settings.audioCacheEnabled = true
            settings.prewarmQueueCount = 0
            settings.skipLeadingSilenceEnabled = false
            settings.skipTrailingSilenceEnabled = false
            settings.replayGainEnabled = false
            settings.gaplessEnabled = false
            settings.crossfadeEnabled = false
            let player = AudioPlayerService(
                sourceManager: manager, playbackSettings: settings,
                playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
            )
            let song = Song(
                id: UUID().uuidString, title: "WebDAV seek", duration: 120,
                fileFormat: .wav, filePath: "/music.wav", sourceID: source.id,
                fileSize: Int64(connector.payload.count)
            )
            defer {
                player.stop()
                CloudPlaybackSource.cancelSessions(sourceID: source.id)
                manager.deleteAudioCache(for: song)
            }
            await Task.yield()
            player.playbackMetadataSourceType = { _ in .webdav }
            player.audioEngine.setVolume(0, persist: false)
            player.setQueue([song])
            player.repeatMode = .off
            await player.play(song: song)
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(player.activeDecoderKind, .cloudStream)
            XCTAssertNil(manager.cachedURL(for: song))

            player.seek(to: target, startPlaying: startPlaying)
            let deadline = Date().addingTimeInterval(20)
            while player.isLoading, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(player.isLoading)
            XCTAssertNil(player.lastPlaybackError)
            XCTAssertEqual(player.currentSong?.id, song.id)
            XCTAssertEqual(player.currentTime, target, accuracy: 1)
            XCTAssertEqual(player.isPlaying, startPlaying)
            XCTAssertEqual(player.currentIndex, 0)
            let failedReads = await connector.failedReads
            let completeReads = await connector.completeReads
            XCTAssertGreaterThan(failedReads, 0, "Must exercise an uncached read after the decoder seeks")
            XCTAssertGreaterThan(completeReads, 0, "Must recover through the complete-file path")
            XCTAssertNotNil(manager.cachedURL(for: song))
            XCTAssertNotEqual(manager.offlineAudioSnapshot(for: song).state, .pinned)
        }
    }

    func testWebDAVListingsExcludeRecycleDirectoryAndDescendants() {
        for path in ["/podcast/#recycle", "/podcast/#RECYCLE/", "/podcast/#recycle/old"] {
            XCTAssertFalse(WebDAVDirectoryVisibilityPolicy.includes(path: path, isDirectory: true))
        }
        for path in ["/podcast/#recycle/episode.mp3", "/podcast/#RECYCLE/old/episode.mp3"] {
            XCTAssertFalse(WebDAVDirectoryVisibilityPolicy.includes(path: path, isDirectory: false))
        }
    }

    func testWebDAVRecycleFilterPreservesOrdinarySimilarNames() {
        for path in ["/podcast", "/podcast/recycle", "/podcast/#recycle collection"] {
            XCTAssertTrue(WebDAVDirectoryVisibilityPolicy.includes(path: path, isDirectory: true))
        }
        for path in ["/podcast/episode.mp3", "/podcast/#recycle.mp3", "/podcast/#recycle"] {
            XCTAssertTrue(WebDAVDirectoryVisibilityPolicy.includes(path: path, isDirectory: false))
        }
    }

    func testWebDAVDirectoryRemovalRequiresConsistentIndependentListings() {
        let previous: Set<String> = ["/Music/A.flac", "/Music/B.flac"]
        let firstMissing = WebDAVDirectoryListingConfirmationPolicy.missingPaths(
            previouslyObserved: previous,
            listed: ["/Music/A.flac"]
        )

        XCTAssertFalse(firstMissing.isEmpty)
        XCTAssertTrue(WebDAVDirectoryListingConfirmationPolicy.acceptsIndependentConfirmation(
            firstMissing: firstMissing,
            secondMissing: firstMissing
        ))
        XCTAssertTrue(WebDAVDirectoryListingConfirmationPolicy.acceptsIndependentConfirmation(
            firstMissing: firstMissing,
            secondMissing: []
        ))
        XCTAssertFalse(WebDAVDirectoryListingConfirmationPolicy.acceptsIndependentConfirmation(
            firstMissing: firstMissing,
            secondMissing: ["/music/a.flac"]
        ))
    }

    func testWebDAVDirectoryComparisonNormalizesCaseAndUnicode() {
        XCTAssertTrue(WebDAVDirectoryListingConfirmationPolicy.missingPaths(
            previouslyObserved: ["/Music/Caf\u{00E9}.flac"],
            listed: ["/music/Cafe\u{0301}.flac"]
        ).isEmpty)
    }

    func testWebDAVConfirmationIncludesPreviouslyIndexedAndLegacySongChildren() {
        let indexed = SourceSyncIndexedItem(
            stableKey: "path:/music/indexed",
            path: "/Music/Indexed",
            parentPath: "/Music",
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            revision: nil
        )
        let legacySong = Song(
            id: "legacy",
            title: "Legacy",
            fileFormat: .flac,
            filePath: "/Music/Legacy/Track.flac",
            sourceID: "source"
        )

        XCTAssertEqual(
            ConnectorScanner.previouslyObservedChildPaths(
                in: "/Music/",
                identityIndex: [indexed.stableKey: indexed],
                existingSongs: [legacySong]
            ),
            ["/Music/Indexed", "/Music/Legacy"]
        )
    }

    func testRetryAfterParsesWholeSecondsWithoutClampingServerDelay() throws {
        for (header, expected) in [("120", 120.0), (" 0 ", 0.0), ("3600", 3600.0)] {
            XCTAssertEqual(
                RemoteMediaHTTPError.retryDelay(from: try response(retryAfter: header)),
                expected
            )
        }
    }

    func testRetryAfterParsesHTTPDatesAgainstProvidedTime() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "1994-11-06T08:49:37Z"))
        for header in [
            "Sun, 06 Nov 1994 08:51:37 GMT",
            "Sunday, 06-Nov-94 08:51:37 GMT",
            "Sun Nov  6 08:51:37 1994"
        ] {
            XCTAssertEqual(
                RemoteMediaHTTPError.retryDelay(from: try response(retryAfter: header), now: now),
                120,
                header
            )
        }
    }

    func testPastRetryAfterDateDoesNotCreateNegativeDelay() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "1994-11-06T08:51:37Z"))
        XCTAssertEqual(
            RemoteMediaHTTPError.retryDelay(
                from: try response(retryAfter: "Sun, 06 Nov 1994 08:49:37 GMT"),
                now: now
            ),
            0
        )
    }

    func testMissingOrMalformedRetryAfterDoesNotInventDelay() throws {
        XCTAssertNil(RemoteMediaHTTPError.retryDelay(from: try response()))
        for header in ["", " ", "-1", "1.5", "1e2", "NaN", "Infinity", "later", "Sun, 40 Nov 1994 08:49:37 GMT"] {
            XCTAssertNil(RemoteMediaHTTPError.retryDelay(from: try response(retryAfter: header)), header)
        }
    }

    func testWebDAVHTTPFailuresPreserveStatusBeforeInspectingHTML() async throws {
        let source = makeWebDAV()
        for status in [401, 403, 404, 429, 503] {
            do {
                _ = try await source.validateStrictRangeResponse(
                    response(status: status, retryAfter: "17", contentType: "text/html"),
                    data: Data("<html>Request failed</html>".utf8),
                    path: "/song.flac",
                    offset: 0,
                    length: 4
                )
                XCTFail("HTTP \(status) must fail before its body can be treated as audio")
            } catch let error as RemoteMediaHTTPError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertEqual(error.retryAfter, 17)
                XCTAssertEqual(error.service, "WebDAV")
            } catch {
                XCTFail("HTTP \(status) was hidden by a different error: \(error)")
            }
        }
    }

    func testWebDAVSuccessfulStatusStillRejectsLoginPageAndIgnoredRange() async throws {
        let source = makeWebDAV()
        let cases: [(Int, String, Data, Int64)] = [
            (200, "text/html", Data("<html>Log in</html>".utf8), 0),
            (206, "text/html", Data("<html>Log in</html>".utf8), 0),
            (200, "audio/flac", Data([0xFF, 0xFA, 0x00, 0x01]), 4)
        ]
        for (status, contentType, data, offset) in cases {
            do {
                _ = try await source.validateStrictRangeResponse(
                    response(status: status, contentType: contentType),
                    data: data,
                    path: "/song.flac",
                    offset: offset,
                    length: 4
                )
                XCTFail("An HTTP success status must not bypass media and Range validation")
            } catch {
                XCTAssertTrue(error is SourceError, "Unexpected error: \(error)")
                XCTAssertFalse(error is RemoteMediaHTTPError)
            }
        }
    }

    func testWebDAVExactRangeStillReturnsAudio() async throws {
        let source = makeWebDAV()
        let data = Data([0xFF, 0xFA, 0x00, 0x01])
        let http = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://media-errors.invalid/song.flac")!,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "audio/flac",
                "Content-Range": "bytes 0-3/8",
                "Content-Length": "4"
            ]
        ))
        let result = try await source.validateStrictRangeResponse(
            http,
            data: data,
            path: "/song.flac",
            offset: 0,
            length: 4
        )
        XCTAssertEqual(result, data)
    }

    private func response(
        status: Int = 503,
        retryAfter: String? = nil,
        contentType: String = "audio/flac"
    ) throws -> HTTPURLResponse {
        var headers = ["Content-Type": contentType]
        headers["Retry-After"] = retryAfter
        return try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://media-errors.invalid/song.flac")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
    }

    @MainActor
    func testWebDAVDeleteSendsRequestAndRequiresConfirmedCompletionForHTTPAndHTTPS() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeletionStatusURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for useSSL in [false, true] {
            let sourceID = UUID().uuidString
            let source = WebDAVSource(sourceID: sourceID, host: "127.0.0.1", useSsl: useSSL,
                                      username: "", password: "", mutationSession: session)
            for status in [200, 204, 401, 403, 404, 405, 410, 202, 207] {
                let path = "/\(sourceID)/\(status).flac"
                do {
                    try await source.deleteFile(at: path)
                    XCTAssertTrue([200, 204].contains(status), "HTTP \(status) must not confirm deletion")
                } catch {
                    switch status {
                    case 401: XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), .authenticationRequired)
                    case 403: XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), .permissionDenied)
                    case 405: XCTAssertEqual(SourceFileDeletionFailureReason.classify(error), .readOnly)
                    case 404, 410: XCTAssertTrue(SourceManager.isMissingFileError(error))
                    case 202, 207: XCTAssertFalse(SourceManager.isMissingFileError(error))
                    default: XCTFail("Unexpected DELETE failure: \(error)")
                    }
                }
                let requests = DeletionStatusURLProtocol.requests(path: path)
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(requests.first?.httpMethod, "DELETE")
                XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
            }
            await source.disconnect()
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(sourceID)
            try? FileManager.default.removeItem(at: cache)
        }
    }

    private func makeWebDAV() -> WebDAVSource {
        let sourceID = "media-http-errors-\(UUID().uuidString)"
        let source = WebDAVSource(
            sourceID: sourceID,
            host: "media-errors.invalid",
            useSsl: true,
            username: "",
            password: ""
        )
        addTeardownBlock {
            await source.disconnect()
            let cache = FileManager.default.temporaryDirectory
                .appendingPathComponent("primuse_webdav_cache")
                .appendingPathComponent(sourceID)
            try? FileManager.default.removeItem(at: cache)
        }
        return source
    }
}

private actor SeekReadFailureConnector: MusicSourceConnector {
    nonisolated let sourceID: String
    nonisolated let payload: Data
    private let failureOffset: Int64
    private(set) var failedReads = 0
    private(set) var completeReads = 0

    init(sourceID: String, failureOffset: Int64) {
        self.sourceID = sourceID
        self.failureOffset = failureOffset
        // Muted PCM fixture: enough uncached data to seek beyond the read-ahead window.
        let byteCount = 120 * 48_000 * 4
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt32(byteCount + 36))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(48_000))
        append(UInt32(192_000))
        append(UInt16(4))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(byteCount))
        data.append(Data(repeating: 0, count: byteCount))
        payload = data
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchRange(path: String, offset: Int64, length: Int64, priority: RangeFetchPriority) async throws -> Data {
        // Playback's small random windows fail; the ordinary complete transfer succeeds.
        // WAV seeking itself succeeds, and the subsequent PCM read raises a decoder error.
        if length > CloudPlaybackSource.chunkSize {
            completeReads += 1
        } else if offset >= failureOffset, offset < 20 * 1_024 * 1_024 {
            failedReads += 1
            throw SourceError.connectionFailed("Invalid WebDAV Content-Range response")
        }
        guard offset >= 0, offset < payload.count, length > 0 else { return Data() }
        return payload.subdata(in: Int(offset)..<min(payload.count, Int(offset + length)))
    }
}

private final class DeletionStatusURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]
    static func requests(path: String) -> [URLRequest] { lock.withLock { recorded[path] ?? [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.recorded[url.path, default: []].append(request) }
        let status = Int(url.deletingPathExtension().lastPathComponent) ?? 500
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class MediaServerRequestTests: XCTestCase {
    @MainActor
    func testStructuredFailuresKeepOfflineAndReauthenticationClassification() {
        for (status, expected) in [(401, AutomaticOfflineFailureKind.authentication), (403, .sourceAccessDenied),
                                   (429, .rateLimited), (503, .rateLimited), (500, .sourceUnavailable),
                                   (400, .sourceUnavailable), (404, .sourceUnavailable)] {
            let failure = HTTPResponseFailure(statusCode: status)
            XCTAssertEqual(AutomaticOfflineFailureClassifier.classify(failure), expected)
            XCTAssertEqual(ServerCatalogAutoRefreshCoordinator.requiresReauthentication(failure), status == 401)
        }
        XCTAssertEqual(AutomaticOfflineFailureClassifier.classify(
            HTTPResponseFailure(statusCode: 403, retryAfter: 3600)
        ), .rateLimited)
    }

    func testUgreenV2CompatibilityFailuresFallBackToV1() async throws {
        for status in [400, 401, 403, 404, 500] {
            let fixture = try MediaCompatibilityFixture(status: status)
            let session = fixture.session()
            defer { session.invalidateAndCancel() }
            let api = UgreenAPI(host: fixture.host, port: 443, useSsl: true, session: session)
            let login = await api.login(account: "qa", password: "fixture")
            XCTAssertTrue(login.success)
            do {
                let files = try await api.listDirectory(path: "/music")
                XCTAssertEqual(files.map(\.name), ["track.flac"])
            } catch { XCTFail("HTTP \(status) should allow legacy firmware fallback: \(error)") }
            XCTAssertTrue(fixture.paths.contains("/ugreen/v2/filemgr/getDirFileListV2"))
            XCTAssertEqual(fixture.paths.filter { $0 == "/ugreen/v1/filemgr/list" }.count, 1)
        }
    }

    func testUgreenV2CooldownNeverStartsLegacyFallback() async throws {
        for status in [429, 503, 403] {
            let fixture = try MediaCompatibilityFixture(status: status, retryAfter: "3600")
            let session = fixture.session()
            defer { session.invalidateAndCancel() }
            let api = UgreenAPI(host: fixture.host, port: 443, useSsl: true, session: session)
            _ = await api.login(account: "qa", password: "fixture")
            do { _ = try await api.listDirectory(path: "/music"); XCTFail("Expected cooldown") }
            catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590) }
            XCTAssertFalse(fixture.paths.contains("/ugreen/v1/filemgr/list"))
        }
    }

    func testMediaServerInstancesShareCompleteServerCooldown() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        MediaQuotaURLProtocol.reset(status: 503)
        for _ in 0..<2 {
            let source = MediaServerSource(sourceID: UUID().uuidString, kind: .jellyfin,
                host: host, port: nil, useSsl: true, basePath: nil,
                username: "quota-user", secret: "fixture", authType: .apiKey,
                requestDataLoader: { MediaQuotaURLProtocol.reply(to: $0) })
            do { try await source.connect(); XCTFail("Expected server cooldown") }
            catch let error as HTTPResponseFailure {
                XCTAssertEqual(error.statusCode, 503)
                XCTAssertGreaterThan(try XCTUnwrap(error.retryAfter), 3590)
            } catch { XCTFail("Expected complete HTTP failure, got \(error)") }
        }
        XCTAssertEqual(MediaQuotaURLProtocol.requests, 1)
    }

    func testFnMusicCatalogRetainsCooldownAcrossPages() async throws {
        let session = quotaSession()
        defer { session.invalidateAndCancel() }
        MediaQuotaURLProtocol.reset(status: 429)
        let api = FnMusicAPI(sourceID: UUID().uuidString, host: UUID().uuidString + ".invalid",
            port: nil, useSSL: true, basePath: nil, connectionMode: .address,
            accessCode: nil, session: session)
        for page in 1...2 {
            await assertQuota { _ = try await api.trackPage(page: page, size: 1) }
        }
        XCTAssertEqual(MediaQuotaURLProtocol.requests, 1)
    }

    func testNASDirectoryQuotasDoNotBecomeEmptyDirectoriesOrReauthentication() async throws {
        for kind in ["synology", "qnap", "ugreen"] {
            let session = quotaSession()
            defer { session.invalidateAndCancel() }
            MediaQuotaURLProtocol.reset(status: 429)
            let host = UUID().uuidString + ".invalid"
            switch kind {
            case "synology":
                let api = SynologyAPI(host: host, port: 443, useSsl: true, session: session)
                let login = await api.login(account: "qa", password: "fixture")
                XCTAssertTrue(login.success)
                for _ in 0..<2 { await assertQuota { _ = try await api.listDirectory(path: "/") } }
                let loggedIn = await api.isLoggedIn
                XCTAssertTrue(loggedIn)
            case "qnap":
                let api = QnapAPI(host: host, port: 443, useSsl: true, session: session)
                let login = await api.login(account: "qa", password: "fixture")
                XCTAssertTrue(login.success)
                for _ in 0..<2 { await assertQuota { _ = try await api.listDirectory(path: "/") } }
                let loggedIn = await api.isLoggedIn
                XCTAssertTrue(loggedIn)
            default:
                let api = UgreenAPI(host: host, port: 443, useSsl: true, session: session)
                let login = await api.login(account: "qa", password: "fixture")
                XCTAssertTrue(login.success)
                for _ in 0..<2 { await assertQuota { _ = try await api.listDirectory(path: "/") } }
                let loggedIn = await api.isLoggedIn
                XCTAssertTrue(loggedIn)
            }
            XCTAssertEqual(MediaQuotaURLProtocol.requests, 1, kind)
        }
    }

    func testQnapForbiddenInvalidatesTheRejectedSession() async throws {
        let session = quotaSession()
        defer { session.invalidateAndCancel() }
        MediaQuotaURLProtocol.reset(status: 403, retryAfter: nil)
        let api = QnapAPI(host: UUID().uuidString + ".invalid", port: 443, useSsl: true, session: session)
        _ = await api.login(account: "qa", password: "fixture")
        do { _ = try await api.listDirectory(path: "/"); XCTFail("Expected rejected session") }
        catch SourceError.authenticationFailed { }
        let loggedIn = await api.isLoggedIn
        XCTAssertFalse(loggedIn)
        XCTAssertEqual(MediaQuotaURLProtocol.requests, 1)
    }

    func testFnMusicForbiddenRetainsAuthenticationClassification() async throws {
        let session = quotaSession()
        defer { session.invalidateAndCancel() }
        MediaQuotaURLProtocol.reset(status: 403, retryAfter: nil)
        let api = FnMusicAPI(sourceID: UUID().uuidString, host: UUID().uuidString + ".invalid",
            port: nil, useSSL: true, basePath: nil, connectionMode: .address, accessCode: nil, session: session)
        do { _ = try await api.trackPage(page: 1, size: 1); XCTFail("Expected authentication error") }
        catch SourceError.authenticationFailed { }
    }

    func testMediaServerForbiddenRetainsAuthenticationClassification() async throws {
        MediaQuotaURLProtocol.reset(status: 403, retryAfter: nil)
        let source = MediaServerSource(sourceID: UUID().uuidString, kind: .jellyfin,
            host: UUID().uuidString + ".invalid", port: nil, useSsl: true, basePath: nil,
            username: "qa", secret: "fixture", authType: .apiKey, requestDataLoader: { MediaQuotaURLProtocol.reply(to: $0) })
        do { try await source.connect(); XCTFail("Expected authentication error") }
        catch SourceError.authenticationFailed { }
    }

    private func quotaSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaQuotaURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func assertQuota(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected HTTP failure") }
        catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 429)
            XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590)
        } catch { XCTFail("HTTP quota was lost: \(error)") }
    }

    func testSubsonicMountsShareCompleteServerCooldown() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaQuotaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MediaQuotaURLProtocol.reset(status: 429)
        for _ in 0..<2 {
            let source = SubsonicSource(sourceID: UUID().uuidString, sourceType: .navidrome,
                host: host, port: nil, useSsl: true, basePath: nil,
                username: "quota-user", password: "fixture", session: session)
            do { try await source.connect(); XCTFail("Expected rate-limit failure") }
            catch let error as HTTPResponseFailure {
                XCTAssertEqual(error.statusCode, 429)
                XCTAssertGreaterThan(try XCTUnwrap(error.retryAfter), 3590)
            } catch { XCTFail("Expected complete HTTP failure, got \(error)") }
        }
        XCTAssertEqual(MediaQuotaURLProtocol.requests, 1, "Another mount must not bypass the account cooldown")
    }
}

private final class MediaQuotaURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 429
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var retryAfter: String? = "3600"
    static var requests: Int { lock.withLock { count } }
    static func reset(status: Int, retryAfter: String? = "3600") { lock.withLock { self.status = status; self.retryAfter = retryAfter; count = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func reply(to request: URLRequest) -> (Data, URLResponse) {
        let path = request.url!.path
        let loginBody: String?
        switch path {
        case "/webapi/auth.cgi": loginBody = #"{"success":true,"data":{"sid":"fixture"}}"#
        case "/cgi-bin/authLogin.cgi": loginBody = #"{"authPassed":1,"authSid":"fixture"}"#
        case "/ugreen/v1/verify/login": loginBody = #"{"code":200,"data":{"token":"fixture"}}"#
        case "/ugreen/v1/verify/check": loginBody = "{}"
        default: loginBody = nil
        }
        if let loginBody {
            return (Data(loginBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
        }
        let status = lock.withLock { count += 1; return self.status }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: retryAfter.map { ["Retry-After": $0] } ?? [:])!
        return (Data("{\"error\":\"limited\"}".utf8), response)
    }
    override func startLoading() {
        let (data, response) = Self.reply(to: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class MediaCompatibilityFixture: @unchecked Sendable {
    let host = UUID().uuidString.lowercased() + ".invalid"
    let status: Int
    let retryAfter: String?
    let publicKey: String
    private let lock = NSLock()
    private var captured: [String] = []
    var paths: [String] { lock.withLock { captured } }
    init(status: Int, retryAfter: String? = nil) throws {
        self.status = status; self.retryAfter = retryAfter
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        self.publicKey = (try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data).base64EncodedString()
    }
    func session() -> URLSession {
        MediaCompatibilityProtocol.fixture = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaCompatibilityProtocol.self]
        return URLSession(configuration: config)
    }
    func reply(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        lock.withLock { captured.append(path) }
        let body: [String: Any]
        var status = 200
        var headers: [String: String] = [:]
        switch path {
        case "/ugreen/v1/verify/check": body = [:]
        case "/ugreen/v1/verify/login": body = ["code": 200, "data": ["token": "fixture", "token_id": "fixture", "public_key": publicKey]]
        case "/ugreen/v2/filemgr/getDirFileListV2":
            status = self.status; headers["Retry-After"] = retryAfter; body = [:]
        default: body = ["code": 200, "data": ["list": [["name": "track.flac", "path": "/music/track.flac", "is_dir": false, "size": 123]]]]
        }
        return (try! JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private final class MediaCompatibilityProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: MediaCompatibilityFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture else { return }
        let (data, response) = fixture.reply(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
