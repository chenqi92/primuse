@preconcurrency import AVFoundation
import Foundation
import PrimuseKit
import SFBAudioEngine

private final class AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class InputSourceBox: @unchecked Sendable {
    let value: InputSource
    init(_ value: InputSource) { self.value = value }
}

final class NativeAudioDecoder: PrimuseAudioDecoder {
    private let bufferFrameCount: AVAudioFrameCount = 8192

    func canDecode(url: URL) -> Bool {
        // SFBAudioEngine supports a huge range of formats
        let ext = url.pathExtension.lowercased()
        return SFBAudioEngine.AudioDecoder.handlesPaths(withExtension: ext)
    }

    func fileInfo(for url: URL) async throws -> AudioFileInfo {
        // Try SFBAudioEngine first for broader format support
        let decoder = try SFBAudioEngine.AudioDecoder(url: url)
        try decoder.open()
        let format = decoder.processingFormat
        let totalFrames = decoder.length
        let duration = totalFrames > 0 ? Double(totalFrames) / format.sampleRate : 0
        try? decoder.close()

        return AudioFileInfo(
            duration: duration,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            bitDepth: Int(format.settings[AVLinearPCMBitDepthKey] as? Int ?? 0),
            format: url.pathExtension.uppercased()
        )
    }

    /// Decode by streaming from a custom `InputSource`. Used by cloud
    /// playback where bytes are fetched via HTTP Range and cached lazily —
    /// see `CloudPlaybackSource`. Same decoding pipeline as URL-based, just
    /// constructed differently.
    func decode(from inputSource: InputSource, outputFormat: AVAudioFormat) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        // SFBAudioEngine's InputSource isn't formally Sendable but it's
        // safe to hand off across one Task boundary — the decoder owns
        // it from then on. Box it to silence the strict-concurrency check.
        let inputBox = InputSourceBox(inputSource)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let decoder = try SFBAudioEngine.AudioDecoder(inputSource: inputBox.value)
                    try decoder.open()
                    try await self.runDecode(decoder: decoder, outputFormat: outputFormat, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func decode(from url: URL, outputFormat: AVAudioFormat) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let decoder = try SFBAudioEngine.AudioDecoder(url: url)
                    try decoder.open()
                    plog("🎵 SFBDecoder: file=\(url.lastPathComponent)")
                    try await self.runDecode(decoder: decoder, outputFormat: outputFormat, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Shared decode loop. Reads PCM from the open `decoder`, converts to
    /// `outputFormat` if needed, yields buffers via the continuation.
    private func runDecode(
        decoder: SFBAudioEngine.AudioDecoder,
        outputFormat: AVAudioFormat,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async throws {
        let sourceFormat = decoder.processingFormat
        let totalFrames = decoder.length

        plog("🎵 SFBDecoder: sourceFormat=sr\(sourceFormat.sampleRate)/ch\(sourceFormat.channelCount) length=\(totalFrames) outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount)")

        if sourceFormat == outputFormat {
            plog("🎵 SFBDecoder: direct read (formats match)")
            while decoder.position < totalFrames {
                let remainingFrames = AVAudioFrameCount(totalFrames - decoder.position)
                let framesToRead = min(bufferFrameCount, remainingFrames)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                    continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                    return
                }
                try decoder.decode(into: buffer, length: framesToRead)
                if buffer.frameLength > 0 {
                    nonisolated(unsafe) let sendBuf = buffer
                    continuation.yield(sendBuf)
                }
            }
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                continuation.finish(throwing: AudioDecoderError.converterCreationFailed)
                return
            }
            while decoder.position < totalFrames {
                let remainingFrames = AVAudioFrameCount(totalFrames - decoder.position)
                let framesToRead = min(bufferFrameCount, remainingFrames)
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                    continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                    return
                }
                try decoder.decode(into: inputBuffer, length: framesToRead)
                guard inputBuffer.frameLength > 0 else { break }
                let inputBufferBox = AudioBufferBox(inputBuffer)

                let outputFrameCapacity = AVAudioFrameCount(
                    Double(inputBuffer.frameLength) * outputFormat.sampleRate / sourceFormat.sampleRate
                ) + 1
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
                    continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                    return
                }
                var error: NSError?
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return inputBufferBox.buffer
                }
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                if outputBuffer.frameLength > 0 {
                    continuation.yield(outputBuffer)
                }
            }
        }

        try? decoder.close()
        continuation.finish()
    }
}

enum AudioDecoderError: Error, LocalizedError {
    case bufferAllocationFailed
    case converterCreationFailed
    case unsupportedFormat(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: return "Failed to allocate audio buffer"
        case .converterCreationFailed: return "Failed to create audio converter"
        case .unsupportedFormat(let fmt): return "Unsupported audio format: \(fmt)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        }
    }
}
