import Foundation
import XCTest
import PrimuseKit
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class PodcastRequestQuotaTests: XCTestCase {
    func testEnclosureRecoversOnceFromTransientNetworkFailure() async throws {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet] {
            let fixture = PodcastRequestFixture(status: 206,
                headers: ["Content-Range": "bytes 0-1/999", "Content-Length": "2"], body: Data([1, 2]),
                transportError: URLError(code), transportFailureCount: 1)
            let probe = await PodcastNetwork.probeEnclosure(fixture.url(), session: fixture.session)
            XCTAssertEqual(probe?.totalLength, 999)
            XCTAssertEqual(fixture.requests.count, 2)
            XCTAssertTrue(fixture.requests.allSatisfy { $0.timeoutInterval <= 4 })
        }
    }

    func testEnclosureRetryIsBoundedAndDoesNotReplayCancellationOrPermanentFailure() async {
        for (code, expected) in [(URLError.Code.timedOut, 2), (.cancelled, 1), (.secureConnectionFailed, 1)] {
            let fixture = PodcastRequestFixture(status: 0, transportError: URLError(code))
            let probe = await PodcastNetwork.probeEnclosure(fixture.url(), session: fixture.session)
            XCTAssertNil(probe)
            XCTAssertEqual(fixture.requests.count, expected)
        }
    }

    func testFeedsOnTheSameEndpointShareLongCooldown() async throws {
        for status in [429, 503] {
            let fixture = PodcastRequestFixture(status: status, headers: ["Retry-After": "3600"])
            for path in ["/first.xml", "/second.xml"] {
                do {
                    _ = try await PodcastNetwork.fetchFeed(fixture.url(path), session: fixture.session)
                    XCTFail("A throttled feed must not become successful content")
                } catch { }
            }
            XCTAssertEqual(fixture.requests.count, 1, "Other feeds must respect the endpoint's cooldown")
        }
    }

    func testEpisodeAssetsAndDirectoryShareDateCooldownWithFeeds() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for entry in ["directory", "chapters", "transcript", "enclosure"] {
            let fixture = PodcastRequestFixture(status: 503, headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(3600))])
            switch entry {
            case "directory": _ = try? await PodcastNetwork.json(from: fixture.url(), session: fixture.session)
            case "chapters": let result = await PodcastNetwork.chapters(from: fixture.url(), session: fixture.session); XCTAssertTrue(result.isEmpty)
            case "transcript": let result = await PodcastNetwork.transcript(from: fixture.url(), session: fixture.session); XCTAssertNil(result)
            default: let result = await PodcastNetwork.probeEnclosure(fixture.url(), session: fixture.session); XCTAssertNil(result)
            }
            do {
                _ = try await PodcastNetwork.fetchFeed(fixture.url("/another.xml"), session: fixture.session)
                XCTFail("An asset's quota applies to feeds on the same endpoint")
            } catch PodcastNetwork.Failure.httpStatus(let status, let retryAfter) {
                XCTAssertEqual(status, 503)
                XCTAssertGreaterThan(retryAfter ?? 0, 3590)
            } catch { XCTFail("Lost server deadline: \(error)") }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testConditional304AndSuccessfulFeedMetadataArePreserved() async throws {
        let unchanged = PodcastRequestFixture(status: 304)
        let result = try await PodcastNetwork.fetchFeed(unchanged.url(), etag: "tag-v1", lastModified: "Wed, 01 Jul 2026 00:00:00 GMT", session: unchanged.session)
        guard case .notModified = result else { return XCTFail("304 must keep the cached feed") }
        XCTAssertEqual(unchanged.requests.first?.value(forHTTPHeaderField: "If-None-Match"), "tag-v1")
        XCTAssertEqual(unchanged.requests.first?.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 01 Jul 2026 00:00:00 GMT")
        let fresh = PodcastRequestFixture(status: 200, headers: ["ETag": "tag-v2", "Last-Modified": "Thu, 02 Jul 2026 00:00:00 GMT"], body: Data("<rss/>".utf8))
        guard case .fetched(let data, let url, let etag, let modified) = try await PodcastNetwork.fetchFeed(fresh.url(), session: fresh.session) else {
            return XCTFail("A successful feed returns its content and validators")
        }
        XCTAssertEqual(data, Data("<rss/>".utf8)); XCTAssertEqual(url, fresh.url())
        XCTAssertEqual(etag, "tag-v2"); XCTAssertEqual(modified, "Thu, 02 Jul 2026 00:00:00 GMT")
    }

    func testPermanentFailureDoesNotRetryOrCacheEmptyTranscript() async throws {
        let missing = PodcastRequestFixture(status: 404)
        let absent = await PodcastNetwork.transcript(from: missing.url(), session: missing.session)
        XCTAssertNil(absent); XCTAssertEqual(missing.requests.count, 1)
        let valid = PodcastRequestFixture(status: 200, body: Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhello\n".utf8), host: missing.host)
        let transcript = await PodcastNetwork.transcript(from: valid.url(), session: valid.session)
        XCTAssertTrue(transcript?.contains("hello") == true)
        XCTAssertEqual(valid.requests.count, 1)
    }

    func testHTTPSProbeQuotaDoesNotFallBackToInsecureHTTP() async throws {
        let fixture = PodcastRequestFixture(status: 429, headers: ["Retry-After": "3600"])
        let plain = URL(string: "http://\(fixture.host)/feed.xml")!
        for _ in 0..<2 {
            do { _ = try await PodcastNetwork.reachableURL(for: plain, session: fixture.session); XCTFail("Expected quota failure") }
            catch PodcastNetwork.Failure.httpStatus(let status, let delay) {
                XCTAssertEqual(status, 429); XCTAssertGreaterThan(delay ?? 0, 3590)
            } catch { XCTFail("Quota must not become a trust prompt: \(error)") }
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.httpMethod, "HEAD")
        XCTAssertEqual(fixture.requests.first?.url?.scheme, "https")
    }

    func testFailedTLSProbeStillRequiresExplicitHTTPTrust() async throws {
        let fixture = PodcastRequestFixture(status: 0, transportError: URLError(.secureConnectionFailed))
        do {
            _ = try await PodcastNetwork.reachableURL(for: URL(string: "http://\(fixture.host)/feed")!, session: fixture.session)
            XCTFail("Untrusted public HTTP must not be returned")
        } catch PodcastNetwork.Failure.insecureHTTP { }
        catch { XCTFail("Unexpected trust result: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.url?.scheme == "https" })
    }

    /// 只开 http 的主机 443 直接拒连: 探测只试一次就回落, 不重试拖慢起播。
    func testRefusedTLSProbeIsNotRetried() async throws {
        let fixture = PodcastRequestFixture(status: 0, transportError: URLError(.cannotConnectToHost))
        do {
            _ = try await PodcastNetwork.reachableURL(for: URL(string: "http://\(fixture.host)/feed")!, session: fixture.session)
            XCTFail("Untrusted public HTTP must not be returned")
        } catch PodcastNetwork.Failure.insecureHTTP { }
        catch { XCTFail("Unexpected trust result: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testResponseLimitAndRangeProbeArePreserved() async throws {
        let oversized = PodcastRequestFixture(status: 200, headers: ["Content-Length": "9"], body: Data(repeating: 0, count: 9))
        do { _ = try await PodcastNetwork.json(from: oversized.url(), maxBytes: 8, session: oversized.session); XCTFail("Body limit must be enforced") }
        catch { XCTAssertEqual(oversized.requests.count, 1) }
        let audio = PodcastRequestFixture(status: 206, headers: ["Content-Range": "bytes 0-1/999", "Content-Length": "2"], body: Data([1, 2]))
        let probe = await PodcastNetwork.probeEnclosure(audio.url(), session: audio.session)
        XCTAssertEqual(probe?.totalLength, 999); XCTAssertEqual(probe?.supportsRange, true)
        XCTAssertEqual(audio.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=0-1")
        XCTAssertEqual(audio.requests.first?.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testCancelledFeedStopsWithoutReplay() async throws {
        let fixture = PodcastRequestFixture(status: 0)
        let session = fixture.session
        let done = expectation(description: "Feed cancelled promptly")
        let task = Task {
            defer { done.fulfill() }
            do { _ = try await PodcastNetwork.fetchFeed(fixture.url(), session: session); XCTFail("Expected cancellation") }
            catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { XCTFail("Unexpected cancellation: \(error)") }
        }
        for _ in 0..<200 {
            if !fixture.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.requests.count, 1)
        task.cancel()
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(fixture.requests.count, 1)
    }
}

@MainActor
final class PodcastPersistenceTests: XCTestCase {
    private struct Library: Codable { var shows: [PodcastShow]; var removed: [String: Date] }

    func testRepeatedUnchangedFeedsDoNotRewriteLargeEpisodeFile() async throws {
        let fixture = try await makeStore(count: 3_300)
        defer { fixture.clean() }
        let before = try FileManager.default.attributesOfItem(atPath: fixture.episodesURL.path)[.systemFileNumber] as? NSNumber
        for tick in 1...5 {
            let merged = PodcastFeedMerge.refresh(show: fixture.store.subscribedShows[0],
                existing: fixture.store.episodesByShow[fixture.showID] ?? [], feed: fixture.feed,
                now: Date(timeIntervalSince1970: 1_800_000_000 + Double(tick)))
            fixture.store.apply(merged, etag: nil, lastModified: nil, upgradedURL: fixture.url)
            fixture.store.flush()
            await fixture.store.persistenceTask?.value
        }
        let after = try FileManager.default.attributesOfItem(atPath: fixture.episodesURL.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(before, after, "Unchanged 3,300-episode feeds must not replace the episode file")
        XCTAssertEqual(fixture.store.episodesByShow[fixture.showID]?.count, 3_300)
    }

    func testConsecutiveSavesKeepLatestEpisodeAndShowSnapshot() async throws {
        let fixture = try await makeStore(count: 10)
        defer { fixture.clean() }
        for tick in 1...8 {
            var feed = fixture.feed
            feed.title = "Show \(tick)"
            feed.items[0].title = "Episode \(tick)"
            let merged = PodcastFeedMerge.refresh(show: fixture.store.subscribedShows[0],
                existing: fixture.store.episodesByShow[fixture.showID] ?? [], feed: feed, now: Date())
            fixture.store.apply(merged, etag: nil, lastModified: nil, upgradedURL: fixture.url)
            fixture.store.flush()
        }
        await fixture.store.persistenceTask?.value
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let episodes = try decoder.decode([PodcastEpisode].self, from: Data(contentsOf: fixture.episodesURL))
        let library = try decoder.decode(Library.self, from: Data(contentsOf: fixture.directory.appendingPathComponent("shows.json")))
        XCTAssertEqual(episodes.first?.title, "Episode 8")
        XCTAssertEqual(library.shows.first?.title, "Show 8")
    }

    func testFailedWriteRemainsDirtyForNextFlush() async throws {
        let fixture = try await makeStore(count: 2)
        defer { fixture.clean() }
        let episodesDirectory = fixture.episodesURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: episodesDirectory)
        try Data("blocked".utf8).write(to: episodesDirectory)
        var feed = fixture.feed
        feed.items[0].title = "Retained after write failure"
        let merged = PodcastFeedMerge.refresh(show: fixture.store.subscribedShows[0],
            existing: fixture.store.episodesByShow[fixture.showID] ?? [], feed: feed, now: Date())
        fixture.store.apply(merged, etag: nil, lastModified: nil, upgradedURL: fixture.url)
        fixture.store.flush()
        await fixture.store.persistenceTask?.value
        try FileManager.default.removeItem(at: episodesDirectory)
        fixture.store.flush()
        await fixture.store.persistenceTask?.value
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let saved = try decoder.decode([PodcastEpisode].self, from: Data(contentsOf: fixture.episodesURL))
        XCTAssertEqual(saved.first?.title, "Retained after write failure")
    }

    func testUnsubscribeIsNotUndoneByAnEarlierPendingSave() async throws {
        let fixture = try await makeStore(count: 3_300)
        defer { fixture.clean() }
        var feed = fixture.feed
        feed.items[0].title = "Pending save"
        let merged = PodcastFeedMerge.refresh(show: fixture.store.subscribedShows[0],
            existing: fixture.store.episodesByShow[fixture.showID] ?? [], feed: feed, now: Date())
        fixture.store.apply(merged, etag: nil, lastModified: nil, upgradedURL: fixture.url)
        fixture.store.flush()
        fixture.store.unsubscribe(fixture.showID)
        fixture.store.flush()
        await fixture.store.persistenceTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.episodesURL.path))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let saved = try decoder.decode(Library.self, from: Data(contentsOf: fixture.directory.appendingPathComponent("shows.json")))
        XCTAssertTrue(saved.shows.isEmpty)
        XCTAssertNotNil(saved.removed[fixture.showID])
    }

    private struct StoreFixture {
        let store: PodcastStore
        let directory: URL
        let episodesURL: URL
        let feed: PodcastFeed
        let url: URL
        let showID: String
        let suite: String
        func clean() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    private func makeStore(count: Int) async throws -> StoreFixture {
        let suite = "podcast-persistence-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = URL(string: "https://\(suite).invalid/feed.xml")!
        let feed = PodcastFeed(title: "Show", items: (0..<count).map {
            PodcastFeedItem(guid: "episode-\($0)", title: "Episode \($0)",
                showNotes: String(repeating: "notes ", count: 200), enclosureURL: url.appendingPathComponent("\($0).m4a"))
        })
        let original = PodcastFeedMerge.subscribe(feed: feed, feedURL: url, now: Date(timeIntervalSince1970: 1_800_000_000))
        let episodeDirectory = directory.appendingPathComponent("Episodes")
        try FileManager.default.createDirectory(at: episodeDirectory, withIntermediateDirectories: true)
        let episodesURL = episodeDirectory.appendingPathComponent(PodcastIdentity.digest(original.show.id) + ".json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(Library(shows: [original.show], removed: [:])).write(to: directory.appendingPathComponent("shows.json"))
        try encoder.encode(original.episodes).write(to: episodesURL)
        let store = PodcastStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), directory: directory)
        store.loadIfNeeded()
        for _ in 0..<500 where !store.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.isLoaded)
        return StoreFixture(store: store, directory: directory, episodesURL: episodesURL,
            feed: feed, url: url, showID: original.show.id, suite: suite)
    }
}

#if os(iOS)
@MainActor
final class PodcastStartupRecoveryTests: XCTestCase {
    func testRecoveryHonorsPauseSwitchAndInterruptionDuringProbe() async throws {
        try await withPlayer { player in
            for change in ["pause", "switch", "generation", "interruption"] {
                let song = self.prepareFailure(player, url: URL(string: "https://fixture.invalid/episode.wav")!)
                let consumed = await player.retryPodcastRangeAfterStartupFailure { url in
                    switch change {
                    case "pause": player.interruptionResumePolicy.registerPauseOrStopIntent()
                    case "switch": player.currentSong = nil
                    case "generation": player.playID = UUID()
                    default: player.interruptionResumePolicy.interruptionBegan(wasActuallyPlaying: true, currentItemID: song.id)
                    }
                    return .init(finalURL: url, totalLength: 1234, supportsRange: true, probedAt: Date())
                }
                XCTAssertTrue(consumed, change)
                XCTAssertFalse(player.isPlaying, change)
                XCTAssertNil(PodcastEnclosureProbeCache.shared.probe(forEpisodeID: song.id), change)
            }
            let song = self.prepareFailure(player, url: URL(string: "https://fixture.invalid/interrupted.wav")!)
            player.interruptionResumePolicy.interruptionBegan(wasActuallyPlaying: true, currentItemID: song.id)
            let consumed = await player.retryPodcastRangeAfterStartupFailure { _ in
                XCTFail("An active interruption must not start a recovery request")
                return nil
            }
            XCTAssertTrue(consumed)
        }
    }

    func testRecoveredRangeStartsCurrentEpisodeWithoutAdvancingQueue() async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_PODCAST_RECOVERY_MUSIC"] == "1" else {
            throw XCTSkip("Requires the ordinary music fixture copied to this test device")
        }
        let music = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaybackValidation/podcast-recovery-119.m4a")
        defer { try? FileManager.default.removeItem(at: music) }
        let payload = try Data(contentsOf: music)
        let server = try PodcastVideoHTTPFixture(payload: payload, contentType: "audio/mp4")
        let port = try await server.start()
        defer { server.stop() }
        try await withPlayer { player in
            let song = self.prepareFailure(player, url: URL(string: "http://127.0.0.1:\(port)/episode.m4a")!)
            let failedPlayID = player.playID
            let suppressed = PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID
            PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID = song.id
            defer {
                PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID = suppressed
                PodcastEnclosureProbeCache.shared.invalidate(episodeID: song.id)
            }
            await player.autoAdvanceAfterFailure(trigger: "playWithFallbackDecoder(song:url:outputFormat:playID:shouldRecordPlaybackStart:)")
            let deadline = Date().addingTimeInterval(15)
            while !(player.audioEngine.isActuallyPlaying && player.currentTime > 1), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(player.currentSong?.id, song.id)
            XCTAssertEqual(player.currentSong?.fileSize, Int64(payload.count))
            XCTAssertEqual(player.queueEntries.count, 2)
            XCTAssertNotEqual(player.playID, failedPlayID)
            XCTAssertTrue(player.audioEngine.isActuallyPlaying)
            XCTAssertGreaterThan(player.currentTime, 1)
            XCTAssertEqual(player.activeDecoderKind, .httpStream)
            let repeated = await player.retryPodcastRangeAfterStartupFailure { _ in
                XCTFail("A recovered known-size episode must not retry again")
                return nil
            }
            XCTAssertFalse(repeated)
            player.currentSong = nil
        }
    }

    private func prepareFailure(_ player: AudioPlayerService, url: URL) -> Song {
        let song = Song(id: UUID().uuidString, title: "Podcast recovery fixture", duration: 15,
            fileFormat: .m4a, filePath: url.absoluteString, sourceID: PodcastPlaybackSong.sourceID, fileSize: 0)
        var next = song
        next.id = UUID().uuidString
        player.setQueue([song, next])
        player.currentSong = song
        player.isPlaying = false
        player.playID = UUID()
        player.interruptionResumePolicy.registerPlayIntent()
        player.beginAutomaticAdvanceTransport(itemID: song.id, reason: "test-startup-failure")
        return song
    }

    private func withPlayer(_ body: (AudioPlayerService) async throws -> Void) async throws {
        _ = AppServices.shared
        await Task.yield()
        let session = AudioSessionManager.shared
        let began = session.onInterruptionBegan, ended = session.onInterruptionEnded
        let configuration = session.onConfigurationChange
        let history = PlayHistoryStore.shared.isRecordingSuspended
        let scrobble = ScrobbleService.shared.isSuspended
        let modes = ListeningPlayModeStore.shared.ledger
        PlayHistoryStore.shared.isRecordingSuspended = true
        ScrobbleService.shared.isSuspended = true
        let suite = "PodcastRecoveryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.prewarmQueueCount = 0
        settings.skipLeadingSilenceEnabled = false
        settings.skipTrailingSilenceEnabled = false
        settings.gaplessEnabled = false
        settings.crossfadeEnabled = false
        settings.audioCacheEnabled = false
        let sources = SourceManager(sourcesProvider: { [] })
        let player = AudioPlayerService(sourceManager: sources, playbackSettings: settings,
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        defer {
            let songs = player.queueEntries.map(\.song)
            player.currentSong = nil
            player.stop()
            player.playbackSessionPersistence.drain()
            for song in songs { sources.deleteAudioCache(for: song) }
            session.onInterruptionBegan = began
            session.onInterruptionEnded = ended
            session.onConfigurationChange = configuration
            PlayHistoryStore.shared.isRecordingSuspended = history
            ScrobbleService.shared.isSuspended = scrobble
            ListeningPlayModeStore.shared.update { $0 = modes }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        player.audioEngine.setVolume(0, persist: false)
        player.shuffleEnabled = false
        player.repeatMode = .off
        try await body(player)
    }
}
#endif

private final class PodcastRequestFixture: @unchecked Sendable {
    let host: String
    let status: Int
    let headers: [String: String]
    let body: Data
    let transportError: URLError?
    let transportFailureCount: Int?
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    lazy var session: URLSession = {
        PodcastRequestProtocol.register(self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastRequestProtocol.self]
        return URLSession(configuration: config)
    }()
    init(status: Int, headers: [String: String] = [:], body: Data = Data(), host: String = UUID().uuidString.lowercased() + ".invalid", transportError: URLError? = nil, transportFailureCount: Int? = nil) {
        self.status = status; self.headers = headers; self.body = body
        self.host = host; self.transportError = transportError
        self.transportFailureCount = transportFailureCount
    }
    func url(_ path: String = "/feed.xml") -> URL { URL(string: "https://\(host)\(path)")! }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
}

private final class PodcastRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: PodcastRequestFixture] = [:]
    static func register(_ fixture: PodcastRequestFixture) { lock.withLock { fixtures[fixture.host] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        fixture.record(request)
        if let error = fixture.transportError,
           fixture.requests.count <= (fixture.transportFailureCount ?? Int.max) {
            client?.urlProtocol(self, didFailWithError: error); return
        }
        if fixture.status == 0 { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: nil, headerFields: fixture.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
