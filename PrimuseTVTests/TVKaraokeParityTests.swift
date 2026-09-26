#if os(tvOS)
import AVFoundation
import Network
import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import PrimuseTV

@MainActor
final class TVKaraokeParityTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let directory: URL
        let defaultsName = "TVKaraokeParityTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let library: MusicLibrary
        let store: TVStore
        let original: Song
        let backing: Song
        let other: Song
        let session: TVKaraokeSession

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: defaultsName)!
            let sources = SourcesStore(storageDirectoryURL: directory)
            let source = MusicSource(id: UUID().uuidString, name: "Fixture", type: .local)
            try sources.addDurably(source)
            original = Song(id: UUID().uuidString, title: "月光练习曲", artistName: "Primuse",
                            duration: 20, fileFormat: .wav, filePath: "/Moon.wav", sourceID: source.id)
            backing = Song(id: UUID().uuidString, title: "月光练习曲 (Instrumental)", artistName: "Primuse",
                           duration: 20, fileFormat: .wav, filePath: "/Moon instrumental.wav", sourceID: source.id)
            other = Song(id: UUID().uuidString, title: "Next", duration: 20, fileFormat: .wav,
                         filePath: "/Next.wav", sourceID: source.id)
            library = MusicLibrary(storageDirectory: directory)
            library.addSongs([original, backing, other])
            await library.waitForPendingIndex()
            store = TVStore(sourcesStore: sources, library: library, defaults: defaults,
                            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
            store.reload()
            session = TVKaraokeSession(store: store, defaults: defaults)
        }

        func begin(backingTrack: Bool = false) async throws {
            XCTAssertTrue(store.playResolvedQueue(songIDs: [original.id, backing.id, other.id], shuffled: false,
                                                   startingAt: backingTrack ? backing.id : original.id))
            // The fixture's local source has no transport. Keep the playback selection,
            // while the integration tests install their own deterministic audio below.
            try await Task.sleep(for: .milliseconds(100))
            store.engine.stop()
            store.engine.prepareForSelection(startAt: 3)
            store.playbackIssue = .unsupported("fixture")
            store.lyrics = [
                TVLyricLine(time: 1, text: "月光照亮长长的路", syllables: [], translation: ""),
                TVLyricLine(time: 7, text: "我们把歌唱到天明", syllables: [], translation: ""),
                TVLyricLine(time: 14, text: "再唱一次", syllables: [], translation: "")
            ]
            session.start()
            try await Task.sleep(for: .milliseconds(250))
        }

        func cleanup() async {
            session.stop()
            store.engine.stop()
            _ = await library.persistNowAndWait()
            defaults.removePersistentDomain(forName: defaultsName)
            for song in [original, backing, other] {
                let assets = MetadataAssetStore.shared
                try? FileManager.default.removeItem(at: assets.lyricsDirectoryURL.appendingPathComponent(assets.expectedLyricsFileName(for: song.id)))
            }
            // SQLite connections remain owned by the fixture until it is released.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("silence.caf"))
        }
    }

    func testCompanionSwitchPreservesPositionLyricsAndQueue() async throws {
        let f = try await Fixture()
        try await f.begin()
        XCTAssertEqual(f.session.instrumentalCompanion?.id, f.backing.id)
        let lines = f.session.stageLines
        f.session.toggleBackingTrack()
        XCTAssertEqual(f.store.currentSongID, f.backing.id)
        XCTAssertEqual(f.store.currentTime, 3, accuracy: 0.2)
        XCTAssertFalse(f.store.isPlaying)
        XCTAssertEqual(f.session.stageLines, lines)
        XCTAssertTrue(f.session.isPlayingInstrumental)
        XCTAssertEqual(f.store.queueSongIDs, [f.backing.id, f.backing.id, f.other.id])
        f.store.playbackIssue = .unsupported("fixture")
        f.session.toggleBackingTrack()
        XCTAssertEqual(f.store.currentSongID, f.original.id)
        XCTAssertEqual(f.store.queueSongIDs, [f.original.id, f.backing.id, f.other.id])
        XCTAssertFalse(f.session.isPlayingInstrumental)
        await f.cleanup()
    }

    func testDirectBackingTrackBorrowsOriginalLyricsWithoutOverwritingBackingCache() async throws {
        let f = try await Fixture()
        let lyrics = [LyricLine(timestamp: 2, text: "Original lyric", isSynchronized: true)]
        _ = await MetadataAssetStore.shared.cacheLyrics(lyrics, forSongID: f.original.id, force: true)
        try await f.begin(backingTrack: true)
        XCTAssertEqual(f.session.lyricsBorrowedFromTitle, f.original.title)
        XCTAssertEqual(f.session.stageLines.first?.text, "Original lyric")
        let backingLyrics = await MetadataAssetStore.shared.cachedLyrics(forSongID: f.backing.id)
        XCTAssertNil(backingLyrics)
        await f.cleanup()
    }

    func testPracticeLoopExtendsAndStopRestoresRate() async throws {
        let f = try await Fixture()
        try await f.begin()
        f.session.practiceRate = 0.7
        f.session.toggleLoop()
        XCTAssertEqual(f.session.loop?.firstWindow, 0)
        f.session.extendLoop()
        XCTAssertEqual(f.session.loop?.lineCount, 2)
        XCTAssertTrue(f.session.isPracticing)
        XCTAssertEqual(f.store.engine.karaokePracticeRate, 0.7)
        f.session.stop()
        XCTAssertEqual(f.store.engine.karaokePracticeRate, 1)
        XCTAssertNil(f.store.engine.karaokeLoopStartAtEnd)
        XCTAssertNil(f.session.loop)
        await f.cleanup()
    }

    func testTrackChangeClearsLoopAndOldLyrics() async throws {
        let f = try await Fixture()
        try await f.begin()
        f.session.toggleLoop()
        f.store.next()
        f.store.next()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(f.store.currentSongID, f.other.id)
        XCTAssertNil(f.session.loop)
        XCTAssertTrue(f.session.stageLines.isEmpty)
        XCTAssertNil(f.session.lyricsBorrowedFromTitle)
        await f.cleanup()
    }

    func testPracticeRateClampsInvalidValuesWithoutRecursion() async throws {
        let f = try await Fixture()
        try await f.begin()
        f.session.practiceRate = .nan
        XCTAssertEqual(f.session.practiceRate, 1)
        f.session.practiceRate = -2
        XCTAssertEqual(f.session.practiceRate, 0.5)
        f.session.practiceRate = 2
        XCTAssertEqual(f.session.practiceRate, 1)
        await f.cleanup()
    }

    func testPhoneStemUsesOnsetsAndKeepsAuthoredWordTiming() async throws {
        let f = try await Fixture()
        try await f.begin()
        let rate = 44_100.0
        let samples = (0..<Int(rate * 18)).map { index -> Float in
            let time = Double(index) / rate
            let pulse = time.truncatingRemainder(dividingBy: 0.65)
            return pulse < 0.18 ? Float(sin(2 * .pi * 440 * time) * 0.4) : 0
        }
        let stem = KaraokeStemFile.encode(left: samples, right: samples, sampleRate: rate)
        f.session.micServer.onStem?(f.original.id, stem)
        for _ in 0..<150 {
            if f.session.usesInferredWordTiming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(f.session.usesPhoneStem)
        XCTAssertTrue(f.session.usesInferredWordTiming)
        XCTAssertGreaterThan(f.session.stageLines.first?.syllables?.count ?? 0, 1)
        let authored = TVLyricLine(time: 1, text: "a b", syllables: [
            TVSyllable(w: "a ", start: 1, end: 2), TVSyllable(w: "b", start: 2, end: 3)
        ], translation: "")
        f.store.lyrics = [authored]
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(f.session.stageLines.first?.syllables?.map(\.start), [1, 2])
        XCTAssertFalse(f.session.usesInferredWordTiming)
        await f.cleanup()
    }

    func testSlowedClockAndNaturalEndStayInsideLoop() async throws {
        let f = try await Fixture()
        try await f.begin()
        let file = f.directory.appendingPathComponent("silence.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let audio = try AVAudioFile(forWriting: file, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = 88_200
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 88_200) }
        try audio.write(from: buffer)
        f.store.engine.load(url: file, title: "Silence", artist: "", album: "", duration: 2,
                            cueStartTime: 0, cueEndTime: 1.5)
        f.store.lyrics = [TVLyricLine(time: 0, text: "Loop", syllables: [], translation: "")]
        f.session.practiceRate = 0.5
        f.store.engine.play()
        try await Task.sleep(for: .milliseconds(350))
        f.session.toggleLoop()
        let anchor = f.store.engine.currentTimeAnchor
        let advanced = f.store.engine.interpolatedTime(at: anchor.addingTimeInterval(0.2)) - f.store.currentTime
        XCTAssertEqual(advanced, 0.1, accuracy: 0.025)
        let songID = f.store.currentSongID
        try await Task.sleep(for: .seconds(3.5))
        XCTAssertEqual(f.store.currentSongID, songID)
        XCTAssertTrue(f.store.isPlaying)
        XCTAssertNotNil(f.session.loop)
        await f.cleanup()
    }

    func testBackingTrackBypassesVocalProcessing() throws {
        let processor = TVKaraokeProcessor()
        let renderer = TVKaraokeTapRenderer(processor: processor)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        buffer.frameLength = 4_096
        let left = (0..<4_096).map { Float(sin(Double($0) * 0.17) * 0.3) }
        let right = (0..<4_096).map { Float(cos(Double($0) * 0.23) * 0.2) }
        left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
        renderer.configure(format: format.streamDescription.pointee, maxFrames: 4_096)
        processor.update(.init(isActive: true, reduction: 1, bypassesVocalReduction: true))
        renderer.process(bufferList: buffer.mutableAudioBufferList, frameCount: 4_096, startOfStream: true, sourceTime: 0)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 4_096)), left)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: 4_096)), right)
        XCTAssertFalse(processor.isProcessing)
    }

    func testPhoneSilenceEngagesAssistAndVoiceOrStaleLinkStandsDown() async throws {
        let f = try await Fixture()
        try await f.begin()
        let file = f.directory.appendingPathComponent("silence.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        do {
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 882_000))
            buffer.frameLength = 882_000
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 882_000) }
            try audio.write(from: buffer)
        }
        f.store.engine.load(url: file, title: "Silence", artist: "", album: "", duration: 20)
        f.store.engine.play()
        let endpoint = try XCTUnwrap(f.session.micServer.endpoint)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "TVKaraokeParityTests.phone"))
        defer { connection.cancel() }
        func send(_ message: KaraokeMicLink.PhoneMessage) {
            connection.send(content: KaraokeMicLink.encode(message), completion: .idempotent)
        }
        send(.hello(version: KaraokeMicLink.protocolVersion, key: endpoint.key, deviceName: "Fixture Phone"))
        for _ in 0..<80 {
            if f.session.isMicConnected && f.session.isVocalReductionAvailable { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(f.session.isMicConnected)
        XCTAssertTrue(f.session.isVocalReductionAvailable)
        for index in 0..<68 {
            send(.reading(sequence: index, midiNote: nil))
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(f.session.isVocalAssisting)
        send(.reading(sequence: 68, midiNote: 67))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(f.session.isVocalAssisting)
        for index in 69..<112 {
            send(.reading(sequence: index, midiNote: nil))
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(f.session.isVocalAssisting)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(f.session.isMicConnected)
        XCTAssertFalse(f.session.isVocalAssisting)
        await f.cleanup()
    }

    func testStageFitsTVViewport() async throws {
        let f = try await Fixture()
        try await f.begin()
        let host = UIHostingController(rootView: TVKaraokeStageContent(session: f.session)
            .environment(f.store).environment(TVThemeState.shared).environment(TVAppearanceState())
            .preferredColorScheme(.dark).background(Color(red: 0.06, green: 0.09, blue: 0.16)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.width, 1000)
        let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let screenshotURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVKaraokeStage-validation.png")
        try screenshot.pngData()?.write(to: screenshotURL)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "TVKaraokeStage"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        previous?.makeKeyAndVisible()
        await f.cleanup()
    }
}
#endif
