import XCTest
import Network
import PrimuseKit
@testable import Primuse

final class AudioCacheSyncPolicyTests: XCTestCase {
    @MainActor
    func testEncryptedCachePlanningWorksWithoutBonjourAndSurvivesDiscoveryRestart() async throws {
        let receiver = AudioCacheSyncService(advertisesBonjour: false)
        let sender = AudioCacheSyncService(advertisesBonjour: false)
        receiver.setApplicationActive(true)
        defer {
            receiver.setApplicationActive(false)
            sender.stopDiscovery()
        }
        try await waitUntil { receiver.connectionCode != nil }
        XCTAssertEqual(receiver.receiverState, .directOnly)
        let peerID = try XCTUnwrap(sender.connect(using: XCTUnwrap(receiver.connectionCode)))
        sender.startDiscovery()
        XCTAssertTrue(sender.peers.contains { $0.id == peerID })
        sender.inspect(peerID: peerID)
        try await waitUntil { sender.operation == .idle }
        XCTAssertNil(sender.lastError)
        XCTAssertEqual(sender.peerPlans[peerID]?.missingFileCount, 0)
        sender.sync(to: peerID)
        try await waitUntil { sender.operation == .idle }
        XCTAssertNil(sender.lastError)
        XCTAssertEqual(sender.lastCompletion?.transferredFileCount, 0)
        try await waitUntil { receiver.incomingTransferCount == 0 }
        XCTAssertNil(receiver.incomingError)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for cache sync state")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testNetworkFailuresDoNotAllBecomePermissionErrors() {
        XCTAssertEqual(AudioCacheSyncNetworkIssue(.dns(-65570)), .permissionDenied)
        XCTAssertEqual(AudioCacheSyncNetworkIssue(.posix(.EACCES)), .permissionDenied)
        XCTAssertEqual(AudioCacheSyncNetworkIssue(.dns(-65555)), .bonjourUnavailable)
        XCTAssertEqual(AudioCacheSyncNetworkIssue(.posix(.ENETDOWN)), .networkUnavailable)
        guard case .other = AudioCacheSyncNetworkIssue(.posix(.ECONNRESET)) else {
            return XCTFail("Connection resets must not be reported as denied permissions")
        }
    }

    func testConnectionCodePreservesReceiverIdentityAndEncryptionKey() throws {
        let value = invitation()
        let code = try XCTUnwrap(value.code)
        XCTAssertEqual(AudioCacheSyncInvitation.parse(" \n" + code + "\n"), value)
    }

    func testConnectionCodeRejectsPublicAndLoopbackDestinations() throws {
        for host in ["8.8.8.8", "127.0.0.1", "0.0.0.0", "example.com", "192.168.1.4/path", "224.0.0.1"] {
            let code = try XCTUnwrap(invitation(host: host).code)
            XCTAssertNil(AudioCacheSyncInvitation.parse(code), host)
        }
        for host in ["10.1.2.3", "172.16.0.2", "192.168.0.4", "169.254.2.3"] {
            XCTAssertNotNil(AudioCacheSyncInvitation.parse(try XCTUnwrap(invitation(host: host).code)))
        }
    }

    func testConnectionCodeRejectsMalformedOrIncompatibleInvitations() throws {
        let invalid = [
            invitation(version: 2), invitation(port: 0), invitation(id: ""),
            invitation(publicKey: Data(repeating: 1, count: 31)), invitation(name: "bad\nname")
        ]
        for value in invalid {
            XCTAssertNil(AudioCacheSyncInvitation.parse(try XCTUnwrap(value.code)))
        }
        XCTAssertNil(AudioCacheSyncInvitation.parse("primuse-cache:invalid"))
        XCTAssertNil(AudioCacheSyncInvitation.parse(String(repeating: "x", count: 2_049)))
    }

    private func invitation(
        host: String = "192.168.0.2", version: Int = 1, port: UInt16 = 12345,
        id: String = "A1A018EB-3000-4B2E-8539-D97654020EF1", name: String = "Mac",
        publicKey: Data = Data(repeating: 7, count: 32)
    ) -> AudioCacheSyncInvitation {
        AudioCacheSyncInvitation(version: version, host: host, port: port, id: id,
                                 name: name, platform: .mac, publicKey: publicKey)
    }

    func testBonjourServiceTypeMatchesInfoPlistFormat() {
        XCTAssertEqual(AudioCacheSyncPolicy.serviceType, "_primuse-cache._tcp")
        XCTAssertFalse(AudioCacheSyncPolicy.serviceType.hasSuffix("."))
    }

    func testCacheFileNameRejectsTraversalAndControlCharacters() {
        XCTAssertTrue(AudioCacheSyncPolicy.isSafeCacheFileName("2f8451.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName("../2f8451.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName("folder/2f8451.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName("folder\\2f8451.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName("bad\u{0}name.flac"))
        XCTAssertFalse(AudioCacheSyncPolicy.isSafeCacheFileName(".."))
    }

    func testTransferredByteCountMustMatchCatalogTolerance() {
        let catalog: Int64 = 100_000
        XCTAssertTrue(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: catalog,
            catalogByteCount: catalog
        ))
        XCTAssertTrue(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 95_000,
            catalogByteCount: catalog
        ))
        XCTAssertFalse(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 94_999,
            catalogByteCount: catalog
        ))
        XCTAssertFalse(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: catalog + 4_097,
            catalogByteCount: catalog
        ))
        XCTAssertFalse(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 0,
            catalogByteCount: catalog
        ))
    }

    func testUnknownCatalogSizeStillRequiresNonemptyFile() {
        XCTAssertTrue(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 1,
            catalogByteCount: 0
        ))
        XCTAssertFalse(AudioCacheSyncPolicy.byteCountIsCompatible(
            transferredByteCount: 0,
            catalogByteCount: 0
        ))
    }

    func testItemIDUsesCanonicalCacheRelativePath() {
        XCTAssertEqual(
            AudioCacheSyncPolicy.itemID(
                sourceID: "source-id",
                cacheFileName: "hashed-name.m4a"
            ),
            "source-id/hashed-name.m4a"
        )
    }

    func testLimitedItemIDsKeepsDeterministicPrefix() {
        let itemIDs = ["one", "two", "three", "four"]

        XCTAssertEqual(
            AudioCacheSyncPolicy.limitedItemIDs(itemIDs, maximumCount: 3),
            ["one", "two", "three"]
        )
        XCTAssertEqual(
            AudioCacheSyncPolicy.limitedItemIDs(itemIDs, maximumCount: 10),
            itemIDs
        )
        XCTAssertEqual(
            AudioCacheSyncPolicy.limitedItemIDs(itemIDs, maximumCount: nil),
            itemIDs
        )
        XCTAssertTrue(
            AudioCacheSyncPolicy.limitedItemIDs(itemIDs, maximumCount: 0).isEmpty
        )
    }
}

@MainActor
final class OfflineAudioSnapshotTests: XCTestCase {
    func testStreamingCompletionUpdatesNegativeSnapshotAndDownloadedMembership() async throws {
        let fixture = try await fixture()
        defer { fixture.manager.deleteLocalCaches(for: [fixture.song]) }
        let entry = fixture.manager.offlineAudioSnapshotEntry(for: fixture.song)
        let initialIDs = await fixture.manager.downloadedSongIDs(in: [fixture.song])
        XCTAssertTrue(initialIDs.isEmpty)
        XCTAssertEqual(entry.snapshot.state, .notCached)
        let revision = fixture.manager.offlineAudioSnapshotRevision

        let partial = fixture.url.appendingPathExtension("partial")
        try Data(repeating: 7, count: 128).write(to: partial)
        await AudioCacheManager.shared.refreshPathFamily(path: fixture.path)
        let partialIDs = await fixture.manager.downloadedSongIDs(in: [fixture.song])
        XCTAssertTrue(partialIDs.isEmpty)

        try FileManager.default.moveItem(at: partial, to: fixture.url)
        await AudioCacheManager.shared.recordAccess(path: fixture.path)
        try await waitUntil { entry.snapshot.state == .cached }
        let completedIDs = await fixture.manager.downloadedSongIDs(in: [fixture.song])
        XCTAssertEqual(completedIDs, [fixture.song.id])
        XCTAssertGreaterThan(fixture.manager.offlineAudioSnapshotRevision, revision)
    }

    func testCacheRemovalUpdatesDownloadedMembershipWithoutReloadingLibrary() async throws {
        let fixture = try await fixture()
        defer { fixture.manager.deleteLocalCaches(for: [fixture.song]) }
        try Data(repeating: 7, count: 128).write(to: fixture.url)
        await AudioCacheManager.shared.recordAccess(path: fixture.path)
        let initialIDs = await fixture.manager.downloadedSongIDs(in: [fixture.song])
        XCTAssertEqual(initialIDs, [fixture.song.id])
        let entry = fixture.manager.offlineAudioSnapshotEntry(for: fixture.song)

        await AudioCacheManager.shared.removeEntry(path: fixture.path)
        try await waitUntil { entry.snapshot.state == .notCached }
        let removedIDs = await fixture.manager.downloadedSongIDs(in: [fixture.song])
        XCTAssertTrue(removedIDs.isEmpty)
    }

    func testCompletedPinnedFileRetainsOfflinePinWhenSnapshotRefreshes() async throws {
        let fixture = try await fixture()
        defer { fixture.manager.deleteLocalCaches(for: [fixture.song]) }
        await fixture.manager.ensureOfflineAudioSnapshot(for: fixture.song)
        let entry = fixture.manager.offlineAudioSnapshotEntry(for: fixture.song)
        try Data(repeating: 7, count: 128).write(to: fixture.url)
        await AudioCacheManager.shared.markDownloaded(path: fixture.path, byteCount: 128, pinned: true)
        try await waitUntil { entry.snapshot.state == .pinned }
        let downloadedIDs = await fixture.manager.downloadedSongIDs(in: [fixture.song])
        XCTAssertEqual(downloadedIDs, [fixture.song.id])
    }

    func testIncompleteCanonicalFileRemainsUndownloadedUntilReplacementCompletes() async throws {
        let fixture = try await fixture()
        defer { fixture.manager.deleteLocalCaches(for: [fixture.song]) }
        await fixture.manager.ensureOfflineAudioSnapshot(for: fixture.song)
        try Data(repeating: 7, count: 16).write(to: fixture.url)
        await AudioCacheManager.shared.recordAccess(path: fixture.path)
        await fixture.manager.refreshOfflineAudioSnapshot(for: fixture.song)
        XCTAssertFalse(fixture.manager.offlineAudioSnapshot(for: fixture.song).isDownloaded)

        try Data(repeating: 7, count: 128).write(to: fixture.url, options: .atomic)
        await AudioCacheManager.shared.recordAccess(path: fixture.path)
        try await waitUntil {
            fixture.manager.offlineAudioSnapshotEntry(for: fixture.song).snapshot.isDownloaded
        }
    }

    private func fixture() async throws -> (manager: SourceManager, song: Song, url: URL, path: String) {
        let source = MusicSource(id: UUID().uuidString, name: "Cache fixture", type: .navidrome)
        let song = Song(id: UUID().uuidString, title: "Cache fixture", fileFormat: .flac,
                        filePath: "/songs/fixture.flac", sourceID: source.id, fileSize: 128)
        let manager = SourceManager(sourcesProvider: { [source] }, songsProvider: { [song] })
        // A newly configured source validates its cache namespace before any
        // transfer can install files; creating files earlier tests quarantine.
        let deadline = Date().addingTimeInterval(3)
        while !(await manager.prepareAutomaticOfflineDownload(song: song, forceRedownload: false)) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let url = manager.cacheURL(for: song)
        return (manager, song, url, source.id + "/" + url.lastPathComponent)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Cache change did not reach the observed song")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
