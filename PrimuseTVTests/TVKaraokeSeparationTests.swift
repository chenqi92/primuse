#if os(tvOS)
import AVFoundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

@MainActor
final class TVKaraokeSeparationTests: XCTestCase {
    func testBorrowedAudioPreservesSourceAndDecodesOnlyCUESlice() async throws {
        let url = try audioFile(rate: 44_100, frames: 88_200)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try await KaraokeSeparationService.decodeForModel(
            file: KaraokeAudioFile(url: url), start: 0.5, end: 1.5
        )
        XCTAssertEqual(samples.left.count, 44_100)
        XCTAssertEqual(samples.left[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(samples.left[44_099], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples.right[0], -0.25, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOwnedAudioIsRemovedAfterResampling() async throws {
        let url = try audioFile(rate: 48_000, frames: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try await KaraokeSeparationService.decodeForModel(
            file: KaraokeAudioFile(url: url, removeAfterDecoding: true), start: nil, end: nil
        )
        XCTAssertEqual(samples.left.count, 44_100, accuracy: 2)
        XCTAssertEqual(samples.left[10_000], 0.25, accuracy: 0.001)
        XCTAssertEqual(samples.right[10_000], -0.25, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedDecodeRemovesOwnedDownload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("invalid audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await KaraokeSeparationService.decodeForModel(
                file: KaraokeAudioFile(url: url, removeAfterDecoding: true), start: nil, end: nil
            )
            XCTFail("An unreadable download must not produce a stem")
        } catch KaraokeSeparationError.unreadableAudio {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancelledDecodeRemovesOwnedDownload() async throws {
        let url = try audioFile(rate: 44_100, frames: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            try await KaraokeSeparationService.decodeForModel(
                file: KaraokeAudioFile(url: url, removeAfterDecoding: true), start: nil, end: nil
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled jobs must not decode a downloaded file")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCachedStemLoadsAtTVGraphRateAndCanBeRegenerated() async throws {
        let song = Song(id: UUID().uuidString, title: "Fixture", fileFormat: .wav, filePath: "/fixture.wav", sourceID: "karaoke-test")
        let url = KaraokeSeparationService.stemURL(for: song)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try KaraokeStemFile.encode(
            left: Array(repeating: 0.25, count: 44_100),
            right: Array(repeating: -0.25, count: 44_100), sampleRate: 44_100
        ).write(to: url)
        let service = KaraokeSeparationService.shared
        XCTAssertEqual(service.state(for: song), .ready)
        let loaded = await service.loadStemSamples(for: song, graphSampleRate: 48_000)
        let samples = try XCTUnwrap(loaded)
        XCTAssertEqual(samples.left.count, 48_000, accuracy: 2)
        XCTAssertEqual(samples.left[10_000], 0.25, accuracy: 0.001)
        XCTAssertEqual(samples.right[10_000], -0.25, accuracy: 0.001)
        service.discardStem(for: song)
        XCTAssertEqual(service.state(for: song), .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLocalModelSeparatesSilenceOnTV() async throws {
        guard let path = ProcessInfo.processInfo.environment["PRIMUSE_TEST_KARAOKE_MODEL"] else {
            throw XCTSkip("Requires the locally compiled vocal model")
        }
        let separator = try KaraokeVocalSeparator(modelURL: URL(fileURLWithPath: path))
        let silence = [Float](repeating: 0, count: 44_100)
        let stem = try await separator.separateVocals(left: silence, right: silence, progress: { _ in }, cooling: { _ in })
        XCTAssertEqual(stem.left.count, silence.count)
        XCTAssertEqual(stem.right.count, silence.count)
        XCTAssertTrue(stem.left.allSatisfy { $0.isFinite && abs($0) < 0.0001 })
        XCTAssertTrue(stem.right.allSatisfy { $0.isFinite && abs($0) < 0.0001 })
    }

    private func audioFile(rate: Double, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            let value: Float = index < Int(rate) ? 0.25 : 0.5
            buffer.floatChannelData![0][index] = value
            buffer.floatChannelData![1][index] = -value
        }
        try file.write(from: buffer)
        return url
    }
}
#endif
