import Foundation
import PrimuseKit
import XCTest
#if os(iOS)
import SwiftUI
import UIKit
import Observation
#endif
@testable import Primuse

@MainActor
final class LibraryFavoritesStoreTests: XCTestCase {
    func testFavoriteArtistCandidatesFollowSameCountReplacementsAndAlbumArtists() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoriteArtists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        await library.whenReady()
        var song = Song(id: "song", title: "Track", albumTitle: "Album", artistName: "Singer",
                        albumArtistName: "Band", fileFormat: .mp3, filePath: "/song.mp3", sourceID: "s")
        library.addSongs([song], affectedSourceIDs: ["s"])
        await library.waitForPendingIndex()
        XCTAssertEqual(Set(library.favoriteArtistCandidates.map(\.name)), ["Singer", "Band"])
        XCTAssertEqual(library.favoriteArtistCandidates.count, 2)
        song.artistName = "New Singer"
        song.albumArtistName = "New Band"
        library.replaceSongs([song])
        await library.waitForPendingIndex()
        XCTAssertEqual(Set(library.favoriteArtistCandidates.map(\.name)), ["New Singer", "New Band"])
        song.albumArtistName = "New Singer"
        library.replaceSongs([song])
        await library.waitForPendingIndex()
        XCTAssertEqual(library.favoriteArtistCandidates.map(\.name), ["New Singer"])
        _ = await library.persistNowAndWait()
    }

    func testRestoringLikedCollectionPreservesSongsAndOtherCollections() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FavoriteCollectionRestore-\(UUID().uuidString)")
        let suite = "FavoriteCollectionRestore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        let songs = (1...25).map {
            Song(id: "song-\($0)", title: "Song \($0)", fileFormat: .mp3,
                 filePath: "/items/\($0).mp3", sourceID: "emby-source")
        }
        library.addSongs(songs, affectedSourceIDs: ["emby-source"])
        library.ensurePlaylist(id: MusicLibrary.likedSongsPlaylistID, name: "Liked")
        library.add(songIDs: songs.map(\.id), toPlaylist: MusicLibrary.likedSongsPlaylistID)
        let regular = library.createPlaylist(name: "Existing playlist")
        let otherPin = QuickAccessPinReference(kind: .playlist, itemID: regular.id)
        defaults.set(LibraryPinStorage.encode([otherPin]), forKey: LibraryPinStorage.defaultsKey)
        let collection = FavoriteCollectionStore(
            defaults: defaults,
            favorites: LibraryFavoritesStore(fileURL: directory.appendingPathComponent("favorites.json"))
        )

        XCTAssertFalse(collection.isCollected(FavoriteCollectionStore.anchor, library: library))
        collection.restoreDefaultEntries(library: library)
        collection.restoreDefaultEntries(library: library)
        XCTAssertEqual(collection.references(library: library), [FavoriteCollectionStore.anchor, otherPin])
        XCTAssertTrue(songs.allSatisfy { library.isLiked(songID: $0.id) })
        collection.uncollect(FavoriteCollectionStore.anchor, library: library)
        XCTAssertFalse(collection.isCollected(FavoriteCollectionStore.anchor, library: library))
        XCTAssertTrue(songs.allSatisfy { library.isLiked(songID: $0.id) })
        collection.restoreDefaultEntries(library: library)
        XCTAssertEqual(collection.references(library: library), [FavoriteCollectionStore.anchor, otherPin])
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The isolated library did not finish persistence")
        }
    }

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

    func testPreparedFavoriteKeysTrackRenamedMetadataAndNewLikes() async {
        let store = LibraryFavoritesStore(fileURL: nil)
        let album = Album(id: "prewarmed-album", title: "First", artistName: "Singer")
        let artist = Artist(id: "prewarmed-artist", name: "Singer")
        await Task.detached { LibraryFavoritesStore.prepareKeys(albums: [album], artists: [artist]) }.value
        XCTAssertFalse(store.isLiked(album))
        store.setLiked(true, album: album)
        XCTAssertEqual(store.likedAlbums(in: [album]).map(\.id), [album.id])
        var renamed = album
        renamed.title = "Second"
        XCTAssertFalse(store.isLiked(renamed))
        XCTAssertTrue(store.isLiked(album))
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

    func testArtistQueriesKeepFollowingLocalAndRemoteChangesAfterCaching() throws {
        let store = LibraryFavoritesStore(fileURL: nil)
        let artist = Artist(id: "original", name: "Beyoncé")
        let renamed = Artist(id: "normalized", name: "BEYONCE")
        XCTAssertFalse(store.isLiked(artist))
        XCTAssertFalse(store.isLiked(renamed))

        store.toggle(artistNamed: artist.name)
        XCTAssertTrue(store.isLiked(artist))
        XCTAssertTrue(store.isLiked(renamed))
        XCTAssertEqual(store.likedArtists(in: [artist]), [artist])

        store.toggle(artistNamed: renamed.name)
        XCTAssertFalse(store.isLiked(artist))
        XCTAssertFalse(store.isLiked(renamed))

        let local = try XCTUnwrap(store.entry(id: store.favoriteID(for: artist)))
        store.applyRemote(LibraryFavorite(kind: .artist, albumTitle: "", artistName: artist.name,
            likedAt: local.likedAt, modifiedAt: local.modifiedAt.addingTimeInterval(60)))
        XCTAssertTrue(store.isLiked(artist))
        XCTAssertTrue(store.isLiked(renamed))
        store.removeRemote(id: local.id)
        XCTAssertFalse(store.isLiked(artist))
        XCTAssertFalse(store.isLiked(renamed))
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

#if os(iOS) && DEBUG
@MainActor
final class ArtistListNavigationPerformanceTests: XCTestCase {
    func testListNavigationBuildsOnlyNearbyArtistRows() async throws {
        try await verifyNavigation(layout: .list)
    }

    func testGridNavigationBuildsOnlyNearbyArtistRows() async throws {
        try await verifyNavigation(layout: .grid)
    }

    private func verifyNavigation(layout: ArtistLayoutMode) async throws {
        let suite = "ArtistNavigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(layout.rawValue, forKey: ArtistLayoutMode.storageKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        library.addSongs((0..<5_000).map { index in
            Song(id: "navigation-\(index)", title: "Track \(index)", albumTitle: "Album \(index)",
                 artistName: String(format: "Navigation Artist %05d", index), duration: 180,
                 fileFormat: .mp3, filePath: "\(index).mp3", sourceID: suite)
        }, indexMaintenance: .deferredIncremental)
        await library.waitForPendingIndex()
        XCTAssertEqual(library.visibleArtists.count, 5_000)
        let player = AudioPlayerService(library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Browsing must not start playback") })
        let manager = SourceManager(sourcesProvider: { [] })
        let intelligence = MusicIntelligenceService(settingsStore: AISettingsStore(defaults: defaults),
                                                     recommendationReuseDefaults: defaults)
        let radio = RadioStationsStore(storeURL: directory.appendingPathComponent("radio.json"))
        let probe = ArtistNavigationProbe()
        var builtIDs = Set<String>()
        var labelBuilds = 0
        ArtistListRenderDiagnostics.didBuildLabel = { id in
            builtIDs.insert(id)
            labelBuilds += 1
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: ArtistNavigationHarness(probe: probe)
            .environment(library).environment(player).environment(manager).environment(intelligence)
            .environment(radio).environment(ThemeService())
            .environment(\.appNavigationMode, .standard)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .defaultAppStorage(defaults))
        window.rootViewController = host
        window.isHidden = false
        defer {
            ArtistListRenderDiagnostics.didBuildLabel = nil
            window.isHidden = true
            window.rootViewController = nil
            defaults.removePersistentDomain(forName: suite)
        }
        addTeardownBlock { [weak library] in
            if library == nil { try? FileManager.default.removeItem(at: directory) }
        }
        try await Task.sleep(for: .milliseconds(400))
        for visit in 1...2 {
            builtIDs.removeAll()
            labelBuilds = 0
            let start = ContinuousClock.now
            withAnimation { probe.deepLink = .section(.artists) }
            try await waitUntil { probe.activeSection == .artists }
            try await Task.sleep(for: .milliseconds(350))
            print("Artist navigation \(layout.rawValue) visit=\(visit) enter unique=\(builtIDs.count) builds=\(labelBuilds) elapsed=\(start.duration(to: .now))")
            XCTAssertGreaterThan(builtIDs.count, 0)
            XCTAssertLessThan(builtIDs.count, 150, "Entering a 5,000-artist library must not construct every row")
            builtIDs.removeAll()
            labelBuilds = 0
            withAnimation {
                NotificationCenter.default.post(name: LibraryDebugNavigation.notification,
                    object: LibraryDebugNavigation.Request(section: .artists, target: nil))
            }
            try await waitUntil { probe.activeSection == nil }
            try await Task.sleep(for: .milliseconds(350))
            print("Artist navigation \(layout.rawValue) visit=\(visit) return unique=\(builtIDs.count) builds=\(labelBuilds)")
            XCTAssertLessThan(builtIDs.count, 150, "Returning to the hub must not reconstruct offscreen artist rows")
            probe.deepLink = nil
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate(), "Navigation did not reach the expected page")
    }
}

@MainActor @Observable
private final class ArtistNavigationProbe {
    var deepLink: LibraryDeepLink?
    var activeSection: LibrarySection?
}

private struct ArtistNavigationHarness: View {
    @Bindable var probe: ArtistNavigationProbe

    var body: some View {
        LibraryView(deepLink: $probe.deepLink) { probe.activeSection = $0 }
    }
}

@MainActor
final class LibraryFolderNavigationTests: XCTestCase {
    func testOpeningFolderSettlesWithoutRepeatedToolbarUpdates() async throws {
        let suite = "FolderNavigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let browseKey = LibrarySongBrowseModePreference.storageKey
        let previousBrowseMode = UserDefaults.standard.object(forKey: browseKey)
        UserDefaults.standard.set(LibrarySongBrowseMode.folder.rawValue, forKey: browseKey)
        defaults.set(LibrarySongBrowseMode.folder.rawValue, forKey: browseKey)
        defer {
            UserDefaults.standard.set(previousBrowseMode, forKey: browseKey)
            defaults.removePersistentDomain(forName: suite)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        sources.add(MusicSource(id: suite, name: "Music", type: .local,
            extraConfig: MusicSource.encodeScannedDirectories(["/music"], into: nil, type: .local)))
        library.addSongs((0..<693).map { index in
            Song(id: "folder-\(index)", title: "Track \(index)", albumTitle: "Album", artistName: "Artist",
                 trackNumber: index + 1, duration: 180, fileFormat: .mp3,
                 filePath: "/music/Album/\(index).mp3", sourceID: suite)
        })
        await library.waitForPendingIndex()

        let services = AppServices.shared
        let probe = FolderNavigationProbe()
        var folderBuilds = 0
        SongListRenderDiagnostics.didBuildFolder = { _ in folderBuilds += 1 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: FolderNavigationHarness(probe: probe)
            .environment(library).environment(sources).environment(services.playerService)
            .environment(services.sourceManager).environment(services.scanService)
            .environment(services.metadataBackfill).environment(services.scraperService)
            .environment(services.scraperSettingsStore).environment(services.themeService)
            .environment(services.batchRemoval).environment(services.musicIntelligence)
            .environment(services.playbackSettingsStore).environment(services.coverTintProvider)
            .environment(\.appNavigationMode, .standard).defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            SongListRenderDiagnostics.didBuildFolder = nil
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
        }
        addTeardownBlock { [weak library] in
            if library == nil { try? FileManager.default.removeItem(at: directory) }
        }

        try await Task.sleep(for: .milliseconds(400))
        probe.request = SongLibraryLocationRequest(songID: "folder-692")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while folderBuilds == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(folderBuilds, 0, "The request must navigate into the real folder page")
        try await Task.sleep(for: .seconds(1))
        XCTAssertLessThan(folderBuilds, 30, "Opening a folder must let the main run loop settle")
        let settledBuilds = folderBuilds
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThanOrEqual(folderBuilds - settledBuilds, 2,
                                "An untouched sort menu must not keep invalidating the folder page")
    }
}

@MainActor @Observable
private final class FolderNavigationProbe {
    var request: SongLibraryLocationRequest?
}

private struct FolderNavigationHarness: View {
    @Bindable var probe: FolderNavigationProbe

    var body: some View {
        NavigationStack { SongListView(locationRequest: $probe.request) }
    }
}
#endif
