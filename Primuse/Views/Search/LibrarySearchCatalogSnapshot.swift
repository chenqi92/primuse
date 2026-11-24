import Foundation
import PrimuseKit

/// 全局搜索走曲库目录时交给 `LibrarySearchIndex` 的歌曲快照(P2c)。
///
/// 持久搜索索引(FTS)给出候选 id,快照只负责把 id 换成可见音乐里的歌;两种情况例外,
/// 索引要直接扫快照里的歌(`LibrarySearchIndex.search` 里的 `shortMetadataIDs` 与短查询的
/// 路径匹配)。内存路径给的是整份 `musicSongs`;这里只给扫描真正会挑中的那些歌:
/// 两种扫描都是按库内顺序的贪心挑选,在「包含所有被挑中的歌、保持库内顺序」的子序列上
/// 重跑一遍,挑中的歌与名次和在整库上跑完全相同。
///
/// - 不需要扫描的查询(≥3 个字,或短查询既不是短汉字也不搜路径):按 id 批量回查目录。
/// - 需要扫描的短查询:流式走一遍目录挑出候选,其余 id(短拼音查询的 FTS 命中)按 id 同步回查。
enum LibrarySearchCatalogSnapshot {
    static func make(
        reader: LibraryCatalogReader,
        query: String,
        matchKinds: Set<LibrarySearchMatchKind>,
        wantsAlbums: Bool,
        songLimit: Int,
        sourceTypes: [String: MusicSourceType]
    ) async throws -> LibrarySearchSongSnapshot {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchesMetadata = wantsAlbums || matchKinds.contains(.metadata) || matchKinds.contains(.fuzzy)
        let scansMetadata = searchesMetadata && trimmed.count < 3 && containsHan(trimmed)
        let scansPaths = matchKinds.contains(.path) && trimmed.count < 3 && songLimit > 0
        guard !trimmed.isEmpty, scansMetadata || scansPaths else {
            return LibrarySearchSongSnapshot(sourceTypes: sourceTypes) { ids in
                do {
                    let songs = try await reader.songsChunked(ids: Array(ids), scope: .visibleMusic)
                    return Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                } catch {
                    if !(error is CancellationError) {
                        plog("🔎 Catalog search lookup failed: \(error.localizedDescription)")
                    }
                    return [:]
                }
            }
        }

        let limit = songLimit * 2
        let candidates = try await reader.readCancellable { catalog, cancellation in
            let locale = Locale.current
            var candidates: [Song] = []
            var exactTitles = 0
            var partialTitles = 0
            var otherMatches = 0
            var metadataDone = !scansMetadata || limit <= 0
            var pathMatches = 0
            var pathsDone = !scansPaths || limit <= 0
            var visited = 0
            try catalog.forEachSong(.visibleMusic) { _, song in
                visited += 1
                if visited.isMultiple(of: 512), cancellation.isCancelled { return false }
                var keep = false
                // 与 `LibrarySearchIndex.shortMetadataIDs` 同一挑法。
                if !metadataDone {
                    let title = song.title
                    if let range = title.range(of: trimmed, options: .caseInsensitive, locale: locale) {
                        if range == title.startIndex..<title.endIndex {
                            exactTitles += 1
                            keep = true
                            if exactTitles == limit { metadataDone = true }
                        } else if exactTitles + partialTitles < limit {
                            partialTitles += 1
                            keep = true
                        }
                    } else if exactTitles + partialTitles + otherMatches < limit,
                              otherMetadataContainsLiteral(song, query: trimmed) {
                        otherMatches += 1
                        keep = true
                    }
                }
                // 与 `LibrarySearchIndex.search` 里短查询的路径扫描同一挑法。
                if !pathsDone, pathMatchesQuery(trimmed, song: song, sourceType: sourceTypes[song.sourceID]) {
                    pathMatches += 1
                    keep = true
                    if pathMatches >= limit { pathsDone = true }
                }
                if keep { candidates.append(song) }
                return !(metadataDone && pathsDone)
            }
            try cancellation.check()
            return candidates
        }
        let catalog = try await reader.catalogHandle()
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return LibrarySearchSongSnapshot(candidates, sourceTypes: sourceTypes) { id in
            if let song = byID[id] { return song }
            return try? catalog.songs(ids: [id], scope: .visibleMusic).first
        }
    }

    // MARK: - Mirrors of the private helpers in `LibrarySearchIndex` (MusicLibrary.swift)

    private static func otherMetadataContainsLiteral(_ song: Song, query: String) -> Bool {
        searchableArtistText(song).localizedCaseInsensitiveContains(query)
            || song.albumTitle?.localizedCaseInsensitiveContains(query) == true
            || song.genre?.localizedCaseInsensitiveContains(query) == true
    }

    private static func searchableArtistText(_ song: Song) -> String {
        let nativeNames = song.sourceArtistNames ?? []
        return nativeNames.isEmpty
            ? (song.artistName ?? "")
            : nativeNames.joined(separator: " ")
    }

    private static func pathMatchesQuery(_ query: String, song: Song, sourceType: MusicSourceType?) -> Bool {
        if let path = song.serverFilePath { return path.localizedCaseInsensitiveContains(query) }
        guard sourceType?.isServerLibrary != true, sourceType != .upnp,
              SongPathPresentationPolicy.displayPathMayContain(filePath: song.filePath, query: query) else { return false }
        return SongPathPresentationPolicy.displayPath(for: song, sourceType: sourceType)?
            .localizedCaseInsensitiveContains(query) == true
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}
