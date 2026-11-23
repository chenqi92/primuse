import Foundation
import GRDB

/// 每行的派生列(不依赖整库分组的部分)。`kind` 与 `folderKey` 由分组维护按行算好后填进来,
/// 与歌曲行一起写;`effectiveAlbumRef` 只由分组维护写。
struct LibraryCatalogDerivedFields {
    var fileNameKey: String
    var fileNameOverride: String?
    var titleKey: Data
    var sectionBucket: Int
    var durationKey: Double
    var discKey: Int
    var trackKey: Int
    var kind: Int
    var flags: Int
    var matchKey: String
    /// 路径原文(列里存的文本)的 47 位哈希:精确路径查询走它的索引,查到后再比原文。
    var pathHash: Int64
    /// 去掉首尾空白的专辑标题的 47 位哈希;没有专辑标题时为 nil。专辑艺人推断与专辑都在同一个
    /// 标题之内,增量维护按它取范围。
    var titleHash: Int64?
    var inferenceDirectory: String?
    var folderKey: Int64?

    var values: [CatalogValue] {
        [.text(fileNameKey), .optionalText(fileNameOverride), .blob(titleKey), .int(Int64(sectionBucket)),
         .real(durationKey), .int(Int64(discKey)), .int(Int64(trackKey)), .int(Int64(kind)), .int(Int64(flags)),
         .text(matchKey), .int(pathHash), titleHash.map(CatalogValue.int) ?? .null,
         .optionalText(inferenceDirectory), folderKey.map(CatalogValue.int) ?? .null]
    }

    static let columnNames = [
        "fileNameKey", "fileNameOverride", "titleKey", "sectionBucket", "durationKey", "discKey", "trackKey",
        "kind", "flags", "matchKey", "pathHash", "titleHash", "inferenceDirectory", "folderKey",
    ]

    /// 音乐源层面的设置,决定文件名列与目录列怎么算。
    struct SourceTraits: Sendable, Equatable {
        var fileNamesFromIndex = false
        var usesFolderParents = false
    }

    /// 纯函数,可以多核并行算。`inferenceDirectory`、`kind`、`folderKey` 由调用方在写事务里补。
    static func make(
        for song: Song,
        source: SourceTraits,
        fileNameOverride: String?
    ) -> LibraryCatalogDerivedFields {
        let duration = song.appliedPlaybackRange?.songDuration ?? song.duration
        // 读音键的首字母下标就是字母索引(与 `indexLetter(for:)` 同一个函数,空名字归 "#")。
        let titleKey = LibraryCollationPolicy.songTitleKey(for: song.title)
        let artistKey = LibraryCollationPolicy.key(for: song.artistName ?? "")
        let albumKey = LibraryCollationPolicy.key(for: song.albumTitle ?? "")
        let titleBucket = titleKey.bucketIndex
        let artistBucket = artistKey.bucketIndex
        let albumBucket = albumKey.bucketIndex
        return LibraryCatalogDerivedFields(
            fileNameKey: columnText(fileNameOverride ?? fileName(for: song, fromIndex: source.fileNamesFromIndex)),
            fileNameOverride: fileNameOverride.map(columnText),
            titleKey: keyData(titleKey),
            sectionBucket: titleBucket | artistBucket << 5 | albumBucket << 10,
            durationKey: duration.isFinite ? max(0, duration) : 0,
            discKey: AlbumTrackOrder.discNumber(for: song),
            trackKey: AlbumTrackOrder.trackNumber(for: song) ?? Int.max,
            kind: LibraryCatalogContentKind.music.rawValue,
            flags: flags(for: song, duration: duration),
            matchKey: columnText(ExternalTrackMatchPolicy.normalizedCoreTitle(song.title)),
            pathHash: pathHash(song.filePath),
            titleHash: titleHash(albumTitle: song.albumTitle),
            inferenceDirectory: nil,
            folderKey: nil
        )
    }

    /// 列里存的文本:与 `LibraryCatalogSongCodec` 一样把 NUL 换成 U+FFFD(GRDB 按 C 字符串绑定)。
    static func columnText(_ value: String) -> String {
        value.utf8.contains(0) ? value.replacingOccurrences(of: "\0", with: "\u{FFFD}") : value
    }

    /// 稳定的 47 位哈希(FNV-1a 64 取高位):跨进程、跨版本不变,存进库里当索引键;
    /// 47 位以内的非负整数 SQLite 用 6 字节存。碰撞只多读几行,查询总会再比原文。
    static func stableHash(_ text: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash >> 17)
    }

    static func pathHash(_ filePath: String) -> Int64 {
        stableHash(columnText(filePath))
    }

    /// 专辑艺人推断与专辑身份所用的标题(`AlbumArtistInferencePolicy` 的去空白标题)。
    static func trimmedAlbumTitle(_ albumTitle: String?) -> String? {
        guard let title = albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    static func titleHash(albumTitle: String?) -> Int64? {
        trimmedAlbumTitle(albumTitle).map(stableHash)
    }

    /// `LibraryCollationPolicy.Key` 的二进制形式:首字节是索引字母下标,后面是 NFC 规范化
    /// 的读音文本。按字节比较的先后与 `Key.<` 一致(Swift 的字符串比较就是 NFC UTF-8 的字典序)。
    static func keyData(_ key: LibraryCollationPolicy.Key) -> Data {
        var bytes: [UInt8] = [UInt8(truncatingIfNeeded: key.bucketIndex)]
        let text = key.text.utf8.allSatisfy({ $0 < 0x80 }) ? key.text : key.text.precomposedStringWithCanonicalMapping
        bytes.append(contentsOf: text.utf8)
        return Data(bytes)
    }

    /// 与 `SongListSnapshotBuilder.fileNameKeys` 不读同步索引时的规则一致。
    static func fileName(for song: Song, fromIndex: Bool) -> String {
        if fromIndex || song.sourceID == AppleMusicLibraryIdentity.sourceID || song.filePath.isEmpty {
            return song.title
        }
        let path = song.filePath
        if path.hasPrefix("nfs::") {
            let decoded = SongPathPresentationPolicy.displayPath(filePath: path, sourceID: song.sourceID)
            return decoded.map { ($0 as NSString).lastPathComponent } ?? song.title
        }
        if path.contains("://"), let url = URL(string: path), url.scheme != nil {
            return url.lastPathComponent.isEmpty ? song.title : url.lastPathComponent
        }
        return (path as NSString).lastPathComponent
    }

    static func flags(for song: Song, duration: Double) -> Int {
        var flags = 0
        if duration > 0 || !song.filePath.isEmpty { flags |= LibraryCatalogSongFlags.playable }
        if song.hasMusicVideo { flags |= LibraryCatalogSongFlags.hasMusicVideo }
        if song.isStandaloneMusicVideo { flags |= LibraryCatalogSongFlags.standaloneMusicVideo }
        if song.isExternal == true { flags |= LibraryCatalogSongFlags.external }
        if song.isCueTrack { flags |= LibraryCatalogSongFlags.cueTrack }
        if song.userMetadataEditedAt != nil { flags |= LibraryCatalogSongFlags.userEdited }
        if song.lyricsText?.isEmpty == false { flags |= LibraryCatalogSongFlags.hasLyricsText }
        if song.coverArtFileName?.isEmpty == false { flags |= LibraryCatalogSongFlags.hasCover }
        if song.lyricsFileName?.isEmpty == false { flags |= LibraryCatalogSongFlags.hasLyricsFile }
        if song.serverCatalogAlbum != nil { flags |= LibraryCatalogSongFlags.serverCatalogAlbum }
        return flags
    }
}

public enum LibraryCatalogSongFlags {
    public static let playable = 1 << 0
    public static let hasMusicVideo = 1 << 1
    public static let standaloneMusicVideo = 1 << 2
    public static let external = 1 << 3
    public static let cueTrack = 1 << 4
    public static let userEdited = 1 << 5
    public static let hasLyricsText = 1 << 6
    public static let hasCover = 1 << 7
    public static let hasLyricsFile = 1 << 8
    public static let serverCatalogAlbum = 1 << 9
}

/// 歌曲的内容类别(派生列 `kind`)。
public enum LibraryCatalogContentKind: Int, Sendable, CaseIterable {
    case music = 0
    case spokenWord = 1
    case podcast = 2
    case ambient = 3
    /// 只因镜像歌单才在库里的条目:可播、可搜、在歌单里,但不进音乐列表与书架。
    case collectionOnly = 4
}
