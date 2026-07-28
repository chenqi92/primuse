import Foundation
import PrimuseKit

enum FileFormatRouter {
    private static let nativeDecoder = NativeAudioDecoder()
    private static let ffmpegDecoder = FFmpegAudioDecoder()

    static func decoder(for url: URL) -> PrimuseAudioDecoder {
        // A DTS-CD image looks like ordinary PCM WAV by extension, so content
        // sniffing must happen before SFBAudioEngine accepts it as WAV.
        if url.pathExtension.caseInsensitiveCompare("wav") == .orderedSame,
           ffmpegDecoder.canDecode(url: url) {
            return ffmpegDecoder
        }
        // SFBAudioEngine is the high-fidelity primary path for Core Audio,
        // lossless/legacy formats and DSD/DoP-capable sources.
        if nativeDecoder.canDecode(url: url) { return nativeDecoder }
        // FFmpeg is the broad compatibility fallback and content probe.
        return ffmpegDecoder
    }

    static func decoder(for format: AudioFormat) -> PrimuseAudioDecoder {
        switch format {
        // Raw ADTS AAC can report a short, incorrect frame count through SFB
        // and may then fail before the first PCM buffer. FFmpeg parses its
        // complete packet timeline and keeps both playback and persisted
        // duration authoritative. M4A/MP4 AAC remains on the native path.
        case .aac, .dts, .ac3, .eac3, .mlp, .truehd, .amr, .atrac, .tak, .wma, .qoa:
            return ffmpegDecoder
        default:
            return nativeDecoder
        }
    }

    /// Formats that cannot use the generic SFB `InputSource` range path.
    /// FFmpeg needs a seekable demuxer here, while DSD needs either the native
    /// DSD decoder/DoP wrapper or the FFmpeg DSD-to-PCM fallback after the file
    /// has a stable local URL.
    static func requiresCompleteLocalFile(_ format: AudioFormat) -> Bool {
        format == .dsf || format == .dff || decoder(for: format) is FFmpegAudioDecoder
    }
}
