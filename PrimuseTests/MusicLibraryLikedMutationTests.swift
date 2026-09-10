import Foundation
import PrimuseKit
import XCTest
import UIKit
@testable import Primuse

@MainActor
final class LibraryReviewTests: XCTestCase {
    func testReviewNormalizationPersistenceAndDeletionTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseReviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let subject = LibraryReviewSubject.album("album-1")
        let library = MusicLibrary(storageDirectory: directory)
        library.updateLibraryReview(
            for: subject,
            rating: 8,
            comment: "  值得反复听  ",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(library.libraryReview(for: subject)?.rating)
        XCTAssertEqual(library.libraryReview(for: subject)?.comment, "值得反复听")
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Review snapshot should persist")
        }

        let restored = MusicLibrary(storageDirectory: directory)
        XCTAssertEqual(restored.libraryReview(for: subject)?.comment, "值得反复听")
        restored.updateLibraryReview(
            for: subject,
            rating: nil,
            comment: "",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertNil(restored.libraryReview(for: subject))
        XCTAssertEqual(restored.allLibraryReviews.count, 1)
        XCTAssertTrue(restored.allLibraryReviews[0].isDeleted)
    }

    func testNewerReviewWinsSnapshotReconciliationIncludingDeletion() {
        let subject = LibraryReviewSubject.song("song-1")
        let active = LibraryReview(
            subject: subject,
            rating: 5,
            comment: "旧评论",
            updatedAt: Date(timeIntervalSince1970: 100),
            deletedAt: nil
        )
        let deleted = LibraryReview(
            subject: subject,
            rating: nil,
            comment: "",
            updatedAt: Date(timeIntervalSince1970: 200),
            deletedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            LibraryReviewReconciliationPolicy.winner(local: active, remote: deleted),
            deleted
        )
        XCTAssertEqual(
            LibraryReviewReconciliationPolicy.winner(local: deleted, remote: active),
            deleted
        )
    }
}

@MainActor
final class MusicLibraryLikedMutationTests: XCTestCase {
    func testBatchLikedMembershipEmitsOnlyActualChangesAndRollbackDoesNotReenter() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLikedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )

        try await exerciseLikedMutations(storageDirectory: storageDirectory)
        try FileManager.default.removeItem(at: storageDirectory)
    }

    private func exerciseLikedMutations(storageDirectory: URL) async throws {
        let library = MusicLibrary(storageDirectory: storageDirectory)
        let songs = [
            makeSong(id: "song-1", path: "/songs/remote-1.mp3"),
            makeSong(id: "song-2", path: "/songs/remote-2.mp3"),
        ]
        library.addSongs(songs, affectedSourceIDs: ["source-1"])
        library.ensurePlaylist(id: MusicLibrary.likedSongsPlaylistID, name: "Liked")
        let regular = library.createPlaylist(name: "Regular")

        var mutations: [(songID: String, previous: Bool, desired: Bool)] = []
        library.likedStateMutationHandler = { song, previous, desired in
            mutations.append((song.id, previous, desired))
        }

        library.add(songIDs: ["song-1", "song-2", "song-1"], toPlaylist: MusicLibrary.likedSongsPlaylistID)
        XCTAssertEqual(mutations.map(\.songID), ["song-1", "song-2"])
        XCTAssertEqual(mutations.map(\.desired), [true, true])

        library.add(songIDs: ["song-1", "song-2"], toPlaylist: MusicLibrary.likedSongsPlaylistID)
        XCTAssertEqual(mutations.count, 2, "Repeated membership must be idempotent")

        library.remove(songIDs: ["song-1", "song-1"], fromPlaylist: MusicLibrary.likedSongsPlaylistID)
        XCTAssertEqual(mutations.map(\.songID), ["song-1", "song-2", "song-1"])
        XCTAssertEqual(mutations.last?.previous, true)
        XCTAssertEqual(mutations.last?.desired, false)

        library.add(songIDs: ["song-1", "song-2"], toPlaylist: regular.id)
        library.remove(songIDs: ["song-1"], fromPlaylist: regular.id)
        XCTAssertEqual(mutations.count, 3, "Ordinary playlists must not trigger server favorites")

        library.setLiked(
            songID: "song-2",
            isLiked: false,
            propagatesServerMutation: false
        )
        XCTAssertEqual(mutations.count, 3, "Recovery changes must not recursively write to the server")

        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }
    }

    private func makeSong(id: String, path: String) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .mp3,
            filePath: path,
            sourceID: "source-1"
        )
    }
}

@MainActor
final class MusicLibraryMetadataReplacementTests: XCTestCase {
    func testSourceListsKeepUnrelatedCachesAndTrackAssetsMigrationAndVisibility() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseSourceSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let first = makeSong(id: "first", path: "/first.mp3")
        var second = makeSong(id: "second", path: "/second.mp3")
        second.sourceID = "source-2"
        library.addSongs([first, second], affectedSourceIDs: [first.sourceID, second.sourceID])
        for _ in 0..<200 where library.visibleSongs.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.count, 2)
        let firstState = library.sourceSongListState(for: first.sourceID)
        let secondState = library.sourceSongListState(for: second.sourceID)
        let firstVersion = firstState.version
        let secondVersion = secondState.version
        let store = SongListSnapshotStore()
        let cached = await store.snapshot(scopeKey: first.sourceID, version: firstVersion, order: .duration, songs: firstState.songs)

        second.bitRate = 320
        await library.replaceSongsPreparedOffMain([second], maintenance: .deferred)
        XCTAssertEqual(firstState.version, firstVersion)
        XCTAssertNotEqual(secondState.version, secondVersion)
        XCTAssertEqual(secondState.replacedSongIDs, [second.id])
        let reused = await store.snapshot(scopeKey: first.sourceID, version: firstState.version, order: .duration, songs: firstState.songs)
        XCTAssertTrue(try XCTUnwrap(cached) === XCTUnwrap(reused))

        let secondMetadataVersion = secondState.version
        library.updateAssetReferences(songID: first.id, coverRef: "first-cover.jpg", lyricsRef: "first.lrc")
        library.updateMusicVideoReference(songID: first.id, mvPath: "/first.mp4")
        library.updateLyricsText([first.id: "Updated lyrics"])
        XCTAssertNotEqual(firstState.version, firstVersion)
        XCTAssertEqual(secondState.version, secondMetadataVersion)
        let refreshed = try XCTUnwrap(firstState.songs.first)
        XCTAssertEqual(refreshed.coverArtFileName, "first-cover.jpg")
        XCTAssertEqual(refreshed.lyricsFileName, "first.lrc")
        XCTAssertEqual(refreshed.mvPath, "/first.mp4")
        XCTAssertEqual(refreshed.lyricsText, "Updated lyrics")

        var moved = refreshed
        moved.sourceID = second.sourceID
        await library.replaceSongsPreparedOffMain([moved], maintenance: .deferred)
        XCTAssertTrue(firstState.songs.isEmpty)
        XCTAssertEqual(Set(secondState.songs.map(\.id)), [first.id, second.id])
        library.updateDisabledSourceIDs([second.sourceID])
        XCTAssertTrue(secondState.songs.isEmpty)
        library.updateDisabledSourceIDs([])
        XCTAssertTrue(secondState === library.sourceSongListState(for: second.sourceID))
        XCTAssertEqual(secondState.songs.count, 2)
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Source snapshot fixture did not finish persistence")
        }
    }

    func testDeferredMaintenancePreservesMetadataUntilEnvironmentAllowsRebuild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseDeferredMaintenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowsMaintenance = false
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { allowsMaintenance }
        )
        var song = makeSong(id: "deferred", path: "/music/deferred.mp3")
        song.albumTitle = "Original"
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        await library.waitForPendingIndex()
        let revision = library.spotlightIndexRevision

        for album in ["Intermediate", "Latest"] {
            song.albumTitle = album
            song.duration = 193
            await library.replaceSongsPreparedOffMain([song], maintenance: .deferred)
            library.flushDeferredLibraryMaintenance()
        }
        XCTAssertEqual(library.song(id: song.id)?.albumTitle, "Latest")
        XCTAssertEqual(library.unobservedVisibleSong(id: song.id)?.duration, 193)
        XCTAssertEqual(library.albums.map(\.title), ["Original"])
        XCTAssertEqual(library.spotlightIndexRevision, revision)
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Deferred grouping must not defer song persistence")
        }
        let restored = MusicLibrary(storageDirectory: directory)
        XCTAssertEqual(restored.song(id: song.id)?.albumTitle, "Latest")

        allowsMaintenance = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<100 where library.spotlightIndexRevision == revision {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.spotlightIndexRevision, revision + 1)
        await library.waitForPendingIndex()
        XCTAssertEqual(library.albums.map(\.title), ["Latest"])
        XCTAssertEqual(library.spotlightIndexRevision, revision + 1)
        library.flushDeferredLibraryMaintenance()
        XCTAssertEqual(library.spotlightIndexRevision, revision + 1)
    }

    func testExplicitIndexBarrierCompletesWhileAutomaticMaintenanceIsDeferred() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseMaintenanceBarrier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        var song = makeSong(id: "barrier", path: "/music/barrier.mp3")
        song.albumTitle = "Before"
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        await library.waitForPendingIndex()
        song.albumTitle = "After"
        await library.replaceSongsPreparedOffMain([song], maintenance: .deferred)
        await library.waitForPendingIndex()
        XCTAssertEqual(library.albums.map(\.title), ["After"])
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The index barrier must preserve song persistence")
        }
    }

    func testPreparedMetadataReplacementPatchesStableLibraryCaches() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseMetadataReplacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let first = makeSong(id: "song-1", path: "/music/one.mp3")
        let second = makeSong(id: "song-2", path: "/music/two.mp3")
        library.addSongs([first, second], affectedSourceIDs: ["source-1"])

        for _ in 0..<200 where library.visibleSongs.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.map(\.id), ["song-1", "song-2"])

        let collectionRevision = library.visibleSongCollectionRevision
        let replacementToken = library.songReplacementToken
        let invalidationRevision = library.songListSnapshotInvalidationRevision
        var updated = first
        updated.duration = 193
        updated.bitRate = 320

        await library.replaceSongsPreparedOffMain([updated], maintenance: .deferred)

        XCTAssertEqual(library.song(id: first.id)?.duration, 193)
        XCTAssertEqual(library.unobservedVisibleSong(id: first.id)?.bitRate, 320)
        XCTAssertEqual(
            library.visibleSongs(forSourceID: first.sourceID).first(where: { $0.id == first.id })?.duration,
            193
        )
        XCTAssertEqual(library.visibleSongCollectionRevision, collectionRevision)
        XCTAssertNotEqual(library.songReplacementToken, replacementToken)
        XCTAssertEqual(library.lastReplacedSongIDs, [first.id])
        XCTAssertEqual(library.songListSnapshotInvalidationRevision, invalidationRevision)
        XCTAssertEqual(library.songs.map(\.id), ["song-1", "song-2"])

        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }
    }

    func testPreparedReplacementMarksPlayabilitySnapshotChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimusePlayabilityReplacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        var song = makeSong(id: "playable", path: "")
        library.addSongs([song], affectedSourceIDs: [song.sourceID])

        let invalidationRevision = library.songListSnapshotInvalidationRevision
        song.duration = 193
        await library.replaceSongsPreparedOffMain([song], maintenance: .deferred)

        XCTAssertTrue(library.unobservedVisibleSong(id: song.id)?.isPlayable == true)
        XCTAssertEqual(
            library.songListSnapshotInvalidationRevision,
            invalidationRevision + 1
        )
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The playability replacement did not finish persistence")
        }
    }

    func testSourceReplacementMarksMembershipSnapshotChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseSourceReplacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        var song = makeSong(id: "moved", path: "/music/moved.mp3")
        library.addSongs([song], affectedSourceIDs: [song.sourceID])

        let invalidationRevision = library.songListSnapshotInvalidationRevision
        song.sourceID = "source-2"
        library.replaceSong(song)

        XCTAssertEqual(library.unobservedVisibleSong(id: song.id)?.sourceID, "source-2")
        XCTAssertEqual(
            library.songListSnapshotInvalidationRevision,
            invalidationRevision + 1
        )
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The source replacement did not finish persistence")
        }
    }

    func testStructuralInvalidationSurvivesFollowingMetadataReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseReplacementInvalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        var song = makeSong(id: "sequence", path: "/music/sequence.mp3")
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        let initialRevision = library.songListSnapshotInvalidationRevision

        song.sourceID = "source-2"
        library.replaceSong(song)
        var metadataOnly = song
        metadataOnly.albumTitle = "Updated"
        library.replaceSong(metadataOnly)

        XCTAssertEqual(
            library.songListSnapshotInvalidationRevision,
            initialRevision + 1,
            "A later metadata replacement must not erase structural invalidation"
        )
        XCTAssertEqual(library.song(id: song.id)?.albumTitle, "Updated")
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The sequential replacements did not finish persistence")
        }
    }

    private func makeSong(id: String, path: String) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .mp3,
            filePath: path,
            sourceID: "source-1"
        )
    }
}

@MainActor
final class MusicLibraryDerivedIndexRecoveryTests: XCTestCase {
    /// 派生重建落地前被一次"不请求派生维护"的 mutation 作废时, 必须自己补发,
    /// 否则 `songs` 已经有新歌而 visibleSongs / visibleAlbums 会一直停在扫描前。
    func testMutationDuringIndexRebuildDoesNotLeaveVisibleCachesStale() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseIndexRequeue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { true }
        )

        var first = makeSong(id: "first", path: "/music/first.mp3")
        first.albumTitle = "Album A"
        library.addSongs([first], affectedSourceIDs: [first.sourceID])
        await library.waitForPendingIndex()
        XCTAssertEqual(library.visibleSongs.map(\.id), ["first"])

        var second = makeSong(id: "second", path: "/music/second.mp3")
        second.albumTitle = "Album B"
        // 启动一次异步派生重建 (250ms 防抖), 不等待它落地。
        library.addSongs(
            [second],
            affectedSourceIDs: [second.sourceID],
            pruneMissingSongs: false
        )
        // 防抖窗口内推进 songMutationGeneration, 且这条路径从不请求派生重建。
        library.updateAssetReferences(songID: "first", coverRef: "first-cover.jpg")

        await library.waitForPendingIndex()

        XCTAssertEqual(Set(library.visibleSongs.map(\.id)), ["first", "second"])
        XCTAssertEqual(Set(library.visibleAlbums.map(\.title)), ["Album A", "Album B"])
        XCTAssertNotNil(library.unobservedVisibleSong(id: "second"))
        XCTAssertEqual(
            library.unobservedVisibleSong(id: "first")?.coverArtFileName,
            "first-cover.jpg",
            "补发的重建必须带上更新后的引用, 而不是用旧快照盖回去"
        )

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The requeued rebuild fixture did not finish persistence")
        }
    }

    /// 离主线程准备好的补丁不能盖掉在它挂起期间发布的、更新的可见缓存。
    func testDelayedPreparedReplacementRebasesOnFresherVisibleCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseVisibleCacheRebase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { true }
        )

        let a = makeSong(id: "a", path: "/music/a.mp3")
        let b = makeSong(id: "b", path: "/music/b.mp3")
        library.addSongs([a, b], affectedSourceIDs: ["source-1"])
        await library.waitForPendingIndex()
        XCTAssertEqual(library.visibleSongs.map(\.id), ["a", "b"])

        // 准备耗时长于 250ms 防抖, 于是派生重建一定先发布 [a, b, c]。
        library.stableMetadataPreparationDelayForTesting = Duration.milliseconds(500)
        library.addSongs(
            [makeSong(id: "c", path: "/music/c.mp3")],
            affectedSourceIDs: ["source-1"],
            pruneMissingSongs: false
        )
        var patched = a
        patched.duration = 193
        await library.replaceSongsPreparedOffMain([patched], maintenance: .deferred)
        library.stableMetadataPreparationDelayForTesting = nil

        XCTAssertEqual(library.visibleSongs.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(library.songCount, 3)
        XCTAssertNotNil(library.visibleSong(id: "c"))
        XCTAssertEqual(library.unobservedVisibleSong(id: "a")?.duration, 193)
        XCTAssertEqual(
            Set(library.visibleSongs(forSourceID: "source-1").map(\.id)),
            ["a", "b", "c"]
        )

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The rebased replacement fixture did not finish persistence")
        }
    }

    /// 单行元数据替换不该在主 actor 上重算整库可见查找表。
    func testMetadataOnlyReplaceSongKeepsWholeLibraryVisibleLookups() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseSingleRowReplace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { true }
        )
        let catalogue = (0..<50).map { makeSong(id: "song-\($0)", path: "/music/\($0).mp3") }
        library.addSongs(catalogue, affectedSourceIDs: ["source-1"])
        await library.waitForPendingIndex()
        XCTAssertEqual(library.visibleSongs.count, 50)

        let artworkRevision = library.albumArtworkLookupRevision
        let collectionRevision = library.visibleSongCollectionRevision
        let invalidationRevision = library.songListSnapshotInvalidationRevision
        let replacementToken = library.songReplacementToken

        var updated = try XCTUnwrap(library.song(id: "song-7"))
        updated.duration = 193
        library.replaceSong(updated)

        XCTAssertEqual(library.song(id: "song-7")?.duration, 193)
        XCTAssertEqual(library.unobservedVisibleSong(id: "song-7")?.duration, 193)
        XCTAssertEqual(
            library.visibleSongs(forSourceID: "source-1").first(where: { $0.id == "song-7" })?.duration,
            193
        )
        XCTAssertEqual(library.lastReplacedSong?.id, "song-7")
        XCTAssertEqual(library.lastReplacedSongIDs, ["song-7"])
        XCTAssertNotEqual(library.songReplacementToken, replacementToken)
        XCTAssertEqual(library.songListSnapshotInvalidationRevision, invalidationRevision)
        XCTAssertEqual(
            library.albumArtworkLookupRevision,
            artworkRevision,
            "元数据替换不应触发整库可见缓存重建"
        )
        XCTAssertEqual(library.visibleSongCollectionRevision, collectionRevision)

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The single-row replacement fixture did not finish persistence")
        }
    }

    private func makeSong(id: String, path: String) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .mp3,
            filePath: path,
            sourceID: "source-1"
        )
    }
}

@MainActor
final class MusicLibraryPersistenceSchedulingTests: XCTestCase {
    /// backfill 的 30s 合并写不能把已经武装好的 2s 用户操作落盘顶掉。
    func testCoalescedBackfillFlushDoesNotStarvePromptUserMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimusePersistDeadline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let liked = makeSong(id: "liked", path: "/music/liked.mp3")
        var other = makeSong(id: "other", path: "/music/other.mp3")
        library.addSongs([liked, other], affectedSourceIDs: ["source-1"])
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The persistence-scheduling fixture did not finish its baseline write")
        }

        library.toggleLiked(songID: "liked")
        XCTAssertTrue(library.isLiked(songID: "liked"))
        other.albumTitle = "Coalesced"
        library.replaceSongs([other])
        XCTAssertTrue(library.hasPendingPortableSnapshotChanges)

        for _ in 0..<600 where library.hasPendingPortableSnapshotChanges {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(
            library.hasPendingPortableSnapshotChanges,
            "点赞武装的短定时器必须继续生效, 而不是被 30s 合并写推后"
        )

        let restored = MusicLibrary(storageDirectory: directory)
        XCTAssertTrue(restored.isLiked(songID: "liked"))
        XCTAssertEqual(restored.song(id: "other")?.albumTitle, "Coalesced")
    }

    private func makeSong(id: String, path: String) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .mp3,
            filePath: path,
            sourceID: "source-1"
        )
    }
}

@MainActor
final class MusicLibraryIncrementalRecoveryTests: XCTestCase {
    /// 恢复写入必须留在 songStoreWriteTask 链上, 否则等待期间产生的增量
    /// 会被更旧的恢复快照覆盖 (或者被挤出链外, 成败无人观察)。
    func testRecoveryWriteKeepsConcurrentDeltaInTheSongStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseSongStoreRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = MusicLibrary(storageDirectory: directory)
        seed.addSongs([makeSong(id: "old", path: "/music/old.mp3")], affectedSourceIDs: ["source-1"])
        guard case .success = await seed.persistNowAndWait() else {
            return XCTFail("The seed library did not finish persistence")
        }

        // 第一次调用是装载期的迁移写入 —— 让它失败以武装
        // songStoreRequiresReplacement; 第二次调用就是 flushIncrementalSongStore
        // 的恢复写入, 停在闸门上等测试插入一次并发增量。
        let firstCallToken = DispatchSemaphore(value: 1)
        let recoveryEntered = DispatchSemaphore(value: 0)
        let recoveryRelease = DispatchSemaphore(value: 0)
        let writer: @Sendable (IncrementalSongStore, [Song], String?) throws -> Int64 = { store, songs, importID in
            if firstCallToken.wait(timeout: .now()) == .success {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            recoveryEntered.signal()
            _ = recoveryRelease.wait(timeout: .now() + 10)
            return try store.replaceAll(with: songs, snapshotImportID: importID)
        }

        let library = MusicLibrary(
            storageDirectory: directory,
            preferExternalSnapshot: true,
            songStoreSnapshotWriter: writer
        )
        let flush = Task { await library.persistIncrementalNowAndWait() }

        var didEnterRecovery = false
        for _ in 0..<500 {
            if recoveryEntered.wait(timeout: .now()) == .success {
                didEnterRecovery = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(didEnterRecovery, "The recovery write must be in flight before the delta")

        library.addSongs(
            [makeSong(id: "later", path: "/music/later.mp3")],
            affectedSourceIDs: ["source-1"],
            pruneMissingSongs: false
        )
        try await Task.sleep(for: .milliseconds(200))
        recoveryRelease.signal()

        guard case .success = await flush.value else {
            return XCTFail("The chained recovery must report a durable commit")
        }
        guard case .success = await library.persistIncrementalNowAndWait() else {
            return XCTFail("Draining the song-store chain must succeed")
        }

        let database = try IncrementalSongStore(
            path: directory.appendingPathComponent("library-songs.sqlite").path
        )
        XCTAssertEqual(Set(try database.loadSongs().map(\.id)), ["old", "later"])
        XCTAssertEqual(Set(library.songs.map(\.id)), ["old", "later"])
    }

    private func makeSong(id: String, path: String) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .mp3,
            filePath: path,
            sourceID: "source-1"
        )
    }
}
