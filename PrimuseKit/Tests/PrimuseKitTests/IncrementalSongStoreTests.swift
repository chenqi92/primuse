import Foundation
import Testing
@testable import PrimuseKit

@Suite("Incremental song persistence")
struct IncrementalSongStoreTests {
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

    @Test("Encoding failure leaves the previous transaction intact")
    func atomicEncodingFailure() throws {
        try withStore { store in
            let original = makeSong(id: "first", path: "/a.mp3", title: "Stable")
            try store.replaceAll(with: [original])
            var invalid = original
            invalid.duration = .nan

            #expect(throws: (any Error).self) {
                try store.apply(upserts: [invalid])
            }
            #expect(try store.loadSongs() == [original])
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
