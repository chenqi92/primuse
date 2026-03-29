import AVFoundation
import Foundation

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
    func decode(from url: URL, outputFormat: AVAudioFormat) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
}
