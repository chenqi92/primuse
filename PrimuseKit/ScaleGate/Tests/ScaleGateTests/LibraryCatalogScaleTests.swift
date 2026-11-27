import Darwin
import Foundation
import GRDB
import Testing
@testable import PrimuseKit

// 合成曲库 `LibraryCatalogSyntheticLibrary` 与进程测量 `LibraryScaleProbes` 在 `Shared/LibraryCatalogScaleSupport.swift`,
// `CatalogTestRandom` 在 `Shared/CatalogTestRandom.swift`:两者都是指向 `PrimuseKit/Tests/PrimuseKitTests/Support/` 的符号链接。
@Suite("Library catalog scale gate", .serialized)
struct LibraryCatalogScaleTests: LibraryScaleProbes {
    /// 后台每 2 ms 采一次 footprint,记最大值。
    final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var running = true
        private let thread: Thread

        init() {
            let box = Box()
            thread = Thread { box.sampler?.loop() }
            box.sampler = self
            thread.start()
        }

        private final class Box: @unchecked Sendable { weak var sampler: PeakSampler? }

        private func loop() {
            while lock.withLock({ running }) {
                let current = LibraryCatalogScaleTests.footprint().current
                lock.withLock { peak = max(peak, current) }
                usleep(2_000)
            }
        }

        func stop() -> UInt64 {
            lock.withLock { running = false }
            return lock.withLock { peak }
        }
    }

    struct Report {
        var lines: [String] = []
        var failures: [String] = []
        mutating func record(_ label: String, _ milliseconds: Double, budget: Double? = nil, enforced: Bool = true) {
            var line = "📏 catalog-scale \(label)=\(String(format: "%.1f", milliseconds))ms"
            if let budget {
                line += " (budget \(String(format: "%.0f", budget)))"
                if milliseconds > budget {
                    if enforced { failures.append(line) } else { line += " over; not enforced in this build" }
                }
            }
            lines.append(line)
            print(line)
        }
        mutating func note(_ text: String) {
            let line = "📏 catalog-scale \(text)"
            lines.append(line)
            print(line)
        }
    }

    static func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = now()
        let value = try body()
        return (value, (now() - start) * 1_000)
    }

    static var songCount: Int {
        ProcessInfo.processInfo.environment["PRIMUSE_CATALOG_SCALE_SONGS"].flatMap(Int.init)
            ?? LibraryCatalogScaleBudgets.ciSongCount
    }

    /// 合成 `library-songs.sqlite`:与 `IncrementalSongStore` 同一张表、同一套 JSON 编码,逐批写。
    static func writeSyntheticStore(at path: String, library: LibraryCatalogSyntheticLibrary) throws {
        _ = try IncrementalSongStore(path: path)
        let queue = try DatabaseQueue(path: path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        for start in stride(from: 0, to: library.songCount, by: 5_000) {
            try queue.write { db in
                let insert = try db.makeStatement(sql: "INSERT INTO librarySongRecords (id, sourceID, orderKey, payload) VALUES (?, ?, ?, ?)")
                for index in start..<min(start + 5_000, library.songCount) {
                    let song = library.song(at: index)
                    try insert.execute(arguments: [song.id, song.sourceID, Int64(index), try encoder.encode(song)])
                }
            }
        }
        try queue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO libraryStoreMetadata (key, value) VALUES ('songs-authoritative', '1');
                INSERT OR REPLACE INTO libraryStoreMetadata (key, value) VALUES ('songs-content-revision', '1');
                """)
        }
    }

    @Test("Scale gate: open, counts, 30 orders, pages, source/path queries, writes, footprint")
    func scaleGate() throws {
        let songCount = Self.songCount
        let library = LibraryCatalogSyntheticLibrary(songCount: songCount)
        // 默认走真实迁移路径(合成 library-songs.sqlite → 导入 → 分组重建);设 0 改用直接批量写入。
        let viaImport = ProcessInfo.processInfo.environment["PRIMUSE_CATALOG_SCALE_VIA_IMPORT"] != "0"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogPath = directory.appendingPathComponent("library-catalog.sqlite").path
        var report = Report()
        report.note("songs=\(songCount) albums≈\(library.albumCount) artists≈\(library.artistCount) viaImport=\(viaImport) locale=\(Locale.current.identifier)")
        let testStart = Self.now()
        let scaled = { (budget: Double, floor: Double) in
            LibraryCatalogScaleBudgets.scaled(budget, songCount: songCount, floor: floor)
        }

        // 0. 每首成本拆分(2 万首样本):生成、派生列、存储列编码。
        do {
            let sample = min(20_000, songCount)
            let (songs, generateMs) = Self.time { (0..<sample).map(library.song(at:)) }
            let traits = LibraryCatalogDerivedFields.SourceTraits()
            let (_, derivedMs) = Self.time {
                for song in songs { _ = LibraryCatalogDerivedFields.make(for: song, source: traits, fileNameOverride: nil) }
            }
            let (_, encodeMs) = Self.time { for song in songs { _ = LibraryCatalogSongCodec.encode(song) } }
            let (_, keysMs) = Self.time {
                for song in songs {
                    _ = LibraryCollationPolicy.songTitleKey(for: song.title)
                    _ = LibraryCollationPolicy.key(for: song.artistName ?? "")
                    _ = LibraryCollationPolicy.key(for: song.albumTitle ?? "")
                }
            }
            let (_, matchMs) = Self.time { for song in songs { _ = ExternalTrackMatchPolicy.splitTitle(song.title) } }
            let perSong = { (ms: Double) in String(format: "%.1fµs", ms * 1_000 / Double(sample)) }
            report.note("perSong generate=\(perSong(generateMs)) derived=\(perSong(derivedMs)) (keys=\(perSong(keysMs)) match=\(perSong(matchMs))) encode=\(perSong(encodeMs))")
        }

        // 1. 建库(不计入走查的内存预算)。
        let buildStart = Self.now()
        if viaImport {
            let storePath = directory.appendingPathComponent("library-songs.sqlite").path
            let (_, storeMs) = try Self.time { try Self.writeSyntheticStore(at: storePath, library: library) }
            report.record("build.syntheticStore", storeMs)
            let catalog = try LibraryCatalog(path: catalogPath)
            LibraryCatalogImportProfile.reset()
            let migrationBaseline = Self.footprint().current
            let migrationSampler = PeakSampler()
            let (result, importMs) = try Self.time {
                try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: catalog)
            }
            #expect(result.isComplete && result.imported == songCount)
            report.record("import.total", importMs)
            report.note("import.stages \(LibraryCatalogImportProfile.summary())")
            report.note("import.throughput=\(Int(Double(songCount) / (importMs / 1_000)))songs/s")
            try? FileManager.default.removeItem(atPath: storePath)
            LibraryCatalogImportProfile.reset()
            let (_, groupingMs) = try Self.time { try catalog.rebuildGrouping() }
            report.record("build.grouping", groupingMs)
            report.note("grouping.stages \(LibraryCatalogImportProfile.summary())")
            report.record("migration.total(import+indexes+grouping)", importMs + groupingMs,
                          budget: scaled(LibraryCatalogScaleBudgets.migrationSeconds * 1_000, 3_000),
                          enforced: LibraryCatalogScaleBudgets.enforcesMigrationTime)
            let migrationPeak = Self.mib(migrationSampler.stop()) - Self.mib(migrationBaseline)
            report.note(String(format: "migration.peakGrowth=%.1fMiB", migrationPeak))
            if migrationPeak > LibraryCatalogScaleBudgets.migrationPeakGrowthMiB {
                report.failures.append("📏 catalog-scale migration.peakGrowth=\(Int(migrationPeak))MiB (budget \(Int(LibraryCatalogScaleBudgets.migrationPeakGrowthMiB)))")
            }
            // 迁移后:本地化排序索引还在后台补建时排一次(整表排序),再补建(不计入迁移时长)。
            #expect(try catalog.hasPendingSortIndexes())
            let (_, pendingSortMs) = try Self.time { try catalog.songRowList(order: .album, scope: .visibleMusic) }
            report.record("sort.album(sortIndexesPending)", pendingSortMs)
            LibraryCatalogImportProfile.reset()
            let (built, sortIndexMs) = try Self.time { try catalog.buildPendingSortIndexes() }
            #expect(built)
            #expect(try !catalog.hasPendingSortIndexes())
            report.record("build.backgroundSortIndexes", sortIndexMs)
            report.note("sortIndexes.stages \(LibraryCatalogImportProfile.summary())")
        } else {
            let catalog = try LibraryCatalog(path: catalogPath)
            try catalog.beginBulkLoad()
            let (_, insertMs) = try Self.time {
                for start in stride(from: 0, to: songCount, by: LibraryScale.importBatchSize) {
                    try autoreleasepool {
                        let batch = (start..<min(start + LibraryScale.importBatchSize, songCount)).map(library.song(at:))
                        try catalog.bulkInsert(batch)
                    }
                }
            }
            report.record("build.bulkInsert", insertMs)
            let (_, indexMs) = try Self.time { try catalog.finishBulkLoad() }
            report.record("build.sortIndexes", indexMs)
            let (_, groupingMs) = try Self.time { try catalog.rebuildGrouping() }
            report.record("build.grouping", groupingMs)
        }
        do {
            let catalog = try LibraryCatalog(path: catalogPath)
            try catalog.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO songStat (songRowid, localPlayCount) SELECT rowid, (rowid * 7) % 50 FROM song WHERE rowid % 10 = 0;
                    INSERT INTO songOffline (songRowid, state) SELECT rowid, 1 FROM song WHERE rowid % 250 = 0;
                    UPDATE source SET name = id;
                    """)
            }
            try catalog.pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        }
        report.record("build.total", (Self.now() - buildStart) * 1_000)
        let attributes = try FileManager.default.attributesOfItem(atPath: catalogPath)
        let databaseBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let bytesPerSong = databaseBytes / Int64(max(1, songCount))
        report.note("db.size=\(String(format: "%.1f", Double(databaseBytes) / 1_048_576))MiB bytesPerSong=\(bytesPerSong)")
        if bytesPerSong > LibraryCatalogScaleBudgets.databaseBytesPerSong {
            report.failures.append("📏 catalog-scale db.bytesPerSong=\(bytesPerSong) (budget \(LibraryCatalogScaleBudgets.databaseBytesPerSong))")
        }
        if let breakdown = try? LibraryCatalog(path: catalogPath).pool.read({ db in
            try Row.fetchAll(db, sql: "SELECT name, sum(pgsize) AS size FROM dbstat GROUP BY name ORDER BY size DESC")
        }) {
            let perSong = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / Double(max(1, songCount))) }
            report.note("db.breakdown " + breakdown.map { "\($0[0] as String)=\(perSong($0[1]))B" }.joined(separator: " "))
        }

        // 2. 走查。基线:建库连接已关、缓存已放。
        let baseline = Self.footprint().current
        let mallocBaseline = Self.mallocBytes()
        let sampler = PeakSampler()

        var retainedLists: [LibraryRowList] = []
        do {
            let (catalog, openMs) = try Self.time { () throws -> LibraryCatalog in
                let catalog = try LibraryCatalog(path: catalogPath)
                _ = try catalog.revision()
                return catalog
            }
            report.record("open", openMs, budget: LibraryCatalogScaleBudgets.openMilliseconds)

            let countBudget = scaled(LibraryCatalogScaleBudgets.countMilliseconds, 50)
            let (visible, visibleMs) = try Self.time { try catalog.songCount(.visible) }
            report.record("count.visible", visibleMs, budget: countBudget)
            #expect(visible == songCount)
            let (music, musicMs) = try Self.time { try catalog.songCount(.visibleMusic) }
            report.record("count.music", musicMs, budget: countBudget)
            report.note("music=\(music) spoken=\(visible - music)")
            let (_, bySourceMs) = try Self.time { try catalog.songCountsBySource() }
            report.record("count.bySource", bySourceMs, budget: countBudget)
            let (_, aggregateMs) = try Self.time { try catalog.aggregates(.visibleMusic) }
            report.record("count.aggregates", aggregateMs, budget: countBudget)

            let indexed = LibraryCatalogSongSort.indexedCriteria
            var titleList = LibraryRowList.empty
            for order in LibrarySongSortOrder.allCases {
                let (list, ms) = try Self.time { try catalog.songRowList(order: order, scope: .visibleMusic) }
                #expect(list.count == music)
                let budget = indexed.contains(order.criterion)
                    ? scaled(LibraryCatalogScaleBudgets.indexedSortMilliseconds, 80)
                    : scaled(LibraryCatalogScaleBudgets.unindexedSortMilliseconds, 300)
                report.record("sort.\(order.rawValue)", ms, budget: budget)
                if order == .title { titleList = list }
                retainedLists.append(list)
                if retainedLists.count > 4 { retainedLists.removeFirst() }
            }

            let cache = LibraryRowCache()
            let (firstPage, firstPageMs) = try Self.time { try cache.songs(forRowids: titleList.page(0..<200), in: catalog) }
            #expect(firstPage.count == 200 && firstPage.allSatisfy { $0 != nil })
            report.record("page.first", firstPageMs, budget: LibraryCatalogScaleBudgets.firstPageMilliseconds)
            var rng = CatalogTestRandom(seed: 99)
            var worstPage = 0.0
            var totalPages = 0.0
            for _ in 0..<20 {
                let start = rng.int(0...max(0, titleList.count - 200))
                let (_, ms) = try Self.time { try cache.songs(forRowids: titleList.page(start..<(start + 200)), in: catalog) }
                worstPage = max(worstPage, ms)
                totalPages += ms
            }
            report.record("page.random.worst", worstPage, budget: LibraryCatalogScaleBudgets.randomPageMilliseconds)
            report.record("page.random.mean", totalPages / 20)

            let sampleIDs = (0..<LibraryScale.maxMaterializedRows).map { library.song(at: ($0 * 97) % songCount).id }
            let (batch, batchMs) = try Self.time { try catalog.songs(ids: sampleIDs) }
            #expect(batch.count == sampleIDs.count)
            report.record("materialize.ids5000", batchMs, budget: LibraryCatalogScaleBudgets.maxBatchMaterializationMilliseconds)

            let (sourceList, sourceMs) = try Self.time { try catalog.rowList(.source("smb-home")) }
            report.record("source.rowList(smb 60%)", sourceMs, budget: scaled(LibraryCatalogScaleBudgets.countMilliseconds, 50))
            report.note("source.smb.count=\(sourceList.count)")
            let probe = library.song(at: songCount / 2)
            let directory = AlbumArtistInferencePolicy.directory(ofPath: probe.filePath)
            let (_, directMs) = try Self.time { try catalog.rowList(sourceID: probe.sourceID, directory: directory, recursive: false) }
            report.record("path.directory", directMs, budget: LibraryCatalogScaleBudgets.pathQueryMilliseconds)
            let artistDirectory = (directory as NSString).deletingLastPathComponent
            let (recursive, recursiveMs) = try Self.time { try catalog.rowList(sourceID: probe.sourceID, directory: artistDirectory, recursive: true) }
            report.record("path.recursive", recursiveMs, budget: LibraryCatalogScaleBudgets.pathQueryMilliseconds)
            #expect(recursive.count >= 1)
            let (foundID, exactMs) = try Self.time { try catalog.songID(sourceID: probe.sourceID, filePath: probe.filePath) }
            #expect(foundID == probe.id)
            report.record("path.exact", exactMs, budget: LibraryCatalogScaleBudgets.pathQueryMilliseconds)

            // 分组查询:专辑/艺人列表与详情、流派、文件夹、有声书、封面回退。
            let groupBudget = scaled(LibraryCatalogScaleBudgets.groupListMilliseconds, 60)
            let (albumList, albumListMs) = try Self.time { try catalog.albumKeys(visibleOnly: true) }
            report.record("group.albumKeys", albumListMs, budget: groupBudget)
            let (albumPage, albumPageMs) = try Self.time { try catalog.albums(keys: albumList.keys.prefix(200)) }
            report.record("group.albumsPage200", albumPageMs, budget: LibraryCatalogScaleBudgets.firstPageMilliseconds)
            report.note("group.albums=\(albumList.count)")
            let sampleAlbum = albumPage[albumPage.count / 2]
            let (albumSongs, albumSongsMs) = try Self.time { () throws -> [Song] in
                try catalog.songs(rowids: catalog.albumSongRowList(albumID: sampleAlbum.id).rowids)
            }
            #expect(!albumSongs.isEmpty)
            report.record("group.albumSongs", albumSongsMs, budget: LibraryCatalogScaleBudgets.albumSongsMilliseconds)
            let (_, albumArtworkMs) = try Self.time { try catalog.preferredArtworkSongID(albumID: sampleAlbum.id) }
            report.record("group.albumArtwork", albumArtworkMs, budget: LibraryCatalogScaleBudgets.albumSongsMilliseconds)
            let (artistList, artistListMs) = try Self.time { try catalog.artistKeys(visibleOnly: true) }
            report.record("group.artistKeys", artistListMs, budget: groupBudget)
            let (artistPage, artistPageMs) = try Self.time { try catalog.artists(keys: artistList.keys.prefix(200)) }
            report.record("group.artistsPage200", artistPageMs, budget: LibraryCatalogScaleBudgets.firstPageMilliseconds)
            report.note("group.artists=\(artistList.count)")
            let sampleArtist = artistPage[artistPage.count / 2]
            let (artistSongs, artistSongsMs) = try Self.time { try catalog.artistSongRowList(artistID: sampleArtist.id) }
            report.record("group.artistSongs(\(artistSongs.count))", artistSongsMs, budget: groupBudget)
            let (genres, genresMs) = try Self.time { try catalog.genres() }
            report.record("group.genres(\(genres.count))", genresMs,
                          budget: scaled(LibraryCatalogScaleBudgets.genreListMilliseconds, 200))
            let (roots, rootsMs) = try Self.time { try catalog.folderChildren(sourceID: "smb-home", path: nil) }
            report.record("group.folderRoots", rootsMs, budget: LibraryCatalogScaleBudgets.pathQueryMilliseconds)
            if let root = roots.first {
                let (_, childMs) = try Self.time { try catalog.folderChildren(sourceID: "smb-home", path: root.path) }
                report.record("group.folderChildren", childMs, budget: LibraryCatalogScaleBudgets.pathQueryMilliseconds)
            }
            let spoken = library.song(at: 5)
            let (placement, bookMs) = try Self.time { try catalog.bookPlacement(songID: spoken.id) }
            report.record("group.bookPlacement", bookMs, budget: LibraryCatalogScaleBudgets.pathQueryMilliseconds)
            if let placement {
                let (book, bookListMs) = try Self.time { try catalog.bookRowList(bookID: placement.bookID) }
                report.record("group.bookRowList(\(book.count))", bookListMs, budget: LibraryCatalogScaleBudgets.pathQueryMilliseconds)
            }

            var streamed = 0
            let (_, streamMs) = try Self.time {
                try catalog.forEachSongIdentity(.everything) { _, _, _ in
                    streamed += 1
                    return true
                }
            }
            #expect(streamed == songCount)
            report.record("stream.identities", streamMs, budget: scaled(LibraryCatalogScaleBudgets.streamAllMilliseconds, 300))

            // 一批增量写入:改 400 首(含跨源同名专辑)、加 100 首、删 100 首。
            var edits: [Song] = []
            for offset in 0..<400 {
                var song = library.song(at: (offset * 1_009) % songCount)
                song.title += " (edit)"
                if offset % 4 == 0 { song.albumTitle = "Greatest Hits"; song.sourceID = Self.sourceFor(offset) }
                edits.append(song)
            }
            let additions = (0..<100).map { library.song(at: songCount + $0) }
            let deletions = (0..<100).map { library.song(at: ($0 * 4_001 + 17) % songCount).id }
            LibraryCatalogImportProfile.reset()
            let (summary, writeMs) = try Self.time { try catalog.apply(upserts: edits + additions, deletingIDs: deletions) }
            report.note("write.stages \(LibraryCatalogImportProfile.summary())")
            report.record("write.incremental", writeMs, budget: LibraryCatalogScaleBudgets.incrementalWriteMilliseconds)
            report.note("write.summary inserted=\(summary.insertedRowids.count) updated=\(summary.updatedRowids.count) deleted=\(summary.deletedRowids.count) rowsRead=\(catalog.lastWriteWork.rowsRead) rowsWritten=\(catalog.lastWriteWork.rowsWritten)")
            cache.invalidate(summary)

            // 扫描入库:一批 2000 首新歌(落在已有专辑的目录里)。
            let ingest = (0..<2_000).map { library.song(at: songCount + 100 + $0) }
            LibraryCatalogImportProfile.reset()
            let (ingestSummary, ingestMs) = try Self.time { try catalog.apply(upserts: ingest) }
            #expect(ingestSummary.insertedRowids.count == ingest.count)
            report.note("write.ingest.stages \(LibraryCatalogImportProfile.summary())")
            report.record("write.ingest2000", ingestMs, budget: LibraryCatalogScaleBudgets.ingestWriteMilliseconds)
            report.note("write.ingest rowsRead=\(catalog.lastWriteWork.rowsRead) rowsWritten=\(catalog.lastWriteWork.rowsWritten)")

            // 改一首歌的标签。
            var tagged = library.song(at: (songCount / 3) | 1)
            tagged.title += " (retagged)"
            tagged.year = 2001
            let (_, singleMs) = try Self.time { try catalog.apply(upserts: [tagged]) }
            report.record("write.singleTagEdit", singleMs, budget: LibraryCatalogScaleBudgets.singleEditMilliseconds)

            // 写完之后各处计数仍然对得上(增量维护没有漂移)。
            let invariants = try catalog.pool.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT (SELECT total(songCount) FROM album) - (SELECT count(*) FROM song WHERE effectiveAlbumRef IS NOT NULL),
                           (SELECT count(*) FROM song WHERE titleHash IS NOT NULL AND effectiveAlbumRef IS NULL),
                           (SELECT count(*) FROM album a WHERE NOT EXISTS (SELECT 1 FROM song s WHERE s.effectiveAlbumRef = a.key)),
                           (SELECT total(songCount) FROM artist) - (SELECT count(*) FROM songArtist),
                           (SELECT count(*) FROM artist) - (SELECT count(DISTINCT artistRef) FROM songArtist),
                           (SELECT total(songCount) FROM folder) - (SELECT count(*) FROM song),
                           (SELECT total(songCount) FROM artistSourceStat) - (SELECT count(*) FROM songArtistLookup)
                    """)!
            }
            let drift = (0..<7).map { invariants[$0] as Double }
            report.note("write.invariants \(drift.map { String(Int($0)) }.joined(separator: ","))")
            #expect(drift.allSatisfy { $0 == 0 }, "catalog counts drifted after writes: \(drift)")
            let (_, resortMs) = try Self.time { try catalog.songRowList(order: .title, scope: .visibleMusic) }
            report.record("sort.title.afterWrite", resortMs, budget: scaled(LibraryCatalogScaleBudgets.indexedSortMilliseconds, 80))
            let greatestHits = try catalog.albumKeys(visibleOnly: true)
            report.note("write.albumsAfter=\(greatestHits.count)")

            cache.removeAll()
            catalog.releaseMemory()
        }
        retainedLists.removeAll()
        let peak = sampler.stop()
        let after = Self.footprint().current
        let mallocAfter = Self.mallocBytes()
        let retainedGrowth = Self.mib(after) - Self.mib(baseline)
        let peakGrowth = Self.mib(peak) - Self.mib(baseline)
        report.note(String(format: "footprint baseline=%.1fMiB after=%.1fMiB peak=%.1fMiB retainedGrowth=%.1fMiB peakGrowth=%.1fMiB",
                           Self.mib(baseline), Self.mib(after), Self.mib(peak), retainedGrowth, peakGrowth))
        report.note(String(format: "malloc inUse %.1f→%.1fMiB allocated %.1f→%.1fMiB",
                           Self.mib(mallocBaseline.inUse), Self.mib(mallocAfter.inUse),
                           Self.mib(mallocBaseline.allocated), Self.mib(mallocAfter.allocated)))
        report.note(String(format: "total=%.1fs", Self.now() - testStart))
        #expect(retainedGrowth <= LibraryCatalogScaleBudgets.retainedGrowthMiB, "retained growth \(retainedGrowth) MiB")
        #expect(peakGrowth <= LibraryCatalogScaleBudgets.peakGrowthMiB, "peak growth \(peakGrowth) MiB")
        for failure in report.failures {
            Issue.record("over budget: \(failure)")
        }
    }

    static func sourceFor(_ offset: Int) -> String {
        LibraryCatalogSyntheticLibrary.sources[offset % LibraryCatalogSyntheticLibrary.sources.count]
    }
}
