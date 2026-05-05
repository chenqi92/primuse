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
    /// `onResolveSourceLength` fires once per decode session as soon as
    /// SFB reports the source's PCM frame count. For cloud-streamed
    /// MP3s without an XING/LAME header, SFB's value is the only
    /// trustworthy duration we'll ever get (backfill saw a truncated
    /// 256KB head and had to guess). The caller writes it back to the
    /// library so the next render shows the real time.
    func decode(
        from inputSource: InputSource,
        outputFormat: AVAudioFormat,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)? = nil
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        // SFBAudioEngine's InputSource isn't formally Sendable but it's
        // safe to hand off across one Task boundary — the decoder owns
        // it from then on. Box it to silence the strict-concurrency check.
        let inputBox = InputSourceBox(inputSource)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let decoder = try SFBAudioEngine.AudioDecoder(inputSource: inputBox.value)
                    try decoder.open()
                    try await self.runDecode(decoder: decoder, outputFormat: outputFormat, continuation: continuation, onResolveSourceLength: onResolveSourceLength)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Protocol-witness signature for `PrimuseAudioDecoder.decode`. The
    /// extended overload below adds the optional length callback used by
    /// `AudioPlayerService` to write back real durations — kept as a
    /// separate method (not just a default arg) so the protocol witness
    /// matches exactly and no other decoder implementation has to be
    /// modified.
    func decode(from url: URL, outputFormat: AVAudioFormat) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        decode(from: url, outputFormat: outputFormat, onResolveSourceLength: nil)
    }

    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let decoder = try SFBAudioEngine.AudioDecoder(url: url)
                    try decoder.open()
                    plog("🎵 SFBDecoder: file=\(url.lastPathComponent)")
                    try await self.runDecode(decoder: decoder, outputFormat: outputFormat, continuation: continuation, onResolveSourceLength: onResolveSourceLength)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Shared decode loop. Reads PCM from the open `decoder`, converts to
    /// `outputFormat` if needed, yields buffers via the continuation.
    private func runDecode(
        decoder: SFBAudioEngine.AudioDecoder,
        outputFormat: AVAudioFormat,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)? = nil
    ) async throws {
        let sourceFormat = decoder.processingFormat
        let totalFrames = decoder.length

        plog("🎵 SFBDecoder: sourceFormat=sr\(sourceFormat.sampleRate)/ch\(sourceFormat.channelCount) length=\(totalFrames) outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount)")

        // Surface the resolved duration so the caller (AudioPlayerService)
        // can write it back to the library, replacing whatever placeholder
        // backfill stuffed in there from its 256KB-head estimate. Guarded
        // against zero sample rate (some malformed files) — caller's
        // closure ignores zero anyway.
        if let onResolveSourceLength, sourceFormat.sampleRate > 0, totalFrames > 0 {
            let durationSeconds = Double(totalFrames) / sourceFormat.sampleRate
            onResolveSourceLength(durationSeconds)
        }

        if sourceFormat == outputFormat {
            plog("🎵 SFBDecoder: direct read (formats match)")
            while !Task.isCancelled, decoder.position < totalFrames {
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
            while !Task.isCancelled, decoder.position < totalFrames {
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
