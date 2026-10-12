import Foundation
import MusicKit
import PrimuseKit

/// Apple Music 目录里和一首歌挨着的歌:相似艺人与本人的热门曲,以及按歌名歌手对上的同一首。
/// 只问 MusicKit 目录,不碰曲库;手机、Mac 的目录续播(`similarCatalogSongs`)和电视的
/// 目录续播共用这一份。怎么拼成一批在 `AppleMusicCatalogContinuationPolicy`。
enum AppleMusicCatalogNeighbors {
    /// 相似艺人(按目录给的顺序)与本人的热门曲,每位一组。本人那组排在第二,
    /// 轮流取时开头是一首别人的,接着才是本人的。`seed` 得是目录曲,资料库条目没有这些关系。
    static func artistTopSongs(around seed: MusicKit.Song) async -> [[MusicKit.Song]] {
        typealias Policy = AppleMusicCatalogContinuationPolicy
        do {
            guard let seedArtist = try await seed.with([.artists]).artists?.first else { return [] }
            let detailed = try await seedArtist.with([.topSongs, .similarArtists])
            let similarIDs = Array((detailed.similarArtists.map { Array($0) } ?? [])
                .prefix(Policy.similarArtistLimit)
                .map(\.id))
            var lists: [[MusicKit.Song]] = []
            if !similarIDs.isEmpty {
                var request = MusicCatalogResourceRequest<MusicKit.Artist>(matching: \.id, memberOf: similarIDs)
                request.properties = [.topSongs]
                let artists = try await request.response().items
                // 一次批量查回来不保证按请求的顺序,按相似度排回去。
                var byID: [MusicItemID: MusicKit.Artist] = [:]
                for artist in artists where byID[artist.id] == nil { byID[artist.id] = artist }
                lists = similarIDs.compactMap { id in
                    guard let songs = byID[id]?.topSongs else { return nil }
                    return Array(songs.prefix(Policy.topSongsPerArtist))
                }
            }
            let own = Array((detailed.topSongs.map { Array($0) } ?? []).prefix(Policy.topSongsPerArtist))
            if !own.isEmpty { lists.insert(own, at: min(1, lists.count)) }
            return lists.filter { !$0.isEmpty }
        } catch {
            plog("♾️ Apple Music artist lookup failed for '\(seed.title)': \(error.localizedDescription)")
            return []
        }
    }

    /// 目录里按「歌名 歌手」搜,只认歌名、歌手都对得上的那一条。
    static func song(matchingTitle title: String, artist: String) async -> MusicKit.Song? {
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [MusicKit.Song.self])
        request.limit = 5
        guard let songs = try? await Array(request.response().songs),
              let index = AppleMusicCatalogContinuationPolicy.matchIndex(
                title: title,
                artist: artist,
                in: songs.map(candidate)
              ) else { return nil }
        return songs[index]
    }

    static func candidate(_ song: MusicKit.Song) -> AppleMusicCatalogContinuationPolicy.Candidate {
        .init(id: song.id.rawValue, title: song.title, artist: song.artistName)
    }
}
