import Foundation
import Testing
@testable import PrimuseKit

// `#expect` 把被测表达式包进闭包, 里面不能调用 mutating 方法; 改状态的调用先落到局部常量。
@Suite("Metadata tag reread queue")
struct MetadataTagRereadQueueTests {
    @Test("再点一次合并进同一批: 去重、保持先后、总数跟着涨")
    func mergeDeduplicatesAndKeepsOrder() {
        var queue = MetadataTagRereadQueue(songIDs: ["a", "b", "a", "c"])
        #expect(queue.total == 3)
        #expect(queue.phase == .running)
        let added = queue.merge(["c", "d", "b", "e", "d"])
        #expect(added == 2)
        #expect(queue.total == 5)
        let run = queue.takeNextRun()
        #expect(run == ["a", "b", "c", "d", "e"])
    }

    @Test("分段取: 每段最多 limit 首, 交出去的不重复交, 放回后按原先后再取")
    func takeNextRunHonoursLimit() {
        var queue = MetadataTagRereadQueue(songIDs: ["a", "b", "c", "d", "e"])
        let first = queue.takeNextRun(limit: 2)
        #expect(first == ["a", "b"])
        let second = queue.takeNextRun(limit: 2)
        #expect(second == ["c", "d"])
        queue.record("a", outcome: .completed)
        queue.returnUnfinished()
        let retaken = queue.takeNextRun(limit: 3)
        #expect(retaken == ["b", "c", "d"])
        let empty = queue.takeNextRun(limit: 0)
        #expect(empty.isEmpty)
        let last = queue.takeNextRun(limit: 9)
        #expect(last == ["e"])
    }

    @Test("在读的一趟里新并进来的歌留给下一趟, 已经交出去的不会再交一次")
    func mergedDuringRunGoesToNextRun() {
        var queue = MetadataTagRereadQueue(songIDs: ["a", "b"])
        let firstRun = queue.takeNextRun()
        #expect(firstRun == ["a", "b"])
        queue.merge(["b", "c"])
        queue.record("a", outcome: .completed)
        queue.record("b", outcome: .failed)
        let finishedEarly = queue.finishIfDrained()
        #expect(!finishedEarly)
        queue.returnUnfinished()
        let secondRun = queue.takeNextRun()
        #expect(secondRun == ["c"])
        queue.record("c", outcome: .skipped)
        let finished = queue.finishIfDrained()
        #expect(finished)
        #expect(queue.phase == .finished)
        let progress = queue.progress
        #expect(progress.completed == 1)
        #expect(progress.failed == 1)
        #expect(progress.skipped == 1)
        #expect(progress.processed == 3)
        #expect(progress.total == 3)
    }

    @Test("暂停: 读完的保留, 没读完的回到待读, 继续时按原先后接着读")
    func pauseKeepsCompletedAndResumesRemaining() {
        var queue = MetadataTagRereadQueue(songIDs: ["a", "b", "c", "d"])
        _ = queue.takeNextRun()
        queue.record("a", outcome: .completed)
        let paused = queue.pause()
        #expect(paused)
        #expect(queue.phase == .paused)
        let whilePaused = queue.takeNextRun()
        #expect(whilePaused.isEmpty)
        // 暂停之后才回来、已经写进资料库的那一首照样记上。
        queue.record("c", outcome: .completed)
        #expect(queue.completed == 2)
        #expect(queue.remainingCount == 2)
        let resumed = queue.resume()
        #expect(resumed)
        let rest = queue.takeNextRun()
        #expect(rest == ["b", "d"])
    }

    @Test("退到后台被系统打断: 剩下的记着, 回到前台续读; 用户暂停的不被自动续上")
    func systemSuspensionPreservesRemainingAndRespectsUserPause() {
        var queue = MetadataTagRereadQueue(songIDs: ["a", "b", "c"])
        _ = queue.takeNextRun()
        queue.record("a", outcome: .completed)
        let suspended = queue.suspend()
        #expect(suspended)
        #expect(queue.phase == .suspended)
        #expect(queue.isActive)
        #expect(queue.remainingCount == 2)
        let resumed = queue.resume()
        #expect(resumed)
        let rest = queue.takeNextRun()
        #expect(rest == ["b", "c"])

        let paused = queue.pause()
        #expect(paused)
        let suspendedWhilePaused = queue.suspend()
        #expect(!suspendedWhilePaused)
        #expect(queue.phase == .paused)

        // 系统打断中的批也能被用户暂停, 之后回到前台不会自己接着读。
        var interrupted = MetadataTagRereadQueue(songIDs: ["x"])
        interrupted.suspend()
        let pausedAfterSuspend = interrupted.pause()
        #expect(pausedAfterSuspend)
        #expect(interrupted.phase == .paused)
    }

    @Test("取消: 剩下的不读, 已读完的照常计数, 结束的批不再接新歌")
    func cancelDropsRemainingAndRejectsMerge() {
        var queue = MetadataTagRereadQueue(songIDs: ["a", "b", "c"])
        _ = queue.takeNextRun()
        queue.record("a", outcome: .completed)
        let cancelled = queue.cancel()
        #expect(cancelled)
        #expect(queue.phase == .cancelled)
        #expect(queue.progress.isCancelled)
        #expect(queue.progress.completed == 1)
        let afterCancel = queue.takeNextRun()
        #expect(afterCancel.isEmpty)
        let resumed = queue.resume()
        #expect(!resumed)
        let added = queue.merge(["d"])
        #expect(added == 0)
        #expect(queue.total == 3)
        #expect(!queue.shouldAnnounceResult)
        let cancelledAgain = queue.cancel()
        #expect(!cancelledAgain)
    }

    @Test("重复或不属于这一批的结果不重复计数")
    func duplicateAndForeignOutcomesAreIgnored() {
        var queue = MetadataTagRereadQueue(songIDs: ["a"])
        _ = queue.takeNextRun()
        queue.record("a", outcome: .completed)
        queue.record("a", outcome: .failed)
        queue.record("zzz", outcome: .completed)
        #expect(queue.processed == 1)
        #expect(queue.completed == 1)
        let finished = queue.finishIfDrained()
        #expect(finished)
    }

    @Test("完成提示只给一次")
    func resultIsAnnouncedOnce() {
        var queue = MetadataTagRereadQueue(songIDs: ["a"])
        _ = queue.takeNextRun()
        queue.record("a", outcome: .completed)
        #expect(!queue.shouldAnnounceResult)
        queue.finishIfDrained()
        #expect(queue.shouldAnnounceResult)
        queue.markResultAnnounced()
        #expect(!queue.shouldAnnounceResult)
        let added = queue.merge(["b"])
        #expect(added == 0)
    }

    @Test("暂停时全部已有结果: 继续之后直接结束")
    func resumeAfterDrainFinishes() {
        var queue = MetadataTagRereadQueue(songIDs: ["a"])
        _ = queue.takeNextRun()
        queue.pause()
        queue.record("a", outcome: .completed)
        let finishedWhilePaused = queue.finishIfDrained()
        #expect(!finishedWhilePaused)
        queue.resume()
        let rest = queue.takeNextRun()
        #expect(rest.isEmpty)
        let finished = queue.finishIfDrained()
        #expect(finished)
    }

    @Test("空选择不会起一批在读的")
    func emptySelectionIsNotActive() {
        let queue = MetadataTagRereadQueue(songIDs: [])
        #expect(!queue.isActive)
        #expect(queue.total == 0)
    }
}
