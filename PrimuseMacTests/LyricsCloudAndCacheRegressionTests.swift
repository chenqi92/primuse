import CloudKit
import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class LyricsCacheObserverTests: XCTestCase {
    private func lines(_ text: String) -> [LyricLine] { [.init(timestamp: 2, text: text)] }

    func testLateCacheArrivalUpdatesCurrentSongAndIgnoresOtherSongs() async {
        let center = NotificationCenter()
        var reads: [String] = []
        var received: [[LyricLine]] = []
        let cached = lines("纸船穿过晨雾")
        let observer = LyricsCacheObserver(center: center, load: { id in reads.append(id); return cached })
        defer { observer.stop() }
        observer.select(songID: "current") { _, value in received.append(value) }
        center.post(name: .primuseLyricsDidCache, object: nil, userInfo: ["songID": "other"])
        center.post(name: .primuseLyricsDidCache, object: nil, userInfo: ["songID": "current"])
        await observer.waitForPendingLoad()
        XCTAssertEqual(reads, ["current"])
        XCTAssertEqual(received, [cached])
    }

    func testNewCacheReadWinsOverLateSameSongResult() async {
        let started = expectation(description: "first read started")
        var continuation: CheckedContinuation<[LyricLine]?, Never>?
        var count = 0
        var received: [String] = []
        let fresh = lines("新写好的歌词")
        let observer = LyricsCacheObserver(center: NotificationCenter(), load: { _ in
            count += 1
            if count == 1 {
                return await withCheckedContinuation { continuation = $0; started.fulfill() }
            }
            return fresh
        })
        defer { observer.stop() }
        observer.select(songID: "song") { _, lines in received.append(lines[0].text) }
        let old = observer.cacheChanged(songID: "song")
        await fulfillment(of: [started], timeout: 2)
        await observer.cacheChanged(songID: "song")?.value
        continuation?.resume(returning: lines("已经过时的歌词"))
        await old?.value
        XCTAssertEqual(received, [fresh[0].text])
    }

    func testSongChangeAndManualEditCancelPendingCacheRead() async {
        for manualEdit in [false, true] {
            let center = NotificationCenter()
            let started = expectation(description: "cache read started")
            var continuation: CheckedContinuation<[LyricLine]?, Never>?
            var received = 0
            let observer = LyricsCacheObserver(center: center, load: { _ in
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
            observer.select(songID: "old") { _, _ in received += 1 }
            let task = observer.cacheChanged(songID: "old")
            await fulfillment(of: [started], timeout: 2)
            if manualEdit {
                center.post(name: .primuseLyricsDidChange, object: "old")
            } else {
                observer.select(songID: "new") { _, _ in received += 1 }
            }
            continuation?.resume(returning: lines("不应覆盖的新旧交界"))
            await task?.value
            XCTAssertEqual(received, 0)
            observer.stop()
        }
    }

    func testStoppingObservationAndEmptyCacheDoNotReplaceLyrics() async {
        let center = NotificationCenter()
        var reads = 0
        var received = 0
        let observer = LyricsCacheObserver(center: center, load: { _ in reads += 1; return [] })
        observer.select(songID: "song") { _, _ in received += 1 }
        await observer.cacheChanged(songID: "song")?.value
        observer.stop()
        center.post(name: .primuseLyricsDidCache, object: nil, userInfo: ["songID": "song"])
        await observer.waitForPendingLoad()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(received, 0)
    }
}

@MainActor
final class LyricLineCommentCloudMappingTests: XCTestCase {
    func testPrivateRecordRoundTripAndRejectsMismatchedPayloadIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricLineCommentStore(directory: directory)
        let anchor = LyricLineCommentAnchor(text: "灯火照着纸船", occurrence: 0, timestamp: 2)
        try store.save(songID: "song", anchor: anchor, text: "留给下一次听见")
        let local = try XCTUnwrap(store.syncRecords().first)
        let id = CKRecord.ID(recordName: "LibraryReview/" + local.id, zoneID: CloudKitSyncService.zoneID)
        let record = CKRecord(recordType: "LibraryReview", recordID: id)
        XCTAssertTrue(CloudKitSyncService.populateLyricLineCommentRecord(record, cloudKey: local.id, store: store))
        XCTAssertEqual(CloudKitSyncService.decodedLyricLineComment(record), local)
        XCTAssertEqual(CloudKitSyncService.channel(for: "LibraryReview", id: local.id), .playlists)
        XCTAssertFalse(CloudKitSyncService.recordTypeIsShareable("LibraryReview"))
        let forged = CKRecord(recordType: "LibraryReview", recordID: .init(recordName: "LibraryReview/wrong", zoneID: CloudKitSyncService.zoneID))
        forged["payload"] = record["payload"]
        XCTAssertNil(CloudKitSyncService.decodedLyricLineComment(forged))
        let family = CKRecord(recordType: "LibraryReview", recordID: .init(recordName: id.recordName, zoneID: CloudKitSyncService.familyZoneID))
        family["payload"] = record["payload"]
        XCTAssertNil(CloudKitSyncService.decodedLyricLineComment(family))
        XCTAssertFalse(CloudKitSyncService.populateLyricLineCommentRecord(family, cloudKey: local.id, store: store))

        try store.save(songID: "song", anchor: anchor, text: "")
        XCTAssertTrue(CloudKitSyncService.populateLyricLineCommentRecord(record, cloudKey: local.id, store: store))
        XCTAssertTrue(try XCTUnwrap(CloudKitSyncService.decodedLyricLineComment(record)).comment.isDeleted)
        XCTAssertEqual(record["updatedAt"] as? Date, try store.syncRecord(for: local.id)?.comment.updatedAt)
    }
}
