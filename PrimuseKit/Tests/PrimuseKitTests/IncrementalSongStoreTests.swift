import Foundation
import Testing
@testable import PrimuseKit

@Suite("Incremental song persistence")
struct IncrementalSongStoreTests {
    @Test("Fresh and authoritative empty stores remain distinct")
    func emptyAuthority() throws {
        try withStore { store in
            #expect(try store.isAuthoritative() == false)
            try store.replaceAll(with: [])
            #expect(try store.isAuthoritative() == true)
            #expect(try store.loadSongs().isEmpty)
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
        }
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
