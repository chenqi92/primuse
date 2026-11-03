import AVFoundation
import ImageIO
import Photos
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class LyricPosterAudioExportTests: XCTestCase {
    func testMusicSurvivesLivePhotoWritingAndKeepsPairingMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try audioFixture(in: directory)
        let bundle = try await write(in: directory, audio: audio)
        let asset = AVURLAsset(url: bundle.videoURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(metadataTracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.06)
        let metadata = try await asset.load(.metadata)
        let identifier = try await metadata.first {
            $0.identifier == .quickTimeMetadataContentIdentifier
        }?.load(.stringValue)
        XCTAssertEqual(identifier, bundle.assetIdentifier)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(bundle.stillURL as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        let maker = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])
        XCTAssertEqual(maker["17"] as? String, bundle.assetIdentifier)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var sampleCount = 0
        var energy = 0.0
        while let sample = output.copyNextSampleBuffer() {
            sampleCount += CMSampleBufferGetNumSamples(sample)
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var data = Data(count: CMBlockBufferGetDataLength(block))
                _ = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                data.withUnsafeBytes { bytes in
                    for value in bytes.bindMemory(to: Float.self) { energy += Double(value * value) }
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(sampleCount, 44_100 * 2)
        XCTAssertGreaterThan(energy, 1)

        let photo = await livePhoto(bundle)
        XCTAssertNotNil(photo, "PhotoKit must accept the image, timed metadata and audio/video pair")
    }

    func testMusicDisabledLeavesTheMovieSilent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try await write(in: directory, audio: nil)
        let tracks = try await AVURLAsset(url: bundle.videoURL).loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testInvalidAudioFailsInsteadOfExportingASilentPhoto() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("invalid.m4a")
        try Data("invalid".utf8).write(to: invalid)
        do {
            _ = try await write(in: directory, audio: invalid)
            XCTFail("An explicit request for music must not silently lose the audio")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.mov").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.jpg").path))
        }
    }

    func testCancelledWritingRemovesIncompleteResources() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await self.write(in: directory, audio: nil) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled export must not return a bundle")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.mov").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.jpg").path))
        }
    }

    func testCancellationWhileAudioAndVideoAreWritingFinishesCleanly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try audioFixture(in: directory)
        let task = Task {
            try await self.write(in: directory, audio: audio) { progress in
                if progress > 0.1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("The export must stop after cancellation")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.mov").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.jpg").path))
        }
    }

    private func write(
        in directory: URL, audio: URL?, onProgress: @MainActor (Double) -> Void = { _ in }
    ) async throws -> LyricPosterLivePhotoBundle {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let frame = try XCTUnwrap(context.makeImage())
        let plan = LyricPosterMotionPlan(duration: 3, frameRate: 24, windows: [], stillFrameIndex: 36)
        return try await LyricPosterLivePhotoWriter.write(
            plan: plan, size: CGSize(width: 128, height: 128), directory: directory,
            baseName: "poster", audioURL: audio, frame: { _ in frame }, onProgress: onProgress
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // Codec fixture only: it is decoded numerically and never played through an audio device.
    private func audioFixture(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("audio.m4a")
        let output = try AudioClipExporter.makeOutputFile(at: url, sampleRate: 44_100, channelCount: 1)
        defer { output.close() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 132_300))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.1)
        }
        try output.write(from: buffer)
        return url
    }

    private func livePhoto(_ bundle: LyricPosterLivePhotoBundle) async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            PHLivePhoto.request(
                withResourceFileURLs: [bundle.stillURL, bundle.videoURL], placeholderImage: nil,
                targetSize: CGSize(width: 128, height: 128), contentMode: .aspectFit
            ) { photo, info in
                guard (info[PHLivePhotoInfoIsDegradedKey] as? Bool) != true else { return }
                continuation.resume(returning: photo)
            }
        }
    }
}
