import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class RecentlyDeletedBatchTests: XCTestCase {
    func testBatchPurgeKeepsPlaylistTombstonesAndOnlyRemovesConfirmedSmartPlaylists() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseRecentlyDeletedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let first = library.createPlaylist(name: "First")
        let second = library.createPlaylist(name: "Second")
        let untouched = library.createPlaylist(name: "Untouched")
        library.deletePlaylists(ids: [first.id, second.id])

        let firstSmart = SmartPlaylist(name: "First Smart")
        let secondSmart = SmartPlaylist(name: "Second Smart")
        let untouchedSmart = SmartPlaylist(name: "Untouched Smart")
        library.saveSmartPlaylist(firstSmart)
        library.saveSmartPlaylist(secondSmart)
        library.saveSmartPlaylist(untouchedSmart)
        library.deleteSmartPlaylist(id: firstSmart.id)
        library.deleteSmartPlaylist(id: secondSmart.id)

        let plan = RecentlyDeletedPurgePlan(
            playlistIDs: [first.id, second.id],
            smartPlaylistIDs: [firstSmart.id, secondSmart.id],
            sourceIDs: [],
            scraperConfigurationIDs: []
        )
        library.permanentlyDeletePlaylists(ids: plan.playlistIDs)
        library.permanentlyDeleteSmartPlaylists(ids: plan.smartPlaylistIDs)

        let purgedPlaylists = Dictionary(
            uniqueKeysWithValues: library.allPlaylists.map { ($0.id, $0) }
        )
        XCTAssertTrue(purgedPlaylists[first.id]?.isPurged == true)
        XCTAssertTrue(purgedPlaylists[second.id]?.isPurged == true)
        XCTAssertTrue(purgedPlaylists[untouched.id]?.isDeleted == false)
        XCTAssertFalse(library.recentlyDeletedPlaylists.contains {
            plan.playlistIDs.contains($0.id)
        })
        XCTAssertEqual(library.allSmartPlaylists.map(\.id), [untouchedSmart.id])
        XCTAssertFalse(plan.deletesRemoteMedia)

        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }
    }
}
