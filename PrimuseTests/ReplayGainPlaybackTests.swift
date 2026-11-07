import AVFoundation
import PrimuseKit
import XCTest
@testable import Primuse
#if os(iOS)
import SwiftUI
import Vision
#endif

final class ReplayGainPlaybackTests: XCTestCase {
    @MainActor func testSpokenWordBypassesTagsCacheAndPreparationAndCancelsPreviousWork() async throws {
        let suite = "replaygain-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettingsStore(defaults: defaults, cloudSync: CloudKVSSync(store: nil, defaults: defaults, observing: nil))
        settings.replayGainEnabled = true
        let sessionURL = FileManager.default.temporaryDirectory.appendingPathComponent("replaygain-session-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: sessionURL) }
        let player = AudioPlayerService(playbackSettings: settings, playbackSessionStore: PlaybackSessionStore(url: sessionURL))
        var book = Song(id: UUID().uuidString, title: "Chapter", duration: 1800,
                        fileFormat: .mp3, filePath: "chapter.mp3", sourceID: "test", genre: "Audiobook")
        book.replayGainTrackGain = -8
        let oldTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        player.replayGainAnalysisTask = oldTask
        player.replayGainAnalysisIdentity = "old-music"
        player.currentSong = book
        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertNil(player.replayGainAnalysisIdentity)
        let url = URL(fileURLWithPath: "/not-opened.mp3")
        let volume = await player.targetProgramVolume(for: book, url: url, allowFileRead: true)
        XCTAssertEqual(volume, 1)
        XCTAssertFalse(player.replayGainPlaybackInfo.showsBadge)
        await player.applyReplayGain(for: book, url: url, mode: .track)
        XCTAssertEqual(player.audioEngine.primaryProgramVolume, 1)
        try await ReplayGainAnalysisService.shared.prepare([book]) { _ in
            XCTFail("Spoken word must not request an audio file")
            return nil
        }
        let status = await ReplayGainAnalysisService.shared.status(for: book)
        XCTAssertEqual(status, .unavailable)
    }

    func testAnalysisBudgetPacesWorkAndCancellationInterruptsTheWait() throws {
        let budget = ReplayGainAnalysisBudget()
        budget.beginWork()
        let start = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 0.02)
        try budget.pace()
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.12)

        let waiting = expectation(description: "Budget wait interrupted")
        DispatchQueue.global(qos: .utility).async {
            budget.beginWork()
            Thread.sleep(forTimeInterval: 0.1)
            do { try budget.pace(); XCTFail("Cancelled budget completed") }
            catch { XCTAssertTrue(error is CancellationError) }
            waiting.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.15)
        budget.cancel()
        wait(for: [waiting], timeout: 0.3)
    }

    @MainActor func testBadgePreferenceIsIndependentOfAudioInfoAndReplayGain() throws {
        let suite = "replaygain-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let playback = PlaybackSettingsStore(defaults: defaults, cloudSync: CloudKVSSync(store: nil, defaults: defaults, observing: nil))
        playback.replayGainEnabled = true
        defaults.set(NowPlayingAudioInfoMode.off.rawValue, forKey: PlayerAppearancePreferences.audioInfoModeKey)
        let service = SettingsActionService(playback: playback, defaults: defaults)
        let id = "appearance.replayGainBadge"
        XCTAssertNotNil(SettingsCatalog.byID[id])
        XCTAssertTrue(SettingsCatalog.search("ReplayGain").contains { $0.id == id })
        XCTAssertTrue(InterfaceLayoutSync.keys.contains(PlayerAppearancePreferences.showsReplayGainBadgeKey))
        XCTAssertEqual(service.booleanValue(for: id), true)
        try service.setEnabled(false, for: id)
        XCTAssertEqual(service.booleanValue(for: id), false)
        XCTAssertTrue(playback.replayGainEnabled)
        XCTAssertEqual(defaults.string(forKey: PlayerAppearancePreferences.audioInfoModeKey), NowPlayingAudioInfoMode.off.rawValue)
        let restored = SettingsActionService(playback: playback, defaults: defaults)
        try restored.setEnabled(true, for: id)
        XCTAssertEqual(service.booleanValue(for: id), true)
        XCTAssertTrue(playback.replayGainEnabled)
    }

    @MainActor func testFailedPreparationDoesNotLeaveLoadingStatus() async throws {
        let song = Song(id: UUID().uuidString, title: "Unavailable", duration: 3, fileFormat: .flac, filePath: "missing.flac", sourceID: "test")
        let info = ReplayGainPlaybackInfo(enabled: true)
        try await ReplayGainAnalysisService.shared.prepare([song]) { song in
            let status = await ReplayGainAnalysisService.shared.status(for: song)
            XCTAssertTrue(info.displayState(analysis: status).isLoading)
            throw CocoaError(.fileNoSuchFile)
        }
        let status = await ReplayGainAnalysisService.shared.status(for: song)
        XCTAssertEqual(info.displayState(analysis: status), .original)
        XCTAssertFalse(info.displayState(analysis: status).isLoading)
    }

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
                XCTAssertTrue(ReplayGainPlaybackInfo(enabled: true).displayState(analysis: status).isLoading)
                return KaraokeAudioFile(url: url)
            }
        }
        XCTAssertEqual(reads, songs.map(\.id))
        for song in songs {
            let cached = await ReplayGainAnalysisService.cachedAdjustment(for: song, mode: .track, album: [])
            XCTAssertTrue(cached.hasValue)
            let status = await ReplayGainAnalysisService.shared.status(for: song)
            XCTAssertEqual(ReplayGainPlaybackInfo(enabled: true).displayState(analysis: status), .cached)
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

    func testRunningAnalysisCancelsPromptlyWithoutCachingPartialAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replaygain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url, seconds: 15)
        let song = Song(id: UUID().uuidString, title: "Running cancellation", duration: 15,
                        fileFormat: .wav, filePath: url.path, sourceID: "test")
        let task = Task { try await ReplayGainAnalysisService.shared.analyze(song, url: url) }
        defer { task.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while await ReplayGainAnalysisService.shared.status(for: song) != .analyzing,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let status = await ReplayGainAnalysisService.shared.status(for: song)
        XCTAssertEqual(status, .analyzing)
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("Running analysis ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 1)
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

    private func writeFixture(to url: URL, seconds: Int = 3) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let frames = 48000 * seconds
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for frame in 0..<frames {
                let amplitude = frame < 48000 ? 0.05 : 0.2
                buffer.floatChannelData![channel][frame] = Float(amplitude * sin(2 * .pi * 1000 * Double(frame) / 48000))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

#if os(iOS)
@MainActor
final class NowPlayingAudioTagRenderingTests: XCTestCase {
    func testStandardAudioTagSurvivesTrackChangesWithAndWithoutArtwork() async throws {
        try await withHost { host in
            for (index, format) in [AudioFormat.flac, .dts, .aac, .mp3, .dts].enumerated() {
                var song = self.song(format: format, id: String(index))
                song.coverArtFileName = index.isMultiple(of: 2) ? nil : "cover.jpg"
                host.rootView = Harness(song: song)
                let text = try await self.visibleText(in: host)
                XCTAssertTrue(text.contains("RG"), text)
                if format == .flac {
                    XCTAssertTrue(text.contains("16/44.1"), text)
                } else {
                    XCTAssertTrue(text.contains(format.displayName), text)
                    XCTAssertTrue(text.contains("4234"), text)
                }
            }
        }
    }

    func testAudioTagRemainsVisibleWhenReplayGainArrivesLater() async throws {
        try await withHost { host in
            let song = self.song(format: .dts)
            host.rootView = Harness(song: song, replayGain: .init(enabled: false))
            let original = try await self.visibleText(in: host)
            XCTAssertTrue(original.contains("DTS"), original)
            host.rootView = Harness(song: song)
            let text = try await self.visibleText(in: host)
            XCTAssertTrue(text.contains("DTS"), text)
            XCTAssertTrue(text.contains("RG"), text)
        }
    }

    func testNarrowLayoutKeepsReplayGainAndRestoresAudioWhenSpaceReturns() async throws {
        try await withHost { host in
            let song = self.song(format: .dts)
            host.rootView = Harness(song: song, width: 210)
            let narrow = try await self.visibleText(in: host)
            XCTAssertTrue(narrow.contains("RG"), narrow)
            XCTAssertFalse(narrow.contains("DTS"), narrow)
            host.rootView = Harness(song: song)
            let restored = try await self.visibleText(in: host)
            XCTAssertTrue(restored.contains("DTS"), restored)
            XCTAssertTrue(restored.contains("RG"), restored)
        }
    }

    private func song(format: AudioFormat, id: String = "tag-layout") -> Song {
        Song(id: id, title: "Tag layout", duration: 234, fileFormat: format,
             filePath: "fixture", sourceID: "test", bitRate: 4234, sampleRate: 44100, bitDepth: 16)
    }

    private func withHost(_ check: (UIHostingController<Harness>) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 120)
        let host = UIHostingController(rootView: Harness(song: song(format: .dts)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        try await check(host)
    }

    private func visibleText(in host: UIHostingController<Harness>) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").replacingOccurrences(of: " ", with: "")
    }

    private struct Harness: View {
        let song: Song
        var replayGain = ReplayGainPlaybackInfo(enabled: true, snapshot: .init(
            mode: .track, values: .init(gain: -18.4), origin: .analysis))
        var width: CGFloat = 402

        var body: some View {
            HStack {
                Text(verbatim: "0:08")
                Spacer()
                Text(verbatim: "-3:46")
            }
            .font(.caption2).monospacedDigit()
            .overlay {
                NowPlayingAudioTagRow(
                    song: song, showsAudio: true, isDownloadingFromICloud: false,
                    source: nil, showsSourceTag: false, outputSampleRate: 48000,
                    allowsOutputDetail: true, replayGain: replayGain, tint: .black
                )
                .padding(.horizontal, 50)
            }
            .padding(.horizontal, 26)
            .frame(width: width, height: 100)
            .environment(\.dynamicTypeSize, .large)
            .background(.white)
        }
    }
}
#endif
