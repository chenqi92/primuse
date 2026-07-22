import Foundation
import PrimuseKit

struct RemoteFileItem: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
    /// Sidecar files (cover.jpg, lyrics.lrc) discovered alongside this audio
    /// item during scan. Cloud connectors populate this from the parent
    /// directory listing so we don't need a fully-downloaded localURL to
    /// detect siblings.
    let sidecarHints: SidecarHints?
    /// Provider content fingerprint — md5 / etag / content_hash / fs_id+
    /// local_mtime. Powers re-scan replacement detection when both size
    /// and mtime are unreliable (Baidu/Aliyun/Dropbox/OneDrive listFiles
    /// often return nil for `modifiedDate`, and a same-size overwrite
    /// would otherwise be missed). Connectors leave this nil when the
    /// list API doesn't expose anything stable.
    let revision: String?

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedDate: Date?,
        sidecarHints: SidecarHints? = nil,
        revision: String? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.sidecarHints = sidecarHints
        self.revision = revision
    }
}

struct SidecarHints: Sendable {
    let coverPath: String?
    let lyricsPath: String?
    let mvPath: String?

    init(coverPath: String? = nil, lyricsPath: String? = nil, mvPath: String? = nil) {
        self.coverPath = coverPath
        self.lyricsPath = lyricsPath
        self.mvPath = mvPath
    }

    var isEmpty: Bool {
        coverPath == nil && lyricsPath == nil && mvPath == nil
    }
}

struct ConnectorScannedSong: Sendable {
    let song: Song
    let displayName: String
}

enum SidecarHintResolver {
    /// 统一的扫描项判定: 音频文件返回带 sidecar hints 的 item; 无同名音频的
    /// 视频文件(mp4/m4v/mov)返回 mvPath 指向自身的 item —— 上层把它当曲目
    /// yield, 建出的 Song 即独立 MV(isStandaloneMusicVideo)。其余返回 nil。
    static func scannableItem(_ item: RemoteFileItem, siblings: [RemoteFileItem]) -> RemoteFileItem? {
        guard item.isDirectory == false else { return nil }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if PrimuseConstants.supportedAudioExtensions.contains(ext) {
            return decoratedAudioItem(item, siblings: siblings)
        }
        if PrimuseConstants.supportedMusicVideoExtensions.contains(ext) {
            return standaloneVideoItem(item, siblings: siblings)
        }
        return nil
    }

    /// 无同名音频的视频文件独立成曲; 有同名音频时它是那首歌的 sidecar,
    /// 返回 nil 以免同一文件既挂 mvPath 又重复成曲。
    static func standaloneVideoItem(_ item: RemoteFileItem, siblings: [RemoteFileItem]) -> RemoteFileItem? {
        let basename = (item.name as NSString).deletingPathExtension
        let baseLower = basename.lowercased()
        let hasSameNameAudio = siblings.contains {
            guard $0.isDirectory == false else { return false }
            let siblingExt = ($0.name as NSString).pathExtension.lowercased()
            return PrimuseConstants.supportedAudioExtensions.contains(siblingExt)
                && ($0.name as NSString).deletingPathExtension.lowercased() == baseLower
        }
        guard hasSameNameAudio == false else { return nil }

        let nonAudio = siblings.filter {
            guard $0.isDirectory == false else { return false }
            let siblingExt = ($0.name as NSString).pathExtension.lowercased()
            return PrimuseConstants.supportedAudioExtensions.contains(siblingExt) == false
        }
        let hints = SidecarHints(
            coverPath: item.sidecarHints?.coverPath
                ?? findSameNameCover(basename: basename, in: nonAudio)
                ?? findFolderCover(in: nonAudio),
            lyricsPath: item.sidecarHints?.lyricsPath
                ?? findSameNameLyrics(basename: basename, in: nonAudio),
            mvPath: item.path
        )
        return RemoteFileItem(
            name: item.name,
            path: item.path,
            isDirectory: false,
            size: item.size,
            modifiedDate: item.modifiedDate,
            sidecarHints: hints,
            revision: item.revision
        )
    }

    static func decoratedAudioItem(_ item: RemoteFileItem, siblings: [RemoteFileItem]) -> RemoteFileItem {
        guard item.isDirectory == false else { return item }

        let basename = (item.name as NSString).deletingPathExtension
        let nonAudio = siblings.filter {
            guard $0.isDirectory == false else { return false }
            let ext = ($0.name as NSString).pathExtension.lowercased()
            return PrimuseConstants.supportedAudioExtensions.contains(ext) == false
        }

        let hints = SidecarHints(
            coverPath: item.sidecarHints?.coverPath
                ?? findSameNameCover(basename: basename, in: nonAudio)
                ?? findFolderCover(in: nonAudio),
            lyricsPath: item.sidecarHints?.lyricsPath
                ?? findSameNameLyrics(basename: basename, in: nonAudio),
            mvPath: item.sidecarHints?.mvPath
                ?? findSameNameMusicVideo(basename: basename, in: nonAudio)
        )
        guard hints.isEmpty == false else { return item }

        return RemoteFileItem(
            name: item.name,
            path: item.path,
            isDirectory: item.isDirectory,
            size: item.size,
            modifiedDate: item.modifiedDate,
            sidecarHints: hints,
            revision: item.revision
        )
    }

    private static func findSameNameCover(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedCoverExtensions {
            if let match = candidates.first(where: {
                let name = ($0.name as NSString).lowercased
                return name == "\(baseLower).\(ext)" || name == "\(baseLower)-cover.\(ext)"
            }) {
                return match.path
            }
        }
        return nil
    }

    private static func findFolderCover(in candidates: [RemoteFileItem]) -> String? {
        for name in PrimuseConstants.folderCoverNames {
            for ext in PrimuseConstants.supportedCoverExtensions {
                if let match = candidates.first(where: {
                    ($0.name as NSString).lowercased == "\(name).\(ext)"
                }) {
                    return match.path
                }
            }
        }
        return nil
    }

    private static func findSameNameLyrics(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedLyricsExtensions {
            if let match = candidates.first(where: {
                ($0.name as NSString).lowercased == "\(baseLower).\(ext)"
            }) {
                return match.path
            }
        }
        return nil
    }

    private static func findSameNameMusicVideo(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedMusicVideoExtensions {
            if let match = candidates.first(where: {
                ($0.name as NSString).lowercased == "\(baseLower).\(ext)"
            }) {
                return match.path
            }
        }
        return nil
    }
}

protocol MusicSourceConnector: Sendable {
    var sourceID: String { get }
    var supportsSidecarWriting: Bool { get }
    func connect() async throws
    func disconnect() async
    func listFiles(at path: String) async throws -> [RemoteFileItem]
    func localURL(for path: String) async throws -> URL
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error>
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error>

    /// Returns a remote HTTP(S) URL that can be streamed directly by AVFoundation.
    /// Sources that support streaming (e.g. Synology) return the URL; others return nil.
    func streamingURL(for path: String) async throws -> URL?

    /// Returns a direct HTTP(S) URL for an image file (cover art sidecar).
    /// Used by CachedArtworkView to load covers without downloading to local cache.
    func imageURL(for path: String) async throws -> URL?

    /// Write data to a remote path. Used by sidecar file writing (cover art, lyrics).
    func writeFile(data: Data, to path: String) async throws

    /// Delete a remote file. Used by song deletion to remove the source audio
    /// file and safe same-name sidecars.
    func deleteFile(at path: String) async throws

    /// Count audio files in a directory (recursive). Default implementation uses scanAudioFiles.
    func countAudioFiles(in path: String) async throws -> Int

    /// Fetch a byte range of a remote file. Used by `MetadataBackfillService`
    /// to read just the ID3/Vorbis/moov header (typically the first 256KB)
    /// instead of downloading the whole audio file.
    /// - Parameters:
    ///   - path: Remote path identifier (same as `localURL` accepts).
    ///   - offset: Starting byte offset. Negative values mean "from the end"
    ///     (e.g. `-262144` is the last 256KB) where the connector supports it.
    ///   - length: Number of bytes to fetch.
    /// Default implementation falls back to a full download via `localURL`,
    /// which is correct but slow — cloud connectors should override.
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data

    /// 批量预热下载链接 / 元数据。给定一组 path, connector 提前 batch 拿
    /// (并 cache) 后续 fetchRange 需要的 dlink / CDN URL / 鉴权信息。
    ///
    /// 出现意义: 百度网盘 filemetas API 单次 fsids 数组最多 100 个, batch
    /// 后单次调用能换 100 首歌的 dlink, 1w 首库下省 99% API 配额。其他
    /// connector 不需要这个 (NAS 直连 / WebDAV 都没单 path 一次的限速)。
    ///
    /// 默认实现 noop, 不强制 connector 实现。失败不抛错 ── 仅是优化, 失败
    /// 时 backfill 仍能走 single-path 慢路径。
    func prefetchMetadata(paths: [String]) async
}

extension MusicSourceConnector {
    var supportsSidecarWriting: Bool { false }

    /// 默认 noop ── 大多数 connector 不需要预热, 单次 fetchRange 自带的
    /// metadata resolve 已经够。只有受限速 / batch API 收益高的源 (百度网盘)
    /// 才 override。
    func prefetchMetadata(paths: [String]) async {}

    func streamingURL(for path: String) async throws -> URL? { nil }
    func imageURL(for path: String) async throws -> URL? {
        // Default: use streamingURL as fallback (works for any file)
        try await streamingURL(for: path)
    }

    func countAudioFiles(in path: String) async throws -> Int {
        var count = 0
        let stream = try await scanAudioFiles(from: path)
        for try await _ in stream { count += 1 }
        return count
    }

    func writeFile(data: Data, to path: String) async throws {
        throw SourceError.connectionFailed("This source does not support file writing")
    }

    func deleteFile(at path: String) async throws {
        throw SourceError.connectionFailed("This source does not support file deletion")
    }

    /// Default fallback: download the whole file via `localURL` then slice.
    /// Correct but slow. Cloud connectors override this with HTTP Range.
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0 else { return Data() }
        let url = try await localURL(for: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let actualOffset: UInt64
        if offset < 0 {
            actualOffset = UInt64(max(0, fileSize + offset))
        } else {
            guard SafeByteRange.exclusiveEnd(offset: offset, length: length) != nil else {
                return Data()
            }
            actualOffset = UInt64(offset)
        }
        try handle.seek(toOffset: actualOffset)
        return handle.readData(ofLength: Int(length))
    }
}

protocol SongScanningConnector: MusicSourceConnector {
    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error>
}

/// A song-scanning connector whose API supplies useful metadata on every
/// scan. Existing user-enriched rows are preserved, but missing or visibly
/// corrupted server fields may be refreshed without requiring file changes.
protocol RefreshingMetadataSongConnector: SongScanningConnector {}

struct MediaServerWritebackResult: Sendable {
    var metadataWritten = false
    var coverWritten = false
    var lyricsWritten = false
    var unsupported: [String] = []
    var errors: [String] = []

    var succeeded: Bool {
        errors.isEmpty
    }
}

/// Native metadata writeback for media-server libraries. This is separate
/// from sidecar file writing because Jellyfin/Emby/Plex expose item APIs and
/// opaque IDs rather than writable source-directory paths.
protocol MediaServerWritebackConnector: MusicSourceConnector {
    func writeScrapedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?
    ) async -> MediaServerWritebackResult
}

/// 服务端曲库源(Subsonic / Navidrome 等)向服务器回报播放的能力。
/// Navidrome 不把单纯的 stream 视为一次播放, 必须显式 scrobble 才会更新
/// 播放次数 / "最近播放" / 转发到服务端配置的 Last.fm·ListenBrainz。
/// - submission == false → "正在播放" (now playing, 不计入历史)
/// - submission == true  → "已播放" (计入播放次数 / 历史)
/// 失败不抛错 —— 回报是尽力而为, 失败不该影响播放。
protocol ServerScrobblingConnector: MusicSourceConnector {
    func scrobble(songPath: String, submission: Bool) async
}

/// 服务端直接提供歌词的能力 (Subsonic getLyricsBySongId / getLyrics)。
/// 返回 LRC 文本(带 `[mm:ss.xx]` 时间轴)或纯文本(无时间轴), 交由
/// `LyricsParser` 统一解析; 没有歌词时返回 nil。服务端歌词不是"同目录
/// .lrc"模型, 所以走这条能力而非 LyricsLoader 的 sidecar 路径。
protocol ServerLyricsConnector: MusicSourceConnector {
    func fetchServerLyrics(for path: String) async -> String?
}

/// Implemented by connectors whose `Song.filePath` is an opaque provider
/// identifier rather than a human-readable path. Scraping can ask for the
/// real upstream filename when old rows have already persisted the opaque id
/// as `Song.title`.
protocol RemoteFileDisplayNameProviding: MusicSourceConnector {
    func displayName(for path: String) async throws -> String?
}

/// Implemented by cloud connectors whose identity is rooted in an OAuth
/// account (Baidu / Aliyun / Dropbox / OneDrive / Google Drive). Lets the
/// upper layer ask "which user does this token belong to" so multiple
/// MusicMount instances pointing at the same upstream account can be
/// coalesced under a single CloudAccount entity.
///
/// Local / NAS connectors (Synology, SMB, WebDAV, FTP, SFTP, NFS, S3,
/// MediaServer, UPnP) do NOT adopt this protocol — their identity is
/// already tied to host/credentials, no extra dedup hop needed.
protocol OAuthCloudSource: MusicSourceConnector {
    /// Stable account identifier issued by the OAuth provider. MUST be
    /// the same value across token refresh and across devices logged
    /// into the same account. Each connector documents which provider
    /// field it returns:
    /// - Baidu Pan: `uk` (from xpan/nas?method=uinfo)
    /// - Aliyun Drive: `id` (from oauth/users/info, OIDC sub)
    /// - Dropbox: `account_id` (from users/get_current_account)
    /// - OneDrive: `id` (from Microsoft Graph /me)
    /// - Google Drive: `sub` (from oauth2/v3/userinfo)
    func accountIdentifier() async throws -> String
}
