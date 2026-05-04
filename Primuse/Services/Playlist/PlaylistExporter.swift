import Foundation
import PrimuseKit

/// 把歌单序列化成可分享的文件 — 两种格式:
///
/// - **m3u8** (`.m3u8`): 通用文本格式, 几乎所有播放器都认。文件路径用
///   `source_name/relative_path` 拼成 (类似 NAS 路径), 让另一端用 basename
///   也能模糊匹配, 跨机/跨平台 OK。
/// - **JSON** (`.json`): Primuse 自己的格式, 带 song.id 完整匹配 + 元数据
///   (artist / album / duration / format), 同 Primuse 用户互发能完美还原。
@MainActor
enum PlaylistExporter {
    enum Format {
        case m3u8
        case json

        var fileExtension: String {
            switch self {
            case .m3u8: return "m3u8"
            case .json: return "json"
            }
        }

        var mimeType: String {
            switch self {
            case .m3u8: return "audio/x-mpegurl"
            case .json: return "application/json"
            }
        }
    }

    /// 把 `playlist` 导出到 tmp 目录, 返回文件 URL。调用方拿这个 URL
    /// 喂 ShareSheet。
    static func export(
        playlist: Playlist,
        songs: [Song],
        format: Format,
        sourcesStore: SourcesStore
    ) throws -> URL {
        let safeName = sanitizeFileName(playlist.name)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).\(format.fileExtension)")
        try? FileManager.default.removeItem(at: url)

        let data: Data
        switch format {
        case .m3u8:
            data = makeM3U8(playlist: playlist, songs: songs, sourcesStore: sourcesStore)
        case .json:
            data = try makeJSON(playlist: playlist, songs: songs)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - m3u8

    private static func makeM3U8(playlist: Playlist, songs: [Song], sourcesStore: SourcesStore) -> Data {
        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("#PLAYLIST:\(playlist.name)")
        for song in songs {
            // EXTINF: 时长 (秒, 整数), 艺术家 - 歌曲名
            let duration = max(0, Int(song.duration.rounded()))
            let displayArtist = song.artistName ?? ""
            let title = displayArtist.isEmpty ? song.title : "\(displayArtist) - \(song.title)"
            lines.append("#EXTINF:\(duration),\(title)")
            // 把源名拼到路径前面, 让对端肉眼能区分 (匹配仍走 basename)
            let sourceName = sourcesStore.allSources.first(where: { $0.id == song.sourceID })?.name ?? "?"
            let relPath = song.filePath.hasPrefix("/") ? song.filePath : "/" + song.filePath
            lines.append("\(sourceName)\(relPath)")
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: - JSON

    /// JSON 格式 — Primuse-native, 带完整元数据。导入方按 song.id 优先匹配,
    /// 找不到 fallback 到 title+artist。
    struct PrimusePlaylistFile: Codable {
        let format: String  // "primuse-playlist"
        let version: Int
        let exportedAt: Date
        let playlist: PlaylistEntry
        let tracks: [TrackEntry]

        struct PlaylistEntry: Codable {
            let name: String
            let createdAt: Date
            let updatedAt: Date
        }

        struct TrackEntry: Codable {
            let songID: String           // 同 Primuse 实例完美匹配
            let title: String
            let artistName: String?
            let albumTitle: String?
            let durationSec: Int?
            let trackNumber: Int?
            let discNumber: Int?
            let fileFormat: String?      // 信息性, 不参与匹配
            let filePath: String         // basename 兜底匹配
            let sourceName: String?      // 信息性
        }
    }

    private static func makeJSON(playlist: Playlist, songs: [Song]) throws -> Data {
        let tracks = songs.map { song in
            PrimusePlaylistFile.TrackEntry(
                songID: song.id,
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle,
                durationSec: song.duration > 0 ? Int(song.duration) : nil,
                trackNumber: song.trackNumber,
                discNumber: song.discNumber,
                fileFormat: song.fileFormat.displayName,
                filePath: song.filePath,
                sourceName: nil
            )
        }
        let file = PrimusePlaylistFile(
            format: "primuse-playlist",
            version: 1,
            exportedAt: Date(),
            playlist: PrimusePlaylistFile.PlaylistEntry(
                name: playlist.name,
                createdAt: playlist.createdAt,
                updatedAt: playlist.updatedAt
            ),
            tracks: tracks
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    // MARK: - Helpers

    /// 把歌单名压成合法文件名 — 去掉文件系统不喜欢的字符 + 截断到 80 字符。
    private static func sanitizeFileName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?*\"<>|\0")
        let cleaned = raw.unicodeScalars.map { illegal.contains($0) ? "_" : Character($0) }
        let str = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = str.isEmpty ? "playlist" : str
        return String(trimmed.prefix(80))
    }
}
