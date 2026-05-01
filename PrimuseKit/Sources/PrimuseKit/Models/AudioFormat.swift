import Foundation

public enum AudioFormat: String, Codable, Sendable, CaseIterable {
    // Native (AVAudioFile) formats
    case mp3
    case aac
    case m4a
    case mp4
    case alac
    case flac
    case wav
    case aiff
    case aif

    // FFmpeg-required formats
    case ape
    case dsf
    case dff
    case ogg
    case opus
    case wma
    case wv

    public var requiresFFmpeg: Bool {
        switch self {
        case .mp3, .aac, .m4a, .mp4, .alac, .flac, .wav, .aiff, .aif:
            return false
        case .ape, .dsf, .dff, .ogg, .opus, .wma, .wv:
            return true
        }
    }

    public var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .m4a: return "M4A"
        case .mp4: return "MP4"
        case .alac: return "ALAC"
        case .flac: return "FLAC"
        case .wav: return "WAV"
        case .aiff, .aif: return "AIFF"
        case .ape: return "APE"
        case .dsf: return "DSD (DSF)"
        case .dff: return "DSD (DFF)"
        case .ogg: return "OGG Vorbis"
        case .opus: return "Opus"
        case .wma: return "WMA"
        case .wv: return "WavPack"
        }
    }

    public var isLossless: Bool {
        switch self {
        case .flac, .alac, .wav, .aiff, .aif, .ape, .dsf, .dff, .wv:
            return true
        case .mp3, .aac, .m4a, .mp4, .ogg, .opus, .wma:
            return false
        }
    }

    public static func from(fileExtension ext: String) -> AudioFormat? {
        AudioFormat(rawValue: ext.lowercased())
    }

    /// UTI / file-type identifier for `AVAssetResourceLoadingContentInformationRequest.contentType`.
    /// Returns nil for formats AVPlayer can't play natively (FFmpeg-required) —
    /// caller falls back to full-download playback for those.
    public var avPlayerContentType: String? {
        switch self {
        case .mp3: return "public.mp3"
        case .aac, .m4a, .mp4, .alac: return "public.mpeg-4-audio"
        case .flac: return "org.xiph.flac"
        case .wav: return "com.microsoft.waveform-audio"
        case .aiff, .aif: return "public.aiff-audio"
        case .ape, .dsf, .dff, .ogg, .opus, .wma, .wv: return nil
        }
    }
}
