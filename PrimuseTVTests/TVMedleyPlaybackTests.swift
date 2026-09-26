#if os(tvOS)
import AVFoundation
import MediaPlayer
import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import PrimuseTV

@MainActor
final class TVMedleyPlaybackTests: XCTestCase {
    @MainActor private final class Fixture {
        let directory: URL
        let defaults: UserDefaults
        let defaultsName = "TVMedleyTests.\(UUID().uuidString)"
        let library: MusicLibrary
        let store: TVStore
        let songs: [Song]
        let audioURLs: [URL]

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: defaultsName)!
            let sources = SourcesStore(storageDirectoryURL: directory)
            var source = MusicSource(id: TVLocalTransferSource.sourceID, name: "Medley fixture", type: .local)
            source.basePath = TVLocalTransferSource.root.path
            try sources.addDurably(source)
            try FileManager.default.createDirectory(at: TVLocalTransferSource.root, withIntermediateDirectories: true)
            var items: [Song] = []
            var urls: [URL] = []
            let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<3 {
                let filename = "medley-\(UUID().uuidString).wav"
                let url = TVLocalTransferSource.root.appendingPathComponent(filename)
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
                urls.append(url)
                items.append(Song(id: UUID().uuidString, title: "串烧测试 \(index + 1)", artistName: "Primuse",
                                  duration: 60, fileFormat: .wav, filePath: "/\(filename)", sourceID: source.id))
            }
            songs = items
            audioURLs = urls
            library = MusicLibrary(storageDirectory: directory)
            library.addSongs(items)
            await library.waitForPendingIndex()
            store = TVStore(sourcesStore: sources, library: library, defaults: defaults,
                            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
            store.reload()
        }

        func cleanup() async {
            store.engine.stop()
            _ = await library.persistNowAndWait()
            defaults.removePersistentDomain(forName: defaultsName)
            for url in audioURLs { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func waitUntil(_ message: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), message)
    }

    func testDefaultChoicePersistenceAndQueueFiltering() async throws {
        let f = try await Fixture()
        XCTAssertEqual(f.store.medleySegmentSeconds, 10)
        f.store.setMedleySegmentSeconds(45)
        XCTAssertEqual(f.defaults.integer(forKey: "tv.medley.segmentSeconds"), 45)
        f.store.setMedleySegmentSeconds(10)
        var cue = f.songs[0]
        cue.id = UUID().uuidString
        cue.filePath = "/cue-fixture.wav"
        cue.cueStartTime = 10
        cue.cueEndTime = 20
        cue.cueSheetPath = "/album.cue"
        var video = f.songs[0]
        video.id = UUID().uuidString
        video.filePath = "/video-fixture.wav"
        video.mvPath = "/movie.mp4"
        f.library.addSongs([cue, video], pruneMissingSongs: false)
        await f.library.waitForPendingIndex()
        f.store.reload()
        XCTAssertTrue(f.store.playMedley(songIDs: [cue.id, f.songs[0].id, f.songs[0].id, video.id, f.songs[1].id]))
        XCTAssertEqual(f.store.queueSongIDs, [f.songs[0].id, f.songs[1].id])
        XCTAssertEqual(f.store.duration, 10)
        XCTAssertEqual(f.library.song(id: f.songs[0].id)?.duration, 60)
        XCTAssertNil(f.library.song(id: f.songs[0].id)?.cueStartTime)
        await f.cleanup()
    }

    func testNativePlaybackCrossfadesAndKeepsPreparedMetadataPrivate() async throws {
        let f = try await Fixture()
        XCTAssertTrue(f.store.playMedley(songIDs: f.songs.map(\.id)))
        try await waitUntil("First slice must start") { f.store.isPlaying }
        let began = Date()
        XCTAssertEqual(f.store.currentSongID, f.songs[0].id)
        XCTAssertEqual(f.store.duration, 10, accuracy: 0.1)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(f.store.currentSongID, f.songs[0].id)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, f.songs[0].title)
        try await waitUntil("The second slice must enter before the first reaches ten seconds", seconds: 10) {
            f.store.currentSongID == f.songs[1].id
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 9.8)
        XCTAssertTrue(f.store.isPlaying)
        XCTAssertLessThan(f.store.currentTime, 1)
        XCTAssertEqual(f.store.queueUpNextIDs, [f.songs[2].id])
        f.store.togglePlayPause()
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        let paused = f.store.currentTime
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(f.store.isPlaying)
        XCTAssertEqual(f.store.currentTime, paused, accuracy: 0.3)
        f.store.togglePlayPause()
        try await waitUntil("Resume must restart both fading decks") { f.store.isPlaying }
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertFalse(f.library.recentlyPlayedSongs().contains { $0.id == f.songs[0].id })
        await f.cleanup()
    }

    func testSeekingAndContinuingFullSongPreservesAbsolutePositionAndPause() async throws {
        let f = try await Fixture()
        XCTAssertTrue(f.store.playMedley(songIDs: f.songs.map(\.id)))
        try await waitUntil("Slice ready") { f.store.isPlaying }
        f.store.togglePlayPause()
        f.store.seek(toFraction: 0.4)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(f.store.currentTime, 4, accuracy: 0.3)
        f.store.continueCurrentMedleySongInFull()
        XCTAssertFalse(f.store.isMedleyActive)
        try await waitUntil("Full song ready") { f.store.engine.isReadyForPreparedPlayback }
        XCTAssertFalse(f.store.isPlaying)
        XCTAssertEqual(f.store.currentTime, 24, accuracy: 0.4)
        XCTAssertEqual(f.store.duration, 60, accuracy: 0.1)
        XCTAssertEqual(f.store.queueSongIDs, f.songs.map(\.id))
        await f.cleanup()
    }

    func testManualNavigationRepeatAndNewQueueExit() async throws {
        let f = try await Fixture()
        XCTAssertTrue(f.store.playMedley(songIDs: f.songs.map(\.id)))
        f.store.next()
        XCTAssertEqual(f.store.currentSongID, f.songs[1].id)
        XCTAssertTrue(f.store.isMedleyActive)
        f.store.previous(restartCurrentIfNeeded: false)
        XCTAssertEqual(f.store.currentSongID, f.songs[0].id)
        f.store.cycleRepeatMode()
        f.store.cycleRepeatMode()
        XCTAssertNotEqual(f.store.repeatMode, .one)
        XCTAssertTrue(f.store.playResolvedQueue(songIDs: [f.songs[2].id], shuffled: false))
        XCTAssertFalse(f.store.isMedleyActive)
        try await waitUntil("Ordinary queue must replace all prepared decks") { f.store.isPlaying }
        XCTAssertEqual(f.store.currentSongID, f.songs[2].id)
        XCTAssertEqual(f.store.duration, 60, accuracy: 0.1)
        await f.cleanup()
    }

    func testDecodedDeckPreparationDoesNotInterruptAudibleDeck() async throws {
        let f = try await Fixture()
        XCTAssertTrue(f.store.playMedley(songIDs: [f.songs[0].id]))
        try await waitUntil("Native deck ready") { f.store.isPlaying }
        let auxiliary = TVAudioEngine(managesSystemPlayback: false)
        auxiliary.setMixVolume(0)
        let decodedURL = f.directory.appendingPathComponent("decoded.wav")
        try FileManager.default.copyItem(at: f.audioURLs[1], to: decodedURL)
        try auxiliary.loadDecoded(fileURL: decodedURL, decoder: .sfbAudioEngine,
                                  title: "Prepared", artist: "", album: "", duration: 10,
                                  cueStartTime: 20, cueEndTime: 30)
        auxiliary.startPlayback(at: 0, autoPlay: false)
        XCTAssertTrue(auxiliary.isReadyForPreparedPlayback)
        XCTAssertEqual(auxiliary.duration, 10, accuracy: 0.1)
        XCTAssertEqual(auxiliary.currentTime, 0, accuracy: 0.1)
        XCTAssertFalse(auxiliary.isPlaying)
        auxiliary.releaseAuxiliaryPlayback()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(f.store.isPlaying)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, f.songs[0].title)
        await f.cleanup()
    }

    func testSystemInterruptionPausesBothDecksUntilResumePermission() async throws {
        let f = try await Fixture()
        XCTAssertTrue(f.store.playMedley(songIDs: f.songs.map(\.id)))
        try await waitUntil("Slice ready") { f.store.isPlaying }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ])
        try await Task.sleep(for: .milliseconds(150))
        let position = f.store.currentTime
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(f.store.isPlaying)
        XCTAssertEqual(f.store.currentTime, position, accuracy: 0.2)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ])
        try await waitUntil("System-approved resume") { f.store.isPlaying }
        await f.cleanup()
    }

    func testEndOfQueueCanRestartAndEndAgain() async throws {
        let f = try await Fixture()
        XCTAssertTrue(f.store.playMedley(songIDs: [f.songs[0].id]))
        try await waitUntil("Slice ready") { f.store.isPlaying }
        f.store.seek(toFraction: 0.95)
        try await waitUntil("Queue should finish", seconds: 3) { !f.store.isPlaying && f.store.currentTime >= 9.9 }
        XCTAssertTrue(f.store.isMedleyActive)
        f.store.togglePlayPause()
        try await waitUntil("Replay should rebuild the finished segment", seconds: 5) {
            f.store.isPlaying && f.store.currentTime < 1
        }
        f.store.seek(toFraction: 0.95)
        try await waitUntil("Replayed queue should also finish", seconds: 3) { !f.store.isPlaying && f.store.currentTime >= 9.9 }
        await f.cleanup()
    }

    func testFailedSuccessorIsSkippedAndLyricsUseSliceTime() async throws {
        let f = try await Fixture()
        var missing = f.songs[0]
        missing.id = UUID().uuidString
        missing.filePath = "/missing-\(UUID().uuidString).wav"
        f.library.addSongs([missing], pruneMissingSongs: false)
        await f.library.waitForPendingIndex()
        f.store.reload()
        XCTAssertTrue(f.store.playMedley(songIDs: [f.songs[0].id, missing.id, f.songs[2].id]))
        try await waitUntil("First slice ready") { f.store.isPlaying }
        f.store.applyLyrics([TVLyricLine(time: 21, text: "歌词", syllables: [TVSyllable(w: "歌", start: 21, end: 22)])],
                            forSongID: f.songs[0].id)
        XCTAssertEqual(f.store.lyrics.first?.time, 1)
        XCTAssertEqual(f.store.lyrics.first?.syllables.first?.start, 1)
        try await waitUntil("Failed successor should be skipped", seconds: 15) { f.store.currentSongID == f.songs[2].id }
        XCTAssertNil(f.store.playbackIssue)
        XCTAssertTrue(f.store.isPlaying)
        await f.cleanup()
    }

    func testAllFailedSongsStopAndCanRetryWhenAvailable() async throws {
        let f = try await Fixture()
        var missing = f.songs[0]
        missing.id = UUID().uuidString
        let filename = "medley-retry-\(UUID().uuidString).wav"
        missing.filePath = "/\(filename)"
        let restoredURL = TVLocalTransferSource.root.appendingPathComponent(filename)
        defer { try? FileManager.default.removeItem(at: restoredURL) }
        f.library.addSongs([missing], pruneMissingSongs: false)
        await f.library.waitForPendingIndex()
        f.store.reload()
        XCTAssertTrue(f.store.playMedley(songIDs: [missing.id]))
        try await waitUntil("Unavailable queue must finish with an error") {
            if case .failed = f.store.engine.status { return true }
            return false
        }
        XCTAssertFalse(f.store.isPlaying)
        XCTAssertNotNil(f.store.playbackIssue)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        try FileManager.default.copyItem(at: f.audioURLs[0], to: restoredURL)
        f.store.togglePlayPause()
        try await waitUntil("Retry must prepare a fresh deck") { f.store.isPlaying }
        XCTAssertNil(f.store.playbackIssue)
        XCTAssertEqual(f.store.currentSongID, missing.id)
        await f.cleanup()
    }

    func testSettingsAndActivePlayerRenderAtTVSize() async throws {
        let f = try await Fixture()
        XCTAssertTrue(f.store.playMedley(songIDs: f.songs.map(\.id)))
        try await waitUntil("Slice ready") { f.store.isPlaying }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let screens: [(String, AnyView)] = [
            ("medley-settings", AnyView(TVMedleySettingsView())),
            ("medley-options", AnyView(TVOptionsView())),
            ("medley-queue", AnyView(TVQueueView())),
            ("medley-player", AnyView(TVNowPlayingView()))
        ]
        for (name, view) in screens {
            let host = UIHostingController(rootView: view.environment(f.store).environment(TVThemeState.shared)
                .environment(TVAppearanceState()).preferredColorScheme(.dark))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(600))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name + ".png")
            try image.pngData()?.write(to: url)
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        window.isHidden = true
        previous?.makeKeyAndVisible()
        await f.cleanup()
    }
}
#endif
