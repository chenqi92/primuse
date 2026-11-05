import AVFoundation
import PrimuseKit
import XCTest
@testable import Primuse

final class ReplayGainPlaybackTests: XCTestCase {
    @MainActor func testLateAnalysisDoesNotChangeCurrentPlaybackOrSeekButNextStartUsesIt() async throws {
        let suite = "replaygain-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettingsStore(defaults: defaults, cloudSync: CloudKVSSync(store: nil, defaults: defaults, observing: nil))
        settings.replayGainEnabled = true
        settings.replayGainMode = .track
        let sessionURL = FileManager.default.temporaryDirectory.appendingPathComponent("replaygain-session-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        let player = AudioPlayerService(playbackSettings: settings, playbackSessionStore: PlaybackSessionStore(url: sessionURL))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replaygain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url)
        let song = Song(id: UUID().uuidString, title: "Stable", duration: 3, fileFormat: .wav, filePath: url.path, sourceID: "test")
        player.currentSong = song
        player.playID = UUID()
        let opening = await player.targetProgramVolume(for: song, url: url, allowFileRead: true)
        XCTAssertEqual(opening, 1)
        XCTAssertFalse(player.replayGainPlaybackInfo.isActive)
        _ = try await ReplayGainAnalysisService.shared.analyze(song, url: url)
        player.playID = UUID() // A seek rebuilds the transport, not the selection.
        await player.applyReplayGain(for: song, url: url, mode: .track)
        XCTAssertEqual(player.audioEngine.primaryProgramVolume, opening)
        XCTAssertFalse(player.replayGainPlaybackInfo.isActive)
        XCTAssertNil(player.replayGainPlaybackInfo.appliedGainDB)
        let status = await ReplayGainAnalysisService.shared.status(for: song)
        XCTAssertEqual(status, .cached)
        let afterQueueRefill = await player.resolveReplayGainValues(for: song, url: url, mode: .album, allowFileRead: true)
        XCTAssertEqual(player.programVolume(for: afterQueueRefill), opening)
        player.retainReplayGainSnapshot(for: nil)
        let replay = await player.targetProgramVolume(for: song, url: url, allowFileRead: true)
        XCTAssertLessThan(replay, opening)
        XCTAssertTrue(player.replayGainPlaybackInfo.isActive)
        XCTAssertEqual(player.replayGainPlaybackInfo.snapshot?.origin, .analysis)
        let measured = await ReplayGainAnalysisService.cachedAdjustment(for: song, mode: .track, album: [])
        XCTAssertEqual(replay, ReplayGainPolicy.linearGain(gainDB: measured.gain, peak: measured.peak), accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(player.replayGainPlaybackInfo.appliedGainDB), 20 * log10(Double(replay)), accuracy: 0.0001)
    }

    @MainActor func testAlbumModeShowsTrackWhenOnlyTrackTagsAreAvailable() async throws {
        let suite = "replaygain-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettingsStore(defaults: defaults, cloudSync: CloudKVSSync(store: nil, defaults: defaults, observing: nil))
        settings.replayGainEnabled = true
        settings.replayGainMode = .album
        let sessionURL = FileManager.default.temporaryDirectory.appendingPathComponent("replaygain-session-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        let player = AudioPlayerService(playbackSettings: settings, playbackSessionStore: PlaybackSessionStore(url: sessionURL))
        var song = Song(id: UUID().uuidString, title: "Tagged", duration: 3, fileFormat: .flac, filePath: "tagged.flac", sourceID: "test")
        song.replayGainTrackGain = -6
        player.currentSong = song
        _ = await player.targetProgramVolume(for: song, url: URL(fileURLWithPath: "/unused.flac"), allowFileRead: false)
        XCTAssertEqual(player.replayGainPlaybackInfo.snapshot?.mode, .track)
        XCTAssertEqual(player.replayGainPlaybackInfo.snapshot?.origin, .tags)
        XCTAssertEqual(try XCTUnwrap(player.replayGainPlaybackInfo.appliedGainDB), -6, accuracy: 0.001)
        settings.outputMode = .highFidelity
        XCTAssertFalse(player.replayGainPlaybackInfo.isActive)
        XCTAssertFalse(player.replayGainPlaybackInfo.showsBadge)
    }

    @MainActor func testPreparationCachesUpcomingTracksAndDoesNotReadThemAgain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replaygain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url)
        let songs = (0..<2).map { Song(id: UUID().uuidString, title: "Upcoming \($0)", duration: 3,
                                      fileFormat: .wav, filePath: url.path, sourceID: "test") }
        var reads = [String]()
        let files = Dictionary(uniqueKeysWithValues: songs.map { (ReplayGainAnalysisCache.key(for: $0), url) })
        for _ in 0..<2 {
            try await ReplayGainAnalysisService.shared.prepare(songs, knownFiles: files) { song in
                reads.append(song.id)
                let status = await ReplayGainAnalysisService.shared.status(for: song)
                XCTAssertEqual(status, .queued)
                return KaraokeAudioFile(url: url)
            }
        }
        XCTAssertEqual(reads, songs.map(\.id))
        for song in songs {
            let cached = await ReplayGainAnalysisService.cachedAdjustment(for: song, mode: .track, album: [])
            XCTAssertTrue(cached.hasValue)
        }
    }

    func testExistingSettingsKeepModeAndNewPreampRoundTrips() throws {
        let old = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{\"replayGainEnabled\":true,\"replayGainMode\":\"album\"}".utf8))
        XCTAssertTrue(old.replayGainEnabled)
        XCTAssertEqual(old.replayGainMode, .album)
        XCTAssertEqual(old.replayGainPreampDB, 0)
        let settings = PlaybackSettings(replayGainEnabled: true, replayGainMode: .automatic, replayGainPreampDB: 4.5)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(PlaybackSettings(replayGainPreampDB: .infinity).replayGainPreampDB, 0)
    }

    func testWholeFileAndCUESegmentAnalysisLeaveAudioUnchanged() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replaygain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url)
        let original = try Data(contentsOf: url)
        var song = Song(id: UUID().uuidString, title: "Analysis", duration: 3, fileFormat: .wav, filePath: url.path, sourceID: "test")
        let full = try await ReplayGainFileAnalyzer.analyze(url: url, song: song)
        XCTAssertEqual(full.duration, 3, accuracy: 0.01)
        XCTAssertEqual(full.peak, 0.2, accuracy: 0.001)
        song.cueStartTime = 1
        song.cueEndTime = 2
        let segment = try await ReplayGainFileAnalyzer.analyze(url: url, song: song)
        XCTAssertEqual(segment.duration, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(segment.integratedLUFS), -13.98, accuracy: 0.1)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCancelledAnalysisDoesNotPublishAPartialMeasurement() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replaygain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url)
        let song = Song(id: UUID().uuidString, title: "Cancel", duration: 3, fileFormat: .wav, filePath: url.path, sourceID: "test")
        let task = Task { try await ReplayGainAnalysisService.shared.analyze(song, url: url) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled analysis completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cached = await ReplayGainAnalysisCache.shared.measurement(for: song)
        XCTAssertNil(cached)
    }

    func testPlayerNodeAppliesPositiveGainToPCMOffline() throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        engine.attach(node)
        // crash-pattern: allow avaudioengine-connect 离线图使用上方已验证的 PCM 格式。
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        input.frameLength = 1024
        for channel in 0..<2 {
            for frame in 0..<1024 { input.floatChannelData![channel][frame] = 0.1 }
        }
        node.volume = ReplayGainPolicy.linearGain(gainDB: 6.0206, peak: 0.1)
        node.scheduleBuffer(input)
        try engine.start()
        defer { node.stop(); engine.stop() }
        // crash-pattern: allow audio-player-node-play 离线图已连接且 engine.start() 成功, 无设备路由变更。
        node.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        XCTAssertEqual(try engine.renderOffline(1024, to: output), .success)
        let peak = (0..<Int(output.frameLength)).map { abs(output.floatChannelData![0][$0]) }.max() ?? 0
        XCTAssertEqual(peak, 0.2, accuracy: 0.001)
    }

    private func writeFixture(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000))
        buffer.frameLength = 144000
        for channel in 0..<2 {
            for frame in 0..<144000 {
                let amplitude = frame < 48000 ? 0.05 : 0.2
                buffer.floatChannelData![channel][frame] = Float(amplitude * sin(2 * .pi * 1000 * Double(frame) / 48000))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
