import Foundation
import ImageIO
import PrimuseKit
import UIKit
import XCTest
@testable import Primuse

@MainActor
final class LibraryPortableArtworkTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryPortableArtworkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func image(jpeg: Bool = false, color: UIColor = .red, width: Int = 32) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: 16), format: format
        ).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
        }
        return try XCTUnwrap(jpeg ? rendered.jpegData(compressionQuality: 0.8) : rendered.pngData())
    }

    private func snapshot(_ songs: [Song]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.data(withJSONObject: [
            "songs": JSONSerialization.jsonObject(with: encoder.encode(songs)),
            "playlists": []
        ])
    }

    func testCancelledUploadedArtworkReadDoesNotClearReplacementImage() async throws {
        let oldImage = try image(jpeg: true, color: .red)
        let newImage = try image(jpeg: true, color: .blue)

        for oldResult in [oldImage, nil] as [Data?] {
            let gate = UploadedArtworkReadGate()
            var displayedImage: UIImage?
            var updateCount = 0
            let oldTask = Task {
                await UploadedArtworkLoader.load(contentID: "old", readData: { _ in
                    await gate.suspend()
                    return oldResult
                }) {
                    displayedImage = $0
                    updateCount += 1
                }
            }
            await gate.waitUntilSuspended()
            oldTask.cancel()

            await UploadedArtworkLoader.load(contentID: "new", readData: { _ in newImage }) {
                displayedImage = $0
                updateCount += 1
            }
            let replacement = displayedImage
            XCTAssertNotNil(replacement)

            await gate.release()
            await oldTask.value
            XCTAssertTrue(displayedImage === replacement)
            XCTAssertEqual(updateCount, 1)
        }
    }

    func testCancelledUploadedArtworkReadDoesNotRestoreRemovedOverride() async throws {
        let data = try image(jpeg: true)
        let gate = UploadedArtworkReadGate()
        var displayedImage = UIImage(data: data)
        var updateCount = 0
        let oldTask = Task {
            await UploadedArtworkLoader.load(contentID: "old", readData: { _ in
                await gate.suspend()
                return data
            }) {
                displayedImage = $0
                updateCount += 1
            }
        }
        await gate.waitUntilSuspended()
        oldTask.cancel()

        await UploadedArtworkLoader.load(contentID: nil) {
            displayedImage = $0
            updateCount += 1
        }
        XCTAssertNil(displayedImage)

        await gate.release()
        await oldTask.value
        XCTAssertNil(displayedImage)
        XCTAssertEqual(updateCount, 1)
    }

    func testCurrentUploadedArtworkReadFailureClearsPreviousImage() async throws {
        let data = try image(jpeg: true)
        for result in [nil, Data("invalid image".utf8)] as [Data?] {
            var displayedImage = UIImage(data: data)
            XCTAssertNotNil(displayedImage)

            await UploadedArtworkLoader.load(contentID: "missing", readData: { _ in result }) {
                displayedImage = $0
            }
            XCTAssertNil(displayedImage)
        }
    }

    func testBoundedJPEGIsTransferredWithoutRecompression() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let original = try image(jpeg: true)
        store.storeCoverSync(original, for: "song")
        let name = store.expectedCoverFileName(for: "song")
        let identity = try XCTUnwrap(store.coverContentIdentifier(named: name))
        let cover = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: identity))
        XCTAssertEqual(cover.data, original)
        XCTAssertFalse(cover.requiredProcessing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.portableArtworkDirectoryURL.path))
    }

    func testTranscodedCoverIsReusedAcrossStoresAndInvalidatesOnReplacement() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        store.storeCoverSync(try image(), for: "song")
        let name = store.expectedCoverFileName(for: "song")
        let firstIdentity = try XCTUnwrap(store.coverContentIdentifier(named: name))
        let first = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: firstIdentity))
        XCTAssertTrue(first.requiredProcessing)
        XCTAssertTrue(LibraryArtworkImageProcessor.isReusablePortableJPEG(first.data))

        let reopened = MetadataAssetStore(storageDirectory: root)
        let reused = try XCTUnwrap(reopened.preparePortableCover(named: name, contentIdentifier: firstIdentity))
        XCTAssertFalse(reused.requiredProcessing)
        XCTAssertEqual(reused.data, first.data)

        reopened.storeCoverSync(try image(color: .blue), for: "song")
        let replacementIdentity = try XCTUnwrap(reopened.coverContentIdentifier(named: name))
        XCTAssertNotEqual(replacementIdentity, firstIdentity)
        let replacement = try XCTUnwrap(reopened.preparePortableCover(named: name, contentIdentifier: replacementIdentity))
        XCTAssertTrue(replacement.requiredProcessing)
        XCTAssertNotEqual(replacement.data, first.data)
    }

    func testOversizedJPEGStillProducesBoundedTransportImage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let original = try image(jpeg: true, width: 1600)
        XCTAssertFalse(LibraryArtworkImageProcessor.isReusablePortableJPEG(original))
        store.storeCoverSync(original, for: "song")
        let name = store.expectedCoverFileName(for: "song")
        let identity = try XCTUnwrap(store.coverContentIdentifier(named: name))
        let cover = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: identity))
        XCTAssertTrue(cover.requiredProcessing)
        XCTAssertTrue(LibraryArtworkImageProcessor.isReusablePortableJPEG(cover.data))
        XCTAssertLessThanOrEqual(cover.data.count, LibraryArtworkContentIDPolicy.maximumSyncedArtworkBytes)
        XCTAssertEqual(store.readCoverData(named: name), original)
    }

    func testCorruptDerivedCacheIsRebuiltAndClearedWithArtworkCache() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        store.storeCoverSync(try image(), for: "song")
        let name = store.expectedCoverFileName(for: "song")
        let identity = try XCTUnwrap(store.coverContentIdentifier(named: name))
        let first = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: identity))
        let files = try FileManager.default.contentsOfDirectory(at: store.portableArtworkDirectoryURL, includingPropertiesForKeys: nil)
        let cache = try XCTUnwrap(files.first)
        try Data("invalid".utf8).write(to: cache)
        let recovered = try XCTUnwrap(store.preparePortableCover(named: name, contentIdentifier: identity))
        XCTAssertTrue(recovered.requiredProcessing)
        XCTAssertEqual(recovered.data, first.data)
        await store.clearAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testSnapshotDeduplicatesSharedCoversAndPreservesMetadataAtBudgetLimit() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let songs = (0..<3).map {
            Song(id: "song-\($0)", title: "Song \($0)", fileFormat: .mp3,
                 filePath: "/song-\($0).mp3", sourceID: "source")
        }
        let original = try image(jpeg: true)
        for song in songs { store.storeCoverSync(original, for: song.id) }
        let data = try snapshot(songs)
        let prepared = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            data, assetStore: store, maximumArtworkBytes: original.count
        )
        let transfer = try XCTUnwrap(prepared)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        XCTAssertEqual((object["songs"] as? [[String: Any]])?.count, songs.count)
        XCTAssertEqual((object["cachedArtworkAssets"] as? [String: String])?.count, 1)
        XCTAssertEqual((object["artworkCacheReferences"] as? [String: String])?.count, songs.count)

        let overBudget = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            data, assetStore: store, maximumArtworkBytes: original.count - 1
        )
        let smallTransfer = try XCTUnwrap(overBudget)
        let smallObject = try XCTUnwrap(JSONSerialization.jsonObject(with: smallTransfer.data) as? [String: Any])
        XCTAssertEqual((smallObject["songs"] as? [[String: Any]])?.count, songs.count)
        XCTAssertNil(smallObject["cachedArtworkAssets"])
        XCTAssertNil(smallObject["artworkCacheReferences"])
    }

    /// 手动「清除封面与歌词」和容量驱逐留下的是同一种残局: ref 和 content 都
    /// 没了, 而 `Song.coverArtFileName` 还留在歌曲记录上。那个字段就是回填队列
    /// 判断「这首歌要不要重读封面」的唯一依据, 不摘掉就再也补不回来。清空必须
    /// 把删掉的 ref 一次性播出去, 让资料库摘掉它们。
    func testClearingAllAssetsAnnouncesTheClearedSongCoverReferences() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let cover = try image(jpeg: true)
        let songIDs = ["song-a", "song-b"]
        for songID in songIDs {
            store.storeCoverSync(cover, for: songID)
        }
        // 专辑封面是派生副本, 键也不同, 不该混进这份通知里。
        _ = await store.storeAlbumCover(cover, forAlbumID: "album-1")

        var observedRefs: Set<String>?
        let received = XCTestExpectation(description: "artwork content evicted")
        let token = NotificationCenter.default.addObserver(
            forName: .primuseArtworkContentEvicted,
            object: nil,
            queue: .main
        ) { note in
            observedRefs = note.userInfo?["refs"] as? Set<String>
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await store.clearAll()
        await fulfillment(of: [received], timeout: 5)

        XCTAssertEqual(
            observedRefs,
            Set(songIDs.map { store.expectedCoverFileName(for: $0) })
        )
        for songID in songIDs {
            let cached = await store.cachedCoverData(forSongID: songID)
            XCTAssertNil(cached)
        }
    }

    func testExhaustedArtworkBudgetStopsConvertingRemainingCovers() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let songs = (0..<3).map {
            Song(id: "song-\($0)", title: "Song \($0)", fileFormat: .mp3,
                 filePath: "/song-\($0).mp3", sourceID: "source")
        }
        for (song, color) in zip(songs, [UIColor.red, .blue, .green]) {
            store.storeCoverSync(try image(color: color), for: song.id)
        }
        let data = try snapshot(songs)
        let prepared = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            data, assetStore: store, maximumArtworkBytes: 1
        )
        let transfer = try XCTUnwrap(prepared)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        XCTAssertEqual((object["songs"] as? [[String: Any]])?.count, songs.count)
        XCTAssertNil(object["cachedArtworkAssets"])
        let files = try FileManager.default.contentsOfDirectory(atPath: store.portableArtworkDirectoryURL.path)
        XCTAssertEqual(files.count, 1)
    }

    func testCancelledSnapshotPreparationDoesNotReturnPartialPayload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let song = Song(id: "cancelled", title: "Song", fileFormat: .mp3,
                        filePath: "/song.mp3", sourceID: "source")
        store.storeCoverSync(try image(), for: song.id)
        let data = try snapshot([song])
        let task = Task {
            await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(data, assetStore: store)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
}

private actor UploadedArtworkReadGate {
    private var isSuspended = false
    private var suspendedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        suspendedWaiter?.resume()
        suspendedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { suspendedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
