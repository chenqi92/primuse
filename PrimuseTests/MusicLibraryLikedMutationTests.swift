import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class MusicLibraryLikedMutationTests: XCTestCase {
    func testBatchLikedMembershipEmitsOnlyActualChangesAndRollbackDoesNotReenter() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLikedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )

        try await exerciseLikedMutations(storageDirectory: storageDirectory)
        try FileManager.default.removeItem(at: storageDirectory)
    }

    private func exerciseLikedMutations(storageDirectory: URL) async throws {
        let library = MusicLibrary(storageDirectory: storageDirectory)
        let songs = [
            makeSong(id: "song-1", path: "/songs/remote-1.mp3"),
            makeSong(id: "song-2", path: "/songs/remote-2.mp3"),
        ]
        library.addSongs(songs, affectedSourceIDs: ["source-1"])
        library.ensurePlaylist(id: MusicLibrary.likedSongsPlaylistID, name: "Liked")
        let regular = library.createPlaylist(name: "Regular")

        var mutations: [(songID: String, previous: Bool, desired: Bool)] = []
        library.likedStateMutationHandler = { song, previous, desired in
            mutations.append((song.id, previous, desired))
        }

        library.add(songIDs: ["song-1", "song-2", "song-1"], toPlaylist: MusicLibrary.likedSongsPlaylistID)
        XCTAssertEqual(mutations.map(\.songID), ["song-1", "song-2"])
        XCTAssertEqual(mutations.map(\.desired), [true, true])

        library.add(songIDs: ["song-1", "song-2"], toPlaylist: MusicLibrary.likedSongsPlaylistID)
        XCTAssertEqual(mutations.count, 2, "Repeated membership must be idempotent")

        library.remove(songIDs: ["song-1", "song-1"], fromPlaylist: MusicLibrary.likedSongsPlaylistID)
        XCTAssertEqual(mutations.map(\.songID), ["song-1", "song-2", "song-1"])
        XCTAssertEqual(mutations.last?.previous, true)
        XCTAssertEqual(mutations.last?.desired, false)

        library.add(songIDs: ["song-1", "song-2"], toPlaylist: regular.id)
        library.remove(songIDs: ["song-1"], fromPlaylist: regular.id)
        XCTAssertEqual(mutations.count, 3, "Ordinary playlists must not trigger server favorites")

        library.setLiked(
            songID: "song-2",
            isLiked: false,
            propagatesServerMutation: false
        )
        XCTAssertEqual(mutations.count, 3, "Recovery changes must not recursively write to the server")

        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }
    }

    private func makeSong(id: String, path: String) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .mp3,
            filePath: path,
            sourceID: "source-1"
        )
    }
}
