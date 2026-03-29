import AVFoundation
import Foundation

/// Fallback decoder using AVAssetReader — handles more MP3 variants and formats
/// that AVAudioFile rejects (VBR, non-standard headers, etc.)
final class AssetReaderDecoder: Sendable {
    private let bufferFrameCount: AVAudioFrameCount = 8192

    func canDecode(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        // AVAssetReader supports all formats that AVFoundation/CoreMedia can handle
        return ["mp3", "aac", "m4a", "alac", "flac", "wav", "aiff", "aif", "m4b", "caf"].contains(ext)
    }

    func fileInfo(for url: URL) async -> AudioFileInfo? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let secs = CMTimeGetSeconds(duration)
        guard secs.isFinite, secs > 0 else { return nil }

        var sampleRate = 44100.0
        var channelCount = 2

        if let tracks = try? await asset.load(.tracks) {
            for track in tracks where track.mediaType == .audio {
                if let descs = try? await track.load(.formatDescriptions) {
                    for desc in descs {
                        if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                            if basic.mSampleRate > 0 { sampleRate = basic.mSampleRate }
                            if basic.mChannelsPerFrame > 0 { channelCount = Int(basic.mChannelsPerFrame) }
                        }
                    }
                }
            }
        }

        return AudioFileInfo(
            duration: secs,
            sampleRate: sampleRate,
            channelCount: channelCount,
            format: url.pathExtension.uppercased()
        )
    }

    func decode(from url: URL, outputFormat: AVAudioFormat) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.load(.tracks)
                    guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
                        continuation.finish(throwing: AudioDecoderError.decodingFailed("No audio track found"))
                        return
                    }

                    let reader = try AVAssetReader(asset: asset)

                    let outputSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: outputFormat.sampleRate,
                        AVNumberOfChannelsKey: outputFormat.channelCount,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: true,
                    ]

                    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
                    output.alwaysCopiesSampleData = false
                    reader.add(output)

                    guard reader.startReading() else {
                        continuation.finish(throwing: AudioDecoderError.decodingFailed(
                            reader.error?.localizedDescription ?? "Failed to start reading"
                        ))
                        return
                    }

                    while reader.status == .reading {
                        guard !Task.isCancelled else {
                            reader.cancelReading()
                            return
                        }

                        guard let sampleBuffer = output.copyNextSampleBuffer() else {
                            break
                        }

                        if let pcmBuffer = createPCMBuffer(from: sampleBuffer, format: outputFormat) {
                            nonisolated(unsafe) let buf = pcmBuffer
                            continuation.yield(buf)
                        }
                    }

                    if reader.status == .failed {
                        continuation.finish(throwing: AudioDecoderError.decodingFailed(
                            reader.error?.localizedDescription ?? "Reader failed"
                        ))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                                  totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let data = dataPointer else { return nil }

        let channelCount = Int(format.channelCount)
        let bytesPerFrame = Int(frameCount) * MemoryLayout<Float>.size

        for ch in 0..<channelCount {
            guard let channelData = buffer.floatChannelData?[ch] else { continue }
            let sourceOffset = ch * bytesPerFrame
            if sourceOffset + bytesPerFrame <= totalLength {
                memcpy(channelData, data.advanced(by: sourceOffset), bytesPerFrame)
            }
        }

        return buffer
    }
}
