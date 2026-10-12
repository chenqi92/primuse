import Foundation
import MusicKit
import PrimuseKit

/// 专辑页用目录补全后的整张专辑。
struct AppleMusicAlbumCompletion: Equatable {
    /// 按目录曲序排好的整张专辑;资料库里有的用资料库那一行。
    let songs: [PrimuseKit.Song]
    /// 资料库里没有、只在目录里的那几首。
    let catalogOnlySongIDs: Set<String>
}

/// 专辑页按 Apple Music 目录补全整张专辑。怎么把目录曲目和资料库曲目对上在
/// `AppleMusicAlbumCompletionPolicy`,这里只管向目录取专辑和曲目。
extension AppleMusicLibraryService {
    /// 资料库里这张专辑只收了几首时,按目录把整张专辑排出来。专辑里有别的源的歌、
    /// 目录里找不到这张专辑、或者资料库已经收全时返回 nil,专辑页照原样显示。
    func completeAlbum(
        _ librarySongs: [PrimuseKit.Song],
        title albumTitle: String,
        artist albumArtist: String?
    ) async -> AppleMusicAlbumCompletion? {
        guard catalogPlaybackIsAvailable, !librarySongs.isEmpty,
              librarySongs.allSatisfy({ $0.sourceID == Self.systemSourceID }) else { return nil }
        guard let album = await catalogAlbum(for: librarySongs, title: albumTitle, artist: albumArtist),
              !Task.isCancelled else { return nil }
        let tracks = await Self.catalogTracks(of: album)
        guard !tracks.isEmpty, !Task.isCancelled else { return nil }

        let slots = AppleMusicAlbumCompletionPolicy.merge(
            catalogTracks: tracks.map(Self.catalogTrackIdentity),
            librarySongs: await libraryTrackIdentities(for: librarySongs)
        )
        let catalogOffsets = slots.compactMap { slot -> Int? in
            if case .catalog(let offset) = slot { return offset }
            return nil
        }
        guard !catalogOffsets.isEmpty, !Task.isCancelled else { return nil }
        let projected = Dictionary(
            uniqueKeysWithValues: zip(catalogOffsets, registerCatalogSongs(catalogOffsets.map { tracks[$0] }))
        )

        var seen = Set<String>()
        var catalogOnly = Set<String>()
        var songs: [PrimuseKit.Song] = []
        for slot in slots {
            let song: PrimuseKit.Song
            switch slot {
            case .library(let offset):
                song = librarySongs[offset]
            case .catalog(let offset):
                guard let catalogSong = projected[offset] else { continue }
                // 目录这一首其实在资料库里(收在别的专辑名下):照常用资料库那一行。
                if !isLibrarySong(catalogSong) { catalogOnly.insert(catalogSong.id) }
                song = catalogSong
            }
            if seen.insert(song.id).inserted { songs.append(song) }
        }
        guard !catalogOnly.isEmpty else { return nil }
        plog(
            "💿 Apple Music album completed '\(albumTitle)' library=\(librarySongs.count) "
                + "catalog=\(tracks.count) added=\(catalogOnly.count)"
        )
        return AppleMusicAlbumCompletion(songs: songs, catalogOnlySongIDs: catalogOnly)
    }

    /// 这张专辑在目录里是哪一张。先按资料库曲目的目录 ID 找它所在的专辑,
    /// 曲目都没带目录 ID 时再按专辑名和艺人搜。
    private func catalogAlbum(
        for songs: [PrimuseKit.Song],
        title: String,
        artist: String?
    ) async -> MusicKit.Album? {
        for song in songs.prefix(3) {
            guard !Task.isCancelled else { return nil }
            guard let catalogSong = await catalogMusicKitSong(for: song) else { continue }
            if let album = try? await catalogSong.with([.albums]).albums?.first,
               AppleMusicAlbumCompletionPolicy.albumTitlesMatch(album.title, title) {
                return album
            }
        }
        let artistName = artist ?? songs.first?.albumArtistName ?? songs.first?.artistName ?? ""
        guard !artistName.isEmpty, !Task.isCancelled else { return nil }
        var request = MusicCatalogSearchRequest(term: "\(title) \(artistName)", types: [MusicKit.Album.self])
        request.limit = 5
        guard let albums = try? await Array(request.response().albums),
              let index = AppleMusicCatalogContinuationPolicy.matchIndex(
                title: title,
                artist: artistName,
                in: albums.map {
                    AppleMusicCatalogContinuationPolicy.Candidate(
                        id: $0.id.rawValue, title: $0.title, artist: $0.artistName
                    )
                }
              ) else { return nil }
        return albums[index]
    }

    /// 专辑的全部曲目(只要歌,不要 MV)。曲目多的专辑分批给,一批批取完。
    private nonisolated static func catalogTracks(of album: MusicKit.Album) async -> [MusicKit.Song] {
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
}
