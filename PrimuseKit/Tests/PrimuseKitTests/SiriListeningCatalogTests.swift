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

    @Test("Named podcast requests reach the library, preserving RSS ownership of tied titles and saved selections")
    func libraryPodcasts() throws {
        let episodes = ["one", "two", "three"].map { id in
            Song(id: id, title: id, fileFormat: .mp3, filePath: "/\(id).mp3", sourceID: "abs")
        }
        let subscriptions = [show("Story FM")]
        let catalog = SiriPodcastShow.catalog(subscriptions: subscriptions, libraryEpisodes: episodes, libraryShowCount: 2) {
            $0 == "three" ? ("dup", "Story FM") : ("news", "Science News")
        }
        #expect(catalog.map(\.title) == ["Story FM", "Science News", "Story FM"])
        let news = try #require(SiriPodcastShow.namedItems(catalog, query: "Science News").first)
        #expect(SiriPodcastShow.libraryID(for: news.id) == "news")
        #expect(SiriPodcastShow.namedItems(catalog, query: "Story FM").first?.id == subscriptions[0].id)
        let saved = SiriMediaIdentifier.namespaced(catalog[2].id, as: "podcastshow")
        #expect(SiriPodcastShow.namedItems(catalog, query: nil, identifiers: [saved]).first?.id == catalog[2].id)
        #expect(SiriPodcastShow.namedItems(catalog, query: "Story FM", identifiers: ["radio:station"]).isEmpty)
        #expect(SiriPodcastShow.needsLibrary(subscriptions: subscriptions, query: nil, identifiers: [saved], needsUnnamedLookup: false))
        #expect(!SiriPodcastShow.needsLibrary(subscriptions: subscriptions, query: "Story FM", identifiers: [], needsUnnamedLookup: true))
        #expect(!SiriPodcastShow.needsLibrary(subscriptions: subscriptions, query: nil, identifiers: [], needsUnnamedLookup: false))
        let positions = ["one": now, "three": now.addingTimeInterval(-30), "archived": now.addingTimeInterval(20)]
        func recent(after subscriptionDate: Date?) -> String? {
            SiriPodcastShow.mostRecentLibraryEpisode(in: positions, newerThan: subscriptionDate, updatedAt: { $0 }) { id in
                episodes.first { $0.id == id }
            }?.id
        }
        #expect(recent(after: nil) == "one")
        #expect(recent(after: now) == nil)
        #expect(recent(after: now.addingTimeInterval(-10)) == "one")
        #expect(!SiriPodcastShow.mayHaveNewerLibraryProgress(than: now, positions: positions, updatedAt: { $0 }, isFinished: { $0 == "archived" }))
        #expect(SiriPodcastShow.mayHaveNewerLibraryProgress(than: now.addingTimeInterval(-10), positions: positions, updatedAt: { $0 }, isFinished: { _ in false }))
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

    @Test("The generic music lookup leaves podcast-specific preparation to the podcast handler")
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

    @Test("Spoken-word items found by a lookup play as part of their book")
    func spokenWordRouting() {
        let bookOf = ["c1": "older", "c2": "older", "c9": "recent", "song": nil] as [String: String?]
        let lookup: (String) -> String? = { bookOf[$0] ?? nil }
        let books = [book("older", listened: now.addingTimeInterval(-86_400)), book("recent", listened: now)]

        // A chapter named by its title starts there.
        #expect(SiriSpokenWordRouting.start(
            forFoundSongIDs: ["c2", "c1"],
            bookID: lookup,
            books: books,
            namesItem: true
        ) == .init(bookID: "older", itemID: "c2"))
        // An album, artist or genre continues the book listened to last.
        #expect(SiriSpokenWordRouting.start(
            forFoundSongIDs: ["c1", "c2", "c9"],
            bookID: lookup,
            books: books,
            namesItem: false
        ) == .init(bookID: "recent", itemID: nil))
        // Nothing started among them: the first one found, from where it was left.
        #expect(SiriSpokenWordRouting.start(
            forFoundSongIDs: ["c1"],
            bookID: lookup,
            books: [],
            namesItem: false
        ) == .init(bookID: "older", itemID: nil))
        // Music stays music.
        #expect(SiriSpokenWordRouting.start(
            forFoundSongIDs: ["song", "c1"],
            bookID: lookup,
            books: books,
            namesItem: true
        ) == nil)
    }

    @Test("Titles name an item; albums, artists and genres name a container")
    func namesItem() {
        #expect(SiriSpokenWordRouting.namesItem(SiriMediaSearchQuery(kind: .song, mediaName: "a"), identifiers: []))
        #expect(SiriSpokenWordRouting.namesItem(SiriMediaSearchQuery(kind: .music, mediaName: "a"), identifiers: []))
        #expect(!SiriSpokenWordRouting.namesItem(SiriMediaSearchQuery(kind: .album, mediaName: "a"), identifiers: []))
        #expect(!SiriSpokenWordRouting.namesItem(SiriMediaSearchQuery(kind: .music, artistName: "a"), identifiers: []))
        #expect(SiriSpokenWordRouting.namesItem(SiriMediaSearchQuery(kind: .music), identifiers: ["song:a"]))
        #expect(!SiriSpokenWordRouting.namesItem(SiriMediaSearchQuery(kind: .music), identifiers: ["album:a"]))
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
