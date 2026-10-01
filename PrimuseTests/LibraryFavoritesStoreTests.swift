import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class LibraryFavoritesStoreTests: XCTestCase {
    private func makeStore(_ url: URL) -> LibraryFavoritesStore {
        LibraryFavoritesStore(fileURL: url)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFavorites-\(UUID().uuidString).json")
    }

    func testTogglingAnAlbumPostsAChangeAndSurvivesAReload() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore(url)
        let album = Album(id: "a1", title: "Fantasy", artistName: "Jay Chou")
        let posted = expectation(forNotification: .primuseLibraryFavoritesDidChange, object: nil) { note in
            (note.userInfo?["ids"] as? [String]) == [store.favoriteID(for: album)]
                && note.userInfo?["origin"] == nil
        }
        store.toggle(album)
        wait(for: [posted], timeout: 1)
        XCTAssertTrue(store.isLiked(album))
        XCTAssertTrue(store.hasLikedAlbums)
        XCTAssertFalse(store.hasLikedArtists)

        let reloaded = makeStore(url)
        XCTAssertTrue(reloaded.isLiked(album))
        // Same name, different case and a new album id: still the same favorite.
        XCTAssertTrue(reloaded.isLiked(Album(id: "a2", title: "fantasy", artistName: "JAY CHOU")))

        reloaded.toggle(album)
        XCTAssertFalse(reloaded.isLiked(album))
        XCTAssertEqual(reloaded.allEntriesIncludingDeleted.count, 1, "unliking keeps a tombstone for iCloud")
    }

    func testRemoteChangesNeverOverrideANewerLocalEdit() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore(url)
        store.setLiked(true, artistNamed: "Adele")
        let id = store.favoriteID(forArtistNamed: "Adele")
        let local = try! XCTUnwrap(store.entry(id: id))

        let staleTombstone = LibraryFavorite(
            kind: .artist, albumTitle: "", artistName: "Adele",
            likedAt: local.likedAt, modifiedAt: local.modifiedAt.addingTimeInterval(-60),
            deletedAt: local.modifiedAt.addingTimeInterval(-60)
        )
        let remoteNote = expectation(forNotification: .primuseLibraryFavoritesDidChange, object: nil)
        remoteNote.isInverted = true
        store.applyRemote(staleTombstone)
        wait(for: [remoteNote], timeout: 0.2)
        XCTAssertTrue(store.isLiked(artistNamed: "Adele"))

        let freshTombstone = LibraryFavorite(
            kind: .artist, albumTitle: "", artistName: "Adele",
            likedAt: local.likedAt, modifiedAt: local.modifiedAt.addingTimeInterval(60),
            deletedAt: local.modifiedAt.addingTimeInterval(60)
        )
        let applied = expectation(forNotification: .primuseLibraryFavoritesDidChange, object: nil) { note in
            note.userInfo?["origin"] as? String == "remote"
        }
        store.applyRemote(freshTombstone)
        wait(for: [applied], timeout: 1)
        XCTAssertFalse(store.isLiked(artistNamed: "Adele"))

        store.removeRemote(id: id)
        XCTAssertNil(store.entry(id: id))
    }

    func testLikedAlbumsAreNewestFirstAndSkipAlbumsNotInTheLibrary() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore(url)
        let first = Album(id: "1", title: "First", artistName: "A")
        let second = Album(id: "2", title: "Second", artistName: "B")
        let missing = Album(id: "3", title: "Missing", artistName: "C")
        store.setLiked(true, album: first)
        store.setLiked(true, album: missing)
        Thread.sleep(forTimeInterval: 0.01)
        store.setLiked(true, album: second)
        XCTAssertEqual(store.likedAlbums(in: [first, second]).map(\.id), ["2", "1"])

        let pruned = store.pruneTombstones(before: Date().addingTimeInterval(60))
        XCTAssertTrue(pruned.isEmpty, "only unliked entries are pruned")
        store.setLiked(false, album: missing)
        XCTAssertEqual(store.pruneTombstones(before: Date().addingTimeInterval(60)), [store.favoriteID(for: missing)])
    }
}
