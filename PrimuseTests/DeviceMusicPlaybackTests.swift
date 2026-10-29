import AVFoundation
import Foundation
import MediaPlayer
import MusicKit
import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import Primuse

@MainActor
private final class PlaylistInspectionWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        for touch in event.allTouches ?? [] where touch.phase == .began {
            print("PHYSICAL_PLAYLIST touch=\(touch.location(in: self)) bounds=\(bounds)")
        }
        super.sendEvent(event)
    }
}

private final class RepeatPlaybackAudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var silentFrames = 0
    private var longestSilence = 0
    private var sampleRate = 1.0

    func install(on node: AVAudioNode) {
        node.installTap(onBus: 0, bufferSize: 512, format: nil) { [self] buffer, _ in
            append(buffer)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        lock.lock()
        defer { lock.unlock() }
        sampleRate = buffer.format.sampleRate
        for frame in 0..<Int(buffer.frameLength) {
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                peak = max(peak, abs(channels[channel][frame]))
            }
            silentFrames = peak < 0.00001 ? silentFrames + 1 : 0
            longestSilence = max(longestSilence, silentFrames)
        }
        frames += Int(buffer.frameLength)
    }

    func snapshot() -> (duration: Double, silence: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (Double(frames) / sampleRate, Double(longestSilence) / sampleRate)
    }
}

final class DeviceMusicPlaybackTests: XCTestCase {
    @MainActor
    func testPhysicalRepeatPlaybackKeepsOutputContinuous() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical audio output device.")
        #else
        guard ProcessInfo.processInfo.environment["PRIMUSE_DEVICE_REPEAT_QA"] == "1" else {
            throw XCTSkip("Opt-in test requiring six-second music clips in RepeatLoopValidation.")
        }
        let root = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent("RepeatLoopValidation", isDirectory: true)
        let suite = "repeat-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let modes = ListeningPlayModeStore.shared.ledger
        let historyWasSuspended = PlayHistoryStore.shared.isRecordingSuspended
        let scrobbleWasSuspended = ScrobbleService.shared.isSuspended
        let idleWasDisabled = UIApplication.shared.isIdleTimerDisabled
        PlayHistoryStore.shared.isRecordingSuspended = true
        ScrobbleService.shared.isSuspended = true
        UIApplication.shared.isIdleTimerDisabled = true
        AppServices.shared.playerService.pause()
        defer {
            defaults.removePersistentDomain(forName: suite)
            ListeningPlayModeStore.shared.update { $0 = modes }
            PlayHistoryStore.shared.isRecordingSuspended = historyWasSuspended
            ScrobbleService.shared.isSuspended = scrobbleWasSuspended
            UIApplication.shared.isIdleTimerDisabled = idleWasDisabled
        }

        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.outputMode = .effects
        settings.prewarmQueueCount = 0
        settings.audioCacheEnabled = false
        settings.skipLeadingSilenceEnabled = false
        settings.skipTrailingSilenceEnabled = false
        settings.replayGainEnabled = false
        let sessionURL = root.appendingPathComponent("repeat-test-session.json")
        let player = AudioPlayerService(playbackSettings: settings,
            playbackSessionStore: PlaybackSessionStore(url: sessionURL))
        defer {
            player.stop()
            player.persistPlaybackSession(flushImmediately: true)
            try? FileManager.default.removeItem(at: sessionURL)
        }

        let cases: [(String, AudioFormat, Bool)] = [
            ("native-gapless", .flac, false),
            ("native-crossfade", .flac, true),
            ("ffmpeg-gapless", .mka, false),
        ]
        for (name, format, crossfade) in cases {
            player.stop()
            settings.gaplessEnabled = !crossfade
            settings.crossfadeEnabled = crossfade
            let url = root.appendingPathComponent("loop.\(format.rawValue)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let song = Song(id: "repeat-\(name)", title: "Repeat music clip", duration: 6,
                            fileFormat: format, filePath: url.path, sourceID: "repeat-test")
            var next = song
            next.id = "next-\(name)"
            player.setQueue([song, next])
            player.shuffleEnabled = false
            player.repeatMode = .one
            await player.play(song: song)
            let started = await waitUntil {
                player.isPlaying && player.currentTime > 0.3 && player.audioEngine.isActuallyPlaying
            }
            XCTAssertTrue(started, player.lastPlaybackError ?? name)
            guard started else { return }
            XCTAssertEqual(player.activeDecoderKind, format == .mka ? .ffmpeg : .native)
            let playID = try XCTUnwrap(player.playID)
            let entryID = player.queueEntries[0].id
            let node = try XCTUnwrap(player.audioEngine.visualizerTapNode)
            let probe = RepeatPlaybackAudioProbe()
            probe.install(on: node)
            do {
                defer { node.removeTap(onBus: 0) }
                var ticket = player.playbackAdvancePolicy.activeTicket?.id
                var boundaries = 0
                var renderedFrame = player.audioEngine.primaryRenderedFrame ?? 0
                let deadline = Date().addingTimeInterval(25)
                while boundaries < 3, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                    XCTAssertEqual(player.playID, playID, "\(name): loop must keep its running transport")
                    XCTAssertEqual(player.currentSong?.id, song.id)
                    XCTAssertEqual(player.currentIndex, 0)
                    XCTAssertEqual(player.queueEntries[0].id, entryID)
                    let frame = player.audioEngine.primaryRenderedFrame ?? 0
                    XCTAssertGreaterThanOrEqual(frame, renderedFrame, "The output node must not restart.")
                    renderedFrame = frame
                    let currentTicket = player.playbackAdvancePolicy.activeTicket?.id
                    if currentTicket != ticket {
                        boundaries += 1
                        ticket = currentTicket
                    }
                    if player.playID != playID || !player.isPlaying { break }
                }
                try await Task.sleep(for: .milliseconds(300))
                let sample = probe.snapshot()
                print("REPEAT_OUTPUT case=\(name) boundaries=\(boundaries) capturedSeconds=\(sample.duration) longestSilence=\(sample.silence)")
                XCTAssertEqual(boundaries, 3)
                XCTAssertGreaterThan(sample.duration, 12)
                XCTAssertLessThan(sample.silence, 0.08, "No inserted silence at a repeat boundary.")
            }

            if crossfade {
                player.sleepStopAfterSongID = song.id
                let stopped = await waitUntil(timeout: 9) { !player.isPlaying && player.isAtTrackEnd }
                XCTAssertTrue(stopped, "Stop after this song must still win over repeat-one.")
                XCTAssertEqual(player.currentSong?.id, song.id)
            } else {
                await player.next()
                let skipped = await waitUntil { player.currentSong?.id == next.id && player.currentTime > 0.2 }
                XCTAssertTrue(skipped, "Manual next must leave repeat-one's current queue entry.")
                XCTAssertEqual(player.currentIndex, 1)
            }
        }
        #endif
    }

    @MainActor
    func testPhysicalFeiniuPlaylistRecovery() async throws {
        try await physicalPlaylistRecovery(type: .fnMusic)
    }

    @MainActor
    func testPhysicalNavidromePlaylistRecovery() async throws {
        try await physicalPlaylistRecovery(type: .navidrome)
    }

    @MainActor
    func testPhysicalSynologyPlaylistRecovery() async throws {
        try await physicalPlaylistRecovery(type: .synologyAudioStation)
    }

    @MainActor
    private func physicalPlaylistRecovery(type: MusicSourceType) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical device and an existing test server account.")
        #else
        guard ProcessInfo.processInfo.environment["PRIMUSE_DEVICE_PLAYLIST_QA"] == "1" else {
            throw XCTSkip("Opt-in test of the device's configured server accounts.")
        }
        let services = AppServices.shared
        let loaded = await waitUntil(timeout: 30) { services.musicLibrary.isReady }
        XCTAssertTrue(loaded)
        guard let source = services.sourcesStore.sources.first(where: { $0.type == type && $0.isEnabled }) else {
            throw XCTSkip("No enabled \(type.rawValue) account is configured on this device.")
        }
        let connector = services.sourceManager.connector(for: source)
        let playlists = try XCTUnwrap(connector as? any ServerPlaylistConnector)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhysicalPlaylist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await playlists.fetchServerPlaylists()
        XCTAssertTrue(snapshot.failedPlaylistIDs.isEmpty)
        XCTAssertFalse(snapshot.playlists.isEmpty)
        let sourceSongs = services.musicLibrary.visibleSongs.filter { $0.sourceID == source.id }
        let byID = Dictionary(sourceSongs.map { (ServerPlaylistIdentity.serverItemID(fromFilePath: $0.filePath), $0) },
                              uniquingKeysWith: { first, _ in first })
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        library.addSongs(sourceSongs)
        await library.waitForPendingIndex()
        _ = ServerPlaylistMirror.apply(snapshot: snapshot, source: source, library: library)
        for remote in snapshot.playlists {
            let id = ServerPlaylistIdentity.playlistID(sourceID: source.id, serverPlaylistID: remote.id)
            XCTAssertEqual(library.playlist(id: id)?.name, remote.name)
            XCTAssertEqual(library.entries(forPlaylist: id).count, Set(remote.trackIDs.filter { !$0.isEmpty }).count)
        }
        let remote = try XCTUnwrap(snapshot.playlists.first { Set($0.trackIDs.filter { byID[$0] != nil }).count >= 2 })
        var seen = Set<String>()
        let ids = Array(remote.trackIDs.filter { byID[$0] != nil && seen.insert($0).inserted }.prefix(2))
        let missing = try XCTUnwrap(byID[ids[0]])
        let known = try XCTUnwrap(byID[ids[1]])
        let isolated = MusicLibrary(storageDirectory: root.appendingPathComponent("missing-library"))
        isolated.addSongs([known])
        await isolated.waitForPendingIndex()
        let fixture = ServerPlaylist(id: "device-pending-recovery", name: "实体歌单验证 · \(source.name)",
            trackIDs: ids + ["qa-metadata-unavailable"], tracks: ids.map { id in
                remote.tracks.first { $0.externalID == id }
                    ?? ExternalPlaylistTrack(title: byID[id]!.title, artists: [byID[id]!.artistName ?? ""],
                                             album: byID[id]!.albumTitle, duration: byID[id]!.duration, externalID: id)
            })
        _ = ServerPlaylistMirror.apply(snapshot: ServerPlaylistSnapshot(playlists: [fixture]), source: source, library: isolated)
        let playlistID = ServerPlaylistIdentity.playlistID(sourceID: source.id, serverPlaylistID: fixture.id)
        let playlist = try XCTUnwrap(isolated.playlist(id: playlistID))
        XCTAssertEqual(isolated.pendingEntryCount(forPlaylist: playlistID), 2)
        XCTAssertEqual(isolated.songs(forPlaylist: playlistID).map(\.id), [known.id])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "physical-playlist-\(UUID().uuidString)"))
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.prewarmQueueCount = 0
        let player = AudioPlayerService(sourceManager: services.sourceManager, library: isolated,
            playbackSettings: settings, playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("session.json")))
        services.playerService.pause()
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first { $0.isKeyWindow }
        let window = PlaylistInspectionWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { PlaylistDetailView(playlist: playlist) }
                .environment(player).environment(isolated).environment(services.sourceManager)
                .environment(services.sourcesStore).environment(services.metadataBackfill)
                .environment(services.scraperService).environment(services.scraperSettingsStore)
                .environment(services.themeService).environment(services.coverTintProvider)
                .environment(services.playbackSettingsStore).environment(services.scanService)
                .environment(services.appleMusic).environment(services.dlnaRenderer)
                .environment(services.audioCacheSync).environment(services.batchRemoval)
                .environment(services.duplicateCleanup).environment(services.serverListeningStats)
                .environment(services.serverCatalogAutoRefresh).environment(services.cloudSync)
                .environment(services.appleMusicLibrary).environment(services.musicIntelligence)
                .environment(services.radioStationsStore).environment(services.updateChecker)
                .environment(player.audioEngine).environment(player.equalizerService)
                .environment(player.audioEffectsService).environment(services.visualizer))
        window.windowLevel = .alert
        window.makeKeyAndVisible()
        defer {
            player.stop()
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
            UIApplication.shared.isIdleTimerDisabled = oldIdle
        }
        func screenshot(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(type.rawValue)-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let inspection = Double(ProcessInfo.processInfo.environment["PRIMUSE_DEVICE_PLAYLIST_INSPECTION_SECONDS"] ?? "") ?? 3
        print("PHYSICAL_PLAYLIST \(type.rawValue) pending; serverPlaylists=\(snapshot.playlists.count) catalog=\(sourceSongs.count)")
        try await Task.sleep(for: .seconds(inspection))
        screenshot("pending")
        XCTAssertNil(player.currentSong, "A gray row must not start playback during inspection.")
        player.stop()
        isolated.addSongs([missing], affectedSourceIDs: [source.id], notifyRemovals: false, pruneMissingSongs: false)
        await isolated.waitForPendingIndex()
        let recovered = await waitUntil { isolated.pendingEntryCount(forPlaylist: playlistID) == 1 }
        XCTAssertTrue(recovered)
        XCTAssertEqual(isolated.songs(forPlaylist: playlistID).map(\.id), [missing.id, known.id])
        print("PHYSICAL_PLAYLIST \(type.rawValue) recovered")
        try await Task.sleep(for: .seconds(inspection))
        screenshot("recovered")
        if player.currentSong?.id != missing.id {
            player.setQueue(isolated.songs(forPlaylist: playlistID))
            await player.play(song: missing)
        }
        let played = await waitUntil(timeout: 30) {
            player.currentSong?.id == missing.id && player.isPlaying && player.currentTime > 1
                && player.audioEngine.isActuallyPlaying
        }
        XCTAssertTrue(played, player.lastPlaybackError ?? "The restored song must produce playback progress.")
        XCTAssertEqual(player.queue.map(\.id), [missing.id, known.id])
        screenshot("playing")
        print("PHYSICAL_PLAYLIST \(type.rawValue) played=\(played) time=\(player.currentTime) queue=\(player.queue.count)")
        _ = await isolated.persistNowAndWait()
        _ = await library.persistNowAndWait()
        #endif
    }

    private struct Manifest: Decodable {
        let files: [Fixture]
    }

    private struct Fixture: Decodable {
        let name: String
        let path: String
        let format: String
        let duration: Double
    }

    @MainActor
    private func fixtureDirectory() throws -> URL {
        #if targetEnvironment(simulator)
        throw XCTSkip("This test requires an explicitly selected physical device.")
        #else
        guard ProcessInfo.processInfo.environment["PRIMUSE_DEVICE_PLAYBACK_QA"] == "1" else {
            throw XCTSkip("Opt-in playback test; requires an external fixture manifest.")
        }
        return try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent("PlaybackValidation", isDirectory: true)
        #endif
    }

    @MainActor
    private func waitUntil(timeout: Double = 15, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return predicate()
    }

    @MainActor
    private func makePlayer(root: URL, sourceType: MusicSourceType = .local) throws -> AudioPlayerService {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "device-playback-\(UUID().uuidString)"))
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.prewarmQueueCount = 0
        settings.skipLeadingSilenceEnabled = false
        settings.skipTrailingSilenceEnabled = false
        settings.audioCacheEnabled = false
        let player = AudioPlayerService(
            playbackSettings: settings,
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("test-session.json"))
        )
        player.configurePlaybackMetadataBackfill(AppServices.shared.metadataBackfill) { _ in sourceType }
        return player
    }

    @MainActor
    private func writeResults(_ rows: [[String: Any]], name: String, root: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("\(name)-results.json"), options: .atomic)
    }

    @MainActor
    func testRemovingRestoredAppleMusicRowsKeepsReplacementPaused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = try makePlayer(root: root, sourceType: .appleMusicLibrary)
        defer { player.stop() }
        let removed = PrimuseKit.Song(id: "old-download", title: "Old download", duration: 60,
                                     fileFormat: .m4a, filePath: "old", sourceID: "local-music")
        let retained = PrimuseKit.Song(id: "retained-local", title: "Retained file", duration: 90,
                                      fileFormat: .m4a, filePath: "retained", sourceID: "local-music")
        player.setQueue([removed, removed, retained])
        player.stagePausedHandoff(song: removed, at: 15)
        await player.prepareQueueForRemovingSongs(withIDs: [removed.id])
        XCTAssertEqual(player.queue.map(\.id), [retained.id])
        XCTAssertEqual(player.currentSong?.id, retained.id)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertEqual(player.currentTime, 0)
        await player.prepareQueueForRemovingSongs(withIDs: [retained.id])
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentSong)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testCarPlayAppleMusicPlaylistAdvancesWithoutLosingQueue() async throws {
        let root = try fixtureDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard MusicAuthorization.currentStatus == .authorized else { throw XCTSkip("Apple Music is not authorized.") }
        let services = AppServices.shared
        let library = services.musicLibrary
        let requestedID = ProcessInfo.processInfo.environment["PRIMUSE_CARPLAY_PLAYLIST_ID"]
        func candidate() -> PrimuseKit.Playlist? {
            library.playlists.first { playlist in
                if let requestedID, playlist.id != requestedID { return false }
                let songs = library.songs(forPlaylist: playlist.id).filteredPlayable()
                return songs.count >= 4 && songs.allSatisfy { $0.sourceID == AppleMusicLibraryService.systemSourceID }
            }
        }
        let loaded = await waitUntil(timeout: 30) { candidate() != nil }
        XCTAssertTrue(loaded, "A selected Apple Music playlist with at least four tracks must be available.")
        let playlist = try XCTUnwrap(candidate())
        let songs = library.songs(forPlaylist: playlist.id).filteredPlayable()
        let player = services.playerService
        let repeatMode = player.repeatMode
        let shuffleEnabled = player.shuffleEnabled
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        player.pause()
        player.repeatMode = .off
        player.shuffleEnabled = false
        defer {
            player.pause()
            player.repeatMode = repeatMode
            player.shuffleEnabled = shuffleEnabled
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
        }

        var results: [[String: Any]] = []
        func currentSystemTitle() -> String? { ApplicationMusicPlayer.shared.queue.currentEntry?.title }
        func matches(_ index: Int) -> Bool {
            player.currentSong?.id == songs[index].id && player.currentIndex == index
                && currentSystemTitle() == songs[index].title && player.isPlaying
        }
        let delegate = CarPlaySceneDelegate()
        let item = CarPlayHomeItem(id: playlist.id, title: playlist.name, target: .playlist(playlist.id, directly: true))
        delegate.activateHomeItem(item)
        let started = await waitUntil(timeout: 30) { matches(0) && player.currentTime > 0.5 }
        XCTAssertTrue(started, "CarPlay playlist selection must start its first track: \(player.lastPlaybackError ?? "no progress")")
        XCTAssertEqual(player.queue.map(\.id), songs.map(\.id))
        XCTAssertEqual(ApplicationMusicPlayer.shared.queue.entries.count, songs.count)
        results.append(["step": "playlist-start", "passed": started, "queueCount": player.queue.count,
                        "systemQueueCount": ApplicationMusicPlayer.shared.queue.entries.count,
                        "title": currentSystemTitle() ?? ""])
        try writeResults(results, name: "carplay-queue", root: root)
        guard started else { return }

        // Run the same home action again before the terminal boundary; it must
        // not detach the canonical queue from the active MusicKit request.
        let currentSlot = try XCTUnwrap(player.queueEntries.first?.id)
        let nativeEntry = ApplicationMusicPlayer.shared.queue.currentEntry?.id
        let previousTime = player.currentTime
        delegate.activateHomeItem(item)
        let restarted = await waitUntil(timeout: 30) {
            matches(0) && !player.isLoading && player.currentTime > previousTime + 0.5
                && ApplicationMusicPlayer.shared.queue.entries.count == songs.count
        }
        XCTAssertTrue(restarted)
        XCTAssertEqual(player.queueEntries.first?.id, currentSlot)
        XCTAssertEqual(ApplicationMusicPlayer.shared.queue.currentEntry?.id, nativeEntry)
        guard restarted else { return }
        player.seek(to: max(0, player.duration - 5))
        let advanced = await waitUntil(timeout: 25) { matches(1) && player.currentTime > 0.5 }
        XCTAssertTrue(advanced, "The first song ending must start the second song without a new tap.")
        XCTAssertEqual(player.queue.map(\.id), songs.map(\.id))
        results.append(["step": "natural-end", "passed": advanced, "queueCount": player.queue.count,
                        "index": player.currentIndex, "title": currentSystemTitle() ?? ""])
        try writeResults(results, name: "carplay-queue", root: root)
        guard advanced else { return }

        // Exercise the system path used by CarPlay, independently of the
        // app's own next() handler.
        try await ApplicationMusicPlayer.shared.skipToNextEntry()
        let skipped = await waitUntil(timeout: 30) { matches(2) && player.currentTime > 0.5 }
        XCTAssertTrue(skipped, "Next must select the third playlist entry after automatic advancement.")
        XCTAssertEqual(player.queue.map(\.id), songs.map(\.id))
        results.append(["step": "system-next", "passed": skipped, "queueCount": player.queue.count,
                        "index": player.currentIndex, "title": currentSystemTitle() ?? ""])
        try writeResults(results, name: "carplay-queue", root: root)
        guard skipped else { return }

        player.pause()
        let activeNativeEntry = ApplicationMusicPlayer.shared.queue.currentEntry?.id
        player.insertNextInQueue([songs[0]])
        let insertedID = player.queueEntries[3].id
        let updated = await waitUntil {
            ApplicationMusicPlayer.shared.queue.entries.count == songs.count + 1
        }
        XCTAssertTrue(updated, "Editing a paused queue must update the native successors.")
        XCTAssertEqual(ApplicationMusicPlayer.shared.queue.currentEntry?.id, activeNativeEntry)
        player.resume()
        try await ApplicationMusicPlayer.shared.skipToNextEntry()
        let insertedPlayed = await waitUntil {
            player.currentSong?.id == songs[0].id && player.currentIndex == 3
                && services.appleMusic.nowPlayingQueueEntryID == insertedID && player.isPlaying
        }
        XCTAssertTrue(insertedPlayed, "An inserted duplicate must advance to its own queue occurrence.")
        results.append(["step": "insert-duplicate-while-paused", "passed": updated && insertedPlayed])
        try writeResults(results, name: "carplay-queue", root: root)
        guard insertedPlayed else { return }

        await player.next()
        let appSkipped = await waitUntil(timeout: 30) {
            player.currentIndex == 4 && player.currentSong?.id == songs[3].id && player.isPlaying
        }
        XCTAssertTrue(appSkipped)
        results.append(["step": "app-next", "passed": appSkipped])
        player.clearQueue()
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertEqual(ApplicationMusicPlayer.shared.queue.entries.count, 1)
        results.append(["step": "clear-native-successors", "passed": player.queue.isEmpty
                        && ApplicationMusicPlayer.shared.queue.entries.count == 1])
        try writeResults(results, name: "carplay-queue", root: root)
        player.pause()
        player.setQueue(songs, startAt: min(3, songs.count - 1))
    }

    @MainActor
    func testLocalAudioFormatMatrix() async throws {
        let root = try fixtureDirectory()
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        AppServices.shared.playerService.pause()
        let player = try makePlayer(root: root)
        defer { player.stop() }
        var results: [[String: Any]] = []
        let selected = ProcessInfo.processInfo.environment["PRIMUSE_DEVICE_PLAYBACK_CASES"]
            .map { Set($0.split(separator: ",").map(String.init)) }

        for fixture in manifest.files where selected == nil || selected!.contains(fixture.name) {
            let url = root.appendingPathComponent(fixture.path)
            let song = PrimuseKit.Song(
                id: "device-qa-\(fixture.name)", title: fixture.name,
                duration: fixture.duration, fileFormat: try XCTUnwrap(AudioFormat(rawValue: fixture.format)),
                filePath: url.path, sourceID: "device-qa-local"
            )
            player.setQueue([song])
            await player.play(song: song, from: url, bypassSystemMediaPlayback: true, shouldRecordPlaybackStart: false)
            let ready = await waitUntil { player.isPlaying && player.audioEngine.isActuallyPlaying || player.lastPlaybackError != nil }
            try await Task.sleep(for: .milliseconds(600))
            let initialTime = player.currentTime
            try await Task.sleep(for: .milliseconds(1500))
            let success = ready && player.currentTime > initialTime + 0.5 && player.isPlaying
                && player.audioEngine.isActuallyPlaying && player.currentSong?.id == song.id
                && player.lastPlaybackError == nil
            var row: [String: Any] = [
                "name": fixture.name, "success": success, "initialTime": initialTime, "time": player.currentTime,
                "engine": player.audioEngine.diagnosticInfo(), "error": player.lastPlaybackError ?? "",
                "queueIndex": player.currentIndex
            ]
            XCTAssertTrue(success, "\(fixture.name): \(row)")
            if success {
                XCTAssertEqual(player.duration, fixture.duration, accuracy: 0.5, "\(fixture.name) duration must reflect the actual media.")
            }

            if success && ["MP3-CBR", "ALAC-24-96", "FLAC-24-192", "DSD64-DSF", "Opus"].contains(fixture.name) {
                player.pause()
                XCTAssertFalse(player.isPlaying)
                player.resume()
                let resumed = await waitUntil { player.isPlaying && player.audioEngine.isActuallyPlaying }
                XCTAssertTrue(resumed, "\(fixture.name) resume")
                player.seek(to: 6, startPlaying: true)
                let sought = await waitUntil { !player.isLoading && player.currentTime >= 6.5 && player.isPlaying }
                XCTAssertTrue(sought, "\(fixture.name) seek: \(player.currentTime)")
                row["pauseResume"] = resumed
                row["seek"] = sought
            }
            player.pause()
            results.append(row)
            try writeResults(results, name: "local-formats", root: root)
        }
        XCTAssertFalse(results.isEmpty)
    }

    @MainActor
    func testCompleteAudioStreams() async throws {
        let root = try fixtureDirectory()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var results: [[String: Any]] = []
        for fixture in manifest.files {
            let url = root.appendingPathComponent(fixture.path)
            let decoder = await FileFormatRouter.decoder(for: url)
            func countFrames(using decoder: any PrimuseAudioDecoder) async throws -> Int {
                var frames = 0
                for try await buffer in decoder.decode(from: url, outputFormat: format) {
                    XCTAssertEqual(buffer.format, format)
                    frames += Int(buffer.frameLength)
                }
                return frames
            }
            let frames: Int
            var fallback = false
            do {
                frames = try await countFrames(using: decoder)
            } catch {
                guard decoder is NativeAudioDecoder else { throw error }
                fallback = true
                frames = try await countFrames(using: FFmpegAudioDecoder())
            }
            let duration = Double(frames) / format.sampleRate
            XCTAssertEqual(duration, fixture.duration, accuracy: 0.5, fixture.name)
            results.append(["name": fixture.name, "decodedDuration": duration, "fallback": fallback])
            try writeResults(results, name: "complete-streams", root: root)
        }
    }

    @MainActor
    func testMP3RangeInputCanDecodeAndSeek() async throws {
        let root = try fixtureDirectory()
        let bytes = try Data(contentsOf: root.appendingPathComponent("MP3-CBR.mp3"))
        let decoder = NativeAudioDecoder()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        for start in [0.0, 6.0] {
            let input = CloudInputSourceObjC(url: URL(string: "primuse-cloud://device-qa/music.mp3"), totalLength: Int64(bytes.count)) { offset, length, _ in
                guard offset >= 0, offset < bytes.count else { return Data() }
                let end = min(Int(offset + length), bytes.count)
                return bytes.subdata(in: Int(offset)..<end)
            }
            var frames = 0
            for try await buffer in decoder.decode(from: input, outputFormat: format, startingAt: start) {
                XCTAssertEqual(buffer.format.sampleRate, 48_000)
                XCTAssertGreaterThan(buffer.frameLength, 0)
                frames += Int(buffer.frameLength)
                if frames >= 16_000 { break }
            }
            XCTAssertGreaterThanOrEqual(frames, 16_000, "Range-backed MP3 seek at \(start)")
        }
    }

    @MainActor
    func testUnplayableLocalAssetsAndQueues() async throws {
        let root = try fixtureDirectory()
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        AppServices.shared.playerService.pause()
        let player = try makePlayer(root: root, sourceType: .appleMusicLibrary)
        defer { player.stop() }
        var results: [[String: Any]] = []
        let invalid = ["empty.m4a", "corrupt.m4a", "corrupt.flac", "html.mp3", "managed.movpkg", "missing.m4a"]
        for path in invalid {
            let url = root.appendingPathComponent(path)
            let song = PrimuseKit.Song(
                id: "device-qa-\(path)", title: path, duration: 12,
                fileFormat: AudioFormat.from(fileExtension: url.pathExtension) ?? .m4a,
                filePath: url.path, sourceID: "device-qa-apple-music-local"
            )
            let next = PrimuseKit.Song(id: "should-not-advance", title: "Next", duration: 12,
                                      fileFormat: .m4a, filePath: root.appendingPathComponent("AAC-M4A.m4a").path,
                                      sourceID: song.sourceID)
            player.repeatMode = .all
            player.setQueue([song, next])
            await player.play(song: song, from: url, bypassSystemMediaPlayback: true, shouldRecordPlaybackStart: false)
            let settled = await waitUntil { !player.isPlaying && !player.isLoading && player.lastPlaybackError != nil }
            try await Task.sleep(for: .seconds(1))
            let success = settled && player.currentSong?.id == song.id && player.currentIndex == 0
                && player.lastPlaybackError != nil && !player.isPlaying && !player.isLoading
            XCTAssertTrue(success, "\(path): index=\(player.currentIndex), error=\(player.lastPlaybackError ?? "nil")")
            results.append(["name": path, "success": success, "queueIndex": player.currentIndex,
                            "error": player.lastPlaybackError ?? ""])
            try writeResults(results, name: "invalid-assets", root: root)
        }
        let errorBeforeDelay = player.lastPlaybackError
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(player.lastPlaybackError, errorBeforeDelay, "Terminal errors must remain visible.")
        XCTAssertNotNil(errorBeforeDelay)

        for (path, expected) in [("managed.movpkg", AppleMusicLocalAssetError.managedDownload),
                                 ("protected.m4p", .protectedContent), ("missing.m4a", .unavailable),
                                 ("empty.m4a", .invalidFile)] {
            let asset = AppleMusicLocalAsset(url: root.appendingPathComponent(path), isSong: true,
                                            isFileLocation: true, isProtected: false)
            XCTAssertThrowsError(try asset.validatedURL()) { error in
                XCTAssertEqual(error as? AppleMusicLocalAssetError, expected)
                XCTAssertEqual(PlaybackPipelineFailurePolicy.action(requestIsCurrent: true, error: error), .preserveCurrentItem)
            }
        }

        let localPlayer = try makePlayer(root: root)
        defer { localPlayer.stop() }
        let brokenQueue = (0..<3).map { i in
            PrimuseKit.Song(id: "broken-\(i)", title: "Broken \(i)", duration: 12,
                            fileFormat: .m4a, filePath: root.appendingPathComponent("corrupt.m4a").path,
                            sourceID: "device-qa-local")
        }
        for mode in [PrimuseKit.RepeatMode.one, .all] {
            localPlayer.repeatMode = mode
            localPlayer.setQueue(brokenQueue)
            await localPlayer.play(song: brokenQueue[0])
            let settled = await waitUntil(timeout: 25) { !localPlayer.isPlaying && !localPlayer.isLoading && localPlayer.lastPlaybackError != nil }
            let index = localPlayer.currentIndex
            try await Task.sleep(for: .seconds(3))
            XCTAssertTrue(settled)
            XCTAssertEqual(localPlayer.currentIndex, index, "All-failed queue must stop cycling.")
            XCTAssertFalse(localPlayer.isPlaying)
            XCTAssertFalse(localPlayer.isLoading)
            XCTAssertNotNil(localPlayer.lastPlaybackError)
            results.append(["name": "all-broken-\(mode)", "success": settled && localPlayer.currentIndex == index,
                            "queueIndex": index, "error": localPlayer.lastPlaybackError ?? ""])
            try writeResults(results, name: "invalid-assets", root: root)
        }
    }

    @MainActor
    func testAppleMusicManagedQueueKeepsSelectedOccurrenceOnPhysicalDevice() async throws {
        let root = try fixtureDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard MusicAuthorization.currentStatus == .authorized else {
            throw XCTSkip("Apple Music access is not authorized on this device.")
        }
        guard try await MusicSubscription.current.canPlayCatalogContent else {
            throw XCTSkip("This device has no catalog playback entitlement.")
        }
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.limit = 12
        let candidates = Array(try await request.response().items.prefix(3))
        guard candidates.count == 3 else { throw XCTSkip("Three library songs are required.") }
        let services = AppServices.shared
        let appleMusic = services.appleMusic
        let songs = [candidates[0], candidates[1], candidates[0], candidates[2]]
        let entryIDs = songs.map { _ in UUID() }
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        services.playerService.pause()
        defer {
            appleMusic.stopAppleMusic()
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
        }
        var results: [[String: Any]] = []
        for selected in [2, 1, 3, 0] {
            let requestID = appleMusic.beginPlaybackRequest()
            appleMusic.prepareForPrimuseManagedQueue()
            await appleMusic.playUserLibrary(
                songs: songs, startAt: selected, queueEntryIDs: entryIDs,
                source: .catalogBackedUserLibrary, expectedDuration: songs[selected].duration ?? 0,
                requestID: requestID, requestCanContinue: { true }
            )
            let progressed = await waitUntil(timeout: 20) {
                appleMusic.isAppleMusicPlaying && appleMusic.currentPlaybackTime > 1
            }
            let actualEntry = ApplicationMusicPlayer.shared.queue.currentEntry
            let actualIndex = actualEntry.flatMap { current in
                ApplicationMusicPlayer.shared.queue.entries.firstIndex { $0.id == current.id }
            }
            let matched = appleMusic.nowPlayingQueueEntryID == entryIDs[selected]
            results.append([
                "selected": selected, "actualIndex": actualIndex ?? -1,
                "entryMapped": matched, "progressed": progressed,
                "requestedTitle": songs[selected].title, "actualTitle": actualEntry?.title ?? "",
                "nativeCount": ApplicationMusicPlayer.shared.queue.entries.count,
                "nativeEntryIDs": ApplicationMusicPlayer.shared.queue.entries.map(\.id),
                "currentNativeEntryID": actualEntry?.id ?? "",
                "error": appleMusic.lastPlaybackError ?? ""
            ])
            try writeResults(results, name: "apple-music-managed-queue", root: root)
            XCTAssertTrue(progressed, "Selected song must play: \(appleMusic.lastPlaybackError ?? "no progress")")
            XCTAssertEqual(actualEntry?.title, songs[selected].title)
            XCTAssertEqual(actualIndex, selected, "Repeated songs must preserve their selected occurrence.")
            XCTAssertTrue(matched, "Resolved MusicKit entries must keep their Primuse queue identity.")
            if selected == 2, matched {
                try await ApplicationMusicPlayer.shared.skipToNextEntry()
                let advanced = await waitUntil { appleMusic.nowPlayingQueueEntryID == entryIDs[3] }
                XCTAssertTrue(advanced, "Native advance must select the next Primuse occurrence.")
                ApplicationMusicPlayer.shared.playbackTime = 0
                try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
                let returned = await waitUntil { appleMusic.nowPlayingQueueEntryID == entryIDs[2] }
                XCTAssertTrue(returned, "Native previous must return to the second copy.")

                let insertedID = UUID()
                appleMusic.seekAppleMusic(to: 12)
                let sought = await waitUntil(timeout: 5) { ApplicationMusicPlayer.shared.playbackTime >= 11.5 }
                XCTAssertTrue(sought, "Seek must settle before verifying progress across an edit.")
                guard sought else { return }
                await appleMusic.updateManagedQueue(
                    songs: [songs[3], songs[2], songs[1]],
                    entryIDs: [entryIDs[3], entryIDs[2], insertedID],
                    currentEntryID: entryIDs[2], repeatMode: .off, requestID: requestID
                )
                let edited = await waitUntil {
                    let entries = ApplicationMusicPlayer.shared.queue.entries
                    return entries.count == 3
                        && !entries.contains(where: \.isTransient)
                        && ApplicationMusicPlayer.shared.queue.currentEntry?.id == entries[1].id
                        && appleMusic.nowPlayingQueueEntryID == entryIDs[2]
                        && appleMusic.isAppleMusicPlaying
                        && ApplicationMusicPlayer.shared.playbackTime >= 11.5
                }
                func nativeState() -> [[String: String]] {
                    ApplicationMusicPlayer.shared.queue.entries.map { entry in
                        let song: MusicKit.Song?
                        if case .song(let resolved) = entry.item { song = resolved } else { song = nil }
                        return ["entryID": entry.id, "title": entry.title,
                                "songID": song?.id.rawValue ?? "",
                                "transientSongID": (entry.transientItem as? MusicKit.Song)?.id.rawValue ?? ""]
                    }
                }
                let afterEdit = nativeState()
                results.append(["stage": "edit", "passed": edited, "entries": afterEdit,
                                "current": ApplicationMusicPlayer.shared.queue.currentEntry?.description ?? "",
                                "time": ApplicationMusicPlayer.shared.playbackTime])
                try writeResults(results, name: "apple-music-managed-queue", root: root)
                XCTAssertTrue(edited, "Reorder, removal, and insertion must retain the playing occurrence.")
                guard edited else { return }
                XCTAssertGreaterThanOrEqual(ApplicationMusicPlayer.shared.playbackTime, 11.5,
                                            "Editing the queue must preserve playback progress.")
                try await ApplicationMusicPlayer.shared.skipToNextEntry()
                let inserted = await waitUntil { appleMusic.nowPlayingQueueEntryID == insertedID }
                XCTAssertTrue(inserted, "An inserted transient entry must resolve to its new Primuse ID.")
                let afterNext = nativeState()
                let currentAfterNext = ApplicationMusicPlayer.shared.queue.currentEntry
                appleMusic.retainCurrentManagedQueueEntry()
                let retained = await waitUntil {
                    ApplicationMusicPlayer.shared.queue.entries.count == 1
                        && appleMusic.nowPlayingQueueEntryID == insertedID
                        && appleMusic.isAppleMusicPlaying
                }
                XCTAssertTrue(retained, "A renderer boundary must retain the current entry's identity.")
                _ = appleMusic.pauseAppleMusic()
                let pausedPosition = ApplicationMusicPlayer.shared.playbackTime
                await appleMusic.updateManagedQueue(
                    songs: [songs[3], songs[1], songs[0]],
                    entryIDs: [UUID(), insertedID, UUID()], currentEntryID: insertedID,
                    repeatMode: .off, requestID: requestID
                )
                let stayedPaused = await waitUntil {
                    let entries = ApplicationMusicPlayer.shared.queue.entries
                    return entries.count == 3 && !entries.contains(where: \.isTransient)
                        && ApplicationMusicPlayer.shared.queue.currentEntry?.id == entries[1].id
                        && ApplicationMusicPlayer.shared.state.playbackStatus == .paused
                        && appleMusic.nowPlayingQueueEntryID == insertedID
                        && !appleMusic.isAppleMusicPlaying
                        && abs(ApplicationMusicPlayer.shared.playbackTime - pausedPosition) < 0.5
                }
                XCTAssertTrue(stayedPaused, "Editing a paused queue must not resume playback.")
                XCTAssertEqual(ApplicationMusicPlayer.shared.playbackTime, pausedPosition, accuracy: 0.5)
                var resumeEditFinished = false
                let resumeEdit = Task { @MainActor in
                    await appleMusic.updateManagedQueue(
                        songs: [songs[0], songs[1], songs[3], songs[0]],
                        entryIDs: [UUID(), insertedID, UUID(), UUID()], currentEntryID: insertedID,
                        repeatMode: .off, requestID: requestID
                    )
                    resumeEditFinished = true
                }
                await Task.yield()
                let resumedDuringEdit = !resumeEditFinished
                let resumeRequested = appleMusic.resumeAppleMusic()
                await resumeEdit.value
                let resumed = await waitUntil {
                    ApplicationMusicPlayer.shared.queue.entries.count == 4
                        && appleMusic.nowPlayingQueueEntryID == insertedID
                        && appleMusic.isAppleMusicPlaying && appleMusic.currentPlaybackTime > 0.5
                }
                XCTAssertTrue(resumeRequested && resumed, "A newer Play command must survive queue preparation.")
                var pauseEditFinished = false
                let pauseEdit = Task { @MainActor in
                    await appleMusic.updateManagedQueue(
                        songs: [songs[3], songs[1], songs[0]],
                        entryIDs: [UUID(), insertedID, UUID()], currentEntryID: insertedID,
                        repeatMode: .off, requestID: requestID
                    )
                    pauseEditFinished = true
                }
                await Task.yield()
                let pausedDuringEdit = !pauseEditFinished
                _ = appleMusic.pauseAppleMusic()
                await pauseEdit.value
                let paused = await waitUntil {
                    ApplicationMusicPlayer.shared.queue.entries.count == 3
                        && appleMusic.nowPlayingQueueEntryID == insertedID
                        && ApplicationMusicPlayer.shared.state.playbackStatus == .paused
                        && !appleMusic.isAppleMusicPlaying
                }
                XCTAssertTrue(paused, "A newer Pause command must survive queue preparation.")
                let obsoleteEdit = Task { @MainActor in
                    await appleMusic.updateManagedQueue(
                        songs: [songs[0], songs[1], songs[0], songs[3]],
                        entryIDs: [UUID(), insertedID, UUID(), UUID()], currentEntryID: insertedID,
                        repeatMode: .off, requestID: requestID
                    )
                }
                await Task.yield()
                obsoleteEdit.cancel()
                await appleMusic.updateManagedQueue(
                    songs: [songs[1], songs[3]], entryIDs: [insertedID, UUID()],
                    currentEntryID: insertedID, repeatMode: .off, requestID: requestID
                )
                await obsoleteEdit.value
                let newestEditWon = await waitUntil {
                    let entries = ApplicationMusicPlayer.shared.queue.entries
                    return entries.count == 2 && !entries.contains(where: \.isTransient)
                        && ApplicationMusicPlayer.shared.queue.currentEntry?.id == entries.first?.id
                        && appleMusic.nowPlayingQueueEntryID == insertedID
                        && ApplicationMusicPlayer.shared.state.playbackStatus == .paused
                }
                XCTAssertTrue(newestEditWon, "A superseded edit must not overwrite the newest queue.")
                results.append(["nativeNext": advanced, "nativePrevious": returned,
                                "queueEdit": edited, "insertedEntry": inserted, "retainCurrent": retained,
                                "pausedEdit": stayedPaused,
                                "resumeCommand": resumed, "pauseCommand": paused,
                                "resumeIssuedDuringEdit": resumedDuringEdit,
                                "pauseIssuedDuringEdit": pausedDuringEdit,
                                "supersededEdit": newestEditWon,
                                "afterEdit": afterEdit, "afterNext": afterNext,
                                "currentAfterNext": currentAfterNext?.description ?? "",
                                "mappedAfterNext": appleMusic.nowPlayingQueueEntryID?.uuidString ?? "",
                                "expectedAfterNext": insertedID.uuidString])
                try writeResults(results, name: "apple-music-managed-queue", root: root)
            }
            _ = appleMusic.pauseAppleMusic()
        }
    }

    @MainActor
    func testAppleMusicDuplicateQueueMirrorsIntoPlayerOnPhysicalDevice() async throws {
        let root = try fixtureDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let services = AppServices.shared
        guard MusicAuthorization.currentStatus == .authorized,
              try await MusicSubscription.current.canPlayCatalogContent,
              services.musicLibrary.appleMusicSourceInstalled,
              !services.musicLibrary.disabledSourceIDs.contains(AppleMusicLibraryService.systemSourceID),
              AppleMusicFeatureSettings.syncUserLibraryEnabled else {
            throw XCTSkip("An enabled Apple Music library and subscription are required.")
        }
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.limit = 12
        let candidates = Array(try await request.response().items.prefix(3))
        guard candidates.count == 3 else { throw XCTSkip("Three library songs are required.") }
        let songs = [candidates[0], candidates[1], candidates[0], candidates[2]]
            .map(AppleMusicLibraryService.toPrimuseSong)
        services.playerService.pause()
        let player = AudioPlayerService(
            sourceManager: services.sourceManager, library: services.musicLibrary,
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("apple-music-queue-session.json"))
        )
        let appleMusic = services.appleMusic
        let savedRepeatMode = player.repeatMode
        let savedShuffle = player.shuffleEnabled
        let savedIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        player.pause()
        player.repeatMode = .off
        player.shuffleEnabled = false
        defer {
            player.stop()
            appleMusic.stopAppleMusic()
            player.repeatMode = savedRepeatMode
            player.shuffleEnabled = savedShuffle
            UIApplication.shared.isIdleTimerDisabled = savedIdleTimer
        }
        player.setQueue(songs, startAt: 2)
        let entryIDs = player.queueEntries.map(\.id)
        await player.play(song: songs[2])
        func matches(_ index: Int) -> Bool {
            player.currentIndex == index && player.currentSong?.id == songs[index].id
                && appleMusic.nowPlayingQueueEntryID == entryIDs[index]
                && player.isPlaying && player.currentTime > 0.5
        }
        let selected = await waitUntil(timeout: 25) { matches(2) }
        XCTAssertTrue(selected, "Primuse must keep the selected duplicate while MusicKit resolves its queue.")
        try await ApplicationMusicPlayer.shared.skipToNextEntry()
        let nativeNext = await waitUntil { matches(3) }
        XCTAssertTrue(nativeNext, "A native skip must update Primuse's index and displayed song together.")
        let previousRequested = await player.previous(restartsCurrentFirst: false)
        let previous = await waitUntil { matches(2) }
        XCTAssertTrue(previousRequested && previous, "Primuse previous must return to the second occurrence.")
        let nextRequested = await player.next()
        let next = await waitUntil { matches(3) }
        XCTAssertTrue(nextRequested && next, "Primuse next must follow the selected occurrence.")
        XCTAssertEqual(player.queueEntries.map(\.id), entryIDs)
        try writeResults([["selectedDuplicate": selected, "nativeNextMirrored": nativeNext,
                           "primusePrevious": previousRequested && previous,
                           "primuseNext": nextRequested && next,
                           "queuePreserved": player.queueEntries.map(\.id) == entryIDs]],
                         name: "apple-music-player-queue", root: root)
    }

    @MainActor
    func testAppleMusicPlaybackOnPhysicalDevice() async throws {
        let root = try fixtureDirectory()
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        let services = AppServices.shared
        let appleMusic = services.appleMusic
        let player = services.playerService
        let auth = MusicAuthorization.currentStatus
        var results: [[String: Any]] = [["authorization": String(describing: auth),
                                       "syncEnabled": AppleMusicFeatureSettings.syncUserLibraryEnabled]]
        try writeResults(results, name: "apple-music", root: root)
        guard auth == .authorized else { throw XCTSkip("Apple Music access is not authorized on this device.") }
        let subscription = try await MusicSubscription.current
        results.append(["canPlayCatalogContent": subscription.canPlayCatalogContent,
                        "canBecomeSubscriber": subscription.canBecomeSubscriber])
        try writeResults(results, name: "apple-music", root: root)
        guard subscription.canPlayCatalogContent else { throw XCTSkip("This device has no catalog playback entitlement.") }

        var request = MusicLibraryRequest<MusicKit.Song>()
        request.limit = 50
        let response = try await request.response()
        var downloadRequest = MusicLibraryRequest<MusicKit.Song>()
        downloadRequest.limit = 5000
        downloadRequest.includeOnlyDownloadedContent = true
        let downloaded = try await downloadRequest.response()
        let downloadIDs = Set(downloaded.items.map(\.id))
        results.append(["librarySampleCount": response.items.count, "downloadedSampleCount": downloaded.items.count,
                        "downloadedListComplete": downloaded.items.count < downloadRequest.limit])

        var candidates = Array(downloaded.items.prefix(2))
        candidates += response.items.filter { !downloadIDs.contains($0.id) }.prefix(4)
        var catalogIDs = Set<MusicItemID>()
        for term in ["晴天 周杰伦", "Take Five Dave Brubeck", "Beethoven Symphony No. 5", "Billie Jean Michael Jackson"] {
            var search = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
            search.limit = 3
            let matches = try await search.response()
            if let song = matches.songs.first, !candidates.contains(where: { $0.id == song.id }) {
                candidates.append(song)
                catalogIDs.insert(song.id)
            }
        }
        XCTAssertFalse(candidates.isEmpty, "No authorized library songs available for playback.")

        let originalSessionURL = PlaybackSessionStore().url
        let originalSession = try? Data(contentsOf: originalSessionURL)
        player.pause()
        defer {
            player.pause()
            appleMusic.stopAppleMusic()
            if let originalSession { try? originalSession.write(to: originalSessionURL, options: .atomic) }
        }

        for candidate in candidates {
            appleMusic.stopAppleMusic()
            let item = (try? await candidate.with([.audioVariants])) ?? candidate
            let primuseSong = AppleMusicLibraryService.toPrimuseSong(item)
            let cached = catalogIDs.contains(item.id) ? nil : await services.appleMusicLibrary.musicKitSong(amID: item.id.rawValue)
            let canUseLibraryRoute = !catalogIDs.contains(item.id) && AppleMusicFeatureSettings.syncUserLibraryEnabled && cached != nil
                && !services.musicLibrary.disabledSourceIDs.contains(AppleMusicLibraryService.systemSourceID)
            if canUseLibraryRoute {
                player.setQueue([primuseSong])
                await player.play(song: primuseSong)
            } else {
                await appleMusic.play(item)
            }
            func currentEntrySong() -> MusicKit.Song? {
                if case .song(let song) = ApplicationMusicPlayer.shared.queue.currentEntry?.item { return song }
                return nil
            }
            func identityMatches() -> Bool {
                if let actual = currentEntrySong() {
                    return actual.id == item.id
                        || services.appleMusicLibrary.canonicalForNowPlaying(actual).id == item.id
                        || actual.title == item.title && actual.artistName == item.artistName
                }
                guard let entry = ApplicationMusicPlayer.shared.queue.currentEntry else { return false }
                let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
                return entry.title.trimmingCharacters(in: trim) == item.title.trimmingCharacters(in: trim)
                    && (entry.subtitle?.contains(item.artistName) == true || item.artistName.isEmpty)
            }
            let ready = await waitUntil(timeout: 30) {
                appleMusic.playbackRequestState?.phase == .started
                    && identityMatches() && appleMusic.isAppleMusicPlaying
                    && ApplicationMusicPlayer.shared.state.playbackStatus == .playing
                    && ApplicationMusicPlayer.shared.playbackTime > 0.5
                    || appleMusic.lastPlaybackError != nil
            }
            let initialTime = ApplicationMusicPlayer.shared.playbackTime
            try await Task.sleep(for: .milliseconds(1500))
            let success = ready && identityMatches() && ApplicationMusicPlayer.shared.playbackTime > initialTime + 0.5 && appleMusic.isAppleMusicPlaying
                && ApplicationMusicPlayer.shared.state.playbackStatus == .playing && appleMusic.lastPlaybackError == nil
            XCTAssertTrue(success, "Apple Music \(item.id): \(appleMusic.lastPlaybackError ?? "no progress")")
            var row: [String: Any] = ["id": item.id.rawValue, "title": item.title, "success": success,
                "downloaded": downloadIDs.contains(item.id), "time": appleMusic.currentPlaybackTime,
                "declaredDuration": item.duration ?? 0, "playbackDuration": appleMusic.currentDuration,
                "actualID": currentEntrySong()?.id.rawValue ?? "", "actualTitle": currentEntrySong()?.title ?? "",
                "entryTitle": ApplicationMusicPlayer.shared.queue.currentEntry?.title ?? "",
                "entrySubtitle": ApplicationMusicPlayer.shared.queue.currentEntry?.subtitle ?? "",
                "initialTime": initialTime, "actualTime": ApplicationMusicPlayer.shared.playbackTime,
                "catalogSearchResult": catalogIDs.contains(item.id),
                "variantsAvailable": item.audioVariants?.map { String(describing: $0) } ?? [],
                "route": canUseLibraryRoute ? "primuse-library" : "catalog",
                "error": appleMusic.lastPlaybackError ?? ""]
            if success {
                XCTAssertTrue(appleMusic.pauseAppleMusic())
                let paused = await waitUntil { ApplicationMusicPlayer.shared.state.playbackStatus == .paused }
                XCTAssertTrue(paused)
                XCTAssertTrue(appleMusic.resumeAppleMusic())
                let resumed = await waitUntil { appleMusic.isAppleMusicPlaying && ApplicationMusicPlayer.shared.state.playbackStatus == .playing }
                XCTAssertTrue(resumed)
                let duration = appleMusic.currentDuration > 0 ? appleMusic.currentDuration : (item.duration ?? 60)
                let target = min(20, duration * 0.4)
                appleMusic.seekAppleMusic(to: target)
                let sought = await waitUntil { appleMusic.currentPlaybackTime >= target + 0.5 && appleMusic.isAppleMusicPlaying }
                XCTAssertTrue(sought)
                row["pauseResumeAndSeek"] = sought
            }
            _ = appleMusic.pauseAppleMusic()
            results.append(row)
            try writeResults(results, name: "apple-music", root: root)
        }
    }
}
