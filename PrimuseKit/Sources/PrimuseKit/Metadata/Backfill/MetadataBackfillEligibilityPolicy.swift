import Foundation

public struct MetadataBackfillWorkReasons: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let duration = Self(rawValue: 1 << 0)
    public static let artwork = Self(rawValue: 1 << 1)
    public static let title = Self(rawValue: 1 << 2)
    public static let albumArtist = Self(rawValue: 1 << 3)
    public static let artist = Self(rawValue: 1 << 4)
    /// M4A 还不知道装的是 AAC 还是 ALAC。
    public static let audioCodec = Self(rawValue: 1 << 5)
    /// 24 bit 的 FLAC 还没查是不是 16 bit 补零。
    public static let effectiveBitDepth = Self(rawValue: 1 << 6)
    public static let contentMetadata = Self(rawValue: 1 << 7)
}

/// Shared predicate for the background metadata pipeline. Each inspection leg
/// is completed independently so an absent optional tag does not make a valid
/// song eligible forever.
public enum MetadataBackfillEligibilityPolicy {
    /// Formats whose bounded reader can recover an embedded cover without
    /// materializing the complete remote audio file.
    public static let embeddedArtworkFormats: Set<AudioFormat> = [
        .mp3, .flac, .m4a, .alac,
        .ape, .wv, .mpc, .tta,
        .ogg, .opus, .speex,
        .wma, .dsf, .dff,
        .wav, .aiff, .aif,
    ]

    /// Bare inventory sources stop refreshing text after the first metadata
    /// read; missing artwork and technical fields retain their own inspection.
    /// STRM rows are descriptors rather than audio files, so they keep
    /// their existing enrichment path instead of inheriting that shortcut.
    public static func restrictsToBareRows(
        sourceUsesBareInventory: Bool,
        isStreamDescriptor: Bool
    ) -> Bool {
        sourceUsesBareInventory && !isStreamDescriptor
    }

    public static func reasons(
        duration: TimeInterval,
        format: AudioFormat,
        hasCoverArt: Bool,
        artworkGivenUp: Bool,
        titleChecked: Bool,
        restrictToBareRows: Bool = false,
        durationInspectionComplete: Bool = false,
        hasAlbumTitle: Bool = false,
        hasAlbumArtist: Bool = true,
        albumArtistChecked: Bool = true,
        albumArtistUnconfirmed: Bool = false,
        hasArtist: Bool = true,
        artistChecked: Bool = true,
        audioCodecUnread: Bool = false,
        effectiveBitDepthUnread: Bool = false,
        contentMetadataUnread: Bool = false,
        containerCodecOnly: Bool = false
    ) -> MetadataBackfillWorkReasons {
        // 服务端曲库源: 目录信息以服务端为准, 只为认编码读一次文件头。
        if containerCodecOnly {
            return audioCodecUnread ? [.audioCodec] : []
        }
        if restrictToBareRows, duration > 0 || durationInspectionComplete {
            // 时长已知不代表封面读过。封面、专辑艺术家和技术信息各自完成后
            // 才停止补读, 不重新打开已经结束的标题/艺术家检查。
            var reasons: MetadataBackfillWorkReasons = hasAlbumTitle && albumArtistUnconfirmed
                ? [.albumArtist] : []
            if embeddedArtworkFormats.contains(format) && !hasCoverArt && !artworkGivenUp {
                reasons.insert(.artwork)
            }
            if audioCodecUnread { reasons.insert(.audioCodec) }
            if effectiveBitDepthUnread { reasons.insert(.effectiveBitDepth) }
            if contentMetadataUnread { reasons.insert(.contentMetadata) }
            return reasons
        }
        var reasons: MetadataBackfillWorkReasons = contentMetadataUnread ? [.contentMetadata] : []
        if audioCodecUnread {
            reasons.insert(.audioCodec)
        }
        if effectiveBitDepthUnread {
            reasons.insert(.effectiveBitDepth)
        }
        if duration <= 0 && !durationInspectionComplete {
            reasons.insert(.duration)
        }
        if embeddedArtworkFormats.contains(format) && !hasCoverArt && !artworkGivenUp {
            reasons.insert(.artwork)
        }
        if !titleChecked {
            reasons.insert(.title)
        }
        // A stored album artist can be the per-track fallback rather than a tag
        // the source ever supplied, and `albumArtistChecked` is set by any pass
        // that read the file for some other reason. Together they make one pass
        // that missed ALBUMARTIST permanent. `albumArtistUnconfirmed` is the
        // caller's library-wide verdict that this row's value settles nothing;
        // it carries its own one-shot marker, so it cannot loop.
        if hasAlbumTitle && ((!hasAlbumArtist && !albumArtistChecked) || albumArtistUnconfirmed) {
            reasons.insert(.albumArtist)
        }
        if !hasArtist && !artistChecked {
            reasons.insert(.artist)
        }
        return reasons
    }

    public static func needsBackfill(
        duration: TimeInterval,
        format: AudioFormat,
        hasCoverArt: Bool,
        artworkGivenUp: Bool,
        titleChecked: Bool,
        restrictToBareRows: Bool = false,
        durationInspectionComplete: Bool = false,
        hasAlbumTitle: Bool = false,
        hasAlbumArtist: Bool = true,
        albumArtistChecked: Bool = true,
        albumArtistUnconfirmed: Bool = false,
        hasArtist: Bool = true,
        artistChecked: Bool = true,
        audioCodecUnread: Bool = false,
        effectiveBitDepthUnread: Bool = false,
        contentMetadataUnread: Bool = false,
        containerCodecOnly: Bool = false
    ) -> Bool {
        !reasons(
            duration: duration,
            format: format,
            hasCoverArt: hasCoverArt,
            artworkGivenUp: artworkGivenUp,
            titleChecked: titleChecked,
            restrictToBareRows: restrictToBareRows,
            durationInspectionComplete: durationInspectionComplete,
            hasAlbumTitle: hasAlbumTitle,
            hasAlbumArtist: hasAlbumArtist,
            albumArtistChecked: albumArtistChecked,
            albumArtistUnconfirmed: albumArtistUnconfirmed,
            hasArtist: hasArtist,
            artistChecked: artistChecked,
            audioCodecUnread: audioCodecUnread,
            effectiveBitDepthUnread: effectiveBitDepthUnread,
            contentMetadataUnread: contentMetadataUnread,
            containerCodecOnly: containerCodecOnly
        ).isEmpty
    }
}
