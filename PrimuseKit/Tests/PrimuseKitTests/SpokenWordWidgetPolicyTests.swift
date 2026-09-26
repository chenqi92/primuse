import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken-word widgets")
struct SpokenWordWidgetPolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func item(
        _ id: String,
        album: String,
        track: Int,
        duration: TimeInterval = 600,
        position: TimeInterval? = nil,
        updated: TimeInterval? = nil,
        finished: TimeInterval? = nil
    ) -> SpokenWordBookItem {
        SpokenWordBookItem(
            id: id,
            title: "Part \(track)",
            albumTitle: album,
            albumArtist: "Author",
            trackNumber: track,
            duration: duration,
            fileName: "\(album)/\(id).mp3",
            position: position,
            positionUpdatedAt: updated.map { t0.addingTimeInterval($0) },
            finishedAt: finished.map { t0.addingTimeInterval($0) }
        )
    }

    @Test("The shelf holds books in progress, most recently heard first, up to the limit")
    func shelfOrder() {
        let books = SpokenWordBookGrouping.books(from: [
            item("a1", album: "A", track: 1, position: 60, updated: 10),
            item("b1", album: "B", track: 1, finished: 50),
            item("b2", album: "B", track: 2),
            item("c1", album: "C", track: 1),
            item("d1", album: "D", track: 1, position: 30, updated: 90),
            item("e1", album: "E", track: 1, finished: 5),
        ])
        let shelf = SpokenWordWidgetPolicy.shelfBooks(from: books, limit: 2)
        #expect(shelf.map(\.title) == ["D", "B"])
        #expect(!shelf.contains { $0.title == "C" })
        #expect(!SpokenWordWidgetPolicy.shelfBooks(from: books).contains { $0.title == "E" })
    }

    @Test("The entry continues from the next unheard part and counts it 1-based")
    func entryPart() throws {
        let books = SpokenWordBookGrouping.books(from: [
            item("b1", album: "B", track: 1, finished: 50),
            item("b2", album: "B", track: 2),
            item("b3", album: "B", track: 3),
        ])
        let book = try #require(books.first)
        let entry = SpokenWordWidgetPolicy.shelfEntry(for: book, coverImageName: "x.jpg")
        #expect(entry.partIndex == 2)
        #expect(entry.partCount == 3)
        #expect(entry.remaining == 1200)
        #expect(abs(entry.fractionComplete - 1.0 / 3) < 0.0001)
    }

    @Test("A single-part book has no part position")
    func singlePart() throws {
        let book = try #require(SpokenWordBookGrouping.books(from: [
            item("m", album: "M", track: 1, position: 60, updated: 1),
        ]).first)
        #expect(SpokenWordWidgetPolicy.partPosition(of: "m", in: book) == nil)
    }

    @Test("Cover names are stable, distinct and file-name safe")
    func coverNames() {
        let a = SpokenWordWidgetPolicy.coverFileName(forBookID: "book:三体\u{1F}刘慈欣")
        #expect(a == SpokenWordWidgetPolicy.coverFileName(forBookID: "book:三体\u{1F}刘慈欣"))
        #expect(a != SpokenWordWidgetPolicy.coverFileName(forBookID: "book:三体\u{1F}"))
        #expect(a.hasPrefix(SpokenWordWidgetPolicy.coverFilePrefix))
        #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") })
    }

    @Test("A position save that moves nothing visible keeps the signature")
    func signatureIgnoresSmallMoves() {
        let before = SpokenWordShelfSnapshot.Book(id: "b", title: "B", fractionComplete: 0.4031, remaining: 3600, partIndex: 2, partCount: 9)
        var after = before
        after.fractionComplete = 0.4044
        after.remaining = 3585
        #expect(SpokenWordWidgetPolicy.signature(of: [before]) == SpokenWordWidgetPolicy.signature(of: [after]))
        after.partIndex = 3
        #expect(SpokenWordWidgetPolicy.signature(of: [before]) != SpokenWordWidgetPolicy.signature(of: [after]))
    }

    @Test("Snapshots without the spoken-word field decode as music")
    func playbackStateDecodesOldSnapshots() throws {
        let json = #"{"isPlaying":true,"currentTime":1,"duration":2,"queueSongIDs":[]}"#
        let state = try JSONDecoder().decode(PlaybackState.self, from: Data(json.utf8))
        #expect(state.spokenWord == nil)
        #expect(!state.isSpokenWord)
    }

    @Test("The spoken-word info round-trips and names SF Symbols")
    func infoRoundTrip() throws {
        var state = PlaybackState(isPlaying: true)
        state.spokenWord = SpokenWordPlaybackInfo(skipBackwardSeconds: 15, skipForwardSeconds: 30, bookTitle: "B", partIndex: 2, partCount: 9)
        let decoded = try JSONDecoder().decode(PlaybackState.self, from: JSONEncoder().encode(state))
        #expect(decoded.spokenWord == state.spokenWord)
        #expect(decoded.spokenWord?.skipBackwardSymbol == "gobackward.15")
        #expect(decoded.spokenWord?.skipForwardSymbol == "goforward.30")
    }
}
