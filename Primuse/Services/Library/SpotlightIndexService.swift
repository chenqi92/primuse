import CoreSpotlight
import Foundation
import OSLog
import PrimuseKit
import UIKit

private let spotlightLog = Logger(subsystem: "com.welape.yuanyin", category: "Spotlight")

// 让 detached background task 也能引用 ── 放在文件作用域避免 @MainActor 隔离。
private let kSongDomain = "com.welape.yuanyin.spotlight.song"
private let kAlbumDomain = "com.welape.yuanyin.spotlight.album"
private let kArtistDomain = "com.welape.yuanyin.spotlight.artist"
private let kPlaylistDomain = "com.welape.yuanyin.spotlight.playlist"

/// Index 主库到系统 Spotlight。用户下拉 Spotlight 搜索 / Siri 搜歌时,猿音
/// 的歌 / 专辑 / 艺术家 / 歌单会出现在结果里; 点进去走 NSUserActivity
/// `CSSearchableItemActionType` 把 identifier 交给 app, ContentView 通过
/// `.onContinueUserActivity` 路由到对应播放或导航。
///
/// 索引策略:
/// - 整库 reindex 由 `reindex(library:)` 调用,在启动 + 库变更 token 翻动时跑
/// - 索引项的 `domainIdentifier` 拆 song / album / artist / playlist 四类,
///   便于将来需要时按类批量删除
/// - 主标题 = 歌名 / 专辑 / 艺术家 / 歌单名; 副标题 = artist (歌曲/专辑) 或
///   item count (歌单)
/// - thumbnailData 从 MetadataAssetStore 取,小图压缩后塞进 attribute set
@MainActor
final class SpotlightIndexService {
    /// 同时 inflight 的 reindex 任务 —— 库变更 token 高频触发时只跑最新一次。
    private var pendingTask: Task<Void, Never>?

    /// 批量重建。先 deleteAll(本 app 的) 再 indexSearchableItems(所有当前可见
    /// 项)。整库万级数据 reindex 在背景 Task.detached 跑,主线程只负责快照
    /// 当前 library 状态。
    func reindex(library: MusicLibrary) {
        // 取消上一次未完成的 reindex
        pendingTask?.cancel()

        // 快照在主线程做(MusicLibrary 是 @MainActor),后续序列化 + 喂 Spotlight
        // 走 detached background Task。
        let songs = library.visibleSongs
        let albums = library.visibleAlbums
        let artists = library.visibleArtists
        // playlist song count 也要在主线程预先 lookup 好,nonisolated 任务
        // 拿不到 MusicLibrary 实例。
        let playlistSummaries: [PlaylistSummary] = library.playlists.map { p in
            PlaylistSummary(id: p.id, name: p.name, songCount: library.songs(forPlaylist: p.id).count)
        }

        pendingTask = Task.detached(priority: .background) { [songs, albums, artists, playlistSummaries] in
            await Self.performReindex(
                songs: songs,
                albums: albums,
                artists: artists,
                playlists: playlistSummaries
            )
        }
    }

    /// 解析 NSUserActivity 拿出原始 identifier。Spotlight 点击会把
    /// `CSSearchableItemActivityIdentifier` 塞进 userInfo,这里直接还出来。
    static func identifier(from activity: NSUserActivity) -> SpotlightItem? {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return nil
        }
        return parse(uniqueIdentifier: id)
    }

    /// 把 unique identifier 拆回 (kind, modelID)。Spotlight 项的 id 我们约定
    /// 形如 `song:<modelID>` / `album:<modelID>` 等。
    static func parse(uniqueIdentifier: String) -> SpotlightItem? {
        let parts = uniqueIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        switch String(parts[0]) {
        case "song": return .song(id: String(parts[1]))
        case "album": return .album(id: String(parts[1]))
        case "artist": return .artist(id: String(parts[1]))
        case "playlist": return .playlist(id: String(parts[1]))
        default: return nil
        }
    }

    // MARK: - Private

    /// 主线程快照后,detached 用得到的 playlist 简表。Playlist 模型自己不带
    /// songCount,得 query 一次 library.songs(forPlaylist:) 计算。
    private struct PlaylistSummary: Sendable {
        let id: String
        let name: String
        let songCount: Int
    }

    private nonisolated static func performReindex(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        playlists: [PlaylistSummary]
    ) async {
        let index = CSSearchableIndex.default()

        // 先把旧索引按 domain 删干净
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            index.deleteSearchableItems(withDomainIdentifiers: [
                kSongDomain, kAlbumDomain, kArtistDomain, kPlaylistDomain,
            ]) { _ in continuation.resume() }
        }

        var items: [CSSearchableItem] = []
        items.reserveCapacity(songs.count + albums.count + artists.count + playlists.count)

        for song in songs {
            if Task.isCancelled { return }
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = song.title
            attrs.album = song.albumTitle
            attrs.artist = song.artistName
            attrs.contentDescription = [song.artistName, song.albumTitle]
                .compactMap { $0 }.joined(separator: " — ")
            attrs.keywords = [song.title, song.artistName, song.albumTitle].compactMap { $0 }
            attrs.thumbnailData = await thumbnailData(for: song.coverArtFileName)
            items.append(CSSearchableItem(
                uniqueIdentifier: "song:\(song.id)",
                domainIdentifier: kSongDomain,
                attributeSet: attrs
            ))
        }
        for album in albums {
            if Task.isCancelled { return }
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = album.title
            attrs.album = album.title
            attrs.artist = album.artistName
            attrs.contentDescription = album.artistName ?? ""
            attrs.keywords = [album.title, album.artistName].compactMap { $0 }
            // Album 没 coverArtFileName,只有 coverArtPath ── 那是源站路径,
            // 不在 App Group 资产目录里。Spotlight thumb 留空,系统给通用 icon。
            items.append(CSSearchableItem(
                uniqueIdentifier: "album:\(album.id)",
                domainIdentifier: kAlbumDomain,
                attributeSet: attrs
            ))
        }
        for artist in artists {
            if Task.isCancelled { return }
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = artist.name
            attrs.artist = artist.name
            attrs.contentDescription = String(localized: "spotlight_artist_subtitle")
            attrs.keywords = [artist.name]
            items.append(CSSearchableItem(
                uniqueIdentifier: "artist:\(artist.id)",
                domainIdentifier: kArtistDomain,
                attributeSet: attrs
            ))
        }
        for playlist in playlists {
            if Task.isCancelled { return }
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = playlist.name
            attrs.contentDescription = String(
                format: String(localized: "spotlight_playlist_subtitle_format"),
                playlist.songCount
            )
            attrs.keywords = [playlist.name]
            items.append(CSSearchableItem(
                uniqueIdentifier: "playlist:\(playlist.id)",
                domainIdentifier: kPlaylistDomain,
                attributeSet: attrs
            ))
        }

        if Task.isCancelled { return }
        let finalItems = items // 让闭包捕获 immutable let,不再触发并发警告
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            index.indexSearchableItems(finalItems) { error in
                if let error {
                    spotlightLog.error("Spotlight index failed: \(error.localizedDescription)")
                } else {
                    spotlightLog.notice("Spotlight indexed \(finalItems.count) items")
                }
                continuation.resume()
            }
        }
    }

    /// 读封面 Data,压成 128x128 JPEG 缩略图喂给 Spotlight。MetadataAssetStore
    /// 是 @MainActor,读操作通过 MainActor.run hop 过去做。
    /// 没封面 / 失败时返回 nil — Spotlight 会显示通用 SF icon。
    private nonisolated static func thumbnailData(for coverArtFileName: String?) async -> Data? {
        guard let coverArtFileName, !coverArtFileName.isEmpty else { return nil }
        let raw: Data? = await MainActor.run {
            MetadataAssetStore.shared.readCoverData(named: coverArtFileName)
        }
        guard let raw, let image = UIImage(data: raw) else { return nil }
        let target = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: target)
        let small = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return small.jpegData(compressionQuality: 0.7)
    }
}

/// Spotlight 结果项类型。`SpotlightIndexService.identifier(from:)` 解析后
/// 给 ContentView,ContentView 根据 case 路由到播放 / 详情页。
enum SpotlightItem: Sendable {
    case song(id: String)
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
}
