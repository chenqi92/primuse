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
    private var playlistSongIDs: [String: [String]] = [:]
    private var recentPlaybackSongIDs: [String] = []

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

        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSnapshot()
    }

    /// Remove all songs for a given source
    func removeSongsForSource(_ sourceID: String) {
        songs.removeAll { $0.sourceID == sourceID }
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
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

    func playlist(id: String) -> Playlist? {
        playlists.first(where: { $0.id == id })
    }

    func songs(forPlaylist playlistID: String) -> [Song] {
        let songLookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        return (playlistSongIDs[playlistID] ?? []).compactMap { songLookup[$0] }
    }

    func recentlyPlayedSongs(limit: Int = 6) -> [Song] {
        let songLookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        return Array(recentPlaybackSongIDs.prefix(limit).compactMap { songLookup[$0] })
    }

    func contains(songID: String, inPlaylist playlistID: String) -> Bool {
        playlistSongIDs[playlistID]?.contains(songID) == true
    }

    func recordPlayback(of songID: String) {
        guard songs.contains(where: { $0.id == songID }) else { return }

        recentPlaybackSongIDs.removeAll { $0 == songID }
        recentPlaybackSongIDs.insert(songID, at: 0)

        if recentPlaybackSongIDs.count > 100 {
            recentPlaybackSongIDs.removeLast(recentPlaybackSongIDs.count - 100)
        }

        persistSnapshot()
    }

    func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        playlistSongIDs[playlist.id] = []
        sortPlaylists()
        persistSnapshot()
        return playlist
    }

    func deletePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
        playlistSongIDs[id] = nil
        persistSnapshot()
    }

    func add(songID: String, toPlaylist playlistID: String) {
        guard songs.contains(where: { $0.id == songID }),
              let existingIndex = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }

        var entries = playlistSongIDs[playlistID] ?? []
        guard entries.contains(songID) == false else { return }

        entries.append(songID)
        playlistSongIDs[playlistID] = entries

        playlists[existingIndex].updatedAt = Date()
        playlists[existingIndex].coverArtPath = songs.first(where: { $0.id == entries.first })?.coverArtFileName
        sortPlaylists()
        persistSnapshot()
    }

    func remove(songID: String, fromPlaylist playlistID: String) {
        guard let existingIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }

        var entries = playlistSongIDs[playlistID] ?? []
        entries.removeAll { $0 == songID }
        playlistSongIDs[playlistID] = entries

        playlists[existingIndex].updatedAt = Date()
        playlists[existingIndex].coverArtPath = songs.first(where: { $0.id == entries.first })?.coverArtFileName
        sortPlaylists()
        persistSnapshot()
    }

    func replaceSong(_ updatedSong: Song) {
        guard let index = songs.firstIndex(where: { $0.id == updatedSong.id }) else { return }
        songs[index] = updatedSong
        rebuildIndex()
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        refreshPlaylistArtworkReferences()
        persistSnapshot()
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
        playlistSongIDs = snapshot.playlistSongIDs ?? [:]
        recentPlaybackSongIDs = snapshot.recentPlaybackSongIDs ?? []
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
    }

    private func persistSnapshot() {
        let snapshot = Snapshot(
            songs: songs,
            playlists: playlists,
            playlistSongIDs: playlistSongIDs,
            recentPlaybackSongIDs: recentPlaybackSongIDs
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private func sortPlaylists() {
        playlists.sort { $0.updatedAt > $1.updatedAt }
    }

    private func refreshPlaylistArtworkReferences() {
        for index in playlists.indices {
            let firstSongID = playlistSongIDs[playlists[index].id]?.first
            playlists[index].coverArtPath = songs.first(where: { $0.id == firstSongID })?.coverArtFileName
        }
        sortPlaylists()
    }

    private func cleanPlaylistEntries() {
        let validSongIDs = Set(songs.map(\.id))
        for playlistID in playlistSongIDs.keys {
            playlistSongIDs[playlistID] = (playlistSongIDs[playlistID] ?? []).filter { validSongIDs.contains($0) }
        }
    }

    private func cleanPlaybackHistoryEntries() {
        let validSongIDs = Set(songs.map(\.id))
        recentPlaybackSongIDs = recentPlaybackSongIDs.filter { validSongIDs.contains($0) }
    }

    private func hashID(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private struct Snapshot: Codable {
        var songs: [Song]
        var playlists: [Playlist]
        var playlistSongIDs: [String: [String]]?
        var recentPlaybackSongIDs: [String]?
    }
}
