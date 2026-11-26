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
