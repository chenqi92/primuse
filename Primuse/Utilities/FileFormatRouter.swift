import Foundation
import PrimuseKit

enum FileFormatRouter {
    private static let nativeDecoder = NativeAudioDecoder()

    static func decoder(for url: URL) -> PrimuseAudioDecoder {
        // SFBAudioEngine-backed NativeDecoder handles all formats:
        // FLAC, MP3, AAC, ALAC, WAV, AIFF, APE, WV, TTA, DSD, Ogg, Musepack, etc.
        nativeDecoder
    }

    static func decoder(for format: AudioFormat) -> PrimuseAudioDecoder {
        nativeDecoder
    }
}
