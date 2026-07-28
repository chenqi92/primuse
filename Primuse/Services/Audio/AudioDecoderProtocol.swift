import AVFoundation
import Foundation

// Decoder tasks transfer fully-written buffers to exactly one playback
// consumer. Neither side mutates a buffer after it has been yielded.
extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

typealias AudioBufferStream = AsyncThrowingStream<AVAudioPCMBuffer, Error>

/// Creates a lossless, bounded PCM stream.
///
/// `AsyncThrowingStream` is unbounded by default and its `yield` API is
/// synchronous. A fast local decoder can therefore enqueue an entire hi-res
/// track before realtime playback consumes more than a few buffers. Using
/// `.bufferingOldest` gives the stream a hard memory bound; when the buffer is
/// full, `yieldWithBackpressure` retries the same (not-yet-enqueued) buffer
/// after a short suspension instead of dropping audio.
enum AudioBufferStreamFactory {
    static let bufferingLimit = 8
    private static let retryDelayNanos: UInt64 = 10_000_000

    static func make(
        _ build: @escaping (AudioBufferStream.Continuation) -> Void
    ) -> AudioBufferStream {
        AudioBufferStream(bufferingPolicy: .bufferingOldest(bufferingLimit), build)
    }

    static func yieldWithBackpressure(
        _ buffer: AVAudioPCMBuffer,
        to continuation: AudioBufferStream.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(buffer) {
            case .enqueued:
                return
            case .dropped:
                // `.bufferingOldest` drops the new element when full, so the
                // caller still owns `buffer` and can safely retry it.
                try await Task.sleep(nanoseconds: retryDelayNanos)
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }
}

struct AudioFileInfo: Sendable {
    var duration: TimeInterval
    var sampleRate: Double
    var channelCount: Int
    var bitDepth: Int?
    var bitRate: Int?
    var format: String
}

protocol PrimuseAudioDecoder: Sendable {
    func canDecode(url: URL) -> Bool
    func fileInfo(for url: URL) async throws -> AudioFileInfo
    func decode(from url: URL, outputFormat: AVAudioFormat) -> AudioBufferStream
}
