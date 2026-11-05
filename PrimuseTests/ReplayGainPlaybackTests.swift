import AVFoundation
import PrimuseKit
import XCTest
@testable import Primuse

final class ReplayGainPlaybackTests: XCTestCase {
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
