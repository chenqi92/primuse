import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class HomePresentationCacheTests: XCTestCase {
    func testStaleDiskCacheRestoresOnlyCurrentVisibleContent() throws {
        let song = Song(id: "kept", title: "Updated title", fileFormat: .mp3, filePath: "/kept.mp3", sourceID: "source")
        let album = Album(id: "kept-album", title: "Updated album")
        let cached = PersistedHomeSnapshot(
            version: PersistedHomeSnapshot.currentVersion, dayStamp: 20200101,
            visibleSongCount: 99, visibleAlbumCount: 50, visibleArtistCount: 10,
            recentSongIDs: ["removed"], heroSongIDs: ["removed", "kept"],
            recentlyAddedAlbums: [
                PersistedHomeAlbumTile(albumID: "removed-album", artworkSongID: "removed"),
                PersistedHomeAlbumTile(albumID: album.id, artworkSongID: "removed")
            ],
            recommendations: [
                PersistedHomeRecommendation(songID: "removed", score: 100, reasons: []),
                PersistedHomeRecommendation(songID: song.id, score: 80, reasons: [])
            ]
        )
        let restored = try XCTUnwrap(HomeView.rehydrateInitialHomePayload(
            cached, visibleAlbums: [album], songForID: { $0 == song.id ? song : nil }
        ))
        XCTAssertEqual(restored.heroCoverSongs.map(\.id), [song.id])
        XCTAssertEqual(restored.forYouResults.map(\.song.title), ["Updated title"])
        XCTAssertEqual(restored.recentlyAddedAlbums.map(\.album.title), ["Updated album"])
        XCTAssertNil(restored.recentlyAddedAlbums.first?.artworkSong)

        let removedSource = try XCTUnwrap(HomeView.rehydrateInitialHomePayload(
            cached, visibleAlbums: [], songForID: { _ in nil }
        ))
        XCTAssertTrue(removedSource.heroCoverSongs.isEmpty)
        XCTAssertTrue(removedSource.recentlyAddedAlbums.isEmpty)
        XCTAssertTrue(removedSource.forYouResults.isEmpty)
    }

    func testRecommendationSnapshotBuildsOffMainThreadWithVisiblePlayableSeeds() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let playable = Song(id: "playable", title: "Song", fileFormat: .mp3, filePath: "/song.mp3", sourceID: "source")
        let unavailable = Song(id: "unavailable", title: "Unavailable", fileFormat: .mp3, filePath: "", sourceID: "source")
        func entry(_ id: String, daysAgo: Double) -> PlayHistoryStore.Entry {
            PlayHistoryStore.Entry(songID: id, songTitle: id, artistName: "Artist", albumTitle: "Album",
                playedAt: now.addingTimeInterval(-daysAgo * 86_400), listenedSec: 60, sourceID: "source")
        }
        let snapshot = MusicDiscoveryEngine.RecommendationSnapshot(
            songs: [playable, unavailable], recentSongs: [playable, unavailable, playable],
            historyEntries: [entry("playable", daysAgo: 2), entry("removed", daysAgo: 20), entry("future", daysAgo: -1)],
            now: now
        )
        let worker = Task.detached { [snapshot] in
            HomePresentationCacheTests.prepareRecommendationSnapshot(snapshot)
        }
        let result = await worker.value
        XCTAssertFalse(result.1)
        XCTAssertEqual(result.0.songs.map(\.id), [playable.id])
        XCTAssertEqual(result.0.seedIDs, [playable.id])
        XCTAssertEqual(result.0.recentWeekIDs, ["playable"])
        XCTAssertEqual(result.0.recentMonthIDs, ["playable", "removed"])
        XCTAssertTrue(MusicDiscoveryEngine.dailyRecommendations(from: result.0, isCancelled: { true }).isEmpty)
    }

    private nonisolated static func prepareRecommendationSnapshot(
        _ snapshot: MusicDiscoveryEngine.RecommendationSnapshot
    ) -> (MusicDiscoveryEngine.RecommendationInput, Bool) {
        (snapshot.makeInput(), Thread.isMainThread)
    }

    private func signature(
        library: Int = 1, history: Int = 1, pins: String = "",
        recommendations: Bool = true
    ) -> HomeView.HomeSnapshotSignature {
        HomeView.HomeSnapshotSignature(
            libraryRevision: library, playlistRevision: 1, historyRevision: history,
            visibleSongCount: 2, visibleAlbumCount: 1, visibleArtistCount: 1,
            recentSongIDs: ["one"], dayStamp: 20260908,
            localeIdentifier: "zh-Hans_CN", timeZoneIdentifier: "Asia/Shanghai",
            quickAccess: pins, favoritesRevision: 6, showsRecommendations: recommendations
        )
    }

    func testReturningToCompletedHomeReusesSnapshotButSameCountEditsInvalidateIt() {
        let model = HomeView.Model()
        let original = signature()
        model.isPrepared = true
        model.signature = original
        model.highlightsSignature = original
        model.recommendationSignature = original

        XCTAssertFalse(model.needsRefresh(for: signature()))
        XCTAssertTrue(model.needsRefresh(for: signature(library: 2)))
        XCTAssertTrue(model.needsRefresh(for: signature(history: 2)))
        XCTAssertTrue(model.needsRefresh(for: signature(pins: "changed-pins")))
    }

    func testLeavingDuringRefreshDoesNotMakePartialResultsReusable() {
        let model = HomeView.Model()
        let previous = signature(library: 1)
        let current = signature(library: 2)
        model.isPrepared = true
        model.signature = current
        model.highlightsSignature = current
        model.recommendationSignature = previous

        XCTAssertTrue(model.needsRefresh(for: current))
        model.recommendationSignature = current
        XCTAssertFalse(model.needsRefresh(for: current))
    }

    func testHiddenRecommendationsDoNotKeepHomeCachePending() {
        let model = HomeView.Model()
        let current = signature(recommendations: false)
        model.isPrepared = true
        model.signature = current
        model.highlightsSignature = current

        XCTAssertFalse(model.needsRefresh(for: current))
        XCTAssertTrue(model.needsRefresh(for: signature(recommendations: true)))
    }

    func testReturningToFoldersReusesIndexAndCatchesMissedMetadataOrNames() {
        let model = HomeDiscoveryModel()
        let song = Song(
            id: "one", title: "One", fileFormat: .mp3,
            filePath: "/Music/one.mp3", sourceID: "source"
        )
        let source = LibraryFolderSourceDescriptor(
            sourceID: "source", displayName: "Library",
            scanRoots: ["/Music"], pathSemantics: .hierarchical
        )
        let request = HomeDiscoveryModel.Request(
            collection: 1, playlists: 1, hierarchy: 1, names: 0, sources: [source]
        )
        let token = UUID()
        let names = ["source": ["/Music": "Music"]]
        XCTAssertTrue(model.needsRebuild(for: request, metadataToken: token, directoryNames: names))
        model.publish(
            index: LibraryFolderIndexBuilder.build(sources: [source], songs: [song]),
            songs: [song.id: song], covers: [:], request: request,
            metadataToken: token, directoryNames: names
        )
        let publishedRevision = model.revision

        XCTAssertFalse(model.needsRebuild(for: request, metadataToken: token, directoryNames: names))
        model.refreshHistory()
        XCTAssertEqual(model.revision, publishedRevision)
        XCTAssertEqual(model.songsByID[song.id]?.title, "One")
        XCTAssertTrue(model.needsRebuild(for: request, metadataToken: UUID(), directoryNames: names))
        XCTAssertTrue(model.needsRebuild(
            for: request, metadataToken: token,
            directoryNames: ["source": ["/Music": "Renamed"]]
        ))

        var updated = song
        updated.title = "Edited title"
        model.updateMetadata(song: updated)
        let handledToken = UUID()
        model.handledMetadataToken = handledToken
        XCTAssertEqual(model.songsByID[song.id]?.title, "Edited title")
        XCTAssertFalse(model.needsRebuild(for: request, metadataToken: handledToken, directoryNames: names))
    }

    func testFolderRequestIsOnlyReusableAfterSuccessfulPublication() {
        let model = HomeDiscoveryModel()
        let initial = HomeDiscoveryModel.Request(
            collection: 1, playlists: 1, hierarchy: 1, names: 0, sources: []
        )
        let changed = HomeDiscoveryModel.Request(
            collection: 1, playlists: 2, hierarchy: 1, names: 0, sources: []
        )
        let token = UUID()
        model.publish(
            index: LibraryFolderIndexBuilder.build(sources: [], songs: []),
            songs: [:], covers: [:], request: initial,
            metadataToken: token, directoryNames: [:]
        )

        XCTAssertTrue(model.needsRebuild(for: changed, metadataToken: token, directoryNames: [:]))
        XCTAssertFalse(model.needsRebuild(for: initial, metadataToken: token, directoryNames: [:]))
        model.publish(
            index: LibraryFolderIndexBuilder.build(sources: [], songs: []),
            songs: [:], covers: [:], request: changed,
            metadataToken: token, directoryNames: [:]
        )
        XCTAssertFalse(model.needsRebuild(for: changed, metadataToken: token, directoryNames: [:]))
    }
}

@MainActor
final class SourcePlaylistVisibilityTests: XCTestCase {
    private func withLibrary(
        _ verify: (MusicLibrary, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourcePlaylistVisibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([
            Song(id: "remote", title: "Remote", fileFormat: .mp3,
                 filePath: "/songs/remote.mp3", sourceID: "server-a"),
            Song(id: "other", title: "Other", fileFormat: .mp3,
                 filePath: "/songs/other.mp3", sourceID: "server-b"),
        ])
        await library.waitForPendingIndex()
        try await verify(library, directory)
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Isolated playlist library failed to persist")
        }
    }

    @discardableResult
    private func mirror(
        in library: MusicLibrary, sourceID: String = "server-a",
        remoteID: String = "favorites", songs: [String] = ["remote"]
    ) -> String {
        let id = ServerPlaylistIdentity.playlistID(sourceID: sourceID, serverPlaylistID: remoteID)
        library.ensurePlaylist(id: id, name: remoteID)
        library.replaceMirrorPlaylistSongs(playlistID: id, songIDs: songs, coverArtPath: nil)
        return id
    }

    func testDisablingSourceHidesExclusivePlaylistsAndKeepsMixedAndEmptyUserPlaylists() async throws {
        try await withLibrary { library, _ in
            let server = mirror(in: library)
            let emptyServer = mirror(in: library, remoteID: "empty", songs: [])
            let local = library.createPlaylist(name: "Only remote", songIDs: ["remote"])
            let mixed = library.createPlaylist(name: "Mixed", songIDs: ["remote", "other"])
            let empty = library.createPlaylist(name: "Empty")
            let revision = library.playlistCollectionRevision

            library.updateDisabledSourceIDs(["server-a"])

            let visible = Set(library.playlists.map(\.id))
            XCTAssertFalse(visible.contains(server))
            XCTAssertFalse(visible.contains(emptyServer))
            XCTAssertFalse(visible.contains(local.id))
            XCTAssertTrue(visible.contains(mixed.id))
            XCTAssertTrue(visible.contains(empty.id))
            XCTAssertEqual(library.songs(forPlaylist: mixed.id).map(\.id), ["other"])
            XCTAssertEqual(library.rawSongIDs(forPlaylist: mixed.id), ["remote", "other"])
            XCTAssertEqual(library.rawSongIDs(forPlaylist: server), ["remote"])
            XCTAssertTrue(library.hiddenMirrorPlaylists.isEmpty)
            XCTAssertGreaterThan(library.playlistCollectionRevision, revision)

            await library.updateDisabledSourceIDsInBackground([])
            XCTAssertTrue(Set(library.playlists.map(\.id)).isSuperset(of: [server, emptyServer, local.id]))
            XCTAssertEqual(library.songs(forPlaylist: mixed.id).map(\.id), ["remote", "other"])
        }
    }

    func testMixedSourcePlaylistRemainsVisibleEvenWhenBothSourcesAreDisabled() async throws {
        try await withLibrary { library, _ in
            let mixed = library.createPlaylist(name: "Mixed", songIDs: ["remote", "other"])
            let mixedMirror = mirror(in: library, songs: ["other", "remote"])
            library.updateDisabledSourceIDs(["server-a", "server-b"])

            XCTAssertTrue(library.playlists.contains { $0.id == mixed.id })
            XCTAssertTrue(library.playlists.contains { $0.id == mixedMirror })
        }
    }

    func testMembershipAndSongSourceChangesInvalidateVisibilityCache() async throws {
        try await withLibrary { library, _ in
            let playlist = library.createPlaylist(name: "Editable", songIDs: ["remote"])
            library.updateDisabledSourceIDs(["server-a"])
            XCTAssertFalse(library.playlists.contains { $0.id == playlist.id })

            library.add(songIDs: ["other"], toPlaylist: playlist.id)
            XCTAssertTrue(library.playlists.contains { $0.id == playlist.id })

            library.replacePlaylistSongs(playlistID: playlist.id, songIDs: ["remote"])
            XCTAssertFalse(library.playlists.contains { $0.id == playlist.id })

            var moved = try XCTUnwrap(library.song(id: "remote"))
            moved.sourceID = "server-b"
            library.addSongs([moved], pruneMissingSongs: false)
            await library.waitForPendingIndex()
            XCTAssertTrue(library.playlists.contains { $0.id == playlist.id })
        }
    }

    func testBackgroundDisableInvalidatesEmptyMirrorVisibility() async throws {
        try await withLibrary { library, _ in
            let emptyMirror = mirror(in: library, sourceID: "empty-source", songs: [])
            let songRevision = library.visibleSongCollectionRevision
            let playlistRevision = library.playlistCollectionRevision

            await library.updateDisabledSourceIDsInBackground(["empty-source"])

            XCTAssertEqual(library.visibleSongCollectionRevision, songRevision)
            XCTAssertGreaterThan(library.playlistCollectionRevision, playlistRevision)
            XCTAssertFalse(library.playlists.contains { $0.id == emptyMirror })
            library.updateDisabledSourceIDs([])
            XCTAssertTrue(library.playlists.contains { $0.id == emptyMirror })
        }
    }

    func testUnresolvedImportedMembersKeepPlaylistVisible() async throws {
        try await withLibrary { library, _ in
            let pending = PlaylistPendingEntry(title: "Unmatched", artists: ["Artist"], origin: "import")
            let playlist = library.createPlaylist(name: "Imported", members: [.song("remote"), .pending(pending)])
            library.updateDisabledSourceIDs(["server-a"])
            XCTAssertTrue(library.playlists.contains { $0.id == playlist.id })
            XCTAssertEqual(library.pendingEntryCount(forPlaylist: playlist.id), 1)
        }
    }

    func testManualHidingSurvivesServerSyncAndRestoresOnlySelectedSource() async throws {
        try await withLibrary { library, directory in
            let first = mirror(in: library)
            let second = mirror(in: library, sourceID: "server-b", songs: ["other"])
            library.hideMirrorPlaylist(id: first)
            library.hideMirrorPlaylist(id: second)
            let source = MusicSource(id: "server-a", name: "Server", type: .navidrome)
            let snapshot = ServerPlaylistSnapshot(playlists: [
                ServerPlaylist(id: "favorites", name: "Renamed favorites", trackIDs: ["remote"]),
            ])
            _ = ServerPlaylistMirror.apply(snapshot: snapshot, source: source, library: library)
            XCTAssertFalse(library.playlists.contains { $0.id == first })
            XCTAssertEqual(library.rawSongIDs(forPlaylist: first), ["remote"])
            XCTAssertEqual(library.hiddenMirrorPlaylists(forSourceID: "server-a").map(\.playlistID), [first])

            let hidden = try XCTUnwrap(library.hiddenMirrorPlaylists(forSourceID: "server-a").first)
            library.restoreHiddenMirrorPlaylist(hidden)
            XCTAssertTrue(library.playlists.contains { $0.id == first })
            XCTAssertFalse(library.playlists.contains { $0.id == second })
            XCTAssertTrue(library.hiddenMirrorPlaylists(forSourceID: "server-a").isEmpty)
            guard case .success = await library.persistNowAndWait() else {
                return XCTFail("Restore did not persist")
            }

            let reloaded = MusicLibrary(storageDirectory: directory)
            XCTAssertTrue(reloaded.playlists.contains { $0.id == first })
            XCTAssertFalse(reloaded.playlists.contains { $0.id == second })
            XCTAssertEqual(reloaded.hiddenMirrorPlaylists(forSourceID: "server-b").map(\.playlistID), [second])
        }
    }

    func testRestoreWhileDisabledShowsPlaylistAfterSourceIsEnabled() async throws {
        try await withLibrary { library, _ in
            let id = mirror(in: library)
            library.hideMirrorPlaylist(id: id)
            library.updateDisabledSourceIDs(["server-a"])
            let hidden = try XCTUnwrap(library.hiddenMirrorPlaylists(forSourceID: "server-a").first)
            library.restoreHiddenMirrorPlaylist(hidden)
            _ = ServerPlaylistMirror.apply(
                snapshot: ServerPlaylistSnapshot(playlists: [
                    ServerPlaylist(id: "favorites", name: "Favorites", trackIDs: ["remote"]),
                ]),
                source: MusicSource(id: "server-a", name: "Server", type: .navidrome),
                library: library
            )
            XCTAssertFalse(library.playlists.contains { $0.id == id })
            XCTAssertTrue(library.hiddenMirrorPlaylists.isEmpty)

            library.updateDisabledSourceIDs([])
            XCTAssertTrue(library.playlists.contains { $0.id == id })
        }
    }

    func testRestoringPrunedMirrorAllowsNextSyncToShowItAgain() async throws {
        try await withLibrary { library, _ in
            let id = mirror(in: library)
            library.hideMirrorPlaylist(id: id)
            library.prunePlaylists(withIDPrefix: ServerPlaylistIdentity.playlistIDPrefix(sourceID: "server-a"), keepingIDs: [])
            XCTAssertNil(library.playlist(id: id))
            let hidden = try XCTUnwrap(library.hiddenMirrorPlaylists(forSourceID: "server-a").first)
            library.restoreHiddenMirrorPlaylist(hidden)

            _ = ServerPlaylistMirror.apply(
                snapshot: ServerPlaylistSnapshot(playlists: [
                    ServerPlaylist(id: "favorites", name: "Favorites", trackIDs: ["remote"]),
                ]),
                source: MusicSource(id: "server-a", name: "Server", type: .navidrome),
                library: library
            )
            XCTAssertTrue(library.playlists.contains { $0.id == id })
            XCTAssertEqual(library.songs(forPlaylist: id).map(\.id), ["remote"])
        }
    }

    func testColdStartupPreservesDisabledMembershipAndManualRestore() async throws {
        try await withLibrary { library, directory in
            let automatic = mirror(in: library)
            let manual = mirror(in: library, sourceID: "server-b", songs: ["other"])
            library.hideMirrorPlaylist(id: manual)
            let suppression = try XCTUnwrap(library.hiddenMirrorPlaylists.first)
            guard case .success = await library.persistNowAndWait() else {
                return XCTFail("Fixture did not persist")
            }
            let preparing = MusicLibrary.makePreparing(storageDirectory: directory, disabledSourceIDs: ["server-a"])
            preparing.restoreHiddenMirrorPlaylist(suppression)
            let prepared = await MusicLibrary.prepareStartup(disabledSourceIDs: ["server-a"], storageDirectory: directory)
            preparing.publish(prepared)

            XCTAssertFalse(preparing.playlists.contains { $0.id == automatic })
            XCTAssertTrue(preparing.playlists.contains { $0.id == manual })
            XCTAssertEqual(preparing.rawSongIDs(forPlaylist: automatic), ["remote"])
            preparing.updateDisabledSourceIDs([])
            XCTAssertTrue(preparing.playlists.contains { $0.id == automatic })
            guard case .success = await preparing.persistNowAndWait() else {
                return XCTFail("Prepared restore did not persist")
            }
        }
    }

    func testAppleMusicDisableAndManualHidingUseIndependentVisibilityRules() async throws {
        try await withLibrary { library, _ in
            library.updateAppleMusicLibrarySyncEnabled(true)
            library.updateAppleMusicSourceInstalled(true)
            let id = AppleMusicLibraryIdentity.systemPlaylistID
            library.ensurePlaylist(id: id, name: "Apple Music")
            library.updateDisabledSourceIDs([AppleMusicLibraryIdentity.sourceID])
            XCTAssertFalse(library.playlists.contains { $0.id == id })
            library.updateDisabledSourceIDs([])
            XCTAssertTrue(library.playlists.contains { $0.id == id })

            library.hideMirrorPlaylist(id: id)
            let hidden = try XCTUnwrap(library.hiddenMirrorPlaylists(forSourceID: AppleMusicLibraryIdentity.sourceID).first)
            library.updateAppleMusicLibrarySyncEnabled(false)
            library.restoreHiddenMirrorPlaylist(hidden)
            XCTAssertFalse(library.playlists.contains { $0.id == id })
            library.updateAppleMusicLibrarySyncEnabled(true)
            XCTAssertTrue(library.playlists.contains { $0.id == id })
        }
    }
}

@MainActor
final class LibraryPreviewSessionTests: XCTestCase {
    func testSuccessfulSourceSyncAdvancesPreviewInvalidationRevision() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseSourceSyncRevisionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let initialRevision = library.sourceSyncCompletionRevision

        library.sourceSyncDidComplete()

        XCTAssertEqual(library.sourceSyncCompletionRevision, initialRevision + 1)
    }

    func testIdenticalMirrorPlaylistSnapshotDoesNotAdvanceRevision() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseMirrorPlaylistNoopTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let songs = [
            Song(id: "one", title: "One", fileFormat: .mp3, filePath: "/songs/one.mp3", sourceID: "source"),
            Song(id: "two", title: "Two", fileFormat: .mp3, filePath: "/songs/two.mp3", sourceID: "source"),
        ]
        library.addSongs(songs, affectedSourceIDs: ["source"])
        let playlistID = ServerPlaylistIdentity.playlistID(
            sourceID: "source",
            serverPlaylistID: "favorites"
        )
        library.ensurePlaylist(id: playlistID, name: "Favorites")
        library.replaceMirrorPlaylistSongs(
            playlistID: playlistID,
            songIDs: ["one", "two"],
            coverArtPath: "cover-1"
        )
        let revision = library.playlistCollectionRevision
        let updatedAt = try XCTUnwrap(library.playlist(id: playlistID)?.updatedAt)

        library.replaceMirrorPlaylistSongs(
            playlistID: playlistID,
            songIDs: ["one", "two"],
            coverArtPath: "cover-1"
        )

        XCTAssertEqual(library.playlistCollectionRevision, revision)
        XCTAssertEqual(library.playlist(id: playlistID)?.updatedAt, updatedAt)

        library.replaceMirrorPlaylistSongs(
            playlistID: playlistID,
            songIDs: ["two", "one"],
            coverArtPath: "cover-1"
        )
        XCTAssertEqual(library.playlistCollectionRevision, revision + 1)
    }

    func testAppleMusicSnapshotPrunesDeletedPlaylistWithoutDeletingLibrarySongs() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseAppleMusicPlaylistPruneTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let sourceID = AppleMusicLibraryIdentity.sourceID
        let song = Song(
            id: "apple-song",
            title: "Apple Song",
            fileFormat: .aac,
            filePath: "i.apple-song",
            sourceID: sourceID
        )
        library.addSongs([song], affectedSourceIDs: [sourceID])

        let removedPlaylistID = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.removed"
        let retainedPlaylistID = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.retained"
        for (id, name) in [
            (AppleMusicLibraryIdentity.systemPlaylistID, "Apple Music Library"),
            (removedPlaylistID, "Primuse Bulk"),
            (retainedPlaylistID, "Retained"),
        ] {
            library.ensurePlaylist(id: id, name: name)
            library.replaceMirrorPlaylistSongs(
                playlistID: id,
                songIDs: [song.id],
                coverArtPath: nil
            )
        }

        library.prunePlaylists(
            withIDPrefix: AppleMusicLibraryIdentity.userPlaylistIDPrefix,
            keepingIDs: [retainedPlaylistID]
        )

        XCTAssertNil(library.playlist(id: removedPlaylistID))
        XCTAssertNotNil(library.playlist(id: retainedPlaylistID))
        XCTAssertNotNil(library.playlist(id: AppleMusicLibraryIdentity.systemPlaylistID))
        XCTAssertEqual(library.song(id: song.id)?.sourceID, sourceID)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: retainedPlaylistID), [song.id])
        XCTAssertEqual(
            library.rawSongIDs(forPlaylist: AppleMusicLibraryIdentity.systemPlaylistID),
            [song.id]
        )
    }

    func testMergeOnlyServerFallbackPreservesMissingRowsAndLocalEnrichment() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseServerFallbackMergeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        var existing = Song(
            id: "one",
            title: "One",
            albumID: "provider-old",
            artistID: "provider-artist-old",
            albumTitle: "Album",
            artistName: "Artist",
            duration: 180,
            fileFormat: .mp3,
            filePath: "/songs/one.mp3",
            sourceID: "source",
            fileSize: 1_024,
            revision: "r1"
        )
        existing.lyricsText = "local lyrics"
        existing.replayGainTrackGain = -7.25
        let missingFromFallback = Song(
            id: "two",
            title: "Two",
            fileFormat: .mp3,
            filePath: "/songs/two.mp3",
            sourceID: "source"
        )
        library.addSongs([existing, missingFromFallback], affectedSourceIDs: ["source"])
        let locallyEnriched = try XCTUnwrap(library.song(id: existing.id))

        var incoming = existing
        incoming.albumID = "provider-new"
        incoming.artistID = "provider-artist-new"
        incoming.lyricsText = nil
        incoming.replayGainTrackGain = nil
        library.addSongs(
            [incoming],
            affectedSourceIDs: ["source"],
            pruneMissingSongs: false,
            mergeServerCatalogRows: true
        )

        XCTAssertEqual(library.song(id: existing.id), locallyEnriched)
        XCTAssertNotNil(library.song(id: missingFromFallback.id))
    }

    func testProgressiveServerPagesAreVisibleWithoutPruningEarlierRows() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseProgressiveServerPageTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let existing = Song(
            id: "existing",
            title: "Existing",
            fileFormat: .mp3,
            filePath: "/songs/existing.mp3",
            sourceID: "source"
        )
        let firstPage = Song(
            id: "page-one",
            title: "Page One",
            fileFormat: .flac,
            filePath: "/songs/page-one.flac",
            sourceID: "source"
        )
        library.addSongs([existing], affectedSourceIDs: ["source"])

        library.addSongs(
            [firstPage],
            affectedSourceIDs: ["source"],
            notifyRemovals: false,
            pruneMissingSongs: false,
            mergeServerCatalogRows: true
        )
        library.addSongs(
            [firstPage],
            affectedSourceIDs: ["source"],
            notifyRemovals: false,
            pruneMissingSongs: false,
            mergeServerCatalogRows: true
        )

        XCTAssertNotNil(library.song(id: existing.id))
        XCTAssertNotNil(library.song(id: firstPage.id))
        XCTAssertEqual(library.songs.filter { $0.sourceID == "source" }.count, 2)
    }

    func testFormatAndCueReplacementSurvivesBareRowMergeAndPublishesContentChange() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseServerFormatReplacementTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        var existing = Song(
            id: "disc-track",
            title: "Track",
            albumTitle: "Album",
            artistName: "Artist",
            duration: 180,
            fileFormat: .mp3,
            filePath: "/music/disc.mp3",
            sourceID: "source",
            fileSize: 4_096,
            bitRate: 320,
            revision: "r1"
        )
        existing.lyricsText = "device enrichment"
        library.addSongs([existing], affectedSourceIDs: ["source"])

        let contentChanged = expectation(description: "content replacement notification")
        let token = NotificationCenter.default.addObserver(
            forName: .primuseSongContentChanged,
            object: nil,
            queue: nil
        ) { _ in
            contentChanged.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let incoming = Song(
            id: existing.id,
            title: existing.title,
            fileFormat: .flac,
            filePath: "/music/disc.flac",
            sourceID: existing.sourceID,
            fileSize: existing.fileSize,
            cueSheetPath: "/music/disc.cue",
            cueStartTime: 15,
            cueEndTime: 195,
            revision: existing.revision
        )
        library.addSongs(
            [incoming],
            affectedSourceIDs: ["source"],
            mergeServerCatalogRows: true
        )

        XCTAssertEqual(XCTWaiter().wait(for: [contentChanged], timeout: 0), .completed)
        let replaced = try XCTUnwrap(library.song(id: existing.id))
        XCTAssertEqual(replaced.fileFormat, .flac)
        XCTAssertEqual(replaced.cueSheetPath, incoming.cueSheetPath)
        XCTAssertEqual(replaced.cueStartTime, incoming.cueStartTime)
        XCTAssertEqual(replaced.cueEndTime, incoming.cueEndTime)
        XCTAssertNil(replaced.lyricsText)
    }

    func testLargeSourceRemovalPublishesPrecomputedIDsAndRetainsOtherSources() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseLargeSourceRemovalTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let removedSongs = (0..<2_048).map { index in
            Song(
                id: "removed-\(index)",
                title: "Removed \(index)",
                fileFormat: .flac,
                filePath: "/removed/\(index).flac",
                sourceID: "large-source"
            )
        }
        let retainedSongs = (0..<32).map { index in
            Song(
                id: "retained-\(index)",
                title: "Retained \(index)",
                fileFormat: .mp3,
                filePath: "/retained/\(index).mp3",
                sourceID: "other-source"
            )
        }
        library.addSongs(
            removedSongs + retainedSongs,
            affectedSourceIDs: ["large-source", "other-source"]
        )

        let notification = expectation(description: "source-scoped song removal")
        let token = NotificationCenter.default.addObserver(
            forName: .primuseSongsRemoved,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(
                Set((note.userInfo?["sourceIDs"] as? [String]) ?? []),
                ["large-source"]
            )
            XCTAssertEqual(
                (note.userInfo?["songIDs"] as? Set<String>)?.count,
                removedSongs.count
            )
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let removedIDs = await library.removeSongsForSources(["large-source"])

        await fulfillment(of: [notification], timeout: 1)
        XCTAssertEqual(removedIDs.count, removedSongs.count)
        XCTAssertEqual(library.songs.map(\.id), retainedSongs.map(\.id))
        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }
    }
}
