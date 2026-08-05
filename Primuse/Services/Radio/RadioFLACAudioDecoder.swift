@preconcurrency import AVFoundation
import Foundation

#if os(tvOS)
extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}
typealias RadioFLACBufferStream = AsyncThrowingStream<AVAudioPCMBuffer, Error>
#else
typealias RadioFLACBufferStream = AudioBufferStream
#endif

private final class RadioFLACConverterInput: @unchecked Sendable {
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

/// Decodes a non-seekable native/Ogg FLAC broadcast and converts its PCM into
/// the fixed format required by the active playback graph.
final class RadioFLACAudioDecoder: Sendable {
    private static let bufferingLimit = 8
    private static let backpressureDelay: UInt64 = 10_000_000

    func decode(
        from source: RadioLiveStreamSource,
        prepared: RadioLiveStreamSource.Prepared,
        outputFormat: AVAudioFormat
    ) -> RadioFLACBufferStream {
        RadioFLACBufferStream(
            bufferingPolicy: .bufferingOldest(Self.bufferingLimit)
        ) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let bridge = try RadioFLACDecoderBridge(
                        oggContainer: prepared.container == .oggFLAC
                    ) { maximumLength, atEOF, errorOut in
                        source.read(
                            maximumLength: maximumLength,
                            atEOF: atEOF,
                            errorOut: errorOut
                        )
                    }

                    var converter: AVAudioConverter?
                    var converterSourceFormat: AVAudioFormat?
                    while !Task.isCancelled {
                        let result = try bridge.readNextBuffer()
                        guard let sourceBuffer = result.buffer else { break }
                        guard sourceBuffer.frameLength > 0 else { continue }

                        let outputBuffer: AVAudioPCMBuffer
                        if sourceBuffer.format == outputFormat {
                            outputBuffer = sourceBuffer
                        } else {
                            if converter == nil || converterSourceFormat != sourceBuffer.format {
                                guard let newConverter = AVAudioConverter(
                                    from: sourceBuffer.format,
                                    to: outputFormat
                                ) else {
                                    throw Self.error(
                                        code: 1,
                                        message: "Unable to configure live FLAC audio conversion."
                                    )
                                }
                                converter = newConverter
                                converterSourceFormat = sourceBuffer.format
                            }
                            guard let converter else {
                                throw Self.error(
                                    code: 1,
                                    message: "Unable to configure live FLAC audio conversion."
                                )
                            }
                            outputBuffer = try Self.convert(
                                sourceBuffer,
                                to: outputFormat,
                                using: converter
                            )
                        }

                        if outputBuffer.frameLength > 0 {
                            try await Self.yieldWithBackpressure(
                                outputBuffer,
                                to: continuation
                            )
                        }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                source.cancel()
            }
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
            throw error(code: 2, message: "Unable to allocate live FLAC audio output.")
        }

        let input = RadioFLACConverterInput(source)
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
            throw error(code: 3, message: "Unable to convert live FLAC audio.")
        }
        return output
    }

    private static func yieldWithBackpressure(
        _ buffer: AVAudioPCMBuffer,
        to continuation: RadioFLACBufferStream.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(buffer) {
            case .enqueued:
                return
            case .dropped:
                try await Task.sleep(nanoseconds: backpressureDelay)
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }

    private static func error(code: Int, message: String) -> NSError {
        NSError(
            domain: "com.welape.yuanyin.radio-flac-decoder",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
