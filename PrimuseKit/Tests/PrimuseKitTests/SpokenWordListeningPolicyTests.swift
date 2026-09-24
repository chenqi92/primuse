import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word bookmarks")
struct SpokenWordBookmarkPolicyTests {
    private func mark(_ position: TimeInterval, at created: Date = Date()) -> SpokenWordBookmark {
        SpokenWordBookmark(songID: "s", position: position, title: "m", createdAt: created)
    }

    @Test("Bookmarks stay ordered by position")
    func ordered() {
        var list: [SpokenWordBookmark] = []
        list = SpokenWordBookmarkPolicy.inserting(mark(120), into: list)
        list = SpokenWordBookmarkPolicy.inserting(mark(30), into: list)
        list = SpokenWordBookmarkPolicy.inserting(mark(600), into: list)
        #expect(list.map(\.position) == [30, 120, 600])
    }

    @Test("A press within two seconds of an existing mark is the same mark")
    func duplicateCollapsed() {
        var list = SpokenWordBookmarkPolicy.inserting(mark(100), into: [])
        list = SpokenWordBookmarkPolicy.inserting(mark(101.5), into: list)
        #expect(list.count == 1)
        list = SpokenWordBookmarkPolicy.inserting(mark(103), into: list)
        #expect(list.count == 2)
    }

    @Test("Invalid positions are ignored")
    func invalidIgnored() {
        #expect(SpokenWordBookmarkPolicy.inserting(mark(-1), into: []).isEmpty)
        #expect(SpokenWordBookmarkPolicy.inserting(mark(.nan), into: []).isEmpty)
    }

    @Test("Past the cap the oldest mark goes, not the earliest position")
    func capDropsOldest() {
        var list: [SpokenWordBookmark] = []
        let base = Date(timeIntervalSince1970: 1_000)
        for index in 0..<SpokenWordBookmarkPolicy.maximumPerItem {
            // Later positions were created earlier, so the cap must remove the
            // largest position rather than the smallest.
            let created = base.addingTimeInterval(TimeInterval(-index))
            list = SpokenWordBookmarkPolicy.inserting(mark(TimeInterval(index * 10), at: created), into: list)
        }
        let newest = mark(9_999, at: base.addingTimeInterval(10))
        list = SpokenWordBookmarkPolicy.inserting(newest, into: list)
        #expect(list.count == SpokenWordBookmarkPolicy.maximumPerItem)
        #expect(list.contains { $0.id == newest.id })
        let droppedPosition = TimeInterval((SpokenWordBookmarkPolicy.maximumPerItem - 1) * 10)
        #expect(!list.contains { $0.position == droppedPosition })
    }
}

@Suite("Spoken word playback rate")
struct SpokenWordPlaybackRatePolicyTests {
    @Test("The spoken-word rate applies only to spoken word")
    func rateFollowsItem() {
        #expect(SpokenWordPlaybackRatePolicy.effectiveRate(
            isSpokenWord: true, musicRate: 1, spokenWordRate: 1.5, rateAllowed: true) == 1.5)
        #expect(SpokenWordPlaybackRatePolicy.effectiveRate(
            isSpokenWord: false, musicRate: 1, spokenWordRate: 1.5, rateAllowed: true) == 1)
        #expect(SpokenWordPlaybackRatePolicy.effectiveRate(
            isSpokenWord: false, musicRate: 0.75, spokenWordRate: 1.5, rateAllowed: true) == 0.75)
    }

    @Test("Passthrough output plays everything at 1×")
    func passthrough() {
        #expect(SpokenWordPlaybackRatePolicy.effectiveRate(
            isSpokenWord: true, musicRate: 1, spokenWordRate: 2, rateAllowed: false) == 1)
    }

    @Test("Rates are clamped to what the time-pitch unit handles well")
    func clamped() {
        #expect(SpokenWordPlaybackRatePolicy.clamped(3) == 2)
        #expect(SpokenWordPlaybackRatePolicy.clamped(0.1) == 0.5)
        #expect(SpokenWordPlaybackRatePolicy.clamped(.nan) == 1)
        #expect(SpokenWordPlaybackRatePolicy.clamped(1.25) == 1.25)
    }

    @Test("Labels drop trailing zeros")
    func labels() {
        #expect(SpokenWordPlaybackRatePolicy.label(for: 1) == "1×")
        #expect(SpokenWordPlaybackRatePolicy.label(for: 1.5) == "1.5×")
        #expect(SpokenWordPlaybackRatePolicy.label(for: 1.25) == "1.25×")
        #expect(SpokenWordPlaybackRatePolicy.label(for: 2) == "2×")
    }
}

@Suite("Spoken word skip intervals")
struct SpokenWordSkipIntervalTests {
    @Test("Stored values snap to an interval that has a glyph")
    func snapping() {
        #expect(SpokenWordSkipPolicy.clampedInterval(15) == 15)
        #expect(SpokenWordSkipPolicy.clampedInterval(20) == 15)
        #expect(SpokenWordSkipPolicy.clampedInterval(25) == 30)
        #expect(SpokenWordSkipPolicy.clampedInterval(0) == 5)
        #expect(SpokenWordSkipPolicy.clampedInterval(500) == 90)
    }

    @Test("Symbol names match SF Symbols")
    func symbols() {
        #expect(SpokenWordSkipPolicy.symbolName(forward: true, interval: 30) == "goforward.30")
        #expect(SpokenWordSkipPolicy.symbolName(forward: false, interval: 15) == "gobackward.15")
        #expect(SpokenWordSkipPolicy.symbolName(forward: false, interval: 12) == "gobackward.10")
    }
}

@Suite("Sleep at chapter end")
struct SpokenWordChapterSleepPolicyTests {
    @Test("Stops once the head moves past the armed chapter")
    func stopsForward() {
        #expect(!SpokenWordChapterSleepPolicy.shouldStop(lockedChapterIndex: 3, currentChapterIndex: 3))
        #expect(SpokenWordChapterSleepPolicy.shouldStop(lockedChapterIndex: 3, currentChapterIndex: 4))
        #expect(SpokenWordChapterSleepPolicy.shouldStop(lockedChapterIndex: 3, currentChapterIndex: 6))
    }

    @Test("Rewinding into an earlier chapter keeps the timer armed")
    func rewindKeepsArmed() {
        #expect(!SpokenWordChapterSleepPolicy.shouldStop(lockedChapterIndex: 3, currentChapterIndex: 2))
        #expect(!SpokenWordChapterSleepPolicy.shouldStop(lockedChapterIndex: 3, currentChapterIndex: nil))
    }
}

@Suite("Spoken word books")
struct SpokenWordBookGroupingTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func chapter(
        _ id: String,
        album: String? = "Dune",
        author: String? = "Frank Herbert",
        disc: Int? = nil,
        track: Int?,
        duration: TimeInterval = 3600,
        file: String = "",
        position: TimeInterval? = nil,
        updated: TimeInterval? = nil,
        finished: TimeInterval? = nil
    ) -> SpokenWordBookItem {
        SpokenWordBookItem(
            id: id,
            title: "Chapter " + id,
            albumTitle: album,
            albumArtist: author,
            discNumber: disc,
            trackNumber: track,
            duration: duration,
            fileName: file.isEmpty ? id + ".m4b" : file,
            position: position,
            positionUpdatedAt: updated.map { t0.addingTimeInterval($0) },
            finishedAt: finished.map { t0.addingTimeInterval($0) }
        )
    }

    @Test("Items sharing an album and author form one book in track order")
    func groupsByAlbum() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("c", track: 3),
            chapter("a", track: 1),
            chapter("b", track: 2),
        ])
        #expect(books.count == 1)
        #expect(books[0].title == "Dune")
        #expect(books[0].author == "Frank Herbert")
        #expect(books[0].items.map(\.id) == ["a", "b", "c"])
    }

    @Test("Album matching ignores case, width and surrounding space")
    func albumMatchingIsLenient() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("a", album: "dune ", track: 1),
            chapter("b", album: "DUNE", track: 2),
        ])
        #expect(books.count == 1)
    }

    @Test("Different authors with the same album title are different books")
    func authorSeparates() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("a", author: "Reader One", track: 1),
            chapter("b", author: "Reader Two", track: 1),
        ])
        #expect(books.count == 2)
    }

    @Test("An item without an album is its own book, titled by the item")
    func loneItem() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("solo", album: nil, track: nil),
        ])
        #expect(books.count == 1)
        #expect(books[0].title == "Chapter solo")
        #expect(books[0].items.count == 1)
    }

    @Test("Discs order before tracks, and file names break ties")
    func discThenTrackThenFile() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("d2t1", disc: 2, track: 1),
            chapter("d1t2", disc: 1, track: 2),
            chapter("d1t1", disc: 1, track: 1),
            chapter("f10", track: nil, file: "Part 10.mp3"),
            chapter("f2", track: nil, file: "Part 2.mp3"),
        ])
        #expect(books[0].items.map(\.id) == ["d1t1", "d1t2", "f2", "f10", "d2t1"])
    }

    @Test("Continue picks the most recently heard unfinished chapter")
    func resumeMostRecent() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("1", track: 1, finished: 10),
            chapter("2", track: 2, position: 600, updated: 50),
            chapter("3", track: 3, position: 100, updated: 20),
        ])
        let book = books[0]
        #expect(book.resumeItemID == "2")
        #expect(book.isInProgress)
        #expect(book.finishedCount == 1)
        #expect(book.lastListenedAt == t0.addingTimeInterval(50))
    }

    @Test("With nothing part-heard, continue is the first unfinished chapter")
    func resumeFirstUnfinished() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("1", track: 1, finished: 10),
            chapter("2", track: 2, finished: 20),
            chapter("3", track: 3),
            chapter("4", track: 4),
        ])
        #expect(books[0].resumeItemID == "3")
        #expect(books[0].isInProgress)
    }

    @Test("A finished book has no resume item and leaves the continue shelf")
    func finishedBook() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("1", track: 1, finished: 10),
            chapter("2", track: 2, finished: 20),
        ])
        #expect(books[0].resumeItemID == nil)
        #expect(books[0].isFinished)
        #expect(!books[0].isInProgress)
        #expect(books[0].fractionComplete == 1)
    }

    @Test("An untouched book is not in progress and starts at chapter one")
    func untouchedBook() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("1", track: 1),
            chapter("2", track: 2),
        ])
        #expect(!books[0].isInProgress)
        #expect(books[0].resumeItemID == "1")
        #expect(books[0].fractionComplete == 0)
        #expect(books[0].remainingDuration == 7200)
    }

    @Test("Progress weighs chapters by duration")
    func durationWeightedProgress() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("1", track: 1, duration: 100, finished: 1),
            chapter("2", track: 2, duration: 300, position: 150, updated: 2),
        ])
        // 100 finished + 150 of 300 = 250 of 400.
        #expect(abs(books[0].fractionComplete - 0.625) < 0.0001)
        #expect(books[0].remainingDuration == 150)
    }

    @Test("Books in progress come first, most recent first, then by title")
    func shelfOrder() {
        let books = SpokenWordBookGrouping.books(from: [
            chapter("z1", album: "Zeta", track: 1),
            chapter("a1", album: "Alpha", track: 1),
            chapter("m1", album: "Middle", track: 1, position: 60, updated: 10),
            chapter("n1", album: "Newest", track: 1, position: 60, updated: 99),
            chapter("f1", album: "Finished", track: 1, finished: 200),
        ])
        #expect(books.map(\.title) == ["Newest", "Middle", "Alpha", "Finished", "Zeta"])
    }
}
