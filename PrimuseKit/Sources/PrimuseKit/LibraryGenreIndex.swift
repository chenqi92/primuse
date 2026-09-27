import Foundation

public struct LibraryGenre: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let songCount: Int
    public let albumCount: Int
    public let representativeSongIDs: [String]

    public init(
        id: String,
        name: String,
        songCount: Int,
        albumCount: Int,
        representativeSongIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.albumCount = albumCount
        self.representativeSongIDs = representativeSongIDs
    }
}

public struct LibraryGenreIndex: Sendable {
    public let genres: [LibraryGenre]
    public let songIDsByGenreID: [String: [String]]
    public let albumIDsByGenreID: [String: [String]]

    public init(
        genres: [LibraryGenre],
        songIDsByGenreID: [String: [String]],
        albumIDsByGenreID: [String: [String]]
    ) {
        self.genres = genres
        self.songIDsByGenreID = songIDsByGenreID
        self.albumIDsByGenreID = albumIDsByGenreID
    }
}

public enum LibraryGenreIndexBuilder {
    private struct Group {
        var displayName: String
        var songs: [Song] = []
        var albumIDs: [String] = []
        var seenAlbumIDs: Set<String> = []

        mutating func append(_ song: Song) {
            songs.append(song)
            if let albumID = song.albumID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !albumID.isEmpty,
               seenAlbumIDs.insert(albumID).inserted {
                albumIDs.append(albumID)
            }
        }
    }

    public static func build(from songs: [Song]) -> LibraryGenreIndex {
        var groups: [String: Group] = [:]
        // 整库只有几十种流派写法, 折叠要带区域设置, 按原始字符串各算一次。
        var resolvedByGenre: [String: (displayName: String, id: String)?] = [:]

        for song in songs {
            guard let genre = song.genre else { continue }
            let lookup: (displayName: String, id: String)?
            if let memoized = resolvedByGenre[genre] {
                lookup = memoized
            } else {
                lookup = displayName(for: genre).map { ($0, normalizedID(for: $0)) }
                resolvedByGenre[genre] = .some(lookup)
            }
            guard let resolved = lookup, !resolved.id.isEmpty else { continue }
            let genreID = resolved.id

            // Keep each group's buffers uniquely owned while appending;
            // copying it out of the dictionary copies a growing array per song.
            groups[genreID, default: Group(displayName: resolved.displayName)].append(song)
        }

        let orderedIDs = groups.keys.sorted()
        let genres = orderedIDs.compactMap { genreID -> LibraryGenre? in
            guard let group = groups[genreID] else { return nil }
            return LibraryGenre(
                id: genreID,
                name: group.displayName,
                songCount: group.songs.count,
                albumCount: group.albumIDs.count,
                representativeSongIDs: representativeSongIDs(from: group.songs)
            )
        }

        return LibraryGenreIndex(
            genres: genres,
            songIDsByGenreID: groups.mapValues { $0.songs.map(\.id) },
            albumIDsByGenreID: groups.mapValues(\.albumIDs)
        )
    }

    public static func normalizedID(for value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func displayName(for value: String?) -> String? {
        guard let value else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// 排名: 有封面在前, 年份新的在前, 再按 id。
    private static func ranksBefore(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsHasArtwork = lhs.coverArtFileName?.isEmpty == false
        let rhsHasArtwork = rhs.coverArtFileName?.isEmpty == false
        if lhsHasArtwork != rhsHasArtwork { return lhsHasArtwork }

        let lhsYear = lhs.year ?? Int.min
        let rhsYear = rhs.year ?? Int.min
        if lhsYear != rhsYear { return lhsYear > rhsYear }
        return lhs.id < rhs.id
    }

    /// 按排名先取 3 张不同专辑各自最靠前的一首, 不够 3 首再按排名补。
    /// 只需线性扫描: 按排名走到的每张专辑第一首就是它排名最高的歌, 所以
    /// 「先各专辑取最高, 再取前三张」与「整组排序后顺着挑」结果相同, 而
    /// 大流派动辄上万首, 整组排序是启动时最贵的一步。
    private static func representativeSongIDs(from songs: [Song]) -> [String] {
        var bestByAlbumID: [String: Song] = [:]
        for song in songs {
            guard let albumID = song.albumID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !albumID.isEmpty else { continue }
            if let current = bestByAlbumID[albumID], !ranksBefore(song, current) { continue }
            bestByAlbumID[albumID] = song
        }
        var selected = topRanked(3, from: bestByAlbumID.values)
        if selected.count < 3 {
            // 补位时同一个 id 只收一次, 且按排名走到的是它排名最高的那首。
            let selectedIDs = Set(selected.map(\.id))
            var bestByID: [String: Song] = [:]
            for song in songs where !selectedIDs.contains(song.id) {
                if let current = bestByID[song.id], !ranksBefore(song, current) { continue }
                bestByID[song.id] = song
            }
            selected.append(contentsOf: topRanked(3 - selected.count, from: bestByID.values))
        }
        return selected.map(\.id)
    }

    /// 排名最前的 `limit` 首(最多 3 首), 按排名顺序, 线性插入。
    private static func topRanked<S: Sequence>(_ limit: Int, from songs: S) -> [Song] where S.Element == Song {
        guard limit > 0 else { return [] }
        var top: [Song] = []
        top.reserveCapacity(limit + 1)
        for song in songs {
            guard top.count < limit || ranksBefore(song, top[top.count - 1]) else { continue }
            let position = top.firstIndex { ranksBefore(song, $0) } ?? top.count
            top.insert(song, at: position)
            if top.count > limit { top.removeLast() }
        }
        return top
    }
}
