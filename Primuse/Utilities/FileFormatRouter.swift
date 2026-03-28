import Foundation
import PrimuseKit

enum FileFormatRouter {
    private static let nativeDecoder = NativeAudioDecoder()
    private static let ffmpegDecoder = FFmpegAudioDecoder()

    static func decoder(for url: URL) -> AudioDecoder {
        let ext = url.pathExtension.lowercased()
        let format = AudioFormat.from(fileExtension: ext)

        if let format, format.requiresFFmpeg {
            return ffmpegDecoder
        }

        if nativeDecoder.canDecode(url: url) {
            return nativeDecoder
        }

        // Fallback to FFmpeg for unknown formats
        return ffmpegDecoder
    }

    static func decoder(for format: AudioFormat) -> AudioDecoder {
        format.requiresFFmpeg ? ffmpegDecoder : nativeDecoder
    }
}
