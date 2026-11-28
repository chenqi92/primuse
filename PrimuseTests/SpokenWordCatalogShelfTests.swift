import Foundation
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse
#if os(iOS)
import UIKit
#endif

/// 6c 单元 4 U8a(S4):有声书架与本机播客节目从曲库目录取,与歌曲模型在内存里时分出来的逐项相同(书、先后、
/// 章节与章节标题、作者、进度、章数)—— 模型放掉之后、这次启动根本没装模型两种状态都测;取的时候不装模型、
/// 不读整库数组。书架页的刷新在模型不在内存里时从目录分、只是进度变了不重分,本机播客按节目的几件事从目录答。
@MainActor
final class SpokenWordCatalogShelfTests: LibraryReleasedTwinTestCase {
    /// 夹具之外再加一本书和一档在启用源里的本机播客(夹具里的播客在停用的源 B,不可见)。
    static func shelfFixture(prefix: String) -> [Song] {
        var songs = fixture(prefix: prefix)
        func add(_ id: String, _ title: String, album: String, artist: String, track: Int, path: String,
                 genre: String, format: AudioFormat) {
            var song = Song(
                id: "\(prefix)-\(id)", title: title, albumTitle: album, artistName: artist, albumArtistName: nil,
                trackNumber: track, discNumber: 1, duration: 600 + Double(songs.count), fileFormat: format,
                filePath: path, sourceID: sourceA, genre: genre, year: 2010, coverArtFileName: nil
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_100_000 + Double(songs.count))
            songs.append(song)
        }
        for chapter in 1...2 {
            add("other-\(chapter)", "Part \(chapter)", album: "Other Book", artist: "Reader", track: chapter,
                path: "/Books/Other Book/\(chapter).m4b", genre: "Audiobook", format: .m4a)
        }
        for episode in 1...2 {
            add("local-pod-\(episode)", "Local Episode \(episode)", album: "Local Show", artist: "Local Host",
                track: episode, path: "/Podcasts/Local Show/\(episode).mp3", genre: "Podcast", format: .mp3)
        }
        return songs
    }

    /// 按内存里的歌曲模型分的书,同书架页的分法(`SpokenWordBooksModel.refresh`,此刻的进度)。
    private func booksFromTheModel(_ library: MusicLibrary, _ collection: SpokenWordCollection) async -> [SpokenWordBook] {
        let model = SpokenWordBooksModel()
        let store = SpokenWordStore.shared
        await model.refresh(songs: collection.songs(in: library), positions: store.positions, finishedAt: store.finishedAt)
        return model.snapshot.activeEntries.map(\.book)
    }

    private struct Expected {
        let books: [SpokenWordBook]
        let shows: [SpokenWordBook]
        let counts: SpokenWordShelfCounts
        /// 本机播客单集 → (节目 id, 节目名),同 `localPodcastShowID` / `localPodcastShowTitle`。
        let placements: [String: [String?]]
        let showCount: Int
    }

    private func expected(from library: MusicLibrary) async -> Expected {
        let books = await booksFromTheModel(library, .books)
        let shows = await booksFromTheModel(library, .localPodcasts)
        var placements: [String: [String?]] = [:]
        for song in library.localPodcastSongs {
            placements[song.id] = [library.localPodcastShowID(forSongID: song.id), library.localPodcastShowTitle(forSongID: song.id)]
        }
        return Expected(
            books: books, shows: shows,
            counts: SpokenWordShelfCounts(books: library.spokenWordBookCount, chapters: library.spokenWordChapterCount),
            placements: placements, showCount: library.localPodcastShowCount
        )
    }

    private func waitUntil(
        _ step: String, timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "\(step): timed out", file: file, line: line)
    }

    /// 目录给的书架、一本书、本数章数,与按内存分的逐项相同。
    private func assertCatalogShelf(
        _ library: MusicLibrary, _ expected: Expected, _ step: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let books = await SpokenWordCatalogShelf.books(.books, in: library)
        XCTAssertEqual(books, expected.books, "\(step): shelf", file: file, line: line)
        let shows = await SpokenWordCatalogShelf.books(.localPodcasts, in: library)
        XCTAssertEqual(shows, expected.shows, "\(step): local podcast shows", file: file, line: line)
        let counts = await SpokenWordCatalogShelf.counts(in: library)
        XCTAssertEqual(counts, expected.counts, "\(step): book and chapter counts", file: file, line: line)
        for (collection, books) in [(SpokenWordCollection.books, expected.books), (.localPodcasts, expected.shows)] {
            for book in books {
                let answer = await SpokenWordCatalogShelf.book(id: book.id, collection, in: library)
                XCTAssertEqual(answer??.book, book, "\(step): \(book.id)", file: file, line: line)
                XCTAssertEqual(answer??.songs.map(\.id), book.items.map(\.id), "\(step): \(book.id) songs", file: file, line: line)
            }
        }
        if let show = expected.shows.first {
            let asBook = await SpokenWordCatalogShelf.book(id: show.id, .books, in: library)
            XCTAssertNotNil(asBook, "\(step): the catalog answered", file: file, line: line)
            XCTAssertNil(asBook ?? nil, "\(step): a show is not a book on the shelf", file: file, line: line)
        }
        let missing = await SpokenWordCatalogShelf.book(id: "no-such-book", in: library)
        XCTAssertNotNil(missing, "\(step): the catalog answered", file: file, line: line)
        XCTAssertNil(missing ?? nil, "\(step): no such book", file: file, line: line)
    }

    /// 本机播客按节目的几件事:单集在哪档节目、id 是不是节目、几档节目、有没有单集。
    private func assertLocalPodcastLookups(
        _ library: MusicLibrary, _ expected: Expected, songs: [Song], _ step: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertFalse(expected.placements.isEmpty, "the fixture has local podcast episodes", file: file, line: line)
        for song in songs where song.genre == "Podcast" {
            let show = LocalPodcastCatalogLookup.show(of: song, in: library)
            let want = expected.placements[song.id]
            XCTAssertEqual(show.map { [$0.id, $0.title] }, want, "\(step): \(song.id)", file: file, line: line)
        }
        for show in expected.shows {
            XCTAssertTrue(LocalPodcastCatalogLookup.isShow(show.id, in: library), "\(step): \(show.id)", file: file, line: line)
        }
        for book in expected.books {
            XCTAssertFalse(LocalPodcastCatalogLookup.isShow(book.id, in: library), "\(step): \(book.id)", file: file, line: line)
        }
        try await waitUntil("\(step): show count", file: file, line: line) {
            LocalPodcastCatalogLookup.showCount(in: library) == expected.showCount
        }
        XCTAssertTrue(LocalPodcastCatalogLookup.hasEpisodes(in: library), "\(step)", file: file, line: line)
        let query = try XCTUnwrap(LibraryFindPolicy.query("Local Episode 2"))
        let nothing = try XCTUnwrap(LibraryFindPolicy.query("zz-no-such-episode"))
        if library.isReady {
            XCTAssertTrue(PodcastLocalShowsSection.hasMatches(query, in: library, catalogAnswer: nil))
            XCTAssertFalse(PodcastLocalShowsSection.hasMatches(nothing, in: library, catalogAnswer: nil))
        } else {
            // 还没找完时算有(本机节目那一块自己筛);找完了按找出来的答。
            XCTAssertTrue(PodcastLocalShowsSection.hasMatches(nothing, in: library, catalogAnswer: nil))
            XCTAssertFalse(PodcastLocalShowsSection.hasMatches(
                nothing, in: library, catalogAnswer: PodcastLocalFindAnswer(query: nothing, matches: false)
            ))
            XCTAssertTrue(PodcastLocalShowsSection.hasMatches(
                nothing, in: library, catalogAnswer: PodcastLocalFindAnswer(query: query, matches: false)
            ), "an answer for another query is not used")
        }
    }

    /// 模型在内存里时、真放掉之后:目录给的书架、一本书、本数章数与按内存分的相同,本机播客按节目的几件事也是。
    func testShelfFromTheCatalogEqualsTheShelfFromTheSongModel() async throws {
        let songs = Self.shelfFixture(prefix: "shelf-released")
        let (library, _) = try makeLaunchedTwin("shelf-released", songs: songs)
        await assertShadowMatches(library, "fixture")
        let expected = await expected(from: library)
        XCTAssertEqual(expected.books.map(\.title), ["Long Story", "Other Book"], "two books in library order")
        XCTAssertEqual(expected.books.map(\.chapterCount), [3, 2])
        XCTAssertEqual(expected.shows.map(\.title), ["Local Show"], "the disabled source's show is not visible")
        await assertCatalogShelf(library, expected, "loaded")
        try await assertLocalPodcastLookups(library, expected, songs: songs, "loaded")

        let before = try await releaseForReal(library)
        await assertCatalogShelf(library, expected, "released")
        try await assertLocalPodcastLookups(library, expected, songs: songs, "released")
        #if os(iOS)
        try await assertCatalogFind(library, "released")
        #endif
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    /// 这次启动没装歌曲模型:目录给的书架与上一次装着模型时分的相同;本数章数这次启动没分过书,从目录数。
    func testShelfAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let wait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(10)
        defer { MusicLibrary.unloadedLaunchCatalogWait = wait }
        let songs = Self.shelfFixture(prefix: "shelf-unloaded")
        let (source, storage) = try await launchFixture("shelf-unloaded", songs: songs)
        let expected = await expected(from: source)
        let directory = try copyOfDirectory(storage, "shelf-unloaded-launch")
        let library = await launch(directory, unloaded: true)
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        try await waitUntilUsable(library)
        try await waitUntil("catalog readable") { library.readableCatalogReader != nil }
        let before = library.songModelResidencyStatistics
        XCTAssertEqual(before.loads, 0)
        XCTAssertTrue(library.hasSpokenWordContent, "seeded from the catalog at launch")
        // 这次启动没有分过书:本数、章数由曲库在发布时从目录数出来(CF-a),侧栏与资料库入口读的就是它。
        try await waitUntil("book and chapter counts from the catalog") {
            SpokenWordShelfCounts(books: library.spokenWordBookCount, chapters: library.spokenWordChapterCount) == expected.counts
        }

        await assertCatalogShelf(library, expected, "unloaded launch")
        try await assertLocalPodcastLookups(library, expected, songs: songs, "unloaded launch")
        #if os(iOS)
        // 书架页的刷新从目录分出来(以前停在占位上),侧栏、资料库入口的本数章数从目录数。
        let model = SpokenWordBooksModel()
        let shelf = try host(Color.clear.spokenWordBooksRefresh(.books, model: model).environment(library))
        defer { unhost(shelf) }
        try await waitUntil("shelf settles from the catalog") { model.isSettled }
        XCTAssertEqual(model.snapshot.activeEntries.map(\.book), expected.books)
        let counted = Box<SpokenWordShelfCounts?>(nil)
        let probe = try host(CountsProbe { counted.value = $0 }.environment(library))
        defer { unhost(probe) }
        // 曲库自己已经数对了,这个修饰符不必再从目录补(它只管曲库还是 0 的那一段)。
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(counted.value, "the library's own counts are right; nothing to add from the catalog")
        try await assertCatalogFind(library, "unloaded launch")
        #endif
        assertNoLoadAndNoArrayRead(library, since: before, "unloaded launch")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0)
    }

    #if os(iOS)
    /// 书架页挂的刷新:模型放掉时内容没变就不重分;只是进度变了时按新进度重算,书和章节照旧,不装、不读整库数组。
    func testShelfRefreshFollowsProgressWhileReleasedWithoutRegrouping() async throws {
        let songs = Self.shelfFixture(prefix: "shelf-progress")
        let (library, _) = try makeLaunchedTwin("shelf-progress", songs: songs)
        await assertShadowMatches(library, "fixture")
        let expected = await expected(from: library)
        let model = SpokenWordBooksModel()
        let shelf = try host(Color.clear.spokenWordBooksRefresh(.books, model: model).environment(library))
        defer { unhost(shelf) }
        try await waitUntil("shelf settles from the model") { model.isSettled }
        XCTAssertEqual(model.snapshot.activeEntries.map(\.book), expected.books)

        let before = try await releaseForReal(library)
        let generation = model.snapshotGeneration
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(model.isSettled, "the shelf stays")
        XCTAssertEqual(model.snapshotGeneration, generation, "releasing alone does not regroup")
        XCTAssertNotNil(model.settledInputs)
        XCTAssertNil(model.settledInputs?.catalogBooksRevision, "still the grouping from the model")

        let book = try XCTUnwrap(expected.books.first)
        let chapter = try XCTUnwrap(book.items.first).id
        SpokenWordStore.shared.markFinished(true, songIDs: [chapter])
        defer { SpokenWordStore.shared.markFinished(false, songIDs: [chapter]) }
        try await waitUntil("progress reaches the shelf") { model.snapshotGeneration != generation }
        let entry = try XCTUnwrap(model.snapshot.entriesByID[book.id])
        XCTAssertTrue(entry.book.items.first?.isFinished == true)
        XCTAssertEqual(entry.songs.map(\.id), book.items.map(\.id), "chapters kept")
        let fromCatalog = await SpokenWordCatalogShelf.books(.books, in: library)
        XCTAssertEqual(model.snapshot.activeEntries.map(\.book), fromCatalog, "same as grouping the catalog now")
        assertNoLoadAndNoArrayRead(library, since: before, "progress while released")
    }

    /// 播客页「在本页里找」在模型不在内存里时由后台按目录找。
    private func assertCatalogFind(_ library: MusicLibrary, _ step: String) async throws {
        for (text, matches) in [("Local Episode 2", true), ("zz-no-such-episode", false)] {
            let answer = Box<PodcastLocalFindAnswer?>(nil)
            let probe = try host(FindProbe(text: text) { answer.value = $0 }.environment(library))
            defer { unhost(probe) }
            try await waitUntil("\(step): find \(text)") { answer.value != nil }
            XCTAssertEqual(answer.value?.matches, matches, "\(step): find \(text)")
            XCTAssertEqual(answer.value?.query, LibraryFindPolicy.query(text))
        }
    }

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct CountsProbe: View {
        let sink: (SpokenWordShelfCounts?) -> Void
        @State private var counts: SpokenWordShelfCounts?

        var body: some View {
            Color.clear
                .spokenWordCatalogShelfCounts($counts)
                .onChange(of: counts) { _, counts in sink(counts) }
        }
    }

    private struct FindProbe: View {
        let text: String
        let sink: (PodcastLocalFindAnswer?) -> Void
        @State private var answer: PodcastLocalFindAnswer?

        var body: some View {
            Color.clear
                .podcastLocalFind(text, answer: $answer)
                .onChange(of: answer) { _, answer in sink(answer) }
        }
    }

    private func host<Content: View>(_ view: Content) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func unhost(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }
    #endif
}
