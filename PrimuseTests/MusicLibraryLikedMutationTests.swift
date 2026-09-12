import Foundation
import os
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
        // 旁挂资源补丁按 300ms 一批发布; 需要立刻读回来的调用方 (这里是断言)
        // 与整行替换/持久化屏障一样先同步 flush。
        library.flushPendingAssetReferencePatches()
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
        library.flushPendingAssetReferencePatches()

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

    /// 补发只允许一次: 同一轮"丢弃连击"里的后续重叠必须交回 60s 维护节奏,
    /// 否则批量刮削 / 回填期间整库分组会背靠背连跑, 每次落地又会作废正在
    /// 准备的 off-main 补丁。
    func testOverlappingMutationsRequeueTheDerivedRebuildOnlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseIndexRequeueCoalescing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { true }
        )

        var first = makeSong(id: "first", path: "/music/first.mp3")
        first.albumTitle = "Album A"
        var second = makeSong(id: "second", path: "/music/second.mp3")
        second.albumTitle = "Album B"
        library.addSongs([first, second], affectedSourceIDs: [first.sourceID])
        await library.waitForPendingIndex()
        XCTAssertEqual(library.immediateIndexRequeueCountForMaintenance, 0)

        var third = makeSong(id: "third", path: "/music/third.mp3")
        third.albumTitle = "Album C"
        // 启动一次异步派生重建 (250ms 防抖), 不等待它落地。
        library.addSongs(
            [third],
            affectedSourceIDs: [third.sourceID],
            pruneMissingSongs: false
        )
        // 防抖窗口内推进 songMutationGeneration: 结果被丢弃, 允许补发一次。
        library.updateAssetReferences(songID: "first", coverRef: "first-cover.jpg")
        library.flushPendingAssetReferencePatches()

        var polls = 0
        while library.immediateIndexRequeueCountForMaintenance == 0, polls < 40 {
            try await Task.sleep(for: .milliseconds(50))
            polls += 1
        }
        XCTAssertEqual(
            library.immediateIndexRequeueCountForMaintenance,
            1,
            "第一次丢弃仍然要立刻补发一次, 否则可见缓存会停在扫描前"
        )

        // 补发的那次重建还在防抖窗口里; 再作废一次不能再触发立即重算。
        library.updateAssetReferences(songID: "second", coverRef: "second-cover.jpg")
        library.flushPendingAssetReferencePatches()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(
            library.immediateIndexRequeueCountForMaintenance,
            1,
            "同一轮连击里的第二次丢弃必须交给 60s 维护节奏"
        )

        // 交给维护节奏之后仍然收敛: 先把补发那一轮排空, 再走一次 flush。
        await library.waitForPendingIndex()
        library.flushDeferredLibraryMaintenance(force: true)
        await library.waitForPendingIndex()

        XCTAssertEqual(
            library.immediateIndexRequeueCountForMaintenance,
            1,
            "整段过程只允许一次立即补发"
        )
        XCTAssertEqual(Set(library.visibleSongs.map(\.id)), ["first", "second", "third"])
        XCTAssertEqual(
            Set(library.visibleAlbums.map(\.title)),
            ["Album A", "Album B", "Album C"]
        )
        XCTAssertEqual(
            library.unobservedVisibleSong(id: "first")?.coverArtFileName,
            "first-cover.jpg"
        )
        XCTAssertEqual(
            library.unobservedVisibleSong(id: "second")?.coverArtFileName,
            "second-cover.jpg"
        )

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The coalesced requeue fixture did not finish persistence")
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

    /// A2c: 刮削一轮会逐首调 `updateAssetReferences`, 逐首发布等于每首都整份
    /// 拷贝 songs / visibleSongs。窗口内的补丁必须合成一次发布, 且每一首的
    /// 最终值都要落到库里。
    func testAssetReferencePatchesCoalesceIntoOnePublication() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseAssetPatchBatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { true }
        )
        let catalogue = (0..<6).map { makeSong(id: "song-\($0)", path: "/music/\($0).mp3") }
        library.addSongs(catalogue, affectedSourceIDs: ["source-1"])
        await library.waitForPendingIndex()

        let generation = library.songMutationGenerationForMaintenance
        let replacementToken = library.songReplacementToken
        for song in catalogue {
            library.updateAssetReferences(songID: song.id, coverRef: "\(song.id)-cover.jpg")
        }
        library.updateAssetReferences(songID: "song-0", lyricsRef: "song-0.lrc")
        library.updateMusicVideoReference(songID: "song-1", mvPath: "/music/1.mp4")
        XCTAssertEqual(
            library.songMutationGenerationForMaintenance,
            generation,
            "窗口内的补丁不能逐首发布"
        )

        var polls = 0
        while library.songMutationGenerationForMaintenance == generation, polls < 60 {
            try await Task.sleep(for: .milliseconds(50))
            polls += 1
        }
        XCTAssertEqual(
            library.songMutationGenerationForMaintenance,
            generation &+ 1,
            "8 次补丁只允许一次 songs 发布"
        )
        XCTAssertNotEqual(library.songReplacementToken, replacementToken)
        for song in catalogue {
            XCTAssertEqual(
                library.song(id: song.id)?.coverArtFileName,
                "\(song.id)-cover.jpg",
                "这一批里每一首的最终值都必须生效"
            )
            XCTAssertEqual(
                library.unobservedVisibleSong(id: song.id)?.coverArtFileName,
                "\(song.id)-cover.jpg"
            )
            XCTAssertEqual(
                library.visibleSongs(forSourceID: "source-1")
                    .first(where: { $0.id == song.id })?.coverArtFileName,
                "\(song.id)-cover.jpg"
            )
        }
        XCTAssertEqual(library.song(id: "song-0")?.lyricsFileName, "song-0.lrc")
        XCTAssertEqual(library.song(id: "song-1")?.mvPath, "/music/1.mp4")
        XCTAssertEqual(library.lastReplacedSongIDs.count, catalogue.count)
        XCTAssertNil(library.lastReplacedSong, "一批多首时不指向单首, 与 addSongs 的约定一致")

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The coalesced asset-patch fixture did not finish persistence")
        }
    }

    /// 刮削的顺序是"读行 → 入队封面补丁 → 用读到的旧行整行回写"(封面走
    /// updateAssetReferences, 紧接着的歌词回写走 replaceSong)。补丁不能被这次
    /// 整行替换盖回去, 反过来整行替换之后入队的补丁也照常落地。
    func testPendingAssetPatchSurvivesWholeRowReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseAssetPatchLostUpdate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { true }
        )
        library.addSongs(
            [
                makeSong(id: "song-0", path: "/music/0.mp3"),
                makeSong(id: "song-1", path: "/music/1.mp3"),
            ],
            affectedSourceIDs: ["source-1"]
        )
        await library.waitForPendingIndex()

        // 调用方在补丁入队之前读到的行 —— 封面还是空的。
        let staleRow = try XCTUnwrap(library.song(id: "song-0"))
        XCTAssertNil(staleRow.coverArtFileName)
        library.updateAssetReferences(songID: "song-0", coverRef: "song-0-cover.jpg")
        library.updateMusicVideoReference(songID: "song-0", mvPath: "/music/0.mp4")

        var writeback = staleRow
        writeback.lyricsFileName = "song-0.lrc"
        writeback.lyricsText = "第一行"
        library.replaceSong(writeback)

        XCTAssertEqual(
            library.song(id: "song-0")?.coverArtFileName,
            "song-0-cover.jpg",
            "窗口内的封面补丁不能被更早读到的整行盖回去"
        )
        XCTAssertEqual(library.song(id: "song-0")?.mvPath, "/music/0.mp4")
        XCTAssertEqual(library.song(id: "song-0")?.lyricsFileName, "song-0.lrc")
        XCTAssertEqual(library.song(id: "song-0")?.lyricsText, "第一行")
        XCTAssertEqual(
            library.unobservedVisibleSong(id: "song-0")?.coverArtFileName,
            "song-0-cover.jpg"
        )

        // 批量整行替换 (回填 / 刮削批次) 走同一个约定。
        let staleBatchRow = try XCTUnwrap(library.song(id: "song-1"))
        library.updateAssetReferences(songID: "song-1", lyricsRef: "song-1.lrc")
        var batchWriteback = staleBatchRow
        batchWriteback.albumTitle = "Album B"
        library.replaceSongs([batchWriteback])
        XCTAssertEqual(library.song(id: "song-1")?.lyricsFileName, "song-1.lrc")
        XCTAssertEqual(library.song(id: "song-1")?.albumTitle, "Album B")

        // 反过来: 整行替换在前、补丁在后, 补丁仍然是更新的那一次写入。
        var replaced = try XCTUnwrap(library.song(id: "song-0"))
        replaced.albumTitle = "Album A"
        library.replaceSong(replaced)
        library.updateAssetReferences(songID: "song-0", coverRef: "song-0-sidecar.jpg")
        library.flushPendingAssetReferencePatches()
        XCTAssertEqual(library.song(id: "song-0")?.coverArtFileName, "song-0-sidecar.jpg")
        XCTAssertEqual(library.song(id: "song-0")?.albumTitle, "Album A")

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The lost-update fixture did not finish persistence")
        }
    }

    /// A3: 派生索引落地改成"整组查找表一次换掉 + 旧的一组交给回收队列"。
    /// 换完之后每一个查找器都必须解析出和换之前一样的结果; 封面回退映射没变
    /// 的那次重建不能再 bump `albumArtworkLookupRevision`。
    func testDerivedIndexApplyKeepsLookupsAndBumpsArtworkRevisionOnlyOnChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseDerivedLookupSwap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { true }
        )
        let catalogue: [Song] = (0..<6).map { index in
            var song = makeSong(id: "song-\(index)", path: "/music/\(index).mp3")
            song.albumTitle = "Album \(index % 2)"
            song.artistName = "Artist \(index % 3)"
            song.genre = "Genre \(index % 2)"
            song.coverArtFileName = "cover-\(index).jpg"
            return song
        }
        library.addSongs(catalogue, affectedSourceIDs: ["source-1"])
        await library.waitForPendingIndex()

        let probe = derivedLookupProbe(library)
        XCTAssertFalse(probe.isEmpty)
        let artworkRevision = library.albumArtworkLookupRevision
        let collectionRevision = library.visibleSongCollectionRevision

        // 同样的内容再提交一次: 仍然走完整的派生重建 + 落地。
        library.addSongs(catalogue, affectedSourceIDs: ["source-1"], pruneMissingSongs: false)
        await library.waitForPendingIndex()

        XCTAssertEqual(
            derivedLookupProbe(library),
            probe,
            "换掉整组查找表之后, 每个查找器都要解析出同样的结果"
        )
        XCTAssertEqual(
            library.albumArtworkLookupRevision,
            artworkRevision,
            "封面回退映射没变时不能让每一张专辑 / 歌手卡片失效"
        )
        XCTAssertEqual(library.visibleSongCollectionRevision, collectionRevision)

        // 新专辑 / 新歌手真的改了回退映射 —— 这时必须 bump。
        var extra = makeSong(id: "song-extra", path: "/music/extra.mp3")
        extra.albumTitle = "Album 9"
        extra.artistName = "Artist 9"
        extra.genre = "Genre 9"
        extra.coverArtFileName = "cover-extra.jpg"
        library.addSongs([extra], affectedSourceIDs: ["source-1"], pruneMissingSongs: false)
        await library.waitForPendingIndex()

        XCTAssertGreaterThan(library.albumArtworkLookupRevision, artworkRevision)
        let extraAlbumID = try XCTUnwrap(library.song(id: "song-extra")?.albumID)
        XCTAssertEqual(library.preferredArtworkSong(forAlbumID: extraAlbumID)?.id, "song-extra")

        // 首选回退歌的 ID 不变、只有它自己的封面引用变了 (回填给单曲专辑写入
        // 内嵌封面): 回退映射一模一样, 但每一张用它兜底的卡片都要重新取图。
        let preferredCoverRevision = library.albumArtworkLookupRevision
        var recovered = try XCTUnwrap(library.song(id: "song-extra"))
        recovered.coverArtFileName = "cover-extra-embedded.jpg"
        library.replaceSongs([recovered], maintenance: .deferred)
        XCTAssertGreaterThan(
            library.albumArtworkLookupRevision,
            preferredCoverRevision,
            "首选回退歌自己的封面变了也要让专辑 / 歌手卡片失效"
        )
        await library.waitForPendingIndex()
        XCTAssertEqual(
            library.preferredArtworkSong(forAlbumID: extraAlbumID)?.coverArtFileName,
            "cover-extra-embedded.jpg"
        )

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The derived-lookup fixture did not finish persistence")
        }
    }

    /// A1: 扫描的中间 flush 走短上限的延后维护 —— 扫描结果照旧立刻提交,
    /// 但派生集合与 Spotlight 脏位合并到窗口末尾。
    func testIncrementalScanFlushDefersDerivedMaintenance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseIncrementalFlush-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(
            storageDirectory: directory,
            deferredMaintenanceAllowed: { true }
        )
        let spotlightRevision = library.spotlightIndexRevision

        library.addSongs(
            [makeSong(id: "first", path: "/music/first.mp3")],
            affectedSourceIDs: ["source-1"],
            indexMaintenance: .deferredIncremental
        )
        XCTAssertEqual(library.songs.map(\.id), ["first"], "中间 flush 仍然立刻提交扫描结果")
        XCTAssertEqual(
            library.spotlightIndexRevision,
            spotlightRevision,
            "中间 flush 不再每次都推进 Spotlight 检查点"
        )
        XCTAssertTrue(library.visibleSongs.isEmpty, "派生集合等合并后的维护窗口")

        await library.waitForPendingIndex()
        XCTAssertEqual(library.visibleSongs.map(\.id), ["first"])
        XCTAssertGreaterThan(library.spotlightIndexRevision, spotlightRevision)

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The deferred incremental flush fixture did not finish persistence")
        }

        // 设备忙闸门 (后台 / 热状态不是 nominal) 是给数小时的 backfill 用的。
        // 扫描已经在跑, 挡住它的中间 flush 等于整个扫描期间资料库都是空的。
        let gatedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseIncrementalFlushGated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: gatedDirectory) }
        let gated = MusicLibrary(
            storageDirectory: gatedDirectory,
            deferredMaintenanceAllowed: { false }
        )
        gated.addSongs(
            [makeSong(id: "gated", path: "/music/gated.mp3")],
            affectedSourceIDs: ["source-1"],
            indexMaintenance: .deferredIncremental
        )
        XCTAssertEqual(gated.songs.map(\.id), ["gated"], "中间 flush 仍然立刻提交扫描结果")
        XCTAssertTrue(gated.visibleSongs.isEmpty, "派生集合等合并后的维护窗口")

        var polls = 0
        while gated.visibleSongs.isEmpty, polls < 120 {
            try await Task.sleep(for: .milliseconds(100))
            polls += 1
        }
        XCTAssertEqual(
            gated.visibleSongs.map(\.id),
            ["gated"],
            "闸门关着也要在短窗口末尾重建可见资料库"
        )

        guard case .success = await gated.persistNowAndWait() else {
            return XCTFail("The gated incremental flush fixture did not finish persistence")
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
        // 进入信号要被异步的测试体等待, 所以它是并发原语而不是信号量 ——
        // 信号量的 wait 在异步上下文里不可用。闸门本身仍然是信号量: 注入的
        // 写入闭包是同步的, 必须真的停在那里。
        let recoveryEntered = OneShotSignal()
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

        // 不轮询也不靠 sleep 去猜: 等到恢复写入真的进到闸门上再插增量。
        await recoveryEntered.wait()

        // `addSongs` 在主 actor 上同步把这笔增量挂到写入链上 (persistSongChanges
        // 当场就给 songStoreWriteTask 赋上新任务), 所以它返回时增量已经排在
        // 被挡住的恢复写入后面, 不需要再等一段时间去确认。
        library.addSongs(
            [makeSong(id: "later", path: "/music/later.mp3")],
            affectedSourceIDs: ["source-1"],
            pruneMissingSongs: false
        )
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

/// 把所有由派生索引查找表支撑的访问器拍成一份可比较的快照。派生重建落地
/// 之后这份快照必须逐行相同 —— 换掉的是持有方式, 不是查询结果。
@MainActor
private func derivedLookupProbe(_ library: MusicLibrary) -> [String] {
    var lines: [String] = []
    for song in library.songs.sorted(by: { $0.id < $1.id }) {
        lines.append("song:\(song.id)=\(library.song(id: song.id)?.coverArtFileName ?? "-")")
        lines.append("visible:\(song.id)=\(library.unobservedVisibleSong(id: song.id)?.id ?? "-")")
        lines.append("contains:\(song.id)=\(library.containsVisibleSong(id: song.id))")
    }
    for album in library.visibleAlbums.sorted(by: { $0.id < $1.id }) {
        lines.append(
            "albumArtwork:\(album.id)=\(library.preferredArtworkSong(forAlbumID: album.id)?.id ?? "-")"
        )
    }
    for artist in library.visibleArtists.sorted(by: { $0.id < $1.id }) {
        lines.append("artist:\(artist.id)=\(library.visibleArtist(id: artist.id)?.name ?? "-")")
        lines.append(
            "artistSongs:\(artist.id)=\(library.songs(forArtist: artist.id).map(\.id).joined(separator: ","))"
        )
        lines.append(
            "artistArtwork:\(artist.id)=\(library.preferredArtworkSong(forArtistID: artist.id)?.id ?? "-")"
        )
    }
    for genre in library.visibleGenres.sorted(by: { $0.id < $1.id }) {
        lines.append(
            "genreSongs:\(genre.id)=\(library.songs(forGenre: genre.id).map(\.id).joined(separator: ","))"
        )
        lines.append(
            "genreAlbums:\(genre.id)=\(library.albums(forGenre: genre.id).map(\.id).joined(separator: ","))"
        )
    }
    lines.append(
        "sourceSongs=\(library.visibleSongs(forSourceID: "source-1").map(\.id).joined(separator: ","))"
    )
    lines.append(
        "sourcePlayable=\(library.playableSongs(forSourceID: "source-1").map(\.id).joined(separator: ","))"
    )
    lines.append("visibleCount=\(library.visibleSongCount(forSourceID: "source-1"))")
    lines.append(
        "counts=\(library.songCountsBySourceID().sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
    )
    return lines
}

/// A1 的排期决策是纯函数, 单独盯住"更早的截止时间获胜"。
final class LibraryDeferredMaintenanceSchedulingTests: XCTestCase {
    func testDeferredMaintenanceRearmKeepsTheEarliestDeadline() {
        // 没有已排期的任务 → 按请求排期。
        XCTAssertEqual(
            LibraryIndexMaintenancePolicy.deferredMaintenanceRearmInterval(
                secondsUntilScheduledFlush: nil,
                requestedInterval: LibraryIndexMaintenancePolicy.incrementalScanMaintenanceInterval
            ),
            LibraryIndexMaintenancePolicy.incrementalScanMaintenanceInterval
        )
        // 扫描的短上限比 backfill 排好的 60s 更早 → 重排。
        XCTAssertEqual(
            LibraryIndexMaintenancePolicy.deferredMaintenanceRearmInterval(
                secondsUntilScheduledFlush: 58,
                requestedInterval: 3
            ),
            3
        )
        // 已排期的更早或相等 → 沿用。连续 flush 每次重排会把截止时间一直
        // 往后推, 扫描期间这个定时器就永远等不到了。
        XCTAssertNil(
            LibraryIndexMaintenancePolicy.deferredMaintenanceRearmInterval(
                secondsUntilScheduledFlush: 1.5,
                requestedInterval: 3
            )
        )
        XCTAssertNil(
            LibraryIndexMaintenancePolicy.deferredMaintenanceRearmInterval(
                secondsUntilScheduledFlush: 3,
                requestedInterval: 3
            )
        )
        XCTAssertLessThan(
            LibraryIndexMaintenancePolicy.incrementalScanMaintenanceInterval,
            LibraryIndexMaintenancePolicy.maximumDeferredMaintenanceInterval
        )
    }
}

/// 一次性信号: 同步侧 (注入的写入闭包) 发信号, 异步侧 `await` 等待。
/// 信号量的 `wait(timeout:)` 在异步上下文里不可用, 而轮询加 sleep 只是在猜
/// 时机; 这个闸门两边都确定 —— 先发后等与先等后发都只放行一次。
private final class OneShotSignal: Sendable {
    private enum State: Sendable {
        case idle
        case waiting(CheckedContinuation<Void, Never>)
        case signalled
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .idle)

    func signal() {
        let waiting: CheckedContinuation<Void, Never>? = state.withLock { state in
            guard case .waiting(let continuation) = state else {
                state = .signalled
                return nil
            }
            state = .signalled
            return continuation
        }
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadySignalled: Bool = state.withLock { state in
                guard case .signalled = state else {
                    state = .waiting(continuation)
                    return false
                }
                return true
            }
            if alreadySignalled { continuation.resume() }
        }
    }
}
