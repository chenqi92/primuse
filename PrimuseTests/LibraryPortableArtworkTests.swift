import Foundation
import ImageIO
import PrimuseKit
import UIKit
import UniformTypeIdentifiers
import SwiftUI
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

    func testFirstPlayerFrameUsesThumbnailBeforeHighResolutionTaskStarts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        let manager = SourceManager(sourcesProvider: { [] })
        let songID = UUID().uuidString
        let data = try image(color: .red, width: 768)
        await MetadataAssetStore.shared.cacheCover(data, forSongID: songID)
        let resolved = expectation(description: "Mini player thumbnail decoded")
        resolved.assertForOverFulfill = false
        let thumbnail = CachedArtworkView(
            coverRef: nil, songID: songID, size: 44, cornerRadius: 0,
            onResolutionChange: { if $0 { resolved.fulfill() } }
        ).environment(library).environment(manager)
        let host = UIHostingController(rootView: thumbnail)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [resolved], timeout: 5)

        // ImageRenderer renders synchronously without mounting a .task.
        // Both the entering player and an already-settled new surface must
        // show the cached cover on that very first frame.
        for settled in [false, true] {
            let hero = CachedArtworkView(
                coverRef: nil, songID: songID, size: 360, cornerRadius: 0,
                loadsHighResolution: settled
            ).artworkCrossfade().environment(library).environment(manager)
            let renderer = ImageRenderer(content: hero)
            renderer.scale = 1
            let rendered = try XCTUnwrap(renderer.uiImage?.cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[0], 230, "First frame must show the red artwork")
            XCTAssertLessThan(pixel[1], 25)
            XCTAssertLessThan(pixel[2], 25)
            XCTAssertGreaterThan(pixel[3], 240)
        }
        await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
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


extension LibraryPortableArtworkTests {
    func testArtworkIdentityLookupSkipsUnrelatedCloudPathsAndRevalidatesMatches() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        var resolvedSources: [String] = []
        library.sourceIdentityResolver = { source in
            resolvedSources.append(source)
            return source == "wrong-account" ? "other" : "account"
        }
        let owner = LibraryArtworkOwner(kind: .artist, id: "owner")
        let original = Song(id: "old", title: "Original", duration: 240, fileFormat: .flac, filePath: "target.flac", sourceID: "original")
        XCTAssertTrue(library.setArtwork(for: owner, to: original))
        let unrelated = (0..<2_000).map { index in
            Song(id: "unrelated-\(index)", title: "Other \(index)", duration: 240, fileFormat: .flac, filePath: "other-\(index).flac", sourceID: "source-\(index % 20)")
        }
        let wrong = Song(id: "wrong", title: "Different", duration: 200, fileFormat: .flac, filePath: original.filePath, sourceID: "wrong-account")
        let remounted = Song(id: "new", title: "Renamed", duration: 260, fileFormat: .flac, filePath: original.filePath, sourceID: "new-mount")
        library.addSongs(unrelated + [wrong, remounted])
        resolvedSources = []
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [remounted]), .selectedSong(remounted.id))
        XCTAssertEqual(Set(resolvedSources), ["wrong-account", "new-mount"])
        XCTAssertEqual(resolvedSources.count, 2)
        resolvedSources = []
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [remounted]), .selectedSong(remounted.id))
        XCTAssertTrue(resolvedSources.isEmpty)

        library.addSongs([wrong], affectedSourceIDs: [remounted.sourceID, wrong.sourceID])
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [wrong]), .automatic)
        library.addSongs([remounted], pruneMissingSongs: false)
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [remounted]), .selectedSong(remounted.id))
        library.sourceIdentityResolver = { _ in nil }
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [remounted]), .automatic)
    }

    /// 首页一屏有多张自选封面卡时，第一张触发的整库查找要顺带把其它卡也解析掉，
    /// 后面的卡直接命中缓存，不再各扫一遍。
    func testArtworkIdentityLookupResolvesAllPendingOwnersInOneScan() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        var resolverCalls = 0
        library.sourceIdentityResolver = { _ in
            resolverCalls += 1
            return "account"
        }
        let first = Song(id: "old-1", title: "One", duration: 200, fileFormat: .flac, filePath: "shared/one.flac", sourceID: "original")
        let second = Song(id: "old-2", title: "Two", duration: 200, fileFormat: .flac, filePath: "shared/two.flac", sourceID: "original")
        let ownerA = LibraryArtworkOwner(kind: .artist, id: "artist-a")
        let ownerB = LibraryArtworkOwner(kind: .artist, id: "artist-b")
        XCTAssertTrue(library.setArtwork(for: ownerA, to: first))
        XCTAssertTrue(library.setArtwork(for: ownerB, to: second))
        var remountedFirst = first
        remountedFirst.id = "new-1"
        remountedFirst.sourceID = "mount"
        var remountedSecond = second
        remountedSecond.id = "new-2"
        remountedSecond.sourceID = "mount"
        let unrelated = (0..<500).map { index in
            Song(id: "unrelated-\(index)", title: "Other \(index)", duration: 200, fileFormat: .flac, filePath: "other-\(index).flac", sourceID: "mount")
        }
        library.addSongs(unrelated + [remountedFirst, remountedSecond])

        resolverCalls = 0
        XCTAssertEqual(
            library.artworkOverrideResolution(for: ownerA, eligibleSongs: [remountedFirst]),
            .selectedSong(remountedFirst.id)
        )
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertEqual(
            library.artworkOverrideResolution(for: ownerB, eligibleSongs: [remountedSecond]),
            .selectedSong(remountedSecond.id)
        )
        XCTAssertEqual(resolverCalls, 1)
    }

    func testArtworkIdentityLookupKeepsTitleFallbackAndFirstMatchingSong() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        let owner = LibraryArtworkOwner(kind: .album, id: "album")
        let original = Song(id: "old", title: "Title", artistName: "Singer", duration: 240, fileFormat: .flac, filePath: "old.flac", sourceID: "source")
        XCTAssertTrue(library.setArtwork(for: owner, to: original))
        var first = original
        first.id = "first"
        first.filePath = "new.flac"
        var second = first
        second.id = "second"
        library.addSongs([first, second])
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [first, second]), .selectedSong(first.id))
        XCTAssertEqual(library.artworkOverrideResolution(for: owner, eligibleSongs: [second]), .automatic)
    }

    // MARK: - 自选封面：元数据与像素对不上的网图 (#104)

    /// 左红右蓝、上下渐变的 JPEG，方便判断方向与是否退化成纯色。
    private func splitJPEG(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { context in
            for row in 0..<height {
                let shade = CGFloat(row) / CGFloat(max(1, height - 1))
                UIColor(red: 1, green: shade, blue: 0, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: row, width: width / 2, height: 1))
                UIColor(red: 0, green: shade, blue: 1, alpha: 1).setFill()
                context.fill(CGRect(x: width / 2, y: row, width: width - width / 2, height: 1))
            }
        }
        let cgImage = try XCTUnwrap(rendered.cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 仿照报告里那张图的 EXIF：IFD0 声称 3745×3745，IFD1 的内嵌缩略图指针
    /// 指到段外（截断），并且同样的段出现两次。
    private func injectingInconsistentExif(into jpeg: Data) -> Data {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func u32(_ value: Int) -> [UInt8] { u16(value >> 16) + u16(value & 0xFFFF) }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
            u16(tag) + u16(type) + u32(count) + value + Array(repeating: 0, count: 4 - value.count)
        }
        var tiff: [UInt8] = Array("MM".utf8) + u16(42) + u32(8)
        let ifd0: [[UInt8]] = [
            entry(0x100, 3, 1, u16(3745)),
            entry(0x101, 3, 1, u16(3745)),
            entry(0x112, 3, 1, u16(1)),
        ]
        let ifd1Offset = 8 + 2 + ifd0.count * 12 + 4
        tiff += u16(ifd0.count) + ifd0.flatMap { $0 } + u32(ifd1Offset)
        let ifd1: [[UInt8]] = [
            entry(0x103, 3, 1, u16(6)),
            entry(0x201, 4, 1, u32(4000)),
            entry(0x202, 4, 1, u32(8701)),
        ]
        tiff += u16(ifd1.count) + ifd1.flatMap { $0 } + u32(0)
        tiff += [0xFF, 0xD8, 0xFF, 0xDB]
        let payload = Array("Exif\0\0".utf8) + tiff
        let segment: [UInt8] = [0xFF, 0xE1] + u16(payload.count + 2) + payload
        var bytes = [UInt8](jpeg)
        bytes.insert(contentsOf: segment + segment, at: 2)
        return Data(bytes)
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let width = image.width, height = image.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        // 位图内存按自上而下存放，第 0 行就是图的顶边。
        let offset = (y * width + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    func testUploadWithInconsistentExifKeepsRealPixels() throws {
        let original = injectingInconsistentExif(into: try splitJPEG(width: 300, height: 300))
        let processed = try XCTUnwrap(LibraryArtworkImageProcessor.process(original))
        let image = try decoded(processed)
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 300)
        let left = try rgb(image, x: 40, y: 150)
        let right = try rgb(image, x: 260, y: 150)
        XCTAssertGreaterThan(left.0, 200)
        XCTAssertLessThan(left.2, 60)
        XCTAssertLessThan(right.0, 60)
        XCTAssertGreaterThan(right.2, 200)
        XCTAssertLessThan(try rgb(image, x: 40, y: 5).1, try rgb(image, x: 40, y: 295).1 - 150)
    }

    func testStrippedUploadStillAppliesExifOrientation() throws {
        let original = try splitJPEG(width: 300, height: 200, orientation: 6)
        let processed = try XCTUnwrap(LibraryArtworkImageProcessor.process(original))
        let image = try decoded(processed)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 300)

        // 以 ImageIO 自己摆正的结果为准，逐个角落比颜色。
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let reference = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 300,
        ] as CFDictionary))
        XCTAssertEqual(reference.width, 200)
        for (x, y) in [(20, 20), (180, 20), (20, 280), (180, 280)] {
            let actual = try rgb(image, x: x, y: y)
            let expected = try rgb(reference, x: x, y: y)
            XCTAssertLessThan(abs(actual.0 - expected.0) + abs(actual.1 - expected.1) + abs(actual.2 - expected.2), 60,
                              "corner (\(x),\(y)) \(actual) vs \(expected)")
        }
    }
}
