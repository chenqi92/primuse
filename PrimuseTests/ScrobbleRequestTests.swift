import Foundation
import PrimuseKit
import XCTest
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class ScrobbleRequestTests: XCTestCase, @unchecked Sendable {
    func testUnauthorizedSubmissionWithUnavailableValidationKeepsRetryableCooldown() async throws {
        let suite = "scrobble-unknown-validation-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let fixture = ScrobbleHTTPFixture(status: 401)
        let requests = ScrobbleRequests(registry: RequestQuotaRegistry(), cooldowns: ScrobbleCooldownStore(suiteName: suite))
        let provider = ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session(), requests: requests)
        do { try await provider.submitListens([Self.entry]); XCTFail("Expected deferred retry") }
        catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 401)
            XCTAssertEqual(failure.isRetryable, true)
            XCTAssertGreaterThan(failure.retryAfter ?? 0, 290)
        }
        XCTAssertEqual(fixture.count, 2)
    }

    func testFreshlyValidTokenWithUnauthorizedSubmissionIsDeferredAcrossRestart() async throws {
        let suite = "scrobble-valid-unauthorized-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let fixture = ScrobbleHTTPFixture(status: 401, validationBody: #"{"valid":true,"code":200}"#)
        let session = fixture.session()
        let token = UUID().uuidString
        for _ in 0..<2 {
            let requests = ScrobbleRequests(registry: RequestQuotaRegistry(), cooldowns: ScrobbleCooldownStore(suiteName: suite))
            let provider = ListenBrainzProvider(userToken: token, session: session, requests: requests)
            do { try await provider.submitListens([Self.entry]); XCTFail("Expected a deferred submission") }
            catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 401)
                XCTAssertGreaterThan(failure.retryAfter ?? 0, 290)
            }
        }
        XCTAssertEqual(fixture.count, 2, "One write and one fresh validation, no immediate replay or restart bypass")
    }

    func testListenBrainzForbiddenResponsesRemainRetryableAndShareCooldown() async throws {
        for body in [#"{"error":"Forbidden"}"#, "<html>Access denied</html>"] {
            for retryAfter in [nil, "3600"] as [String?] {
                let suite = "scrobble-forbidden-" + UUID().uuidString
                defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
                let fixture = ScrobbleHTTPFixture(status: 403,
                    headers: retryAfter.map { ["Retry-After": $0] } ?? [:], body: body)
                let session = fixture.session()
                let token = UUID().uuidString
                for _ in 0..<2 {
                    let requests = ScrobbleRequests(registry: RequestQuotaRegistry(), cooldowns: ScrobbleCooldownStore(suiteName: suite))
                    let provider = ListenBrainzProvider(userToken: token, session: session, requests: requests)
                    do {
                        try await provider.submitListens([Self.entry])
                        XCTFail("Expected a retryable forbidden response")
                    } catch let failure as HTTPResponseFailure {
                        XCTAssertEqual(failure.statusCode, 403)
                        XCTAssertGreaterThan(failure.retryAfter ?? 0, retryAfter == nil ? 50 : 3590)
                    } catch { XCTFail("Forbidden response incorrectly rejected the token: \(error)") }
                    do {
                        try await provider.sendNowPlaying(Self.entry)
                        XCTFail("Now Playing bypassed the shared cooldown")
                    } catch is HTTPResponseFailure {}
                    let valid = await provider.validateCredentials()
                    XCTAssertNil(valid, "A blocked request does not prove that the token is invalid")
                }
                XCTAssertEqual(fixture.count, 1, "Restart and Now Playing must honor the cooldown")
            }
        }
    }

    @MainActor
    func testValidListenBrainzTokenWithForbiddenSubmissionKeepsDurableQueue() async throws {
        let suite = "scrobble-valid-forbidden-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ScrobbleSettingsStore.shared
        let wasEnabled = settings.isEnabled
        settings.isEnabled = false
        defer { settings.isEnabled = wasEnabled }
        let fixture = ScrobbleHTTPFixture(status: 200, body: #"{"valid":true,"code":200}"#)
        let requests = ScrobbleRequests(registry: RequestQuotaRegistry(), cooldowns: ScrobbleCooldownStore(suiteName: suite))
        let provider = ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session(), requests: requests)
        let valid = await provider.validateCredentials()
        XCTAssertEqual(valid, true)
        fixture.setResponse(status: 403, headers: ["Content-Type": "text/html"], body: "<html>Access denied</html>")
        let service = ScrobbleService(defaults: defaults, providers: { [provider] })
        let before = Date().timeIntervalSince1970
        service.handlePlaybackStarted(song: Song(id: "forbidden", title: "Track", albumTitle: "Album", artistName: "Artist",
            duration: 60, fileFormat: .flac, filePath: "/fixture.flac", sourceID: "fixture"))
        service.handleProgressTick(playedDelta: 30)
        for _ in 0..<1_000 where queueDeadline(defaults, key: "serverRetryAt") < before + 50 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertTrue(service.rejectedCredentials.isEmpty)
        XCTAssertGreaterThanOrEqual(queueDeadline(defaults, key: "serverRetryAt"), before + 50)
        let reopened = ScrobbleService(defaults: defaults, providers: { [provider] })
        reopened.retryPendingNow()
        XCTAssertEqual(reopened.pendingCount, 1)
        XCTAssertTrue(reopened.rejectedCredentials.isEmpty)
        XCTAssertGreaterThanOrEqual(queueDeadline(defaults), before + 50)
        XCTAssertEqual(fixture.count, 2)
    }

    func testSubmissionCooldownAlsoBlocksNowPlaying() async throws {
        for lastFM in [false, true] {
            let fixture = ScrobbleHTTPFixture(status: 429, headers: ["Retry-After": "3600"])
            let session = fixture.session()
            let key = UUID().uuidString
            let provider: any ScrobbleProvider = lastFM
                ? LastFmProvider(apiKey: key, apiSecret: "secret", sessionKey: "session", session: session)
                : ListenBrainzProvider(userToken: key, session: session)
            for submit in [true, false] {
                do {
                    if submit { try await provider.submitListens([Self.entry]) }
                    else { try await provider.sendNowPlaying(Self.entry) }
                    XCTFail("Expected complete server cooldown")
                } catch let failure as HTTPResponseFailure {
                    XCTAssertEqual(failure.statusCode, 429)
                    XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590)
                } catch { XCTFail("Lost structured cooldown: \(error)") }
            }
            XCTAssertEqual(fixture.count, 1, "Now Playing may not spend a separate quota")
        }
    }
    func testLongDateCooldownSurvivesNewStoreAndRegistry() async throws {
        let suite = "scrobble-cooldown-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let fixture = ScrobbleHTTPFixture(status: 503, headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(86400))])
        let session = fixture.session()
        for _ in 0..<2 {
            let requests = ScrobbleRequests(registry: RequestQuotaRegistry(), cooldowns: ScrobbleCooldownStore(suiteName: suite))
            let provider = ListenBrainzProvider(userToken: "private-fixture-token", session: session, requests: requests)
            do { try await provider.sendNowPlaying(Self.entry); XCTFail("Expected persisted cooldown") }
            catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 86390) }
        }
        XCTAssertEqual(fixture.count, 1)
        let data = try XCTUnwrap(UserDefaults(suiteName: suite)?.data(forKey: "primuse.scrobble.serverCooldowns.v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-fixture-token"))
    }

    func testPersistedCooldownIsBoundedAgainstHugeDelaysAndClockRollback() async throws {
        let suite = "scrobble-cooldown-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let limit = ScrobbleCooldownStore.maximumDelay
        let fixture = ScrobbleHTTPFixture(status: 429, headers: ["Retry-After": "2592000"])
        let requests = ScrobbleRequests(registry: RequestQuotaRegistry(), cooldowns: ScrobbleCooldownStore(suiteName: suite))
        do {
            try await ListenBrainzProvider(userToken: "fixture", session: fixture.session(), requests: requests)
                .sendNowPlaying(Self.entry)
            XCTFail("Expected the server cooldown")
        } catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.retryAfter, limit) }

        let key = "bounded-fixture"
        let start: TimeInterval = 1_800_000_000
        await ScrobbleCooldownStore(suiteName: suite, now: { start }).record(key, status: 429, delay: 30 * 86_400)
        // Recorded, then the system clock went back ten days: still at most one bound away.
        let rolledBack = start - 10 * 86_400
        do { try await ScrobbleCooldownStore(suiteName: suite, now: { rolledBack }).check(key); XCTFail("Expected cooldown") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.retryAfter, limit) }
        try await ScrobbleCooldownStore(suiteName: suite, now: { rolledBack + limit }).check(key)
    }

    func testLastFMOperationFailedIsQueuedForRetry() async throws {
        let fixture = ScrobbleHTTPFixture(status: 200, body: #"{"error":8,"message":"Operation failed"}"#)
        let provider = LastFmProvider(apiKey: UUID().uuidString, apiSecret: "fixture", sessionKey: "fixture",
            session: fixture.session(), requests: ScrobbleRequests(registry: RequestQuotaRegistry()))
        do { try await provider.submitListens([Self.entry]); XCTFail("Expected a retryable failure") }
        catch let error as ScrobbleError { XCTFail("Error 8 was dropped as \(error)") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.isRetryable, true) }
        XCTAssertEqual(fixture.count, 1)
    }

    func testIndependentAccountsAndEndpointsCanSubmitDuringAnotherCooldown() async throws {
        let fixture = ScrobbleHTTPFixture(status: 429, headers: ["Retry-After": "3600"])
        let session = fixture.session()
        let registry = RequestQuotaRegistry()
        let suite = "scrobble-isolation-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let requests = ScrobbleRequests(registry: registry, cooldowns: ScrobbleCooldownStore(suiteName: suite))
        let first = ListenBrainzProvider(userToken: "reader-a", session: session, requests: requests)
        do { try await first.submitListens([Self.entry]); XCTFail("Expected quota") } catch is HTTPResponseFailure {}
        fixture.setResponse(status: 200, headers: [:], body: "{}")
        try await ListenBrainzProvider(userToken: "reader-b", session: session, requests: requests).sendNowPlaying(Self.entry)
        try await ListenBrainzProvider(userToken: "reader-a", baseURL: URL(string: "https://independent.invalid")!,
            session: session, requests: requests).sendNowPlaying(Self.entry)
        do { try await first.sendNowPlaying(Self.entry); XCTFail("Original account bypassed quota") } catch is HTTPResponseFailure {}
        XCTAssertEqual(fixture.count, 3)
    }

    func testLastFMBusinessQuotaIsSharedWithDiscoveryAndNewSession() async throws {
        for status in [200, 400] {
            let fixture = ScrobbleHTTPFixture(status: status, body: #"{"error":29,"message":"limited"}"#)
            let session = fixture.session()
            let key = UUID().uuidString
            let registry = RequestQuotaRegistry()
            let requests = ScrobbleRequests(registry: registry)
            for sk in ["old-session", "new-session"] {
                do { try await LastFmProvider(apiKey: key, apiSecret: "fixture", sessionKey: sk, session: session, requests: requests).sendNowPlaying(Self.entry)
                    XCTFail("Business quota must remain a failure")
                } catch let failure as HTTPResponseFailure { XCTAssertTrue(failure.isRateLimitFailure); XCTAssertGreaterThan(failure.retryAfter ?? 0, 25) }
                catch { XCTFail("HTTP \(status) business quota lost: \(String(describing: error))") }
            }
            #if !os(tvOS)
            let discovery = LastFmSimilarAPI(apiKey: { key }, session: session, quotaRegistry: registry)
            do { _ = try await discovery.similarTracks(artist: "Artist", track: "Track"); XCTFail("Discovery bypassed application quota") }
            catch let failure as HTTPResponseFailure { XCTAssertTrue(failure.isRateLimitFailure) }
            #endif
            XCTAssertEqual(fixture.count, 1)
        }
    }

    func testUnknownWriteResultsNeverReplayAtTransportLayer() async throws {
        for code in [URLError.Code.timedOut, .networkConnectionLost] {
            for lastFM in [false, true] {
                let fixture = ScrobbleHTTPFixture(status: 0, error: URLError(code))
                let session = fixture.session()
                let provider: any ScrobbleProvider = lastFM
                    ? LastFmProvider(apiKey: UUID().uuidString, apiSecret: "fixture", sessionKey: "fixture", session: session)
                    : ListenBrainzProvider(userToken: UUID().uuidString, session: session)
                do { try await provider.submitListens([Self.entry]); XCTFail("Expected ambiguous transport failure") }
                catch let error as ScrobbleError { XCTAssertTrue(error.isRetryable, "The durable at-least-once queue still owns recovery") }
                XCTAssertEqual(fixture.count, 1)
            }
        }
    }

    func testCancellationStopsHeldTransportAndDoesNotReplay() async throws {
        let fixture = ScrobbleHTTPFixture(status: 200, hold: true)
        let started = expectation(description: "submission started")
        let stopped = expectation(description: "submission stopped")
        fixture.started = started; fixture.stopped = stopped
        let provider = ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session())
        let pending = Task { try await provider.submitListens([Self.entry]) }
        defer { pending.cancel() }
        await fulfillment(of: [started], timeout: 5)
        pending.cancel()
        do { try await pending.value; XCTFail("Cancellation lost") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(fixture.count, 1)
    }

    @MainActor
    func testServerDeadlineSurvivesQueuePersistenceAndManualRetry() async throws {
        let suite = "scrobble-queue-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ScrobbleSettingsStore.shared
        let wasEnabled = settings.isEnabled
        settings.isEnabled = false // Hold the automatic scheduler while observing the durable contract.
        defer { settings.isEnabled = wasEnabled }
        let fixture = ScrobbleHTTPFixture(status: 503, headers: ["Retry-After": "3600"])
        let provider = ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session())
        let service = ScrobbleService(defaults: defaults, providers: { [provider] })
        let before = Date().timeIntervalSince1970
        let song = Song(id: UUID().uuidString, title: "Queue fixture", albumTitle: "Album", artistName: "Artist",
            duration: 60, fileFormat: .flac, filePath: "/fixture.flac", sourceID: "fixture")
        service.handlePlaybackStarted(song: song)
        service.handleProgressTick(playedDelta: 30)
        // Up to ten seconds: the first submission runs on a busy build host's executor too.
        for _ in 0..<1_000 {
            if queueDeadline(defaults) >= before + 3590 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertGreaterThanOrEqual(queueDeadline(defaults), before + 3590)
        service.retryPendingNow()
        let reopened = ScrobbleService(defaults: defaults, providers: { [provider] })
        reopened.retryPendingNow()
        XCTAssertGreaterThanOrEqual(queueDeadline(defaults), before + 3590, "Manual retry or restart cannot shorten server cooldown")
        XCTAssertEqual(fixture.count, 1)
    }

    @MainActor
    func testRejectedTokenHoldsListensUntilANewTokenSendsThem() async throws {
        let suite = "scrobble-rejected-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ScrobbleSettingsStore.shared
        let wasEnabled = settings.isEnabled
        settings.isEnabled = false // Only the explicit retry below may send.
        defer { settings.isEnabled = wasEnabled }
        let fixture = ScrobbleHTTPFixture(status: 401, validationBody: #"{"valid":false,"code":200}"#)
        let requests = ScrobbleRequests(registry: RequestQuotaRegistry(), cooldowns: ScrobbleCooldownStore(suiteName: suite))
        var provider = ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session(), requests: requests)
        let rejectedFingerprint = provider.credentialFingerprint
        let service = ScrobbleService(defaults: defaults, providers: { [provider] })
        func listen(_ id: String) {
            service.handlePlaybackStarted(song: Song(id: id, title: id, albumTitle: "Album", artistName: "Artist",
                duration: 60, fileFormat: .flac, filePath: "/\(id).flac", sourceID: "fixture"))
            service.handleProgressTick(playedDelta: 30)
        }

        listen("first")
        for _ in 0..<1_000 where service.rejectedCredentials[.listenBrainz] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.rejectedCredentials[.listenBrainz], rejectedFingerprint)
        XCTAssertEqual(service.pendingCount, 1, "A rejected token must not drop the listen")
        XCTAssertTrue(service.hasRejectedCredential(for: .listenBrainz))

        listen("second")
        XCTAssertEqual(service.pendingCount, 2)
        XCTAssertEqual(fixture.count, 2, "The rejected token is only rechecked once, then held")

        fixture.setResponse(status: 200, headers: [:], body: "{}")
        provider = ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session(), requests: requests)
        XCTAssertFalse(service.hasRejectedCredential(for: .listenBrainz))
        settings.isEnabled = true
        service.retryPendingNow()
        for _ in 0..<1_000 where service.pendingCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertEqual(fixture.count, 4)
    }
    @MainActor
    func testNonMusicNeverReachesProvidersButKeepsSourcePlaybackFeedback() async throws {
        try await withContentFixture { defaults, store in
            let providers = ScrobbleProviderID.allCases.map { ScrobbleRecordingProvider(id: $0) }
            let service = ScrobbleService(defaults: defaults, providers: { providers },
                                          spokenWordStore: store, songLookup: { _ in nil })
            defer { service.clearQueue() }
            ScrobbleSettingsStore.shared.isEnabled = true
            var serverStarts: [String] = []
            var serverListens: [String] = []
            service.serverScrobbleHandler = { song, submission in
                if submission { serverListens.append(song.id) }
                else { serverStarts.append(song.id) }
            }
            store.setKind(.spokenWord, forSongIDs: ["marked-book"])
            store.setFolderKind(.spokenWord, sourceID: "fixture", path: "/Books")
            let blocked = [
                contentSong("rss", sourceID: PodcastPlaybackSong.sourceID),
                contentSong("audiobook", path: "/chapter.m4b"),
                contentSong("podcast-file", genre: "Podcast"),
                contentSong("lecture", genre: "Lecture"),
                contentSong("marked-book"),
                contentSong("folder-book", path: "/Books/part.mp3"),
                contentSong("server-book", sourceID: "books-server"),
                contentSong("radio", sourceID: RadioStation.playbackSourceID)
            ]
            for song in blocked {
                service.handlePlaybackStarted(song: song)
                service.handleProgressTick(playedDelta: 240)
            }
            var videoPodcast = contentSong("video-podcast", sourceID: PodcastPlaybackSong.sourceID)
            videoPodcast.duration = 0
            videoPodcast.mvPath = "https://fixture.invalid/episode.mp4"
            service.handlePlaybackStarted(song: videoPodcast)
            service.handlePlaybackDurationResolved(songID: videoPodcast.id, duration: 900)
            service.handleProgressTick(playedDelta: 240)

            store.setKind(.music, forSongIDs: ["corrected-music"])
            var videoMusic = contentSong("music-video")
            videoMusic.duration = 0
            videoMusic.mvPath = "https://fixture.invalid/music.mp4"
            let music = [contentSong("long-music"), contentSong("corrected-music", path: "/music.m4b"), videoMusic]
            for song in music {
                service.handlePlaybackStarted(song: song)
                if song.duration == 0 { service.handlePlaybackDurationResolved(songID: song.id, duration: 900) }
                service.handleProgressTick(playedDelta: 239)
                XCTAssertFalse(providers.contains { $0.listens.contains(song.id) })
                service.handleProgressTick(playedDelta: 1)
            }
            for _ in 0..<500 where service.pendingCount > 0 || providers.contains(where: { $0.listens.count < music.count || $0.nowPlaying.count < music.count }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            for provider in providers {
                XCTAssertEqual(Set(provider.nowPlaying), Set(music.map(\.id)))
                XCTAssertEqual(Set(provider.listens), Set(music.map(\.id)))
            }
            XCTAssertEqual(serverStarts.count, blocked.count + 1 + music.count)
            XCTAssertEqual(serverListens, serverStarts)
            XCTAssertEqual(service.pendingCount, 0)
        }
    }

    @MainActor
    func testServerOptOutStopsNowPlayingAndPlayCountIndependentlyOfLastFm() async throws {
        try await withContentFixture { defaults, store in
            let settings = ScrobbleSettingsStore.shared
            let provider = ScrobbleRecordingProvider(id: .lastFm)
            let service = ScrobbleService(defaults: defaults, providers: { [provider] },
                                          spokenWordStore: store, songLookup: { _ in nil })
            var reports = [String]()
            service.serverScrobbleHandler = { song, submission in
                reports.append(song.id + (submission ? ":played" : ":started"))
            }

            settings.isEnabled = true
            service.handlePlaybackStarted(song: contentSong("first"))
            settings.reportPlaybackToServer = false
            service.handleProgressTick(playedDelta: 240)
            service.handlePlaybackStarted(song: contentSong("private"))
            service.handleProgressTick(playedDelta: 240)
            settings.reloadAfterOfflineImport()
            XCTAssertFalse(settings.reportPlaybackToServer)
            for _ in 0..<500 where provider.listens.count < 2 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(Set(provider.listens), ["first", "private"])
            XCTAssertEqual(reports, ["first:started"])

            settings.isEnabled = false
            settings.reportPlaybackToServer = true
            service.handlePlaybackStarted(song: contentSong("resumed"))
            service.handleProgressTick(playedDelta: 240)
            XCTAssertEqual(reports, ["first:started", "resumed:started", "resumed:played"])
        }
    }

    @MainActor
    func testSwitchingToSpokenWordAndReclassificationDoNotSubmitMusicSession() async throws {
        try await withContentFixture { defaults, store in
            let provider = ScrobbleRecordingProvider(id: .lastFm)
            let service = ScrobbleService(defaults: defaults, providers: { [provider] },
                                          spokenWordStore: store, songLookup: { _ in nil })
            defer { service.clearQueue() }
            service.handlePlaybackStarted(song: contentSong("music"))
            service.handleProgressTick(playedDelta: 239)
            service.handlePlaybackStarted(song: contentSong("book", path: "/chapter.m4b"))
            service.handleProgressTick(playedDelta: 240)
            service.handlePlaybackStarted(song: contentSong("reclassified"))
            store.setKind(.podcast, forSongIDs: ["reclassified"])
            service.handleProgressTick(playedDelta: 240)
            service.handlePlaybackStarted(song: contentSong("control"))
            service.handleProgressTick(playedDelta: 240)
            for _ in 0..<500 where provider.listens.isEmpty || service.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(provider.listens, ["control"])
            XCTAssertEqual(service.pendingCount, 0)
        }
    }

    @MainActor
    func testLegacyQueueFiltersKnownNonMusicAndHoldsUnknownUntilLibraryResolves() async throws {
        try await withContentFixture { defaults, store in
            let provider = ScrobbleRecordingProvider(id: .lastFm)
            let podcastID = PodcastIdentity.episodeID(showID: "fixture", guid: "episode")
            store.setKind(.spokenWord, forSongIDs: ["marked-book"])
            var songs = ["music": contentSong("music"), "book": contentSong("book", path: "/chapter.m4b")]
            let ids = ["music", "book", "marked-book", podcastID, RadioStation.playbackSongIDPrefix + "fixture", "unknown"]
            let rows: [[String: Any]] = ids.map { id in
                ["entry": ["songID": id, "title": id, "artist": "Fixture", "startedAt": Int(Date().timeIntervalSince1970)],
                 "pendingProviders": ["lastFm"], "attempts": 0, "nextRetryAt": 0]
            }
            defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "primuse.scrobble.queue.v1")
            let service = ScrobbleService(defaults: defaults, providers: { [provider] },
                                          spokenWordStore: store, songLookup: { songs[$0] })
            defer { service.clearQueue() }
            XCTAssertEqual(service.pendingCount, 2)
            ScrobbleSettingsStore.shared.isEnabled = true
            service.retryPendingNow()
            for _ in 0..<500 where service.pendingCount != 1 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(provider.listens, ["music"])
            XCTAssertEqual(service.pendingCount, 1, "Unknown legacy records remain pending without being sent")

            ScrobbleSettingsStore.shared.isEnabled = false
            let saved = try XCTUnwrap(defaults.data(forKey: "primuse.scrobble.queue.v1"))
            service.clearQueue()
            defaults.set(saved, forKey: "primuse.scrobble.queue.v1")
            songs["unknown"] = contentSong("unknown")
            let reopened = ScrobbleService(defaults: defaults, providers: { [provider] },
                                           spokenWordStore: store, songLookup: { songs[$0] })
            defer { reopened.clearQueue() }
            ScrobbleSettingsStore.shared.isEnabled = true
            reopened.retryPendingNow()
            for _ in 0..<500 where reopened.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(provider.listens, ["music", "unknown"])
            XCTAssertEqual(reopened.pendingCount, 0)
        }
    }

    @MainActor
    func testPersistedContentSupportsRetryWithoutLibraryAndRechecksFolderClassification() async throws {
        try await withContentFixture { defaults, store in
            let initial = ScrobbleRecordingProvider(id: .lastFm)
            let service = ScrobbleService(defaults: defaults, providers: { [initial] },
                                          spokenWordStore: store, songLookup: { _ in nil })
            defer { service.clearQueue() }
            for song in [contentSong("music"), contentSong("later-book", path: "/Books/part.mp3")] {
                service.handlePlaybackStarted(song: song)
                service.handleProgressTick(playedDelta: 240)
            }
            XCTAssertEqual(service.pendingCount, 2)
            let saved = try XCTUnwrap(defaults.data(forKey: "primuse.scrobble.queue.v1"))
            for _ in 0..<500 where service.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(service.pendingCount, 0)
            service.clearQueue()
            defaults.set(saved, forKey: "primuse.scrobble.queue.v1")
            store.setFolderKind(.spokenWord, sourceID: "fixture", path: "/Books")
            let online = ScrobbleRecordingProvider(id: .lastFm)
            let reopened = ScrobbleService(defaults: defaults, providers: { [online] },
                                           spokenWordStore: store, songLookup: { _ in nil })
            defer { reopened.clearQueue() }
            XCTAssertEqual(reopened.pendingCount, 1)
            ScrobbleSettingsStore.shared.isEnabled = true
            reopened.retryPendingNow()
            for _ in 0..<500 where reopened.pendingCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(online.listens, ["music"])
            XCTAssertEqual(reopened.pendingCount, 0)
        }
    }

    @MainActor
    private func withContentFixture(_ body: @MainActor (UserDefaults, SpokenWordStore) async throws -> Void) async throws {
        let suite = "scrobble-content-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SpokenWordStore(storeURL: folder.appendingPathComponent("spoken.json"))
        store.updateFolderTagSources([
            MusicSource(id: "fixture", name: "Fixture", type: .webdav),
            MusicSource(id: "books-server", name: "Books", type: .tingReader)
        ], pruningStaleTags: false)
        let settings = ScrobbleSettingsStore.shared
        let previous = (settings.isEnabled, settings.enabledProviders, settings.sendNowPlaying, settings.reportPlaybackToServer)
        settings.reportPlaybackToServer = true
        settings.isEnabled = false
        settings.enabledProviders = Set(ScrobbleProviderID.allCases)
        settings.sendNowPlaying = true
        defer {
            settings.isEnabled = false
            settings.enabledProviders = previous.1
            settings.reportPlaybackToServer = previous.3
            settings.sendNowPlaying = previous.2
            settings.isEnabled = previous.0
            store.persistLocally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try await body(defaults, store)
    }

    private func contentSong(_ id: String, path: String = "/fixture.flac", genre: String? = nil,
                             sourceID: String = "fixture") -> Song {
        Song(id: id, title: id, artistName: "Fixture", duration: 3600, fileFormat: .flac,
             filePath: path, sourceID: sourceID, genre: genre)
    }

    private func queueDeadline(_ defaults: UserDefaults, key: String = "nextRetryAt") -> TimeInterval {
        guard let data = defaults.data(forKey: "primuse.scrobble.queue.v1"),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return rows.first?[key] as? Double ?? 0
    }

    static let entry = ScrobbleEntry(songID: "fixture", title: "Title + &", artist: "Artist", startedAt: 1_700_000_000)
}

private final class ScrobbleRecordingProvider: ScrobbleProvider, @unchecked Sendable {
    let id: ScrobbleProviderID
    let credentialFingerprint = "content-fixture"
    private let lock = NSLock()
    private var recordedNowPlaying: [String] = []
    private var recordedListens: [String] = []
    var nowPlaying: [String] { lock.withLock { recordedNowPlaying } }
    var listens: [String] { lock.withLock { recordedListens } }

    init(id: ScrobbleProviderID) { self.id = id }
    func validateCredentials() async -> Bool? { true }
    func sendNowPlaying(_ entry: ScrobbleEntry) async throws {
        lock.withLock { recordedNowPlaying.append(entry.songID) }
    }
    func submitListens(_ entries: [ScrobbleEntry]) async throws {
        lock.withLock { recordedListens.append(contentsOf: entries.map(\.songID)) }
    }
}

private final class ScrobbleHTTPFixture: @unchecked Sendable {
    private var status: Int
    private var headers: [String: String]
    private var body: Data
    let error: URLError?
    let hold: Bool
    let validationBody: String?
    var started: XCTestExpectation?
    var stopped: XCTestExpectation?
    private let lock = NSLock()
    private var requests = 0
    var count: Int { lock.withLock { requests } }
    init(status: Int, headers: [String: String] = [:], body: String = "{}", error: URLError? = nil, hold: Bool = false, validationBody: String? = nil) {
        self.status = status; self.headers = headers; self.body = Data(body.utf8); self.error = error; self.hold = hold
        self.validationBody = validationBody
    }
    func setResponse(status: Int, headers: [String: String], body: String) {
        lock.withLock { self.status = status; self.headers = headers; self.body = Data(body.utf8) }
    }
    func reply(for request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            requests += 1
            if request.url?.path.hasSuffix("validate-token") == true, let validationBody {
                return (200, [:], Data(validationBody.utf8))
            }
            return (status, headers, body)
        }
    }
    func session() -> URLSession {
        ScrobbleHTTPProtocol.lock.withLock { ScrobbleHTTPProtocol.fixture = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScrobbleHTTPProtocol.self]
        return URLSession(configuration: config)
    }
}
private final class ScrobbleHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixture: ScrobbleHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixture! }
        let (status, headers, body) = fixture.reply(for: request)
        fixture.started?.fulfill()
        if fixture.hold { return }
        if let error = fixture.error { client?.urlProtocol(self, didFailWithError: error); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.fixture }?.stopped?.fulfill() }
}
