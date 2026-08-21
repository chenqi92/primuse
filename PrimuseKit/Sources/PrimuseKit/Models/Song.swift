import CoreFoundation
import Foundation
import GRDB

public struct Song: Codable, Identifiable, Hashable, Sendable {
    public var id: String // SHA256 of sourceID + relativePath
    public var title: String
    public var albumID: String?
    public var artistID: String?
    public var albumTitle: String?
    public var artistName: String?
    /// Effective album artist used for album grouping. Full metadata readers
    /// store the embedded album artist when available and otherwise fall back
    /// to the track artist, so a nil value also identifies legacy rows that
    /// have not yet inspected this field.
    public var albumArtistName: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval
    public var fileFormat: AudioFormat
    public var filePath: String // relative within source
    public var sourceID: String
    public var fileSize: Int64
    /// Bit rate in kbps. Source adapters must normalize APIs that report bps.
    public var bitRate: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var genre: String?
    public var year: Int?
    public var lastModified: Date?
    public var dateAdded: Date
    public var coverArtFileName: String?
    /// Source-owned artist artwork reference captured from a server catalogue.
    /// Unlike `artistID`, which is replaced with Primuse's name-derived ID,
    /// this stays in the connector's native namespace so artist views can ask
    /// the originating source for its dedicated image.
    public var artistArtworkFileName: String?
    public var lyricsFileName: String?
    public var mvPath: String?
    public var replayGainTrackGain: Double?
    public var replayGainTrackPeak: Double?
    public var replayGainAlbumGain: Double?
    public var replayGainAlbumPeak: Double?
    /// Source-relative path of the CUE sheet that defines this virtual track.
    /// Nil for ordinary one-file-per-track songs.
    public var cueSheetPath: String?
    /// Track boundaries inside `filePath`, expressed on the decoded PCM
    /// timeline. INDEX 01 is used for the start; the next INDEX 01 in the same
    /// FILE block is used for the end.
    public var cueStartTime: TimeInterval?
    public var cueEndTime: TimeInterval?
    /// Provider-supplied content identifier — etag, md5, content_hash,
    /// `fs_id` + `local_mtime`, etc. Used by re-scan to detect remote
    /// replacement on cloud drives that don't report a usable
    /// modifiedDate (Baidu, Aliyun, Dropbox, OneDrive). When non-nil on
    /// both sides and different, the file is treated as replaced even
    /// when path and size are identical.
    public var revision: String?

    /// FTS5 拼音搜索用的预生成 latin transliteration. nil 表示标题没有
    /// 中文 / 全 ASCII (不需要拼音索引)。由 PinyinTransformer 在 scan /
    /// migration 时计算填入。
    public var titlePinyin: String?
    public var artistPinyin: String?
    public var albumPinyin: String?
    /// 整曲歌词的纯文本 dump (去时间戳), 给 FTS5 全文搜索用。nil 表示
    /// 这首歌没有歌词或还没 backfill 完。LibraryDatabase migration 留空,
    /// MetadataBackfillService 异步读 .lrc 文件填回。
    public var lyricsText: String?
    /// Set only after the user explicitly saves editable metadata. Background
    /// scans and metadata backfill may still refresh technical fields, but must
    /// preserve the user-controlled identity fields while this marker exists.
    public var userMetadataEditedAt: Date?

    public init(
        id: String,
        title: String,
        albumID: String? = nil,
        artistID: String? = nil,
        albumTitle: String? = nil,
        artistName: String? = nil,
        albumArtistName: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval = 0,
        fileFormat: AudioFormat,
        filePath: String,
        sourceID: String,
        fileSize: Int64 = 0,
        bitRate: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        genre: String? = nil,
        year: Int? = nil,
        lastModified: Date? = nil,
        dateAdded: Date = Date(),
        coverArtFileName: String? = nil,
        artistArtworkFileName: String? = nil,
        lyricsFileName: String? = nil,
        mvPath: String? = nil,
        replayGainTrackGain: Double? = nil,
        replayGainTrackPeak: Double? = nil,
        replayGainAlbumGain: Double? = nil,
        replayGainAlbumPeak: Double? = nil,
        cueSheetPath: String? = nil,
        cueStartTime: TimeInterval? = nil,
        cueEndTime: TimeInterval? = nil,
        revision: String? = nil,
        titlePinyin: String? = nil,
        artistPinyin: String? = nil,
        albumPinyin: String? = nil,
        lyricsText: String? = nil,
        userMetadataEditedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.albumID = albumID
        self.artistID = artistID
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.albumArtistName = albumArtistName
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.fileFormat = fileFormat
        self.filePath = filePath
        self.sourceID = sourceID
        self.fileSize = fileSize
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.genre = genre
        self.year = year
        self.lastModified = lastModified
        self.dateAdded = dateAdded
        self.coverArtFileName = coverArtFileName
        self.artistArtworkFileName = artistArtworkFileName
        self.lyricsFileName = lyricsFileName
        self.mvPath = mvPath
        self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak
        self.cueSheetPath = cueSheetPath
        self.cueStartTime = cueStartTime
        self.cueEndTime = cueEndTime
        self.revision = revision
        self.titlePinyin = titlePinyin
        self.artistPinyin = artistPinyin
        self.albumPinyin = albumPinyin
        self.lyricsText = lyricsText
        self.userMetadataEditedAt = userMetadataEditedAt
    }
}

/// Encodes a connector-relative artwork reference together with the source
/// that owns it. `Artist.thumbnailPath` has only one persisted string slot, so
/// the ownership must travel with the reference for adaptive source routing to
/// select the correct credentials and LAN/public endpoint at display time.
public enum SourceOwnedArtworkReference {
    public struct Resolved: Equatable, Sendable {
        public let sourceID: String
        public let reference: String

        public init(sourceID: String, reference: String) {
            self.sourceID = sourceID
            self.reference = reference
        }
    }

    private static let prefix = "primuse-source-artwork:"

    public static func make(sourceID: String, reference: String) -> String? {
        guard !sourceID.isEmpty, !reference.isEmpty,
              !sourceID.contains("\0"), !reference.contains("\0") else { return nil }
        let payload = Data((sourceID + "\0" + reference).utf8)
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + encoded
    }

    public static func resolve(_ value: String?) -> Resolved? {
        guard let value, value.hasPrefix(prefix) else { return nil }
        var encoded = String(value.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        if padding > 0 { encoded.append(String(repeating: "=", count: padding)) }
        guard let payload = Data(base64Encoded: encoded),
              let separator = payload.firstIndex(of: 0),
              let sourceID = String(data: payload[..<separator], encoding: .utf8),
              let reference = String(data: payload[payload.index(after: separator)...], encoding: .utf8),
              !sourceID.isEmpty, !reference.isEmpty else { return nil }
        return Resolved(sourceID: sourceID, reference: reference)
    }
}

public struct AlbumGroupingIdentity: Hashable, Sendable {
    public let albumTitle: String
    public let artistName: String

    public init(albumTitle: String, artistName: String) {
        self.albumTitle = albumTitle
        self.artistName = artistName
    }
}

public enum AlbumGroupingPolicy {
    /// Returns the album-level artist when supplied by the source, otherwise
    /// the track artist. Call this when a source has completed metadata
    /// inspection so legacy nil values can be distinguished from a known
    /// fallback.
    public static func resolvedAlbumArtistName(
        albumArtistName: String?,
        trackArtistName: String?
    ) -> String? {
        normalized(albumArtistName) ?? normalized(trackArtistName)
    }

    /// Keeps an explicit album artist stable while allowing the track-artist
    /// fallback to follow a deliberate artist change.
    public static func updatedAlbumArtistName(
        existingAlbumArtistName: String?,
        previousTrackArtistName: String?,
        updatedTrackArtistName: String?,
        incomingAlbumArtistName: String? = nil
    ) -> String? {
        if let incoming = normalized(incomingAlbumArtistName) {
            return incoming
        }

        let existing = normalized(existingAlbumArtistName)
        if existing == nil || equivalent(existing, normalized(previousTrackArtistName)) {
            return normalized(updatedTrackArtistName)
        }
        return existing
    }

    public static func identity(
        albumTitle: String?,
        albumArtistName: String?,
        trackArtistName: String?,
        unknownArtistName: String
    ) -> AlbumGroupingIdentity? {
        guard let albumTitle = normalized(albumTitle) else { return nil }
        let artistName = resolvedAlbumArtistName(
            albumArtistName: albumArtistName,
            trackArtistName: trackArtistName
        ) ?? unknownArtistName
        return AlbumGroupingIdentity(albumTitle: albumTitle, artistName: artistName)
    }

    /// Older persisted songs predate albumArtistName. Callers must provide an
    /// independent persisted completion marker: absence is a valid inspected
    /// result and must not force every later scan to reread the same file.
    public static func requiresMetadataRefresh(
        albumTitle: String?,
        albumArtistName: String?,
        metadataInspectionComplete: Bool
    ) -> Bool {
        !metadataInspectionComplete
            && normalized(albumTitle) != nil
            && normalized(albumArtistName) == nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func equivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

/// Repairs metadata text that a media server or tagger decoded with the wrong
/// character set. The encoding analysis lives in `TextEncodingRepair`; this
/// type adds the library-specific policy on top of it — which fields are worth
/// re-deriving from a filename once the original bytes are unrecoverable.
public enum MediaMetadataTextRepair {
    public struct FileNameIdentity: Sendable, Equatable {
        public let artist: String
        public let title: String

        public init(artist: String, title: String) {
            self.artist = artist
            self.title = title
        }
    }

    public static func repaired(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !containsUnrecoverableReplacement(in: trimmed) else { return nil }

        return legacyChineseCandidate(for: trimmed) ?? trimmed
    }

    public static func isSuspicious(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return containsUnrecoverableReplacement(in: trimmed)
            || legacyChineseCandidate(for: trimmed) != nil
    }

    public static func fileNameTitle(from path: String?) -> String? {
        guard let baseName = fileBaseName(from: path) else { return nil }
        if let numberedTitle = numberedTrackTitle(baseName) { return numberedTitle }
        return fileNameIdentity(fromBaseName: baseName)?.title ?? baseName
    }

    public static func fileNameArtist(from path: String?) -> String? {
        guard let baseName = fileBaseName(from: path) else { return nil }
        if numberedTrackTitle(baseName) != nil { return nil }
        guard let parsed = fileNameIdentity(fromBaseName: baseName) else { return nil }
        return parsed.artist.allSatisfy(\.isNumber) ? nil : parsed.artist
    }

    /// Parses common NAS base names without treating a bare underscore inside a
    /// legitimate artist or title as a separator. At least one side of an
    /// underscore must contain whitespace, so both `Artist _ Title` and the
    /// inconsistent `Artist _Title_ 20240101` form remain supported.
    public static func fileNameIdentity(fromBaseName value: String?) -> FileNameIdentity? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalizedSeparators = trimmed.replacingOccurrences(
            of: "\\s+_\\s*|\\s*_\\s+",
            with: " _ ",
            options: .regularExpression
        )
        let underscoreParts = normalizedSeparators
            .components(separatedBy: " _ ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if underscoreParts.count >= 2 {
            return FileNameIdentity(artist: underscoreParts[0], title: underscoreParts[1])
        }

        guard let range = trimmed.range(of: "\\s*[–—-]\\s+", options: .regularExpression) else {
            return nil
        }
        let artist = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return FileNameIdentity(artist: artist, title: title)
    }

    private static func fileBaseName(from path: String?) -> String? {
        guard let path else { return nil }
        let lastComponent = (path as NSString).lastPathComponent
        let baseName = (lastComponent as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? nil : baseName
    }

    private static func numberedTrackTitle(_ value: String) -> String? {
        if let dot = value.range(of: ". ") {
            let prefix = value[..<dot.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = value[dot.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, prefix.allSatisfy(\.isNumber), !title.isEmpty {
                return title
            }
        }
        if let parsed = fileNameIdentity(fromBaseName: value), parsed.artist.allSatisfy(\.isNumber) {
            return parsed.title
        }
        return nil
    }

    /// 在文件内嵌标签与文件名之间挑更可信的一个。
    ///
    /// 这是两条完全独立的来源: 标签是文件内部的裸字节, 没有可靠的编码声明,
    /// 解码全靠猜; 文件名来自目录列表 —— 网盘 API 给的是 UTF-8 JSON, 本地
    /// 是文件系统 —— 基本不会错。所以标签解坏时, 文件名往往还是好的。
    ///
    /// 两边都可疑时保留标签值: 至少让用户看见原文, 也还能用手动编码修正去救。
    public static func preferred(embedded: String?, fromFileName: String?) -> String? {
        let tag = embedded?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = fromFileName?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Repair only reversible mojibake. `repaired` returns nil for U+FFFD /
        // lossy question-mark input, so those values can never be invented
        // back into text and instead fall through to the independent filename.
        if let repairedTag = repaired(tag), !isSuspicious(repairedTag) {
            return repairedTag
        }
        if let repairedName = repaired(name), !isSuspicious(repairedName) {
            return repairedName
        }
        if let tag, !tag.isEmpty { return embedded }
        return fromFileName
    }

    private static func legacyChineseCandidate(for value: String) -> String? {
        TextEncodingRepair.repaired(value)
    }

    private static func containsUnrecoverableReplacement(in value: String) -> Bool {
        TextEncodingRepair.hasUnrecoverableReplacement(in: value)
    }
}

/// Keeps explicit user edits authoritative when a fresh source record or a
/// background metadata result is merged into the library.
public enum SongUserMetadataPolicy {
    public static func preservingUserEdits(from existing: Song, in incoming: Song) -> Song {
        guard existing.userMetadataEditedAt != nil else { return incoming }

        var result = incoming
        result.title = existing.title
        result.albumID = existing.albumID
        result.artistID = existing.artistID
        result.albumTitle = existing.albumTitle
        result.artistName = existing.artistName
        result.albumArtistName = existing.albumArtistName ?? incoming.albumArtistName
        result.trackNumber = existing.trackNumber
        result.discNumber = existing.discNumber
        result.genre = existing.genre
        result.year = existing.year
        result.coverArtFileName = existing.coverArtFileName
        result.titlePinyin = existing.titlePinyin
        result.artistPinyin = existing.artistPinyin
        result.albumPinyin = existing.albumPinyin
        result.userMetadataEditedAt = existing.userMetadataEditedAt
        return result
    }

    public static func editableFieldsChanged(from original: Song, to updated: Song) -> Bool {
        original.title != updated.title
            || original.artistName != updated.artistName
            || original.albumTitle != updated.albumTitle
            || original.trackNumber != updated.trackNumber
            || original.discNumber != updated.discNumber
            || original.genre != updated.genre
            || original.year != updated.year
            || original.coverArtFileName != updated.coverArtFileName
    }
}

extension Song: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "songs" }
}

public extension Song {
    /// The path stored in this row is a small runtime-resolved stream
    /// descriptor, not the media object itself.
    var isStreamDescriptor: Bool {
        PrimuseConstants.supportedStreamDescriptorExtensions.contains(
            (filePath as NSString).pathExtension.lowercased()
        )
    }

    var isCueTrack: Bool {
        cueSheetPath?.isEmpty == false && cueStartTime != nil
    }

    var cueSegmentDuration: TimeInterval? {
        guard let start = cueStartTime, let end = cueEndTime, end > start else { return nil }
        return end - start
    }

    /// True when the song can be handed to the player. A non-empty `filePath`
    /// means there is a location to stream/decode — the player resolves the
    /// real `duration` on play and rewrites it into the library, so cloud
    /// Phase-A songs whose `duration` hasn't been backfilled yet are still
    /// playable (previously they were stuck "unplayable" until backfill, which
    /// is slow/unreliable on large cloud libraries). The `duration > 0` clause
    /// keeps provider songs that have no file path (e.g. Apple Music) playable.
    /// To detect "metadata still pending" for the bare-row UI, test
    /// `duration <= 0` directly, not `!isPlayable`.
    var isPlayable: Bool { duration > 0 || !filePath.isEmpty }

    /// 独立 MV 曲目 —— 媒体本体就是视频文件, 扫描时把 `mvPath` 指向自身
    /// (`mvPath == filePath`)。这类歌曲不受全局 MV 模式开关影响, 始终走
    /// AVPlayer 视频管线; 普通歌曲的 MV 仍是"同名 sidecar"(mvPath 指向
    /// 另一个文件)。
    var isStandaloneMusicVideo: Bool {
        guard let mvPath, !mvPath.isEmpty else { return false }
        return mvPath == filePath
    }
}

public extension Sequence where Element == Song {
    /// Drop only songs with nothing to play (no file path and no duration).
    /// Cloud Phase-A songs without a backfilled duration are kept — the player
    /// resolves their duration on play — so the queue no longer skips them.
    func filteredPlayable() -> [Song] { filter(\.isPlayable) }
}
