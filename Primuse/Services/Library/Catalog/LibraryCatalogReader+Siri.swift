import Foundation
import PrimuseKit

extension LibraryCatalogReader {
    /// Siri 按名字、按 id 找歌的候选(见 `SiriMediaSearchResolver.candidateSongs`):在主线程外
    /// 按库内顺序流式挑出,只物化可能命中的那些。
    func siriCandidateSongs(
        query: SiriMediaSearchQuery,
        resolvedItemIDs: [String],
        scope: LibrarySongScope
    ) async throws -> [Song] {
        try await read { catalog in
            try SiriMediaSearchResolver.candidateSongs(query: query, resolvedItemIDs: resolvedItemIDs) { body in
                try catalog.forEachSong(scope) { _, song in
                    try body(song)
                    return true
                }
            }
        }
    }
}

/// Siri 解析要的歌。目录可读时只取候选(交给 `SiriMediaSearchResolver` 各入口与交整库的结果相同),
/// 目录读不了、读失败时照旧给内存里的整库数组。
@MainActor
enum SiriLibrarySongs {
    enum Scope {
        /// 音乐(`musicSongs`)。
        case music
        /// 全部可见内容(`visibleSongs`)。
        case visible
        /// 有声书(`spokenWordSongs`:有声内容里不含本机下载的播客单集)。
        case spokenWord
    }

    static func candidates(
        for query: SiriMediaSearchQuery,
        identifiers: [String] = [],
        in scope: Scope,
        library: MusicLibrary
    ) async -> [Song] {
        if let host = library.catalogHost, host.revisions.isReadable {
            let catalogScope: LibrarySongScope
            switch scope {
            case .music: catalogScope = .visibleMusic
            case .visible: catalogScope = .visible
            case .spokenWord: catalogScope = LibrarySongScope(kinds: [.spokenWord])
            }
            do {
                return try await host.reader.siriCandidateSongs(
                    query: query, resolvedItemIDs: identifiers, scope: catalogScope
                )
            } catch {
                plog("🎙️ Siri catalog candidates failed (\(error)); using the in-memory library")
            }
        }
        switch scope {
        // crash-pattern: allow legacy-library-api 目录读不了时的后备,同原来交整库
        case .music: return library.musicSongs
        // crash-pattern: allow legacy-library-api 目录读不了时的后备,同原来交整库
        case .visible: return library.visibleSongs
        // crash-pattern: allow legacy-library-api 目录读不了时的后备,同原来交整库
        case .spokenWord: return library.spokenWordSongs
        }
    }
}

/// Siri 按名字找专辑、艺人、流派时比对的名字清单(iPhone 与电视共用)。目录可读时在目录上分批建
/// (专辑、艺人按可见列表的先后,流派按可见歌曲逐首走同一套拆法),不取整库数组;目录读不了、读失败
/// 时照旧用内存里的列表。
@MainActor
enum SiriLibraryNamedItems {
    static func albums(artistName: String?, library: MusicLibrary) async -> [SiriNamedMediaItem] {
        let requestedArtist = artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = library.catalogHost, host.revisions.isReadable {
            do {
                return try await host.reader.read { catalog in
                    let keys = try catalog.albumKeys(visibleOnly: true).keys
                    var items: [SiriNamedMediaItem] = []
                    var start = 0
                    while start < keys.count {
                        let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                        for album in try catalog.albums(keys: keys[start..<end], visibleCounts: true) {
                            if let item = albumItem(album, requestedArtist: requestedArtist) { items.append(item) }
                        }
                        start = end
                    }
                    return items
                }
            } catch {
                plog("🎙️ Siri album names catalog read failed (\(error)); using the in-memory library")
            }
        }
        // crash-pattern: allow legacy-library-api 目录读不了时的后备,同原来交整库
        return library.visibleAlbums.compactMap { albumItem($0, requestedArtist: requestedArtist) }
    }

    static func artists(library: MusicLibrary) async -> [SiriNamedMediaItem] {
        if let host = library.catalogHost, host.revisions.isReadable {
            do {
                return try await host.reader.read { catalog in
                    let keys = try catalog.artistKeys(visibleOnly: true).keys
                    var items: [SiriNamedMediaItem] = []
                    var start = 0
                    while start < keys.count {
                        let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                        for artist in try catalog.artists(keys: keys[start..<end], visibleCounts: true) {
                            items.append(SiriNamedMediaItem(id: artist.id, name: artist.name))
                        }
                        start = end
                    }
                    return items
                }
            } catch {
                plog("🎙️ Siri artist names catalog read failed (\(error)); using the in-memory library")
            }
        }
        // crash-pattern: allow legacy-library-api 目录读不了时的后备,同原来交整库
        return library.visibleArtists.map { SiriNamedMediaItem(id: $0.id, name: $0.name) }
    }

    static func genres(library: MusicLibrary) async -> [SiriNamedMediaItem] {
        if let host = library.catalogHost, host.revisions.isReadable {
            do {
                return try await host.reader.read { catalog in
                    var collector = GenreCollector()
                    try catalog.forEachSong(.visible) { _, song in
                        collector.add(song)
                        return true
                    }
                    return collector.items
                }
            } catch {
                plog("🎙️ Siri genre names catalog read failed (\(error)); using the in-memory library")
            }
        }
        var collector = GenreCollector()
        // crash-pattern: allow legacy-library-api 目录读不了时的后备,同原来交整库
        for song in library.visibleSongs { collector.add(song) }
        return collector.items
    }

    nonisolated private static func albumItem(_ album: Album, requestedArtist: String?) -> SiriNamedMediaItem? {
        if let requestedArtist, !requestedArtist.isEmpty,
           album.artistName?.localizedCaseInsensitiveContains(requestedArtist) != true {
            return nil
        }
        let displayName: String
        if let artist = album.artistName, !artist.isEmpty {
            displayName = "\(album.title) — \(artist)"
        } else {
            displayName = album.title
        }
        return SiriNamedMediaItem(id: album.id, name: displayName, aliases: [album.title])
    }

    /// 可见歌曲里出现过的流派名(按浏览时的拆法,不分大小写去重),按名字排。
    private struct GenreCollector {
        private var seenRaw = Set<String>()
        private var seen = Set<String>()
        private var collected: [SiriNamedMediaItem] = []

        mutating func add(_ song: Song) {
            // ID3 格式的歌另按斜杠惯例拆：同一串流派写法按两种拆法各看一次。
            guard let raw = song.genre,
                  seenRaw.insert(GenreSlashConvention.applies(to: song.fileFormat) ? "\u{1}" + raw : raw).inserted
            else { return }
            for genre in GenreTagValues.browseNames(for: song) where seen.insert(genre.lowercased()).inserted {
                collected.append(SiriNamedMediaItem(id: genre, name: genre))
            }
        }

        var items: [SiriNamedMediaItem] {
            collected.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

