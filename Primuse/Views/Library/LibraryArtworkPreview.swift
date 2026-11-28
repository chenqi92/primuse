import Foundation
import PrimuseKit

struct LibraryArtworkPreviewSelection: Sendable {
    var revision = ""
    /// 挑这一份时的用户改动部分(快捷访问、手选封面)。只有它变了才立刻重挑。
    var userRevision = ""
    // crash-pattern: allow library-array-property 挑出的预览至多三首(从 LibraryView 移来,原来就是这个上界)
    var songs: [Song] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var radioStations: [RadioStation] = []
    var albumFallbackSongs: [String: [Song]] = [:]
    var artistFallbackSongs: [String: [Song]] = [:]
}

enum LibraryArtworkPreviewBuilder {
    static func hasReference(_ value: String?) -> Bool {
        guard let value else { return false }
        return autoreleasepool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func songHasArtworkHint(_ song: Song) -> Bool {
        hasReference(song.coverArtFileName)
            || (song.sourceID == AppleMusicLibraryIdentity.sourceID && !song.filePath.isEmpty)
    }

    static func select<Item>(
        _ items: [Item],
        maximumCount: Int = 3,
        randomSeed: String,
        id: (Item) -> String,
        hasArtworkHint: (Item) -> Bool
    ) -> [Item] {
        guard maximumCount > 0, !items.isEmpty else { return [] }
        var accumulator = LibraryArtworkPreviewAccumulator<Item>(maximumCount: maximumCount, randomSeed: randomSeed)
        for item in items {
            let itemID = id(item)
            guard !itemID.isEmpty else { continue }
            let hint = autoreleasepool { hasArtworkHint(item) }
            accumulator.offer(id: itemID, item: item, hasArtworkHint: hint)
        }
        return accumulator.items
    }
}

/// `LibraryArtworkPreviewBuilder.select` 的那一套挑法,一个一个地喂(内存里的数组与曲库目录的流式读共用,同序同结果):
/// 有封面线索的在前,其次按「种子 + id」的 FNV 散列从小到大,再按 id;同一 id 只留更靠前的那次;只留前 `maximumCount` 个。
/// 结果与喂的先后无关。
struct LibraryArtworkPreviewAccumulator<Item> {
    private typealias RankedItem = (id: String, item: Item, hasArtworkHint: Bool, rank: UInt64)
    private let maximumCount: Int
    private let seedHash: UInt64
    private var selected: [RankedItem] = []

    init(maximumCount: Int = 3, randomSeed: String) {
        self.maximumCount = maximumCount
        var seedHash: UInt64 = 14_695_981_039_346_656_037
        for byte in randomSeed.utf8 {
            seedHash ^= UInt64(byte)
            seedHash = seedHash &* 1_099_511_628_211
        }
        seedHash ^= 0
        seedHash = seedHash &* 1_099_511_628_211
        self.seedHash = seedHash
        selected.reserveCapacity(maximumCount)
    }

    var items: [Item] { selected.map(\.item) }

    private static func precedes(_ lhs: RankedItem, _ rhs: RankedItem) -> Bool {
        if lhs.hasArtworkHint != rhs.hasArtworkHint {
            return lhs.hasArtworkHint
        }
        if lhs.rank != rhs.rank {
            return lhs.rank < rhs.rank
        }
        return lhs.id < rhs.id
    }

    mutating func offer(id itemID: String, item: Item, hasArtworkHint hint: Bool) {
        guard maximumCount > 0, !itemID.isEmpty else { return }
        var rank = seedHash
        for byte in itemID.utf8 {
            rank ^= UInt64(byte)
            rank = rank &* 1_099_511_628_211
        }
        let candidate: RankedItem = (id: itemID, item: item, hasArtworkHint: hint, rank: rank)
        if let existingIndex = selected.firstIndex(where: { $0.id == itemID }) {
            guard Self.precedes(candidate, selected[existingIndex]) else { return }
            selected.remove(at: existingIndex)
        } else if selected.count == maximumCount,
                  let worst = selected.last,
                  !Self.precedes(candidate, worst) {
            return
        }
        let insertionIndex = selected.firstIndex { Self.precedes(candidate, $0) } ?? selected.endIndex
        if insertionIndex < maximumCount {
            selected.insert(candidate, at: insertionIndex)
            if selected.count > maximumCount {
                selected.removeLast()
            }
        } else if selected.count < maximumCount {
            selected.append(candidate)
        }
    }
}

extension LibraryArtworkPreviewBuilder {
    /// 资料库入口的封面预览,歌曲模型不在内存里时从曲库目录挑(Q2,6c 单元 4 U3b)。与 `LibraryView.refreshArtworkPreviews`
    /// 里按内存数组挑的那一份同一套挑法、同一份输入,同一个种子挑出同一份:
    /// - 第一趟按库内顺序走可见的歌:挑三首,记下有封面线索的歌所在的专辑、艺人,以及歌单里有线索的成员;
    /// - 专辑、艺人按目录的可见列表取 id(与头像路径),挑三个;`albumArtists` 时艺人是「专辑艺术家」列表(U4b 的
    ///   `albumArtistBrowse`,6c 单元 4 U3c,同内存里的 `browsableArtists(.albumArtists)`;只当过专辑艺人的没有头像路径,同内存);
    ///   给了 `fullReleaseChoices`(「不列只有单曲、EP 的人」,C1)时是按 RC-b 的名单筛过的那份,同内存里筛过的列表;
    ///   名单答不出时抛错,不拿空名单挑出空头像;
    /// - 第二趟只看备用封面要的那几张专辑、那几个艺人(收藏货架上的与挑中的),各挑三首。
    /// 挑中的歌、专辑、艺人最后按 id / 键物化。歌单、电台是小状态,照内存那一份挑。
    static func catalogSelection(
        catalog: LibraryCatalog,
        albumArtists: Bool = false,
        fullReleaseChoices: FullReleaseAlbumArtistMemo.Choices? = nil,
        randomSeed: String, revision: String, userRevision: String,
        playlists: [Playlist], playlistMemberIDs: [String: [String]], radioStations: [RadioStation],
        albumOverrideIDs: Set<String>, artistOverrideIDs: Set<String>, playlistOverrideIDs: Set<String>,
        pinnedAlbumIDs: Set<String>, pinnedArtistIDs: Set<String>
    ) throws -> LibraryArtworkPreviewSelection {
        func hint(_ row: LibraryArtworkPreviewSongRow) -> Bool {
            hasReference(row.coverArtFileName)
                || (row.sourceID == AppleMusicLibraryIdentity.sourceID && !row.filePath.isEmpty)
        }
        let allPlaylistMemberIDs = playlistMemberIDs.isEmpty ? Set<String>() : Set(playlistMemberIDs.values.joined())
        var albumIDsWithSongArtworkHint = Set<String>()
        var artistIDsWithSongArtworkHint = Set<String>()
        var playlistSongIDsWithArtworkHint = Set<String>()
        var songs = LibraryArtworkPreviewAccumulator<String>(randomSeed: "\(randomSeed)#songs")
        try catalog.forEachArtworkPreviewSong(.visible) { row in
            let hasHint = autoreleasepool { hint(row) }
            songs.offer(id: row.id, item: row.id, hasArtworkHint: hasHint)
            guard hasHint else { return }
            if !allPlaylistMemberIDs.isEmpty, allPlaylistMemberIDs.contains(row.id) {
                playlistSongIDsWithArtworkHint.insert(row.id)
            }
            if let albumID = row.albumID { albumIDsWithSongArtworkHint.insert(albumID) }
            if let artistID = row.artistID { artistIDsWithSongArtworkHint.insert(artistID) }
        }
        let playlistIDsWithMemberArtworkHint = Set(playlistMemberIDs.compactMap { entry in
            entry.value.contains(where: playlistSongIDsWithArtworkHint.contains) ? entry.key : nil
        })

        var albums = LibraryArtworkPreviewAccumulator<Int32>(randomSeed: "\(randomSeed)#albums")
        var albumIDByKey: [Int32: String] = [:]
        let albumKeys = Array(try catalog.albumKeys(visibleOnly: true).keys)
        for start in stride(from: 0, to: albumKeys.count, by: LibraryScale.maxMaterializedRows) {
            let chunk = albumKeys[start..<min(albumKeys.count, start + LibraryScale.maxMaterializedRows)]
            for album in try catalog.albumIDs(keys: chunk) {
                let hasHint = albumOverrideIDs.contains(album.id)
                    || albumIDsWithSongArtworkHint.contains(album.id)
                    || MetadataAssetStore.shared.hasAlbumCover(forAlbumID: album.id)
                albums.offer(id: album.id, item: album.key, hasArtworkHint: hasHint)
                albumIDByKey[album.key] = album.id
            }
        }
        var artists = LibraryArtworkPreviewAccumulator<Int32>(randomSeed: "\(randomSeed)#artists")
        var artistIDByKey: [Int32: String] = [:]
        // 专辑艺术家列表里曲目艺人的键大于 0(艺人表),只当过专辑艺人的是 -(序号 + 1)(列表里整项留着)。
        let keeping = try fullReleaseChoices.map { choices -> Set<String> in
            guard let ids = try FullReleaseAlbumArtistMemo.shared.artistIDs(catalog: catalog, choices: choices) else {
                throw LibraryCatalogReaderError.unavailable
            }
            return ids
        }
        let browse = albumArtists ? try catalog.albumArtistBrowse(keeping: keeping) : nil
        let artistKeys = try browse.map { Array($0.keys) } ?? Array(catalog.artistKeys(visibleOnly: true).keys)
        for start in stride(from: 0, to: artistKeys.count, by: LibraryScale.maxMaterializedRows) {
            let chunk = artistKeys[start..<min(artistKeys.count, start + LibraryScale.maxMaterializedRows)]
            var rows = try catalog.artistIDsAndThumbnails(keys: chunk.filter { $0 > 0 })
            if let browse {
                rows += chunk.filter { $0 < 0 && browse.albumOnly.indices.contains(Int(-$0) - 1) }.map { key -> (key: Int32, id: String, thumbnailPath: String?) in
                    let artist = browse.albumOnly[Int(-key) - 1]
                    return (key: key, id: artist.id, thumbnailPath: artist.thumbnailPath)
                }
            }
            for artist in rows {
                let hasHint = artistOverrideIDs.contains(artist.id)
                    || hasReference(artist.thumbnailPath)
                    || artistIDsWithSongArtworkHint.contains(artist.id)
                    || MetadataAssetStore.shared.hasArtistImage(forArtistID: artist.id)
                artists.offer(id: artist.id, item: artist.key, hasArtworkHint: hasHint)
                artistIDByKey[artist.key] = artist.id
            }
        }
        let selectedPlaylists = select(playlists, randomSeed: "\(randomSeed)#playlists", id: \Playlist.id) { playlist in
            playlistOverrideIDs.contains(playlist.id)
                || (playlist.hasDedicatedCoverArt && hasReference(playlist.coverArtPath))
                || playlistIDsWithMemberArtworkHint.contains(playlist.id)
        }
        let selectedRadioStations = select(radioStations, randomSeed: "\(randomSeed)#radio", id: \RadioStation.id) { station in
            station.logoData.map(ArtworkImageCompatibility.isCompleteImage) == true || hasReference(station.logoFileName)
        }

        let selectedAlbumIDs = albums.items.compactMap { albumIDByKey[$0] }
        let selectedArtistIDs = artists.items.compactMap { artistIDByKey[$0] }
        let fallbackAlbumIDs = pinnedAlbumIDs.union(selectedAlbumIDs)
        let fallbackArtistIDs = pinnedArtistIDs.union(selectedArtistIDs)
        var albumGroups: [String: LibraryArtworkPreviewAccumulator<String>] = [:]
        var artistGroups: [String: LibraryArtworkPreviewAccumulator<String>] = [:]
        if !fallbackAlbumIDs.isEmpty || !fallbackArtistIDs.isEmpty {
            try catalog.forEachArtworkPreviewSong(.visible) { row in
                if let albumID = row.albumID, fallbackAlbumIDs.contains(albumID) {
                    albumGroups[albumID, default: .init(randomSeed: "\(randomSeed)#album#\(albumID)")]
                        .offer(id: row.id, item: row.id, hasArtworkHint: hint(row))
                }
                if let artistID = row.artistID, fallbackArtistIDs.contains(artistID) {
                    artistGroups[artistID, default: .init(randomSeed: "\(randomSeed)#artist#\(artistID)")]
                        .offer(id: row.id, item: row.id, hasArtworkHint: hint(row))
                }
            }
        }

        // 挑中的按 id / 键物化(一次至多几十首、各三个)。
        let pickedSongIDs = songs.items + albumGroups.values.flatMap(\.items) + artistGroups.values.flatMap(\.items)
        var songsByID: [String: Song] = [:]
        let uniqueIDs = Array(Set(pickedSongIDs))
        for start in stride(from: 0, to: uniqueIDs.count, by: LibraryScale.maxMaterializedRows) {
            let chunk = Array(uniqueIDs[start..<min(uniqueIDs.count, start + LibraryScale.maxMaterializedRows)])
            for song in try catalog.songs(ids: chunk, scope: .visible) { songsByID[song.id] = song }
        }
        return LibraryArtworkPreviewSelection(
            revision: revision,
            userRevision: userRevision,
            songs: songs.items.compactMap { songsByID[$0] },
            albums: try catalog.albums(keys: albums.items, visibleCounts: true),
            artists: try browse.map { browse in
                let byKey = try catalog.albumArtists(keys: artists.items, in: browse)
                return artists.items.compactMap { byKey[$0] }
            } ?? catalog.artists(keys: artists.items, visibleCounts: true),
            playlists: selectedPlaylists,
            radioStations: selectedRadioStations,
            albumFallbackSongs: albumGroups.mapValues { $0.items.compactMap { songsByID[$0] } },
            artistFallbackSongs: artistGroups.mapValues { $0.items.compactMap { songsByID[$0] } }
        )
    }
}

extension LibraryArtworkPreviewBuilder {
    /// 资料库入口的封面预览,按内存里的整库数组挑(歌曲模型在内存里时;与以前在 `LibraryView` 里的那一段相同)。
    static func memorySelection(
        songs: [Song], albums: [Album], artists: [Artist],
        randomSeed: String, revision: String, userRevision: String,
        playlists: [Playlist], playlistMemberIDs: [String: [String]], radioStations: [RadioStation],
        albumOverrideIDs: Set<String>, artistOverrideIDs: Set<String>, playlistOverrideIDs: Set<String>,
        pinnedAlbumIDs: Set<String>, pinnedArtistIDs: Set<String>
    ) -> LibraryArtworkPreviewSelection {
        // 只要几组 id, 不复制一份整库歌曲数组。
        let allPlaylistMemberIDs = playlistMemberIDs.isEmpty
            ? Set<String>()
            : Set(playlistMemberIDs.values.joined())
        var albumIDsWithSongArtworkHint = Set<String>()
        var artistIDsWithSongArtworkHint = Set<String>()
        var playlistSongIDsWithArtworkHint = Set<String>()
        for song in songs where LibraryArtworkPreviewBuilder.songHasArtworkHint(song) {
            if !allPlaylistMemberIDs.isEmpty, allPlaylistMemberIDs.contains(song.id) {
                playlistSongIDsWithArtworkHint.insert(song.id)
            }
            if let albumID = song.albumID { albumIDsWithSongArtworkHint.insert(albumID) }
            if let artistID = song.artistID { artistIDsWithSongArtworkHint.insert(artistID) }
        }
        let playlistIDsWithMemberArtworkHint = Set(playlistMemberIDs.compactMap { entry in
            entry.value.contains(where: playlistSongIDsWithArtworkHint.contains) ? entry.key : nil
        })

        let selectedSongs = LibraryArtworkPreviewBuilder.select(
            songs,
            randomSeed: "\(randomSeed)#songs",
            id: \Song.id,
            hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
        )
        let selectedAlbums = LibraryArtworkPreviewBuilder.select(
            albums,
            randomSeed: "\(randomSeed)#albums",
            id: \Album.id
        ) { album in
            albumOverrideIDs.contains(album.id)
                || albumIDsWithSongArtworkHint.contains(album.id)
                || MetadataAssetStore.shared.hasAlbumCover(forAlbumID: album.id)
        }
        let selectedArtists = LibraryArtworkPreviewBuilder.select(
            artists,
            randomSeed: "\(randomSeed)#artists",
            id: \Artist.id
        ) { artist in
            artistOverrideIDs.contains(artist.id)
                || LibraryArtworkPreviewBuilder.hasReference(artist.thumbnailPath)
                || artistIDsWithSongArtworkHint.contains(artist.id)
                || MetadataAssetStore.shared.hasArtistImage(forArtistID: artist.id)
        }
        let selectedPlaylists = LibraryArtworkPreviewBuilder.select(
            playlists,
            randomSeed: "\(randomSeed)#playlists",
            id: \Playlist.id
        ) { playlist in
            playlistOverrideIDs.contains(playlist.id)
                || (
                    playlist.hasDedicatedCoverArt
                        && LibraryArtworkPreviewBuilder.hasReference(playlist.coverArtPath)
                )
                || playlistIDsWithMemberArtworkHint.contains(playlist.id)
        }
        let selectedRadioStations = LibraryArtworkPreviewBuilder.select(
            radioStations,
            randomSeed: "\(randomSeed)#radio",
            id: \RadioStation.id
        ) { station in
            station.logoData.map(ArtworkImageCompatibility.isCompleteImage) == true
                || LibraryArtworkPreviewBuilder.hasReference(station.logoFileName)
        }

        let fallbackAlbumIDs = pinnedAlbumIDs.union(selectedAlbums.map(\.id))
        let albumGroups = Dictionary(grouping: songs.filter { song in
            song.albumID.map(fallbackAlbumIDs.contains) == true
        }) { $0.albumID ?? "" }
        let albumFallbackSongs = albumGroups.mapValues { albumSongs in
            LibraryArtworkPreviewBuilder.select(
                albumSongs,
                randomSeed: "\(randomSeed)#album#\(albumSongs.first?.albumID ?? "")",
                id: \Song.id,
                hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
            )
        }

        let fallbackArtistIDs = pinnedArtistIDs.union(selectedArtists.map(\.id))
        let artistGroups = Dictionary(grouping: songs.filter { song in
            song.artistID.map(fallbackArtistIDs.contains) == true
        }) { $0.artistID ?? "" }
        let artistFallbackSongs = artistGroups.mapValues { artistSongs in
            LibraryArtworkPreviewBuilder.select(
                artistSongs,
                randomSeed: "\(randomSeed)#artist#\(artistSongs.first?.artistID ?? "")",
                id: \Song.id,
                hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
            )
        }

        return LibraryArtworkPreviewSelection(
            revision: revision,
            userRevision: userRevision,
            songs: selectedSongs,
            albums: selectedAlbums,
            artists: selectedArtists,
            playlists: selectedPlaylists,
            radioStations: selectedRadioStations,
            albumFallbackSongs: albumFallbackSongs,
            artistFallbackSongs: artistFallbackSongs
        )
    }
}
