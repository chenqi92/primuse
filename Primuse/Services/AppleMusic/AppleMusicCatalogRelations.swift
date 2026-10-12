import Foundation
import MusicKit
import PrimuseKit

/// 续播用的 Apple Music 目录相似歌曲。规则(怎么对上同一首、怎么拼一批)在
/// `AppleMusicCatalogContinuationPolicy`,这里只管向目录和 Last.fm 取数据。
extension AppleMusicLibraryService {
    // MARK: 续播相似歌曲

    /// 跟 `seeds`(最近播的在前)相似的目录曲:先拿 Last.fm 的相似单曲到目录里逐首对上,
    /// 不够再轮流放相似艺人和本人的热门曲。`excludedIDs` 是 Primuse 歌曲 ID,
    /// `excludedSongKeys` 是 `AppleMusicCatalogContinuationPolicy.songKey`。
    /// 取不到返回空,调用方退回曲库里挑。
    func similarCatalogSongs(
        seeds: [PrimuseKit.Song],
        excludedIDs: Set<String>,
        excludedSongKeys: Set<String>
    ) async -> [PrimuseKit.Song] {
        typealias Policy = AppleMusicCatalogContinuationPolicy
        guard catalogPlaybackIsAvailable, let seed = seeds.first else { return [] }
        let similar = await lastFmSimilarCatalogSongs(for: seed, excludedSongKeys: excludedSongKeys)
        guard !Task.isCancelled else { return [] }
        let artistLists = similar.count < Policy.batchSize ? await artistTopSongs(around: seed) : []
        guard !Task.isCancelled else { return [] }

        var songsByID: [String: MusicKit.Song] = [:]
        for song in similar + artistLists.flatMap({ $0 }) where songsByID[song.id.rawValue] == nil {
            songsByID[song.id.rawValue] = song
        }
        let picked = Policy.assemble(
            similarTracks: similar.map(Self.continuationCandidate),
            artistTopSongs: artistLists.map { $0.map(Self.continuationCandidate) },
            isExcluded: { candidate in
                excludedIDs.contains(Self.primuseSongID(forItemID: candidate.id))
                    || excludedSongKeys.contains(Policy.songKey(title: candidate.title, artist: candidate.artist))
            }
        )
        plog(
            "♾️ Apple Music catalog continuation seed='\(seed.title)' "
                + "lastfm=\(similar.count) artists=\(artistLists.count) picked=\(picked.count)"
        )
        return registerCatalogSongs(picked.compactMap { songsByID[$0.id] })
    }

    /// Last.fm 认为相似的单曲,在目录里逐首对上(对不上的丢掉)。按 Last.fm 的相似度排序。
    private func lastFmSimilarCatalogSongs(
        for seed: PrimuseKit.Song,
        excludedSongKeys: Set<String>
    ) async -> [MusicKit.Song] {
        typealias Policy = AppleMusicCatalogContinuationPolicy
        let artist = (seed.artistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return [] }
        let tracks: [LastFmSimilarAPI.SimilarTrack]
        do {
            tracks = try await LastFmSimilarAPI().similarTracks(artist: artist, track: seed.title, limit: 40)
        } catch {
            plog("♾️ Last.fm similar tracks unavailable for '\(seed.title)': \(error.localizedDescription)")
            return []
        }
        var seenKeys = excludedSongKeys
        let wanted = Array(tracks.filter {
            !$0.title.isEmpty && seenKeys.insert(Policy.songKey(title: $0.title, artist: $0.artist)).inserted
        }.prefix(Policy.lastFmLookupLimit))

        var found: [MusicKit.Song] = []
        var start = 0
        while start < wanted.count, found.count < Policy.batchSize, !Task.isCancelled {
            let chunk = Array(wanted[start..<min(start + Policy.lookupConcurrency, wanted.count)])
            start += chunk.count
            let matches = await withTaskGroup(of: (Int, MusicKit.Song?).self) { group in
                for (offset, track) in chunk.enumerated() {
                    group.addTask {
                        (offset, await Self.catalogSong(matchingTitle: track.title, artist: track.artist))
                    }
                }
                var results = [MusicKit.Song?](repeating: nil, count: chunk.count)
                for await (offset, song) in group { results[offset] = song }
                return results
            }
            found += matches.compactMap { $0 }
        }
        return found
    }

    /// 目录里按「歌名 歌手」搜,只认歌名、歌手都对得上的那一条。
    private nonisolated static func catalogSong(matchingTitle title: String, artist: String) async -> MusicKit.Song? {
        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [MusicKit.Song.self])
        request.limit = 5
        guard let songs = try? await Array(request.response().songs),
              let index = AppleMusicCatalogContinuationPolicy.matchIndex(
                title: title,
                artist: artist,
                in: songs.map(continuationCandidate)
              ) else { return nil }
        return songs[index]
    }

    /// 相似艺人(按目录给的顺序)与本人的热门曲,每位一组。本人那组排在第二,
    /// 轮流取时开头是一首别人的,接着才是本人的。
    private func artistTopSongs(around seed: PrimuseKit.Song) async -> [[MusicKit.Song]] {
        typealias Policy = AppleMusicCatalogContinuationPolicy
        guard let catalogSeed = await catalogMusicKitSong(for: seed) else { return [] }
        do {
            guard let seedArtist = try await catalogSeed.with([.artists]).artists?.first else { return [] }
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

    private nonisolated static func continuationCandidate(
        _ song: MusicKit.Song
    ) -> AppleMusicCatalogContinuationPolicy.Candidate {
        .init(id: song.id.rawValue, title: song.title, artist: song.artistName)
    }
}
