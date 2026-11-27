import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word shelf startup snapshot")
struct SpokenWordShelfStartupSnapshotTests {
    private let earlier = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    private func item(
        _ number: Int,
        book: String = "长书",
        duration: TimeInterval = 600,
        position: TimeInterval? = nil,
        updatedAt: Date? = nil,
        finishedAt: Date? = nil
    ) -> SpokenWordBookItem {
        SpokenWordBookItem(
            id: "\(book)-\(number)",
            title: "第\(number)集",
            albumTitle: book,
            albumArtist: "讲述者",
            trackNumber: number,
            duration: duration,
            fileName: "/\(book)/\(String(format: "%03d", number)).mp3",
            sourceID: "src",
            position: position,
            positionUpdatedAt: position == nil ? nil : (updatedAt ?? later),
            finishedAt: finishedAt
        )
    }

    private func book(_ items: [SpokenWordBookItem]) throws -> SpokenWordBook {
        try #require(SpokenWordBookGrouping.books(from: items).first)
    }

    private func resumeIndex(_ book: SpokenWordBook) -> Int? {
        book.resumeItemID.flatMap { id in book.items.firstIndex { $0.id == id } }
    }

    /// 拼出来的书和原来的书在书架上看得见的每个量都一样。
    private func expectSameOnShelf(_ original: SpokenWordBook) {
        let stored = SpokenWordShelfStartupSnapshot.Book(book: original, isArchived: false, cover: nil)
        let rebuilt = stored.makeBook()
        #expect(rebuilt.id == original.id)
        #expect(rebuilt.title == original.title)
        #expect(rebuilt.author == original.author)
        #expect(rebuilt.chapterCount == original.chapterCount)
        #expect(rebuilt.finishedCount == original.finishedCount)
        #expect(rebuilt.isFinished == original.isFinished)
        #expect(rebuilt.isInProgress == original.isInProgress)
        #expect(rebuilt.canContinue == original.canContinue)
        #expect(rebuilt.lastListenedAt == original.lastListenedAt)
        #expect(rebuilt.resumeItemID == original.resumeItemID)
        #expect(resumeIndex(rebuilt) == resumeIndex(original))
        #expect(abs(rebuilt.totalDuration - original.totalDuration) < 0.001)
        #expect(abs(rebuilt.fractionComplete - original.fractionComplete) < 1e-6)
        #expect((rebuilt.remainingDuration == nil) == (original.remainingDuration == nil))
        if let rebuiltRemaining = rebuilt.remainingDuration, let remaining = original.remainingDuration {
            #expect(abs(rebuiltRemaining - remaining) < 0.01)
        }
    }

    @Test("A book not started yet draws the same")
    func notStarted() throws {
        expectSameOnShelf(try book((1...5).map { item($0) }))
    }

    @Test("A book part way through draws the same, chapters of different lengths included")
    func partWay() throws {
        let original = try book([
            item(1, duration: 300, finishedAt: earlier),
            item(2, duration: 900, finishedAt: earlier),
            item(3, position: 120, updatedAt: later),
            item(4),
            item(5, duration: 1_800),
        ])
        #expect(original.isInProgress)
        expectSameOnShelf(original)
    }

    @Test("Progress only inside one long chapter still fits")
    func partialOnly() throws {
        let original = try book([
            item(1, duration: 5_000, position: 4_000),
            item(2, duration: 60),
            item(3, duration: 60),
        ])
        #expect(original.finishedCount == 0)
        expectSameOnShelf(original)
    }

    @Test("A short first chapter finished, the rest not started")
    func shortFinishedChapter() throws {
        expectSameOnShelf(try book([
            item(1, duration: 30, finishedAt: earlier),
            item(2, duration: 6_000),
            item(3, duration: 6_000),
        ]))
    }

    @Test("A finished book, and one finished and heard again")
    func finished() throws {
        let done = try book((1...4).map { item($0, finishedAt: earlier) })
        #expect(done.isFinished)
        expectSameOnShelf(done)

        var items = (1...4).map { item($0, finishedAt: earlier) }
        items[1] = item(2, position: 90, updatedAt: later, finishedAt: earlier)
        let again = try book(items)
        #expect(again.canContinue)
        expectSameOnShelf(again)
    }

    @Test("Chapters without a length average their progress")
    func unknownLengths() throws {
        let original = try book([
            item(1, duration: 0, finishedAt: earlier),
            item(2, duration: 600, position: 300),
            item(3, duration: 0),
            item(4, duration: 600),
        ])
        #expect(original.remainingDuration == nil)
        expectSameOnShelf(original)
    }

    @Test("Single-file books, in progress and untimed")
    func singleFile() throws {
        expectSameOnShelf(try book([item(1, duration: 3_600, position: 1_200)]))
        expectSameOnShelf(try book([item(1, duration: 0)]))
        expectSameOnShelf(try book([item(1, duration: 0, finishedAt: earlier)]))
    }

    @Test("A long series keeps its chapter count and where to continue")
    func longSeries() throws {
        let items = (1...300).map { number in
            number <= 40 ? item(number, duration: 1_200, finishedAt: earlier)
                : number == 41 ? item(number, duration: 1_200, position: 500)
                : item(number, duration: 1_200)
        }
        let original = try book(items)
        expectSameOnShelf(original)
        let rebuilt = SpokenWordShelfStartupSnapshot.Book(book: original, isArchived: false, cover: nil).makeBook()
        #expect(rebuilt.resumeItemID == "长书-41")
        #expect(rebuilt.items.filter { $0.id == "长书-41" }.count == 1)
        // 拼出来的章节不会和真实的歌同名。
        #expect(rebuilt.items.filter { $0.id.hasPrefix("长书-") }.count == 1)
    }

    @Test("Encodes and decodes; other versions and broken files read as nothing")
    func codec() throws {
        let original = try book([item(1, finishedAt: earlier), item(2, position: 30)])
        let cover = SpokenWordShelfStartupSnapshot.Cover(song: Song(
            id: "song-1", title: "第1集", fileFormat: .m4a, filePath: "/长书/001.m4a", sourceID: "src",
            genre: "Audiobook", coverArtFileName: "cover-1.jpg"
        ))
        let snapshot = SpokenWordShelfStartupSnapshot(
            sourceIDs: ["b", "a"],
            books: [.init(book: original, isArchived: true, cover: cover)]
        )
        let data = try snapshot.encoded()
        let decoded = try #require(SpokenWordShelfStartupSnapshot.decode(data))
        #expect(decoded == snapshot)
        #expect(decoded.matches(sourceIDs: ["a", "b"]))
        #expect(!decoded.matches(sourceIDs: ["a"]))
        #expect(!decoded.matches(sourceIDs: ["a", "b", "c"]))

        let song = try #require(decoded.books.first?.cover).makeSong()
        #expect(song.id == "song-1")
        #expect(song.sourceID == "src")
        #expect(song.filePath == "/长书/001.m4a")
        #expect(song.fileFormat == .m4a)
        #expect(song.coverArtFileName == "cover-1.jpg")
        #expect(song.genre == "Audiobook")

        var newer = snapshot
        newer.version = SpokenWordShelfStartupSnapshot.formatVersion + 1
        let newerData = try newer.encoded()
        #expect(SpokenWordShelfStartupSnapshot.decode(newerData) == nil)
        #expect(SpokenWordShelfStartupSnapshot.decode(Data()) == nil)
        #expect(SpokenWordShelfStartupSnapshot.decode(Data("not a plist".utf8)) == nil)
        #expect(SpokenWordShelfStartupSnapshot.decode(data.prefix(data.count / 2)) == nil)
    }

    @Test("Listening further does not change the structure; a book finishing or a new book does")
    func structure() throws {
        let other = try book((1...3).map { item($0, book: "短书") })
        func snapshot(_ current: SpokenWordBook, extra: [SpokenWordBook] = []) -> SpokenWordShelfStartupSnapshot {
            SpokenWordShelfStartupSnapshot(
                sourceIDs: ["src"],
                books: ([current, other] + extra).map { .init(book: $0, isArchived: false, cover: nil) }
            )
        }
        let start = snapshot(try book([item(1, position: 30, updatedAt: earlier), item(2)]))
        let further = snapshot(try book([item(1, position: 300, updatedAt: later), item(2)]))
        #expect(start != further)
        #expect(start.structure == further.structure)

        let finishedChapter = snapshot(try book([item(1, finishedAt: later), item(2, position: 10, updatedAt: later)]))
        #expect(start.structure == finishedChapter.structure)

        let finishedBook = snapshot(try book([item(1, finishedAt: later), item(2, finishedAt: later)]))
        #expect(start.structure != finishedBook.structure)

        let third = try book((1...2).map { item($0, book: "新书") })
        let withThird = snapshot(try book([item(1, position: 30, updatedAt: earlier), item(2)]), extra: [third])
        #expect(start.structure != withThird.structure)
    }

    @Test("Switching which book is heard most recently changes the structure")
    func listeningOrder() throws {
        func snapshot(firstAt: Date, secondAt: Date) throws -> SpokenWordShelfStartupSnapshot {
            SpokenWordShelfStartupSnapshot(sourceIDs: ["src"], books: [
                .init(book: try book([item(1, book: "甲", position: 10, updatedAt: firstAt), item(2, book: "甲")]),
                      isArchived: false, cover: nil),
                .init(book: try book([item(1, book: "乙", position: 10, updatedAt: secondAt), item(2, book: "乙")]),
                      isArchived: false, cover: nil),
            ])
        }
        let first = try snapshot(firstAt: later, secondAt: earlier)
        let firstAgain = try snapshot(firstAt: later.addingTimeInterval(60), secondAt: earlier)
        let second = try snapshot(firstAt: earlier, secondAt: later)
        #expect(first.structure == firstAgain.structure)
        #expect(first.structure != second.structure)
    }

    @Test("Keeps the first screen of the shelf, and finished or archived books only as whole sections")
    func keptBooks() {
        let shelf = (0..<10).map { "s\($0)" }
        let finished = (0..<5).map { "f\($0)" }
        let archived = ["a0", "a1"]

        let all = SpokenWordShelfStartupPolicy.keptBookIDs(
            listening: ["s3"], shelf: shelf, finished: finished, archived: archived,
            shelfLimit: 20, listeningLimit: 4, bookLimit: 40
        )
        #expect(all == Set(shelf + finished + archived))

        // 书架超过一屏: 下面两节露不出来, 不留; 在重听的那本已听完的书也拿掉。
        let truncated = SpokenWordShelfStartupPolicy.keptBookIDs(
            listening: ["f2", "s9"], shelf: shelf, finished: finished, archived: archived,
            shelfLimit: 4, listeningLimit: 4, bookLimit: 40
        )
        #expect(truncated == ["s0", "s1", "s2", "s3", "s9"])

        // 已听完那一节整节放不下: 整节不留, 归档的也不留。
        let noFinished = SpokenWordShelfStartupPolicy.keptBookIDs(
            listening: ["f1"], shelf: shelf, finished: finished, archived: archived,
            shelfLimit: 20, listeningLimit: 4, bookLimit: 12
        )
        #expect(noFinished == Set(shelf))

        // 已听完放得下、归档的放不下。
        let noArchived = SpokenWordShelfStartupPolicy.keptBookIDs(
            listening: [], shelf: shelf, finished: finished, archived: archived,
            shelfLimit: 20, listeningLimit: 4, bookLimit: 16
        )
        #expect(noArchived == Set(shelf + finished))

        // 「在听」也只留前面几本。
        let listening = SpokenWordShelfStartupPolicy.keptBookIDs(
            listening: ["x0", "x1", "x2"], shelf: [], finished: [], archived: [],
            shelfLimit: 20, listeningLimit: 2, bookLimit: 40
        )
        #expect(listening == ["x0", "x1"])
    }
}
