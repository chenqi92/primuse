import Foundation
import GRDB
import PrimuseKit

actor LibraryDatabase {
    private let dbPool: DatabasePool

    static func create() async throws -> LibraryDatabase {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDirectory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)

        let dbPath = dbDirectory.appendingPathComponent("library.sqlite").path
        let config = Configuration()

        let dbPool = try DatabasePool(path: dbPath, configuration: config)
        let database = LibraryDatabase(dbPool: dbPool)
        try await database.migrate()
        return database
    }

    private init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "sources") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("host", .text)
                t.column("port", .integer)
                t.column("sharePath", .text)
                t.column("username", .text)
                t.column("basePath", .text)
                t.column("lastScannedAt", .datetime)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("songCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "artists") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("albumCount", .integer).notNull().defaults(to: 0)
                t.column("songCount", .integer).notNull().defaults(to: 0)
                t.column("thumbnailPath", .text)
            }

            try db.create(table: "albums") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("artistID", .text).references("artists", onDelete: .setNull)
                t.column("artistName", .text)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("coverArtPath", .text)
                t.column("songCount", .integer).notNull().defaults(to: 0)
                t.column("totalDuration", .double).notNull().defaults(to: 0)
                t.column("sourceID", .text).references("sources", onDelete: .cascade)
            }

            try db.create(table: "songs") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("albumID", .text).references("albums", onDelete: .setNull)
                t.column("artistID", .text).references("artists", onDelete: .setNull)
                t.column("albumTitle", .text)
                t.column("artistName", .text)
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("fileFormat", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("sourceID", .text).notNull().references("sources", onDelete: .cascade)
                t.column("fileSize", .integer).notNull().defaults(to: 0)
                t.column("bitRate", .integer)
                t.column("sampleRate", .integer)
                t.column("bitDepth", .integer)
                t.column("genre", .text)
                t.column("year", .integer)
                t.column("lastModified", .datetime)
                t.column("dateAdded", .datetime).notNull()
                t.column("coverArtFileName", .text)
                t.column("lyricsFileName", .text)
            }

            try db.create(table: "playlists") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("coverArtPath", .text)
            }

            try db.create(table: "playlistSongs") { t in
                t.column("playlistID", .text).notNull().references("playlists", onDelete: .cascade)
                t.column("songID", .text).notNull().references("songs", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.primaryKey(["playlistID", "songID"])
            }

            try db.create(table: "eqPresets") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("bands", .text).notNull() // JSON array
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
            }

            // Full-text search index
            try db.create(virtualTable: "songsFts", using: FTS5()) { t in
                t.synchronize(withTable: "songs")
                t.column("title")
                t.column("artistName")
                t.column("albumTitle")
            }
        }

        // Song gained `revision` (provider md5/etag/content_hash) so
        // re-scan can detect same-size, same-mtime overwrites on cloud
        // drives. Without this column, Song's PersistableRecord save
        // would throw — Song lists `revision` but the table didn't.
        migrator.registerMigration("v2_song_revision") { db in
            try db.alter(table: "songs") { t in
                t.add(column: "revision", .text)
            }
        }

        // Stage 2 of the Account/Mount split: introduce CloudAccount as
        // a first-class entity that an OAuth-typed MusicSource (now
        // semantically a "mount") can point at. The unique index on
        // (provider, accountUID) enforces "one row per upstream account"
        // at the DB layer — same protection the deterministic id
        // (sha256(provider:uid)) gives at the model layer, doubled up.
        // sources gains a nullable `cloudAccountID` FK; nil for
        // local/NAS sources whose identity is host+credentials. No FK
        // constraint enforced (cloudAccounts may not exist yet during
        // stage 4 migration); cleanup is logical, handled by SourcesStore.
        migrator.registerMigration("v3_cloud_accounts") { db in
            try db.create(table: "cloudAccounts") { t in
                t.primaryKey("id", .text)
                t.column("provider", .text).notNull()
                t.column("accountUID", .text).notNull()
                t.column("displayName", .text)
                t.column("avatarURL", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }
            try db.create(
                index: "cloudAccounts_provider_uid",
                on: "cloudAccounts",
                columns: ["provider", "accountUID"],
                options: .unique
            )
            try db.alter(table: "sources") { t in
                t.add(column: "cloudAccountID", .text)
            }
        }

        // Run every registered migration, not just v1 — pinning to
        // `upTo: "v1_initial"` would silently skip later versions on
        // upgrade and reintroduce schema drift.
        try migrator.migrate(dbPool)
    }

    // MARK: - Songs

    func allSongs(orderedBy column: String = "title") throws -> [Song] {
        try dbPool.read { db in
            try Song.order(Column(column).asc).fetchAll(db)
        }
    }

    func song(id: String) throws -> Song? {
        try dbPool.read { db in
            try Song.fetchOne(db, key: id)
        }
    }

    func songs(forAlbum albumID: String) throws -> [Song] {
        try dbPool.read { db in
            try Song
                .filter(Column("albumID") == albumID)
                .order(Column("discNumber").asc, Column("trackNumber").asc)
                .fetchAll(db)
        }
    }

    func songs(forArtist artistID: String) throws -> [Song] {
        try dbPool.read { db in
            try Song
                .filter(Column("artistID") == artistID)
                .order(Column("albumTitle").asc, Column("trackNumber").asc)
                .fetchAll(db)
        }
    }

    func songs(forSource sourceID: String) throws -> [Song] {
        try dbPool.read { db in
            try Song.filter(Column("sourceID") == sourceID).fetchAll(db)
        }
    }

    func saveSong(_ song: Song) throws {
        try dbPool.write { db in
            try song.save(db)
        }
    }

    func saveSongs(_ songs: [Song]) throws {
        try dbPool.write { db in
            for song in songs {
                try song.save(db)
            }
        }
    }

    func deleteSong(id: String) throws {
        try dbPool.write { db in
            _ = try Song.filter(Column("id") == id).deleteAll(db)
        }
    }

    func deleteSongs(forSource sourceID: String) throws {
        try dbPool.write { db in
            _ = try Song.filter(Column("sourceID") == sourceID).deleteAll(db)
        }
    }

    // MARK: - Albums

    func allAlbums() throws -> [Album] {
        try dbPool.read { db in
            try Album.order(Column("title").asc).fetchAll(db)
        }
    }

    func album(id: String) throws -> Album? {
        try dbPool.read { db in
            try Album.fetchOne(db, key: id)
        }
    }

    func albums(forArtist artistID: String) throws -> [Album] {
        try dbPool.read { db in
            try Album
                .filter(Column("artistID") == artistID)
                .order(Column("year").desc)
                .fetchAll(db)
        }
    }

    func saveAlbum(_ album: Album) throws {
        try dbPool.write { db in
            try album.save(db)
        }
    }

    // MARK: - Artists

    func allArtists() throws -> [Artist] {
        try dbPool.read { db in
            try Artist.order(Column("name").asc).fetchAll(db)
        }
    }

    func artist(id: String) throws -> Artist? {
        try dbPool.read { db in
            try Artist.fetchOne(db, key: id)
        }
    }

    func saveArtist(_ artist: Artist) throws {
        try dbPool.write { db in
            try artist.save(db)
        }
    }

    // MARK: - Playlists

    func allPlaylists() throws -> [Playlist] {
        try dbPool.read { db in
            try Playlist.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    func savePlaylist(_ playlist: Playlist) throws {
        try dbPool.write { db in
            try playlist.save(db)
        }
    }

    func deletePlaylist(id: String) throws {
        try dbPool.write { db in
            _ = try Playlist.deleteOne(db, key: id)
        }
    }

    func playlistSongs(playlistID: String) throws -> [Song] {
        try dbPool.read { db in
            try Song
                .joining(required: Song.hasOne(
                    PlaylistSong.self,
                    using: ForeignKey(["songID"], to: ["id"])
                ).filter(Column("playlistID") == playlistID))
                .order(sql: "playlistSongs.sortOrder ASC")
                .fetchAll(db)
        }
    }

    func addSongToPlaylist(playlistID: String, songID: String) throws {
        try dbPool.write { db in
            let maxOrder = try Int.fetchOne(db, sql: """
                SELECT MAX(sortOrder) FROM playlistSongs WHERE playlistID = ?
                """, arguments: [playlistID]) ?? -1
            let ps = PlaylistSong(playlistID: playlistID, songID: songID, sortOrder: maxOrder + 1)
            try ps.save(db)
        }
    }

    // MARK: - Sources

    func allSources() throws -> [MusicSource] {
        try dbPool.read { db in
            try MusicSource.order(Column("name").asc).fetchAll(db)
        }
    }

    func saveSource(_ source: MusicSource) throws {
        try dbPool.write { db in
            try source.save(db)
        }
    }

    func deleteSource(id: String) throws {
        try dbPool.write { db in
            _ = try MusicSource.deleteOne(db, key: id)
        }
    }

    // MARK: - EQ Presets

    func allEQPresets() throws -> [EQPreset] {
        try dbPool.read { db in
            try EQPreset.order(Column("name").asc).fetchAll(db)
        }
    }

    func saveEQPreset(_ preset: EQPreset) throws {
        try dbPool.write { db in
            try preset.save(db)
        }
    }

    // MARK: - Search

    func search(query: String) throws -> [Song] {
        try dbPool.read { db in
            // Escape FTS5 special characters: wrap in quotes for literal matching
            let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
            let searchTerm = "\"\(escaped)\"*"
            return try Song.fetchAll(db, sql: """
                SELECT songs.* FROM songs
                JOIN songsFts ON songsFts.rowid = songs.rowid
                WHERE songsFts MATCH ?
                ORDER BY rank
                LIMIT 100
                """, arguments: [searchTerm])
        }
    }

    func searchSongs(query: String) throws -> [Song] {
        try dbPool.read { db in
            let wildcard = "%\(query)%"
            return try Song.fetchAll(db, sql: """
                SELECT * FROM songs
                WHERE title LIKE ? OR artistName LIKE ? OR albumTitle LIKE ?
                ORDER BY title ASC
                LIMIT 100
                """, arguments: [wildcard, wildcard, wildcard])
        }
    }

    // MARK: - Stats

    func songCount() throws -> Int {
        try dbPool.read { db in
            try Song.fetchCount(db)
        }
    }

    func albumCount() throws -> Int {
        try dbPool.read { db in
            try Album.fetchCount(db)
        }
    }

    func artistCount() throws -> Int {
        try dbPool.read { db in
            try Artist.fetchCount(db)
        }
    }
}
