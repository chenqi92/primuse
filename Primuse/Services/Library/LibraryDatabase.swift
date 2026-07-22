import Foundation
import GRDB
import PrimuseKit

actor LibraryDatabase {
    private let dbPool: DatabasePool

    static func create() async throws -> LibraryDatabase {
        let fileManager = FileManager.default
        let appSupport = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
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

        // Persist ReplayGain tags extracted during local scans and
        // cloud/HTTP metadata backfill. Playback can then apply loudness
        // normalization for streaming URLs without re-opening the source
        // as a local file.
        migrator.registerMigration("v4_song_replay_gain") { db in
            try db.alter(table: "songs") { t in
                t.add(column: "replayGainTrackGain", .double)
                t.add(column: "replayGainTrackPeak", .double)
                t.add(column: "replayGainAlbumGain", .double)
                t.add(column: "replayGainAlbumPeak", .double)
            }
        }

        // 给 FTS5 加拼音 + 全文歌词索引, 支持 "zjl" 搜 "周杰伦" / 歌词
        // 命中。拼音列存 song 表方便 re-index, lyricsText 同库存大字段
        // (背靠 Spotlight 经验, GRDB BLOB/TEXT 大字段不会拖 row scan)。
        // backfill 流程: migration 内 pinyin 即刻生成 (in-memory transform
        // 快); lyricsText 留空, 让 MetadataBackfillService 异步读 .lrc
        // 文件填回, 避免 migration 卡在 disk IO。
        migrator.registerMigration("v5_pinyin_lyrics_fts") { db in
            try db.alter(table: "songs") { t in
                t.add(column: "titlePinyin", .text)
                t.add(column: "artistPinyin", .text)
                t.add(column: "albumPinyin", .text)
                t.add(column: "lyricsText", .text)
            }
            // 现有歌曲 backfill pinyin: 一次 SELECT + 批量 UPDATE。
            let rows = try Row.fetchAll(db, sql: "SELECT id, title, artistName, albumTitle FROM songs")
            for row in rows {
                let id: String = row["id"]
                let title: String = row["title"] ?? ""
                let artist: String? = row["artistName"]
                let album: String? = row["albumTitle"]
                try db.execute(
                    sql: "UPDATE songs SET titlePinyin = ?, artistPinyin = ?, albumPinyin = ? WHERE id = ?",
                    arguments: [
                        PinyinTransformer.pinyin(title),
                        artist.flatMap { PinyinTransformer.pinyin($0) },
                        album.flatMap { PinyinTransformer.pinyin($0) },
                        id
                    ]
                )
            }
            // 重建 FTS5 表: drop 旧的, 重新建带新列, 然后 sync。
            try db.execute(sql: "DROP TABLE IF EXISTS songsFts")
            try db.create(virtualTable: "songsFts", using: FTS5()) { t in
                t.synchronize(withTable: "songs")
                t.column("title")
                t.column("artistName")
                t.column("albumTitle")
                t.column("titlePinyin")
                t.column("artistPinyin")
                t.column("albumPinyin")
                t.column("lyricsText")
            }
        }

        // Same-name MV sidecar path discovered during source scans. The value
        // follows coverArtFileName / lyricsFileName semantics: it may be a
        // same-directory filename, a source-relative path, or a connector path.
        migrator.registerMigration("v6_song_mv_path") { db in
            try db.alter(table: "songs") { t in
                t.add(column: "mvPath", .text)
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
            try Self.withPinyinFilled(song).save(db)
        }
    }

    func saveSongs(_ songs: [Song]) throws {
        try dbPool.write { db in
            for song in songs {
                try Self.withPinyinFilled(song).save(db)
            }
        }
    }

    /// 写库前自动补 titlePinyin / artistPinyin / albumPinyin —— 让 scan /
    /// backfill / 手工编辑等所有路径都不用各自记得算拼音。已有值 (nil 之
    /// 外) 保留, 避免覆盖用户自定义。
    private nonisolated static func withPinyinFilled(_ song: Song) -> Song {
        var copy = song
        if copy.titlePinyin == nil {
            copy.titlePinyin = PinyinTransformer.pinyin(copy.title)
        }
        if copy.artistPinyin == nil, let artist = copy.artistName {
            copy.artistPinyin = PinyinTransformer.pinyin(artist)
        }
        if copy.albumPinyin == nil, let album = copy.albumTitle {
            copy.albumPinyin = PinyinTransformer.pinyin(album)
        }
        return copy
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
            // 同时尝试原文 / 拼音 / 拼音首字母三种 token, 用 FTS5 OR 拼起来:
            // "原文"* OR "拼音"* OR "缩写"*。任何一个命中都算结果, ORDER BY rank
            // 让 BM25 自动给最相关的排前面 (原文整词完全匹配通常排第一)。
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let pinyin = PinyinTransformer.pinyin(trimmed)
            let initials = PinyinTransformer.initials(trimmed)
            var terms: [String] = [quoteFTS5(trimmed) + "*"]
            if let pinyin, pinyin != trimmed.lowercased() {
                terms.append(quoteFTS5(pinyin) + "*")
            }
            if let initials, initials != trimmed.lowercased() {
                terms.append(quoteFTS5(initials) + "*")
            }
            let searchTerm = terms.joined(separator: " OR ")
            return try Song.fetchAll(db, sql: """
                SELECT songs.* FROM songs
                JOIN songsFts ON songsFts.rowid = songs.rowid
                WHERE songsFts MATCH ?
                ORDER BY rank
                LIMIT 100
                """, arguments: [searchTerm])
        }
    }

    private nonisolated func quoteFTS5(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
