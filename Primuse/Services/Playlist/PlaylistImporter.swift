import Foundation
import PrimuseKit

/// 解析 m3u8 / Primuse-JSON 文件, 跟当前 library 匹配, 给 UI 一个
/// preview 让用户确认再创建歌单。
///
/// 匹配优先级 (高到低):
/// 1. JSON 里 song.id 完全匹配 (同一个 Primuse 实例间)
/// 2. 文件路径 basename 完全匹配 (跨机/跨平台 NAS 路径不一致也能命中)
/// 3. (title, artist) 模糊匹配 (去 diacritic / 大小写 / trim)
/// 4. 多个匹配命中: 用 DuplicateDetector 质量评分挑最高音质
@MainActor
enum PlaylistImporter {
    /// 单条 import 解析结果。`matchedSong` 为 nil 表示库里没找到。
    struct ImportEntry: Identifiable {
        let id = UUID()
        /// 原始文件里描述的曲目 (展示用)
        let displayTitle: String
        let displayArtist: String?
        /// 库里命中的歌曲, nil = 未匹配
        let matchedSong: Song?
        /// 命中的方式 — 让用户大概知道怎么对上的
        let matchKind: MatchKind?

        enum MatchKind: String {
            case songID    // Primuse-JSON 完整匹配
            case basename  // m3u8 文件名匹配
            case fuzzy     // 标题+艺术家模糊
        }
    }

    struct ImportPreview {
        let suggestedName: String
        let entries: [ImportEntry]

        var matchedCount: Int { entries.filter { $0.matchedSong != nil }.count }
        var missingCount: Int { entries.filter { $0.matchedSong == nil }.count }
    }

    enum ImportError: LocalizedError {
        case unsupportedFormat
        case malformed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return String(localized: "playlist_import_err_format")
            case .malformed(let why): return String(format: String(localized: "playlist_import_err_malformed_format"), why)
            case .empty: return String(localized: "playlist_import_err_empty")
            }
        }
    }

    /// 入口 —— 自动按扩展名分流。
    static func parseAndMatch(fileURL: URL, library: MusicLibrary) throws -> ImportPreview {
        let ext = fileURL.pathExtension.lowercased()
        // SecurityScopedResource: Files document picker 给的 URL 受沙箱保护,
        // 必须 startAccessing 才能读, 否则 Data(contentsOf:) 报权限错。
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ImportError.malformed(error.localizedDescription)
        }

        switch ext {
        case "m3u", "m3u8":
            return try parseM3U8(data: data, fileName: fileURL.deletingPathExtension().lastPathComponent, library: library)
        case "json":
            return try parseJSON(data: data, fileName: fileURL.deletingPathExtension().lastPathComponent, library: library)
        default:
            throw ImportError.unsupportedFormat
        }
    }

    // MARK: - JSON parser

    private static func parseJSON(data: Data, fileName: String, library: MusicLibrary) throws -> ImportPreview {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: PlaylistExporter.PrimusePlaylistFile
        do {
            file = try decoder.decode(PlaylistExporter.PrimusePlaylistFile.self, from: data)
        } catch {
            throw ImportError.malformed(error.localizedDescription)
        }
        guard !file.tracks.isEmpty else { throw ImportError.empty }

        // 匹配池用 visibleSongs(排除停用源), 与手动匹配 / 歌单展示口径一致:
        // 命中停用源的歌只会出现在全量 library.songs 里, 写进歌单后通过
        // songs(forPlaylist:) 也看不到, 会造成"导入成功却凭空少歌"。
        let visibleSongs = library.visibleSongs
        let index = SongMatchIndex(songs: visibleSongs)
        let entries = file.tracks.map { track -> ImportEntry in
            // 1. song.id 完全匹配
            if let s = index.byID[track.songID] {
                return ImportEntry(
                    displayTitle: track.title,
                    displayArtist: track.artistName,
                    matchedSong: s,
                    matchKind: .songID
                )
            }
            // 2. basename 匹配
            if let s = index.matchByBasename(track.filePath) {
                return ImportEntry(
                    displayTitle: track.title,
                    displayArtist: track.artistName,
                    matchedSong: s,
                    matchKind: .basename
                )
            }
            // 3. 模糊匹配 title+artist
            if let s = index.matchByTitleArtist(title: track.title, artist: track.artistName) {
                return ImportEntry(
                    displayTitle: track.title,
                    displayArtist: track.artistName,
                    matchedSong: s,
                    matchKind: .fuzzy
                )
            }
            return ImportEntry(
                displayTitle: track.title,
                displayArtist: track.artistName,
                matchedSong: nil,
                matchKind: nil
            )
        }
        return ImportPreview(suggestedName: file.playlist.name, entries: entries)
    }

    // MARK: - m3u8 parser

    /// EXTM3U 解析 — 标准格式:
    /// ```
    /// #EXTM3U
    /// #PLAYLIST:歌单名         (可选)
    /// #EXTINF:时长,艺术家 - 歌名  (可选, 跟在文件路径前)
    /// 文件路径
    /// ```
    /// `#EXTINF` 不存在时 fallback 到从路径推断 displayTitle。
    private static func parseM3U8(data: Data, fileName: String, library: MusicLibrary) throws -> ImportPreview {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.malformed("encoding")
        }
        var playlistName = fileName
        var pendingExtInf: String?
        var rawEntries: [(path: String, extInf: String?)] = []

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTM3U") { continue }
            if line.hasPrefix("#PLAYLIST:") {
                playlistName = String(line.dropFirst("#PLAYLIST:".count)).trimmingCharacters(in: .whitespaces)
                if playlistName.isEmpty { playlistName = fileName }
                continue
            }
            if line.hasPrefix("#EXTINF:") {
                pendingExtInf = String(line.dropFirst("#EXTINF:".count))
                continue
            }
            if line.hasPrefix("#") { continue }  // 其他注释跳过
            rawEntries.append((path: line, extInf: pendingExtInf))
            pendingExtInf = nil
        }
        guard !rawEntries.isEmpty else { throw ImportError.empty }

        // 匹配池用 visibleSongs(排除停用源), 与手动匹配 / 歌单展示口径一致。
        let visibleSongs = library.visibleSongs
        let index = SongMatchIndex(songs: visibleSongs)
        let entries = rawEntries.map { raw -> ImportEntry in
            let (displayTitle, displayArtist) = parseExtInf(raw.extInf, fallbackPath: raw.path)
            // 1. basename 匹配
            if let s = index.matchByBasename(raw.path) {
                return ImportEntry(
                    displayTitle: displayTitle,
                    displayArtist: displayArtist,
                    matchedSong: s,
                    matchKind: .basename
                )
            }
            // 2. 模糊匹配
            if let s = index.matchByTitleArtist(title: displayTitle, artist: displayArtist) {
                return ImportEntry(
                    displayTitle: displayTitle,
                    displayArtist: displayArtist,
                    matchedSong: s,
                    matchKind: .fuzzy
                )
            }
            return ImportEntry(
                displayTitle: displayTitle,
                displayArtist: displayArtist,
                matchedSong: nil,
                matchKind: nil
            )
        }
        return ImportPreview(suggestedName: playlistName, entries: entries)
    }

    /// 解析 `#EXTINF:duration,Artist - Title` 格式。Artist 段可能没有 (用户
    /// 自己手写的 m3u8 常见), 这种情况整段当 title。
    private static func parseExtInf(_ extInf: String?, fallbackPath: String) -> (title: String, artist: String?) {
        guard let extInf else {
            // 没 EXTINF, 用路径 basename 当标题
            let decodedPath = fallbackPath.removingPercentEncoding ?? fallbackPath
            let base = if let url = URL(string: fallbackPath), url.isFileURL {
                url.lastPathComponent
            } else {
                (decodedPath as NSString).lastPathComponent
            }
            let withoutExt = (base as NSString).deletingPathExtension
            return (withoutExt, nil)
        }
        // duration,rest 拆分
        guard let commaIdx = extInf.firstIndex(of: ",") else {
            return (extInf.trimmingCharacters(in: .whitespaces), nil)
        }
        let rest = String(extInf[extInf.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
        // " - " 分隔 artist - title (m3u8 约定)
        if let dashRange = rest.range(of: " - ") {
            let artist = String(rest[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(rest[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (title, artist.isEmpty ? nil : artist)
        }
        return (rest, nil)
    }

    // MARK: - Match strategies

    /// Pre-index once so importing M tracks into an N-song library is O(N+M)
    /// instead of repeatedly filtering and normalizing the whole library.
    private struct SongMatchIndex {
        let byID: [String: Song]
        private let byBasename: [String: [Song]]
        private let byNormalizedTitle: [String: [Song]]

        init(songs: [Song]) {
            var ids: [String: Song] = [:]
            var basenames: [String: [Song]] = [:]
            var titles: [String: [Song]] = [:]
            ids.reserveCapacity(songs.count)
            basenames.reserveCapacity(songs.count)
            titles.reserveCapacity(songs.count)
            for song in songs {
                if ids[song.id] == nil { ids[song.id] = song }
                let basename = (song.filePath as NSString).lastPathComponent.lowercased()
                basenames[basename, default: []].append(song)
                let title = PlaylistImporter.normalize(song.title)
                if !title.isEmpty {
                    titles[title, default: []].append(song)
                }
            }
            byID = ids
            byBasename = basenames
            byNormalizedTitle = titles
        }

        func matchByBasename(_ path: String) -> Song? {
            for needle in PlaylistImporter.basenameCandidates(for: path) {
                if let match = PlaylistImporter.chooseBest(from: byBasename[needle] ?? []) {
                    return match
                }
            }
            return nil
        }

        func matchByTitleArtist(title: String, artist: String?) -> Song? {
            let normalizedTitle = PlaylistImporter.normalize(title)
            guard !normalizedTitle.isEmpty,
                  let candidates = byNormalizedTitle[normalizedTitle]
            else { return nil }
            guard let artist else {
                return PlaylistImporter.chooseBest(from: candidates)
            }
            let normalizedArtist = PlaylistImporter.normalize(artist)
            return PlaylistImporter.chooseBest(from: candidates.filter {
                PlaylistImporter.normalize($0.artistName ?? "") == normalizedArtist
            })
        }
    }

    /// 多个匹配命中时挑最高音质 (DuplicateDetector 已经把这一逻辑写好了)。
    nonisolated private static func chooseBest(from songs: [Song]) -> Song? {
        guard !songs.isEmpty else { return nil }
        return songs.max { DuplicateDetector.qualityScore(of: $0) < DuplicateDetector.qualityScore(of: $1) }
    }

    nonisolated private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    nonisolated private static func basenameCandidates(for rawPath: String) -> [String] {
        var candidates: [String] = []
        func append(_ value: String) {
            let basename = (value as NSString).lastPathComponent.lowercased()
            if !basename.isEmpty, !candidates.contains(basename) { candidates.append(basename) }
        }
        // Preserve literal percent signs first so a real file named `%20.mp3`
        // wins over the decoded-space fallback.
        append(rawPath)
        if let url = URL(string: rawPath), url.isFileURL {
            append(url.path)
        }
        if let decoded = rawPath.removingPercentEncoding {
            append(decoded)
        }
        return candidates
    }

    // MARK: - Apply

    /// 把 preview 里匹配到的歌曲创建成新歌单 (用 `playlistName`)。
    /// 未匹配的条目会被丢弃。返回新创建的 Playlist。
    @discardableResult
    static func createPlaylist(
        from preview: ImportPreview,
        named playlistName: String,
        library: MusicLibrary
    ) -> Playlist {
        let songIDs = preview.entries.compactMap { $0.matchedSong?.id }
        // 按导入顺序一次写入。逐首 add 会让大型歌单重复持久化整份曲库
        // 快照并向 SwiftUI / CloudKit 发布 N 次。
        return library.createPlaylist(name: playlistName, songIDs: songIDs)
    }
}
