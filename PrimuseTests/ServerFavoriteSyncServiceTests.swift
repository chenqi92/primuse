import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class ServerFavoriteSyncServiceTests: XCTestCase {
    func testNavidromeStarAndUnstarRoundTripThroughAuthoritativeSnapshots() async {
        let source = makeSource(type: .navidrome)
        let song = makeSong(sourceID: source.id, path: "/songs/song-1.flac")
        let manager = FavoriteManagerFake()
        let library = FavoriteLibraryFake(songs: [song])
        let service = makeService(source: source, manager: manager, library: library)

        library.setLocalLiked(song.id, true)
        service.localLikedStateDidChange(song: song, previous: false, desired: true)
        await service.waitForPendingMutations(sourceID: source.id)

        XCTAssertEqual(manager.setCalls.map(\.itemID), ["song-1"])
        XCTAssertEqual(manager.setCalls.map(\.desired), [true])
        XCTAssertTrue(library.isLiked(songID: song.id))
        XCTAssertTrue(library.errorMessages.isEmpty)

        library.setLocalLiked(song.id, false)
        service.localLikedStateDidChange(song: song, previous: true, desired: false)
        await service.waitForPendingMutations(sourceID: source.id)

        XCTAssertEqual(manager.setCalls.map(\.desired), [true, false])
        XCTAssertFalse(library.isLiked(songID: song.id))
        XCTAssertTrue(library.errorMessages.isEmpty)
    }

    func testRefreshReconcilesOnlySongsOwnedByTheNavidromeSource() async {
        let source = makeSource(type: .navidrome)
        let first = makeSong(sourceID: source.id, path: "/songs/song-1.flac")
        let second = makeSong(sourceID: source.id, path: "/songs/song-2.flac")
        let local = makeSong(sourceID: "local-source", path: "/local/song-3.flac")
        let manager = FavoriteManagerFake()
        manager.serverItemIDs = ["song-2"]
        let library = FavoriteLibraryFake(songs: [first, second, local])
        library.setLocalLiked(first.id, true)
        library.setLocalLiked(local.id, true)
        let service = makeService(source: source, manager: manager, library: library)

        await service.refresh(source: source)

        XCTAssertFalse(library.isLiked(songID: first.id))
        XCTAssertTrue(library.isLiked(songID: second.id))
        XCTAssertTrue(library.isLiked(songID: local.id))
    }

    func testSupportedSourceMatrixPreservesEmbyAndExcludesEveryOtherSource() async {
        for sourceType in MusicSourceType.allCases {
            let source = makeSource(type: sourceType)
            let path = sourceType == .emby ? "/items/item-1.mp3" : "/songs/item-1.mp3"
            let song = makeSong(sourceID: source.id, path: path)
            let manager = FavoriteManagerFake()
            let library = FavoriteLibraryFake(songs: [song])
            let service = makeService(source: source, manager: manager, library: library)

            library.setLocalLiked(song.id, true)
            service.localLikedStateDidChange(song: song, previous: false, desired: true)
            await service.waitForPendingMutations(sourceID: source.id)

            let shouldWrite = ServerFavoriteWritebackPolicy.supports(sourceType)
            XCTAssertEqual(manager.setCalls.count, shouldWrite ? 1 : 0, "Unexpected call for \(sourceType)")
            XCTAssertTrue(library.isLiked(songID: song.id))
        }
    }

    func testMissingRemoteSongIDAndDeletedSourceRollbackWithoutCallingServer() async {
        let malformedSource = makeSource(type: .navidrome)
        let malformedSong = makeSong(sourceID: malformedSource.id, path: "/albums/not-a-song.mp3")
        let malformedManager = FavoriteManagerFake()
        let malformedLibrary = FavoriteLibraryFake(songs: [malformedSong])
        let malformedService = makeService(
            source: malformedSource,
            manager: malformedManager,
            library: malformedLibrary
        )

        malformedLibrary.setLocalLiked(malformedSong.id, true)
        malformedService.localLikedStateDidChange(song: malformedSong, previous: false, desired: true)

        XCTAssertFalse(malformedLibrary.isLiked(songID: malformedSong.id))
        XCTAssertTrue(malformedManager.setCalls.isEmpty)
        XCTAssertEqual(malformedLibrary.errorMessages.count, 1)

        let deletedSource = makeSource(type: .navidrome, isDeleted: true)
        let deletedSong = makeSong(sourceID: deletedSource.id, path: "/songs/deleted-source.mp3")
        let deletedManager = FavoriteManagerFake()
        let deletedLibrary = FavoriteLibraryFake(songs: [deletedSong])
        let deletedService = makeService(
            source: deletedSource,
            manager: deletedManager,
            library: deletedLibrary
        )

        deletedLibrary.setLocalLiked(deletedSong.id, true)
        deletedService.localLikedStateDidChange(song: deletedSong, previous: false, desired: true)

        XCTAssertFalse(deletedLibrary.isLiked(songID: deletedSong.id))
        XCTAssertTrue(deletedManager.setCalls.isEmpty)
        XCTAssertEqual(deletedLibrary.errorMessages.count, 1)
    }

    func testAmbiguousFailureUsesRecoveryReadAndDoesNotRollbackAcceptedWrite() async {
        let source = makeSource(type: .subsonic)
        let song = makeSong(sourceID: source.id, path: "/songs/song-accepted.mp3")
        let manager = FavoriteManagerFake()
        manager.serverItemIDs = ["song-accepted"]
        manager.setError = URLError(.timedOut)
        let library = FavoriteLibraryFake(songs: [song])
        let service = makeService(source: source, manager: manager, library: library)

        library.setLocalLiked(song.id, true)
        service.localLikedStateDidChange(song: song, previous: false, desired: true)
        await service.waitForPendingMutations(sourceID: source.id)

        XCTAssertTrue(library.isLiked(songID: song.id))
        XCTAssertTrue(library.errorMessages.isEmpty)
        XCTAssertEqual(manager.fetchBySourceIDCount, 1)
    }

    func testOfflineTimeoutAuthenticationAndRemovedSourceFailuresRollbackClearly() async {
        let failures: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            SourceError.authenticationFailed,
            SourceError.fileNotFound("Source not found for favorite update"),
            FavoriteTestError.rejected,
        ]

        for (index, failure) in failures.enumerated() {
            let source = makeSource(id: "source-\(index)", type: .navidrome)
            let song = makeSong(sourceID: source.id, path: "/songs/song-\(index).mp3")
            let manager = FavoriteManagerFake()
            manager.setError = failure
            manager.fetchError = failure
            let library = FavoriteLibraryFake(songs: [song])
            let service = makeService(source: source, manager: manager, library: library)

            library.setLocalLiked(song.id, true)
            service.localLikedStateDidChange(song: song, previous: false, desired: true)
            await service.waitForPendingMutations(sourceID: source.id)

            XCTAssertFalse(library.isLiked(songID: song.id), "Failure \(index) did not roll back")
            XCTAssertEqual(library.errorMessages.count, 1, "Failure \(index) was silent")
        }
    }

    func testRapidToggleRollsBackToInitialConfirmedStateWhenBothWritesFail() async {
        let result = await exerciseRapidToggle(firstWriteSucceeds: false)

        XCTAssertEqual(result.calls, [true, false])
        XCTAssertFalse(result.isLiked)
        XCTAssertEqual(result.errorCount, 1)
    }

    func testRapidToggleRollsBackToFirstConfirmedWriteWhenSecondWriteFails() async {
        let result = await exerciseRapidToggle(firstWriteSucceeds: true)

        XCTAssertEqual(result.calls, [true, false])
        XCTAssertTrue(result.isLiked)
        XCTAssertEqual(result.errorCount, 1)
    }

    private func exerciseRapidToggle(
        firstWriteSucceeds: Bool
    ) async -> (calls: [Bool], isLiked: Bool, errorCount: Int) {
        let source = makeSource(type: .navidrome)
        let song = makeSong(sourceID: source.id, path: "/songs/rapid-song.flac")
        let manager = BlockingFavoriteManager(firstWriteSucceeds: firstWriteSucceeds)
        let library = FavoriteLibraryFake(songs: [song])
        let service = makeService(source: source, manager: manager, library: library)

        library.setLocalLiked(song.id, true)
        service.localLikedStateDidChange(song: song, previous: false, desired: true)
        await manager.waitForFirstWrite()

        library.setLocalLiked(song.id, false)
        service.localLikedStateDidChange(song: song, previous: true, desired: false)
        manager.releaseFirstWrite()
        await service.waitForPendingMutations(sourceID: source.id)

        return (manager.setCalls, library.isLiked(songID: song.id), library.errorMessages.count)
    }

    private func makeService(
        source: MusicSource,
        manager: any ServerFavoriteManaging,
        library: FavoriteLibraryFake
    ) -> ServerFavoriteSyncService {
        ServerFavoriteSyncService(
            sourceManager: manager,
            sourcesStore: FavoriteSourcesFake(sources: [source]),
            library: library,
            player: FavoritePublisherFake()
        )
    }

    private func makeSource(
        id: String = UUID().uuidString,
        type: MusicSourceType,
        isDeleted: Bool = false
    ) -> MusicSource {
        MusicSource(
            id: id,
            name: "QA",
            type: type,
            host: "127.0.0.1",
            isDeleted: isDeleted,
            deletedAt: isDeleted ? Date() : nil
        )
    }

    private func makeSong(sourceID: String, path: String) -> Song {
        Song(
            id: "\(sourceID):\(path)",
            title: "QA Song",
            fileFormat: .mp3,
            filePath: path,
            sourceID: sourceID
        )
    }
}

private enum FavoriteTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Favorite mutation rejected" }
}

@MainActor
private final class FavoriteManagerFake: ServerFavoriteManaging {
    struct SetCall {
        let itemID: String
        let desired: Bool
    }

    var serverItemIDs = Set<String>()
    var setError: Error?
    var fetchError: Error?
    private(set) var setCalls: [SetCall] = []
    private(set) var fetchBySourceIDCount = 0

    func fetchServerFavorites(for source: MusicSource) async throws -> ServerFavoriteSnapshot? {
        if let fetchError { throw fetchError }
        return ServerFavoriteSnapshot(itemIDs: Array(serverItemIDs))
    }

    func fetchServerFavorites(sourceID: String) async throws -> ServerFavoriteSnapshot? {
        fetchBySourceIDCount += 1
        if let fetchError { throw fetchError }
        return ServerFavoriteSnapshot(itemIDs: Array(serverItemIDs))
    }

    func setServerFavorite(for song: Song, isFavorite: Bool) async throws -> ServerFavoriteSnapshot? {
        let itemID = ServerPlaylistIdentity.serverItemID(fromFilePath: song.filePath) ?? ""
        setCalls.append(SetCall(itemID: itemID, desired: isFavorite))
        if let setError { throw setError }
        if isFavorite {
            serverItemIDs.insert(itemID)
        } else {
            serverItemIDs.remove(itemID)
        }
        return ServerFavoriteSnapshot(itemIDs: Array(serverItemIDs))
    }
}

@MainActor
private final class BlockingFavoriteManager: ServerFavoriteManaging {
    private let firstWriteSucceeds: Bool
    private var firstWriteStarted = false
    private var firstWriteStartWaiter: CheckedContinuation<Void, Never>?
    private var firstWriteRelease: CheckedContinuation<Void, Never>?
    private var serverItemIDs = Set<String>()
    private(set) var setCalls: [Bool] = []

    init(firstWriteSucceeds: Bool) {
        self.firstWriteSucceeds = firstWriteSucceeds
    }

    func waitForFirstWrite() async {
        if firstWriteStarted { return }
        await withCheckedContinuation { continuation in
            firstWriteStartWaiter = continuation
        }
    }

    func releaseFirstWrite() {
        firstWriteRelease?.resume()
        firstWriteRelease = nil
    }

    func fetchServerFavorites(for source: MusicSource) async throws -> ServerFavoriteSnapshot? {
        throw FavoriteTestError.rejected
    }

    func fetchServerFavorites(sourceID: String) async throws -> ServerFavoriteSnapshot? {
        throw FavoriteTestError.rejected
    }

    func setServerFavorite(for song: Song, isFavorite: Bool) async throws -> ServerFavoriteSnapshot? {
        setCalls.append(isFavorite)
        if setCalls.count == 1 {
            firstWriteStarted = true
            firstWriteStartWaiter?.resume()
            firstWriteStartWaiter = nil
            await withCheckedContinuation { continuation in
                firstWriteRelease = continuation
            }
            if firstWriteSucceeds {
                serverItemIDs.insert("rapid-song")
                return ServerFavoriteSnapshot(itemIDs: Array(serverItemIDs))
            }
        }
        throw FavoriteTestError.rejected
    }
}

@MainActor
private final class FavoriteSourcesFake: ServerFavoriteSourcesProviding {
    private let sourcesByID: [String: MusicSource]

    init(sources: [MusicSource]) {
        sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
    }

    func source(id: String) -> MusicSource? {
        sourcesByID[id]
    }
}

@MainActor
private final class FavoriteLibraryFake: ServerFavoriteLibraryManaging {
    let songs: [Song]
    private var likedSongIDs = Set<String>()
    private(set) var errorMessages: [String] = []

    init(songs: [Song]) {
        self.songs = songs
    }

    func setLocalLiked(_ songID: String, _ isLiked: Bool) {
        if isLiked {
            likedSongIDs.insert(songID)
        } else {
            likedSongIDs.remove(songID)
        }
    }

    func isLiked(songID: String) -> Bool {
        likedSongIDs.contains(songID)
    }

    func setLiked(songID: String, isLiked: Bool, propagatesServerMutation: Bool) {
        setLocalLiked(songID, isLiked)
    }

    func replaceLikedSongs(fromSourceID sourceID: String, with authoritativeSongIDs: [String]) {
        let sourceSongIDs = Set(songs.lazy.filter { $0.sourceID == sourceID }.map(\.id))
        likedSongIDs.subtract(sourceSongIDs)
        likedSongIDs.formUnion(authoritativeSongIDs)
    }

    func presentServerFavoriteError(_ message: String) {
        errorMessages.append(message)
    }
}

@MainActor
private final class FavoritePublisherFake: ServerFavoriteSurfacePublishing {
    func republishNowPlayingSurfaces() {}
}
