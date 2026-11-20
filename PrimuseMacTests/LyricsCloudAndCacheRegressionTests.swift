import CloudKit
import Foundation
import os
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class MacLyricsAssetAvailabilityTests: XCTestCase {
    func testReadingPlaybackStateAndUnsupportedLyricsDoNotProbeAssetPacks() async {
        let probe = expectation(description: "The resource manager stays unused")
        probe.isInverted = true
        let service = LocalLyricsTranslationService(isSupported: true) { _ in
            probe.fulfill()
            return nil
        }
        XCTAssertEqual(service.modelRevision, 0)
        XCTAssertEqual(service.modelState, .notDownloaded)
        let group = LyricTranslationGroup(id: "it", sourceLanguageCode: "it", candidates: [
            .init(id: "line", text: "La luna piega la carta", sourceLanguageCode: "it")
        ])
        let outcome = await service.translate(groups: [group], targetLanguageCode: "de", systemTranslator: nil,
                                              isCurrent: { true }, onTranslation: { _, _ in })
        XCTAssertEqual(outcome.unsupportedGroups, [group])
        await fulfillment(of: [probe], timeout: 0.2)
    }

    func testOfflineRouteDiscoversExistingPacksOnceBeforeRequestingDownload() async {
        let probes = OSAllocatedUnfairLock(initialState: [LocalLyricsTranslationModel.Pack]())
        let service = LocalLyricsTranslationService(isSupported: true) { pack in
            probes.withLock { $0.append(pack) }
            return nil
        }
        let group = LyricTranslationGroup(id: "en", sourceLanguageCode: "en", candidates: [
            .init(id: "line", text: "The paper moon keeps time", sourceLanguageCode: "en")
        ])
        for _ in 0..<2 {
            let outcome = await service.translate(groups: [group], targetLanguageCode: "fa", systemTranslator: nil,
                                                  isCurrent: { true }, onTranslation: { _, _ in })
            XCTAssertEqual(outcome.groupsNeedingModel, [group])
        }
        let lookedUp = probes.withLock { $0 }
        XCTAssertTrue(lookedUp.contains(.persian))
        XCTAssertEqual(Set(lookedUp).count, lookedUp.count)
    }

    func testInterruptedManagerInitializationIsSkippedAndSuccessfulLoadClearsMarker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("current.pending")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: marker)
        XCTAssertNil(BackgroundAssetsPrerequisites.initializeOnce(marker: marker) {
            XCTFail("The same build must not re-enter an interrupted framework initializer")
            return 1
        })
        let upgraded = directory.appendingPathComponent("upgraded.pending")
        XCTAssertEqual(BackgroundAssetsPrerequisites.initializeOnce(marker: upgraded) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: upgraded.path))
            return 2
        }, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: upgraded.path))
    }
}

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
final class EmbeddedLyricsReselectionTests: XCTestCase {
    func testCachedSongCanSwitchBetweenTwoWordTimingsForTheSameLine() async throws {
        let song = Song(id: "embedded-\(UUID().uuidString)", title: "Copper Tide", fileFormat: .flac,
                        filePath: "/Copper Tide.flac", sourceID: "test", fileSize: 1)
        let original = "[00:01.00]<00:01.00>Copper <00:01.70>tide"
        let preferred = "[00:01.00]<00:01.00>Copper <00:01.30>tide"
        let stored = LyricsDocumentSource.embedded.stamped(LyricsContentParser.parseText(original))
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let wrote = await store.cacheLyrics(stored, forSongID: song.id, force: true)
        XCTAssertTrue(wrote)
        await store.storeEmbeddedLyricsAlternatives(.init(variants: [.init(text: preferred), .init(text: original)]),
                                                   forSongID: song.id)
        let changed = await LyricsLoader.reselectedEmbeddedVariant(for: song, cached: stored)
        let lastStart = try XCTUnwrap(changed?.first?.syllables?.last?.start)
        XCTAssertEqual(lastStart, 1.3, accuracy: 0.001)
        let cached = await store.cachedLyrics(forSongID: song.id)
        let again = await LyricsLoader.reselectedEmbeddedVariant(for: song, cached: try XCTUnwrap(cached))
        XCTAssertNil(again)
    }

    func testSYLTBeforeUSLTKeepsItsPhysicalPosition() async throws {
        func bytes(_ value: Int, shift: Int = 8) -> Data {
            let mask = (1 << shift) - 1
            return Data((0..<4).reversed().map { UInt8((value >> ($0 * shift)) & mask) })
        }
        func frame(_ name: String, _ payload: Data) -> Data {
            Data(name.utf8) + bytes(payload.count) + Data([0, 0]) + payload
        }
        let prefix = Data([3]) + Data("eng".utf8)
        let timed = prefix + Data([2, 1, 0]) + Data("Copper tide".utf8) + Data([0]) + bytes(1000)
        let plain = prefix + Data([0]) + Data("Paper lantern".utf8)
        let custom = Data([3]) + Data("LYRICS".utf8) + Data([0]) + Data("[00:01.00]Glass harbor".utf8)
        let body = frame("SYLT", timed) + frame("USLT", plain) + frame("TXXX", custom)
        let header = Data([0x49, 0x44, 0x33, 3, 0, 0]) + bytes(body.count, shift: 7)
        let audioFrame = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        var song = header + body
        for _ in 0..<8 { song += audioFrame }
        let metadata = await FileMetadataReader.RangeReadSession().read(from: song, fileExtension: "mp3")
        let alternatives = try XCTUnwrap(metadata.embeddedLyricsAlternatives)
        XCTAssertEqual(alternatives.variants.map(\.text), ["[00:01.000]Copper tide", "Paper lantern", "[00:01.00]Glass harbor"])
        XCTAssertEqual(FileMetadataReader.Metadata.embeddedLyrics(from: alternatives, priority: .firstInFile)?.lyricsText,
                       "[00:01.000]Copper tide")
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
