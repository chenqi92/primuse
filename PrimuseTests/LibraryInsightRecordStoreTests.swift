import XCTest
import PrimuseKit
@testable import Primuse

/// 专辑 / 艺人简介存在曲库快照里:落盘、重开、跨设备合并都要保住后改的那份。
@MainActor
final class LibraryInsightRecordStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makeIsolatedStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLibraryInsightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func record(_ summary: String, at offset: TimeInterval, deleted: Bool = false) -> LibraryInsightRecord {
        LibraryInsightRecord(
            id: "album-intro-test",
            kind: .album,
            albumTitle: "First Love",
            artistName: "Utada",
            summary: deleted ? "" : summary,
            tags: deleted ? [] : ["Pop"],
            isUserEdited: true,
            updatedAt: t0.addingTimeInterval(offset),
            deletedAt: deleted ? t0.addingTimeInterval(offset) : nil
        )
    }

    private struct IncomingSnapshot: Encodable {
        var songs: [Song] = []
        var playlists: [Playlist] = []
        var libraryInsights: [LibraryInsightRecord]
    }

    private func incomingData(_ records: [LibraryInsightRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(IncomingSnapshot(libraryInsights: records))
    }

    func testSavedIntroSurvivesAReload() async throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        library.saveLibraryInsightRecord(record("Mine", at: 10))
        XCTAssertEqual(library.libraryInsightRecord(id: "album-intro-test")?.summary, "Mine")
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Snapshot did not persist")
        }
        let reopened = MusicLibrary(storageDirectory: directory)
        XCTAssertEqual(reopened.libraryInsightRecord(id: "album-intro-test")?.summary, "Mine")
        XCTAssertEqual(reopened.libraryInsightRecord(id: "album-intro-test")?.tags, ["Pop"])
    }

    func testAnOlderVersionDoesNotReplaceANewerOne() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        library.saveLibraryInsightRecord(record("Newer", at: 20))
        library.saveLibraryInsightRecord(record("Older", at: 10))
        XCTAssertEqual(library.libraryInsightRecord(id: "album-intro-test")?.summary, "Newer")
    }

    func testADeletedIntroIsNotRevivedByAnotherDevicesOlderCopy() async throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        library.saveLibraryInsightRecord(record("Mine", at: 10))
        library.saveLibraryInsightRecord(record("", at: 20, deleted: true))
        XCTAssertNil(library.libraryInsightRecord(id: "album-intro-test"))
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Snapshot did not persist")
        }
        let localData = try Data(contentsOf: directory.appendingPathComponent("library-cache.json"))

        let stale = try MusicLibrary.mergingSnapshotUserState(
            localData: localData,
            incomingData: try incomingData([record("Stale", at: 15)]),
            locallyRetainedSongIDs: []
        )
        let staleDirectory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: staleDirectory) }
        try stale.write(to: staleDirectory.appendingPathComponent("library-cache.json"))
        XCTAssertNil(MusicLibrary(storageDirectory: staleDirectory).libraryInsightRecord(id: "album-intro-test"))

        let newer = try MusicLibrary.mergingSnapshotUserState(
            localData: localData,
            incomingData: try incomingData([record("Rewritten elsewhere", at: 30)]),
            locallyRetainedSongIDs: []
        )
        let newerDirectory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: newerDirectory) }
        try newer.write(to: newerDirectory.appendingPathComponent("library-cache.json"))
        XCTAssertEqual(
            MusicLibrary(storageDirectory: newerDirectory).libraryInsightRecord(id: "album-intro-test")?.summary,
            "Rewritten elsewhere"
        )
    }
}
