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
    /// Backing storage that includes soft-deleted entries. UI-facing
    /// `playlists` filters this down.
    private(set) var allPlaylists: [Playlist] = []
    /// Live (non-deleted) playlists for normal UI use.
    var playlists: [Playlist] { allPlaylists.filter { !$0.isDeleted } }
    /// Soft-deleted playlists, newest deletion first. Drives the "Recently
    /// Deleted" recovery panel.
    var recentlyDeletedPlaylists: [Playlist] {
        allPlaylists
            .filter { $0.isDeleted }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }
    private var playlistSongIDs: [String: [String]] = [:]
    private var recentPlaybackSongIDs: [String] = []
    private(set) var disabledSourceIDs: Set<String> = []

    /// Cached filtered views — rebuilt only when songs/disabled state change
    private(set) var visibleSongs: [Song] = []
    private(set) var visibleAlbums: [Album] = []
    private(set) var visibleArtists: [Artist] = []

    private let snapshotURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func updateDisabledSourceIDs(_ ids: Set<String>) {
        disabledSourceIDs = ids
        rebuildVisibleCache()
    }

    var songCount: Int { visibleSongs.count }
    var albumCount: Int { visibleAlbums.count }
    var artistCount: Int { visibleArtists.count }

    private func rebuildVisibleCache() {
        if disabledSourceIDs.isEmpty {
            visibleSongs = songs
            visibleAlbums = albums
            visibleArtists = artists
        } else {
            visibleSongs = songs.filter { !disabledSourceIDs.contains($0.sourceID) }
            let visibleAlbumIDs = Set(visibleSongs.compactMap(\.albumID))
            visibleAlbums = albums.filter { visibleAlbumIDs.contains($0.id) }
            let visibleArtistIDs = Set(visibleSongs.compactMap(\.artistID))
            visibleArtists = artists.filter { visibleArtistIDs.contains($0.id) }
        }
    }

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        snapshotURL = directory.appendingPathComponent("library-cache.json")
        encoder.outputFormatting = [.sortedKeys]
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

    /// Delete a single song and rebuild index
    func deleteSong(_ song: Song) {
        songs.removeAll { $0.id == song.id }
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
        return visibleSongs.filter {
            $0.title.lowercased().contains(q)
            || ($0.artistName?.lowercased().contains(q) ?? false)
            || ($0.albumTitle?.lowercased().contains(q) ?? false)
        }
    }

    func songs(forAlbum albumID: String) -> [Song] {
        visibleSongs.filter { $0.albumID == albumID }
            .sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
    }

    func songs(forArtist artistID: String) -> [Song] {
        visibleSongs.filter { $0.artistID == artistID }
    }

    func recentlyAddedAlbums(limit: Int = 10) -> [Album] {
        let albumLatestDate = Dictionary(grouping: visibleSongs) { $0.albumID ?? "" }
            .mapValues { $0.map(\.dateAdded).max() ?? .distantPast }
        return visibleAlbums
            .sorted { (albumLatestDate[$0.id] ?? .distantPast) > (albumLatestDate[$1.id] ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func playlist(id: String) -> Playlist? {
        allPlaylists.first(where: { $0.id == id })
    }

    func songs(forPlaylist playlistID: String) -> [Song] {
        let songLookup = Dictionary(uniqueKeysWithValues: visibleSongs.map { ($0.id, $0) })
        return (playlistSongIDs[playlistID] ?? []).compactMap { songLookup[$0] }
    }

    func recentlyPlayedSongs(limit: Int = 6) -> [Song] {
        let songLookup = Dictionary(uniqueKeysWithValues: visibleSongs.map { ($0.id, $0) })
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
        NotificationCenter.default.post(name: .primusePlaybackHistoryDidChange, object: nil)
    }

    func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        allPlaylists.append(playlist)
        playlistSongIDs[playlist.id] = []
        sortPlaylists()
        persistSnapshot()
        notifyPlaylistsChanged([playlist.id])
        return playlist
    }

    /// Soft-delete: mark `isDeleted = true`, propagated to other devices as
    /// an update so the recycle bin converges.
    func deletePlaylist(id: String) {
        guard let index = allPlaylists.firstIndex(where: { $0.id == id }) else { return }
        allPlaylists[index].isDeleted = true
        allPlaylists[index].deletedAt = Date()
        allPlaylists[index].updatedAt = Date()
        persistSnapshot()
        notifyPlaylistsChanged([id])
    }

    /// Restore a soft-deleted playlist (e.g. from the Recently Deleted view).
    func restorePlaylist(id: String) {
        guard let index = allPlaylists.firstIndex(where: { $0.id == id }) else { return }
        allPlaylists[index].isDeleted = false
        allPlaylists[index].deletedAt = nil
        allPlaylists[index].updatedAt = Date()
        persistSnapshot()
        notifyPlaylistsChanged([id])
    }

    /// Permanently remove a playlist (manual purge or 30-day prune). Drops the
    /// record from CloudKit too.
    func permanentlyDeletePlaylist(id: String) {
        allPlaylists.removeAll { $0.id == id }
        playlistSongIDs[id] = nil
        persistSnapshot()
        notifyPlaylistDeleted(id)
    }

    /// Sweep playlists whose `deletedAt` is older than `threshold` and remove
    /// them for good. Called on launch with a 30-day threshold.
    func prunePlaylists(deletedBefore threshold: Date) {
        let toPrune = allPlaylists.filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < threshold }
        guard !toPrune.isEmpty else { return }
        for playlist in toPrune {
            permanentlyDeletePlaylist(id: playlist.id)
        }
    }

    func add(songID: String, toPlaylist playlistID: String) {
        guard songs.contains(where: { $0.id == songID }),
              let existingIndex = allPlaylists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }

        var entries = playlistSongIDs[playlistID] ?? []
        guard entries.contains(songID) == false else { return }

        entries.append(songID)
        playlistSongIDs[playlistID] = entries

        allPlaylists[existingIndex].updatedAt = Date()
        allPlaylists[existingIndex].coverArtPath = songs.first(where: { $0.id == entries.first })?.coverArtFileName
        sortPlaylists()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
    }

    func remove(songID: String, fromPlaylist playlistID: String) {
        guard let existingIndex = allPlaylists.firstIndex(where: { $0.id == playlistID }) else { return }

        var entries = playlistSongIDs[playlistID] ?? []
        entries.removeAll { $0 == songID }
        playlistSongIDs[playlistID] = entries

        allPlaylists[existingIndex].updatedAt = Date()
        allPlaylists[existingIndex].coverArtPath = songs.first(where: { $0.id == entries.first })?.coverArtFileName
        sortPlaylists()
        persistSnapshot()
        notifyPlaylistsChanged([playlistID])
    }

    // MARK: - Cloud sync hooks

    /// Raw stored song IDs for a playlist (no visibility filtering).
    func rawSongIDs(forPlaylist playlistID: String) -> [String] {
        playlistSongIDs[playlistID] ?? []
    }

    /// Snapshot of recent playback song IDs — used by CloudKit sync.
    var recentPlaybackSongIDsForSync: [String] { recentPlaybackSongIDs }

    /// Wipe playback history (in response to a remote deletion).
    func clearPlaybackHistory() {
        recentPlaybackSongIDs.removeAll()
        persistSnapshot()
    }

    /// Apply a playlist record + its song list pulled from CloudKit. Does not
    /// re-broadcast a local change notification. Song IDs are stored as-is;
    /// `songs(forPlaylist:)` filters down to whatever songs are present locally
    /// at display time, so a freshly-synced device will fill in entries as its
    /// own scan progresses.
    func applyRemotePlaylist(_ playlist: Playlist, songIDs: [String]) {
        if let index = allPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            allPlaylists[index] = playlist
        } else {
            allPlaylists.append(playlist)
        }
        playlistSongIDs[playlist.id] = songIDs
        sortPlaylists()
        persistSnapshot()
    }

    /// Replace the local playback history with one pulled from CloudKit. IDs are
    /// stored as-is; `recentlyPlayedSongs(limit:)` filters down to locally-known
    /// songs at display time.
    func applyRemotePlaybackHistory(songIDs: [String]) {
        recentPlaybackSongIDs = Array(songIDs.prefix(100))
        persistSnapshot()
    }

    /// Remove a playlist in response to a remote deletion event. Does not fire
    /// the local-change notification (which would echo back to CloudKit).
    func deletePlaylistFromRemote(id: String) {
        allPlaylists.removeAll { $0.id == id }
        playlistSongIDs[id] = nil
        persistSnapshot()
    }

    private func notifyPlaylistsChanged(_ ids: [String]) {
        NotificationCenter.default.post(
            name: .primusePlaylistsDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private func notifyPlaylistDeleted(_ id: String) {
        NotificationCenter.default.post(
            name: .primusePlaylistDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Most recently replaced song — observable so consumers (e.g. player) can sync.
    /// Use songReplacementToken for onChange triggers (it changes on every replace, even same song).
    private(set) var lastReplacedSong: Song?
    private(set) var songReplacementToken = UUID()

    func replaceSong(_ updatedSong: Song) {
        guard let index = songs.firstIndex(where: { $0.id == updatedSong.id }) else { return }
        songs[index] = updatedSong
        lastReplacedSong = updatedSong
        songReplacementToken = UUID()
        rebuildIndex()
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        refreshPlaylistArtworkReferences()
        persistSnapshot()
    }

    // MARK: - Index Rebuild

    private func rebuildIndex() {
        // Build albums — only group songs that have an actual album title
        // Songs without album title get no albumID (treated as singles)
        let unknownArtist = String(localized: "unknown_artist")
        let songsWithAlbum = songs.filter { $0.albumTitle != nil && !$0.albumTitle!.isEmpty }
        let albumGroups = Dictionary(grouping: songsWithAlbum) { song -> String in
            let artist = song.artistName ?? unknownArtist
            let album = song.albumTitle!
            return "\(artist)\0\(album)"
        }

        albums = albumGroups.map { key, songs in
            let parts = key.split(separator: "\0", maxSplits: 1)
            let artistName = parts.count > 0 ? String(parts[0]) : unknownArtist
            let albumTitle = parts.count > 1 ? String(parts[1]) : unknownArtist
            let id = hashID("\(artistName):\(albumTitle)")

            let artistID = hashID(artistName.lowercased())
            return Album(
                id: id,
                title: albumTitle,
                artistID: artistID,
                artistName: artistName,
                year: songs.first?.year,
                genre: songs.first?.genre,
                songCount: songs.count,
                totalDuration: songs.reduce(0) { $0 + $1.duration.sanitizedDuration },
                sourceID: songs.first?.sourceID
            )
        }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }

        // Update albumID on songs — nil for songs without album
        for i in songs.indices {
            if let album = songs[i].albumTitle, !album.isEmpty {
                let artist = songs[i].artistName ?? unknownArtist
                songs[i].albumID = hashID("\(artist):\(album)")
            } else {
                songs[i].albumID = nil
            }
        }

        // Build artists
        let artistGroups = Dictionary(grouping: songs) { $0.artistName ?? unknownArtist }

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
            let name = songs[i].artistName ?? unknownArtist
            songs[i].artistID = hashID(name.lowercased())
        }

        rebuildVisibleCache()
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            return
        }

        songs = snapshot.songs
        allPlaylists = snapshot.playlists
        playlistSongIDs = snapshot.playlistSongIDs ?? [:]
        recentPlaybackSongIDs = snapshot.recentPlaybackSongIDs ?? []
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
    }

    private var persistTask: Task<Void, Never>?

    private func persistSnapshot() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    /// Write library snapshot to disk immediately (e.g. on app backgrounding).
    func persistNow() {
        let snapshot = Snapshot(
            songs: songs,
            playlists: allPlaylists,
            playlistSongIDs: playlistSongIDs,
            recentPlaybackSongIDs: recentPlaybackSongIDs
        )
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private func sortPlaylists() {
        allPlaylists.sort { $0.updatedAt > $1.updatedAt }
    }

    private func refreshPlaylistArtworkReferences() {
        for index in allPlaylists.indices {
            let firstSongID = playlistSongIDs[allPlaylists[index].id]?.first
            allPlaylists[index].coverArtPath = songs.first(where: { $0.id == firstSongID })?.coverArtFileName
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

extension Notification.Name {
    static let primusePlaylistsDidChange = Notification.Name("primuse.playlistsDidChange")
    static let primusePlaylistDidDelete = Notification.Name("primuse.playlistDidDelete")
    static let primusePlaybackHistoryDidChange = Notification.Name("primuse.playbackHistoryDidChange")
    static let primuseSourcesDidChange = Notification.Name("primuse.sourcesDidChange")
    static let primuseSourceDidDelete = Notification.Name("primuse.sourceDidDelete")
    static let primuseScraperConfigDidChange = Notification.Name("primuse.scraperConfigDidChange")
    static let primuseScraperConfigDidDelete = Notification.Name("primuse.scraperConfigDidDelete")
}
