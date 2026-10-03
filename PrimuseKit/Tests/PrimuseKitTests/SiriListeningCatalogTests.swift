import Foundation
import Testing
@testable import PrimuseKit

@Suite("Siri listening catalog")
struct SiriListeningCatalogTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    @Test("Continue listening picks the book last listened to that is not finished")
    func bookToContinue() {
        let older = book("older", listened: now.addingTimeInterval(-86_400))
        let recent = book("recent", listened: now)
        let unstarted = book("unstarted", listened: nil)

        #expect(SiriListeningCatalog.bookToContinue([unstarted, older, recent])?.id == "recent")
        #expect(SiriListeningCatalog.bookToContinue([unstarted]) == nil)
    }

    @Test("Registered books keep the shelf order and stay within the budget")
    func shortcutBooks() {
        let books = (0..<12).map { book("b\($0)", listened: nil) }
        #expect(SiriListeningCatalog.shortcutBooks(books).map(\.id) == Array(books.prefix(8)).map(\.id))
        #expect(SiriListeningCatalog.shortcutBooks(books, limit: 2).map(\.id) == ["b0", "b1"])
    }

    @Test("A book can be named with its author")
    func bookNames() throws {
        let item = try #require(SiriListeningCatalog.namedItems(books: [
            SpokenWordBook(id: "b", title: "三体", author: "刘慈欣", items: [], resumeItemID: nil, lastListenedAt: nil),
        ]).first)
        #expect(item.name == "三体")
        #expect(item.aliases.contains("三体 刘慈欣"))

        let resolved = SiriNamedMediaResolver.resolve(
            query: "三体",
            namespace: "audiobook",
            items: [item]
        )
        #expect(resolved?.selected.id == "b")
        #expect(resolved?.isStrongMatch == true)
    }

    @Test("Shows with an episode in progress are registered first")
    func shortcutShows() {
        let shows = ["a", "b", "c", "d"].map(show)
        let ordered = SiriListeningCatalog.shortcutShows(shows, recentShowIDs: ["c", "missing", "c", "a"], limit: 3)
        #expect(ordered.map(\.id) == ["c", "a", "b"])
    }

    @Test("Sleep timer requests follow what is playing")
    func sleepTimer() {
        #expect(SiriSleepTimerRequest.minutes30.resolution(space: nil, hasChapters: false) == .set(.minutes(30)))
        #expect(SiriSleepTimerRequest.off.resolution(space: .music, hasChapters: false) == .cancel)
        #expect(SiriSleepTimerRequest.endOfTrack.resolution(space: .music, hasChapters: false) == .set(.endOfTrack))
        #expect(SiriSleepTimerRequest.endOfTrack.resolution(space: .radio, hasChapters: false) == .unavailable)
        #expect(SiriSleepTimerRequest.endOfTrack.resolution(space: nil, hasChapters: false) == .unavailable)
        #expect(SiriSleepTimerRequest.endOfChapter.resolution(space: .spokenWord, hasChapters: true) == .set(.endOfChapter))
        #expect(SiriSleepTimerRequest.endOfChapter.resolution(space: .spokenWord, hasChapters: false) == .set(.endOfTrack))
        #expect(SiriSleepTimerRequest.endOfChapter.resolution(space: .music, hasChapters: true) == .set(.endOfTrack))
        #expect(SiriSleepTimerRequest.endOfChapter.resolution(space: .podcast, hasChapters: true) == .set(.endOfChapter))
    }

    @Test("Book and podcast identifiers survive the namespace round trip")
    func identifiers() {
        let book = SiriMediaIdentifier.namespaced("book-1", as: "audiobook")
        let show = SiriMediaIdentifier.namespaced("podcast-show:abc", as: "podcastshow")
        #expect(SiriMediaIdentifier.value(from: book, expectedNamespace: "audiobook") == "book-1")
        #expect(SiriMediaIdentifier.value(from: show, expectedNamespace: "podcastshow") == "podcast-show:abc")
        #expect(SiriMediaIdentifier.value(from: show, expectedNamespace: "song") == nil)
    }

    @Test("Podcasts never wait for the music library; books do")
    func libraryNeeds() {
        #expect(!SiriRequestNeeds.libraryForPlayback(SiriMediaSearchQuery(kind: .podcast, mediaName: "x"), identifierGroups: []))
        #expect(SiriRequestNeeds.libraryForPlayback(SiriMediaSearchQuery(kind: .audiobook), identifierGroups: []))
        #expect(!SiriRequestNeeds.libraryForResolution(SiriMediaSearchQuery(kind: .audiobook), identifiers: []))
        #expect(SiriRequestNeeds.libraryForResolution(SiriMediaSearchQuery(kind: .audiobook, mediaName: "三体"), identifiers: []))
        #expect(SiriMediaSearchResolver.resolve(
            query: SiriMediaSearchQuery(kind: .podcast, mediaName: "x"),
            songs: []
        ) == nil)
    }

    private func book(_ id: String, listened: Date?) -> SpokenWordBook {
        SpokenWordBook(id: id, title: id, author: nil, items: [], resumeItemID: nil, lastListenedAt: listened)
    }

    private func show(_ id: String) -> PodcastShow {
        PodcastShow(
            id: id,
            feedURL: URL(string: "https://example.com/\(id).xml")!,
            title: id,
            subscribedAt: now
        )
    }
}
