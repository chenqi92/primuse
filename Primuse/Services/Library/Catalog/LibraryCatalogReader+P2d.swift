import Foundation
import PrimuseKit

/// P2d(扫描、音乐源、离线、批量整理、tvOS)要的读接口。全部建在目录的公开接口之上,
/// 结果有界(专辑曲目、喜欢的专辑/艺人、计数)或在主线程外流式折叠(调用方只留有界的结果)。
extension LibraryCatalogReader {
    // MARK: Counts

    /// 各源的歌曲数。默认含停用源,与按 `library.songs` 数各源的旧写法一致。
    func songCountsBySource(_ scope: LibrarySongScope = .everything) async throws -> [String: Int] {
        try await read { try $0.songCountsBySource(scope) }
    }

    /// 首页、资料库标题、「有没有内容」要的几个数:可见音乐歌曲数、可见专辑数、可见艺人数
    /// (对应 `musicSongs.count`、`visibleAlbums.count`、`visibleArtists.count`)。
    func presenceCounts() async throws -> LibraryCatalogPresenceCounts {
        try await read { catalog in
            LibraryCatalogPresenceCounts(
                musicSongs: try catalog.songCount(.visibleMusic),
                albums: try catalog.albumKeys(visibleOnly: true).count,
                artists: try catalog.artistKeys(visibleOnly: true).count
            )
        }
    }

    // MARK: Albums

    /// 一张专辑的可见曲目 id,按碟号、曲号(`AlbumTrackOrder`),至多 `limit` 首。
    func albumSongIDs(albumID: String, limit: Int = LibraryScale.maxMaterializedRows) async throws -> [String] {
        try await albumSongIDs(albumIDs: [albumID], limit: limit)[albumID] ?? []
    }

    /// 专辑墙顺序里的最后 `count` 张可见专辑(对应 `visibleAlbums.suffix(count)`)。
    func lastAlbums(count: Int, visibleOnly: Bool = true) async throws -> [Album] {
        let cap = min(max(0, count), LibraryScale.maxMaterializedRows)
        guard cap > 0 else { return [] }
        return try await read { catalog in
            let keys = try catalog.albumKeys(visibleOnly: visibleOnly).keys
            return try catalog.albums(keys: keys.suffix(cap), visibleCounts: visibleOnly)
        }
    }

    // MARK: Liked albums and artists

    /// 喜欢的专辑:可见专辑按喜欢的键(`LibraryFavoriteKey`,与 `LibraryFavoritesStore.likedAlbums(in:)`
    /// 同一个算法)对上 `likedOrder`,按喜欢的先后排(同一个先后保持专辑墙顺序)。
    /// 专辑按键分批物化,内存只占一批;结果以对上喜欢的专辑数为界(同名同艺人的几张都算,
    /// 与旧写法一样走完整列)。
    func likedAlbums(likedOrder: [String: Int], unknownArtistName: String) async throws -> [Album] {
        guard !likedOrder.isEmpty else { return [] }
        return try await read { catalog in
            let keys = try catalog.albumKeys(visibleOnly: true).keys
            var matched: [(album: Album, offset: Int)] = []
            var start = 0
            while start < keys.count {
                let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                for album in try catalog.albums(keys: keys[start..<end], visibleCounts: true) {
                    let key = LibraryFavoriteKey.id(
                        kind: .album, albumTitle: album.title, artistName: album.artistName ?? "",
                        unknownArtistName: unknownArtistName
                    )
                    if let offset = likedOrder[key] { matched.append((album, offset)) }
                }
                start = end
            }
            return matched.sorted { $0.offset < $1.offset }.map(\.album)
        }
    }

    /// 喜欢的艺人(全部艺人的可见列表,对应 `likedArtists(in: visibleArtists)`)。
    func likedArtists(likedOrder: [String: Int], unknownArtistName: String) async throws -> [Artist] {
        guard !likedOrder.isEmpty else { return [] }
        return try await read { catalog in
            let keys = try catalog.artistKeys(visibleOnly: true).keys
            var matched: [(artist: Artist, offset: Int)] = []
            var start = 0
            while start < keys.count {
                let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                for artist in try catalog.artists(keys: keys[start..<end], visibleCounts: true) {
                    let key = LibraryFavoriteKey.id(
                        kind: .artist, albumTitle: "", artistName: artist.name,
                        unknownArtistName: unknownArtistName
                    )
                    if let offset = likedOrder[key] { matched.append((artist, offset)) }
                }
                start = end
            }
            return matched.sorted { $0.offset < $1.offset }.map(\.artist)
        }
    }

    // MARK: Paths

    /// 某源里某个精确路径上的所有歌曲 id(CUE 分轨共用一个文件),库内顺序,含停用源。
    func songIDs(sourceID: String, filePath: String) async throws -> [String] {
        try await read { catalog in
            let rows = try catalog.rowList(sourceID: sourceID, filePath: filePath).rowids
            return try catalog.songs(rowids: rows).map(\.id)
        }
    }

    /// 同一个音频文件上的歌(CUE 分轨的兄弟轨),库内顺序,含停用源。
    func songs(sourceID: String, filePath: String) async throws -> [Song] {
        try await read { catalog in
            try catalog.songs(rowids: catalog.rowList(sourceID: sourceID, filePath: filePath).rowids)
        }
    }

    // MARK: Streaming folds

    /// 在主线程外按库内顺序流式折叠一个范围的身份投影(行号、id、路径);`update` 返回 false
    /// 提前结束。结果的大小由调用方负责(只留有界的东西,或某个源范围内的东西)。
    func reduceSongIdentities<Result: Sendable>(
        _ scope: LibrarySongScope,
        into initial: Result,
        _ update: @escaping @Sendable (inout Result, LibraryCatalogSongIdentity) -> Bool
    ) async throws -> Result {
        try await read { catalog in
            var result = initial
            try catalog.forEachSongIdentity(scope) { rowid, id, filePath in
                update(&result, LibraryCatalogSongIdentity(rowid: rowid, id: id, filePath: filePath))
            }
            return result
        }
    }

    /// 同上,遍历整首歌(维护谓词、离线、补全选批这类要看标签字段的)。内存只占一批。
    func reduceSongs<Result: Sendable>(
        _ scope: LibrarySongScope,
        into initial: Result,
        _ update: @escaping @Sendable (inout Result, Song) -> Bool
    ) async throws -> Result {
        try await read { catalog in
            var result = initial
            try catalog.forEachSong(scope) { _, song in update(&result, song) }
            return result
        }
    }
}

/// `LibraryCatalogReader.presenceCounts()` 的结果。
struct LibraryCatalogPresenceCounts: Sendable, Equatable {
    var musicSongs: Int
    var albums: Int
    var artists: Int
}
