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
    /// Tombstones for songs the user has explicitly removed via the
    /// row's "delete song" action. Persisted so the next scan doesn't
    /// re-add the same path.
    ///
    /// Identity key shape: `"<accountID-or-sourceID>:<filePath>"`.
    /// Using `cloudAccountID` (when available) instead of mount UUID
    /// is critical — re-OAuth of the same Baidu account mints a new
    /// `MusicSource.id`, which would change `song.id` and bypass any
    /// tombstone keyed by that. The CloudAccount id is deterministic
    /// (sha256(provider:uid)) and survives the re-add, so tombstones
    /// stick.
    private(set) var deletedSongIdentities: Set<String> = []

    /// Plug-in to translate a `Song.sourceID` (mount UUID) into its
    /// canonical identity prefix — usually the source's `cloudAccountID`
    /// for OAuth mounts, falling back to the sourceID itself for
    /// local/NAS sources where there's no account concept.
    /// Set by `AppServices` at startup; nil-safe for tests.
    var sourceIdentityResolver: ((_ sourceID: String) -> String?)?

    private func identityKey(for song: Song) -> String {
        let prefix = sourceIdentityResolver?(song.sourceID) ?? song.sourceID
        return "\(prefix):\(song.filePath)"
    }
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
        // Merge semantics:
        //
        // - Drop songs from the affected sources that the new scan didn't
        //   yield (file deleted on the remote).
        // - For songs that already exist AND the incoming entry is "bare"
        //   (cloud Phase A scan: duration=0 && bitRate=nil), keep the
        //   previously-backfilled metadata. Just refresh the fields the
        //   scan is authoritative for: fileSize, lastModified, sidecar
        //   pointers when the scan found new ones.
        // - For everything else (local source rescan, full-metadata scan,
        //   or genuinely new songs), trust the incoming entry.
        //
        // The previous implementation simply wiped every song from the
        // source and re-appended — which silently undid hours of cloud
        // metadata backfill the moment the user tapped "scan" again.
        //
        // Filter out paths the user has explicitly deleted. Identity
        // key is account+path (not mount-UUID+path) — re-OAuth of the
        // same upstream account mints a new mount.id but the path is
        // unchanged, and we want the tombstone to keep working. The
        // user can reverse the tombstone via `restoreDeletedSong`.
        let filteredNewSongs = newSongs.filter { !deletedSongIdentities.contains(identityKey(for: $0)) }
        let incomingIDs = Set(filteredNewSongs.map(\.id))
        let sourceIDs = Set(filteredNewSongs.map(\.sourceID))

        songs.removeAll { sourceIDs.contains($0.sourceID) && !incomingIDs.contains($0.id) }

        var existingIndexByID: [String: Int] = [:]
        existingIndexByID.reserveCapacity(songs.count)
        for (i, s) in songs.enumerated() { existingIndexByID[s.id] = i }

        var contentChanged: [Song] = []

        for newSong in filteredNewSongs {
            if let idx = existingIndexByID[newSong.id] {
                let existing = songs[idx]
                // Detect remote replacement: same path/ID but different
                // bytes. Conservative — only triggers when both sides
                // populate the field. Without this, the merge below
                // would silently keep the OLD artist/album/duration
                // backfilled from the previous file.
                let sizeChanged = newSong.fileSize > 0
                    && existing.fileSize > 0
                    && newSong.fileSize != existing.fileSize
                let mtimeChanged: Bool = {
                    guard let a = newSong.lastModified, let b = existing.lastModified else { return false }
                    return a != b
                }()
                // Provider revision (md5/etag/content_hash) catches
                // overwrites that don't change size and that come from
                // sources without a usable mtime — Baidu/Aliyun/Dropbox.
                let revisionChanged: Bool = {
                    guard let a = newSong.revision, let b = existing.revision else { return false }
                    return a != b
                }()
                if sizeChanged || mtimeChanged || revisionChanged {
                    songs[idx] = newSong
                    contentChanged.append(newSong)
                    continue
                }
                // "Bare incoming" matches `MetadataBackfillService.isBareSong` —
                // a Phase A scan that found no metadata. If the existing
                // entry has any metadata at all, prefer it.
                let incomingIsBare = newSong.duration == 0
                    && newSong.bitRate == nil
                    && newSong.artistID == nil
                    && newSong.albumID == nil
                    && newSong.year == nil
                    && newSong.genre == nil
                let existingHasMetadata = existing.duration > 0
                    || existing.bitRate != nil
                    || existing.artistID != nil
                    || existing.albumID != nil
                    || existing.year != nil
                    || existing.genre != nil
                if incomingIsBare && existingHasMetadata {
                    var merged = existing
                    merged.fileSize = newSong.fileSize
                    merged.lastModified = newSong.lastModified
                    // Always refresh revision — when the connector starts
                    // surfacing a fingerprint that wasn't there before
                    // (e.g. user upgraded to a build that reads md5), we
                    // want existing songs to pick it up so the next scan
                    // can detect overwrites.
                    if newSong.revision != nil { merged.revision = newSong.revision }
                    // Sidecar from a fresh scan (sibling listing) wins over
                    // backfill's embedded-art reference; if the scan didn't
                    // find any, keep what backfill stored.
                    if let cover = newSong.coverArtFileName { merged.coverArtFileName = cover }
                    if let lyrics = newSong.lyricsFileName { merged.lyricsFileName = lyrics }
                    songs[idx] = merged
                } else {
                    songs[idx] = newSong
                }
            } else {
                songs.append(newSong)
                existingIndexByID[newSong.id] = songs.count - 1
            }
        }

        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSnapshot()

        if !contentChanged.isEmpty {
            NotificationCenter.default.post(
                name: .primuseSongContentChanged,
                object: nil,
                userInfo: ["songs": contentChanged]
            )
        }
    }

    /// Delete a single song and rebuild index
    @discardableResult
    func deleteSong(_ song: Song) -> Int {
        songs.removeAll { $0.id == song.id }
        // Tombstone keyed by canonical identity (account+path, not
        // mount-UUID+path) so re-adding the same Baidu account on
        // a fresh source UUID doesn't bypass it.
        deletedSongIdentities.insert(identityKey(for: song))
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        rebuildIndex()
        persistSnapshot()
        return songs.filter { $0.sourceID == song.sourceID }.count
    }

    /// Reverse a previous `deleteSong` so the next scan can re-add the
    /// path. Caller passes the same Song object that was deleted (or
    /// any Song with the same source/path).
    func restoreDeletedSong(_ song: Song) {
        let key = identityKey(for: song)
        guard deletedSongIdentities.contains(key) else { return }
        deletedSongIdentities.remove(key)
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

    /// Look up the current Song by its stable id. Used by row views to
    /// re-read after backfill mutates the library in place — passing the
    /// row a snapshot freezes the spinner forever even after duration is
    /// filled, because SwiftUI doesn't always re-build NavigationDestination
    /// views from their parent's latest state.
    func song(id: String) -> Song? {
        songs.first(where: { $0.id == id })
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
    /// IDs of every song touched in the most recent replace operation.
    /// Single-song `replaceSong` populates this with one element; batch
    /// `replaceSongs` populates the whole batch. Consumers (e.g. the
    /// player) use this to sync currentSong/queue when a backfilled
    /// song happened to NOT be the last one in a batch.
    private(set) var lastReplacedSongIDs: Set<String> = []
    private(set) var songReplacementToken = UUID()

    func replaceSong(_ updatedSong: Song) {
        guard let index = songs.firstIndex(where: { $0.id == updatedSong.id }) else { return }
        songs[index] = updatedSong
        lastReplacedSong = updatedSong
        lastReplacedSongIDs = [updatedSong.id]
        songReplacementToken = UUID()
        rebuildIndex()
        cleanPlaylistEntries()
        cleanPlaybackHistoryEntries()
        refreshPlaylistArtworkReferences()
        persistSnapshot()
    }

    /// Batch counterpart to `replaceSong`. Used by `MetadataBackfillService`
    /// to apply many metadata fills at once — running rebuildIndex /
    /// persistSnapshot once per batch instead of per song keeps the UI
    /// responsive when the backfill worker is at full speed (otherwise
    /// the artists/albums grouping is recomputed dozens of times a second).
    func replaceSongs(_ updatedSongs: [Song]) {
        guard !updatedSongs.isEmpty else { return }
        var idToIndex: [String: Int] = [:]
        idToIndex.reserveCapacity(songs.count)
        for (i, song) in songs.enumerated() { idToIndex[song.id] = i }

        var lastApplied: Song?
        var appliedIDs: Set<String> = []
        var missedIDs: [String] = []
        for updated in updatedSongs {
            guard let index = idToIndex[updated.id] else {
                missedIDs.append(updated.id)
                continue
            }
            songs[index] = updated
            lastApplied = updated
            appliedIDs.insert(updated.id)
        }
        plog("📚 replaceSongs: requested=\(updatedSongs.count) applied=\(appliedIDs.count) missed=\(missedIDs.count) librarySongs=\(songs.count) missedSampleID=\(missedIDs.first ?? "-") sampleLibID=\(songs.first?.id ?? "-")")
        guard let lastApplied else { return }
        lastReplacedSong = lastApplied
        lastReplacedSongIDs = appliedIDs
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
        // Old `deletedSongIDs` field stored mount-UUID-derived song.id
        // tombstones — useless after re-OAuth changes the source UUID.
        // Drop them silently; new identity-based tombstones replace.
        deletedSongIdentities = Set(snapshot.deletedSongIdentities ?? [])
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
            recentPlaybackSongIDs: recentPlaybackSongIDs,
            deletedSongIdentities: Array(deletedSongIdentities)
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
        /// Account-or-source-prefixed identity keys ("<id>:<filePath>").
        /// Persisted via Array because Set isn't Codable-stable across
        /// SDK revs. Optional so old snapshots decode without it.
        var deletedSongIdentities: [String]?
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
    /// Posted from `MusicLibrary.addSongs` when a re-scan finds an existing
    /// path with different size/mtime — i.e. the user replaced the file
    /// remotely. `userInfo["songs"]` is the `[Song]` of fresh bare songs;
    /// listeners (SourceManager, MetadataBackfillService) drop stale audio
    /// caches and clear failed-backfill marks for these IDs.
    static let primuseSongContentChanged = Notification.Name("primuse.songContentChanged")
    /// Posted in addition to `primuseSourcesDidChange` when a source is
    /// soft-deleted locally. CloudKitSyncService listens to this and
    /// enqueues a real `deleteRecord` instead of pushing the soft-delete
    /// flag as a `saveRecord` (the latter caused server-side records to
    /// linger and resurrect on every fetch).
    static let primuseSourceDidSoftDelete = Notification.Name("primuse.sourceDidSoftDelete")
    /// CloudAccount upsert (insert / edit / soft-delete bumping
    /// modifiedAt). Mirror of `primuseSourcesDidChange` for the new
    /// account record type.
    static let primuseCloudAccountsDidChange = Notification.Name("primuse.cloudAccountsDidChange")
    /// CloudAccount soft-delete (push real `deleteRecord` to CloudKit so
    /// the upstream record clears). Mirror of `primuseSourceDidSoftDelete`.
    static let primuseCloudAccountDidSoftDelete = Notification.Name("primuse.cloudAccountDidSoftDelete")
    /// CloudAccount permanent delete (post-30-day prune).
    static let primuseCloudAccountDidDelete = Notification.Name("primuse.cloudAccountDidDelete")
}
