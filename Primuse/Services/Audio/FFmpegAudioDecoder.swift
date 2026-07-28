@preconcurrency import AVFoundation
import Foundation

private final class FFmpegBridgeBox: @unchecked Sendable {
    let value: FFmpegDecoderBridge
    init(_ value: FFmpegDecoderBridge) { self.value = value }
}

private final class FFmpegInputBufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        defer { buffer = nil }
        return buffer
    }
}

/// Broad compatibility fallback built on the LGPL-only FFmpeg runtime.
/// SFBAudioEngine remains the first choice for formats it supports; this
/// decoder covers DTS/DTS-HD, DTS-CD WAV, Dolby, WMA/ATRAC and other formats,
/// and also acts as the content-probing last resort for mislabeled files.
final class FFmpegAudioDecoder: PrimuseAudioDecoder {
    static let preferredExtensions: Set<String> = [
        "aac", "dts", "dtshd", "ac3", "eac3", "ec3", "mlp", "truehd", "thd",
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
    ) -> AudioBufferStream {
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
    ) -> AudioBufferStream {
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
    ) -> AudioBufferStream {
        AudioBufferStreamFactory.make { continuation in
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
                    var exactSeekTarget = startTime.flatMap { $0 > 0 ? $0 : nil }
                    while !Task.isCancelled {
                        let result = try box.value.readNextBuffer()
                        guard var sourceBuffer = result.buffer else { break }
                        if sourceBuffer.frameLength == 0 { continue }
                        if let target = exactSeekTarget,
                           result.hasPresentationTime,
                           sourceBuffer.format.sampleRate > 0 {
                            let bufferStart = result.presentationTime
                            let bufferEnd = bufferStart
                                + Double(sourceBuffer.frameLength) / sourceBuffer.format.sampleRate
                            if bufferEnd <= target {
                                continue
                            }
                            if bufferStart < target {
                                let skip = AVAudioFrameCount(
                                    ((target - bufferStart) * sourceBuffer.format.sampleRate)
                                        .rounded(.down)
                                )
                                if skip < sourceBuffer.frameLength {
                                    sourceBuffer = try Self.slice(
                                        sourceBuffer,
                                        skipping: skip
                                    )
                                }
                            }
                            exactSeekTarget = nil
                        } else if exactSeekTarget != nil {
                            // A demuxer without timestamps can still perform
                            // its native seek; it just cannot be sample-trimmed.
                            exactSeekTarget = nil
                        }

                        if let existingConverter = converter,
                           converterSourceFormat != sourceBuffer.format {
                            for output in try Self.drain(
                                converter: existingConverter,
                                outputFormat: outputFormat
                            ) {
                                try await AudioBufferStreamFactory.yieldWithBackpressure(
                                    output,
                                    to: continuation
                                )
                            }
                            converter = nil
                            converterSourceFormat = nil
                        }

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
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                outputBuffer,
                                to: continuation
                            )
                        }
                    }
                    if let converter {
                        for output in try Self.drain(
                            converter: converter,
                            outputFormat: outputFormat
                        ) {
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                output,
                                to: continuation
                            )
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
            if let buffer = input.take() {
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        if let conversionError { throw conversionError }
        if status == .error {
            throw AudioDecoderError.decodingFailed("FFmpeg PCM conversion failed")
        }
        return output
    }

    private static func drain(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
        var drained: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 8192
            ) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            if status == .error {
                throw AudioDecoderError.decodingFailed("FFmpeg PCM converter drain failed")
            }
            if output.frameLength > 0 { drained.append(output) }
            if status == .endOfStream || output.frameLength == 0 { return drained }
        }
    }

    private static func slice(
        _ source: AVAudioPCMBuffer,
        skipping: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let count = source.frameLength - skipping
        guard count > 0,
              let destination = AVAudioPCMBuffer(
                  pcmFormat: source.format,
                  frameCapacity: count
              ) else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        destination.frameLength = count
        let bytesPerFrame = Int(
            source.format.streamDescription.pointee.mBytesPerFrame
        )
        guard bytesPerFrame > 0 else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let sourceOffset = Int(skipping) * bytesPerFrame
        let byteCount = Int(count) * bytesPerFrame
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData,
                  sourceOffset + byteCount
                    <= Int(sourceBuffers[index].mDataByteSize) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            memcpy(
                destinationData,
                sourceData.advanced(by: sourceOffset),
                byteCount
            )
        }
        return destination
    }
}
