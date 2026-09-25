import Foundation
import Testing
@testable import PrimuseKit

struct ListeningSpaceSearchPolicyTests {
    typealias Policy = ListeningSpaceSearchPolicy

    // MARK: Segments

    @Test func onlyMusicOffersNoSegments() {
        #expect(Policy.scopes(visibleSpaces: [.music]).isEmpty)
    }

    @Test func segmentsFollowVisibleSpaces() {
        #expect(Policy.scopes(visibleSpaces: [.music, .radio]) == [.all, .music, .radio])
        #expect(Policy.scopes(visibleSpaces: [.music, .spokenWord]) == [.all, .music, .spokenWord])
        #expect(Policy.scopes(visibleSpaces: [.music, .radio, .spokenWord])
            == [.all, .music, .radio, .spokenWord])
    }

    @Test func emptiedSpaceFallsBackToAll() {
        let available = Policy.scopes(visibleSpaces: [.music, .spokenWord])
        #expect(Policy.effectiveScope(.radio, available: available) == .all)
        #expect(Policy.effectiveScope(.spokenWord, available: available) == .spokenWord)
        #expect(Policy.effectiveScope(.music, available: []) == .all)
    }

    @Test func showsGroupsPerScope() {
        #expect(Policy.shows(.radio, in: .all))
        #expect(Policy.shows(.radio, in: .radio))
        #expect(!Policy.shows(.radio, in: .music))
        #expect(!Policy.shows(.music, in: .spokenWord))
    }

    // MARK: Normalising

    @Test func normalisesCaseWidthDiacriticsAndSpaces() {
        #expect(Policy.normalized("  ＣＮＲ   Music ") == "cnr music")
        #expect(Policy.normalized("Café") == "cafe")
        #expect(Policy.normalized("   ").isEmpty)
    }

    // MARK: Radio

    private let stations: [Policy.RadioCandidate] = [
        .init(id: "a", name: "Jazz Lounge", folderName: "Night", tagNames: ["chill"]),
        .init(id: "b", name: "Classic FM", folderName: "Jazz", tagNames: []),
        .init(id: "c", name: "News 24", folderName: nil, tagNames: ["talk", "jazz-free"]),
        .init(id: "d", name: "Jazz", folderName: nil, tagNames: []),
        .init(id: "e", name: "Pop Hits", nowPlayingTitle: "Some Jazz Standard"),
    ]

    @Test func radioRanksNameThenNowPlayingThenFolderThenTag() {
        let matches = Policy.matchStations(query: "jazz", in: stations)
        #expect(matches.map(\.stationID) == ["d", "a", "e", "b", "c"])
        #expect(matches.map(\.field) == [.name, .name, .nowPlaying, .folder, .tag])
    }

    @Test func radioIsWidthAndCaseInsensitive() {
        let matches = Policy.matchStations(query: "ＣＬＡＳＳＩＣ", in: stations)
        #expect(matches.map(\.stationID) == ["b"])
    }

    @Test func radioMatchesWordsAcrossFields() {
        let matches = Policy.matchStations(query: "lounge night", in: stations)
        #expect(matches.map(\.stationID) == ["a"])
        #expect(matches.first?.field == .words)
    }

    @Test func radioEmptyQueryMatchesNothing() {
        #expect(Policy.matchStations(query: "  ", in: stations).isEmpty)
        #expect(Policy.matchStations(query: "zzz", in: stations).isEmpty)
    }

    // MARK: Spoken word

    private func book(
        _ album: String,
        author: String?,
        items: [(id: String, title: String, file: String)]
    ) -> [SpokenWordBookItem] {
        items.enumerated().map { index, item in
            SpokenWordBookItem(
                id: item.id,
                title: item.title,
                albumTitle: album,
                albumArtist: author,
                trackNumber: index + 1,
                duration: 600,
                fileName: item.file
            )
        }
    }

    private var shelf: [SpokenWordBook] {
        SpokenWordBookGrouping.books(from:
            book("The Three Kingdoms", author: "Shan Tianfang", items: [
                ("t1", "Episode 1", "/books/tk/001.mp3"),
                ("t2", "Peach Garden Oath", "/books/tk/002.mp3"),
            ])
            + book("Kingdom Come", author: "Someone", items: [("k1", "Part 1", "/k/1.m4b")])
            + book("Lectures", author: "Prof. Kingdom", items: [("l1", "Intro", "/l/intro.mp3")])
            + book("Radio Plays", author: "BBC", items: [
                ("r1", "Act One", "/r/act1.mp3"),
                ("r2", "Act Two", "/r/kingdom-special.mp3"),
            ])
        )
    }

    @Test func bookRanksTitleThenAuthorThenItem() {
        let matches = Policy.matchBooks(query: "kingdom", in: shelf)
        let titles = matches.compactMap { match in shelf.first { $0.id == match.bookID }?.title }
        #expect(titles == ["Kingdom Come", "The Three Kingdoms", "Lectures", "Radio Plays"])
        #expect(matches.map(\.field) == [.title, .title, .author, .item])
        #expect(matches.last?.matchedItemID == "r2")
    }

    @Test func bookMatchesItemTitleAndReportsItem() {
        let matches = Policy.matchBooks(query: "peach garden", in: shelf)
        #expect(matches.count == 1)
        #expect(matches.first?.field == .item)
        #expect(matches.first?.matchedItemID == "t2")
    }

    @Test func bookFileNameIgnoresFolderAndExtension() {
        #expect(Policy.matchBooks(query: "books", in: shelf).isEmpty)
        #expect(Policy.matchBooks(query: "mp3", in: shelf).isEmpty)
        #expect(Policy.matchBooks(query: "002", in: shelf).first?.matchedItemID == "t2")
    }

    @Test func bookMatchesTitleAndAuthorWords() {
        let matches = Policy.matchBooks(query: "three tianfang", in: shelf)
        #expect(matches.count == 1)
        #expect(matches.first?.field == .words)
    }

    @Test func bookAuthorFallsBackToItemArtist() {
        let items = [SpokenWordBookItem(
            id: "x", title: "Chapter", albumTitle: "Story", artist: "Narrator Name", duration: 60
        )]
        let books = SpokenWordBookGrouping.books(from: items)
        #expect(Policy.matchBooks(query: "narrator", in: books).first?.field == .author)
    }
}
