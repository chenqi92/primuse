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

    // Containers only FFmpeg opens on every platform. Matroska/WebM carry
    // FLAC, Opus, Vorbis or AAC; `.w64`/`.rf64` are the >4 GB successors of
    // WAV; `.ra` is RealAudio (Cook/Sipr/ATRAC3 and friends).
    case mka
    case webm
    case mp2
    case w64
    case rf64
    case ra

    // Tracker modules, rendered by SFBAudioEngine's DUMB decoder. One case
    // per extension because SFB picks that decoder by path extension, and
    // cached copies are named after `rawValue`.
    case mod
    case xm
    case it
    case s3m
    case stm
    case mtm
    case ptm
    case okt
    case composer669 = "669"

    public var isTrackerModule: Bool {
        switch self {
        case .mod, .xm, .it, .s3m, .stm, .mtm, .ptm, .okt, .composer669: true
        default: false
        }
    }

    public var requiresFFmpeg: Bool {
        // Kept as the historical API name. In practice this means the format
        // needs the SFBAudioEngine/FFmpeg custom decode pipeline.
        switch self {
        case .mp3, .aac, .m4a, .mp4, .m4v, .mov, .alac, .flac, .wav, .aiff, .aif, .au, .caf:
            return false
        case .ape, .dsf, .dff, .ogg, .opus, .wma, .wv, .dts,
             .ac3, .eac3, .mlp, .truehd, .amr, .atrac, .tak, .tta,
             .mpc, .shn, .speex, .qoa, .mka, .webm, .mp2, .w64, .rf64, .ra,
             .mod, .xm, .it, .s3m, .stm, .mtm, .ptm, .okt, .composer669:
            return true
        }
    }

    /// Formats that go straight to FFmpeg instead of SFBAudioEngine. SFB has
    /// no decoder for most of them (WMA, DTS, TrueHD, ATRAC, TAK, QOA,
    /// Matroska/WebM, RealAudio); raw ADTS AAC reports a short frame count
    /// through it, and its packed 24-bit True Audio path crashes while
    /// releasing PCM buffers. MP2, Wave64 and RF64 are claimed by Core Audio
    /// or libsndfile on some platforms only, so FFmpeg keeps them identical
    /// everywhere.
    /// iOS, macOS and tvOS all route by this one list.
    public var prefersFFmpegDecoder: Bool {
        switch self {
        case .aac, .dts, .ac3, .eac3, .mlp, .truehd, .amr, .atrac, .tak, .wma, .qoa, .tta,
             .mka, .webm, .mp2, .w64, .rf64, .ra:
            return true
        case .mp3, .m4a, .mp4, .m4v, .mov, .alac, .flac, .wav, .aiff, .aif, .au, .caf,
             .ape, .dsf, .dff, .ogg, .opus, .wv, .mpc, .shn, .speex,
             .mod, .xm, .it, .s3m, .stm, .mtm, .ptm, .okt, .composer669:
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
        case .mka: return "Matroska"
        case .webm: return "WebM"
        case .mp2: return "MP2"
        case .w64: return "Wave64"
        case .rf64: return "RF64"
        case .ra: return "RealAudio"
        case .mod: return "MOD"
        case .xm: return "XM"
        case .it: return "IT"
        case .s3m: return "S3M"
        case .stm: return "STM"
        case .mtm: return "MTM"
        case .ptm: return "PTM"
        case .okt: return "Oktalyzer"
        case .composer669: return "669"
        }
    }

    public var isLossless: Bool {
        switch self {
        case .flac, .alac, .wav, .aiff, .aif, .au, .caf, .ape, .dsf, .dff,
             .wv, .mlp, .truehd, .tak, .tta, .shn, .w64, .rf64:
            return true
        // Matroska is a container: FLAC inside `.mka` is lossless, Opus is
        // not. Without the codec on the song, claim nothing.
        case .mp3, .aac, .m4a, .mp4, .m4v, .mov, .ogg, .opus, .wma, .dts,
             .ac3, .eac3, .amr, .atrac, .mpc, .speex, .qoa, .mka, .webm, .mp2, .ra,
             .mod, .xm, .it, .s3m, .stm, .mtm, .ptm, .okt, .composer669:
            return false
        }
    }

    public static func from(fileExtension ext: String) -> AudioFormat? {
        switch ext.lowercased() {
        case "asf": return .wma
        // Audiobook/spoken-word MP4. Same container as `.m4a`, and mapping it
        // here keeps scan and backfill on one value: the ISO base-media
        // signature also resolves to `m4a`, so the two can never disagree.
        case "m4b": return .m4a
        // iPhone ringtones: an AAC `.m4a` under another name.
        case "m4r": return .m4a
        // Compressed AIFF and Broadcast WAV are the same containers the
        // native decoders and the AIFF/RIFF parsers already read; the file
        // signature resolves them to `aiff`/`wav` as well.
        case "aifc": return .aiff
        case "bwf": return .wav
        case "weba": return .webm
        case "mpa", "mp1", "m2a": return .mp2
        case "bw64": return .rf64
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
             .mpc, .shn, .speex, .qoa, .mka, .webm, .mp2, .w64, .rf64, .ra,
             .mod, .xm, .it, .s3m, .stm, .mtm, .ptm, .okt, .composer669: return nil
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

    /// Sources whose connectors implement guarded replacement and readback,
    /// including relocation when a provider assigns a new file ID.
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
        .pan123,
        .drime,
        .aliyunDrive,
        .googleDrive,
        .oneDrive,
        .dropbox,
    ]

    public static let serverAPISourceTypes: Set<MusicSourceType> = [
        .jellyfin,
        .emby,
        .plex,
        .airsonic,
        .fnMusic,
        .synologyAudioStation,
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

/// Where saved lyrics go for songs whose audio file can take them.
///
/// The sidecar is the lossless copy: a few kilobytes, word timing and
/// translation tracks intact, and the media object is never touched. The
/// embedded copy travels with the file to players that only read tags, at the
/// price of downloading, rewriting and re-uploading the whole song on every
/// save — so it is opt-in, and library-wide scraping never embeds.
public enum LyricsEmbeddingMode: String, CaseIterable, Sendable {
    /// Lyrics file only. The default, and the only behaviour before embedding.
    case off
    /// Lyrics file, plus a line-timed copy inside the audio file.
    case alongside
    /// Inside the audio file only: no new lyrics file is created. A lyrics
    /// document that already sits beside the song is still kept up to date,
    /// otherwise its stale text would win on the paths that read files first.
    case embedOnly

    /// Order of how far a mode reaches into the user's files. Moving up needs
    /// the user to confirm what that costs; moving down never does.
    var invasiveness: Int {
        switch self {
        case .off: return 0
        case .alongside: return 1
        case .embedOnly: return 2
        }
    }
}

public enum EmbeddedLyricsCopyPolicy {
    public static let modeDefaultsKey = "primuse.lyrics.embedMode"
    /// The first build of this feature stored an on/off switch, which meant
    /// "lyrics file and audio file".
    static let legacyEnabledDefaultsKey = "primuse.lyrics.embedCopyEnabled"

    public static func mode(defaults: UserDefaults = .standard) -> LyricsEmbeddingMode {
        if let raw = defaults.string(forKey: modeDefaultsKey),
           let mode = LyricsEmbeddingMode(rawValue: raw) {
            return mode
        }
        return defaults.bool(forKey: legacyEnabledDefaultsKey) ? .alongside : .off
    }

    public static func setMode(_ mode: LyricsEmbeddingMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeDefaultsKey)
        defaults.removeObject(forKey: legacyEnabledDefaultsKey)
    }

    public static func requiresConfirmation(
        from current: LyricsEmbeddingMode,
        to requested: LyricsEmbeddingMode
    ) -> Bool {
        requested.invasiveness > current.invasiveness
    }

    /// Same sources and formats as embedded tag editing: the copy goes through
    /// the identical guarded replacement of the media object. Songs outside
    /// this set keep writing lyrics files whatever the mode says.
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

    /// The mode that applies to one song: `.off` whenever its file cannot be
    /// embedded into.
    public static func effectiveMode(
        _ mode: LyricsEmbeddingMode,
        sourceType: MusicSourceType,
        format: AudioFormat,
        isCueTrack: Bool,
        isStreamDescriptor: Bool
    ) -> LyricsEmbeddingMode {
        guard mode != .off,
              canEmbed(
                  sourceType: sourceType,
                  format: format,
                  isCueTrack: isCueTrack,
                  isStreamDescriptor: isStreamDescriptor
              ) else {
            return .off
        }
        return mode
    }

    /// Whether a save may leave the lyrics file out. Only embed-only mode does,
    /// and only while no lyrics document of any kind sits beside the song.
    public static func skipsLyricsFile(
        _ effectiveMode: LyricsEmbeddingMode,
        lyricsDocumentExists: Bool
    ) -> Bool {
        effectiveMode == .embedOnly && !lyricsDocumentExists
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
    case f4v
    case wmv
    case ts
    case m2ts
    case mpg
    case vob
    case rmvb
    case ogv
    case threeGP = "3gp"

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
        case .f4v: return "F4V"
        case .wmv: return "WMV"
        case .ts: return "MPEG-TS"
        case .m2ts: return "M2TS"
        case .mpg: return "MPEG"
        case .vob: return "VOB"
        case .rmvb: return "RMVB"
        case .ogv: return "Ogg Video"
        case .threeGP: return "3GP"
        }
    }

    /// Formats AVPlayer opens as they are. Everything else is rewritten into
    /// MP4 first (`MusicVideoCompatibilityPolicy`).
    public var isNativelyPlayable: Bool {
        switch self {
        case .mp4, .m4v, .mov, .m3u8:
            return true
        case .mkv, .webm, .avi, .flv, .f4v, .wmv, .ts, .m2ts, .mpg, .vob, .rmvb, .ogv, .threeGP:
            return false
        }
    }

    public static func from(fileExtension ext: String) -> VideoFormat? {
        switch ext.lowercased() {
        case "divx": return .avi
        case "mpeg", "m1v", "m2v": return .mpg
        case "mts", "m2t": return .m2ts
        case "rm": return .rmvb
        case "3g2": return .threeGP
        default: return VideoFormat(rawValue: ext.lowercased())
        }
    }
}

/// Rewriting a music video AVPlayer cannot open into MP4: which streams can
/// keep their bytes (a remux takes seconds) and which must be decoded and
/// re-encoded — video to H.264 through VideoToolbox, audio to AAC.
///
/// A copied stream must be one AVPlayer decodes on every device of the
/// platform; the MP4 muxer accepting it is not enough, since AVFoundation
/// reports a 10-bit H.264 track as playable and then shows nothing.
public enum MusicVideoCompatibilityPolicy {
    public enum StreamKind: Sendable, Equatable {
        case video
        case audio
    }

    public struct Stream: Sendable, Equatable {
        public var kind: StreamKind
        /// FFmpeg's codec descriptor name (`h264`, `hevc`, `aac`...).
        public var codecName: String
        /// FFmpeg `AV_PROFILE_*` value; -99 when unknown.
        public var profile: Int
        /// Bits per component; 0 when unknown.
        public var bitDepth: Int
        /// 4:2:0 chroma, or no pixel format declared.
        public var chroma420: Bool

        public init(kind: StreamKind, codecName: String, profile: Int = -99, bitDepth: Int = 0, chroma420: Bool = true) {
            self.kind = kind
            self.codecName = codecName
            self.profile = profile
            self.bitDepth = bitDepth
            self.chroma420 = chroma420
        }
    }

    public struct Platform: Sendable, Equatable {
        /// VideoToolbox decodes AV1 in hardware (A17 Pro / M3 and later).
        /// FFmpeg has no software AV1 decoder here, so elsewhere the video
        /// is dropped and the song keeps its sound.
        public var decodesAV1: Bool
        /// ProRes decodes on every Mac; on iPhone and Apple TV it is
        /// re-encoded rather than trusted to the device generation.
        public var decodesProRes: Bool

        public init(decodesAV1: Bool, decodesProRes: Bool) {
            self.decodesAV1 = decodesAV1
            self.decodesProRes = decodesProRes
        }
    }

    /// H.264 Baseline, Constrained Baseline, Main and High, plus unknown.
    private static let copyableH264Profiles: Set<Int> = [66, 578, 77, 100, -99]
    /// HEVC Main and Main 10, plus unknown.
    private static let copyableHEVCProfiles: Set<Int> = [1, 2, -99]
    /// MP3 is missing on purpose: MP3 inside MP4 opens as a playable track
    /// in AVFoundation and then decodes to nothing (AVI and FLV music videos
    /// measured on macOS 27), so it is re-encoded like any other codec.
    private static let copyableAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "alac"]

    public static func canCopy(_ stream: Stream, on platform: Platform) -> Bool {
        switch stream.kind {
        case .audio:
            return copyableAudioCodecs.contains(stream.codecName)
        case .video:
            switch stream.codecName {
            case "h264":
                return copyableH264Profiles.contains(stream.profile)
                    && stream.bitDepth <= 8 && stream.chroma420
            case "hevc":
                return copyableHEVCProfiles.contains(stream.profile)
                    && stream.bitDepth <= 10 && stream.chroma420
            case "av1":
                return platform.decodesAV1 && stream.bitDepth <= 10 && stream.chroma420
            case "prores":
                return platform.decodesProRes
            default:
                return false
            }
        }
    }

    /// Whether a music video at this path has to be rewritten before
    /// AVPlayer can play it. URLs with a scheme are left alone: a server
    /// that hands out a stream URL is expected to transcode itself.
    public static func needsConversion(path: String) -> Bool {
        if let url = URL(string: path), url.scheme?.isEmpty == false { return false }
        let ext = (path as NSString).pathExtension
        return VideoFormat.from(fileExtension: ext)?.isNativelyPlayable == false
    }

    /// Cache for rewritten videos. Apple TV's caches are purged by the
    /// system and its storage is small, so it keeps less.
    public static let cacheByteBudget: Int64 = 3 * 1024 * 1024 * 1024
    public static let tvCacheByteBudget: Int64 = 1024 * 1024 * 1024

    public struct CacheEntry: Sendable, Equatable {
        public var name: String
        public var byteCount: Int64
        public var lastAccess: Date

        public init(name: String, byteCount: Int64, lastAccess: Date) {
            self.name = name
            self.byteCount = byteCount
            self.lastAccess = lastAccess
        }
    }

    /// Least recently played first until the rest fits the budget. The
    /// video about to play is never evicted, even when it alone is larger.
    public static func evictionVictims(
        _ entries: [CacheEntry],
        budget: Int64,
        keeping kept: String?
    ) -> [String] {
        var total = entries.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }
        guard total > budget else { return [] }
        var victims: [String] = []
        for entry in entries.sorted(by: { $0.lastAccess < $1.lastAccess }) where entry.name != kept {
            victims.append(entry.name)
            total -= max(0, entry.byteCount)
            if total <= budget { break }
        }
        return victims
    }
}
