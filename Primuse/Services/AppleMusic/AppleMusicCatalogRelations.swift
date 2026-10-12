import Foundation
import MusicKit
import PrimuseKit

/// 续播用的 Apple Music 目录相似歌曲。规则(怎么对上同一首、怎么拼一批)在
/// `AppleMusicCatalogContinuationPolicy`,目录这一侧的查询在 `AppleMusicCatalogNeighbors`,
/// 这里只管 Last.fm 那一路和曲库这边的排除。
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
            similarTracks: similar.map(AppleMusicCatalogNeighbors.candidate),
            artistTopSongs: artistLists.map { $0.map(AppleMusicCatalogNeighbors.candidate) },
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
                        (offset, await AppleMusicCatalogNeighbors.song(matchingTitle: track.title, artist: track.artist))
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

    /// 相似艺人与本人的热门曲(见 `AppleMusicCatalogNeighbors`)。曲库里的歌先换成它的目录版。
    private func artistTopSongs(around seed: PrimuseKit.Song) async -> [[MusicKit.Song]] {
        guard let catalogSeed = await catalogMusicKitSong(for: seed) else { return [] }
        return await AppleMusicCatalogNeighbors.artistTopSongs(around: catalogSeed)
    }
}
