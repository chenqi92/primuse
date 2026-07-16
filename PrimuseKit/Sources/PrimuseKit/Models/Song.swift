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
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval
    public var fileFormat: AudioFormat
    public var filePath: String // relative within source
    public var sourceID: String
    public var fileSize: Int64
    public var bitRate: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var genre: String?
    public var year: Int?
    public var lastModified: Date?
    public var dateAdded: Date
    public var coverArtFileName: String?
    public var lyricsFileName: String?
    public var mvPath: String?
    public var replayGainTrackGain: Double?
    public var replayGainTrackPeak: Double?
    public var replayGainAlbumGain: Double?
    public var replayGainAlbumPeak: Double?
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

    public init(
        id: String,
        title: String,
        albumID: String? = nil,
        artistID: String? = nil,
        albumTitle: String? = nil,
        artistName: String? = nil,
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
        lyricsFileName: String? = nil,
        mvPath: String? = nil,
        replayGainTrackGain: Double? = nil,
        replayGainTrackPeak: Double? = nil,
        replayGainAlbumGain: Double? = nil,
        replayGainAlbumPeak: Double? = nil,
        revision: String? = nil,
        titlePinyin: String? = nil,
        artistPinyin: String? = nil,
        albumPinyin: String? = nil,
        lyricsText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.albumID = albumID
        self.artistID = artistID
        self.albumTitle = albumTitle
        self.artistName = artistName
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
        self.lyricsFileName = lyricsFileName
        self.mvPath = mvPath
        self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak
        self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak
        self.revision = revision
        self.titlePinyin = titlePinyin
        self.artistPinyin = artistPinyin
        self.albumPinyin = albumPinyin
        self.lyricsText = lyricsText
    }
}

/// Repairs metadata text returned by media servers when legacy GBK/GB18030
/// bytes were decoded as ISO-8859-1. It also exposes filename fallbacks for
/// fields that already contain U+FFFD and therefore cannot be losslessly
/// recovered from the server response.
public enum MediaMetadataTextRepair {
    public static func repaired(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("\u{FFFD}") else { return nil }

        return legacyChineseCandidate(for: trimmed) ?? trimmed
    }

    public static func isSuspicious(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("\u{FFFD}") || legacyChineseCandidate(for: trimmed) != nil
    }

    public static func fileNameTitle(from path: String?) -> String? {
        guard let baseName = fileBaseName(from: path) else { return nil }
        return splitArtistAndTitle(baseName)?.title ?? baseName
    }

    public static func fileNameArtist(from path: String?) -> String? {
        guard let baseName = fileBaseName(from: path) else { return nil }
        return splitArtistAndTitle(baseName)?.artist
    }

    private static func fileBaseName(from path: String?) -> String? {
        guard let path else { return nil }
        let lastComponent = (path as NSString).lastPathComponent
        let baseName = (lastComponent as NSString)
            .deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? nil : baseName
    }

    private static func splitArtistAndTitle(_ value: String) -> (artist: String, title: String)? {
        guard let range = value.range(of: "\\s+[–—-]\\s+", options: .regularExpression) else {
            return nil
        }
        let artist = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return (artist, title)
    }

    private static func legacyChineseCandidate(for value: String) -> String? {
        guard value.unicodeScalars.allSatisfy({ $0.value <= 0xFF }),
              let latin1Data = value.data(using: .isoLatin1) else {
            return nil
        }

        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        guard let decoded = String(data: latin1Data, encoding: String.Encoding(rawValue: gb18030)),
              decoded != value,
              !decoded.contains("\u{FFFD}") else {
            return nil
        }

        let originalExtendedLatinCount = value.unicodeScalars.filter { (0xA1...0xFF).contains($0.value) }.count
        let decodedHanCount = decoded.unicodeScalars.filter { isHan($0.value) }.count

        // Requiring several extended-Latin bytes and at least two resulting
        // Han characters avoids rewriting normal Western names such as
        // "Beyoncé" while still covering short mojibake titles like "¹ý»ð".
        guard originalExtendedLatinCount >= 3, decodedHanCount >= 2 else {
            return nil
        }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHan(_ scalar: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(scalar)
            || (0x4E00...0x9FFF).contains(scalar)
            || (0xF900...0xFAFF).contains(scalar)
    }
}

extension Song: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "songs" }
}

public extension Song {
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
