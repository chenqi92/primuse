import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word now playing")
struct SpokenWordNowPlayingPolicyTests {
    private func item(
        _ id: String,
        duration: TimeInterval = 600,
        position: TimeInterval? = nil,
        finished: Bool = false
    ) -> SpokenWordBookItem {
        SpokenWordBookItem(
            id: id,
            title: "Part \(id)",
            albumTitle: "Book",
            duration: duration,
            position: position,
            finishedAt: finished ? Date(timeIntervalSince1970: 1) : nil
        )
    }

    private func book(_ items: [SpokenWordBookItem]) -> SpokenWordBook {
        SpokenWordBook(
            id: "book",
            title: "Book",
            author: "Narrator",
            items: items,
            resumeItemID: items.first?.id,
            lastListenedAt: nil
        )
    }

    private let chapters = [
        MediaChapter(startTime: 0, title: "One"),
        MediaChapter(startTime: 100, title: "Two"),
        MediaChapter(startTime: 250, title: "Three"),
    ]

    // MARK: Summary

    @Test("A book of several files numbers its files and counts the live play head")
    func multiFileSummary() {
        let book = book([
            item("a", finished: true),
            item("b", position: 60),
            item("c"),
        ])
        let summary = SpokenWordNowPlayingPolicy.summary(
            book: book,
            currentItemID: "b",
            position: 300,
            duration: 600,
            chapterCount: 0,
            currentChapterIndex: nil
        )
        #expect(summary.partIndex == 2)
        #expect(summary.partCount == 3)
        #expect(!summary.partsAreChapterMarks)
        // 600 heard + 300 of 600 = 900 of 1800.
        #expect(abs(summary.bookFraction - 0.5) < 0.0001)
        #expect(summary.bookRemaining == 900)
    }

    @Test("A playing item marked finished still counts where the head is")
    func playingFinishedItemUsesHead() {
        let summary = SpokenWordNowPlayingPolicy.summary(
            book: book([item("a", finished: true), item("b")]),
            currentItemID: "a",
            position: 0,
            duration: 600,
            chapterCount: 0,
            currentChapterIndex: nil
        )
        #expect(summary.bookFraction == 0)
        #expect(summary.bookRemaining == 1200)
    }

    @Test("A one-file book is numbered by its chapter marks")
    func oneFileChapters() {
        let summary = SpokenWordNowPlayingPolicy.summary(
            book: book([item("a", duration: 400)]),
            currentItemID: "a",
            position: 120,
            duration: 400,
            chapterCount: 3,
            currentChapterIndex: 1
        )
        #expect(summary.partIndex == 2)
        #expect(summary.partCount == 3)
        #expect(summary.partsAreChapterMarks)
        #expect(summary.bookRemaining == 280)
    }

    @Test("One file without marks has no part number")
    func oneFileNoMarks() {
        let summary = SpokenWordNowPlayingPolicy.summary(
            book: nil,
            currentItemID: "x",
            position: 10,
            duration: 100,
            chapterCount: 0,
            currentChapterIndex: nil
        )
        #expect(summary.partIndex == nil)
        #expect(summary.partCount == nil)
        #expect(summary.bookRemaining == 90)
    }

    @Test("An unknown duration means no time left is shown, never a guess")
    func unknownDuration() {
        let summary = SpokenWordNowPlayingPolicy.summary(
            book: book([item("a"), item("b", duration: 0)]),
            currentItemID: "a",
            position: 10,
            duration: 600,
            chapterCount: 0,
            currentChapterIndex: nil
        )
        #expect(summary.bookRemaining == nil)
        #expect(summary.partCount == 2)
    }

    @Test("Listening time follows the speed")
    func listeningTime() {
        #expect(SpokenWordNowPlayingPolicy.listeningTime(forContent: 3600, rate: 1.5) == 2400)
        #expect(SpokenWordNowPlayingPolicy.listeningTime(forContent: 3600, rate: 1) == 3600)
        // Clamped like the engine: 4× plays at 2×.
        #expect(SpokenWordNowPlayingPolicy.listeningTime(forContent: 3600, rate: 4) == 1800)
        #expect(SpokenWordNowPlayingPolicy.listeningTime(forContent: .nan, rate: 1) == 0)
    }

    @Test("Time left in the part runs to the next mark, or to the end of the file")
    func partRemaining() {
        #expect(SpokenWordNowPlayingPolicy.partRemaining(
            position: 120, duration: 400, chapters: chapters, currentChapterIndex: 1
        ) == 130)
        #expect(SpokenWordNowPlayingPolicy.partRemaining(
            position: 300, duration: 400, chapters: chapters, currentChapterIndex: 2
        ) == 100)
        #expect(SpokenWordNowPlayingPolicy.partRemaining(
            position: 30, duration: 90, chapters: [], currentChapterIndex: nil
        ) == 60)
        #expect(SpokenWordNowPlayingPolicy.partRemaining(
            position: 30, duration: 0, chapters: [], currentChapterIndex: nil
        ) == nil)
    }

    @Test("Bookmark ticks are fractions of the item, sorted, and never past its end")
    func bookmarkFractions() {
        let marks = [300.0, 50, 900].map {
            SpokenWordBookmark(songID: "a", position: $0, title: "m")
        }
        #expect(SpokenWordNowPlayingPolicy.bookmarkFractions(marks, duration: 600) == [50.0 / 600, 0.5])
        #expect(SpokenWordNowPlayingPolicy.bookmarkFractions(marks, duration: 0).isEmpty)
    }

    // MARK: Contents

    @Test("A book of several files lists them with their states")
    func contentsOfFiles() {
        let rows = SpokenWordContentsPolicy.rows(
            book: book([item("a", finished: true), item("b"), item("c", position: 300)]),
            currentItemID: "b",
            position: 150,
            duration: 600,
            chapters: [],
            currentChapterIndex: nil
        )
        #expect(rows.map(\.itemID) == ["a", "b", "c"])
        #expect(rows.map(\.number) == [1, 2, 3])
        #expect(rows[0].state == .finished)
        #expect(rows[1].state == .current(fraction: 0.25))
        #expect(rows[2].state == .inProgress(fraction: 0.5))
        #expect(rows.allSatisfy { !$0.isNested })
    }

    @Test("The playing file's own marks are listed under it")
    func nestedChapters() {
        let rows = SpokenWordContentsPolicy.rows(
            book: book([item("a", duration: 400), item("b")]),
            currentItemID: "a",
            position: 120,
            duration: 400,
            chapters: chapters,
            currentChapterIndex: 1
        )
        #expect(rows.count == 5)
        #expect(rows[0].kind == .item)
        #expect(rows[1].kind == .chapter(index: 0, startTime: 0))
        #expect(rows[1].isNested)
        #expect(rows[1].state == .finished)
        #expect(rows[2].state == .current(fraction: 20.0 / 150))
        #expect(rows[3].duration == 150)
        #expect(rows[3].state == .unplayed)
        #expect(rows[4].itemID == "b")
    }

    @Test("A one-file book lists its marks, not the file")
    func oneFileContents() {
        let rows = SpokenWordContentsPolicy.rows(
            book: book([item("a", duration: 400)]),
            currentItemID: "a",
            position: 260,
            duration: 400,
            chapters: chapters,
            currentChapterIndex: 2
        )
        #expect(rows.map(\.title) == ["One", "Two", "Three"])
        #expect(rows.allSatisfy { !$0.isNested })
        #expect(rows[2].duration == 150)
        #expect(rows[2].isCurrent)
    }

    @Test("Without a book the playing item is listed on its own")
    func noBook() {
        let rows = SpokenWordContentsPolicy.rows(
            book: nil,
            currentItemID: "x",
            currentItemTitle: "Lecture",
            position: 10,
            duration: 100,
            chapters: [],
            currentChapterIndex: nil
        )
        #expect(rows.count == 1)
        #expect(rows[0].title == "Lecture")
        #expect(rows[0].isCurrent)
    }

    @Test("The list opens on the playing row, else where the book resumes")
    func initialRow() {
        let rows = SpokenWordContentsPolicy.rows(
            book: book([item("a"), item("b"), item("c")]),
            currentItemID: nil,
            position: 0,
            duration: 0,
            chapters: [],
            currentChapterIndex: nil
        )
        #expect(SpokenWordContentsPolicy.initialRowIndex(in: rows, resumeItemID: "c") == 2)
        #expect(SpokenWordContentsPolicy.initialRowIndex(in: rows, resumeItemID: nil) == 0)
        #expect(SpokenWordContentsPolicy.initialRowIndex(in: [], resumeItemID: nil) == nil)

        let playing = SpokenWordContentsPolicy.rows(
            book: book([item("a", duration: 400), item("b")]),
            currentItemID: "a",
            position: 120,
            duration: 400,
            chapters: chapters,
            currentChapterIndex: 1
        )
        // The innermost current row: the chapter, not the file above it.
        #expect(SpokenWordContentsPolicy.initialRowIndex(in: playing, resumeItemID: "b") == 2)
    }

    // MARK: Bookmarks

    @Test("Bookmarks come in reading order and carry their part number")
    func bookmarkEntries() {
        let byItem: [String: [SpokenWordBookmark]] = [
            "b": [SpokenWordBookmark(songID: "b", position: 90, title: "late"),
                  SpokenWordBookmark(songID: "b", position: 10, title: "early")],
            "a": [SpokenWordBookmark(songID: "a", position: 500, title: "first")],
        ]
        let entries = SpokenWordBookBookmarkPolicy.entries(itemIDs: ["a", "b"]) { byItem[$0] ?? [] }
        #expect(entries.map(\.bookmark.title) == ["first", "early", "late"])
        #expect(entries.map(\.partNumber) == [1, 2, 2])

        let single = SpokenWordBookBookmarkPolicy.entries(itemIDs: ["a"]) { byItem[$0] ?? [] }
        #expect(single.map(\.partNumber) == [nil])
    }

    // MARK: Moving between parts

    @Test("Previous goes back to the start of the chapter, then to the previous one")
    func previousPart() {
        #expect(SpokenWordPartNavigationPolicy.previous(
            position: 130, chapters: chapters, currentChapterIndex: 1, hasPreviousItem: true
        ) == .seekToChapter(1))
        #expect(SpokenWordPartNavigationPolicy.previous(
            position: 101, chapters: chapters, currentChapterIndex: 1, hasPreviousItem: true
        ) == .seekToChapter(0))
        // At the first mark the previous file comes next.
        #expect(SpokenWordPartNavigationPolicy.previous(
            position: 1, chapters: chapters, currentChapterIndex: 0, hasPreviousItem: true
        ) == .previousItem)
        #expect(SpokenWordPartNavigationPolicy.previous(
            position: 1, chapters: chapters, currentChapterIndex: 0, hasPreviousItem: false
        ) == .restartItem)
        #expect(SpokenWordPartNavigationPolicy.previous(
            position: 40, chapters: [], currentChapterIndex: nil, hasPreviousItem: true
        ) == .restartItem)
        #expect(SpokenWordPartNavigationPolicy.previous(
            position: 2, chapters: [], currentChapterIndex: nil, hasPreviousItem: true
        ) == .previousItem)
    }

    @Test("Next moves through the marks, then to the next file")
    func nextPart() {
        #expect(SpokenWordPartNavigationPolicy.next(
            chapters: chapters, currentChapterIndex: 0, hasNextItem: true
        ) == .seekToChapter(1))
        #expect(SpokenWordPartNavigationPolicy.next(
            chapters: chapters, currentChapterIndex: nil, hasNextItem: true
        ) == .seekToChapter(0))
        #expect(SpokenWordPartNavigationPolicy.next(
            chapters: chapters, currentChapterIndex: 2, hasNextItem: true
        ) == .nextItem)
        #expect(SpokenWordPartNavigationPolicy.next(
            chapters: chapters, currentChapterIndex: 2, hasNextItem: false
        ) == .none)
        #expect(!SpokenWordPartNavigationPolicy.canGoNext(
            chapters: [], currentChapterIndex: nil, hasNextItem: false
        ))
    }
}
