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
    }

    public static func build(from songs: [Song]) -> LibraryGenreIndex {
        var groups: [String: Group] = [:]

        for song in songs {
            guard let displayName = displayName(for: song.genre) else { continue }
            let genreID = normalizedID(for: displayName)
            guard !genreID.isEmpty else { continue }

            var group = groups[genreID] ?? Group(displayName: displayName)
            group.songs.append(song)
            if let albumID = song.albumID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !albumID.isEmpty,
               group.seenAlbumIDs.insert(albumID).inserted {
                group.albumIDs.append(albumID)
            }
            groups[genreID] = group
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

    private static func representativeSongIDs(from songs: [Song]) -> [String] {
        let ranked = songs.sorted { lhs, rhs in
            let lhsHasArtwork = lhs.coverArtFileName?.isEmpty == false
            let rhsHasArtwork = rhs.coverArtFileName?.isEmpty == false
            if lhsHasArtwork != rhsHasArtwork { return lhsHasArtwork }

            let lhsYear = lhs.year ?? Int.min
            let rhsYear = rhs.year ?? Int.min
            if lhsYear != rhsYear { return lhsYear > rhsYear }
            return lhs.id < rhs.id
        }

        var selected: [Song] = []
        var selectedIDs = Set<String>()
        var selectedAlbumIDs = Set<String>()

        for song in ranked {
            guard selected.count < 3 else { break }
            let albumID = song.albumID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let albumID, !albumID.isEmpty,
                  selectedAlbumIDs.insert(albumID).inserted else { continue }
            selected.append(song)
            selectedIDs.insert(song.id)
        }

        if selected.count < 3 {
            for song in ranked where selectedIDs.insert(song.id).inserted {
                selected.append(song)
                if selected.count == 3 { break }
            }
        }
        return selected.map(\.id)
    }
}
