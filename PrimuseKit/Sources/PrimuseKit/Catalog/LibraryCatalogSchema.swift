import Foundation
import GRDB

/// `library-catalog.sqlite` 的表结构。歌曲行的列即真相,不存整首 JSON;
/// 派生列由写入方(`LibraryCatalogWriter`)算好。
enum LibraryCatalogSchema {
    static let schemaVersion = 1

    /// GRDB 内置的本地化比较(每个连接打开时 GRDB 自动注册)。名字写进索引定义,
    /// 系统语言变了要 `REINDEX` 这两个排序规则。
    static let localizedCollation = DatabaseCollation.localizedCompare.name
    static let localizedStandardCollation = DatabaseCollation.localizedStandardCompare.name

    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("catalog-v1") { db in
            try createV1(db)
        }
    }

    private static func createV1(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE catalogMeta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE source (
                key INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                name TEXT,
                enabled INTEGER NOT NULL DEFAULT 1,
                hasDirectoryAuthority INTEGER NOT NULL DEFAULT 0,
                fileNamesFromIndex INTEGER NOT NULL DEFAULT 0,
                usesFolderParents INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE song (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                orderKey INTEGER NOT NULL,
                sourceKey INTEGER NOT NULL,
                title TEXT NOT NULL,
                artistName TEXT,
                albumTitle TEXT,
                albumArtistName TEXT,
                albumID TEXT,
                artistID TEXT,
                trackNumber INTEGER,
                discNumber INTEGER,
                year INTEGER,
                duration REAL NOT NULL,
                fileFormat TEXT NOT NULL,
                audioCodec TEXT,
                filePath TEXT NOT NULL,
                serverFilePath TEXT,
                fileSize INTEGER NOT NULL,
                bitRate INTEGER,
                sampleRate INTEGER,
                bitDepth INTEGER,
                effectiveBitDepth INTEGER,
                genre TEXT,
                dateAdded REAL NOT NULL,
                serverDateAdded REAL,
                lastModified REAL,
                serverPlayCount INTEGER,
                coverArtFileName TEXT,
                artistArtworkFileName TEXT,
                lyricsFileName TEXT,
                revision TEXT,
                lyricsText TEXT,
                extra BLOB,
                fileNameKey TEXT NOT NULL,
                fileNameOverride TEXT,
                titleKey BLOB NOT NULL,
                albumSortKey TEXT NOT NULL,
                albumIDSortKey TEXT NOT NULL,
                sectionBucket INTEGER NOT NULL,
                durationKey REAL NOT NULL,
                discKey INTEGER NOT NULL,
                trackKey INTEGER NOT NULL,
                kind INTEGER NOT NULL DEFAULT 0,
                flags INTEGER NOT NULL,
                matchKey TEXT NOT NULL,
                albumTitleKey TEXT,
                inferenceDirectory TEXT,
                folderKey INTEGER,
                effectiveAlbumID TEXT,
                effectiveAlbumArtist TEXT
            );

            CREATE TABLE fileParent (
                sourceKey INTEGER NOT NULL,
                filePath TEXT NOT NULL,
                parent TEXT NOT NULL,
                PRIMARY KEY (sourceKey, filePath)
            ) WITHOUT ROWID;

            CREATE TABLE album (
                key INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                titleKey BLOB NOT NULL,
                artistID TEXT NOT NULL,
                artistName TEXT NOT NULL,
                artistKey BLOB NOT NULL,
                year INTEGER,
                genre TEXT,
                sourceID TEXT,
                firstOrderKey INTEGER NOT NULL,
                firstSongID TEXT NOT NULL,
                songCount INTEGER NOT NULL,
                duration REAL NOT NULL
            );
            CREATE INDEX album_title ON album(title COLLATE \(localizedCollation), firstOrderKey);

            CREATE TABLE albumSourceStat (
                albumID TEXT NOT NULL,
                sourceKey INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                songCount INTEGER NOT NULL,
                duration REAL NOT NULL,
                maxDateAdded REAL,
                PRIMARY KEY (albumID, sourceKey, kind)
            ) WITHOUT ROWID;

            CREATE TABLE albumArtistCredit (
                albumID TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                artistID TEXT NOT NULL,
                name TEXT,
                PRIMARY KEY (albumID, ordinal)
            ) WITHOUT ROWID;
            CREATE INDEX albumArtistCredit_artist ON albumArtistCredit(artistID);

            CREATE TABLE artist (
                key INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL,
                nameKey BLOB NOT NULL,
                firstOrderKey INTEGER NOT NULL,
                firstOrdinal INTEGER NOT NULL,
                songCount INTEGER NOT NULL,
                albumCount INTEGER NOT NULL,
                thumbnailPath TEXT
            );
            CREATE INDEX artist_name ON artist(name COLLATE \(localizedCollation), firstOrderKey, firstOrdinal);

            CREATE TABLE songArtist (
                songRowid INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                artistID TEXT NOT NULL,
                PRIMARY KEY (songRowid, ordinal)
            ) WITHOUT ROWID;

            CREATE TABLE songArtistLookup (
                songRowid INTEGER NOT NULL,
                artistID TEXT NOT NULL,
                PRIMARY KEY (songRowid, artistID)
            ) WITHOUT ROWID;

            CREATE TABLE artistSourceStat (
                artistID TEXT NOT NULL,
                sourceKey INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                songCount INTEGER NOT NULL,
                PRIMARY KEY (artistID, sourceKey, kind)
            ) WITHOUT ROWID;

            CREATE TABLE songGenre (
                songRowid INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                genreID TEXT NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (songRowid, ordinal)
            ) WITHOUT ROWID;

            CREATE TABLE folder (
                key INTEGER PRIMARY KEY AUTOINCREMENT,
                sourceKey INTEGER NOT NULL,
                parentKey INTEGER NOT NULL,
                name TEXT NOT NULL,
                oddPath TEXT NOT NULL DEFAULT '',
                songCount INTEGER NOT NULL DEFAULT 0,
                UNIQUE (sourceKey, parentKey, name, oddPath)
            );

            CREATE TABLE songBook (
                songRowid INTEGER PRIMARY KEY,
                kind INTEGER NOT NULL,
                folderLink TEXT,
                albumLink TEXT,
                bookID TEXT,
                displayTitle TEXT
            );
            CREATE TABLE book (
                id TEXT NOT NULL,
                kind INTEGER NOT NULL,
                title TEXT,
                PRIMARY KEY (id, kind)
            ) WITHOUT ROWID;

            CREATE TABLE playlistEntry (
                playlistID TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                songID TEXT NOT NULL,
                songRowid INTEGER,
                PRIMARY KEY (playlistID, ordinal)
            ) WITHOUT ROWID;
            CREATE INDEX playlistEntry_song ON playlistEntry(songID);
            CREATE TABLE likedSong (
                songID TEXT PRIMARY KEY NOT NULL,
                songRowid INTEGER,
                likedAt REAL
            ) WITHOUT ROWID;
            CREATE TABLE dislikedSong (
                songID TEXT PRIMARY KEY NOT NULL,
                songRowid INTEGER,
                dislikedAt REAL
            ) WITHOUT ROWID;
            CREATE TABLE shuffleLink (
                fromSongID TEXT NOT NULL,
                toSongID TEXT NOT NULL,
                PRIMARY KEY (fromSongID, toSongID)
            ) WITHOUT ROWID;
            CREATE TABLE songStat (
                songRowid INTEGER PRIMARY KEY,
                localPlayCount INTEGER NOT NULL DEFAULT 0,
                lastPlayedAt REAL
            );
            CREATE TABLE songOffline (
                songRowid INTEGER PRIMARY KEY,
                state INTEGER NOT NULL,
                bytes INTEGER NOT NULL DEFAULT 0,
                updatedAt REAL
            );
            CREATE TABLE songMaintenance (
                songRowid INTEGER PRIMARY KEY,
                flags INTEGER NOT NULL DEFAULT 0,
                retryCount INTEGER NOT NULL DEFAULT 0,
                lastAttemptAt REAL,
                detail TEXT
            );

            CREATE TABLE catalogChange (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                kind INTEGER NOT NULL,
                songRowid INTEGER NOT NULL,
                songID TEXT NOT NULL
            );
            """)
        try createDeferredIndexes(db)
    }

    /// 歌曲表的二级索引(按源、路径、目录、身份匹配键、库内顺序)。
    static let secondaryIndexes: [(name: String, sql: String)] = [
        ("song_order", "CREATE INDEX IF NOT EXISTS song_order ON song(orderKey)"),
        ("song_sourceOrder", "CREATE INDEX IF NOT EXISTS song_sourceOrder ON song(sourceKey, orderKey)"),
        ("song_sourcePath", "CREATE INDEX IF NOT EXISTS song_sourcePath ON song(sourceKey, filePath)"),
        ("song_match", "CREATE INDEX IF NOT EXISTS song_match ON song(matchKey)"),
    ]

    /// 分组派生表的索引:导入时逐行写分组表,这些也延后到导完一次建。
    static let groupingIndexes: [(name: String, sql: String)] = [
        ("songArtist_artist", "CREATE INDEX IF NOT EXISTS songArtist_artist ON songArtist(artistID, songRowid)"),
        ("songArtistLookup_artist", "CREATE INDEX IF NOT EXISTS songArtistLookup_artist ON songArtistLookup(artistID, songRowid)"),
        ("songGenre_genre", "CREATE INDEX IF NOT EXISTS songGenre_genre ON songGenre(genreID, songRowid)"),
        ("songBook_book", "CREATE INDEX IF NOT EXISTS songBook_book ON songBook(bookID) WHERE bookID IS NOT NULL"),
        ("songBook_folder", "CREATE INDEX IF NOT EXISTS songBook_folder ON songBook(kind, folderLink) WHERE folderLink IS NOT NULL"),
        ("songBook_album", "CREATE INDEX IF NOT EXISTS songBook_album ON songBook(kind, albumLink) WHERE albumLink IS NOT NULL"),
        ("song_effectiveAlbum", "CREATE INDEX IF NOT EXISTS song_effectiveAlbum ON song(effectiveAlbumID, orderKey) WHERE effectiveAlbumID IS NOT NULL"),
        ("song_albumTitle", "CREATE INDEX IF NOT EXISTS song_albumTitle ON song(albumTitleKey, orderKey) WHERE albumTitleKey IS NOT NULL"),
        ("song_folder", "CREATE INDEX IF NOT EXISTS song_folder ON song(folderKey) WHERE folderKey IS NOT NULL"),
    ]

    /// 歌曲列表排序用的覆盖索引,只给最常用的四种:标题、艺人、专辑、加入时间。键全相等的行按行号排
    /// (行号显式写进索引,排在覆盖列之前),降序就是倒着扫同一条索引。其余排序走 ORDER BY 加结果缓存。
    static let sortIndexes: [(name: String, sql: String)] = [
        ("song_sort_title", """
            CREATE INDEX IF NOT EXISTS song_sort_title ON song(
                kind, titleKey, title COLLATE \(localizedCollation), rowid, sourceKey, sectionBucket)
            """),
        ("song_sort_artist", """
            CREATE INDEX IF NOT EXISTS song_sort_artist ON song(
                kind, coalesce(artistName, '') COLLATE \(localizedCollation), rowid, sourceKey, sectionBucket)
            """),
        ("song_sort_album", """
            CREATE INDEX IF NOT EXISTS song_sort_album ON song(
                kind, albumSortKey COLLATE \(localizedCollation),
                albumIDSortKey COLLATE \(DatabaseCollation.unicodeCompare.name), discKey, trackKey,
                title COLLATE \(localizedStandardCollation), rowid, sourceKey, sectionBucket)
            """),
        ("song_sort_dateAdded", "CREATE INDEX IF NOT EXISTS song_sort_dateAdded ON song(kind, dateAdded, rowid, sourceKey)"),
    ]

    /// 批量导入时先拆掉、导完一次建好(建索引走排序器,比逐行维护快得多)。都用
    /// IF NOT EXISTS,幂等。
    static var deferredIndexes: [(name: String, sql: String)] { secondaryIndexes + groupingIndexes + sortIndexes }

    static func createDeferredIndexes(_ db: Database) throws {
        for index in deferredIndexes {
            try db.execute(sql: index.sql)
        }
    }

    static func dropDeferredIndexes(_ db: Database) throws {
        for index in deferredIndexes {
            try db.execute(sql: "DROP INDEX IF EXISTS \(index.name)")
        }
    }

    /// 批量写入期间写连接的页缓存(KiB);写完恢复 `LibraryScale.connectionCacheKiB`。
    static let bulkLoadCacheKiB = 32_768
}
