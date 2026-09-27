#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

/// 本机改动台账:同一首歌的记录合并、「挑过候选」不被降级、副本去重与回收。
final class TVMetadataOverrideStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tv-override-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testChosenEntryIsNotDowngradedAndKeepsEarlierCover() async throws {
        let store = TVMetadataOverrideStore(directory: directory)
        let cover = Data([0xFF, 0xD8, 0xFF, 0x01])
        let fields = ScrapedMetadataMergePolicy.Fields(title: "Title", artist: "Artist")
        await store.record(
            songID: "song-1", kind: .chosen, editedAt: Date(timeIntervalSince1970: 100),
            fields: fields, cover: cover, lyrics: nil
        )
        await store.record(
            songID: "song-1", kind: .filledMissing, editedAt: Date(timeIntervalSince1970: 200),
            fields: nil, cover: nil, lyrics: nil
        )

        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.kind, .chosen)
        XCTAssertEqual(entry.fields, fields)
        XCTAssertEqual(entry.editedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(entry.coverFile, TVMetadataOverrideStore.contentName(of: cover))
        let storedCover = await store.coverData(for: entry)
        XCTAssertEqual(storedCover, cover)
    }

    func testEntriesSurviveReloadAndUnreferencedCopiesAreRemoved() async throws {
        let cover = Data([0x89, 0x50, 0x4E, 0x47])
        do {
            let store = TVMetadataOverrideStore(directory: directory)
            await store.record(
                songID: "song-2", kind: .filledMissing, editedAt: Date(timeIntervalSince1970: 10),
                fields: nil, cover: cover, lyrics: nil
            )
        }
        let reloaded = TVMetadataOverrideStore(directory: directory)
        let entries = await reloaded.allEntries()
        XCTAssertEqual(entries.map(\.songID), ["song-2"])

        // 只剩封面的记录丢掉封面后整条删掉,副本文件也跟着回收。
        await reloaded.dropCover(songID: "song-2")
        let remaining = await reloaded.allEntries()
        XCTAssertTrue(remaining.isEmpty)
        let copy = directory
            .appendingPathComponent("tv-metadata-overrides", isDirectory: true)
            .appendingPathComponent(TVMetadataOverrideStore.contentName(of: cover))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }
}
#endif
