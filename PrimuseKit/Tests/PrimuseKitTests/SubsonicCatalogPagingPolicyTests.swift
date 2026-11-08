import Foundation
import GRDB
import Testing
@testable import PrimuseKit

struct SubsonicCatalogPagingPolicyTests {
    @Test func largeSongPagesDoNotChangeLegacyAlbumLimitsOrExistingCheckpoints() {
        #expect(SubsonicCatalogPagingPolicy.pageSize == 500)
        #expect(SubsonicCatalogPagingPolicy.songPageSize(serverType: " Navidrome ") == 2_000)
        for type in [nil, "gonic", "airsonic", "unknown"] {
            #expect(SubsonicCatalogPagingPolicy.songPageSize(serverType: type) == 500)
        }
        #expect(SubsonicCatalogPagingPolicy.resumedPageSize(saved: 500, preferred: 2_000) == 500)
        #expect(SubsonicCatalogPagingPolicy.resumedPageSize(saved: nil, preferred: 2_000) == 2_000)
        #expect(SubsonicCatalogPagingPolicy.resumedPageSize(saved: 2_000, preferred: 500) == 500)
        let query = SubsonicCatalogPagingPolicy.search3QueryItems(songOffset: 4_000, pageSize: 2_000)
        #expect(query.first { $0.name == "songCount" }?.value == "2000")
    }

    @Test func cappedSongPagesContinueAtTheActualOffsetUntilEmpty() {
        var offsets: [Int] = []
        var offset = 0
        for received in [500, 500, 37, 0] {
            offsets.append(offset)
            guard let next = SubsonicCatalogPagingPolicy.nextOffset(
                currentOffset: offset, receivedCount: received,
                pageSize: 2_000, continuesAfterShortPage: true
            ) else { break }
            offset = next
        }
        #expect(offsets == [0, 500, 1_000, 1_037])
        let checkpoint = SubsonicCatalogResumeState(
            pageSize: 2_000, stageSessionID: "capped", catalogRevision: "stable",
            nextOffset: 1_037, completedPageCount: 3, stagedSongCount: 1_037,
            stagedItemCount: 1_037,
            firstPageItemIDs: ["first"]
        )
        #expect(checkpoint.isUsable(stagedSongCount: 1_037))
    }
    @Test func everySubsonicFamilyMemberUsesTheSharedPagedRoute() {
        #expect(MusicSourceType.subsonic.isSubsonicFamily)
        #expect(MusicSourceType.navidrome.isSubsonicFamily)
        #expect(MusicSourceType.airsonic.isSubsonicFamily)
        #expect(MusicSourceType.gonic.isSubsonicFamily)
        #expect(!MusicSourceType.plex.isSubsonicFamily)
    }

    @Test func weakServerRevisionNeverDeletesOnASingleWalk() {
        #expect(SubsonicCatalogPagingPolicy.deletionAuthority == .confirmationRequired)
    }

    @Test func directSongSearchIsLimitedToOpenSubsonicAndNavidrome() {
        #expect(SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: true,
            serverType: "gonic"
        ))
        #expect(SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: false,
            serverType: "Navidrome"
        ))
        #expect(!SubsonicCatalogPagingPolicy.shouldUseDirectSongSearch(
            isOpenSubsonic: false,
            serverType: "airsonic"
        ))
    }

    @Test func searchRequestFetchesOnlyOneFullSongPage() {
        let items = SubsonicCatalogPagingPolicy.search3QueryItems(
            songOffset: 500,
            musicFolderID: "7"
        )
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(values["query"] == "")
        #expect(values["artistCount"] == "0")
        #expect(values["albumCount"] == "0")
        #expect(values["songCount"] == "500")
        #expect(values["songOffset"] == "500")
        #expect(values["musicFolderId"] == "7")
    }

    @Test func searchRequestCanNameSeveralLibraries() {
        let items = SubsonicCatalogPagingPolicy.search3QueryItems(
            songOffset: 0,
            musicFolderID: "7",
            musicFolderIDs: ["1", "3"]
        )
        #expect(items.filter { $0.name == "musicFolderId" }.map(\.value) == ["1", "3"])
        let unfiltered = SubsonicCatalogPagingPolicy.search3QueryItems(songOffset: 0)
        #expect(!unfiltered.contains { $0.name == "musicFolderId" })
    }

    @Test func fullPagesAdvanceAndFinalPagesStop() {
        #expect(SubsonicCatalogPagingPolicy.nextOffset(
            currentOffset: 0,
            receivedCount: 500
        ) == 500)
        #expect(SubsonicCatalogPagingPolicy.nextOffset(
            currentOffset: 500,
            receivedCount: 300
        ) == nil)
        #expect(SubsonicCatalogPagingPolicy.terminalVerificationOffset(
            currentOffset: 500,
            receivedCount: 300,
            nextOffset: nil
        ) == 800)
        #expect(SubsonicCatalogPagingPolicy.terminalVerificationOffset(
            currentOffset: 0,
            receivedCount: 500,
            nextOffset: 500
        ) == nil)
    }

    @Test func eightHundredSongsNeedOnlyTwoCatalogPages() {
        var requestedOffsets: [Int] = []
        var offset = 0
        for receivedCount in [500, 300] {
            requestedOffsets.append(offset)
            guard let next = SubsonicCatalogPagingPolicy.nextOffset(
                currentOffset: offset,
                receivedCount: receivedCount
            ) else { break }
            offset = next
        }

        #expect(requestedOffsets == [0, 500])
    }

    @Test func exactEightThousandSnapshotDoesNotRepeatVerifiedEmptyPage() {
        var requestedOffsets: [Int] = []
        var offset = 0
        for receivedCount in Array(repeating: 500, count: 16) + [0] {
            requestedOffsets.append(offset)
            guard let next = SubsonicCatalogPagingPolicy.nextOffset(
                currentOffset: offset,
                receivedCount: receivedCount
            ) else {
                let terminalOffset = SubsonicCatalogPagingPolicy.terminalVerificationOffset(
                    currentOffset: offset,
                    receivedCount: receivedCount,
                    nextOffset: nil
                )
                #expect(!SubsonicCatalogPagingPolicy.needsTerminalProbe(
                    terminalOffset: terminalOffset,
                    observedEmptyTerminalOffset: receivedCount == 0 ? offset : nil
                ))
                break
            }
            offset = next
        }

        #expect(requestedOffsets == Array(stride(from: 0, through: 8_000, by: 500)))
    }

    @Test func legacyAlbumWalkUsesBoundedConcurrencyAndWideSafetyLimits() {
        #expect(SubsonicCatalogPagingPolicy.legacyAlbumConcurrency == 6)
        #expect(SubsonicCatalogPagingPolicy.isWithinAlbumLimit(100_000))
        #expect(!SubsonicCatalogPagingPolicy.isWithinAlbumLimit(100_001))
        #expect(SubsonicCatalogPagingPolicy.isWithinSongLimit(10_000_000))
        #expect(!SubsonicCatalogPagingPolicy.isWithinSongLimit(10_000_001))
    }

    @Test func resumeStateRequiresMatchingSchemaPageSizeAndStagedCount() {
        let state = SubsonicCatalogResumeState(
            stageSessionID: "session-a",
            catalogRevision: "scan:2",
            nextOffset: 500,
            completedPageCount: 1,
            stagedSongCount: 2,
            stagedItemCount: 2,
            firstPageItemIDs: ["one", "two"],
            seenItemIDs: ["one", "two"]
        )
        #expect(SubsonicCatalogPagingPolicy.canResume(state, stagedSongCount: 2))
        #expect(!SubsonicCatalogPagingPolicy.canResume(state, stagedSongCount: 1))

        var oldSchema = state
        oldSchema.schemaVersion = 0
        #expect(!SubsonicCatalogPagingPolicy.canResume(oldSchema, stagedSongCount: 2))

        var oldPageSize = state
        oldPageSize.pageSize = 250
        #expect(!SubsonicCatalogPagingPolicy.canResume(oldPageSize, stagedSongCount: 2))
    }

    @Test func completedResumeStateCanCommitWithoutAnotherPage() {
        let state = SubsonicCatalogResumeState(
            stageSessionID: "session-b",
            catalogRevision: "scan:800",
            nextOffset: nil,
            completedPageCount: 2,
            stagedSongCount: 800,
            stagedItemCount: 800,
            firstPageItemIDs: ["first"],
            seenItemIDs: Set((0..<800).map { String($0) })
        )
        #expect(state.isUsable(stagedSongCount: 800))
    }
}

@Suite("Paged Subsonic catalogue staging")
struct PagedSongCatalogStagingStoreTests {
    @Test("Legacy JSON and compressed pages resume together without losing metadata")
    func mixedPayloadFormatsSurviveRestart() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        var legacy = makeSong(index: 1)
        legacy.lyricsText = String(repeating: "灯塔收起晚风，纸船驶向星河。\n", count: 100)
        legacy.lastModified = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        var compressed = legacy
        compressed.id = "song-2"
        compressed.title = "灯塔与纸船"
        let folder = SourceSyncIndexedItem(stableKey: "folder", path: "/Music",
            displayName: String(repeating: "夜间观测站", count: 100), parentPath: nil,
            isDirectory: true, size: 0, modifiedDate: nil, revision: nil)
        do {
            let store = try PagedSongCatalogStagingStore(path: url.path)
            try store.reset(sourceID: "source", stageSessionID: "mixed", ownerGeneration: 1,
                replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "r1")
            try store.stagePage(sourceID: "source", stageSessionID: "mixed", scopeFingerprint: "account",
                catalogRevision: "r1", offset: 0, nextOffset: 1, itemIDs: [legacy.id], songs: [legacy],
                metadataInspectedSongIDs: [legacy.id], hierarchyItems: [folder], addedSongCount: 1)
            let observer = try DatabaseQueue(path: url.path)
            try observer.write { db in
                try db.execute(sql: "UPDATE pagedCatalogSongs SET payload = ?",
                    arguments: [try JSONEncoder().encode(legacy)])
                try db.execute(sql: "UPDATE pagedCatalogHierarchy SET payload = ?",
                    arguments: [try JSONEncoder().encode(folder)])
            }
        }
        let reopened = try PagedSongCatalogStagingStore(path: url.path)
        #expect(try reopened.snapshot(sourceID: "source")?.nextOffset == 1)
        #expect(try reopened.loadHierarchyIndex(sourceID: "source")[folder.stableKey] == folder)
        try reopened.stagePage(sourceID: "source", stageSessionID: "mixed", scopeFingerprint: "account",
            catalogRevision: "r1", offset: 1, nextOffset: nil, itemIDs: [compressed.id], songs: [compressed],
            metadataInspectedSongIDs: [], hierarchyItems: [folder], addedSongCount: 1)
        let delta = try reopened.delta(sourceID: "source", existingByID: [:], batchSize: 1)
        #expect(delta.upserts == [legacy, compressed])
        #expect(delta.authoritativeSongIDs == [legacy.id, compressed.id])
        #expect(delta.metadataInspectedSongIDs == [legacy.id])
        #expect(try reopened.loadHierarchyIndex(sourceID: "source")[folder.stableKey] == folder)
        let observer = try DatabaseQueue(path: url.path)
        try observer.read { (db: Database) throws -> Void in
            let storedPayload = try Data.fetchOne(db,
                sql: "SELECT payload FROM pagedCatalogSongs WHERE songID = ?", arguments: [compressed.id])
            let payload = try #require(storedPayload)
            #expect(payload.count < (try JSONEncoder().encode(compressed)).count / 2)
            #expect(try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok")
        }
    }

    @Test("Shared folders write once per page and unchanged later pages do not update them")
    func sharedHierarchySkipsDuplicateWritesButKeepsLatestValue() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let store = try PagedSongCatalogStagingStore(path: url.path)
        try store.reset(sourceID: "source", stageSessionID: "folders", ownerGeneration: 1,
            replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "r1")
        let observer = try DatabaseQueue(path: url.path)
        try observer.write { db in
            try db.execute(sql: "CREATE TABLE hierarchyWrites (kind TEXT)")
            try db.execute(sql: """
                CREATE TRIGGER hierarchyInsert AFTER INSERT ON pagedCatalogHierarchy
                BEGIN INSERT INTO hierarchyWrites VALUES ('insert'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER hierarchyUpdate AFTER UPDATE ON pagedCatalogHierarchy
                BEGIN INSERT INTO hierarchyWrites VALUES ('update'); END
                """)
        }
        let original = SourceSyncIndexedItem(stableKey: "root", path: "/Music", displayName: "旧目录",
            parentPath: nil, isDirectory: true, size: 0, modifiedDate: nil, revision: nil)
        var renamed = original
        renamed.displayName = "新目录"
        for offset in 0..<3 {
            let song = makeSong(index: offset)
            let items = offset == 0 ? Array(repeating: original, count: 500)
                : Array(repeating: original, count: 500) + [renamed]
            try store.stagePage(sourceID: "source", stageSessionID: "folders", scopeFingerprint: "account",
                catalogRevision: "r1", offset: offset, nextOffset: offset < 2 ? offset + 1 : nil,
                itemIDs: [song.id], songs: [song], metadataInspectedSongIDs: [],
                hierarchyItems: items, addedSongCount: 1)
        }
        #expect(try store.loadHierarchyIndex(sourceID: "source") == ["root": renamed])
        try observer.read { (db: Database) throws -> Void in
            #expect(try String.fetchAll(db, sql: "SELECT kind FROM hierarchyWrites ORDER BY rowid") == ["insert", "update"])
        }
    }

    @Test("Raw staged catalogue rows merge with current local edits and discard replaced-file enrichment")
    func rawCatalogRowsPreserveCurrentLocalMetadata() throws {
        try withStore { store in
            try store.reset(sourceID: "source", stageSessionID: "raw", ownerGeneration: 1,
                replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "r1")
            let raw = makeSong(index: 1)
            var replacement = makeSong(index: 2)
            replacement.revision = "r2"
            try store.stagePage(sourceID: "source", stageSessionID: "raw", scopeFingerprint: "account",
                catalogRevision: "r1", offset: 0, nextOffset: nil,
                itemIDs: [raw.id, replacement.id], songs: [raw, replacement],
                metadataInspectedSongIDs: [], hierarchyItems: [], addedSongCount: 0)
            var edited = raw
            edited.title = "用户更新的标题"
            edited.userMetadataEditedAt = Date(timeIntervalSince1970: 1_800_000_000)
            edited.lyricsText = "晚风停在窗边，星光落在纸上。"
            edited.replayGainTrackGain = -7.25
            var replaced = makeSong(index: 2)
            replaced.lyricsText = "旧文件里的虚构歌词。"
            replaced.replayGainTrackGain = -6
            let delta = try store.delta(sourceID: "source", existingByID: [edited.id: edited, replaced.id: replaced])
            #expect(delta.authoritativeSongIDs == [edited.id, replaced.id])
            #expect(delta.upserts == [replacement])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRIMUSE_CATALOG_IO_BENCHMARK"] == "1"))
    func catalogStagingWriteBenchmark() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let store = try PagedSongCatalogStagingStore(path: url.path)
        try store.reset(sourceID: "source", stageSessionID: "benchmark", ownerGeneration: 1,
                        replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "r1")
        func writtenBytes() throws -> UInt64 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            #expect(result == 0)
            return info.ri_diskio_byteswritten
        }
        let before = try writtenBytes()
        let started = ContinuousClock.now
        for offset in stride(from: 0, to: 50_000, by: 2_000) {
            let songs = (offset..<offset + 2_000).map { index in
                var song = makeSong(index: index)
                song.id = String(format: "%08x-%08x", UInt32(index) &* 2_654_435_761, index)
                song.artistName = "Catalogue Artist \(index / 200)"
                song.albumTitle = "Evening Observatory \(index / 20)"
                song.albumArtistName = song.artistName
                song.filePath = "/Music/\(song.artistName!)/\(song.albumTitle!)/\(song.title).flac"
                song.fileFormat = .flac
                song.fileSize = 32_000_000
                song.trackNumber = index % 20 + 1
                song.sampleRate = 44_100
                song.bitDepth = 16
                song.bitRate = 900
                song.genre = "Instrumental"
                song.year = 2024
                song.lastModified = Date(timeIntervalSince1970: 1_700_000_000.123_456)
                song.coverArtFileName = "server-cover/album-\(index / 20)"
                return song
            }
            let hierarchy = songs.enumerated().flatMap { relativeIndex, song in
                let index = offset + relativeIndex
                return [
                    SourceSyncIndexedItem(stableKey: "root", path: "/Music", parentPath: nil,
                        isDirectory: true, size: 0, modifiedDate: nil, revision: nil),
                    SourceSyncIndexedItem(stableKey: "artist-\(index / 200)", path: "/Music/\(song.artistName!)",
                        parentPath: "/Music", isDirectory: true, size: 0, modifiedDate: nil, revision: nil),
                    SourceSyncIndexedItem(stableKey: "album-\(index / 20)", path: "/Music/\(song.artistName!)/\(song.albumTitle!)",
                        parentPath: "/Music/\(song.artistName!)", isDirectory: true, size: 0, modifiedDate: nil, revision: nil),
                    SourceSyncIndexedItem(stableKey: song.id, path: song.filePath,
                        parentPath: "/Music/\(song.artistName!)/\(song.albumTitle!)", isDirectory: false,
                        songIDs: [song.id], size: song.fileSize, modifiedDate: song.lastModified, revision: song.revision),
                ]
            }
            try store.stagePage(sourceID: "source", stageSessionID: "benchmark", scopeFingerprint: "account",
                catalogRevision: "r1", offset: offset, nextOffset: offset + 2_000 < 50_000 ? offset + 2_000 : nil,
                itemIDs: songs.map(\.id), songs: songs, metadataInspectedSongIDs: [],
                hierarchyItems: hierarchy, addedSongCount: songs.count)
        }
        let observer = try DatabaseQueue(path: url.path)
        try observer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let elapsed = started.duration(to: .now)
        let writes = try writtenBytes() - before
        let payloadBytes = try observer.read { db in
            (try Int.fetchOne(db, sql: "SELECT sum(length(payload)) FROM pagedCatalogSongs") ?? 0)
                + (try Int.fetchOne(db, sql: "SELECT sum(length(payload)) FROM pagedCatalogHierarchy") ?? 0)
        }
        #expect(try store.snapshot(sourceID: "source")?.stagedSongCount == 50_000)
        #expect(try store.loadHierarchyIndex(sourceID: "source").count == 52_751)
        print("CATALOG_IO songs=50000 hierarchy=52751 diskWrittenBytes=\(writes) payloadBytes=\(payloadBytes) elapsed=\(elapsed)")
    }

    @Test("Discarded catalogue pages are reused without shrinking or growing the database")
    func discardedPagesAreReusedByTheNextScan() async throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let store = try PagedSongCatalogStagingStore(path: url.path)
        let observer = try DatabaseQueue(path: url.path)
        func seed(generation: Int) throws {
            let session = "session-\(generation)"
            try store.reset(sourceID: "source", stageSessionID: session, ownerGeneration: generation,
                            replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "revision")
            for offset in stride(from: 0, to: 5_000, by: 500) {
                let songs = (offset..<offset + 500).map(makeSong(index:))
                let hierarchy = songs.flatMap { song in
                    (0..<3).map { suffix in
                        SourceSyncIndexedItem(stableKey: "\(song.id)-\(suffix)", path: "\(song.filePath).\(suffix)",
                            parentPath: "/Music", isDirectory: false, songIDs: [song.id], size: 1_024,
                            modifiedDate: nil, revision: "r1")
                    }
                }
                _ = try store.stagePage(sourceID: "source", stageSessionID: session,
                    scopeFingerprint: "account", catalogRevision: "revision", offset: offset,
                    nextOffset: offset + 500 < 5_000 ? offset + 500 : nil, itemIDs: songs.map(\.id),
                    songs: songs, metadataInspectedSongIDs: [], hierarchyItems: hierarchy, addedSongCount: 0)
            }
        }
        try seed(generation: 1)
        let before = try await observer.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
             try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0,
             try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0)
        }
        let started = ContinuousClock.now
        let batches = AsyncStream<Int>.makeStream()
        defer { batches.continuation.finish() }
        try await store.discardInBatches(sourceID: "source", stageSessionID: "session-1") { count in
            if count > 0 { batches.continuation.yield(count) }
        }
        let elapsed = started.duration(to: .now)
        batches.continuation.finish()
        var reclaimed: [Int] = []
        for await count in batches.stream { reclaimed.append(count) }
        #expect(reclaimed.count == 3)
        #expect(reclaimed.reduce(0, +) == 25_000)
        let cleared = try await observer.read { db in
            for table in ["pagedCatalogItems", "pagedCatalogSongs", "pagedCatalogHierarchy", "pagedCatalogStages"] {
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0)
            }
            return (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
                    try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0)
        }
        #expect(cleared.0 == before.0)
        #expect(cleared.1 > before.1)
        try seed(generation: 2)
        try await observer.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "PRAGMA page_count") == before.0)
            #expect((try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0) < cleared.1)
            #expect(try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM pagedCatalogSongs") == 5_000)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM pagedCatalogHierarchy") == 15_000)
        }
        try store.reset(sourceID: "source", stageSessionID: "session-3", ownerGeneration: 3,
                        replacingStageSessionID: "session-2", scopeFingerprint: "account", catalogRevision: "revision")
        try await observer.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "PRAGMA page_count") == before.0)
            #expect(try Int.fetchOne(db, sql: "PRAGMA freelist_count") == cleared.1)
        }
        print("Catalogue page reuse songs=5000 hierarchy=15000 reusableBytes=\((cleared.1 - before.1) * before.2) fileGrowth=0 cleanup=\(elapsed)")
    }

    @Test("Whole-table reclamation stops clearing shared tables when another source starts")
    func anotherSourceStartingDuringReclamationKeepsItsRows() async throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let store = try PagedSongCatalogStagingStore(path: url.path)
        try store.reset(sourceID: "source", stageSessionID: "old", ownerGeneration: 1,
                        replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "revision")
        let songs = (0..<600).map(makeSong(index:))
        _ = try store.stagePage(sourceID: "source", stageSessionID: "old", scopeFingerprint: "account",
            catalogRevision: "revision", offset: 0, nextOffset: nil, itemIDs: songs.map(\.id), songs: songs,
            metadataInspectedSongIDs: [], hierarchyItems: [], addedSongCount: 0)
        let otherSong = makeSong(index: 9_999)
        try await store.discardInBatches(sourceID: "source", stageSessionID: "old") { count in
            guard count > 0, try store.snapshot(sourceID: "other") == nil else { return }
            try store.reset(sourceID: "other", stageSessionID: "new", ownerGeneration: 2,
                            replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "revision")
            _ = try store.stagePage(sourceID: "other", stageSessionID: "new", scopeFingerprint: "account",
                catalogRevision: "revision", offset: 0, nextOffset: nil, itemIDs: [otherSong.id], songs: [otherSong],
                metadataInspectedSongIDs: [], hierarchyItems: [], addedSongCount: 1)
        }
        #expect(try store.snapshot(sourceID: "source") == nil)
        #expect(try store.snapshot(sourceID: "other")?.stageSessionID == "new")
        #expect(try store.delta(sourceID: "other", existingByID: [:]).upserts == [otherSong])
        #expect(try store.stagedItemIDs(sourceID: "other", among: [otherSong.id]) == [otherSong.id])
    }

    @Test("Cancelled cleanup resumes orphan rows without damaging a resumable source")
    func interruptedCleanupResumesInBoundedBatches() async throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let store = try PagedSongCatalogStagingStore(path: url.path)
        let songs = (0..<1_250).map(makeSong(index:))
        for sourceID in ["source", "retained"] {
            try store.reset(sourceID: sourceID, stageSessionID: sourceID, ownerGeneration: 1,
                            replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "revision")
            _ = try store.stagePage(sourceID: sourceID, stageSessionID: sourceID,
                scopeFingerprint: "account", catalogRevision: "revision", offset: 0, nextOffset: nil,
                itemIDs: songs.map(\.id), songs: songs, metadataInspectedSongIDs: [], hierarchyItems: [], addedSongCount: 0)
        }
        do {
            try await store.discardInBatches(sourceID: "source", stageSessionID: "source") { count in
                #expect(count <= 512)
                if count > 0 { throw CancellationError() }
            }
            Issue.record("Cleanup should stop after its first committed batch")
        } catch is CancellationError { }
        #expect(try store.snapshot(sourceID: "source") == nil)
        #expect(try store.stagedSongIDs(sourceID: "source", among: songs.map(\.id)).count == songs.count)
        let reopened = try PagedSongCatalogStagingStore(path: url.path)
        try reopened.releaseOwnershipFromEarlierLaunch()
        _ = try await reopened.discardUnresumableStagesInBatches(keepingStageSessionIDs: ["retained": "retained"]) { count in
            #expect(count <= 512)
        }
        #expect(try reopened.stagedSongIDs(sourceID: "source", among: songs.map(\.id)).isEmpty)
        #expect(try reopened.delta(sourceID: "retained", existingByID: [:]).upserts.count == songs.count)
        #expect(try reopened.stagedItemIDs(sourceID: "source", among: songs.map(\.id)).isEmpty)
    }

    @Test("A new catalogue stage wins over an older cleanup between batches")
    func newStageStopsOldCleanup() async throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let store = try PagedSongCatalogStagingStore(path: url.path)
        try store.reset(sourceID: "source", stageSessionID: "old", ownerGeneration: 1,
                        replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "revision")
        let songs = (0..<600).map(makeSong(index:))
        _ = try store.stagePage(sourceID: "source", stageSessionID: "old",
            scopeFingerprint: "account", catalogRevision: "revision", offset: 0, nextOffset: nil,
            itemIDs: songs.map(\.id), songs: songs, metadataInspectedSongIDs: [], hierarchyItems: [], addedSongCount: 0)
        let replacement = makeSong(index: 9_999)
        try await store.discardInBatches(sourceID: "source", stageSessionID: "old") { count in
            guard count > 0 else { return }
            try store.reset(sourceID: "source", stageSessionID: "new", ownerGeneration: 2,
                            replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "revision")
            _ = try store.stagePage(sourceID: "source", stageSessionID: "new",
                scopeFingerprint: "account", catalogRevision: "revision", offset: 0, nextOffset: nil,
                itemIDs: [replacement.id], songs: [replacement], metadataInspectedSongIDs: [], hierarchyItems: [], addedSongCount: 1)
        }
        try await store.discardInBatches(sourceID: "source", stageSessionID: "old")
        #expect(try store.snapshot(sourceID: "source")?.stageSessionID == "new")
        #expect(try store.delta(sourceID: "source", existingByID: [:]).upserts == [replacement])
    }

    @Test("Cancelled reconciliation leaves the durable stage available for retry")
    func cancelledDeltaCanBeRetried() async throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        let store = try PagedSongCatalogStagingStore(path: url.path)
        try store.reset(sourceID: "source", stageSessionID: "cancelled", ownerGeneration: 1,
                        replacingStageSessionID: nil, scopeFingerprint: "account", catalogRevision: "revision")
        let song = makeSong(index: 1)
        _ = try store.stagePage(sourceID: "source", stageSessionID: "cancelled",
            scopeFingerprint: "account", catalogRevision: "revision", offset: 0, nextOffset: nil,
            itemIDs: [song.id], songs: [song], metadataInspectedSongIDs: [], hierarchyItems: [], addedSongCount: 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try store.delta(sourceID: "source", existingByID: [:])
            }
        }
        await cancelled.value
        #expect(try store.delta(sourceID: "source", existingByID: [:]).upserts == [song])
    }

    @Test("A page and its duplicate receipts commit atomically")
    func duplicatePageRollsBack() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-a",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            let first = makeSong(index: 1)
            let initial = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-a",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: 500,
                itemIDs: ["item-1"],
                songs: [first],
                metadataInspectedSongIDs: [first.id],
                hierarchyItems: [],
                addedSongCount: 1
            )

            #expect(throws: PagedSongCatalogStagingError.duplicateItemID("item-1")) {
                try store.stagePage(
                    sourceID: "source",
                    stageSessionID: "session-a",
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-a",
                    offset: 500,
                    nextOffset: nil,
                    itemIDs: ["item-2", "item-1"],
                    songs: [makeSong(index: 2)],
                    metadataInspectedSongIDs: [],
                    hierarchyItems: [],
                    addedSongCount: 1
                )
            }

            #expect(try store.snapshot(sourceID: "source") == initial)
            let delta = try store.delta(sourceID: "source", existingByID: [:])
            #expect(delta.upserts == [first])
            #expect(delta.authoritativeSongIDs == [first.id])
            #expect(delta.metadataInspectedSongIDs == [first.id])
        }
    }

    @Test("Re-anchoring keeps staged pages and lets the walk read on under a new revision")
    func reanchorKeepsStagedPages() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-a",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            let first = makeSong(index: 1)
            _ = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-a",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: 500,
                itemIDs: ["item-1"],
                songs: [first],
                metadataInspectedSongIDs: [],
                hierarchyItems: [],
                addedSongCount: 1
            )
            #expect(
                try store.stagedItemIDs(sourceID: "source", among: ["item-2", "item-1"])
                    == ["item-1"]
            )

            #expect(throws: PagedSongCatalogStagingError.scopeChanged) {
                try store.reanchor(
                    sourceID: "source",
                    stageSessionID: "stale-session",
                    catalogRevision: "scan-b",
                    nextOffset: 500
                )
            }
            let moved = try store.reanchor(
                sourceID: "source",
                stageSessionID: "session-a",
                catalogRevision: "scan-b",
                nextOffset: 500
            )
            #expect(moved.catalogRevision == "scan-b")
            #expect(moved.nextOffset == 500)
            #expect(moved.stagedItemCount == 1)
            #expect(moved.firstPageItemIDs == ["item-1"])

            // The old revision can no longer stage; the new one reads on.
            #expect(throws: PagedSongCatalogStagingError.revisionChanged) {
                try store.stagePage(
                    sourceID: "source",
                    stageSessionID: "session-a",
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-a",
                    offset: 500,
                    nextOffset: nil,
                    itemIDs: ["item-2"],
                    songs: [makeSong(index: 2)],
                    metadataInspectedSongIDs: [],
                    hierarchyItems: [],
                    addedSongCount: 1
                )
            }
            let second = makeSong(index: 2)
            let finished = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-a",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-b",
                offset: 500,
                nextOffset: nil,
                itemIDs: ["item-2"],
                songs: [second],
                metadataInspectedSongIDs: [],
                hierarchyItems: [],
                addedSongCount: 1
            )
            #expect(finished.nextOffset == nil)
            #expect(finished.stagedItemCount == 2)
            let delta = try store.delta(sourceID: "source", existingByID: [:])
            #expect(delta.authoritativeSongIDs == [first.id, second.id])

            // A walk that grew past its end reopens a finished stage.
            let reopened = try store.reanchor(
                sourceID: "source",
                stageSessionID: "session-a",
                catalogRevision: "scan-c",
                nextOffset: 500
            )
            #expect(reopened.nextOffset == 500)
            #expect(reopened.completedPageCount == 2)
        }
    }

    @Test("A newer scan generation owns reset and stale cancellation cannot erase it")
    func resetUsesGenerationCompareAndSwap() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-a",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-b",
                ownerGeneration: 2,
                replacingStageSessionID: "unknown-session",
                scopeFingerprint: "account-b",
                catalogRevision: "scan-b"
            )

            #expect(throws: PagedSongCatalogStagingError.scopeChanged) {
                try store.reset(
                    sourceID: "source",
                    stageSessionID: "stale-session",
                    ownerGeneration: 1,
                    replacingStageSessionID: "session-a",
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-a"
                )
            }
            let storedSnapshot = try store.snapshot(sourceID: "source")
            let snapshot = try #require(storedSnapshot)
            #expect(snapshot.stageSessionID == "session-b")
            #expect(snapshot.ownerGeneration == 2)
            #expect(snapshot.scopeFingerprint == "account-b")

            try store.discard(sourceID: "source", stageSessionID: "session-a")
            #expect(try store.snapshot(sourceID: "source")?.stageSessionID == "session-b")
            try store.discard(sourceID: "source", stageSessionID: "session-b")
            #expect(try store.snapshot(sourceID: "source") == nil)
        }
    }

    @Test("A stage left by an earlier launch cannot refuse this launch's reset")
    func earlierLaunchOwnershipIsReleased() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-old-launch",
                ownerGeneration: 9,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            // Generations restart at launch: without the release, generation 1
            // with a stale session id is refused by the old owner.
            #expect(throws: PagedSongCatalogStagingError.scopeChanged) {
                try store.reset(
                    sourceID: "source",
                    stageSessionID: "session-new",
                    ownerGeneration: 1,
                    replacingStageSessionID: nil,
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-b"
                )
            }
            try store.releaseOwnershipFromEarlierLaunch()
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-new",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-b"
            )
            #expect(try store.snapshot(sourceID: "source")?.stageSessionID == "session-new")
            #expect(try store.snapshot(sourceID: "source")?.ownerGeneration == 1)
        }
    }

    @Test("Startup cleanup drops only stages no checkpoint can resume")
    func unresumableStagesAreDiscarded() throws {
        try withStore { store in
            for (sourceID, sessionID) in [
                ("resumable", "session-r"),
                ("orphan", "session-o"),
                ("stale", "session-s-old"),
            ] {
                try store.reset(
                    sourceID: sourceID,
                    stageSessionID: sessionID,
                    ownerGeneration: 3,
                    replacingStageSessionID: nil,
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-a"
                )
                _ = try store.stagePage(
                    sourceID: sourceID,
                    stageSessionID: sessionID,
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-a",
                    offset: 0,
                    nextOffset: 500,
                    itemIDs: ["item-\(sourceID)"],
                    songs: [makeSong(index: sourceID.count)],
                    metadataInspectedSongIDs: [],
                    hierarchyItems: [],
                    addedSongCount: 1
                )
            }
            try store.releaseOwnershipFromEarlierLaunch()
            // A scan of this launch already reset its own stage; it is owned
            // and must survive although no startup checkpoint names it.
            try store.reset(
                sourceID: "claimed",
                stageSessionID: "session-c",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )

            let discarded = try store.discardUnresumableStages(keepingStageSessionIDs: [
                "resumable": "session-r",
                "stale": "session-s-new",
            ])

            #expect(discarded == ["orphan", "stale"])
            #expect(try store.snapshot(sourceID: "resumable")?.stagedItemCount == 1)
            #expect(try store.snapshot(sourceID: "claimed") != nil)
            #expect(try store.snapshot(sourceID: "orphan") == nil)
            #expect(try store.snapshot(sourceID: "stale") == nil)
            #expect(try store.stagedItemIDs(sourceID: "orphan", among: ["item-orphan"]).isEmpty)
            #expect(try store.stagedItemIDs(sourceID: "resumable", among: ["item-resumable"]) == ["item-resumable"])
        }
    }

    @Test("Staged progress survives reopening the SQLite store")
    func stagedProgressSurvivesColdRestart() throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        do {
            let store = try PagedSongCatalogStagingStore(path: url.path)
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-cold",
                ownerGeneration: 7,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            _ = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-cold",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: 500,
                itemIDs: ["item-1"],
                songs: [makeSong(index: 1)],
                metadataInspectedSongIDs: [],
                hierarchyItems: [],
                addedSongCount: 1
            )
        }

        let reopened = try PagedSongCatalogStagingStore(path: url.path)
        let storedSnapshot = try reopened.snapshot(sourceID: "source")
        let snapshot = try #require(storedSnapshot)
        #expect(snapshot.stageSessionID == "session-cold")
        #expect(snapshot.ownerGeneration == 7)
        #expect(snapshot.nextOffset == 500)
        #expect(snapshot.stagedSongCount == 1)
        #expect(try reopened.delta(sourceID: "source", existingByID: [:]).upserts.count == 1)
    }

    @Test("Delta emits only changed rows and keeps a complete authoritative ID set")
    func deltaIsIncrementalAndAuthoritative() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-a",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            let unchanged = makeSong(index: 1)
            let added = makeSong(index: 2)
            _ = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-a",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: nil,
                itemIDs: ["item-1", "item-2"],
                songs: [unchanged, added],
                metadataInspectedSongIDs: [added.id],
                hierarchyItems: [],
                addedSongCount: 1
            )
            let removed = makeSong(index: 3)

            let delta = try store.delta(
                sourceID: "source",
                existingByID: [unchanged.id: unchanged, removed.id: removed]
            )

            #expect(delta.upserts == [added])
            #expect(delta.authoritativeSongIDs == [unchanged.id, added.id])
            #expect(!delta.authoritativeSongIDs.contains(removed.id))
            #expect(delta.metadataInspectedSongIDs == [added.id])
        }
    }

    @Test("Fractional server mtimes preserve local enrichment across staging")
    func fractionalModificationDateRoundTripsLosslessly() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-fractional",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a"
            )
            var existing = makeSong(index: 1)
            existing.lastModified = Date(timeIntervalSince1970: 1_700_000_000.123_456)
            existing.lyricsText = "device lyrics"
            existing.replayGainTrackGain = -7.25
            var incoming = existing
            incoming.lyricsText = nil
            incoming.replayGainTrackGain = nil
            _ = try store.stagePage(
                sourceID: "source",
                stageSessionID: "session-fractional",
                scopeFingerprint: "account-a",
                catalogRevision: "scan-a",
                offset: 0,
                nextOffset: nil,
                itemIDs: ["item-1"],
                songs: [incoming],
                metadataInspectedSongIDs: [],
                hierarchyItems: [],
                addedSongCount: 0
            )

            let delta = try store.delta(
                sourceID: "source",
                existingByID: [existing.id: existing]
            )
            #expect(delta.upserts.isEmpty)
            #expect(delta.authoritativeSongIDs == [existing.id])
        }
    }

    @Test("Fifty thousand staged songs stay bounded and keyset-linear")
    func fiftyThousandSongDeltaStaysLinear() throws {
        try withStore { store in
            try store.reset(
                sourceID: "source",
                stageSessionID: "session-large",
                ownerGeneration: 1,
                replacingStageSessionID: nil,
                scopeFingerprint: "account-a",
                catalogRevision: "scan-large"
            )
            var existing: [String: Song] = [:]
            existing.reserveCapacity(50_000)
            let clock = ContinuousClock()
            let start = clock.now
            for pageStart in stride(from: 0, to: 50_000, by: 500) {
                let songs = (pageStart..<pageStart + 500).map(makeSong(index:))
                for song in songs { existing[song.id] = song }
                _ = try store.stagePage(
                    sourceID: "source",
                    stageSessionID: "session-large",
                    scopeFingerprint: "account-a",
                    catalogRevision: "scan-large",
                    offset: pageStart,
                    nextOffset: pageStart + 500 < 50_000 ? pageStart + 500 : nil,
                    itemIDs: songs.map { "item-\($0.id)" },
                    songs: songs,
                    metadataInspectedSongIDs: [],
                    hierarchyItems: [],
                    addedSongCount: 0
                )
            }

            let delta = try store.delta(
                sourceID: "source",
                existingByID: existing,
                batchSize: 500
            )
            #expect(delta.upserts.isEmpty)
            #expect(delta.authoritativeSongIDs.count == 50_000)
            #expect(start.duration(to: clock.now) < .seconds(30))
        }
    }

    private func withStore(
        _ body: (PagedSongCatalogStagingStore) throws -> Void
    ) throws {
        let url = temporaryStoreURL()
        defer { removeStoreFiles(at: url) }
        try body(PagedSongCatalogStagingStore(path: url.path))
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-paged-catalog-\(UUID().uuidString).sqlite")
    }

    private func removeStoreFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
    }

    private func makeSong(index: Int) -> Song {
        Song(
            id: "song-\(index)",
            title: "Song \(index)",
            duration: 180,
            fileFormat: .mp3,
            filePath: "/Music/song-\(index).mp3",
            sourceID: "source",
            fileSize: 1_024,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            revision: "r1"
        )
    }
}

struct SubsonicAlbumCatalogStoreTests {
    private let album = ServerCatalogAlbumMetadata(id: "album", artist: "Various Artists", created: Date(timeIntervalSince1970: 100), libraryID: "2")

    @Test func resumesPagesAndRejectsLateWriters() throws {
        let store = try SubsonicAlbumCatalogStore(path: ":memory:")
        let now = Date()
        var first = try store.claim(key: "account", revision: "r1", scopes: ["2"], now: now)
        first.offsets["2"] = 1
        first.firstPageIDs["2"] = [album.id]
        try store.savePage(key: "account", checkpoint: first, scope: "2", offset: 0, albums: [album], now: now)
        var second = try store.claim(key: "account", revision: "r1", scopes: ["2"], now: now)
        #expect(second.albums[album.id] == album)
        #expect(second.offsets["2"] == 1)
        first.offsets["2"] = -1
        try store.savePage(key: "account", checkpoint: first, scope: "2", offset: 1, albums: [], now: now)
        second.offsets["2"] = 2
        try store.savePage(key: "account", checkpoint: second, scope: "2", offset: 1, albums: [album], now: now)
        let resumed = try store.claim(key: "account", revision: "r1", scopes: ["2"], now: now)
        #expect(resumed.offsets["2"] == 2)
        #expect(!resumed.isComplete)
    }

    @Test func cacheClaimsDoNotExtendFreshnessAndChangedIdentityCannotReuse() throws {
        for invalidation in ["age", "revision", "scope", "unknown"] {
            let store = try SubsonicAlbumCatalogStore(path: ":memory:")
            let now = Date(timeIntervalSince1970: 10_000)
            var initial = try store.claim(key: "key", revision: "r1", scopes: ["2"], now: now)
            initial.offsets["2"] = -1
            try store.savePage(key: "key", checkpoint: initial, scope: "2", offset: 0, albums: [album], now: now)
            let reusable = try store.claim(key: "key", revision: "r1", scopes: ["2"], now: now.addingTimeInterval(3_500))
            #expect(reusable.isComplete)
            #expect(reusable.albums.count == 1)
            let changed = try store.claim(key: "key", revision: invalidation == "unknown" ? nil : invalidation == "revision" ? "r2" : "r1",
                                          scopes: invalidation == "scope" ? ["3"] : ["2"],
                                          now: now.addingTimeInterval(invalidation == "age" ? 3_601 : 3_501))
            #expect(changed.albums.isEmpty)
            #expect(!changed.isComplete)
        }
    }

    @Test func providerIdentitySurvivesLocalAlbumGroupingAndProtectsEdits() throws {
        var song = Song(id: "song", title: "Title", albumID: "local-group", artistName: "Soloist", duration: 1,
                        fileFormat: .mp3, filePath: "/songs/song.mp3", sourceID: "source",
                        serverCatalogAlbum: .init(id: album.id, taggedArtist: nil))
        song = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        let enrichment = ServerCatalogEnrichment(albums: [album.id: album])
        let enriched = enrichment.applying(to: song)
        #expect(enriched.albumArtistName == album.artist)
        #expect(enriched.serverAlbumDateAdded == album.created)
        #expect(enriched.serverLibraryID == "2")
        #expect(enriched.albumID == "local-group")
        song.albumArtistName = "My edit"
        song.userMetadataEditedAt = Date()
        let merged = ServerSongCatalogMergePolicy.merged(existing: song, incoming: enriched)
        #expect(merged.albumArtistName == "My edit")
        #expect(merged.serverAlbumDateAdded == album.created)
        #expect(merged.serverCatalogAlbum == song.serverCatalogAlbum)
    }

    @Test func cachedDateParsingKeepsExistingPrecisionAndOffsets() {
        let parser = SubsonicCatalogDateParser()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        for value in ["2024-01-01T00:00:00.875Z", "2024-01-01T00:00:00.123456Z", "2024-01-01T08:00:00+08:00", "2024-01-01T00:00:00Z", "invalid"] {
            #expect(parser.date(from: value) == (fractional.date(from: value) ?? plain.date(from: value)))
        }
    }
}
