import Foundation
import GRDB

/// 每行的派生列(不依赖整库分组的部分)。
struct LibraryCatalogDerivedFields {
    var directoryKey: String
    var fileNameKey: String
    var fileNameOverride: String?
    var titleKey: Data
    /// 排序用的非空文本:比较器把 nil 当 ""(`artistName ?? ""`)。单独存成非空列,
    /// 覆盖索引才能直接读出来做降序时的组界判断。
    var artistSortKey: String
    var albumSortKey: String
    var albumIDSortKey: String
    var artistKey: Data
    var albumKey: Data
    var sectionBucket: Int
    var durationKey: Double
    var discKey: Int
    var trackKey: Int
    var kind: Int
    var flags: Int
    var matchKey: String
    var albumTitleKey: String?
    var inferenceDirectory: String?
    var effectiveAlbumID: String?
    var effectiveAlbumArtist: String?

    var databaseValues: [DatabaseValueConvertible?] {
        [directoryKey, fileNameKey, fileNameOverride, titleKey, artistSortKey, albumSortKey, albumIDSortKey,
         artistKey, albumKey, sectionBucket,
         durationKey, discKey, trackKey, kind, flags, matchKey, albumTitleKey, inferenceDirectory,
         effectiveAlbumID, effectiveAlbumArtist]
    }

    static let columnNames = [
        "directoryKey", "fileNameKey", "fileNameOverride", "titleKey", "artistSortKey", "albumSortKey",
        "albumIDSortKey", "artistKey", "albumKey",
        "sectionBucket", "durationKey", "discKey", "trackKey", "kind", "flags", "matchKey",
        "albumTitleKey", "inferenceDirectory", "effectiveAlbumID", "effectiveAlbumArtist",
    ]

    /// 音乐源层面的设置,决定文件名列与目录列怎么算。
    struct SourceTraits {
        var fileNamesFromIndex = false
        var usesFolderParents = false
    }

    static func make(
        for song: Song,
        source: SourceTraits,
        fileNameOverride: String?,
        folderParent: String?
    ) -> LibraryCatalogDerivedFields {
        let directory = AlbumArtistInferencePolicy.directory(ofPath: song.filePath)
        let duration = song.appliedPlaybackRange?.songDuration ?? song.duration
        // 读音键的首字母下标就是字母索引(与 `indexLetter(for:)` 同一个函数,空名字归 "#")。
        let titleKey = LibraryCollationPolicy.songTitleKey(for: song.title)
        let artistKey = LibraryCollationPolicy.key(for: song.artistName ?? "")
        let albumKey = LibraryCollationPolicy.key(for: song.albumTitle ?? "")
        let titleBucket = titleKey.bucketIndex
        let artistBucket = artistKey.bucketIndex
        let albumBucket = albumKey.bucketIndex
        let albumTitle = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryCatalogDerivedFields(
            directoryKey: directory,
            fileNameKey: fileNameOverride ?? fileName(for: song, fromIndex: source.fileNamesFromIndex),
            fileNameOverride: fileNameOverride,
            titleKey: keyData(titleKey),
            artistSortKey: columnText(song.artistName ?? ""),
            albumSortKey: columnText(song.albumTitle ?? ""),
            albumIDSortKey: columnText(song.albumID ?? ""),
            artistKey: keyData(artistKey),
            albumKey: keyData(albumKey),
            sectionBucket: titleBucket | artistBucket << 5 | albumBucket << 10,
            durationKey: duration.isFinite ? max(0, duration) : 0,
            discKey: AlbumTrackOrder.discNumber(for: song),
            trackKey: AlbumTrackOrder.trackNumber(for: song) ?? Int.max,
            kind: LibraryCatalogContentKind.music.rawValue,
            flags: flags(for: song, duration: duration),
            matchKey: ExternalTrackMatchPolicy.normalizedCoreTitle(song.title),
            albumTitleKey: albumTitle?.isEmpty == false ? albumTitle : nil,
            inferenceDirectory: source.usesFolderParents ? folderParent : directory,
            effectiveAlbumID: song.albumID,
            effectiveAlbumArtist: nil
        )
    }

    /// 列里存的文本:与 `LibraryCatalogSongCodec` 一样把 NUL 换成 U+FFFD(GRDB 按 C 字符串绑定)。
    static func columnText(_ value: String) -> String {
        value.utf8.contains(0) ? value.replacingOccurrences(of: "\0", with: "\u{FFFD}") : value
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
        if !song.id.utf8.allSatisfy({ $0 < 0x80 }), song.id != song.id.precomposedStringWithCanonicalMapping {
            flags |= LibraryCatalogSongFlags.nonNFCIdentifier
        }
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
    /// id 不是 NFC:按字节比较与 Swift 的 `<` 不一致,排序的 id 兜底要改用 Swift 比较。
    public static let nonNFCIdentifier = 1 << 10
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
