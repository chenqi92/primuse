import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class AISmartPlaylistEngineTests: XCTestCase {
    func testAIPlaylistResolvesPortableIdentitiesInGeneratedOrder() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseAISmartPlaylistTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        library.sourceIdentityResolver = { sourceID in
            sourceID == "local-source" ? "shared-account" : nil
        }
        let first = song(id: "local-one", title: "First", path: "/one.flac")
        let second = song(id: "local-two", title: "Second", path: "/two.flac")
        library.addSongs([first, second], affectedSourceIDs: ["local-source"])
        for _ in 0..<100 where library.visibleSongs.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.map(\.id), [first.id, second.id])

        let playlist = SmartPlaylist(
            name: "Generated",
            kind: .ai,
            aiConfiguration: AISmartPlaylistConfiguration(selections: [
                selection(
                    songID: "remote-two",
                    title: "Second",
                    path: "/two.flac",
                    accountID: "shared-account"
                ),
                selection(songID: first.id, title: first.title, path: first.filePath),
                selection(songID: "missing", title: "Missing", path: "/missing.flac"),
                selection(songID: first.id, title: first.title, path: first.filePath),
            ])
        )

        let matches = SmartPlaylistEngine.match(
            playlist,
            in: library,
            history: .shared
        )

        XCTAssertEqual(matches.map(\.id), [second.id, first.id])
    }

    private func song(id: String, title: String, path: String) -> Song {
        Song(
            id: id,
            title: title,
            artistName: "Artist",
            duration: 180,
            fileFormat: .flac,
            filePath: path,
            sourceID: "local-source"
        )
    }

    private func selection(
        songID: String,
        title: String,
        path: String,
        accountID: String? = nil
    ) -> AISmartPlaylistSelection {
        AISmartPlaylistSelection(identity: SongIdentity(
            songID: songID,
            title: title,
            artistName: "Artist",
            duration: 180,
            cloudAccountID: accountID,
            filePath: path
        ))
    }
}
