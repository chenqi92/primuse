import Foundation
import PrimuseKit
import CryptoKit

/// Global in-memory music library shared across the app
@MainActor
@Observable
final class MusicLibrary {
    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var playlists: [Playlist] = []

    private let snapshotURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var songCount: Int { songs.count }
    var albumCount: Int { albums.count }
    var artistCount: Int { artists.count }

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        snapshotURL = directory.appendingPathComponent("library-cache.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadSnapshot()
    }

    /// Add songs from a scan result and rebuild albums/artists
    func addSongs(_ newSongs: [Song]) {
        // Merge: replace songs from same source, keep others
        let sourceIDs = Set(newSongs.map(\.sourceID))
        songs.removeAll { sourceIDs.contains($0.sourceID) }
        songs.append(contentsOf: newSongs)

        rebuildIndex()
        persistSnapshot()
    }

    /// Remove all songs for a given source
    func removeSongsForSource(_ sourceID: String) {
        songs.removeAll { $0.sourceID == sourceID }
        rebuildIndex()
        persistSnapshot()
    }

    /// Search songs by query
    func search(query: String) -> [Song] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return songs.filter {
            $0.title.lowercased().contains(q)
            || ($0.artistName?.lowercased().contains(q) ?? false)
            || ($0.albumTitle?.lowercased().contains(q) ?? false)
        }
    }

    func songs(forAlbum albumID: String) -> [Song] {
        songs.filter { $0.albumID == albumID }
            .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }

    func songs(forArtist artistID: String) -> [Song] {
        songs.filter { $0.artistID == artistID }
    }

    // MARK: - Index Rebuild

    private func rebuildIndex() {
        // Build albums
        let albumGroups = Dictionary(grouping: songs) { song -> String in
            let artist = song.artistName ?? "Unknown"
            let album = song.albumTitle ?? "Unknown"
            return "\(artist)|\(album)"
        }

        albums = albumGroups.map { key, songs in
            let parts = key.split(separator: "|", maxSplits: 1)
            let artistName = parts.count > 0 ? String(parts[0]) : nil
            let albumTitle = parts.count > 1 ? String(parts[1]) : "Unknown"
            let id = hashID("\(artistName ?? ""):\(albumTitle)")

            return Album(
                id: id,
                title: albumTitle,
                artistName: artistName,
                year: songs.first?.year,
                genre: songs.first?.genre,
                songCount: songs.count,
                totalDuration: songs.reduce(0) { $0 + $1.duration },
                sourceID: songs.first?.sourceID
            )
        }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }

        // Update albumID on songs
        for i in songs.indices {
            let artist = songs[i].artistName ?? "Unknown"
            let album = songs[i].albumTitle ?? "Unknown"
            songs[i].albumID = hashID("\(artist):\(album)")
        }

        // Build artists
        let artistGroups = Dictionary(grouping: songs) { $0.artistName ?? "Unknown" }

        artists = artistGroups.map { name, songs in
            let id = hashID(name.lowercased())
            let albumCount = Set(songs.compactMap(\.albumTitle)).count
            return Artist(
                id: id,
                name: name,
                albumCount: albumCount,
                songCount: songs.count
            )
        }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        // Update artistID on songs
        for i in songs.indices {
            let name = songs[i].artistName ?? "Unknown"
            songs[i].artistID = hashID(name.lowercased())
        }
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            return
        }

        songs = snapshot.songs
        playlists = snapshot.playlists
        rebuildIndex()
    }

    private func persistSnapshot() {
        let snapshot = Snapshot(songs: songs, playlists: playlists)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private func hashID(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private struct Snapshot: Codable {
        var songs: [Song]
        var playlists: [Playlist]
    }
}
