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
