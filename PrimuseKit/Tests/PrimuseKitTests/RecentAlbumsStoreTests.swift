import Foundation
import Testing
@testable import PrimuseKit

@Suite("Recent albums persistence")
struct RecentAlbumsStoreTests {
    @Test("Existing snapshots load without a cover field")
    func legacySnapshot() throws {
        try withDefaults { defaults, _ in
            defaults.set(Data(#"[{"id":"old","title":"旧专辑","artistName":"Artist"}]"#.utf8), forKey: "recentAlbums")
            let album = try #require(RecentAlbumsStore.load(from: defaults).first)
            #expect(album.id == "old")
            #expect(album.title == "旧专辑")
            #expect(album.artistName == "Artist")
            #expect(album.coverImageName == nil)
        }
    }

    @Test("Recording keeps eight most recent albums and refreshes duplicates")
    func boundedRecency() throws {
        try withDefaults { defaults, _ in
            for index in 0..<10 {
                RecentAlbumsStore.record(entry("\(index)"), in: defaults)
            }
            #expect(RecentAlbumsStore.load(from: defaults).map(\.id) == ["9", "8", "7", "6", "5", "4", "3", "2"])

            RecentAlbumsStore.record(
                RecentAlbumEntry(id: "4", title: "Updated", artistName: "New artist", coverImageName: "new.png"),
                in: defaults
            )
            let albums = RecentAlbumsStore.load(from: defaults)
            #expect(albums.map(\.id) == ["4", "9", "8", "7", "6", "5", "3", "2"])
            #expect(albums.first?.title == "Updated")
            #expect(albums.first?.artistName == "New artist")
            #expect(albums.first?.coverImageName == "new.png")
        }
    }

    @Test("Concurrent app writers preserve every album across defaults instances")
    func concurrentWriters() throws {
        try withDefaults { defaults, suite in
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                let writer = UserDefaults(suiteName: suite)
                for _ in 0..<20 {
                    RecentAlbumsStore.record(entry("\(index)"), in: writer)
                    let snapshot = RecentAlbumsStore.load(from: writer)
                    #expect(snapshot.count <= 8)
                    #expect(Set(snapshot.map(\.id)).count == snapshot.count)
                }
            }
            let albums = RecentAlbumsStore.load(from: defaults)
            #expect(albums.count == 8)
            #expect(Set(albums.map(\.id)) == Set((0..<8).map(String.init)))
        }
    }

    @Test("A separate reader observes published snapshots and clearing")
    func sharedSnapshot() throws {
        try withDefaults { writer, suite in
            let reader = try #require(UserDefaults(suiteName: suite))
            RecentAlbumsStore.record(entry("first"), in: writer)
            let data = try #require(reader.data(forKey: "recentAlbums"))
            #expect(try JSONDecoder().decode([RecentAlbumEntry].self, from: data).map(\.id) == ["first"])

            RecentAlbumsStore.clear(in: writer)
            #expect(reader.data(forKey: "recentAlbums") == nil)
            #expect(RecentAlbumsStore.load(from: reader).isEmpty)
            RecentAlbumsStore.record(entry("next"), in: writer)
            #expect(RecentAlbumsStore.load(from: reader).map(\.id) == ["next"])
        }
    }

    @Test("A corrupt snapshot can recover on the next recording")
    func corruptSnapshot() throws {
        try withDefaults { defaults, _ in
            defaults.set(Data("not json".utf8), forKey: "recentAlbums")
            #expect(RecentAlbumsStore.load(from: defaults).isEmpty)
            RecentAlbumsStore.record(entry("recovered"), in: defaults)
            #expect(RecentAlbumsStore.load(from: defaults).map(\.id) == ["recovered"])
        }
    }

    private func entry(_ id: String) -> RecentAlbumEntry {
        RecentAlbumEntry(id: id, title: "Album \(id)", artistName: "Artist", coverImageName: nil)
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "RecentAlbumsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }
}
