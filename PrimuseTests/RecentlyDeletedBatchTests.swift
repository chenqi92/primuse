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

    // MARK: - Device-local song exclusions (WebDAV deletion refused)

    /// A WebDAV row whose source deletion the server refused. `identityKey`
    /// is `"<sourceID>:<filePath>"` when no cloud-account resolver is wired,
    /// which is the case for an isolated test library.
    private static func makeWebDAVSong(
        id: String = "webdav-duplicate",
        sourceID: String = "webdav-source",
        filePath: String = "/Music/Album/duplicate.flac"
    ) -> Song {
        Song(
            id: id,
            title: "Duplicate",
            artistName: "Tester",
            duration: 120,
            fileFormat: .flac,
            filePath: filePath,
            sourceID: sourceID
        )
    }

    private static func makeIsolatedStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseDeviceLocalExclusionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testRemoveSongsFromThisDeviceDropsRowsWithoutWritingASyncedTombstone() throws {
        let storageDirectory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let song = Self.makeWebDAVSong()
        library.addSongs([song])
        XCTAssertEqual(library.songs.map(\.id), [song.id])

        let remainingCounts = try library.removeSongsFromThisDevice([song])
        XCTAssertEqual(remainingCounts[song.sourceID], 0)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.isExcludedOnThisDevice(song))
        // The tombstone set is merged across devices by snapshot sync, so a
        // device-local removal must never land in it.
        XCTAssertTrue(library.deletedSongIdentities.isEmpty)

        // A rescan of the same source on this device must not bring it back.
        library.addSongs([song])
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.deletedSongIdentities.isEmpty)
    }

    func testDeviceLocalExclusionSurvivesReopeningTheSameStorageDirectory() async throws {
        let storageDirectory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let song = Self.makeWebDAVSong()
        let library = MusicLibrary(storageDirectory: storageDirectory)
        library.addSongs([song])
        try library.removeSongsFromThisDevice([song])
        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }

        let reopened = MusicLibrary(storageDirectory: storageDirectory)
        XCTAssertTrue(reopened.isExcludedOnThisDevice(song))
        XCTAssertFalse(reopened.songs.contains { $0.id == song.id })
        reopened.addSongs([song])
        XCTAssertFalse(reopened.songs.contains { $0.id == song.id })
    }

    func testPortableSnapshotPreservesSongsHiddenOnlyOnSendingDevice() async throws {
        let storageDirectory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let song = Self.makeWebDAVSong()
        let library = MusicLibrary(storageDirectory: storageDirectory)
        library.addSongs([song])
        try library.removeSongsFromThisDevice([song])
        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }

        let identity = "\(song.sourceID):\(song.filePath)"
        let snapshotData = try Data(
            contentsOf: storageDirectory.appendingPathComponent("library-cache.json")
        )
        let snapshotText = try XCTUnwrap(String(data: snapshotData, encoding: .utf8))
        XCTAssertFalse(snapshotText.contains(identity))
        let snapshotObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshotData) as? [String: Any]
        )
        let tombstones = snapshotObject["deletedSongIdentities"] as? [String] ?? []
        XCTAssertFalse(tombstones.contains(identity))
        let snapshotSongPaths = (snapshotObject["songs"] as? [[String: Any]] ?? [])
            .compactMap { $0["filePath"] as? String }
        XCTAssertTrue(snapshotSongPaths.contains(song.filePath))
        let receivingDirectory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: receivingDirectory) }
        try snapshotData.write(to: receivingDirectory.appendingPathComponent("library-cache.json"))
        let receivingLibrary = MusicLibrary(storageDirectory: receivingDirectory)
        XCTAssertEqual(receivingLibrary.songs.map(\.id), [song.id])
        XCTAssertFalse(receivingLibrary.isExcludedOnThisDevice(song))

        // The exclusion lives in its own device-local ledger file instead.
        let ledgerData = try Data(
            contentsOf: storageDirectory
                .appendingPathComponent("library-device-local-excluded-songs.json")
        )
        let ledger = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ledgerData) as? [String: Any]
        )
        XCTAssertEqual(ledger["identities"] as? [String], [identity])
    }

    /// The ledger stores `identityKey(for:)`, whose prefix is the resolved
    /// cloud-account identity when a resolver is wired. `loadSnapshot` runs
    /// from `init`, before AppServices installs that resolver, so the reopened
    /// library computes the raw `"<sourceID>:<filePath>"` form for the same
    /// song — the exclusion has to hold on both sides of that window.
    func testDeviceLocalExclusionRecordedWithResolverStillAppliesAfterReopen() async throws {
        let storageDirectory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let source = MusicSource(id: "webdav-source", name: "WebDAV", type: .webdav)
        let song = Self.makeWebDAVSong(sourceID: source.id)
        let library = MusicLibrary(storageDirectory: storageDirectory)
        library.sourceIdentityResolver = { $0 == source.id ? "account-1" : nil }
        library.addSongs([song])
        try library.removeSongsFromThisDevice([song])
        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }

        // Reopened the way the app does it: no resolver yet at load time.
        let reopened = MusicLibrary(storageDirectory: storageDirectory)
        XCTAssertFalse(reopened.songs.contains { $0.id == song.id })
        XCTAssertTrue(reopened.isExcludedOnThisDevice(song))

        // Once AppServices installs the resolver the recorded key matches
        // directly, and a rescan of the same source still must not re-add it.
        reopened.sourceIdentityResolver = { $0 == source.id ? "account-1" : nil }
        reopened.addSongs([song])
        XCTAssertTrue(reopened.songs.isEmpty)
    }

    func testLocalExclusionPreservesPlaylistAndHistoryAcrossSyncAndReload() async throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeWebDAVSong()
        library.addSongs([song])
        let playlist = library.createPlaylist(name: "Retained membership")
        library.add(songIDs: [song.id], toPlaylist: playlist.id)
        library.recordPlayback(of: song.id)
        try library.removeSongsFromThisDevice([song])
        library.addSongs([song])
        await library.waitForPendingIndex()
        XCTAssertNil(library.song(id: song.id))
        XCTAssertEqual(library.songForSynchronization(id: song.id)?.filePath, song.filePath)
        XCTAssertTrue(library.songs(forPlaylist: playlist.id).isEmpty)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), [song.id])
        XCTAssertEqual(library.recentPlaybackSongIDsForSync, [song.id])

        let identity = SongIdentity(songID: song.id, title: song.title,
            artistName: song.artistName, duration: song.duration,
            cloudAccountID: nil, filePath: song.filePath)
        library.applyRemotePlaylist(playlist, songIDs: [song.id], identities: [identity])
        library.applyRemotePlaybackHistory(songIDs: [song.id], identities: [identity])
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Snapshot did not persist")
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("library-cache.json"))
        let receiverDirectory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: receiverDirectory) }
        try data.write(to: receiverDirectory.appendingPathComponent("library-cache.json"))
        let receiver = MusicLibrary(storageDirectory: receiverDirectory)
        XCTAssertEqual(receiver.songs(forPlaylist: playlist.id).map(\.id), [song.id])
        XCTAssertEqual(receiver.recentlyPlayedSongs().map(\.id), [song.id])

        let reopened = MusicLibrary(storageDirectory: directory)
        XCTAssertTrue(reopened.songs.isEmpty)
        XCTAssertEqual(reopened.rawSongIDs(forPlaylist: playlist.id), [song.id])
        XCTAssertEqual(reopened.recentPlaybackSongIDsForSync, [song.id])
        XCTAssertEqual(reopened.songForSynchronization(id: song.id)?.id, song.id)
    }

    func testFailedExclusionWriteLeavesLocalRowsAndMembershipIntact() async throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeWebDAVSong()
        library.addSongs([song])
        let playlist = library.createPlaylist(name: "Unchanged")
        library.add(songIDs: [song.id], toPlaylist: playlist.id)
        let ledgerURL = directory.appendingPathComponent("library-device-local-excluded-songs.json")
        try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try library.removeSongsFromThisDevice([song]))
        XCTAssertEqual(library.songs.map(\.id), [song.id])
        XCTAssertFalse(library.isExcludedOnThisDevice(song))
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), [song.id])
        _ = await library.persistNowAndWait()
    }

    func testRemovingSourceDiscardsRetainedSnapshotRows() async throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeWebDAVSong()
        library.addSongs([song])
        try library.removeSongsFromThisDevice([song])
        await library.removeSongsForSource(song.sourceID)
        XCTAssertNil(library.songForSynchronization(id: song.id))
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Snapshot did not persist")
        }
        let reopened = MusicLibrary(storageDirectory: directory)
        XCTAssertNil(reopened.songForSynchronization(id: song.id))
    }

    // MARK: - Tombstoned device-local files the user put back (#134)

    private static func makeLocalSong(
        id: String = "local-track",
        sourceID: String = "local-source",
        filePath: String = "/Album/track.flac"
    ) -> Song {
        Song(
            id: id,
            title: "Track",
            artistName: "Tester",
            duration: 180,
            fileFormat: .flac,
            filePath: filePath,
            sourceID: sourceID
        )
    }

    /// 用户删掉标签不全的几首、改好标签后又把同名文件导了回来。文件此刻确实
    /// 在磁盘上, 所以墓碑必须让路并被撤销, 否则那几首永远进不了资料库。
    func testRescanReadmitsATombstonedLocalFileThatIsBackOnDisk() async throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeLocalSong()
        library.addSongs([song])
        // 界面上的删除是先删掉源文件、确认之后才来删库记录的。
        library.deleteSong(song, sourceFileDeleted: true)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertEqual(library.deletedSongIdentities, ["\(song.sourceID):\(song.filePath)"])

        // 没装探针(离主线程装载 / tvOS)时保持历史行为: 一律拦下。
        library.addSongs([song])
        XCTAssertTrue(library.songs.isEmpty)

        var probedSongIDs: [String] = []
        library.deviceLocalFilePresenceProbe = { candidates in
            probedSongIDs.append(contentsOf: candidates.map(\.id))
            return Set(candidates.map(\.id))
        }
        library.addSongs([song])
        XCTAssertEqual(probedSongIDs, [song.id])
        XCTAssertEqual(library.songs.map(\.id), [song.id])
        XCTAssertTrue(library.deletedSongIdentities.isEmpty)

        // 撤销要落盘, 否则下次冷启动墓碑又把它挡回去。
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Snapshot did not persist")
        }
        let reopened = MusicLibrary(storageDirectory: directory)
        XCTAssertEqual(reopened.songs.map(\.id), [song.id])
        XCTAssertTrue(reopened.deletedSongIdentities.isEmpty)
    }

    /// 竞态: 用户刚删掉一首, 而一轮更早开始的扫描随后才把结果交上来。文件已
    /// 经不在磁盘上, 探针为 false, 删除不能被这次迟到的 flush 撤销。
    func testAStaleScanFlushDoesNotUndoADeletionWhenTheFileIsGone() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeLocalSong()
        library.addSongs([song])
        library.deleteSong(song, sourceFileDeleted: true)
        library.deviceLocalFilePresenceProbe = { _ in [] }

        library.addSongs([song])
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertEqual(library.deletedSongIdentities, ["\(song.sourceID):\(song.filePath)"])
    }

    /// 「从本机移除」那本账的语义就是源文件故意留在原处, 所以文件在磁盘上是
    /// 常态而不是证据。它只能由设置里的恢复界面撤销。
    func testADeviceLocalExclusionIsNeverRevokedByAScan() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeLocalSong()
        library.addSongs([song])
        try library.removeSongsFromThisDevice([song])
        library.deviceLocalFilePresenceProbe = { candidates in Set(candidates.map(\.id)) }

        library.addSongs([song])
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.isExcludedOnThisDevice(song))
        XCTAssertTrue(library.deletedSongIdentities.isEmpty)
    }

    /// 常态零开销: 库里没有任何删除记录时, 准入判定连探针都不该问一次。
    func testTheProbeIsNotConsultedWhenNothingWasEverDeleted() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        var probeCallCount = 0
        library.deviceLocalFilePresenceProbe = { _ in
            probeCallCount += 1
            return []
        }
        library.addSongs([Self.makeLocalSong(), Self.makeLocalSong(
            id: "local-track-2",
            filePath: "/Album/track-2.flac"
        )])
        XCTAssertEqual(library.songs.count, 2)
        XCTAssertEqual(probeCallCount, 0)
    }

    /// 批量删除的「从资料库移除」承诺"源文件不会被删除, 但重新扫描时它们不会
    /// 再被加回"。删库记录时文件还在磁盘上就是这个语义, 复活必须跳过它们。
    func testRemovingFromTheLibraryWhileKeepingTheFileSurvivesARescan() async throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeLocalSong()
        library.addSongs([song])
        // 文件一直在磁盘上 —— 删除前后都是。
        library.deviceLocalFilePresenceProbe = { candidates in Set(candidates.map(\.id)) }
        library.deleteSong(song, sourceFileDeleted: false)
        XCTAssertTrue(library.songs.isEmpty)

        library.addSongs([song])
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertFalse(library.deletedSongIdentities.isEmpty)

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Snapshot did not persist")
        }
        let reopened = MusicLibrary(storageDirectory: directory)
        reopened.deviceLocalFilePresenceProbe = { candidates in Set(candidates.map(\.id)) }
        reopened.addSongs([song])
        XCTAssertTrue(reopened.songs.isEmpty)
    }

    /// 另一首歌的墓碑还在, 不能被这一批的复活顺手带走。
    func testOnlyTheIdentitiesWhoseFilesCameBackAreRevoked() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let restored = Self.makeLocalSong()
        let stillGone = Self.makeLocalSong(id: "local-track-2", filePath: "/Album/track-2.flac")
        library.addSongs([restored, stillGone])
        library.deleteSongs([restored, stillGone], sourceFileDeleted: true)
        XCTAssertEqual(library.deletedSongIdentities.count, 2)

        library.deviceLocalFilePresenceProbe = { candidates in
            Set(candidates.filter { $0.id == restored.id }.map(\.id))
        }
        library.addSongs([restored, stillGone])
        XCTAssertEqual(library.songs.map(\.id), [restored.id])
        XCTAssertEqual(
            library.deletedSongIdentities,
            ["\(stillGone.sourceID):\(stillGone.filePath)"]
        )
    }

    // MARK: - Remote sources: the server put a different file back (#134)

    private static func makeRemoteSong(
        id: String = "webdav-track",
        sourceID: String = "webdav-source",
        filePath: String = "/Music/Album/track.flac",
        fileSize: Int64 = 5_000_000,
        lastModified: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        revision: String? = nil
    ) -> Song {
        var song = Song(
            id: id,
            title: "Track",
            artistName: "Tester",
            duration: 180,
            fileFormat: .flac,
            filePath: filePath,
            sourceID: sourceID
        )
        song.fileSize = fileSize
        song.lastModified = lastModified
        song.revision = revision
        return song
    }

    /// 服务端上删掉之后又在同一路径放了另一个文件(重新上传了改好标签的那份)。
    /// 签名变了就是证据, 墓碑让路。
    func testARemoteFileReplacedAtTheSamePathIsReadmitted() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let original = Self.makeRemoteSong()
        library.addSongs([original])
        library.deleteSongs([original], sourceFileDeleted: true)
        XCTAssertTrue(library.songs.isEmpty)

        // 同一份文件又被扫描到(续扫重放的陈旧目录页): 签名没变, 仍然挡住。
        library.addSongs([original])
        XCTAssertTrue(library.songs.isEmpty)

        // 换了一份: 大小和修改时间都变了。
        let replacement = Self.makeRemoteSong(
            fileSize: 5_400_000,
            lastModified: Date(timeIntervalSince1970: 1_800_000_000)
        )
        library.addSongs([replacement])
        XCTAssertEqual(library.songs.map(\.id), [replacement.id])
        XCTAssertTrue(library.deletedSongIdentities.isEmpty)
        // 撤销要留痕, 否则跨设备并集会把墓碑带回来。
        let key = "\(original.sourceID):\(original.filePath)"
        XCTAssertNotNil(library.deletedSongIdentityDetails[key]?.revivedAt)
    }

    /// 「从资料库移除」承诺过源文件保留、重扫不会加回。用户之后给整个文件夹
    /// 批量重写标签会改掉所有文件的大小与修改时间 —— 不能因此全带回来。
    func testALibraryOnlyRemovalIsNotRevivedByRewrittenTags() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeRemoteSong()
        library.addSongs([song])
        library.deleteSongs([song], sourceFileDeleted: false)

        let retagged = Self.makeRemoteSong(
            fileSize: 5_400_000,
            lastModified: Date(timeIntervalSince1970: 1_800_000_000)
        )
        library.addSongs([retagged])
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertEqual(library.deletedSongIdentities, ["\(song.sourceID):\(song.filePath)"])
    }

    /// 本版本之前产生的墓碑没有证据, 远端源那条规则对它们无效。
    func testAnEvidenceFreeTombstoneStillBlocksARemoteRescan() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let song = Self.makeRemoteSong()
        library.addSongs([song])
        // 默认参数就是保守侧, 等价于旧调用方没有交代源文件删没删。
        library.deleteSongs([song])

        let replacement = Self.makeRemoteSong(fileSize: 9_000_000)
        library.addSongs([replacement])
        XCTAssertTrue(library.songs.isEmpty)
    }

    /// 撤销必须扛得住跨设备并集: 另一台设备尚未同步的旧快照里还有这个键。
    func testARevivedIdentityIsNotResurrectedByAnotherDeviceSnapshot() async throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let original = Self.makeRemoteSong()
        library.addSongs([original])
        library.deleteSongs([original], sourceFileDeleted: true)
        let replacement = Self.makeRemoteSong(fileSize: 5_400_000)
        library.addSongs([replacement])
        XCTAssertEqual(library.songs.map(\.id), [replacement.id])
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Snapshot did not persist")
        }

        let key = "\(original.sourceID):\(original.filePath)"
        let localData = try Data(
            contentsOf: directory.appendingPathComponent("library-cache.json")
        )
        // 另一台设备的旧快照: 墓碑还在, 没有证据表。
        let staleIncoming = try XCTUnwrap(
            "{\"songs\":[],\"playlists\":[],\"deletedSongIdentities\":[\"\(key)\"]}"
                .data(using: .utf8)
        )
        let merged = try MusicLibrary.mergingSnapshotUserState(
            localData: localData,
            incomingData: staleIncoming,
            locallyRetainedSongIDs: []
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: merged) as? [String: Any]
        )
        let tombstones = object["deletedSongIdentities"] as? [String] ?? []
        XCTAssertFalse(tombstones.contains(key))

        // 重新装载合并后的快照, 替换那一份仍然在库里。
        let receiving = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: receiving) }
        try merged.write(to: receiving.appendingPathComponent("library-cache.json"))
        let reopened = MusicLibrary(storageDirectory: receiving)
        XCTAssertTrue(reopened.deletedSongIdentities.isEmpty)
        reopened.addSongs([replacement])
        XCTAssertEqual(reopened.songs.map(\.id), [replacement.id])
    }

    /// 撤销之后再删一次同一路径, 墓碑要重新生效。
    func testDeletingTheSamePathAgainAfterARevivalBlocksOnceMore() throws {
        let directory = try Self.makeIsolatedStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let original = Self.makeRemoteSong()
        library.addSongs([original])
        library.deleteSongs([original], sourceFileDeleted: true)
        let replacement = Self.makeRemoteSong(fileSize: 5_400_000)
        library.addSongs([replacement])
        XCTAssertEqual(library.songs.map(\.id), [replacement.id])

        library.deleteSongs([replacement], sourceFileDeleted: true)
        let key = "\(original.sourceID):\(original.filePath)"
        XCTAssertEqual(library.deletedSongIdentities, [key])
        XCTAssertNil(library.deletedSongIdentityDetails[key]?.revivedAt)
        // 同一份再交上来不该放行。
        library.addSongs([replacement])
        XCTAssertTrue(library.songs.isEmpty)
    }

    func testDeniedFailuresOfferDeviceLocalRemovalForAnySourceType() throws {
        let webdav = MusicSource(id: "webdav-source", name: "WebDAV", type: .webdav)
        let smb = MusicSource(id: "smb-source", name: "SMB", type: .smb)
        let permissionDenied = Self.makeWebDAVSong(id: "permission", filePath: "/Music/a.flac")
        let readOnly = Self.makeWebDAVSong(id: "read-only", filePath: "/Music/b.flac")
        let authenticationRequired = Self.makeWebDAVSong(id: "auth", filePath: "/Music/c.flac")
        let mixed = Self.makeWebDAVSong(id: "mixed", filePath: "/Music/d.flac")

        let webdavFailure = DuplicateCleanupService.SourceFailure(
            source: webdav,
            songs: [permissionDenied, readOnly, authenticationRequired, mixed],
            reasons: [.permissionDenied, .readOnly, .authenticationRequired, .unavailable],
            reasonsBySongID: [
                permissionDenied.id: [.permissionDenied],
                readOnly.id: [.readOnly],
                authenticationRequired.id: [.authenticationRequired],
                mixed.id: [.permissionDenied, .unavailable],
            ]
        )
        XCTAssertTrue(webdavFailure.supportsDeviceLocalRemoval)
        XCTAssertEqual(
            Set(webdavFailure.deviceLocalRemovableSongs.map(\.id)),
            [permissionDenied.id, readOnly.id]
        )

        let smbSong = Self.makeWebDAVSong(id: "smb-song", sourceID: smb.id, filePath: "/Music/e.flac")
        let smbFailure = DuplicateCleanupService.SourceFailure(
            source: smb,
            songs: [smbSong],
            reasons: [.permissionDenied],
            reasonsBySongID: [smbSong.id: [.permissionDenied]]
        )
        XCTAssertTrue(smbFailure.supportsDeviceLocalRemoval)
        XCTAssertEqual(smbFailure.deviceLocalRemovableSongs.map(\.id), [smbSong.id])
    }
}
