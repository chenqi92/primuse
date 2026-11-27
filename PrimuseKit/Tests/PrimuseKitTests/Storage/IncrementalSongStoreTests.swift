import Foundation
import GRDB
import Testing
@testable import PrimuseKit

@Suite("Incremental song persistence")
struct IncrementalSongStoreTests {
    @Test("Unchanged search documents do not rewrite FTS pages; edited terms replace old terms")
    func searchDocumentWriteElision() throws {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE documents USING fts5(title, artist)")
            try LibrarySearchDocumentWriter.update(
                table: "documents", columns: ["title", "artist"], values: ["Original", "Artist"],
                rowID: 1, isNew: true, in: db
            )
        }
        let before = try database.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }
        try database.write { db in
            for _ in 0..<20 {
                try LibrarySearchDocumentWriter.update(
                    table: "documents", columns: ["title", "artist"], values: ["Original", "Artist"],
                    rowID: 1, isNew: false, in: db
                )
            }
        }
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT total_changes()") } == before)
        try database.write { db in
            try LibrarySearchDocumentWriter.update(
                table: "documents", columns: ["title", "artist"], values: ["Updated", "Artist"],
                rowID: 1, isNew: false, in: db
            )
        }
        let matches = try database.read { db in
            [
                try Int.fetchOne(db, sql: "SELECT count(*) FROM documents WHERE documents MATCH 'Original'"),
                try Int.fetchOne(db, sql: "SELECT rowid FROM documents WHERE documents MATCH 'Updated'"),
                try Int.fetchOne(db, sql: "SELECT rowid FROM documents WHERE documents MATCH 'Artist'"),
            ]
        }
        #expect(matches == [0, 1, 1])
    }

    @Test("Stream descriptor fast rejection preserves path extension semantics")
    func streamDescriptorPaths() {
        for path in ["/Music/song.mp3", "/Music/song.STRM", "/Music/song.strm/", "/Music/.strm", "/Music/STRM", "", "/中文/歌曲.strm", "/Music/song.strm?x=1", "/Music/song.strm.flac", "/Music/song.strm.", "/Music/song.strm "] {
            let song = makeSong(id: "extension", path: path, title: "Song")
            #expect(song.isStreamDescriptor == PrimuseConstants.supportedStreamDescriptorExtensions.contains((path as NSString).pathExtension.lowercased()))
        }
    }

    @Test("Fresh and authoritative empty stores remain distinct")
    func emptyAuthority() throws {
        try withStore { store in
            #expect(try store.startupState() == IncrementalSongStoreStartupState(
                isAuthoritative: false,
                contentRevision: 0,
                completedMigrationVersion: 0
            ))
            try store.replaceAll(with: [])
            #expect(try store.isAuthoritative() == true)
            #expect(try store.loadSongs().isEmpty)
            #expect(try store.startupState().contentRevision == 1)
        }
    }

    @Test("Replacement round-trips order and STRM identity")
    func replacementRoundTrip() throws {
        try withStore { store in
            let first = makeSong(id: "first", path: "/Music/first.strm", title: "第一首")
            let second = makeSong(id: "second", path: "/Music/second.flac", title: "Second")
            try store.replaceAll(with: [first, second])

            let loaded = try store.loadSongs()
            #expect(loaded.map(\.id) == ["first", "second"])
            #expect(loaded[0].isStreamDescriptor)
            #expect(loaded[0].title == "第一首")
        }
    }

    @Test("Upserts and deletes commit as one incremental transaction")
    func incrementalApply() throws {
        try withStore { store in
            let first = makeSong(id: "first", path: "/a.mp3", title: "Old")
            let second = makeSong(id: "second", path: "/b.mp3", title: "Keep")
            try store.replaceAll(with: [first, second])

            var changed = first
            changed.title = "New"
            let third = makeSong(id: "third", path: "/c.mp3", title: "Added")
            try store.apply(upserts: [changed, third], deletingIDs: [second.id])

            let loaded = try store.loadSongs()
            #expect(loaded.map(\.id) == ["first", "third"])
            #expect(loaded.first?.title == "New")
            #expect(try store.songCount() == 2)
            #expect(try store.startupState().contentRevision == 2)
        }
    }

    @Test("Renaming an ID keeps the row in place; a taken ID falls back to delete and append")
    func renamingKeepsPosition() throws {
        try withStore { store in
            let first = makeSong(id: "first", path: "/a.mp3", title: "First")
            let second = makeSong(id: "second", path: "/b.mp3", title: "Second")
            let third = makeSong(id: "third", path: "/c.mp3", title: "Third")
            try store.replaceAll(with: [first, second, third])

            // 改标签后身份变了:与 App 一样带着新 id 的整首 upsert、删旧 id、再说明这是改名。
            var renamed = first
            renamed.id = "first-v2"
            renamed.title = "First (edited)"
            try store.apply(upserts: [renamed], deletingIDs: [first.id], renaming: [first.id: renamed.id])
            var loaded = try store.loadSongs()
            #expect(loaded.map(\.id) == ["first-v2", "second", "third"])
            #expect(loaded[0].title == "First (edited)")

            // 只改名、不带新值:负载里的 id 也跟着改。
            try store.apply(upserts: [], renaming: ["second": "second-v2"])
            loaded = try store.loadSongs()
            #expect(loaded.map(\.id) == ["first-v2", "second-v2", "third"])
            #expect(loaded[1].title == "Second")

            // 新 id 已被占:不改名,旧行照常删,新值写到已有那行。
            var merged = loaded[2]
            merged.id = "first-v2"
            try store.apply(upserts: [merged], deletingIDs: ["third"], renaming: ["third": "first-v2"])
            loaded = try store.loadSongs()
            #expect(loaded.map(\.id) == ["first-v2", "second-v2"])
            #expect(loaded[0].title == "Third")
        }
    }

    @Test("Content revisions and launch migration markers are monotonic")
    func startupMetadata() throws {
        try withStore { store in
            let song = makeSong(id: "first", path: "/a.mp3", title: "First")
            let replacementRevision = try store.replaceAll(with: [song])
            #expect(replacementRevision == 1)

            try store.markMigrationCompleted(version: 2)
            try store.markMigrationCompleted(version: 1)
            var state = try store.startupState()
            #expect(state.completedMigrationVersion == 2)

            var changed = song
            changed.title = "Changed"
            let applyRevision = try store.apply(upserts: [changed])
            #expect(applyRevision == 2)
            state = try store.startupState()
            #expect(state.contentRevision == 2)
            #expect(state.completedMigrationVersion == 2)
        }
    }

    @Test("Repeated unchanged batches neither write pages nor advance the durable revision")
    func unchangedBatchesDoNotWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("songs.sqlite").path
        let store = try IncrementalSongStore(path: path)
        let songs = (0..<100).map { makeSong(id: "song-\($0)", path: "/\($0).flac", title: "Song \($0)") }
        let revision = try store.replaceAll(with: songs)
        let observer = try DatabaseQueue(path: path)
        let before = try observer.read { db in
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            return try Int.fetchOne(db, sql: "PRAGMA data_version")
        }
        for _ in 0..<10 {
            #expect(try store.apply(upserts: songs, deletingIDs: ["absent"]) == revision)
        }
        let reopened = try IncrementalSongStore(path: path)
        #expect(try reopened.apply(upserts: songs) == revision)
        #expect(try observer.read { try Int.fetchOne($0, sql: "PRAGMA data_version") } == before)
        #expect(try reopened.loadSongs() == songs)
    }

    @Test("Legacy JSON key ordering does not force a library rewrite")
    func legacyPayloadDoesNotWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("songs.sqlite").path
        let store = try IncrementalSongStore(path: path)
        let song = makeSong(id: "legacy", path: "/legacy.flac", title: "Legacy")
        let revision = try store.replaceAll(with: [song])
        let observer = try DatabaseQueue(path: path)
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        legacyEncoder.outputFormatting = .prettyPrinted
        let legacy = try legacyEncoder.encode(song)
        try observer.write { db in
            try db.execute(sql: "UPDATE librarySongRecords SET payload = ? WHERE id = ?", arguments: [legacy, song.id])
        }
        #expect(try store.apply(upserts: [song]) == revision)
        #expect(try observer.read { try Data.fetchOne($0, sql: "SELECT payload FROM librarySongRecords") } == legacy)
        var changed = song
        changed.title = "Edited"
        #expect(try store.apply(upserts: [changed]) == revision + 1)
        #expect(try store.loadSongs().first?.title == "Edited")
    }

    @Test("A failed SQL transaction rolls back deletes and updates together")
    func sqlFailureIsAtomic() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("songs.sqlite").path
        let store = try IncrementalSongStore(path: path)
        let song = makeSong(id: "original", path: "/original.flac", title: "Original")
        let revision = try store.replaceAll(with: [song])
        let connection = try DatabaseQueue(path: path)
        try connection.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_insert BEFORE INSERT ON librarySongRecords
                BEGIN SELECT RAISE(ABORT, 'test write failure'); END
                """)
        }
        #expect(throws: (any Error).self) {
            try store.apply(upserts: [makeSong(id: "new", path: "/new.flac", title: "New")], deletingIDs: [song.id])
        }
        #expect(try store.loadSongs() == [song])
        #expect(try store.startupState().contentRevision == revision)
    }

    @Test("Encoding failure leaves the previous transaction intact")
    func atomicEncodingFailure() throws {
        try withStore { store in
            let original = makeSong(id: "first", path: "/a.mp3", title: "Stable")
            try store.replaceAll(with: [original])
            var invalid = original
            invalid.duration = .nan
            let inserted = makeSong(id: "inserted", path: "/b.mp3", title: "Inserted")
            #expect(throws: (any Error).self) {
                try store.apply(upserts: [inserted, invalid], deletingIDs: [original.id])
            }
            #expect(try store.loadSongs() == [original])
            #expect(throws: (any Error).self) {
                try store.replaceAll(with: [inserted, invalid], snapshotImportID: "incomplete")
            }
            #expect(try store.loadSongs() == [original])
            #expect(try store.lastSnapshotImportID() == nil)
            #expect(try store.startupState().contentRevision == 1)
        }
    }

    @Test("User metadata protection marker round-trips")
    func userMetadataProtectionRoundTrip() throws {
        try withStore { store in
            var song = makeSong(id: "manual", path: "/manual.mp3", title: "Manual")
            song.userMetadataEditedAt = Date(timeIntervalSince1970: 1_750_000_000)
            try store.replaceAll(with: [song])

            let loaded = try #require(try store.loadSongs().first)
            #expect(loaded.userMetadataEditedAt == song.userMetadataEditedAt)
        }
    }

    @Test("Native multi-artist values round-trip without flattening")
    func sourceArtistNamesRoundTrip() throws {
        try withStore { store in
            var song = makeSong(id: "collaboration", path: "/collaboration.flac", title: "Together")
            song.artistName = "AC/DC / Simon & Garfunkel"
            song.sourceArtistNames = ["AC/DC", "Simon & Garfunkel"]
            try store.replaceAll(with: [song])

            let loaded = try #require(try store.loadSongs().first)
            #expect(loaded.artistName == song.artistName)
            #expect(loaded.sourceArtistNames == ["AC/DC", "Simon & Garfunkel"])
        }
    }

    @Test("Catalog refresh adds, updates and withdraws paths on stored tracks without replacing their identity")
    func serverFilePathRefreshRoundTrip() throws {
        try withStore { store in
            let legacy = makeSong(id: "stable", path: "/songs/id.mp3", title: "Edited")
            try store.replaceAll(with: [legacy])
            var stored = try #require(try store.loadSongs().first)
            #expect(stored.serverFilePath == nil)
            stored.userMetadataEditedAt = Date(timeIntervalSince1970: 1_700_000_000)
            var catalog = legacy
            catalog.title = "Server title"
            for path: String? in ["Albums/First.mp3", "别的目录/Second #1.mp3", nil] {
                catalog.serverFilePath = path
                let updated = ServerSongCatalogMergePolicy.merged(existing: stored, incoming: catalog)
                #expect(!ServerSongCatalogMergePolicy.contentChanged(existing: stored, incoming: updated))
                try store.apply(upserts: [updated], deletingIDs: [])
                stored = try #require(try store.loadSongs().first)
                #expect(stored.id == legacy.id && stored.filePath == legacy.filePath)
                #expect(stored.title == "Edited" && stored.serverFilePath == path)
            }
        }
    }

    @Test("Batched concurrent decoding keeps the stored order across batch boundaries")
    func concurrentDecodingKeepsOrder() throws {
        try withStore { store in
            // 跨两批多一点, 最后一批不满, 每批都会切成多片并行解码。
            let count = IncrementalSongStore.decodeBatchSize * 2 + 37
            let songs = (0..<count).map { index in
                makeSong(id: "song-\(index)", path: "/Music/\(index).flac", title: "第 \(index) 首")
            }
            try store.replaceAll(with: songs)

            let loaded = try store.loadSongs()
            #expect(loaded.map(\.id) == songs.map(\.id))
            #expect(loaded.map(\.title) == songs.map(\.title))
        }
    }

    @Test("Loading shares one copy of each repeated field and keeps every value")
    func loadSharesRepeatedStrings() throws {
        try withStore { store in
            let songs = (0..<300).map { index -> Song in
                var song = makeSong(id: "song-\(index)", path: "/Music/\(index).flac", title: "第 \(index) 首")
                song.sourceID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
                song.albumTitle = "A Fairly Long Album Title \(index % 3)"
                song.artistName = "Some Artist With A Long Name"
                song.albumID = String(repeating: "a", count: 63) + "\(index % 3)"
                song.sourceArtistNames = ["Some Artist With A Long Name", "Guest Artist Name"]
                return song
            }
            try store.replaceAll(with: songs)

            let loaded = try store.loadSongs()
            #expect(loaded == songs)
            // Identity of the UTF-8 buffer; only compared, never read.
            func storage(_ value: String?) -> UnsafeRawPointer? {
                guard let value else { return nil }
                let pointer: UnsafeRawPointer?? = value.utf8.withContiguousStorageIfAvailable {
                    UnsafeRawPointer($0.baseAddress)
                }
                return pointer ?? nil
            }
            #expect(storage(loaded[0].albumTitle) == storage(loaded[3].albumTitle))
            #expect(storage(loaded[0].albumTitle) != storage(loaded[1].albumTitle))
            #expect(storage(loaded[0].artistName) == storage(loaded[299].artistName))
            #expect(storage(loaded[0].sourceID) == storage(loaded[299].sourceID))
            #expect(storage(loaded[0].albumID) == storage(loaded[3].albumID))
        }
    }

    @Test("A corrupt row still fails the load instead of being skipped")
    func concurrentDecodingReportsCorruptRows() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payloads = try (0..<1_000).map { index in
            try encoder.encode(makeSong(id: "song-\(index)", path: "/\(index).mp3", title: "\(index)"))
        }
        payloads[700] = Data("{ not a song".utf8)
        #expect(throws: (any Error).self) {
            try IncrementalSongStore.decodeSongs(payloads)
        }
        payloads[700] = payloads[699]
        #expect(try IncrementalSongStore.decodeSongs(payloads).count == 1_000)
    }

    @Test("Loading reads rows in stored order through an index, without a temporary sort")
    func loadingUsesTheOrderIndex() throws {
        try withStore { store in
            try store.apply(upserts: (0..<20).map { makeSong(id: "song-\($0)", path: "/\($0).mp3", title: "\($0)") })
            let plan = try store.loadSongsQueryPlan().joined(separator: " | ")
            #expect(plan.contains("librarySongRecords_on_orderKey_id"), "\(plan)")
            #expect(!plan.contains("TEMP B-TREE"), "\(plan)")
            #expect(try store.loadSongs().map(\.id) == (0..<20).map { "song-\($0)" })
        }
    }

    @Test("Content tags survive incremental persistence and tag removal")
    func contentMetadataRoundTrip() throws {
        try withStore { store in
            var song = makeSong(id: "tagged", path: "/track.m4a", title: "Track")
            song.contentMetadata = SongContentMetadata(iTunesAdvisory: 4, copyright: "℗ Label", isFileInspectionComplete: true)
            try store.replaceAll(with: [song])
            #expect(try store.loadSongs().first?.contentMetadata == song.contentMetadata)
            song.contentMetadata = SongContentMetadata(isFileInspectionComplete: true)
            try store.apply(upserts: [song], deletingIDs: [])
            let restored = try #require(store.loadSongs().first)
            #expect(restored.contentMetadata == song.contentMetadata)
            #expect(restored.contentMetadata?.isExplicit == false)
        }
    }

    @Test("Launch pages seek past tied keys, skip filtered rows and reject a changed catalogue")
    func launchPageCursor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("songs.sqlite").path
        let store = try IncrementalSongStore(path: path)
        let songs = (0..<641).map { index -> Song in
            var song = makeSong(id: String(format: "%04d", index), path: "/\(index).mp3", title: "Track")
            song.sourceID = index.isMultiple(of: 7) ? "hidden" : "shown"
            return song
        }
        try store.replaceAll(with: songs)
        try store.markMigrationCompleted(version: 10)
        try DatabaseQueue(path: path).write { db in try db.execute(sql: "UPDATE librarySongRecords SET orderKey = 1") }
        func read(_ cursor: IncrementalSongPreviewCursor? = nil, ids: [String] = []) throws -> IncrementalSongPreviewPage {
            try IncrementalSongPageReader.preview(at: path, sources: ["shown"], minimumMigration: 10, ids: ids,
                                                  browseIfMissing: true, after: cursor) { !$0.id.hasSuffix("3") }
        }
        let first = try read()
        let cursor = try #require(first.next)
        let second = try read(cursor)
        let finalCursor = try #require(second.next)
        let last = try read(finalCursor)
        #expect(first.songs.count == 200 && second.songs.count == 200 && last.next == nil)
        #expect((first.songs + second.songs + last.songs).map(\.id) == songs.filter {
            $0.sourceID == "shown" && !$0.id.hasSuffix("3")
        }.map(\.id))
        #expect(try read(ids: ["0640", "0000", "0640", "0003", "missing"]).songs.map(\.id) == ["0640", "0640"])
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: "DROP INDEX librarySongRecords_on_orderKey_id")
        }
        #expect(try read(cursor).songs == second.songs)
        let olderStore = try IncrementalSongPageReader(path: path, sourceIDs: ["shown"])
        #expect(try olderStore.page(at: 0) == Array(songs.filter { $0.sourceID == "shown" }.prefix(200)))
        try store.apply(upserts: [], deletingIDs: ["0640"])
        #expect(throws: IncrementalSongPageError.snapshotChanged) { try read(cursor) }
    }

    private func withStore(_ body: (IncrementalSongStore) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-song-store-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let store = try IncrementalSongStore(path: url.path)
        try body(store)
    }

    @Test("Pages keep canonical order across sources and never decode outside the requested page")
    func boundedPages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("songs.sqlite").path
        let store = try IncrementalSongStore(path: path)
        let songs = (0..<1_003).map { index -> Song in
            var song = makeSong(id: "song-\(index)", path: "/\(index).mp3", title: "Song \(index)")
            song.sourceID = index.isMultiple(of: 2) ? "a" : "b"
            return song
        }
        try store.replaceAll(with: songs)
        let all = try IncrementalSongPageReader(path: path)
        #expect(all.count == songs.count)
        #expect(try all.page(at: 0) == Array(songs.prefix(200)))
        #expect(try all.page(at: 5) == Array(songs.suffix(3)))
        #expect(try all.page(at: 6).isEmpty)
        #expect(throws: IncrementalSongPageError.invalidRange) { try all.page(at: -1) }
        #expect(throws: IncrementalSongPageError.invalidRange) { try all.page(at: Int.max) }
        let filtered = try IncrementalSongPageReader(path: path, sourceIDs: ["b"])
        let expected = songs.filter { $0.sourceID == "b" }
        #expect(filtered.count == expected.count)
        #expect(try filtered.page(at: 1) == Array(expected[200..<400]))
        let requested = Array(songs.reversed().map(\.id)) + ["missing", "song-3"]
        #expect(try filtered.songs(ids: requested) == Array(expected.reversed()) + [songs[3]])
        #expect(try IncrementalSongPageReader(path: path, sourceIDs: []).count == 0)
        #expect(try IncrementalSongPageReader(path: path, sourceIDs: []).songs(ids: requested).isEmpty)
        #expect(try all.queryPlan().allSatisfy { !$0.contains("TEMP B-TREE") })
        #expect(try filtered.queryPlan().allSatisfy { !$0.contains("TEMP B-TREE") })

        let raw = try DatabaseQueue(path: path)
        try raw.write { db in
            try db.execute(sql: "UPDATE librarySongRecords SET payload = ? WHERE id = ?",
                           arguments: [Data("broken".utf8), "song-1002"])
        }
        #expect(try all.page(at: 0).count == 200)
        #expect(try all.songs(ids: ["song-1", "song-900"]) == [songs[1], songs[900]])
        #expect(throws: (any Error).self) { try all.page(at: 5) }
    }

    @Test("A changed canonical revision cannot mix two page snapshots")
    func changedPageSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("songs.sqlite").path
        let store = try IncrementalSongStore(path: path)
        #expect(throws: IncrementalSongPageError.unavailable) { try IncrementalSongPageReader(path: path) }
        var song = makeSong(id: "one", path: "/one.mp3", title: "Old")
        try store.replaceAll(with: [song])
        let reader = try IncrementalSongPageReader(path: path)
        song.title = "New"
        try store.apply(upserts: [song])
        #expect(throws: IncrementalSongPageError.snapshotChanged) { try reader.page(at: 0) }
        #expect(throws: IncrementalSongPageError.snapshotChanged) { try reader.songs(ids: [song.id]) }
        #expect(try IncrementalSongPageReader(path: path).page(at: 0) == [song])
    }

    @Test("Browsing and late page arrivals retain at most three pages")
    func boundedPageWindow() {
        let page = (0..<200).map { makeSong(id: "\($0)", path: "/\($0)", title: "\($0)") }
        var window = SongPageWindow()
        for center in [0, 1, 2, 100, 3_499, 20, 0] {
            window.move(toRow: center * 200)
            for index in window.missingPages(totalCount: 700_000) { window.insert(page, at: index) }
            #expect(window.cachedSongCount <= 600)
            #expect(window.song(at: center * 200) == page.first)
        }
        window.insert(page, at: 3_499)
        #expect(window.song(at: 3_499 * 200) == nil)
        #expect(window.song(at: -1) == nil)
        #expect(window.missingPages(totalCount: 0).isEmpty)
    }

    @Test("SongStringInterner shares long lyricsFileName and revision storage across songs")
    func internsLyricsFileNameAndRevision() {
        let sharedLyrics = String("sha256:0123456789abcdef0123456789abcdef0123456789abcdef.lrc")
        let sharedRevision = String("etag-long-server-revision-token-9876543210")
        var first = makeSong(id: "one", path: "/one.flac", title: "One")
        first.lyricsFileName = String(sharedLyrics.unicodeScalars)
        first.revision = String(sharedRevision.unicodeScalars)
        var second = makeSong(id: "two", path: "/two.flac", title: "Two")
        second.lyricsFileName = String(sharedLyrics.unicodeScalars)
        second.revision = String(sharedRevision.unicodeScalars)

        var interner = SongStringInterner()
        interner.intern(&first)
        interner.intern(&second)

        #expect(first.lyricsFileName == second.lyricsFileName)
        #expect(first.revision == second.revision)
    }

    private func makeSong(id: String, path: String, title: String) -> Song {
        Song(
            id: id,
            title: title,
            duration: 180,
            fileFormat: .mp3,
            filePath: path,
            sourceID: "source",
            fileSize: 1_024,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
