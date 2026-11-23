import Foundation
import GRDB

/// `library-catalog.sqlite` 的表结构。歌曲行的列即真相,不存整首 JSON;
/// 派生列由写入方(`LibraryCatalogWriter`)算好。
///
/// 体积纪律(PLAN §5,每首 ≤ 900 字节):
/// - 分组表一律用整数引用(`artistRef`、`album.key`、`genreName.ref`),不重复存 32 位十六进制 id;
/// - 路径、专辑标题只索引 47 位哈希(`pathHash`、`titleHash`),查到后再比原文;
/// - 目录查询走文件夹树(`folder` + `song.folderKey`),不索引整条路径;
/// - 库内顺序就是行号顺序(导入按 (orderKey, id) 写、新行追加到尾),索引不再带 orderKey。
enum LibraryCatalogSchema {
    /// 目录还没随版本发布,v1 的布局原地替换。
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
                id TEXT NOT NULL,
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
                sectionBucket INTEGER NOT NULL,
                durationKey REAL NOT NULL,
                discKey INTEGER NOT NULL,
                trackKey INTEGER NOT NULL,
                kind INTEGER NOT NULL DEFAULT 0,
                flags INTEGER NOT NULL,
                matchKey TEXT NOT NULL,
                pathHash INTEGER NOT NULL,
                titleHash INTEGER,
                inferenceDirectory TEXT,
                folderKey INTEGER,
                effectiveAlbumRef INTEGER
            );

            CREATE TABLE fileParent (
                sourceKey INTEGER NOT NULL,
                filePath TEXT NOT NULL,
                parent TEXT NOT NULL,
                PRIMARY KEY (sourceKey, filePath)
            ) WITHOUT ROWID;

            CREATE TABLE artistRef (
                ref INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE
            );

            CREATE TABLE album (
                key INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                titleKey BLOB NOT NULL,
                artistRef INTEGER NOT NULL,
                artistID TEXT NOT NULL,
                artistName TEXT NOT NULL,
                artistKey BLOB NOT NULL,
                year INTEGER,
                genre TEXT,
                sourceID TEXT,
                firstRowid INTEGER NOT NULL DEFAULT 0,
                songCount INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                ownerCredited INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX album_title ON album(title COLLATE \(localizedCollation), firstRowid);
            CREATE INDEX album_owner ON album(artistRef) WHERE ownerCredited = 1;

            CREATE TABLE albumSourceStat (
                albumKey INTEGER NOT NULL,
                sourceKey INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                songCount INTEGER NOT NULL,
                duration REAL NOT NULL,
                maxDateAdded REAL,
                PRIMARY KEY (albumKey, sourceKey, kind)
            ) WITHOUT ROWID;

            CREATE TABLE albumArtistCredit (
                albumKey INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                artistRef INTEGER NOT NULL,
                name TEXT,
                PRIMARY KEY (albumKey, ordinal)
            ) WITHOUT ROWID;
            CREATE INDEX albumArtistCredit_artist ON albumArtistCredit(artistRef);

            CREATE TABLE artist (
                key INTEGER PRIMARY KEY,
                id TEXT NOT NULL,
                name TEXT NOT NULL,
                nameKey BLOB NOT NULL,
                firstRowid INTEGER NOT NULL,
                firstOrdinal INTEGER NOT NULL,
                songCount INTEGER NOT NULL,
                albumCount INTEGER NOT NULL,
                thumbnailPath TEXT
            );
            CREATE INDEX artist_name ON artist(name COLLATE \(localizedCollation), firstRowid, firstOrdinal);

            CREATE TABLE songArtist (
                songRowid INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                artistRef INTEGER NOT NULL,
                artwork INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (songRowid, ordinal)
            ) WITHOUT ROWID;

            CREATE TABLE songArtistLookup (
                songRowid INTEGER NOT NULL,
                artistRef INTEGER NOT NULL,
                PRIMARY KEY (songRowid, artistRef)
            ) WITHOUT ROWID;

            CREATE TABLE artistSourceStat (
                artistRef INTEGER NOT NULL,
                sourceKey INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                songCount INTEGER NOT NULL,
                PRIMARY KEY (artistRef, sourceKey, kind)
            ) WITHOUT ROWID;

            CREATE TABLE genreName (
                ref INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                genreID TEXT NOT NULL,
                UNIQUE (name, genreID)
            );
            CREATE INDEX genreName_genre ON genreName(genreID);

            CREATE TABLE songGenre (
                songRowid INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                genreRef INTEGER NOT NULL,
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
            CREATE INDEX folder_withSongs ON folder(sourceKey) WHERE songCount > 0;

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

    /// 歌曲表的二级索引:id(唯一)、按源、路径哈希、所在文件夹、扫描索引给的父文件夹、身份匹配键。
    /// id 的唯一性也放在这里(不写进表定义),导入时才能先拆掉、导完排序一次建好。
    static let secondaryIndexes: [(name: String, sql: String)] = [
        ("song_id", "CREATE UNIQUE INDEX IF NOT EXISTS song_id ON song(id)"),
        ("song_source", "CREATE INDEX IF NOT EXISTS song_source ON song(sourceKey)"),
        ("song_path", "CREATE INDEX IF NOT EXISTS song_path ON song(pathHash)"),
        ("song_folder", "CREATE INDEX IF NOT EXISTS song_folder ON song(folderKey)"),
        ("song_parentDirectory", """
            CREATE INDEX IF NOT EXISTS song_parentDirectory ON song(sourceKey, inferenceDirectory)
            WHERE inferenceDirectory IS NOT NULL
            """),
        ("song_match", "CREATE INDEX IF NOT EXISTS song_match ON song(matchKey)"),
    ]

    /// 分组派生表的索引:导入时逐行写分组表,这些也延后到导完一次建。
    static let linkIndexes: [(name: String, sql: String)] = [
        ("songArtist_artist", "CREATE INDEX IF NOT EXISTS songArtist_artist ON songArtist(artistRef)"),
        ("songArtist_artwork", "CREATE INDEX IF NOT EXISTS songArtist_artwork ON songArtist(artistRef) WHERE artwork = 1"),
        ("songArtistLookup_artist", "CREATE INDEX IF NOT EXISTS songArtistLookup_artist ON songArtistLookup(artistRef)"),
        ("songGenre_genre", "CREATE INDEX IF NOT EXISTS songGenre_genre ON songGenre(genreRef)"),
        ("songBook_book", "CREATE INDEX IF NOT EXISTS songBook_book ON songBook(bookID) WHERE bookID IS NOT NULL"),
        ("songBook_folder", "CREATE INDEX IF NOT EXISTS songBook_folder ON songBook(kind, folderLink) WHERE folderLink IS NOT NULL"),
        ("songBook_album", "CREATE INDEX IF NOT EXISTS songBook_album ON songBook(kind, albumLink) WHERE albumLink IS NOT NULL"),
        ("song_title", "CREATE INDEX IF NOT EXISTS song_title ON song(titleHash) WHERE titleHash IS NOT NULL"),
    ]

    /// 专辑归属的索引:整库重建时最后一步统一回写 `effectiveAlbumRef`,写前拆掉、写完再建。
    static let albumIndex = (
        name: "song_album",
        sql: "CREATE INDEX IF NOT EXISTS song_album ON song(effectiveAlbumRef) WHERE effectiveAlbumRef IS NOT NULL"
    )

    static var groupingIndexes: [(name: String, sql: String)] { linkIndexes + [albumIndex] }

    /// 歌曲列表排序用的覆盖索引:标题、艺人、专辑、加入时间、文件名。键全相等的行按行号排
    /// (行号显式写进索引,排在覆盖列之前),降序就是倒着扫同一条索引。其余排序走 ORDER BY 加结果缓存。
    /// 专辑排序的两个文本键直接索引表达式(`coalesce(albumTitle, '')`),不再单独存一份。
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
                kind, \(albumSortExpression) COLLATE \(localizedCollation),
                \(albumIDSortExpression) COLLATE \(DatabaseCollation.unicodeCompare.name), discKey, trackKey,
                title COLLATE \(localizedStandardCollation), rowid, sourceKey, sectionBucket)
            """),
        ("song_sort_dateAdded", "CREATE INDEX IF NOT EXISTS song_sort_dateAdded ON song(kind, dateAdded, rowid, sourceKey)"),
        ("song_sort_fileName", """
            CREATE INDEX IF NOT EXISTS song_sort_fileName ON song(
                kind, fileNameKey COLLATE \(localizedStandardCollation), rowid, sourceKey)
            """),
    ]

    /// 比较器把 nil 当 "":与列里存的文本(NUL 已换成 U+FFFD)按同一口径比。索引与查询必须写成同一个表达式。
    static let albumSortExpression = "coalesce(albumTitle, '')"
    static let albumIDSortExpression = "coalesce(albumID, '')"

    /// 批量导入时先拆掉、导完一次建好(建索引走排序器,比逐行维护快得多)。都用
    /// IF NOT EXISTS,幂等。
    static var deferredIndexes: [(name: String, sql: String)] { secondaryIndexes + groupingIndexes + sortIndexes }

    /// 迁移时不建、迁移完后由 `LibraryCatalog.buildPendingSortIndexes` 在后台补的排序索引:头一列就是
    /// 本地化比较的文本,建一条要回调比较上百万次(10 万首每条约 0.7–0.9 s,50 万首约 4 s),没有不改
    /// 排序结果又更快的建法。标题那条前面有读音键,多数比较按字节就分出先后,留在迁移里建。
    /// 没建好之前这几种排序照样走同一句 ORDER BY,只是要整表排序(结果按修订号缓存)。
    static let backgroundSortIndexNames: Set<String> = ["song_sort_artist", "song_sort_album", "song_sort_fileName"]

    static var backgroundSortIndexes: [(name: String, sql: String)] {
        sortIndexes.filter { backgroundSortIndexNames.contains($0.name) }
    }

    /// 迁移(导入旧库)结束时一起建的延后索引:除了留到后台的那几条排序索引。
    static var migrationIndexes: [(name: String, sql: String)] {
        deferredIndexes.filter { !backgroundSortIndexNames.contains($0.name) }
    }

    static func createDeferredIndexes(_ db: Database, includingBackgroundSortIndexes: Bool = true) throws {
        for index in includingBackgroundSortIndexes ? deferredIndexes : migrationIndexes {
            try db.execute(sql: index.sql)
        }
    }

    static func dropDeferredIndexes(_ db: Database) throws {
        for index in deferredIndexes {
            try db.execute(sql: "DROP INDEX IF EXISTS \(index.name)")
        }
    }

    /// 批量写入期间写连接的页缓存(KiB);写完恢复 `LibraryScale.connectionCacheKiB`。
    static let bulkLoadCacheKiB = 8_192
    /// 建索引、整表排序时排序器可用的辅助线程(`PRAGMA threads`)。
    static let sorterThreads = 3
}
