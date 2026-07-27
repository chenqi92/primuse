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
    case au
    case caf

    // Video containers — used by standalone music-video songs
    // (Song.isStandaloneMusicVideo), which play through AVPlayer.
    case m4v
    case mov

    // SFBAudioEngine / FFmpeg formats that AVFoundation does not decode
    // consistently across Apple platforms.
    case ape
    case dsf
    case dff
    case ogg
    case opus
    case wma
    case wv
    case dts
    case ac3
    case eac3
    case mlp
    case truehd
    case amr
    case atrac
    case tak
    case tta
    case mpc
    case shn
    case speex
    case qoa

    public var requiresFFmpeg: Bool {
        // Kept as the historical API name. In practice this means the format
        // needs the SFBAudioEngine/FFmpeg custom decode pipeline.
        switch self {
        case .mp3, .aac, .m4a, .mp4, .m4v, .mov, .alac, .flac, .wav, .aiff, .aif, .au, .caf:
            return false
        case .ape, .dsf, .dff, .ogg, .opus, .wma, .wv, .dts,
             .ac3, .eac3, .mlp, .truehd, .amr, .atrac, .tak, .tta,
             .mpc, .shn, .speex, .qoa:
            return true
        }
    }

    public var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .m4a: return "M4A"
        case .mp4: return "MP4"
        case .m4v: return "M4V"
        case .mov: return "MOV"
        case .alac: return "ALAC"
        case .flac: return "FLAC"
        case .wav: return "WAV"
        case .aiff, .aif: return "AIFF"
        case .au: return "AU"
        case .caf: return "CAF"
        case .ape: return "APE"
        case .dsf: return "DSD (DSF)"
        case .dff: return "DSD (DFF)"
        case .ogg: return "OGG Vorbis"
        case .opus: return "Opus"
        case .wma: return "WMA"
        case .wv: return "WavPack"
        case .dts: return "DTS"
        case .ac3: return "Dolby Digital (AC-3)"
        case .eac3: return "Dolby Digital Plus (E-AC-3)"
        case .mlp: return "MLP"
        case .truehd: return "Dolby TrueHD"
        case .amr: return "AMR"
        case .atrac: return "ATRAC"
        case .tak: return "TAK"
        case .tta: return "TTA"
        case .mpc: return "Musepack"
        case .shn: return "Shorten"
        case .speex: return "Speex"
        case .qoa: return "QOA"
        }
    }

    public var isLossless: Bool {
        switch self {
        case .flac, .alac, .wav, .aiff, .aif, .au, .caf, .ape, .dsf, .dff,
             .wv, .mlp, .truehd, .tak, .tta, .shn:
            return true
        case .mp3, .aac, .m4a, .mp4, .m4v, .mov, .ogg, .opus, .wma, .dts,
             .ac3, .eac3, .amr, .atrac, .mpc, .speex, .qoa:
            return false
        }
    }

    public static func from(fileExtension ext: String) -> AudioFormat? {
        switch ext.lowercased() {
        case "ec3": return .eac3
        case "thd": return .truehd
        case "dtshd", "dts-hd", "dtswav": return .dts
        case "oma", "aa3", "at3": return .atrac
        case "mpp": return .mpc
        case "spx": return .speex
        case "snd": return .au
        default: return AudioFormat(rawValue: ext.lowercased())
        }
    }

    /// UTI / file-type identifier for `AVAssetResourceLoadingContentInformationRequest.contentType`.
    /// Returns nil for formats AVPlayer can't play natively (FFmpeg-required) —
    /// caller falls back to full-download playback for those.
    public var avPlayerContentType: String? {
        switch self {
        case .mp3: return "public.mp3"
        case .aac, .m4a, .mp4, .alac: return "public.mpeg-4-audio"
        case .m4v: return "public.mpeg-4"
        case .mov: return "com.apple.quicktime-movie"
        case .flac: return "org.xiph.flac"
        case .wav: return "com.microsoft.waveform-audio"
        case .aiff, .aif: return "public.aiff-audio"
        case .au: return "public.au-audio"
        case .caf: return "com.apple.coreaudio-format"
        case .ape, .dsf, .dff, .ogg, .opus, .wma, .wv, .dts,
             .ac3, .eac3, .mlp, .truehd, .amr, .atrac, .tak, .tta,
             .mpc, .shn, .speex, .qoa: return nil
        }
    }
}

public enum VideoFormat: String, Codable, Sendable, CaseIterable {
    case mp4
    case m4v
    case mov
    case m3u8
    case mkv
    case webm
    case avi
    case flv
    case wmv
    case ts

    public var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .m4v: return "M4V"
        case .mov: return "MOV"
        case .m3u8: return "HLS"
        case .mkv: return "MKV"
        case .webm: return "WebM"
        case .avi: return "AVI"
        case .flv: return "FLV"
        case .wmv: return "WMV"
        case .ts: return "MPEG-TS"
        }
    }

    /// Formats AVPlayer can consume directly in the first MV implementation.
    public var isNativelyPlayable: Bool {
        switch self {
        case .mp4, .m4v, .mov, .m3u8:
            return true
        case .mkv, .webm, .avi, .flv, .wmv, .ts:
            return false
        }
    }

    public static func from(fileExtension ext: String) -> VideoFormat? {
        VideoFormat(rawValue: ext.lowercased())
    }
}
