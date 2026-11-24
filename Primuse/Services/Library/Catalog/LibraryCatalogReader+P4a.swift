import Foundation
import PrimuseKit

/// P4a(补全记账、离线状态)要的读接口。
extension LibraryCatalogReader {
    // MARK: Offline

    /// `songOffline` 已经按当前这一份目录填满(导入之后要重填),此后由下载、移除与缓存范围的变化跟着维护
    /// (`SourceManager` 的离线目录同步)。为 true 时「已下载」过滤与排序可以直接读目录;为 false 时照旧走内存。
    func offlineStateIsCurrent() async throws -> Bool {
        try await read { try $0.offlineStateIsCurrent() }
    }

    /// 已下载的歌的行号,库内顺序。
    func downloadedRowList(scope: LibrarySongScope = .everything) async throws -> LibraryRowList {
        try await read { try $0.offlineRowList(.downloaded, scope: scope) }
    }

    /// 已下载的歌数。
    func downloadedSongCount(scope: LibrarySongScope = .everything) async throws -> Int {
        try await read { try $0.offlineCount(.downloaded, scope: scope) }
    }

    /// 在主线程外按库内顺序流式折叠已下载的歌(以下载数为界)。
    func reduceDownloadedSongs<Result: Sendable>(
        into initial: Result,
        _ update: @escaping @Sendable (inout Result, Song, LibraryCatalogOfflineEntry) -> Void
    ) async throws -> Result {
        try await read { catalog in
            var result = initial
            try catalog.forEachOfflineSong(.downloaded) { _, song, entry in
                update(&result, song, entry)
                return true
            }
            return result
        }
    }
}
