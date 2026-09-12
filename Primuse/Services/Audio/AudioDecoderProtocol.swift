import AVFoundation
import Foundation
import PrimuseKit

// Decoder tasks transfer fully-written buffers to exactly one playback
// consumer. Neither side mutates a buffer after it has been yielded.
extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

typealias AudioBufferStream = BoundedAsyncChannel<AVAudioPCMBuffer>

/// Creates a lossless, bounded PCM stream.
///
/// A fast local decoder can enqueue an entire hi-res track before realtime
/// playback consumes more than a few buffers, so the handoff has to be
/// bounded. `BoundedAsyncChannel` gives it a hard memory bound without
/// dropping audio: `yieldWithBackpressure` suspends the decoder until the
/// playback pump takes a buffer, instead of retrying a dropped buffer on a
/// 10 ms timer for as long as the pump stays parked in its lookahead gate.
enum AudioBufferStreamFactory {
    static let bufferingLimit = 8

    static func make(
        _ build: @escaping (AudioBufferStream.Continuation) -> Void
    ) -> AudioBufferStream {
        AudioBufferStream(capacity: bufferingLimit, build)
    }

    static func yieldWithBackpressure(
        _ buffer: AVAudioPCMBuffer,
        to continuation: AudioBufferStream.Continuation
    ) async throws {
        try Task.checkCancellation()
        try await continuation.send(buffer)
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
