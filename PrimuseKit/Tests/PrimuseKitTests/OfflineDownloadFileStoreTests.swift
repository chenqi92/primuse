import Darwin
import Foundation
import XCTest
@testable import PrimuseKit

final class OfflineDownloadFileStoreTests: XCTestCase {
    private var root: URL!
    private var store: OfflineDownloadFileStore!
    private let path = "source/1234567890abcdef.flac"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = OfflineDownloadFileStore(directory: root.appendingPathComponent("Documents/Downloads"),
                                        indexURL: root.appendingPathComponent("Private/index.json"))
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: root)
    }

    private func audio(_ name: String = "cache.flac", bytes: UInt8 = 7) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: bytes, count: 4096).write(to: url)
        return url
    }

    func testCompactFormatSurvivesNamingReplacementAndRestart() throws {
        func compact(_ format: StreamTranscodeFormat) throws -> URL {
            let url = try audio(format.rawValue + ".compact.m4a")
            let record = OfflineCompactArtifactRecord(originalByteCount: 10000, bitRateKbps: 192, format: format)
            let bytes = Array(record.serialized.utf8)
            let status = bytes.withUnsafeBytes {
                setxattr(url.path, OfflineDownloadQualityPolicy.compactRecordAttributeName,
                         $0.baseAddress, $0.count, 0, 0)
            }
            XCTAssertEqual(status, 0)
            return url
        }
        let aac = try store.publish(compact(.aac), for: path, kind: .compact, displayName: "Track")
        let mp3 = try store.publish(compact(.mp3), for: path, kind: .compact, displayName: "Track")
        XCTAssertEqual(mp3.pathExtension, "mp3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: aac.path))
        XCTAssertEqual(store.fileURL(for: path, kind: .compact), mp3)
        let renamed = mp3.deletingLastPathComponent().appendingPathComponent("My Track.mp3")
        try FileManager.default.moveItem(at: mp3, to: renamed)
        XCTAssertEqual(try store.reconcile(), [path])
        let opus = try store.publish(compact(.opus), for: path, kind: .compact)
        XCTAssertEqual(opus.lastPathComponent, "My Track.opus")
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        let restarted = OfflineDownloadFileStore(directory: store.directory,
                                                indexURL: root.appendingPathComponent("Private/index.json"))
        XCTAssertEqual(restarted.fileURL(for: path, kind: .compact), opus)
        try FileManager.default.removeItem(at: opus)
        let restoredAAC = try restarted.publish(compact(.aac), for: path, kind: .compact)
        XCTAssertEqual(restoredAAC.lastPathComponent, "My Track.m4a")
        XCTAssertEqual(restarted.fileURL(for: path, kind: .compact), restoredAAC)
    }

    func testClearingTheEntireCacheDoesNotRemoveTheDownload() throws {
        let cached = try audio()
        let downloaded = try store.publish(cached, for: path, kind: .original, displayName: "歌手 - 歌名")
        let cacheInode = try FileManager.default.attributesOfItem(atPath: cached.path)[.systemFileNumber] as? NSNumber
        let downloadInode = try FileManager.default.attributesOfItem(atPath: downloaded.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(cacheInode, downloadInode)
        try FileManager.default.removeItem(at: cached)
        XCTAssertEqual(try store.reconcile(), [])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(for: path, kind: .original))),
                       Data(repeating: 7, count: 4096))
        XCTAssertTrue(downloaded.lastPathComponent.contains("歌手 - 歌名"))
        XCTAssertFalse(store.wasExternallyRemoved(path))
    }

    func testRenamingAndMovingInDownloadsSurvivesRestart() throws {
        let downloaded = try store.publish(audio(), for: path, kind: .original)
        let folder = store.directory.appendingPathComponent("我收藏的音乐")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renamed = folder.appendingPathComponent("自定义歌名.flac")
        try FileManager.default.moveItem(at: downloaded, to: renamed)
        XCTAssertEqual(try store.reconcile(), [path])
        XCTAssertEqual(store.fileURL(for: path, kind: .original), renamed)
        try store.setDisplayName("不应覆盖用户的名字", for: path)
        XCTAssertEqual(store.fileURL(for: path, kind: .original), renamed)

        let restarted = OfflineDownloadFileStore(directory: store.directory,
                                                indexURL: root.appendingPathComponent("Private/index.json"))
        XCTAssertEqual(restarted.fileURL(for: path, kind: .original), renamed)
    }

    func testDeletingInFilesDoesNotRecoverFromTheSurvivingCacheLink() throws {
        let cached = try audio()
        let downloaded = try store.publish(cached, for: path, kind: .original)
        try FileManager.default.removeItem(at: downloaded)
        XCTAssertEqual(try store.reconcile(), [path])
        XCTAssertNil(store.fileURL(for: path, kind: .original))
        XCTAssertFalse(store.manages(path))
        XCTAssertTrue(store.wasExternallyRemoved(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        let restarted = OfflineDownloadFileStore(directory: store.directory,
                                                indexURL: root.appendingPathComponent("Private/index.json"))
        XCTAssertTrue(restarted.wasExternallyRemoved(path))
        try restarted.publish(cached, for: path, kind: .original)
        XCTAssertFalse(restarted.wasExternallyRemoved(path))
        XCTAssertNotNil(restarted.fileURL(for: path, kind: .original))
    }

    func testDeletingOriginalKeepsCompactDownloadAndItsOwnership() throws {
        let original = try store.publish(audio(), for: path, kind: .original)
        let compact = try store.publish(audio("compact.m4a", bytes: 3), for: path, kind: .compact)
        try FileManager.default.removeItem(at: original)
        _ = try store.reconcile()
        XCTAssertNil(store.fileURL(for: path, kind: .original))
        XCTAssertEqual(store.fileURL(for: path, kind: .compact), compact)
        XCTAssertFalse(store.wasExternallyRemoved(path))
    }

    func testPublishingRefreshRetainsTheUserFilenameAndReplacesTheBytes() throws {
        let original = try store.publish(audio(), for: path, kind: .original)
        let renamed = store.directory.appendingPathComponent("my song.flac")
        try FileManager.default.moveItem(at: original, to: renamed)
        _ = try store.reconcile()
        let updated = try store.publish(audio("refresh.flac", bytes: 9), for: path, kind: .original)
        XCTAssertEqual(updated, renamed)
        XCTAssertEqual(try Data(contentsOf: renamed), Data(repeating: 9, count: 4096))
    }

    func testNamesCannotEscapeDownloadsOrOverwriteUnrelatedFiles() throws {
        let original = try store.publish(audio(), for: path, kind: .original, displayName: "../../Song")
        XCTAssertTrue(original.path.hasPrefix(store.directory.path + "/"))
        try FileManager.default.removeItem(at: original)
        try Data([1, 2, 3]).write(to: original)
        let updated = try store.publish(audio("new.flac", bytes: 9), for: path, kind: .original)
        XCTAssertNotEqual(updated, original)
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: updated), Data(repeating: 9, count: 4096))
    }

    func testUnreadableIndexNeverTreatsAnExistingDownloadAsUnmanagedCache() throws {
        let downloaded = try store.publish(audio(), for: path, kind: .original)
        try Data("invalid index".utf8).write(to: root.appendingPathComponent("Private/index.json"))
        let restarted = OfflineDownloadFileStore(directory: store.directory,
                                                indexURL: root.appendingPathComponent("Private/index.json"))
        XCTAssertThrowsError(try restarted.reconcile())
        XCTAssertThrowsError(try restarted.remove(path))
        XCTAssertTrue(restarted.manages(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
    }

    func testMissingTransferDoesNotReplaceExistingDownload() throws {
        let downloaded = try store.publish(audio(), for: path, kind: .original)
        XCTAssertThrowsError(try store.publish(root.appendingPathComponent("missing.flac"), for: path, kind: .original))
        XCTAssertEqual(try Data(contentsOf: downloaded), Data(repeating: 7, count: 4096))
    }

    func testInterruptedJournalAppendPreservesCommittedDownloadsAndAcceptsFurtherChanges() throws {
        let downloaded = try store.publish(audio(), for: path, kind: .original)
        let journal = root.appendingPathComponent("Private/index.json.journal")
        let file = try FileHandle(forWritingTo: journal)
        try file.seekToEnd()
        try file.write(contentsOf: Data("{\"path\":\"interrupted".utf8))
        try file.close()
        let restarted = OfflineDownloadFileStore(directory: store.directory,
                                                indexURL: root.appendingPathComponent("Private/index.json"))
        XCTAssertEqual(restarted.fileURL(for: path, kind: .original), downloaded)
        try restarted.remove(path)
        let again = OfflineDownloadFileStore(directory: store.directory,
                                             indexURL: root.appendingPathComponent("Private/index.json"))
        XCTAssertEqual(try again.paths(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
    }

    func testCheckpointAndFollowingJournalBothSurviveRestart() throws {
        let cached = try audio()
        for _ in 0..<256 { try store.publish(cached, for: path, kind: .original) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Private/index.json").path))
        let secondPath = "source/second.flac"
        let second = try store.publish(audio("second.flac"), for: secondPath, kind: .original)
        let restarted = OfflineDownloadFileStore(directory: store.directory,
                                                indexURL: root.appendingPathComponent("Private/index.json"))
        XCTAssertEqual(try restarted.paths(), [path, secondPath])
        XCTAssertEqual(restarted.fileURL(for: secondPath, kind: .original), second)
    }
}
