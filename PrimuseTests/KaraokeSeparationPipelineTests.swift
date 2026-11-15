import AVFoundation
import CoreML
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class KaraokeSeparationPipelineTests: XCTestCase {
    func testCancelledQueuedJobDoesNotEnterOrReleaseRunningSlot() async throws {
        let gate = KaraokePreparationGate()
        let active = UUID(), cancelled = UUID(), next = UUID()
        try await gate.acquire(active)
        var entered = false
        let waiting = Task {
            try await gate.acquire(cancelled)
            defer { gate.release(cancelled) }
            XCTFail("A cancelled queued song must never acquire audio")
        }
        for _ in 0..<10 { await Task.yield() }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let following = Task {
            try await gate.acquire(next)
            defer { gate.release(next) }
            entered = true
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(entered)
        gate.release(active)
        try await following.value
        XCTAssertTrue(entered)
    }

    func testCancellationAtSlotHandoffDoesNotStrandFollowingJob() async throws {
        let gate = KaraokePreparationGate()
        let active = UUID(), cancelled = UUID(), next = UUID()
        try await gate.acquire(active)
        let waiting = Task {
            try await gate.acquire(cancelled)
            defer { gate.release(cancelled) }
            try Task.checkCancellation()
        }
        for _ in 0..<10 { await Task.yield() }
        waiting.cancel()
        gate.release(active)
        _ = try? await waiting.value
        try await gate.acquire(next)
        gate.release(next)
    }

    func testStreamingDecodePreservesCUEAndAllModelWindows() async throws {
        let source = try fixture(rate: 44_100, frames: 100_003)
        defer { try? FileManager.default.removeItem(at: source) }
        let prepared = try await KaraokeSeparationService.decodeModelAudioFile(
            file: KaraokeAudioFile(url: source), start: 0.25, end: 2.0
        )
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        XCTAssertEqual(prepared.frames, 77_175)
        let samples = try readAudio(prepared.url)
        let original = try readAudio(source)
        XCTAssertEqual(samples.left, Array(original.left[11_025..<88_200]))
        XCTAssertEqual(samples.right, Array(original.right[11_025..<88_200]))
        let layout = KaraokeDemucsLayout(sampleRate: 44_100, fftSize: 4096, hopLength: 1024,
                                        segmentLength: 20_000, overlap: 0.25)
        let plan = KaraokeSeparationPlan(totalLength: prepared.frames, layout: layout)
        let audioFile = try AVAudioFile(forReading: prepared.url)
        for segment in plan.segments {
            let actual = try KaraokeVocalSeparator.readWindow(from: audioFile, segment: segment,
                                                              totalLength: prepared.frames, layout: layout)
            XCTAssertEqual(actual.left, plan.window(segment, of: samples.left))
            XCTAssertEqual(actual.right, plan.window(segment, of: samples.right))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testStreamingResamplingMatchesContinuousConverterAcrossBoundariesAndTail() async throws {
        let source = try fixture(rate: 48_000, frames: 111_117)
        defer { try? FileManager.default.removeItem(at: source) }
        let prepared = try await KaraokeSeparationService.decodeModelAudioFile(
            file: KaraokeAudioFile(url: source), start: nil, end: nil
        )
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let actual = try readAudio(prepared.url)
        let expected = try wholeBufferReference(source, sampleRate: 44_100)
        XCTAssertEqual(actual.left.count, expected.left.count)
        XCTAssertEqual(actual.right.count, expected.right.count)
        XCTAssertLessThan(zip(actual.left, expected.left).map { abs($0 - $1) }.max() ?? 1, 0.00001)
        XCTAssertLessThan(zip(actual.right, expected.right).map { abs($0 - $1) }.max() ?? 1, 0.00001)
    }

    func testFailedAndCancelledPreparationRemoveOnlyOwnedInputs() async throws {
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("invalid PCM".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        do {
            _ = try await KaraokeSeparationService.decodeModelAudioFile(
                file: KaraokeAudioFile(url: invalid, removeAfterDecoding: true), start: nil, end: nil
            )
            XCTFail("Invalid input must not produce a prepared file")
        } catch KaraokeSeparationError.unreadableAudio {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
        let owned = try fixture(rate: 48_000, frames: 30_000)
        defer { try? FileManager.default.removeItem(at: owned) }
        let task = Task {
            try await KaraokeSeparationService.decodeModelAudioFile(
                file: KaraokeAudioFile(url: owned, removeAfterDecoding: true), start: nil, end: nil
            )
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }

    func testDirectStemTrackLoadMatchesSamplesAtBothGraphRates() async throws {
        let source = try fixture(rate: 44_100, frames: 31_337)
        defer { try? FileManager.default.removeItem(at: source) }
        let samples = try readAudio(source)
        let song = Song(id: UUID().uuidString, title: "Window Lantern", fileFormat: .wav,
                        filePath: source.path, sourceID: "karaoke-pipeline-test")
        let destination = KaraokeSeparationService.stemURL(for: song)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try KaraokeStemFile.encode(left: samples.left, right: samples.right, sampleRate: 44_100).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        for rate in [44_100.0, 48_000.0] {
            let loaded = await KaraokeSeparationService.shared.loadStem(for: song, graphSampleRate: rate)
            let reference = await KaraokeSeparationService.shared.loadStemSamples(for: song, graphSampleRate: rate)
            let track = try XCTUnwrap(loaded)
            let expected = try XCTUnwrap(reference)
            XCTAssertEqual(track.frames, expected.left.count)
            for index in 0..<track.frames {
                XCTAssertEqual(Float(track.samples[index * 2]) / 32_767, expected.left[index], accuracy: 1.0 / 32_767)
                XCTAssertEqual(Float(track.samples[index * 2 + 1]) / 32_767, expected.right[index], accuracy: 1.0 / 32_767)
            }
        }
    }

    func testConfiguredRealModelCompletesStreamingPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["PRIMUSE_TEST_KARAOKE_MODEL"],
              let audioPath = environment["PRIMUSE_TEST_KARAOKE_AUDIO"] else {
            throw XCTSkip("Requires an explicit local model and audio fixture")
        }
        let prepared = try await KaraokeSeparationService.decodeModelAudioFile(
            file: KaraokeAudioFile(url: URL(fileURLWithPath: audioPath)), start: nil, end: nil
        )
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("karaoke-test-\(UUID()).kvst")
        defer { try? FileManager.default.removeItem(at: output) }
        let separator = try KaraokeVocalSeparator(modelURL: URL(fileURLWithPath: modelPath))
        try await separator.separateVocals(file: prepared, outputURL: output, songID: "pipeline-test",
                                          progress: { _ in }, hold: {})
        let result = try XCTUnwrap(KaraokeStemFile.decode(Data(contentsOf: output)))
        XCTAssertEqual(result.header.frames, prepared.frames)
        XCTAssertEqual(result.header.sampleRate, 44_100)
        XCTAssertTrue(result.left.allSatisfy(\.isFinite))
        XCTAssertTrue(result.right.allSatisfy(\.isFinite))
    }

    private func fixture(rate: Double, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("karaoke-fixture-\(UUID()).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            let phase = Double(index) / rate
            buffer.floatChannelData![0][index] = Float(sin(phase * 2 * .pi * 437)) * 0.4
            buffer.floatChannelData![1][index] = Float(cos(phase * 2 * .pi * 773)) * 0.3
        }
        try file.write(from: buffer)
        return url
    }

    private func readAudio(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))),
                Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))))
    }

    private func wholeBufferReference(_ url: URL, sampleRate: Double) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: format))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * sampleRate / input.format.sampleRate)) + 4096))
        let pending = ReferenceInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = pending.take() else { inputStatus.pointee = .endOfStream; return nil }
            inputStatus.pointee = .haveData
            return next
        }
        XCTAssertNotEqual(status, .error)
        if let error { throw error }
        return (Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))),
                Array(UnsafeBufferPointer(start: output.floatChannelData![1], count: Int(output.frameLength))))
    }
}

private final class ReferenceInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}

@MainActor
final class KaraokeRecordingTests: XCTestCase {
    func testMixdownFinishesAtEOFForPartialAndFullChunks() async throws {
        for frames in [4_096, 8_192, 20_003] {
            try await verifyMix(rate: 44_100, channels: 2, frames: frames)
            try await verifyMix(rate: 48_000, channels: 1, frames: frames)
        }
    }

    func testHighSampleRateTakesProduceReadableAAC() async throws {
        for rate in [88_200.0, 96_000, 176_400, 192_000] {
            try await verifyMix(rate: rate, channels: 2, frames: Int(rate) + 333)
        }
    }

    func testFailedMixLeavesSourceTakesReadable() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.caf")
        try writeTake(source, rate: 48_000, channels: 1, frames: 8_192, amplitude: 0.2)
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocker)
        do {
            _ = try await KaraokeMixdown.mix(
                accompaniment: .init(url: source, firstHostSeconds: 1),
                voice: .init(url: source, firstHostSeconds: 1),
                outputLatency: 0, inputLatency: 0, voiceGain: 1,
                destination: blocker.appendingPathComponent("recording.m4a")
            )
            XCTFail("An unwritable destination must fail")
        } catch {
            let retained = try AVAudioFile(forReading: source)
            XCTAssertEqual(retained.length, 8_192)
        }
    }

    private func verifyMix(rate: Double, channels: AVAudioChannelCount, frames: Int) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accompaniment = directory.appendingPathComponent("accompaniment.caf")
        let voice = directory.appendingPathComponent("voice.caf")
        let destination = directory.appendingPathComponent("recording.m4a")
        try writeTake(accompaniment, rate: rate, channels: channels, frames: frames, amplitude: 0)
        // A different microphone rate and channel count must still preserve the sung voice.
        try writeTake(voice, rate: 48_000, channels: 1,
                      frames: Int(ceil(Double(frames) / rate * 48_000)), amplitude: 0.2)
        let result = try await KaraokeMixdown.mix(
            accompaniment: .init(url: accompaniment, firstHostSeconds: 1),
            voice: .init(url: voice, firstHostSeconds: 1),
            outputLatency: 0, inputLatency: 0, voiceGain: 1, destination: destination
        )
        XCTAssertEqual(result, destination)
        let output = try AVAudioFile(forReading: result)
        let targetRate = rate == 44_100 ? 44_100.0 : 48_000.0
        XCTAssertEqual(output.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(output.processingFormat.sampleRate, targetRate)
        XCTAssertEqual(output.processingFormat.channelCount, channels)
        XCTAssertEqual(Double(output.length), Double(frames) / rate * targetRate, accuracy: 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(output.length)
        ))
        try output.read(into: buffer, frameCount: AVAudioFrameCount(output.length))
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) }
        XCTAssertGreaterThan(sqrt(energy / Double(samples.count)), 0.05)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("karaoke-recording-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeTake(_ url: URL, rate: Double, channels: AVAudioChannelCount,
                           frames: Int, amplitude: Float) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        defer { file.close() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                buffer.floatChannelData![channel][frame] = amplitude * Float(sin(Double(frame) / rate * 2 * .pi * 437))
            }
        }
        try file.write(from: buffer)
    }
}
