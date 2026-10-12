import Foundation
import MusicKit
import PrimuseKit

/// Apple Music 目录里和一首歌、一张专辑挨着的东西:相似艺人与本人的热门曲、按歌名歌手对上的
/// 同一首、按专辑名艺人对上的专辑和它的全部曲目。只问 MusicKit 目录,不碰曲库;手机、Mac 的
/// 目录续播与专辑补全和电视的同名功能共用这一份。怎么拼成一批在 `AppleMusicCatalogContinuationPolicy`。
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

    /// 目录里按「专辑名 艺人」搜,只认专辑名、艺人都对得上的那一张。
    static func album(matchingTitle title: String, artist: String) async -> MusicKit.Album? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [MusicKit.Album.self])
        request.limit = 5
        guard let albums = try? await Array(request.response().albums),
              let index = AppleMusicCatalogContinuationPolicy.matchIndex(
                title: title,
                artist: artist,
                in: albums.map {
                    AppleMusicCatalogContinuationPolicy.Candidate(
                        id: $0.id.rawValue, title: $0.title, artist: $0.artistName
                    )
                }
              ) else { return nil }
        return albums[index]
    }

    /// 专辑的全部曲目(只要歌,不要 MV)。曲目多的专辑分批给,一批批取完。
    static func tracks(of album: MusicKit.Album) async -> [MusicKit.Song] {
        do {
            guard var batch = try await album.with([.tracks]).tracks else { return [] }
            var songs: [MusicKit.Song] = []
            while true {
                for track in batch {
                    if case .song(let song) = track { songs.append(song) }
                }
                guard batch.hasNextBatch, songs.count < 500,
                      let next = try await batch.nextBatch() else { break }
                batch = next
            }
            return songs
        } catch {
            plog("⚠️Apple Music album tracks failed for '\(album.title)': \(error.localizedDescription)")
            return []
        }
    }

    static func candidate(_ song: MusicKit.Song) -> AppleMusicCatalogContinuationPolicy.Candidate {
        .init(id: song.id.rawValue, title: song.title, artist: song.artistName)
    }
}
