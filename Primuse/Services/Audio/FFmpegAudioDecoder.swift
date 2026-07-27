@preconcurrency import AVFoundation
import Foundation

private final class FFmpegBridgeBox: @unchecked Sendable {
    let value: FFmpegDecoderBridge
    init(_ value: FFmpegDecoderBridge) { self.value = value }
}

private final class FFmpegInputBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Broad compatibility fallback built on the LGPL-only FFmpeg runtime.
/// SFBAudioEngine remains the first choice for formats it supports; this
/// decoder covers DTS/DTS-HD, DTS-CD WAV, Dolby, WMA/ATRAC and other formats,
/// and also acts as the content-probing last resort for mislabeled files.
final class FFmpegAudioDecoder: PrimuseAudioDecoder {
    static let preferredExtensions: Set<String> = [
        "dts", "dtshd", "ac3", "eac3", "ec3", "mlp", "truehd", "thd",
        "wma", "asf", "xma", "oma", "aa3", "at3", "atrac", "amr",
        "awb", "tak", "tta", "wv", "ape", "mpc", "mpp", "shn", "spx",
        "qoa", "dsf", "dff", "dtswav"
    ]

    func canDecode(url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "wav" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            let prefix = try? handle.read(upToCount: 256 * 1024)
            try? handle.close()
            return prefix.map(FFmpegDecoderBridge.dataContainsDTSSync) ?? false
        }
        if Self.preferredExtensions.contains(ext) { return true }
        return FFmpegDecoderBridge.canDecode(url)
    }

    static func dataContainsDTSSync(_ data: Data) -> Bool {
        FFmpegDecoderBridge.dataContainsDTSSync(data)
    }

    func fileInfo(for url: URL) async throws -> AudioFileInfo {
        let info = try FFmpegDecoderBridge.probeURL(url)
        return AudioFileInfo(
            duration: info.duration,
            sampleRate: info.sampleRate,
            channelCount: info.channelCount,
            bitDepth: info.bitDepth > 0 ? info.bitDepth : nil,
            bitRate: info.bitRateKbps > 0 ? info.bitRateKbps : nil,
            format: info.codecName.uppercased()
        )
    }

    func decode(
        from url: URL,
        outputFormat: AVAudioFormat
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        decode(
            from: url,
            outputFormat: outputFormat,
            startingAt: nil,
            onResolveSourceLength: nil
        )
    }

    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        decode(
            from: url,
            outputFormat: outputFormat,
            startingAt: nil,
            onResolveSourceLength: onResolveSourceLength
        )
    }

    /// Opens one decoder session and performs a demuxer-level seek before
    /// yielding PCM. This avoids decoding an entire album image from frame zero.
    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        startingAt startTime: TimeInterval?,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bridge = try FFmpegDecoderBridge(url: url)
                    let box = FFmpegBridgeBox(bridge)
                    let info = box.value.fileInfo
                    if info.duration > 0 { onResolveSourceLength?(info.duration) }
                    if let startTime, startTime > 0 {
                        try box.value.seek(toTime: startTime)
                    }

                    var converter: AVAudioConverter?
                    var converterSourceFormat: AVAudioFormat?
                    while !Task.isCancelled {
                        let result = try box.value.readNextBuffer()
                        guard let sourceBuffer = result.buffer else { break }
                        if sourceBuffer.frameLength == 0 { continue }

                        let outputBuffer: AVAudioPCMBuffer
                        if sourceBuffer.format == outputFormat {
                            outputBuffer = sourceBuffer
                        } else {
                            if converter == nil || converterSourceFormat != sourceBuffer.format {
                                guard let newConverter = AVAudioConverter(
                                    from: sourceBuffer.format,
                                    to: outputFormat
                                ) else {
                                    throw AudioDecoderError.converterCreationFailed
                                }
                                converter = newConverter
                                converterSourceFormat = sourceBuffer.format
                            }
                            guard let converter else {
                                throw AudioDecoderError.converterCreationFailed
                            }
                            outputBuffer = try Self.convert(
                                sourceBuffer,
                                to: outputFormat,
                                using: converter
                            )
                        }
                        if outputBuffer.frameLength > 0 {
                            nonisolated(unsafe) let sendableBuffer = outputBuffer
                            continuation.yield(sendableBuffer)
                        }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func convert(
        _ source: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(1, capacity)
        ) else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let input = FFmpegInputBufferBox(source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if input.supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            input.supplied = true
            outStatus.pointee = .haveData
            return input.buffer
        }
        if let conversionError { throw conversionError }
        if status == .error {
            throw AudioDecoderError.decodingFailed("FFmpeg PCM conversion failed")
        }
        return output
    }
}
