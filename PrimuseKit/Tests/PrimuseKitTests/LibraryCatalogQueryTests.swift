import Foundation
import os
import GRDB
import Testing
@testable import PrimuseKit

@Suite("Library catalog queries and import", .serialized)
struct LibraryCatalogQueryTests {
    static func song(_ id: String, source: String, path: String, title: String = "t", duration: Double = 100) -> Song {
        Song(id: id, title: title, duration: duration, fileFormat: .flac, filePath: path, sourceID: source)
    }

    @Test("Source, path and count queries")
    func sourceAndPathQueries() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let songs = [
            Self.song("a1", source: "A", path: "Music/X/01.flac"),
            Self.song("a2", source: "A", path: "Music/X/02.flac"),
            Self.song("a3", source: "A", path: "Music/X/Sub/03.flac"),
            Self.song("a4", source: "A", path: "Music/Y/04.flac"),
            Self.song("a5", source: "A", path: "Music/X0/05.flac"),
            Self.song("cue1", source: "A", path: "Music/X/album.ape"),
            Self.song("cue2", source: "A", path: "Music/X/album.ape"),
            Self.song("b1", source: "B", path: "", duration: 0),
            Self.song("b2", source: "B", path: "Music/X/01.flac"),
        ]
        try catalog.apply(upserts: songs)
        func ids(_ list: LibraryRowList) throws -> [String] { try catalog.songs(rowids: list.rowids).map(\.id) }

        #expect(try catalog.songCount(.everything) == 9)
        #expect(try catalog.songCountsBySource() == ["A": 7, "B": 2])
        #expect(try catalog.songCount(LibrarySongScope(playableOnly: true)) == 8)
        #expect(try ids(catalog.rowList(.source("A"))) == ["a1", "a2", "a3", "a4", "a5", "cue1", "cue2"])
        #expect(try ids(catalog.rowList(sourceID: "A", directory: "Music/X", recursive: false)) == ["a1", "a2", "cue1", "cue2"])
        #expect(try ids(catalog.rowList(sourceID: "A", directory: "Music/X", recursive: true)) == ["a1", "a2", "a3", "cue1", "cue2"])
        #expect(try ids(catalog.rowList(sourceID: "A", filePath: "Music/X/album.ape")) == ["cue1", "cue2"])
        #expect(try catalog.fileStems(sourceID: "A", directory: "Music/X") == ["01", "02", "album"])
        #expect(try catalog.songID(sourceID: "B", filePath: "Music/X/01.flac") == "b2")
        #expect(try catalog.firstSong(.source("B"))?.id == "b1")
        #expect(try catalog.containsSongs(.source("C")) == false)

        try catalog.setSourceEnabled(false, sourceID: "B")
        #expect(try catalog.songCount(.visible) == 7)
        #expect(try catalog.songCount(.everything) == 9)
        #expect(try catalog.songs(ids: ["b1", "a1"], scope: .visible).map(\.id) == ["a1"])
        #expect(try catalog.songs(ids: ["b1", "a1"]).map(\.id) == ["b1", "a1"])

        var streamed: [String] = []
        try catalog.forEachSongIdentity(.source("A")) { _, id, _ in
            streamed.append(id)
            return streamed.count < 3
        }
        #expect(streamed == ["a1", "a2", "a3"])
        var all: [String] = []
        try catalog.forEachSong(.everything) { _, song in
            all.append(song.id)
            return true
        }
        #expect(all == songs.map(\.id))
    }

    @Test("Prefix upper bounds cover exactly the strings that start with the prefix")
    func prefixBounds() {
        #expect(LibraryCatalogPath.upperBound(forPrefix: "a/b/") == "a/b0")
        #expect(LibraryCatalogPath.upperBound(forPrefix: "晴") > "晴天")
        #expect(LibraryCatalogPath.upperBound(forPrefix: "x\u{10FFFF}") == "y")
    }

    @Test("Row cache materializes in batches, keeps order and evicts least recently used")
    func rowCache() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let songs = (0..<20).map { Self.song("s\($0)", source: "A", path: "p/\($0).flac") }
        let summary = try catalog.apply(upserts: songs)
        let rowids = Array(summary.insertedRowids)
        let cache = LibraryRowCache(capacity: 8)
        let firstPage = try cache.songs(forRowids: rowids[0..<8], in: catalog)
        #expect(firstPage.map { $0?.id } == (0..<8).map { "s\($0)" })
        #expect(cache.count == 8)
        _ = try cache.songs(forRowids: [rowids[0]], in: catalog)
        _ = try cache.songs(forRowids: rowids[8..<10], in: catalog)
        #expect(cache.count == 8)
        // s0 刚用过;s1、s2 最久没用,被挤掉。
        let reversed = try cache.songs(forRowids: [rowids[9], rowids[0], rowids[1]], in: catalog)
        #expect(reversed.map { $0?.id } == ["s9", "s0", "s1"])
        let deleted = try catalog.apply(upserts: [], deletingIDs: ["s0"])
        cache.invalidate(deleted)
        #expect(try cache.songs(forRowids: [rowids[0]], in: catalog) == [nil])
    }

    @Test("Row cache answers by song ID from cached rows and forgets an ID when its row changes")
    func rowCacheByID() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let songs = (0..<12).map { Self.song("s\($0)", source: "A", path: "p/\($0).flac", title: "t\($0)") }
        let inserted = try catalog.apply(upserts: songs)
        let rowids = Array(inserted.insertedRowids)
        let cache = LibraryRowCache(capacity: 8)

        // 没缓存的按 id 查一行并记下;目录里没有的不记。
        #expect(try cache.song(id: "s3", in: catalog) == songs[3])
        #expect(try cache.song(id: "missing", in: catalog) == nil)
        #expect(cache.count == 1)
        // 按行号取过的行,按 id 取不再碰目录:目录里悄悄改掉(不发失效)之后读到的还是缓存的那一份。
        _ = try cache.songs(forRowids: rowids[0..<2], in: catalog)
        var edited = songs[0]
        edited.title = "edited"
        let update = try catalog.apply(upserts: [edited])
        #expect(try cache.song(id: "s0", in: catalog)?.title == "t0")
        // 失效之后按 id 读到新的一行。
        cache.invalidate(update)
        #expect(try cache.song(id: "s0", in: catalog)?.title == "edited")

        // 一批:与输入一一对应,重复的、没有的都在自己的位置上。
        let batch = try cache.songs(ids: ["s5", "missing", "s0", "s5"], in: catalog)
        #expect(batch.map { $0?.id } == ["s5", nil, "s0", "s5"])

        // 改名(行号不变):旧 id 读不到了,新 id 读到同一行。
        _ = try cache.song(id: "s7", in: catalog)
        let renamed = try catalog.apply(upserts: [], renaming: ["s7": "s7-moved"])
        cache.invalidate(renamed)
        #expect(try cache.song(id: "s7", in: catalog) == nil)
        #expect(try cache.song(id: "s7-moved", in: catalog)?.title == "t7")
        #expect(try cache.songs(forRowids: [rowids[7]], in: catalog).first??.id == "s7-moved")

        // 删掉再加回来换了行号:按 id 读到新行,旧行号上什么都没有。
        _ = try cache.song(id: "s9", in: catalog)
        cache.invalidate(try catalog.apply(upserts: [], deletingIDs: ["s9"]))
        #expect(try cache.song(id: "s9", in: catalog) == nil)
        var back = songs[9]
        back.title = "back"
        cache.invalidate(try catalog.apply(upserts: [back]))
        #expect(try cache.song(id: "s9", in: catalog)?.title == "back")
        #expect(try cache.songs(forRowids: [rowids[9]], in: catalog) == [nil])

        // 容量用满:被挤掉的行按 id 也不在缓存里了(再读就是查目录),条数不超过容量。
        for index in 0..<12 where index != 7 { _ = try cache.song(id: "s\(index)", in: catalog) }
        #expect(cache.count == 8)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(try cache.song(id: "s1", in: catalog) == songs[1])

        // 比缓存四分之一还大的一批:答案照给,取回的行不放进缓存。
        cache.removeAll()
        let large = try cache.songs(ids: ["s1", "s2", "s3"], in: catalog)
        #expect(large.map { $0?.id } == ["s1", "s2", "s3"])
        #expect(cache.count == 0)
        let small = try cache.songs(ids: ["s1", "s2"], in: catalog)
        #expect(small.map { $0?.id } == ["s1", "s2"])
        #expect(cache.count == 2)
    }

    @Test("A row fetched while the catalog changed is returned but not kept")
    func rowCacheDoesNotKeepARowFetchedAcrossAnInvalidation() async throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let songs = (0..<400).map { Self.song("s\($0)", source: "A", path: "p/\($0).flac", title: "t\($0)") }
        try catalog.apply(upserts: songs)
        let cache = LibraryRowCache(capacity: 64)
        // 一边不停地改同一批行并发失效,一边按 id 读:每次读完,缓存里留下的行不能比目录旧。
        let writer = Task.detached {
            for round in 1...40 {
                var changed = songs[0..<8].map { $0 }
                for index in changed.indices { changed[index].title = "round-\(round)" }
                cache.invalidate(try catalog.apply(upserts: changed))
            }
        }
        for _ in 0..<400 {
            for index in 0..<8 { _ = try cache.song(id: "s\(index)", in: catalog) }
        }
        try await writer.value
        for index in 0..<8 {
            #expect(try cache.song(id: "s\(index)", in: catalog)?.title == "round-40")
        }
    }

    @Test("A by-ID read does not wait for the reader pool")
    func byIDReadDoesNotWaitForThePool() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.apply(upserts: (0..<40).map { Self.song("s\($0)", source: "A", path: "p/\($0).flac") })
        let cache = LibraryRowCache()
        // 池里的读连接都被占着(各停在一趟遍历的第一行上)。
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<LibraryScale.maximumReaderCount {
            DispatchQueue.global().async {
                try? catalog.forEachSongIdentity(.everything) { _, _, _ in
                    entered.signal()
                    release.wait()
                    return false
                }
            }
        }
        for _ in 0..<LibraryScale.maximumReaderCount { entered.wait() }
        // 按 id 读一首走专用的连接:不等它们。
        let done = DispatchSemaphore(value: 0)
        let found = OSAllocatedUnfairLock<String?>(initialState: nil)
        DispatchQueue.global().async {
            let id = (try? cache.song(id: "s3", in: catalog))?.id
            found.withLock { $0 = id }
            done.signal()
        }
        let finishedInTime = done.wait(timeout: .now() + 5) == .success
        for _ in 0..<LibraryScale.maximumReaderCount { release.signal() }
        #expect(finishedInTime, "a by-ID read waited for a pool reader")
        if !finishedInTime { done.wait() }
        #expect(found.withLock { $0 } == "s3")
    }

    @Test("A visible album or artist read by ID is the item the visible lists give; the split flag answers like a full scan")
    func visibleAlbumAndArtistByID() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        var songs: [Song] = []
        for index in 0..<24 {
            let source = index % 4 == 0 ? "B" : "A"
            songs.append(Song(
                id: "s\(index)", title: "t\(index)", albumTitle: "Album \(index / 4)",
                artistName: index % 3 == 0 ? "Singer \(index % 5)、Guest" : "Singer \(index % 5)",
                albumArtistName: "Singer \(index / 4 % 5)", trackNumber: index % 4 + 1, discNumber: 1,
                duration: 100.25 + Double(index), fileFormat: index % 6 == 0 ? .m4a : .flac,
                filePath: "/\(source)/Album \(index / 4)/\(index).\(index % 6 == 0 ? "m4b" : "flac")",
                sourceID: source, genre: index % 6 == 0 ? "Audiobook" : "Pop"
            ))
        }
        /// 目录用的那条判断(走 `kind` 打头的索引),与原来的写法(`kind != 0`,整表扫)各问一遍。
        func splitFlags() throws -> (indexed: Bool, scanned: Bool) {
            try catalog.reader.read { db in
                let scanned = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM source WHERE enabled = 0)
                        OR EXISTS (SELECT 1 FROM song WHERE kind != 0 AND sourceKey IN (SELECT key FROM source WHERE enabled = 1))
                    """) ?? false
                return (try LibraryCatalog.visibleSplitsLibrary(in: db), scanned)
            }
        }
        /// 目录里此刻有没有不算音乐的歌(逐首问类别,不经那两条判断)。
        func hasNonMusic() throws -> Bool {
            try songs.contains { song in
                guard let kind = try catalog.contentKind(songID: song.id) else { return false }
                return kind != .music
            }
        }
        func assertMatchesLists() throws {
            // 走索引的写法与整表扫的写法同一个答案;列表与按 id 取一项用的都是它。
            let flags = try splitFlags()
            #expect(flags.indexed == flags.scanned)
            // 列表查询本身:可见的专辑键、艺人键,与按整表扫的那条判断直接算出来的同一批。
            let expected = try catalog.reader.read { db -> (albums: Set<Int64>, artists: Set<Int64>) in
                let enabled = "SELECT key FROM source WHERE enabled = 1"
                let albumFilter = flags.scanned
                    ? " WHERE key IN (SELECT albumKey FROM albumSourceStat WHERE kind = 0 AND sourceKey IN (\(enabled)))" : ""
                let artistFilter = flags.scanned
                    ? " WHERE key IN (SELECT artistRef FROM artistSourceStat WHERE kind = 0 AND sourceKey IN (\(enabled)))" : ""
                return (
                    Set(try Int64.fetchAll(db, sql: "SELECT key FROM album\(albumFilter)")),
                    Set(try Int64.fetchAll(db, sql: "SELECT key FROM artist\(artistFilter)"))
                )
            }
            #expect(Set(try catalog.albumKeys(visibleOnly: true).keys.map(Int64.init)) == expected.albums)
            #expect(Set(try catalog.artistKeys(visibleOnly: true).keys.map(Int64.init)) == expected.artists)
            let browse = try #require(try catalog.albumBrowseKeys(order: .title, unknownArtistName: nil, currentYear: 2026))
            #expect(Set(browse.keys.map(Int64.init)) == expected.albums)
            #expect(Set(try catalog.artistBrowseKeys(unknownArtistName: nil).keys.map(Int64.init)) == expected.artists)
            let albums = try catalog.albums(keys: catalog.albumKeys(visibleOnly: true).keys)
            let artists = try catalog.artists(keys: catalog.artistKeys(visibleOnly: true).keys)
            #expect(!albums.isEmpty && !artists.isEmpty)
            for album in albums { #expect(try catalog.visibleAlbum(id: album.id) == album) }
            for artist in artists { #expect(try catalog.visibleArtist(id: artist.id) == artist) }
            // 整库有、可见列表里没有的,按 id 也没有。
            let visibleAlbumIDs = Set(albums.map(\.id))
            for album in try catalog.albums(keys: catalog.albumKeys(visibleOnly: false).keys, visibleCounts: false)
            where !visibleAlbumIDs.contains(album.id) {
                #expect(try catalog.visibleAlbum(id: album.id) == nil)
            }
            let visibleArtistIDs = Set(artists.map(\.id))
            for artist in try catalog.artists(keys: catalog.artistKeys(visibleOnly: false).keys, visibleCounts: false)
            where !visibleArtistIDs.contains(artist.id) {
                #expect(try catalog.visibleArtist(id: artist.id) == nil)
            }
            #expect(try catalog.visibleAlbum(id: "no-such-album") == nil)
            #expect(try catalog.visibleArtist(id: "no-such-artist") == nil)
        }
        // 只有音乐、没有停用的源:可见的就是整库。
        try catalog.apply(upserts: songs.filter { $0.genre == "Pop" })
        #expect(try !hasNonMusic())
        #expect(try !splitFlags().indexed)
        try assertMatchesLists()
        // 加上有声书那几首:有不算音乐的歌时两条判断都为真。
        try catalog.apply(upserts: songs)
        let classifiedNonMusic = try hasNonMusic()
        #expect(try splitFlags().indexed == classifiedNonMusic)
        try assertMatchesLists()
        // 停用一个源:只在那个源里有歌的专辑、艺人不再可见,其余的计数只算可见的歌。
        try catalog.setSourceEnabled(false, sourceID: "B")
        #expect(try splitFlags().indexed)
        try assertMatchesLists()
        // 启用的源里只剩音乐(不算音乐的都在停用的源里)。
        try catalog.apply(upserts: [], deletingIDs: songs.filter { $0.genre != "Pop" && $0.sourceID == "A" }.map(\.id))
        #expect(try splitFlags().indexed)
        try assertMatchesLists()
        // 重新启用、去掉其余不算音乐的:回到整库都可见。
        try catalog.setSourceEnabled(true, sourceID: "B")
        try catalog.apply(upserts: [], deletingIDs: songs.filter { $0.genre != "Pop" }.map(\.id))
        #expect(try !splitFlags().indexed)
        try assertMatchesLists()
        try catalog.setSourceEnabled(false, sourceID: "B")
        try assertMatchesLists()
        try catalog.setSourceEnabled(false, sourceID: "A")
        #expect(try catalog.albumKeys(visibleOnly: true).count == 0)
        #expect(try catalog.visibleAlbum(id: catalog.albums(keys: catalog.albumKeys(visibleOnly: false).keys).first?.id ?? "") == nil)
    }

    /// 合成一个 `library-songs.sqlite`。
    static func makeStore(at path: String, songs: [Song]) throws -> IncrementalSongStore {
        let store = try IncrementalSongStore(path: path)
        try store.replaceAll(with: songs)
        return store
    }

    @Test("Import streams the incremental store, resumes after interruption, and matches a one-shot import")
    func resumableImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rng = CatalogTestRandom(seed: 77)
        let songs = (0..<1_234).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        let store = try Self.makeStore(at: storePath, songs: songs)
        // 再追加几首:新行的 orderKey 排在后面。
        let extra = (0..<5).map { CatalogSongFactory.randomSong(&rng, index: 5_000 + $0, exotic: false).withoutAppliedPlaybackRange }
        try store.apply(upserts: extra)
        let expectedOrder = try store.loadSongs()

        let resumedPath = directory.appendingPathComponent("resumed.sqlite").path
        do {
            let catalog = try LibraryCatalog(path: resumedPath)
            let partial = try LibraryCatalogImporter.importIncrementalSongStore(
                at: storePath, into: catalog, batchSize: 100, maximumBatches: 3
            )
            #expect(partial.isComplete == false)
            #expect(partial.imported == 300)
        }
        let resumedCatalog = try LibraryCatalog(path: resumedPath)
        var reports: [LibraryCatalogImportProgress] = []
        let finished = try LibraryCatalogImporter.importIncrementalSongStore(
            at: storePath, into: resumedCatalog, batchSize: 100, progress: { reports.append($0) }
        )
        #expect(finished.isComplete)
        #expect(finished.imported == expectedOrder.count)
        #expect(reports.first?.imported == 400)

        let oneShot = try LibraryCatalog(path: directory.appendingPathComponent("oneshot.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: oneShot)

        func indexNames(_ catalog: LibraryCatalog) throws -> Set<String> {
            try catalog.pool.read { db in
                try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            }
        }
        for catalog in [resumedCatalog, oneShot] {
            var imported: [Song] = []
            try catalog.forEachSong(.everything) { _, song in
                imported.append(song)
                return true
            }
            #expect(imported == expectedOrder)
            // 迁移只建必需的索引;本地化排序索引记成待建,打开时也不建。
            #expect(try indexNames(catalog).isSuperset(of: LibraryCatalogSchema.migrationIndexes.map(\.name)))
            #expect(try indexNames(catalog).isDisjoint(with: LibraryCatalogSchema.backgroundSortIndexNames))
            #expect(try catalog.hasPendingSortIndexes())
        }
        let reopened = try LibraryCatalog(path: resumedPath)
        #expect(try indexNames(reopened).isDisjoint(with: LibraryCatalogSchema.backgroundSortIndexNames))
        #expect(try reopened.hasPendingSortIndexes())
        // 索引没建好时这几种排序整表排;建好后走索引,结果一样。
        let orders: [LibrarySongSortOrder] = [.artist, .artistDescending, .album, .albumDescending, .fileName, .fileNameDescending]
        let pendingLists = try orders.map { try reopened.songRowList(order: $0).rowids }
        var asked = 0
        #expect(try reopened.buildPendingSortIndexes(isCancelled: { asked += 1; return asked > 1 }) == false)
        #expect(try reopened.hasPendingSortIndexes())
        #expect(try reopened.buildPendingSortIndexes())
        #expect(try orders.map { try reopened.songRowList(order: $0).rowids } == pendingLists)
        #expect(try indexNames(reopened).isSuperset(of: LibraryCatalogSchema.deferredIndexes.map(\.name)))
        #expect(try !reopened.hasPendingSortIndexes())
        // 已完成:再调一次什么也不做。
        let again = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: oneShot)
        #expect(again.isComplete)
        #expect(try oneShot.songCount(.everything) == expectedOrder.count)
    }

    @Test("Source traits changed mid-import apply from the next written batch, as in a sequential import")
    func importRechecksSourceTraits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rng = CatalogTestRandom(seed: 79)
        let songs = (0..<600).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        _ = try Self.makeStore(at: storePath, songs: songs)
        // 改特征要有可见效果:选一个按路径取文件名的源(Apple Music 本来就用标题)。
        let target = try #require(songs.first {
            $0.sourceID != AppleMusicLibraryIdentity.sourceID && !$0.filePath.isEmpty
        }).sourceID
        func flip(_ catalog: LibraryCatalog) throws {
            try catalog.pool.write { db in
                try db.execute(sql: "UPDATE source SET fileNamesFromIndex = 1 WHERE id = ?", arguments: [target])
            }
        }
        func songRows(_ catalog: LibraryCatalog) throws -> [[DatabaseValue]] {
            try catalog.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM song ORDER BY rowid").map { Array($0.databaseValues) }
            }
        }

        // 下一批在写第一批时已按旧特征算好;第一批写完后改特征,写下一批前要发现并重算。
        let pipelined = try LibraryCatalog(path: directory.appendingPathComponent("pipelined.sqlite").path)
        var flipped = false
        _ = try LibraryCatalogImporter.importIncrementalSongStore(
            at: storePath, into: pipelined, batchSize: 100,
            progress: { _ in
                guard !flipped else { return }
                flipped = true
                usleep(200_000)
                try? flip(pipelined)
            }
        )
        // 参照:逐批导入时,第一批之后改特征,后面的批次按新特征写。
        let reference = try LibraryCatalog(path: directory.appendingPathComponent("reference.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: reference, batchSize: 100, maximumBatches: 1)
        try flip(reference)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: reference, batchSize: 100)
        let unchanged = try LibraryCatalog(path: directory.appendingPathComponent("unchanged.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: unchanged, batchSize: 100)

        #expect(flipped)
        #expect(try songRows(pipelined) == songRows(reference))
        #expect(try songRows(pipelined) != songRows(unchanged))
    }

    @Test("Renaming song IDs keeps rowids and library order; the result equals a fresh catalog of the same songs")
    func renamingKeepsRowsInPlace() throws {
        var rng = CatalogTestRandom(seed: 80)
        let songs = (0..<40).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        _ = try catalog.apply(upserts: songs)
        let before = try catalog.rowList(.everything).rowids
        let rowid0 = try #require(try catalog.rowids(forIDs: [songs[0].id]).first ?? nil)
        let rowid5 = try #require(try catalog.rowids(forIDs: [songs[5].id]).first ?? nil)

        // 改标签换了身份:带着新值改名;只改名不带新值;新 id 已被占(退回删旧行、写到已有那行)。
        var renamed0 = songs[0]
        renamed0.id = songs[0].id + "-v2"
        renamed0.title = "Edited"
        var merged7 = songs[7]
        merged7.id = songs[8].id
        _ = try catalog.apply(
            upserts: [renamed0, merged7],
            deletingIDs: [songs[0].id, songs[7].id],
            renaming: [songs[0].id: renamed0.id, songs[5].id: songs[5].id + "-v2", songs[7].id: songs[8].id]
        )
        #expect(try catalog.song(id: songs[0].id) == nil)
        #expect(try catalog.song(id: songs[7].id) == nil)
        #expect(try catalog.rowids(forIDs: [renamed0.id]) == [rowid0])
        #expect(try catalog.rowids(forIDs: [songs[5].id + "-v2"]) == [rowid5])
        #expect(try catalog.song(id: renamed0.id)?.title == "Edited")
        #expect(try catalog.rowList(.everything).rowids.count == before.count - 1)

        // 与一个按同样顺序写入同样最终歌曲的新目录逐项相同。
        var final = songs
        final[0] = renamed0
        final[5].id = songs[5].id + "-v2"
        final[8] = merged7
        final.remove(at: 7)
        let fresh = try TemporaryCatalog()
        _ = try fresh.catalog.apply(upserts: final)
        func ids(_ catalog: LibraryCatalog) throws -> [String] {
            var result: [String] = []
            try catalog.forEachSong(.everything) { _, song in
                result.append(song.id)
                return true
            }
            return result
        }
        func albums(_ catalog: LibraryCatalog) throws -> [String] {
            try catalog.albums(keys: catalog.albumKeys(visibleOnly: false).keys, visibleCounts: false)
                .map { "\($0.id)|\($0.title)|\($0.songCount)" }.sorted()
        }
        #expect(try ids(catalog) == ids(fresh.catalog))
        #expect(try albums(catalog) == albums(fresh.catalog))
        #expect(try catalog.songCountsBySource(.everything) == fresh.catalog.songCountsBySource(.everything))
    }

    @Test("A store that changed between runs restarts the import")
    func importRestartsWhenStoreChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rng = CatalogTestRandom(seed: 78)
        let songs = (0..<300).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        let store = try Self.makeStore(at: storePath, songs: songs)
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: catalog, batchSize: 50, maximumBatches: 2)
        var edited = songs[0]
        edited.title = "changed in between"
        try store.apply(upserts: [edited], deletingIDs: [songs[299].id])
        let result = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: catalog, batchSize: 50)
        #expect(result.isComplete)
        #expect(try catalog.songCount(.everything) == 299)
        #expect(try catalog.song(id: songs[0].id)?.title == "changed in between")
    }
}
