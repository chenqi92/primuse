#if os(tvOS)
import Foundation
import MusicKit
import PrimuseKit

/// Apple TV 上的 Apple Music 目录搜索。
///
/// 只做搜索与结果转换:把 MusicKit 的 `Song` 变成 `AppleMusicCatalogHit`,
/// 界面层不必引入 MusicKit。播放由 `TVAppleMusicPlayer` 负责。
///
/// 未授权时不发请求也不弹授权:搜索框每敲一下弹一次对话框不可接受,
/// 授权留到用户真的点播某一条时再请求(见 `TVAppleMusicPlayer.play`)。
@MainActor
@Observable
final class TVAppleMusicCatalog {
    private(set) var hits: [AppleMusicCatalogHit] = []
    private(set) var albums: [AppleMusicCatalogAlbumHit] = []
    private(set) var artists: [AppleMusicCatalogArtistHit] = []
    /// 用户在 Apple Music 里建的歌单。与搜索无关,进入歌单页时加载一次。
    private(set) var playlists: [AppleMusicPlaylistHit] = []
    private(set) var isLoadingPlaylists = false
    private(set) var isSearching = false
    private(set) var lastError: String?
    /// 未授权 —— 界面据此提示「去设置里允许后即可搜索 Apple Music」。
    private(set) var needsAuthorization = false

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func search(_ term: String) {
        searchTask?.cancel()
        let authorization = Self.authorizationState
        needsAuthorization = authorization != .authorized
        guard AppleMusicCatalogSearchPolicy.shouldSearch(
            term: term,
            authorization: authorization
        ) else {
            hits = []
            albums = []
            artists = []
            isSearching = false
            lastError = nil
            return
        }
        let normalized = AppleMusicCatalogSearchPolicy.normalized(term)
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: AppleMusicCatalogSearchPolicy.debounce)
            guard !Task.isCancelled, let self else { return }
            await self.run(term: normalized)
        }
    }

    func clear() {
        searchTask?.cancel()
        searchTask = nil
        hits = []
        albums = []
        artists = []
        isSearching = false
        lastError = nil
    }

    /// 拉取用户自己的 Apple Music 歌单。未授权时不发请求也不弹授权。
    func loadPlaylists() async {
        guard Self.authorizationState == .authorized else {
            needsAuthorization = true
            playlists = []
            return
        }
        needsAuthorization = false
        guard !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        defer { isLoadingPlaylists = false }
        do {
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.limit = 100
            var batch = try await request.response().items
            var collected = Array(batch)
            while batch.hasNextBatch {
                try Task.checkCancellation()
                guard let next = try await batch.nextBatch() else { break }
                collected.append(contentsOf: next)
                batch = next
            }
            guard !Task.isCancelled else { return }
            playlists = AppleMusicCatalogSearchPolicy.deduplicatedByID(
                collected.map(Self.hit(from:))
            )
            lastError = nil
        } catch is CancellationError {
            // 视图已经离开,不必报错。
        } catch {
            guard !Task.isCancelled else { return }
            playlists = []
            lastError = error.localizedDescription
        }
    }

    private func run(term: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            var request = MusicCatalogSearchRequest(
                term: term,
                types: [MusicKit.Song.self, MusicKit.Album.self, MusicKit.Artist.self]
            )
            request.limit = AppleMusicCatalogSearchPolicy.resultLimit
            let response = try await request.response()
            guard !Task.isCancelled else { return }
            hits = response.songs.map(Self.hit(from:))
            let collectionLimit = AppleMusicCatalogSearchPolicy.collectionResultLimit
            albums = AppleMusicCatalogSearchPolicy.deduplicatedByID(
                response.albums.prefix(collectionLimit).map(Self.hit(from:))
            )
            artists = AppleMusicCatalogSearchPolicy.deduplicatedByID(
                response.artists.prefix(collectionLimit).map(Self.hit(from:))
            )
            lastError = nil
        } catch is CancellationError {
            // 用户继续在打字,旧查询作废,不必报错。
        } catch {
            guard !Task.isCancelled else { return }
            hits = []
            albums = []
            artists = []
            lastError = error.localizedDescription
        }
    }

    private static func hit(from song: MusicKit.Song) -> AppleMusicCatalogHit {
        AppleMusicCatalogHit(
            id: song.id.rawValue,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle ?? "",
            duration: song.duration ?? 0,
            // 电视上这一列的缩略图不大,取 200pt 足够,别拉整张封面。
            artworkURL: song.artwork?.url(width: 200, height: 200)
        )
    }

    private static func hit(from album: MusicKit.Album) -> AppleMusicCatalogAlbumHit {
        AppleMusicCatalogAlbumHit(
            id: album.id.rawValue,
            title: album.title,
            artistName: album.artistName,
            artworkURL: album.artwork?.url(width: 400, height: 400)
        )
    }

    private static func hit(from artist: MusicKit.Artist) -> AppleMusicCatalogArtistHit {
        AppleMusicCatalogArtistHit(
            id: artist.id.rawValue,
            name: artist.name,
            artworkURL: artist.artwork?.url(width: 300, height: 300)
        )
    }

    private static func hit(from playlist: MusicKit.Playlist) -> AppleMusicPlaylistHit {
        AppleMusicPlaylistHit(
            id: playlist.id.rawValue,
            name: playlist.name,
            curatorName: playlist.curatorName ?? "",
            artworkURL: playlist.artwork?.url(width: 400, height: 400)
        )
    }

    private static var authorizationState: AppleMusicAuthorizationState {
        switch MusicAuthorization.currentStatus {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
#endif
