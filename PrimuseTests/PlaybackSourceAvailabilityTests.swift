import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class PlaybackSourceAvailabilityTests: XCTestCase {
    private struct OfflineConnector: MusicSourceConnector {
        let sourceID: String
        func connect() async throws { throw URLError(.notConnectedToInternet) }
        func disconnect() async {}
        func listFiles(at path: String) async throws -> [RemoteFileItem] { throw URLError(.notConnectedToInternet) }
        func localURL(for path: String) async throws -> URL { throw URLError(.notConnectedToInternet) }
        func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
            throw URLError(.notConnectedToInternet)
        }
        func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
            throw URLError(.notConnectedToInternet)
        }
    }

    private actor ColdCacheSourceGate {
        var calls = 0
        var continuation: CheckedContinuation<Void, Never>?
        let entered: XCTestExpectation
        init(entered: XCTestExpectation) { self.entered = entered }
        func load(_ source: MusicSource) async -> [MusicSource] {
            calls += 1
            if calls == 2 {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    entered.fulfill()
                }
            }
            return [source]
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    func testColdCachedPlaybackJoinsScopeValidationAndNeverConnects() async throws {
        let source = MusicSource(id: "cached-start-\(UUID().uuidString)", name: "Offline", type: .navidrome,
                                 host: "offline.invalid", port: 4533)
        let song = Song(id: UUID().uuidString, title: "Cached audio", duration: 90, fileFormat: .flac,
                        filePath: "/ASMR/track.flac", sourceID: source.id, fileSize: 128)
        let previous = SourceManager(sourcesProvider: { [source] })
        let trusted = await previous.prepareAutomaticOfflineDownload(song: song, forceRedownload: false)
        XCTAssertTrue(trusted)
        let cached = previous.cacheURL(for: song)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 128).write(to: cached)
        defer { previous.deleteSourceCaches(sourceID: source.id) }

        let entered = expectation(description: "Cold-start scope validation is reading the source")
        let gate = ColdCacheSourceGate(entered: entered)
        let relaunched = SourceManager(sourcesProvider: { await gate.load(source) }, connectorFactory: { _ in
            XCTFail("A complete cached file must not create a network connector")
            return LocalFileSource(sourceID: source.id, basePath: cached.deletingLastPathComponent())
        })
        await fulfillment(of: [entered], timeout: 3)
        let returnedEarly = expectation(description: "Playback must wait for the existing local scope check")
        returnedEarly.isInverted = true
        var didRelease = false
        let preparation = Task { @MainActor in
            let result = await relaunched.prepareAutomaticOfflineDownload(song: song, forceRedownload: false)
            if !didRelease { returnedEarly.fulfill() }
            return result
        }
        await fulfillment(of: [returnedEarly], timeout: 0.1)
        didRelease = true
        await gate.release()
        let prepared = await preparation.value
        XCTAssertTrue(prepared)
        let busy = expectation(description: "Cache inventory is busy")
        let releaseMaintenance = DispatchSemaphore(value: 0)
        let maintenance = Task.detached {
            await AudioCacheManager.shared.holdCacheActorForPlaybackTest(entered: busy, release: releaseMaintenance)
        }
        defer { releaseMaintenance.signal() }
        await fulfillment(of: [busy], timeout: 3)
        let started = ContinuousClock.now
        let url = try await relaunched.resolveURL(for: song)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(200))
        XCTAssertEqual(url, cached)
        XCTAssertTrue(url.isFileURL)
        relaunched.finalizeStreamingSession(for: song)
        releaseMaintenance.signal()
        await maintenance.value
    }

    @MainActor
    func testCachedASMRStartsAndSeeksWithoutNetworkWithUnknownDuration() async throws {
        let suite = "CachedASMRPlayback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = MusicSource(id: suite, name: "Offline", type: .navidrome, host: "offline.invalid")
        let fixture = try OfflineAudioFixture.writeWAV(to: directory.appendingPathComponent("rain.wav"),
            seconds: 12, sampleRate: 44_100, channels: 2)
        let song = Song(id: suite, title: "Rain", duration: 0, fileFormat: .wav,
            filePath: "/ASMR/rain.wav", sourceID: source.id,
            fileSize: try OfflineAudioFixture.byteCount(of: fixture), genre: "Audiobook ASMR")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in
            OfflineConnector(sourceID: source.id)
        })
        let trusted = await manager.prepareAutomaticOfflineDownload(song: song, forceRedownload: false)
        XCTAssertTrue(trusted)
        let cached = manager.cacheURL(for: song)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: cached)
        defer { manager.deleteSourceCaches(sourceID: source.id) }

        let settings = PlaybackSettingsStore(defaults: defaults,
            cloudSync: CloudKVSSync(store: nil, defaults: defaults, observing: nil))
        settings.prewarmQueueCount = 0
        settings.skipLeadingSilenceEnabled = false
        settings.skipTrailingSilenceEnabled = false
        settings.replayGainEnabled = false
        let player = AudioPlayerService(sourceManager: manager, playbackSettings: settings,
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        let historyWasSuspended = PlayHistoryStore.shared.isRecordingSuspended
        let scrobbleWasSuspended = ScrobbleService.shared.isSuspended
        let playModes = ListeningPlayModeStore.shared.ledger
        PlayHistoryStore.shared.isRecordingSuspended = true
        ScrobbleService.shared.isSuspended = true
        defer {
            player.stop()
            ListeningPlayModeStore.shared.update { $0 = playModes }
            PlayHistoryStore.shared.isRecordingSuspended = historyWasSuspended
            ScrobbleService.shared.isSuspended = scrobbleWasSuspended
        }
        player.playbackMetadataSourceType = { _ in .navidrome }
        player.audioEngine.setVolume(0, persist: false)
        player.setQueue([song])
        player.repeatMode = .off
        let busy = expectation(description: "Background cache inventory is busy during playback")
        let release = DispatchSemaphore(value: 0)
        let maintenance = Task.detached {
            await AudioCacheManager.shared.holdCacheActorForPlaybackTest(entered: busy, release: release)
        }
        defer { release.signal() }
        await fulfillment(of: [busy], timeout: 3)
        let started = ContinuousClock.now
        await player.play(song: song)
        while (!player.audioEngine.isActuallyPlaying || player.currentTime < 0.05),
              started.duration(to: .now) < .seconds(3) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.audioEngine.isActuallyPlaying)
        XCTAssertEqual(player.duration, 12, accuracy: 0.1)
        player.seek(to: 7, startPlaying: true)
        await player.seekTask?.value
        XCTAssertEqual(player.currentTime, 7, accuracy: 0.5)
        XCTAssertTrue(player.isPlaying)
        release.signal()
        await maintenance.value
    }

    @MainActor
    func testShuffleQuickActionInstallsEveryPlayableCandidateAndAnchorsTheSelectedEntry() throws {
        let suite = "shuffle-quick-action-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = AudioPlayerService(
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Queue construction must not activate audio") }
        )
        let playable = (0..<4).map {
            Song(
                id: "playable-\($0)",
                title: "Playable \($0)",
                duration: 180,
                fileFormat: .flac,
                filePath: "/playable-\($0).flac",
                sourceID: "source"
            )
        }
        let unplayable = Song(
            id: "unplayable",
            title: "Unplayable",
            duration: 0,
            fileFormat: .flac,
            filePath: "",
            sourceID: "source"
        )
        let candidates = (playable + [unplayable]).filteredPlayable()
        let shuffledQueue = candidates.shuffled()
        let selectedID = try XCTUnwrap(shuffledQueue.first?.id)

        player.shuffleEnabled = true
        player.setQueue(shuffledQueue, startAt: 0)

        XCTAssertEqual(Set(player.queue.map(\.id)), Set(playable.map(\.id)))
        XCTAssertEqual(player.queue.count, playable.count)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.queuedSong(at: player.currentIndex)?.id, selectedID)
        XCTAssertEqual(player.shuffledIndices.first, player.currentIndex)
        XCTAssertEqual(Set(player.shuffledIndices), Set(player.queue.indices))
    }

    @MainActor
    func testQueueShuffleTraversalSkipsDisabledSourcesAndReturnsToRawOrderWhenDisabled() throws {
        let suite = "shuffle-source-availability-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disabledSourceID = "disabled-source"
        let library = MusicLibrary(
            disabledSourceIDs: [disabledSourceID],
            storageDirectory: directory.appendingPathComponent("library")
        )
        let player = AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Queue traversal must not activate audio") }
        )
        let songs = [
            Song(id: "current", title: "Current", duration: 180, fileFormat: .flac,
                 filePath: "/current.flac", sourceID: "enabled-source"),
            Song(id: "disabled", title: "Disabled", duration: 180, fileFormat: .flac,
                 filePath: "/disabled.flac", sourceID: disabledSourceID),
            Song(id: "next", title: "Next", duration: 180, fileFormat: .flac,
                 filePath: "/next.flac", sourceID: "enabled-source"),
            Song(id: "after", title: "After", duration: 180, fileFormat: .flac,
                 filePath: "/after.flac", sourceID: "enabled-source")
        ]
        player.setQueue(songs, startAt: 0)
        player.shuffleEnabled = true
        player.shuffledIndices = [0, 1, 2, 3]
        player.shufflePosition = 0

        XCTAssertEqual(player.nextQueueTraversalTarget()?.queueIndex, 2)
        XCTAssertTrue(player.advanceToNextIndex())
        XCTAssertEqual(player.currentIndex, 2)

        player.shuffleEnabled = false
        XCTAssertEqual(player.nextQueueTraversalTarget()?.queueIndex, 3)
    }

    @MainActor
    func testQueueTraversalSkipsAppleMusicSongsThatNeedASubscriptionUntilOneIsActive() throws {
        let suite = "apple-music-subscription-only-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        let player = AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Queue traversal must not activate audio") }
        )
        let appleMusic = AppleMusicLibraryService.systemSourceID
        let songs = [
            Song(id: "current", title: "Current", duration: 180, fileFormat: .flac,
                 filePath: "/current.flac", sourceID: "local-source"),
            Song(id: "cloud", title: "Cloud", duration: 180, fileFormat: .aac,
                 filePath: "1001", sourceID: appleMusic),
            Song(id: "next", title: "Next", duration: 180, fileFormat: .flac,
                 filePath: "/next.flac", sourceID: "local-source"),
            Song(id: "imported", title: "Imported", duration: 180, fileFormat: .aac,
                 filePath: "1002", sourceID: appleMusic)
        ]
        var restrictedIDs: Set<String> = ["cloud", "next"]
        player.appleMusicPlaybackRestrictionProvider = { song in
            restrictedIDs.contains(song.id) ? .cloudOnly : nil
        }
        player.setQueue(songs, startAt: 0)

        XCTAssertEqual(player.appleMusicPlaybackRestriction(for: songs[1]), .cloudOnly)
        XCTAssertFalse(player.isSongAvailableForNewPlayback(songs[1]))
        // Only system-library rows are asked: another source's song is never restricted.
        XCTAssertNil(player.appleMusicPlaybackRestriction(for: songs[2]))
        XCTAssertTrue(player.isSongAvailableForNewPlayback(songs[2]))
        XCTAssertEqual(player.nextQueueTraversalTarget()?.queueIndex, 2)
        XCTAssertEqual(player.queueEntries.map(\.song.id), songs.map(\.id))

        // A subscription makes the row playable again in place.
        restrictedIDs = []
        XCTAssertTrue(player.isSongAvailableForNewPlayback(songs[1]))
        XCTAssertEqual(player.nextQueueTraversalTarget()?.queueIndex, 1)
    }

    @MainActor
    func testUnavailableSourceCountsDownOnlyWhenAnotherSourceCanPlay() async throws {
        let suite = "unavailable-source-skip-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = AudioPlayerService(
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("A source-skip prompt must not activate audio") }
        )
        func song(_ id: String, source: String) -> Song {
            Song(id: id, title: id, duration: 180, fileFormat: .mp3, filePath: "/\(id).mp3", sourceID: source)
        }
        let reason = "quota used up"

        player.setQueue([song("a", source: "pan123"), song("b", source: "pan123"), song("c", source: "nas")], startAt: 0)
        player.currentSong = player.queue.first
        await player.handleUnavailableSourceFailure(song: player.queue[0], reason: reason)
        let skip = try XCTUnwrap(player.pendingSourceSkip)
        XCTAssertEqual(skip.sourceID, "pan123")
        XCTAssertEqual(skip.secondsRemaining, PendingSourceSkip.countdownSeconds)
        XCTAssertEqual(player.lastPlaybackError, skip.message)
        XCTAssertTrue(skip.message.contains(reason))
        player.cancelPendingSourceSkip()
        XCTAssertNil(player.pendingSourceSkip)
        XCTAssertEqual(player.lastPlaybackError, reason)

        player.setQueue([song("d", source: "pan123"), song("e", source: "pan123")], startAt: 0)
        player.currentSong = player.queue.first
        await player.handleUnavailableSourceFailure(song: player.queue[0], reason: reason)
        XCTAssertNil(player.pendingSourceSkip, "Nothing else can play, so there is nothing to count down to")
        XCTAssertEqual(player.lastPlaybackError, reason)
    }

    @MainActor
    func testFNConnectionFailureSkipsTheSourceWithoutAFileLevelNetworkProbe() async throws {
        let suite = "fn-source-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = AudioPlayerService(
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Failure classification must not activate audio") }
        )
        for error in [FnConnectError.unreachable, .discoveryUnavailable, .musicServiceUnavailable,
                      .accessCodeRequired, .accessCodeRejected] {
            let sourceWide = await player.isSourceWideResolutionFailure(error, sourceID: "fn-test")
            XCTAssertTrue(sourceWide)
        }
        let loginTimeoutIsSourceWide = await player.isSourceWideResolutionFailure(
            FnMusicSource.LoginTimeoutError(), sourceID: "fn-test"
        )
        XCTAssertTrue(loginTimeoutIsSourceWide)
        for error: Error in [SourceError.fileNotFound("one-track"),
                             SourceError.connectionFailed("媒体端点：resource not found"),
                             URLError(.timedOut)] {
            let sourceWide = await player.isSourceWideResolutionFailure(error, sourceID: "fn-test")
            XCTAssertFalse(sourceWide, "A single media request cannot establish a source outage")
        }
    }

    private actor ProbeLog {
        var hosts: [String] = []
        func record(_ host: String) { hosts.append(host) }
    }

    @MainActor
    func testSourceOutageIsCachedAndAnExplicitRetryCanRecover() async {
        let source = MusicSource(
            id: "playback-outage-\(UUID().uuidString)",
            name: "Playback Test",
            type: .navidrome,
            host: "nas.invalid",
            port: 4533
        )
        let manager = SourceManager(sourcesProvider: { [source] })
        let calls = ProbeLog()
        let unavailable = await manager.playbackSourceEndpointsAreUnavailable(
            sourceID: source.id,
            probe: { endpoint in
                await calls.record(endpoint.host)
                throw URLError(.cannotConnectToHost)
            }
        )
        XCTAssertTrue(unavailable)
        XCTAssertTrue(manager.isSourceKnownUnavailableForPlayback(source.id))
        let repeated = await manager.playbackSourceEndpointsAreUnavailable(
            sourceID: source.id,
            probe: { endpoint in await calls.record(endpoint.host) }
        )
        XCTAssertTrue(repeated)
        let beforeRetry = await calls.hosts
        XCTAssertEqual(beforeRetry.count, 1)

        let afterRetry = await manager.playbackSourceEndpointsAreUnavailable(
            sourceID: source.id,
            refresh: true,
            probe: { endpoint in await calls.record(endpoint.host) }
        )
        XCTAssertFalse(afterRetry)
        XCTAssertFalse(manager.isSourceKnownUnavailableForPlayback(source.id))
        let afterRetryCalls = await calls.hosts
        XCTAssertEqual(afterRetryCalls.count, 2)
    }

    @MainActor
    func testOutageIsPublishedForViewsAndWithdrawnOnRecovery() async {
        let source = MusicSource(
            id: "playback-published-\(UUID().uuidString)",
            name: "Playback Test",
            type: .navidrome,
            host: "nas.invalid",
            port: 4533
        )
        let manager = SourceManager(sourcesProvider: { [source] })
        var changes = 0
        manager.onPlaybackSourceAvailabilityChange = { changes += 1 }

        _ = await manager.playbackSourceEndpointsAreUnavailable(
            sourceID: source.id,
            probe: { _ in throw URLError(.cannotConnectToHost) }
        )
        XCTAssertEqual(manager.unreachablePlaybackSourceIDs, [source.id])
        XCTAssertEqual(manager.playbackSourceStanding(source.id), .unreachable)
        XCTAssertEqual(changes, 1)

        _ = await manager.playbackSourceEndpointsAreUnavailable(
            sourceID: source.id,
            refresh: true,
            probe: { _ in }
        )
        XCTAssertTrue(manager.unreachablePlaybackSourceIDs.isEmpty)
        XCTAssertEqual(manager.playbackSourceStanding(source.id), .reachable)
        XCTAssertEqual(changes, 2)
    }

    @MainActor
    func testWorkingPublicRouteKeepsSongsEligibleWhenLANIsUnreachable() async {
        var source = MusicSource(
            id: "playback-routes-\(UUID().uuidString)",
            name: "Playback Test",
            type: .navidrome
        )
        source.connectionConfiguration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(host: "192.168.40.5", port: 4533, useSsl: false),
            publicEndpoint: SourceConnectionEndpoint(host: "public.invalid", port: 443, useSsl: true)
        )
        let fixture = source
        let manager = SourceManager(sourcesProvider: { [fixture] })
        let unavailable = await manager.playbackSourceEndpointsAreUnavailable(
            sourceID: source.id,
            probe: { endpoint in
                if endpoint.host == "192.168.40.5" { throw URLError(.timedOut) }
            }
        )
        XCTAssertFalse(unavailable)
        XCTAssertFalse(manager.isSourceKnownUnavailableForPlayback(source.id))
    }

    @MainActor
    func testCancelledProbeDoesNotQuarantineSongs() async {
        let source = MusicSource(
            id: "playback-cancel-\(UUID().uuidString)",
            name: "Playback Test",
            type: .smb,
            host: "nas.invalid",
            port: 445
        )
        let manager = SourceManager(sourcesProvider: { [source] })
        let unavailable = await manager.playbackSourceEndpointsAreUnavailable(
            sourceID: source.id,
            probe: { _ in throw CancellationError() }
        )
        XCTAssertFalse(unavailable)
        XCTAssertFalse(manager.isSourceKnownUnavailableForPlayback(source.id))
    }
}
