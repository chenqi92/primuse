import Foundation
import Testing
@testable import PrimuseKit

@Suite("Snapshot import receipts")
struct SnapshotImportReceiptTests {
    @Test("A receipt commits with the song rows and survives later incremental writes")
    func receiptSurvivesLaterChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IncrementalSongStore(path: directory.appendingPathComponent("songs.sqlite").path)
        let first = Song(id: "first", title: "First", fileFormat: .mp3, filePath: "/first.mp3", sourceID: "source")
        let later = Song(id: "later", title: "Later", fileFormat: .mp3, filePath: "/later.mp3", sourceID: "source")
        try store.replaceAll(with: [first], snapshotImportID: "import-a")
        try store.apply(upserts: [later])
        #expect(try store.lastSnapshotImportID() == "import-a")
        #expect(try Set(store.loadSongs().map(\.id)) == ["first", "later"])
    }

    @Test("A failed replacement cannot acknowledge the incoming import")
    func failedReplacementKeepsOldReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IncrementalSongStore(path: directory.appendingPathComponent("songs.sqlite").path)
        let original = Song(id: "original", title: "Original", fileFormat: .mp3, filePath: "/original.mp3", sourceID: "source")
        let duplicate = Song(id: "duplicate", title: "Duplicate", fileFormat: .mp3, filePath: "/duplicate.mp3", sourceID: "source")
        try store.replaceAll(with: [original], snapshotImportID: "import-a")
        #expect(throws: (any Error).self) {
            try store.replaceAll(with: [duplicate, duplicate], snapshotImportID: "import-b")
        }
        #expect(try store.lastSnapshotImportID() == "import-a")
        #expect(try store.loadSongs().map(\.id) == ["original"])
    }
}
