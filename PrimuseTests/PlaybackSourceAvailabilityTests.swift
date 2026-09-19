import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class PlaybackSourceAvailabilityTests: XCTestCase {
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
