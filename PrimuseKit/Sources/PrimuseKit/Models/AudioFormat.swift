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

    /// Formats that go straight to FFmpeg instead of SFBAudioEngine. SFB has
    /// no decoder for most of them (WMA, DTS, TrueHD, ATRAC, TAK, QOA); raw
    /// ADTS AAC reports a short frame count through it, and its packed 24-bit
    /// True Audio path crashes while releasing PCM buffers.
    /// iOS, macOS and tvOS all route by this one list.
    public var prefersFFmpegDecoder: Bool {
        switch self {
        case .aac, .dts, .ac3, .eac3, .mlp, .truehd, .amr, .atrac, .tak, .wma, .qoa, .tta:
            return true
        case .mp3, .m4a, .mp4, .m4v, .mov, .alac, .flac, .wav, .aiff, .aif, .au, .caf,
             .ape, .dsf, .dff, .ogg, .opus, .wv, .mpc, .shn, .speex:
            return false
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
        case "asf": return .wma
        case "oga": return .ogg
        case "wave": return .wav
        case "awb": return .amr
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

    /// 回填会用文件签名把扫描按扩展名猜出的格式修正掉 —— `.wav` 容器里装的
    /// DTS 流最终存成 `.dts`。修正只发生在读过字节的一侧: 此后扫描永远给
    /// `.wav`、库里永远是 `.dts`, 两个值再也不会相等。
    ///
    /// 新增任何「按签名修正格式」的逻辑时必须同步往这里加一对, 否则那条
    /// 修正就会让扫描与库永久分歧。
    private static let signatureRefinements: [Set<AudioFormat>] = [
        [.wav, .dts],
    ]

    /// 这两个格式是否可能描述同一份字节。
    ///
    /// 用在「文件内容有没有变」的判断上: 指纹一致时两边格式不等只说明识别
    /// 口径不同, 不是文件被换过。把它当成内容变化会每次扫描都清掉已经补好
    /// 的时长、标签和封面, 回填再补回来, 循环往复。
    public static func describeSameBytes(_ lhs: AudioFormat, _ rhs: AudioFormat) -> Bool {
        lhs == rhs || signatureRefinements.contains([lhs, rhs])
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

/// Describes what the tag editor can persist for a source/format pair.
/// Sidecar-only sources can store artwork or lyrics next to the audio, but
/// that is intentionally distinct from changing the audio file's embedded
/// metadata.
public enum AudioMetadataWritebackCapability: Sendable, Equatable {
    case embedded
    case serverAPI
    case sidecarOnly
    case localOnly
}

public enum AudioMetadataWritebackPolicy {
    /// Formats whose native metadata containers are verified by Primuse's
    /// writer: ID3v2/APIC, FLAC Vorbis comments/PICTURE, and MP4 `ilst`/`covr`.
    public static let embeddedFormats: Set<AudioFormat> = [.mp3, .flac, .m4a]

    /// File-addressed sources whose connectors implement the common guarded
    /// replace transaction. Providers that replace an object by assigning a
    /// new opaque ID are intentionally excluded until their library identity
    /// can be migrated atomically with the remote object.
    public static let embeddedSourceTypes: Set<MusicSourceType> = [
        .local,
        .synology,
        .qnap,
        .webdav,
        .smb,
        .ftp,
        .sftp,
        .nfs,
        .s3,
        .baiduPan,
        .aliyunDrive,
        .googleDrive,
        .oneDrive,
        .dropbox,
    ]

    public static let serverAPISourceTypes: Set<MusicSourceType> = [
        .jellyfin,
        .emby,
        .plex,
    ]

    public static func capability(
        sourceType: MusicSourceType,
        format: AudioFormat
    ) -> AudioMetadataWritebackCapability {
        if serverAPISourceTypes.contains(sourceType) {
            return .serverAPI
        }
        if embeddedSourceTypes.contains(sourceType), embeddedFormats.contains(format) {
            return .embedded
        }
        if sourceType.supportsSidecarWriting {
            return .sidecarOnly
        }
        return .localOnly
    }
}

/// Whether saved lyrics are also stored inside the audio file.
///
/// The sidecar stays the primary copy: it is a few kilobytes, carries word
/// timing and translation tracks, and never touches the media object. The
/// embedded copy travels with the file to players that only read tags, at the
/// price of downloading, rewriting and re-uploading the whole song — so it is
/// opt-in, and library-wide scraping never takes part in it.
public enum EmbeddedLyricsCopyPolicy {
    public static let enabledDefaultsKey = "primuse.lyrics.embedCopyEnabled"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    /// Same sources and formats as embedded tag editing: the copy goes through
    /// the identical guarded replacement of the media object.
    public static func canEmbed(
        sourceType: MusicSourceType,
        format: AudioFormat,
        isCueTrack: Bool,
        isStreamDescriptor: Bool
    ) -> Bool {
        guard !isCueTrack, !isStreamDescriptor else { return false }
        return AudioMetadataWritebackPolicy.capability(
            sourceType: sourceType,
            format: format
        ) == .embedded
    }
}

/// Request preconditions shared by WebDAV media and sidecar replacements.
/// Primuse only treats a quoted, non-weak ETag as a concurrency token.
public enum WebDAVWritebackPolicy {
    public static func strongETag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.lowercased().hasPrefix("w/"),
              trimmed.first == "\"",
              trimmed.last == "\"" else {
            return nil
        }
        return trimmed
    }

    public static func taggedDestinationCondition(
        destinationURL: URL,
        strongETag: String
    ) -> String? {
        guard self.strongETag(strongETag) != nil else { return nil }
        return "<\(destinationURL.absoluteString)> ([\(strongETag)])"
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
