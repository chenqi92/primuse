import Foundation
import Testing
@testable import PrimuseKit

@MainActor
@Suite("Songs kept only for mirrored playlists")
struct CollectionOnlySongStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("collection-only-songs.json")
    }

    @Test("A replaced entry survives a relaunch")
    func persists() {
        let url = temporaryURL()
        let store = CollectionOnlySongStore(url: url)
        #expect(store.replace(["a", "b"], forSourceID: "apple-music"))

        let reloaded = CollectionOnlySongStore(url: url)
        #expect(reloaded.songIDs == ["a", "b"])
        #expect(reloaded.songIDs(forSourceID: "apple-music") == ["a", "b"])
    }

    @Test("The library is asked to re-split only when the union changes")
    func reportsUnionChanges() {
        let store = CollectionOnlySongStore(url: temporaryURL())
        #expect(store.replace(["a"], forSourceID: "one"))
        #expect(!store.replace(["a"], forSourceID: "one"))
        // Another source listing the same song leaves the union as it was.
        #expect(!store.replace(["a"], forSourceID: "two"))
        #expect(store.replace(["a", "c"], forSourceID: "two"))
        #expect(store.songIDs == ["a", "c"])

        #expect(store.replace([], forSourceID: "two"))
        #expect(store.songIDs == ["a"])
        #expect(store.songIDs(forSourceID: "two").isEmpty)
    }

    @Test("Clearing a source's entry is persisted too")
    func clearingPersists() {
        let url = temporaryURL()
        let store = CollectionOnlySongStore(url: url)
        store.replace(["a"], forSourceID: "apple-music")
        store.replace([], forSourceID: "apple-music")

        #expect(CollectionOnlySongStore(url: url).songIDs.isEmpty)
    }

    @Test("An unreadable file starts empty instead of failing")
    func unreadableFile() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)

        let store = CollectionOnlySongStore(url: url)
        #expect(store.songIDs.isEmpty)
        #expect(store.replace(["a"], forSourceID: "apple-music"))
        #expect(CollectionOnlySongStore(url: url).songIDs == ["a"])
    }
}
