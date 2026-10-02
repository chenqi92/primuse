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

@MainActor
final class LibraryCollectionRenameTests: XCTestCase {
    private func makeLibrary() async -> (MusicLibrary, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectionRename-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        let songs = ["a", "b"].map { id in
            Song(id: id, title: id, albumTitle: "Old Title", artistName: "Artist",
                 albumArtistName: "Artist", fileFormat: .mp3, filePath: "/\(id).mp3", sourceID: "s")
        }
        library.addSongs(songs, affectedSourceIDs: ["s"])
        await library.waitForPendingIndex()
        return (library, directory)
    }

    func testRenamingAWholeAlbumIsReportedAndTheFavoriteFollows() async throws {
        let (library, directory) = await makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var reported: [MusicLibrary.CollectionRename] = []
        library.collectionRenameHandler = { reported += $0 }
        let renamed = library.songs.map { song -> Song in
            var song = song
            song.albumTitle = "New Title"
            return song
        }
        library.replaceSongs(renamed)
        XCTAssertEqual(reported, [MusicLibrary.CollectionRename(
            kind: .album, fromTitle: "Old Title", fromArtist: "Artist", toTitle: "New Title", toArtist: "Artist"
        )])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameFavorites-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryFavoritesStore(fileURL: url)
        store.setLiked(true, album: Album(id: "old", title: "Old Title", artistName: "Artist"))
        store.applyCollectionRenames(reported)
        XCTAssertTrue(store.isLiked(Album(id: "new", title: "New Title", artistName: "Artist")))
    }

    func testMovingOneSongToAnotherAlbumIsNotARename() async throws {
        let (library, directory) = await makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var reported: [MusicLibrary.CollectionRename] = []
        library.collectionRenameHandler = { reported += $0 }
        var moved = try XCTUnwrap(library.song(id: "a"))
        moved.albumTitle = "Somewhere Else"
        library.replaceSong(moved)
        XCTAssertTrue(reported.isEmpty)
    }
}

@MainActor
final class ServerCollectionFavoriteSyncServiceTests: XCTestCase {
    private func makeFixture() -> (LibraryFavoritesStore, FakeCollectionFavoriteConnector, ServerCollectionFavoriteSyncService, UserDefaults, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectionFavorites-\(UUID().uuidString).json")
        let store = LibraryFavoritesStore(fileURL: url)
        let suite = "CollectionFavoritesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let connector = FakeCollectionFavoriteConnector()
        let source = MusicSource(id: "nav", name: "Navidrome", type: .navidrome)
        let service = ServerCollectionFavoriteSyncService(
            sourcesProvider: { [source] },
            connectorProvider: { _ in connector },
            songProvider: { entry, _ in
                Song(id: "song-\(entry.albumTitle)", title: "T", fileFormat: .mp3,
                     filePath: "/songs/server-song-1.mp3", sourceID: "nav")
            },
            favorites: store,
            defaults: defaults,
            localChangeDelay: .seconds(3600)
        )
        return (store, connector, service, defaults, url)
    }

    func testFirstSyncImportsServerFavoritesWithoutPushingLocalOnes() async throws {
        let (store, connector, service, _, url) = makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        await connector.setFavorites([
            ServerCollectionFavorite(kind: .album, itemID: "al-1", albumTitle: "Fantasy", artistName: "Jay Chou"),
            ServerCollectionFavorite(kind: .artist, itemID: "ar-1", albumTitle: "", artistName: "Adele"),
        ])
        store.setLiked(true, album: Album(id: "x", title: "Local Only", artistName: "Someone"))

        await service.syncAllNow()

        XCTAssertTrue(store.isLiked(Album(id: "y", title: "fantasy", artistName: "jay chou")))
        XCTAssertTrue(store.isLiked(artistNamed: "Adele"))
        let calls = await connector.setCalls
        XCTAssertTrue(calls.isEmpty, "the first sync never pushes existing local likes")
        XCTAssertEqual(service.baseline(for: "nav")?.keys.count, 2)
    }

    func testLocalChangesArePushedAndServerRemovalsComeBack() async throws {
        let (store, connector, service, _, url) = makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        await connector.setFavorites([
            ServerCollectionFavorite(kind: .album, itemID: "al-1", albumTitle: "Fantasy", artistName: "Jay Chou"),
        ])
        await service.syncAllNow()

        try await Task.sleep(for: .milliseconds(20))
        let liked = Album(id: "z", title: "25", artistName: "Adele")
        store.setLiked(true, album: liked)
        await service.syncAllNow()
        var calls = await connector.setCalls
        XCTAssertEqual(calls.last?.itemID, "server-album-of-server-song-1")
        XCTAssertEqual(calls.last?.isFavorite, true)

        // Unstarred in another client.
        let remaining = await connector.favorites.filter { $0.itemID != "al-1" }
        await connector.setFavorites(remaining)
        await service.syncAllNow()
        XCTAssertFalse(store.isLiked(Album(id: "y", title: "Fantasy", artistName: "Jay Chou")))
        XCTAssertTrue(store.isLiked(liked))

        // A failed push is retried on the next pass.
        try await Task.sleep(for: .milliseconds(20))
        store.setLiked(false, album: liked)
        await connector.setFailing(true)
        await service.syncAllNow()
        let stillStarred = await connector.favorites.contains { $0.albumTitle == "25" }
        XCTAssertTrue(stillStarred)
        await connector.setFailing(false)
        await service.syncAllNow()
        calls = await connector.setCalls
        XCTAssertEqual(calls.last?.isFavorite, false)
        let unstarred = await connector.favorites.contains { $0.albumTitle == "25" }
        XCTAssertFalse(unstarred)
    }

    func testALikeMadeWhileAPassIsPushingIsPushedByTheNextPass() async throws {
        let (store, connector, service, _, url) = makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        await service.syncAllNow()

        try await Task.sleep(for: .milliseconds(20))
        store.setLiked(true, album: Album(id: "a", title: "25", artistName: "Adele"))
        let late = Album(id: "b", title: "21", artistName: "Adele")
        await connector.setOnSet { await MainActor.run { store.setLiked(true, album: late) } }
        await service.syncAllNow()
        await connector.setOnSet(nil)
        await service.syncAllNow()

        let calls = await connector.setCalls
        XCTAssertEqual(calls.count, 2, "the like made mid-pass must not be mistaken for an already synced one")
        XCTAssertTrue(calls.allSatisfy(\.isFavorite))
    }
}

private actor FakeCollectionFavoriteConnector: ServerCollectionFavoriteConnector {
    struct SetCall: Equatable {
        let kind: LibraryFavoriteKind
        let itemID: String
        let isFavorite: Bool
    }

    let sourceID = "nav"
    private(set) var favorites: [ServerCollectionFavorite] = []
    private(set) var setCalls: [SetCall] = []
    private var failing = false
    private var onSet: (@Sendable () async -> Void)?

    func setFavorites(_ favorites: [ServerCollectionFavorite]) { self.favorites = favorites }
    func setFailing(_ failing: Bool) { self.failing = failing }
    func setOnSet(_ hook: (@Sendable () async -> Void)?) { onSet = hook }

    func fetchServerCollectionFavorites() async throws -> [ServerCollectionFavorite] { favorites }

    func serverCollectionMembership(songItemID: String) async throws -> ServerCollectionMembership {
        ServerCollectionMembership(
            albumID: "server-album-of-\(songItemID)",
            artists: [ServerArtistReference(id: "server-artist", name: "Adele")]
        )
    }

    func setServerCollectionFavorite(kind: LibraryFavoriteKind, itemID: String, isFavorite: Bool) async throws {
        guard !failing else { throw URLError(.timedOut) }
        await onSet?()
        setCalls.append(SetCall(kind: kind, itemID: itemID, isFavorite: isFavorite))
        if isFavorite {
            favorites.append(ServerCollectionFavorite(kind: kind, itemID: itemID, albumTitle: "25", artistName: "Adele"))
        } else {
            favorites.removeAll { $0.itemID == itemID }
        }
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

