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

    func decode(from url: URL, outputFormat: AVAudioFormat) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let decoder = try SFBAudioEngine.AudioDecoder(url: url)
                    try decoder.open()

                    let sourceFormat = decoder.processingFormat
                    let totalFrames = decoder.length

                    plog("🎵 SFBDecoder: file=\(url.lastPathComponent) sourceFormat=sr\(sourceFormat.sampleRate)/ch\(sourceFormat.channelCount) length=\(totalFrames) outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount)")

                    // If formats match, read directly
                    if sourceFormat.sampleRate == outputFormat.sampleRate &&
                       sourceFormat.channelCount == outputFormat.channelCount {
                        plog("🎵 SFBDecoder: direct read (formats match)")
                        while decoder.position < totalFrames {
                            let remainingFrames = AVAudioFrameCount(totalFrames - decoder.position)
                            let framesToRead = min(bufferFrameCount, remainingFrames)

                            guard let buffer = AVAudioPCMBuffer(
                                pcmFormat: sourceFormat,
                                frameCapacity: framesToRead
                            ) else {
                                continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                                return
                            }

                            try decoder.decode(into: buffer, length: framesToRead)
                            if buffer.frameLength > 0 {
                                continuation.yield(buffer)
                            }
                        }
                    } else {
                        // Need format conversion
                        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                            continuation.finish(throwing: AudioDecoderError.converterCreationFailed)
                            return
                        }

                        while decoder.position < totalFrames {
                            let remainingFrames = AVAudioFrameCount(totalFrames - decoder.position)
                            let framesToRead = min(bufferFrameCount, remainingFrames)

                            guard let inputBuffer = AVAudioPCMBuffer(
                                pcmFormat: sourceFormat,
                                frameCapacity: framesToRead
                            ) else {
                                continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                                return
                            }

                            try decoder.decode(into: inputBuffer, length: framesToRead)
                            guard inputBuffer.frameLength > 0 else { break }
                            let inputBufferBox = AudioBufferBox(inputBuffer)

                            let outputFrameCapacity = AVAudioFrameCount(
                                Double(inputBuffer.frameLength) * outputFormat.sampleRate / sourceFormat.sampleRate
                            ) + 1

                            guard let outputBuffer = AVAudioPCMBuffer(
                                pcmFormat: outputFormat,
                                frameCapacity: outputFrameCapacity
                            ) else {
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
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
