import Foundation
import Testing
@testable import PrimuseKit

@Suite struct SpokenWordChapterRepeatPolicyTests {
    private static let sampleChapters: [MediaChapter] = [
        MediaChapter(startTime: 0, title: "序章"),
        MediaChapter(startTime: 120, title: "第一章"),
        MediaChapter(startTime: 360, title: "第二章"),
    ]

    @Test func multiFileBoundsRespectIntroAndIgnoreShortItems() {
        let target = SpokenWordChapterRepeatTarget(songID: "ch-1", chapterIndex: nil, bookID: "book-a")
        let plain = SpokenWordChapterRepeatPolicy.bounds(
            for: target,
            songID: "ch-1",
            duration: 600,
            chapters: [],
            introOutro: nil
        )
        #expect(plain == SpokenWordChapterRepeatBounds(start: 0, end: nil))

        let withIntro = SpokenWordChapterRepeatPolicy.bounds(
            for: target,
            songID: "ch-1",
            duration: 600,
            chapters: [],
            introOutro: SpokenWordIntroOutro(introSeconds: 30, outroSeconds: 15)
        )
        #expect(withIntro == SpokenWordChapterRepeatBounds(start: 30, end: nil))

        // 短序言不跳片头，避免跳过正文。
        let shortPreface = SpokenWordChapterRepeatPolicy.bounds(
            for: target,
            songID: "ch-1",
            duration: 40,
            chapters: [],
            introOutro: SpokenWordIntroOutro(introSeconds: 30, outroSeconds: 15)
        )
        #expect(shortPreface == SpokenWordChapterRepeatBounds(start: 0, end: nil))
    }

    @Test func chapterMarkBoundsCoverMiddleLastIntroAndDuplicateMarks() {
        let middle = SpokenWordChapterRepeatPolicy.bounds(
            for: SpokenWordChapterRepeatTarget(songID: "m4b", chapterIndex: 1, bookID: "book-a"),
            songID: "m4b",
            duration: 720,
            chapters: Self.sampleChapters,
            introOutro: SpokenWordIntroOutro(introSeconds: 20, outroSeconds: 10)
        )
        #expect(middle == SpokenWordChapterRepeatBounds(start: 120, end: 360))

        let last = SpokenWordChapterRepeatPolicy.bounds(
            for: SpokenWordChapterRepeatTarget(songID: "m4b", chapterIndex: 2, bookID: "book-a"),
            songID: "m4b",
            duration: 720,
            chapters: Self.sampleChapters,
            introOutro: SpokenWordIntroOutro(introSeconds: 20, outroSeconds: 10)
        )
        #expect(last == SpokenWordChapterRepeatBounds(start: 360, end: nil))

        // 第一章应用片头跳过，但不会越过第二章起点。
        let firstWithIntro = SpokenWordChapterRepeatPolicy.bounds(
            for: SpokenWordChapterRepeatTarget(songID: "m4b", chapterIndex: 0, bookID: "book-a"),
            songID: "m4b",
            duration: 720,
            chapters: Self.sampleChapters,
            introOutro: SpokenWordIntroOutro(introSeconds: 25, outroSeconds: 0)
        )
        #expect(firstWithIntro == SpokenWordChapterRepeatBounds(start: 25, end: 120))

        let firstShortChapter = SpokenWordChapterRepeatPolicy.bounds(
            for: SpokenWordChapterRepeatTarget(songID: "m4b", chapterIndex: 0, bookID: "book-a"),
            songID: "m4b",
            duration: 720,
            chapters: [MediaChapter(startTime: 0, title: "序"), MediaChapter(startTime: 15, title: "一")],
            introOutro: SpokenWordIntroOutro(introSeconds: 25, outroSeconds: 0)
        )
        #expect(firstShortChapter == SpokenWordChapterRepeatBounds(start: 0, end: 15))

        // 重合或零长度章节标记不会触发死循环边界。
        let duplicateChapters = [
            MediaChapter(startTime: 0, title: "一"),
            MediaChapter(startTime: 120, title: "二"),
            MediaChapter(startTime: 120, title: "二(重复)"),
            MediaChapter(startTime: 240, title: "三"),
        ]
        let deduped = SpokenWordChapterRepeatPolicy.bounds(
            for: SpokenWordChapterRepeatTarget(songID: "m4b", chapterIndex: 1, bookID: "book-a"),
            songID: "m4b",
            duration: 600,
            chapters: duplicateChapters
        )
        #expect(deduped == SpokenWordChapterRepeatBounds(start: 120, end: 240))
    }

    @Test func reachedEndAndTimeUntilEndRespectToleranceDirectionAndSpeed() {
        let bounds = SpokenWordChapterRepeatBounds(start: 120, end: 360)
        #expect(!SpokenWordChapterRepeatPolicy.reachedEnd(
            of: bounds, at: 359.5, currentChapterIndex: 1, lockedChapterIndex: 1
        ))
        #expect(SpokenWordChapterRepeatPolicy.reachedEnd(
            of: bounds, at: 359.96, currentChapterIndex: 1, lockedChapterIndex: 1
        ))
        #expect(SpokenWordChapterRepeatPolicy.reachedEnd(
            of: bounds, at: 360.2, currentChapterIndex: 2, lockedChapterIndex: 1
        ))
        // 退回上一章末尾不触发提前结束。
        #expect(!SpokenWordChapterRepeatPolicy.reachedEnd(
            of: bounds, at: 110, currentChapterIndex: 0, lockedChapterIndex: 1
        ))

        let remaining = SpokenWordChapterRepeatPolicy.timeUntilEnd(of: bounds, at: 357, rate: 1.5)
        #expect(remaining == 2.0)

        let fileEndBounds = SpokenWordChapterRepeatBounds(start: 360, end: nil)
        #expect(!SpokenWordChapterRepeatPolicy.reachedEnd(
            of: fileEndBounds, at: 500, currentChapterIndex: 2, lockedChapterIndex: 2
        ))
        #expect(SpokenWordChapterRepeatPolicy.timeUntilEnd(of: fileEndBounds, at: 500, rate: 1.0) == nil)
    }

    @Test func reconciliationFollowsSameBookAndClearsOnBookOrSpaceChange() {
        let initial = SpokenWordChapterRepeatTarget(songID: "ch-1", chapterIndex: nil, bookID: "book-a")

        // 离开有声书（切到音乐或播客）自动关闭。
        #expect(SpokenWordChapterRepeatPolicy.reconciled(
            target: initial, currentSongID: "song-1", currentBookID: nil,
            isAudiobook: false, chapters: [], currentChapterIndex: nil, currentTime: 0
        ) == nil)

        // 切到另一本书自动关闭。
        #expect(SpokenWordChapterRepeatPolicy.reconciled(
            target: initial, currentSongID: "b-ch-1", currentBookID: "book-b",
            isAudiobook: true, chapters: [], currentChapterIndex: nil, currentTime: 0
        ) == nil)

        // 同书内手动切到下一文件章节，单章循环跟到新章。
        let nextFile = SpokenWordChapterRepeatPolicy.reconciled(
            target: initial, currentSongID: "ch-2", currentBookID: "book-a",
            isAudiobook: true, chapters: [], currentChapterIndex: nil, currentTime: 0
        )
        #expect(nextFile == SpokenWordChapterRepeatTarget(songID: "ch-2", chapterIndex: nil, bookID: "book-a"))

        // 章节标记异步加载完成后自动绑定当前所在章节。
        let bound = SpokenWordChapterRepeatPolicy.reconciled(
            target: initial, currentSongID: "ch-1", currentBookID: "book-a",
            isAudiobook: true, chapters: Self.sampleChapters, currentChapterIndex: nil, currentTime: 180
        )
        #expect(bound == SpokenWordChapterRepeatTarget(songID: "ch-1", chapterIndex: 1, bookID: "book-a"))
    }

    @Test func userSeekRetargetsWhileBackwardSkipPreservesLockedChapter() {
        let target = SpokenWordChapterRepeatTarget(songID: "m4b", chapterIndex: 1, bookID: "book-a")

        // 快退 15 秒越过章首落到上一章末尾时，保留原锁定章节。
        let backwardSkip = SpokenWordChapterRepeatPolicy.retargetedAfterUserSeek(
            target, songID: "m4b", seekTime: 112, chapters: Self.sampleChapters,
            preservesChapterOnBackwardCrossing: true
        )
        #expect(backwardSkip?.chapterIndex == 1)

        // 主动拖动进度条到第三章时，改锁第三章。
        let directScrub = SpokenWordChapterRepeatPolicy.retargetedAfterUserSeek(
            target, songID: "m4b", seekTime: 400, chapters: Self.sampleChapters,
            preservesChapterOnBackwardCrossing: false
        )
        #expect(directScrub?.chapterIndex == 2)

        // 主动拖动到第一章也跟随。
        let scrubBack = SpokenWordChapterRepeatPolicy.retargetedAfterUserSeek(
            target, songID: "m4b", seekTime: 30, chapters: Self.sampleChapters,
            preservesChapterOnBackwardCrossing: false
        )
        #expect(scrubBack?.chapterIndex == 0)
    }

    @Test func rowMatchingDistinguishesFileItemsAndChapterMarks() {
        let itemRow = SpokenWordContentsRow(
            kind: .item, itemID: "vol-1", number: 1, title: "卷一",
            duration: 720, state: .current(fraction: 0.2), isNested: false
        )
        let chapterRow1 = SpokenWordContentsRow(
            kind: .chapter(index: 1, startTime: 120), itemID: "vol-1", number: 2, title: "第一章",
            duration: 240, state: .current(fraction: 0.2), isNested: true
        )
        let chapterRow2 = SpokenWordContentsRow(
            kind: .chapter(index: 2, startTime: 360), itemID: "vol-1", number: 3, title: "第二章",
            duration: 360, state: .unplayed, isNested: true
        )

        let fileTarget = SpokenWordChapterRepeatTarget(songID: "vol-1", chapterIndex: nil, bookID: "book-a")
        #expect(SpokenWordChapterRepeatPolicy.matches(fileTarget, row: itemRow))
        #expect(!SpokenWordChapterRepeatPolicy.matches(fileTarget, row: chapterRow1))

        let chapterTarget = SpokenWordChapterRepeatTarget(songID: "vol-1", chapterIndex: 1, bookID: "book-a")
        #expect(!SpokenWordChapterRepeatPolicy.matches(chapterTarget, row: itemRow))
        #expect(SpokenWordChapterRepeatPolicy.matches(chapterTarget, row: chapterRow1))
        #expect(!SpokenWordChapterRepeatPolicy.matches(chapterTarget, row: chapterRow2))
    }
}
