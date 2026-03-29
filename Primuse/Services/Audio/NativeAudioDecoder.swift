import AVFoundation
import Foundation
import PrimuseKit

private final class AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

final class NativeAudioDecoder: AudioDecoder {
    private let supportedExtensions: Set<String> = ["mp3", "aac", "m4a", "alac", "flac", "wav", "aiff", "aif"]
    private let bufferFrameCount: AVAudioFrameCount = 8192

    func canDecode(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    func fileInfo(for url: URL) async throws -> AudioFileInfo {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate

        return AudioFileInfo(
            duration: duration,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            bitDepth: Int(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0),
            format: url.pathExtension.uppercased()
        )
    }

    func decode(from url: URL, outputFormat: AVAudioFormat) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Try opening with default format first, fallback to explicit common format
                    let file: AVAudioFile
                    do {
                        file = try AVAudioFile(forReading: url)
                    } catch {
                        // Fallback: try opening with explicit PCM format
                        file = try AVAudioFile(
                            forReading: url,
                            commonFormat: .pcmFormatFloat32,
                            interleaved: false
                        )
                    }
                    let sourceFormat = file.processingFormat
                    plog("🎵 NativeDecoder: file=\(url.lastPathComponent) sourceFormat=sr\(sourceFormat.sampleRate)/ch\(sourceFormat.channelCount) length=\(file.length) outputFormat=sr\(outputFormat.sampleRate)/ch\(outputFormat.channelCount)")

                    // If formats match, read directly
                    if sourceFormat.sampleRate == outputFormat.sampleRate &&
                       sourceFormat.channelCount == outputFormat.channelCount {
                        plog("🎵 NativeDecoder: direct read (formats match)")
                        while file.framePosition < file.length {
                            let remainingFrames = AVAudioFrameCount(file.length - file.framePosition)
                            let framesToRead = min(bufferFrameCount, remainingFrames)

                            guard let buffer = AVAudioPCMBuffer(
                                pcmFormat: sourceFormat,
                                frameCapacity: framesToRead
                            ) else {
                                continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                                return
                            }

                            try file.read(into: buffer, frameCount: framesToRead)
                            continuation.yield(buffer)
                        }
                    } else {
                        // Need format conversion
                        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                            continuation.finish(throwing: AudioDecoderError.converterCreationFailed)
                            return
                        }

                        while file.framePosition < file.length {
                            let remainingFrames = AVAudioFrameCount(file.length - file.framePosition)
                            let framesToRead = min(bufferFrameCount, remainingFrames)

                            guard let inputBuffer = AVAudioPCMBuffer(
                                pcmFormat: sourceFormat,
                                frameCapacity: framesToRead
                            ) else {
                                continuation.finish(throwing: AudioDecoderError.bufferAllocationFailed)
                                return
                            }

                            try file.read(into: inputBuffer, frameCount: framesToRead)
                            let inputBufferBox = AudioBufferBox(inputBuffer)

                            let outputFrameCapacity = AVAudioFrameCount(
                                Double(framesToRead) * outputFormat.sampleRate / sourceFormat.sampleRate
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
