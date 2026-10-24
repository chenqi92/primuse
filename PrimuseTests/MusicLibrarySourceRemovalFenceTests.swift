import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 整源移除的代际围栏回归。持续的扫描 / 回填突变会不停推进
/// `songMutationGeneration`, 无上限重试会被这股突变流永远拖住。
@MainActor
final class MusicLibrarySourceRemovalFenceTests: XCTestCase {

    /// 记录搅动任务的进度, 让测试能断言"移除是在突变仍在进行时完成的"。
    @MainActor
    private final class ChurnProgress {
        var mutations = 0
        var isFinished = false
    }

    func testSourceRemovalCompletesWhileConcurrentMutationsKeepLanding() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseSourceRemovalFence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs(
            [
                makeSong(id: "doomed-1", sourceID: "source-1"),
                makeSong(id: "doomed-2", sourceID: "source-1"),
            ],
            affectedSourceIDs: ["source-1"]
        )
        library.addSongs(
            [
                makeSong(id: "kept-1", sourceID: "source-2"),
                makeSong(id: "kept-2", sourceID: "source-2"),
            ],
            affectedSourceIDs: ["source-2"],
            pruneMissingSongs: false
        )
        await library.waitForPendingIndex()
        XCTAssertEqual(library.songCount, 4)

        // 准备时长远大于搅动间隔, 于是每一次离主线程准备都必然被抢跑。
        library.sourceSongRemovalPreparationDelayForTesting = .milliseconds(250)

        let progress = ChurnProgress()
        let churn = Task { @MainActor in
            for index in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { break }
                library.addSongs(
                    [makeSong(id: "churn-\(index)", sourceID: "source-2")],
                    affectedSourceIDs: ["source-2"],
                    pruneMissingSongs: false
                )
                progress.mutations += 1
            }
            progress.isFinished = true
        }

        let removed = await library.removeSongsForSources(["source-1"])
        // 下面这段必须在任何挂起点之前读完: 一旦再次让出主线程, 搅动任务还会
        // 继续加歌, 快照与计数就对不上了。
        let mutationsWhileRemoving = progress.mutations
        let churnStillRunning = !progress.isFinished
        let songCountAfterRemoval = library.songCount
        let remainingSourceIDs = Set(library.songs.map(\.sourceID))
        let doomedSurvivors = library.songs.filter { $0.sourceID == "source-1" }
        let keptFirst = library.song(id: "kept-1")
        let keptSecond = library.song(id: "kept-2")
        churn.cancel()
        _ = await churn.value
        library.sourceSongRemovalPreparationDelayForTesting = nil

        XCTAssertGreaterThan(
            mutationsWhileRemoving,
            0,
            "夹具无效: 移除期间必须真的有并发突变落地"
        )
        XCTAssertTrue(
            churnStillRunning,
            "移除必须在突变仍在持续时完成, 而不是一直重试到突变停下"
        )
        XCTAssertEqual(removed, ["doomed-1", "doomed-2"])
        XCTAssertTrue(doomedSurvivors.isEmpty)
        XCTAssertNotNil(keptFirst)
        XCTAssertNotNil(keptSecond)
        XCTAssertEqual(remainingSourceIDs, ["source-2"])
        XCTAssertEqual(songCountAfterRemoval, 2 + mutationsWhileRemoving)
    }

    private func makeSong(id: String, sourceID: String) -> Song {
        Song(
            id: id,
            title: id,
            fileFormat: .mp3,
            filePath: "/music/\(sourceID)/\(id).mp3",
            sourceID: sourceID
        )
    }
}

/// 看板 PRIM-37:音乐源删掉重加、文件改名或挪了位置、电视把源藏起来后又当新源加回来,
/// 歌曲 id 全换了, 评分、评论、「我喜欢」和歌单成员要跟到新的那一份上。
@MainActor
final class CarriedSongMarksLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseCarriedMarks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRemovedSourceReaddedUnderNewIDsGetsRatingsLikesAndPlaylistBack() async throws {
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs(
            [song("old-1", "source-1", title: "Song A"), song("old-2", "source-1", title: "Song B")],
            affectedSourceIDs: ["source-1"]
        )
        await library.waitForPendingIndex()
        library.updateLibraryReview(for: .song("old-1"), rating: 5, comment: "副歌")
        library.likeSongs(["old-2"])
        let playlist = library.createPlaylist(name: "Mix", songIDs: ["old-2", "old-1"])

        await library.removeSongsForSources(["source-1"])
        XCTAssertEqual(Set(library.carriedSongMarksForTesting.keys), ["old-1", "old-2"])
        XCTAssertFalse(library.isLiked(songID: "old-2"))

        // 同一个网盘当新源加回来:路径一样,源 id 不同,所以歌曲 id 全换了。
        library.addSongs(
            [song("new-1", "source-2", title: "Song A"), song("new-2", "source-2", title: "Song B")],
            affectedSourceIDs: ["source-2"]
        )
        await library.waitForPendingIndex()
        await library.resolveCarriedSongMarksForTesting()
        library.resolvePlaylistPendingEntriesForTesting()

        XCTAssertEqual(library.libraryReview(for: .song("new-1"))?.rating, 5)
        XCTAssertEqual(library.libraryReview(for: .song("new-1"))?.comment, "副歌")
        XCTAssertTrue(library.isLiked(songID: "new-2"))
        XCTAssertTrue(library.carriedSongMarksForTesting.isEmpty)
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).map(\.id), ["new-2", "new-1"], "歌单顺序不变")
    }

    func testAnotherVersionOfTheSongKeepsWaiting() async throws {
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([song("old-1", "source-1", title: "Song A")], affectedSourceIDs: ["source-1"])
        await library.waitForPendingIndex()
        library.updateLibraryReview(for: .song("old-1"), rating: 4, comment: "")

        await library.removeSongsForSources(["source-1"])
        library.addSongs([song("live-1", "source-2", title: "Song A (Live)")], affectedSourceIDs: ["source-2"])
        await library.waitForPendingIndex()
        await library.resolveCarriedSongMarksForTesting()

        XCTAssertNil(library.libraryReview(for: .song("live-1")))
        XCTAssertEqual(Set(library.carriedSongMarksForTesting.keys), ["old-1"], "对不上的继续等,不丢")
    }

    func testTargetKeepsItsOwnRating() async throws {
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([song("old-1", "source-1", title: "Song A")], affectedSourceIDs: ["source-1"])
        library.addSongs(
            [song("copy-1", "source-2", title: "Song A")],
            affectedSourceIDs: ["source-2"],
            pruneMissingSongs: false
        )
        await library.waitForPendingIndex()
        library.updateLibraryReview(for: .song("old-1"), rating: 5, comment: "")
        library.updateLibraryReview(for: .song("copy-1"), rating: 2, comment: "")

        await library.removeSongsForSources(["source-1"])
        await library.waitForPendingIndex()
        await library.resolveCarriedSongMarksForTesting()

        XCTAssertEqual(library.libraryReview(for: .song("copy-1"))?.rating, 2, "已有的评分不被覆盖")
        XCTAssertTrue(library.carriedSongMarksForTesting.isEmpty)
    }

    func testSameIDsComingBackAfterTheSourceWasEmptiedRestoreLikesAndOrder() async throws {
        let library = MusicLibrary(storageDirectory: directory)
        let original = [song("s-1", "source-1", title: "Song A"), song("s-2", "source-1", title: "Song B")]
        library.addSongs(original, affectedSourceIDs: ["source-1"])
        await library.waitForPendingIndex()
        library.likeSongs(["s-1"])
        let playlist = library.createPlaylist(name: "Mix", songIDs: ["s-2", "s-1"])

        // 电视改了源的连接参数:先把整源清空,重扫回来的是同一批 id。
        library.addSongs([], affectedSourceIDs: ["source-1"])
        await library.waitForPendingIndex()
        XCTAssertTrue(library.songs(forPlaylist: playlist.id).map(\.id).isEmpty)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id).count, 2, "歌单里留着占位")

        library.addSongs(original, affectedSourceIDs: ["source-1"])
        await library.waitForPendingIndex()
        await library.resolveCarriedSongMarksForTesting()
        library.resolvePlaylistPendingEntriesForTesting()

        XCTAssertTrue(library.isLiked(songID: "s-1"))
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).map(\.id), ["s-2", "s-1"])
    }

    func testHiddenSourceReaddedAsNewSourceCarriesMarks() async throws {
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs(
            [song("old-1", "source-1", title: "Song A"), song("old-2", "source-1", title: "Song B")],
            affectedSourceIDs: ["source-1"]
        )
        await library.waitForPendingIndex()
        library.updateLibraryReview(for: .song("old-1"), rating: 3, comment: "")
        library.likeSongs(["old-1"])
        let playlist = library.createPlaylist(name: "Mix", songIDs: ["old-2", "old-1"])

        // 电视「从 Apple TV 移除」:源藏起来,歌还在库里。
        library.updateDisabledSourceIDs(["source-1"])
        library.carryMarksFromHiddenSource("source-1")
        library.addSongs(
            [song("new-1", "source-2", title: "Song A"), song("new-2", "source-2", title: "Song B")],
            affectedSourceIDs: ["source-2"]
        )
        await library.waitForPendingIndex()
        await library.resolveCarriedSongMarksForTesting()
        library.resolvePlaylistPendingEntriesForTesting()

        XCTAssertEqual(library.libraryReview(for: .song("new-1"))?.rating, 3)
        XCTAssertTrue(library.isLiked(songID: "new-1"))
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).map(\.id), ["new-2", "new-1"])
    }

    func testLedgerSurvivesRelaunch() async throws {
        do {
            let library = MusicLibrary(storageDirectory: directory)
            library.addSongs([song("old-1", "source-1", title: "Song A")], affectedSourceIDs: ["source-1"])
            await library.waitForPendingIndex()
            library.likeSongs(["old-1"])
            await library.removeSongsForSources(["source-1"])
            XCTAssertEqual(library.carriedSongMarksForTesting.count, 1)
            library.persistNow()
        }
        // 等串行写盘队列落地。
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-carried-song-marks.json").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reopened = MusicLibrary(storageDirectory: directory)
        XCTAssertEqual(reopened.carriedSongMarksForTesting["old-1"]?.liked, true)
        reopened.discardCarriedSongMarks()
        XCTAssertTrue(reopened.carriedSongMarksForTesting.isEmpty)
    }

    private func song(_ id: String, _ sourceID: String, title: String) -> Song {
        Song(
            id: id,
            title: title,
            albumTitle: "Album",
            artistName: "Artist",
            duration: title.hasPrefix("Song A") ? 200 : 180,
            fileFormat: .flac,
            filePath: "/music/\(title).flac",
            sourceID: sourceID,
            fileSize: 1_000
        )
    }
}

/// 看板 PRIM-38:评分、红心与自建歌单的整份备份,导到 id 全换了的曲库里也能恢复。
@MainActor
final class LibraryBackupServiceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLibraryBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBackupRestoresIntoRebuiltLibraryWithoutDuplicates() async throws {
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        let original = MusicLibrary(storageDirectory: directory.appendingPathComponent("a"))
        original.addSongs(
            [song("a-1", title: "Song A"), song("a-2", title: "Song B"), song("a-3", title: "Song C")],
            affectedSourceIDs: ["source-1"]
        )
        await original.waitForPendingIndex()
        original.updateLibraryReview(for: .song("a-1"), rating: 5, comment: "副歌")
        original.updateLibraryReview(for: .song("a-2"), rating: 2, comment: "")
        original.likeSongs(["a-3", "a-1"])
        _ = original.createPlaylist(name: "通勤", songIDs: ["a-3", "a-1", "a-2"])
        let data = try LibraryBackupService.makeBackup(library: original, sourcesStore: sources).encoded()

        // 重建后的曲库:同样的歌换了 id,Song B 本机已经打了 4 星,Song C 还没扫到。
        let rebuilt = MusicLibrary(storageDirectory: directory.appendingPathComponent("b"))
        rebuilt.addSongs([song("b-1", title: "Song A"), song("b-2", title: "Song B")], affectedSourceIDs: ["source-2"])
        await rebuilt.waitForPendingIndex()
        rebuilt.updateLibraryReview(for: .song("b-2"), rating: 4, comment: "")

        let restore = try await LibraryBackupService.prepareRestore(data: data, library: rebuilt)
        XCTAssertEqual(restore.plan.conflicts.count, 1)
        XCTAssertEqual(restore.plan.unmatchedTrackCount, 1)
        LibraryBackupService.apply(restore, overwritingConflicts: false, library: rebuilt)

        XCTAssertEqual(rebuilt.libraryReview(for: .song("b-1"))?.rating, 5)
        XCTAssertEqual(rebuilt.libraryReview(for: .song("b-1"))?.comment, "副歌")
        XCTAssertEqual(rebuilt.libraryReview(for: .song("b-2"))?.rating, 4, "本机已有的评分默认不动")
        XCTAssertTrue(rebuilt.isLiked(songID: "b-1"))
        let playlist = try XCTUnwrap(rebuilt.playlists.first { $0.name == "通勤" })
        XCTAssertEqual(rebuilt.rawSongIDs(forPlaylist: playlist.id).count, 3, "没扫到的那首留占位")
        XCTAssertEqual(rebuilt.songs(forPlaylist: playlist.id).map(\.id), ["b-1", "b-2"])

        // 再导一次:不新建歌单、不重复加歌。
        let again = try await LibraryBackupService.prepareRestore(data: data, library: rebuilt)
        LibraryBackupService.apply(again, overwritingConflicts: false, library: rebuilt)
        XCTAssertEqual(rebuilt.playlists.filter { $0.name == "通勤" }.count, 1)
        XCTAssertEqual(rebuilt.rawSongIDs(forPlaylist: playlist.id).count, 3)

        // Song C 后来扫到了:评分、红心和歌单位置都补上。
        rebuilt.addSongs([song("b-3", title: "Song C")], affectedSourceIDs: ["source-3"])
        await rebuilt.waitForPendingIndex()
        await rebuilt.resolveCarriedSongMarksForTesting()
        rebuilt.resolvePlaylistPendingEntriesForTesting()
        XCTAssertTrue(rebuilt.isLiked(songID: "b-3"))
        XCTAssertEqual(rebuilt.songs(forPlaylist: playlist.id).map(\.id), ["b-3", "b-1", "b-2"])
    }

    func testOverwritingConflictsUsesTheBackupsRating() async throws {
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        let original = MusicLibrary(storageDirectory: directory.appendingPathComponent("a"))
        original.addSongs([song("a-1", title: "Song A")], affectedSourceIDs: ["source-1"])
        await original.waitForPendingIndex()
        original.updateLibraryReview(for: .song("a-1"), rating: 5, comment: "")
        let data = try LibraryBackupService.makeBackup(library: original, sourcesStore: sources).encoded()

        let rebuilt = MusicLibrary(storageDirectory: directory.appendingPathComponent("b"))
        rebuilt.addSongs([song("b-1", title: "Song A")], affectedSourceIDs: ["source-2"])
        await rebuilt.waitForPendingIndex()
        rebuilt.updateLibraryReview(for: .song("b-1"), rating: 1, comment: "")
        let restore = try await LibraryBackupService.prepareRestore(data: data, library: rebuilt)
        LibraryBackupService.apply(restore, overwritingConflicts: true, library: rebuilt)
        XCTAssertEqual(rebuilt.libraryReview(for: .song("b-1"))?.rating, 5)
    }

    private func song(_ id: String, title: String) -> Song {
        Song(
            id: id,
            title: title,
            albumTitle: "Album",
            artistName: "Artist",
            duration: title == "Song A" ? 200 : (title == "Song B" ? 180 : 240),
            fileFormat: .flac,
            filePath: "/music/\(title).flac",
            sourceID: id.hasPrefix("a") ? "source-1" : (id == "b-3" ? "source-3" : "source-2"),
            fileSize: 1_000
        )
    }
}
