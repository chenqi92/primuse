import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audiobookshelf")
struct AudiobookshelfServiceTests {
    @Test("Server endpoints keep the prefix; track and cover references round-trip")
    func protocolReferences() throws {
        let base = try #require(AudiobookshelfAPIProtocol.serverBaseURL(
            host: "books.example.com",
            port: 13378,
            useSSL: false,
            basePath: "/abs"
        ))
        #expect(base.absoluteString == "http://books.example.com:13378/abs")
        let libraries = try #require(AudiobookshelfAPIProtocol.endpointURL(serverBaseURL: base, path: "/api/libraries"))
        #expect(libraries.path == "/abs/api/libraries")
        let login = try #require(AudiobookshelfAPIProtocol.endpointURL(serverBaseURL: base, path: "/login"))
        #expect(login.path == "/abs/login")
        #expect(AudiobookshelfAPIProtocol.fileURL(serverBaseURL: base, itemID: "li_1", ino: "42")?.path
            == "/abs/api/items/li_1/file/42")
        // 转义过的 id 段不再被转第二遍(`%20` 曾经变成 `%2520`)。
        #expect(AudiobookshelfAPIProtocol.fileURL(serverBaseURL: base, itemID: "li 1", ino: "42")?.absoluteString
            == "http://books.example.com:13378/abs/api/items/li%201/file/42")

        let filePath = AudiobookshelfAPIProtocol.trackPath(itemID: "li_1", kind: .file(ino: "42"), fileExtension: "M4B")
        #expect(filePath == "/audiobookshelf/items/li_1/files/42.m4b")
        let file = try #require(AudiobookshelfAPIProtocol.trackReference(from: filePath))
        #expect(file.itemID == "li_1")
        #expect(file.kind == .file(ino: "42"))
        #expect(file.fileExtension == "m4b")

        let episodePath = AudiobookshelfAPIProtocol.trackPath(itemID: "li_2", kind: .episode(id: "ep_9"), fileExtension: "mp3")
        let episode = try #require(AudiobookshelfAPIProtocol.trackReference(from: episodePath))
        #expect(episode.kind == .episode(id: "ep_9"))
        #expect(AudiobookshelfAPIProtocol.trackReference(from: "/items/42.mp3") == nil)
        #expect(AudiobookshelfAPIProtocol.trackReference(from: "/audiobookshelf/items/li_1/other/1.mp3") == nil)

        let cover = AudiobookshelfAPIProtocol.coverReference(itemID: "li_1", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(AudiobookshelfAPIProtocol.coverItemID(fromReference: cover) == "li_1")
        #expect(AudiobookshelfAPIProtocol.coverItemID(fromReference: "songloft:cover:songs:1:x") == nil)
    }

    // 计算属性而不是静态常量:`[String: Any]` 不是 Sendable,严格并发下不能做全局常量。
    private static var bookJSON: [String: Any] { [
        "id": "li_book",
        "libraryId": "lib_books",
        "mediaType": "book",
        "addedAt": 1_700_000_000_000,
        "updatedAt": 1_700_000_500_000,
        "media": [
            "coverPath": "/metadata/items/li_book/cover.jpg",
            "duration": 180.0,
            "metadata": [
                "title": "The Long Walk",
                "authors": [["id": "au_1", "name": "Stephen King"]],
                "narrators": ["Kirby Heyborne"],
                "series": [["id": "se_1", "name": "Bachman", "sequence": "1"]],
                "genres": ["Fiction", "Thriller"],
                "publishedYear": "1979",
            ],
            "audioFiles": [
                ["ino": "11", "index": 1, "duration": 60.0, "metadata": ["filename": "01 - Part One.mp3", "ext": ".mp3", "size": 1000],
                 "metaTags": ["tagTitle": "Part One"], "trackNumFromMeta": 1, "bitRate": 128_000],
                ["ino": "12", "index": 2, "duration": 120.0, "metadata": ["filename": "02.mp3", "ext": ".mp3", "size": 2000]],
                ["ino": "13", "index": 3, "duration": 5.0, "exclude": true, "metadata": ["filename": "junk.mp3", "ext": ".mp3", "size": 1]],
            ],
            "chapters": [
                ["id": 0, "start": 0.0, "end": 30.0, "title": "Chapter 1"],
                ["id": 1, "start": 30.0, "end": 90.0, "title": "Chapter 2"],
                ["id": 2, "start": 90.0, "end": 180.0, "title": "Chapter 3"],
            ],
        ],
    ] }

    @Test("A book becomes one song per audio file, grouped as one album by its author")
    func bookSongs() throws {
        let item = try #require(AudiobookshelfCatalogItem(json: Self.bookJSON))
        #expect(item.mediaType == .book)
        #expect(item.audioFiles.map(\.ino) == ["11", "12"])
        #expect(item.mediaIsComplete)
        #expect(!item.needsExpandedFetch)
        let songs = item.makeSongs(sourceID: "src")
        #expect(songs.count == 2)
        let first = try #require(songs.first)
        #expect(first.title == "Part One")
        #expect(first.albumTitle == "The Long Walk")
        #expect(first.albumArtistName == "Stephen King")
        #expect(first.artistName == "Kirby Heyborne")
        #expect(first.trackNumber == 1)
        #expect(first.duration == 60)
        #expect(first.fileFormat == .mp3)
        #expect(first.filePath == "/audiobookshelf/items/li_book/files/11.mp3")
        #expect(first.serverLibraryID == "lib_books")
        #expect(first.bitRate == 128)
        #expect(first.year == 1979)
        #expect(first.genre == "Fiction, Thriller")
        #expect(first.coverArtFileName.map { AudiobookshelfAPIProtocol.coverItemID(fromReference: $0) } == "li_book")
        #expect(songs[1].title == "02")
        #expect(songs[1].trackNumber == 2)
        // Stable ids: the same payload maps to the same song twice.
        #expect(item.makeSongs(sourceID: "src").map(\.id) == songs.map(\.id))
        #expect(first.id != songs[1].id)
    }

    @Test("Book-level chapters are cut onto each file's own timeline")
    func chaptersPerFile() throws {
        let item = try #require(AudiobookshelfCatalogItem(json: Self.bookJSON))
        #expect(item.tracks.map(\.startOffset) == [0, 60])
        let firstFile = item.chapters(forIno: "11")
        #expect(firstFile.map(\.startTime) == [0, 30])
        #expect(firstFile.map(\.title) == ["Chapter 1", "Chapter 2"])
        // Chapter 2 started at 30 s of the book and is still running when file two begins at 60 s.
        let secondFile = item.chapters(forIno: "12")
        #expect(secondFile.map(\.startTime) == [0, 30])
        #expect(secondFile.map(\.title) == ["Chapter 2", "Chapter 3"])
        #expect(item.chapters(forIno: "99").isEmpty)
    }

    @Test("Listening positions convert between a file and the whole book")
    func positions() throws {
        let item = try #require(AudiobookshelfCatalogItem(json: Self.bookJSON))
        #expect(item.bookPosition(ino: "12", localPosition: 15) == 75)
        #expect(item.bookPosition(ino: "11", localPosition: 999) == 60)
        let inSecond = try #require(item.filePosition(bookPosition: 75))
        #expect(inSecond.ino == "12")
        #expect(inSecond.localPosition == 15)
        let atStart = try #require(item.filePosition(bookPosition: 0))
        #expect(atStart.ino == "11")
        let pastEnd = try #require(item.filePosition(bookPosition: 10_000))
        #expect(pastEnd.ino == "12")
        #expect(pastEnd.localPosition == 120)
    }

    @Test("Server progress spreads over the book's files, and a file position folds back into one")
    func progressMapping() throws {
        let item = try #require(AudiobookshelfCatalogItem(json: Self.bookJSON))
        let midSecond = AudiobookshelfMediaProgress(libraryItemID: "li_book", episodeID: nil, currentTime: 75, duration: 180,
                                                    isFinished: false, lastUpdate: Date(timeIntervalSince1970: 1))
        let spread = item.trackProgress(from: midSecond)
        #expect(spread.count == 2)
        #expect(spread[0].kind == .file(ino: "11"))
        #expect(spread[0].isFinished)
        #expect(spread[1].kind == .file(ino: "12"))
        #expect(spread[1].position == 15)
        #expect(!spread[1].isFinished)
        #expect(spread[1].fileExtension == "mp3")

        let finished = AudiobookshelfMediaProgress(libraryItemID: "li_book", episodeID: nil, currentTime: 180, duration: 180,
                                                   isFinished: true, lastUpdate: nil)
        // 先存局部变量再断言:#expect 的宏展开装不下带 key path 的 allSatisfy。
        let allDone = item.trackProgress(from: finished).allSatisfy { $0.isFinished }
        #expect(allDone)
        #expect(item.trackProgress(from: finished).count == 2)
        #expect(item.trackProgress(from: AudiobookshelfMediaProgress(libraryItemID: "other", episodeID: nil, currentTime: 1,
                                                                     duration: 1, isFinished: false, lastUpdate: nil)).isEmpty)

        let back = try #require(item.serverProgress(for: .file(ino: "12"), position: 15, isFinished: false))
        #expect(back.episodeID == nil)
        #expect(back.currentTime == 75)
        #expect(back.duration == 180)
        #expect(!back.isFinished)
        // Finishing the first file is not finishing the book; finishing the last one is.
        let firstDone = try #require(item.serverProgress(for: .file(ino: "11"), position: 60, isFinished: true))
        #expect(firstDone.currentTime == 60)
        #expect(!firstDone.isFinished)
        let lastDone = try #require(item.serverProgress(for: .file(ino: "12"), position: 120, isFinished: true))
        #expect(lastDone.currentTime == 180)
        #expect(lastDone.isFinished)
        #expect(item.serverProgress(for: .file(ino: "99"), position: 1, isFinished: false) == nil)
    }

    @Test("A minified list row that reports files asks for the expanded item")
    func minifiedRow() throws {
        let json: [String: Any] = [
            "id": "li_min", "libraryId": "lib", "mediaType": "book",
            "media": ["metadata": ["title": "Short"], "numAudioFiles": 3, "duration": 10.0],
        ]
        let item = try #require(AudiobookshelfCatalogItem(json: json))
        #expect(!item.mediaIsComplete)
        #expect(item.needsExpandedFetch)
        #expect(item.makeSongs(sourceID: "src").isEmpty)
        let empty: [String: Any] = [
            "id": "li_empty", "libraryId": "lib", "mediaType": "book",
            "media": ["metadata": ["title": "Ebook only"], "numAudioFiles": 0],
        ]
        #expect(AudiobookshelfCatalogItem(json: empty)?.needsExpandedFetch == false)
    }

    @Test("Podcast episodes become songs under the podcast, newest last")
    func podcastSongs() throws {
        let json: [String: Any] = [
            "id": "li_pod", "libraryId": "lib_pods", "mediaType": "podcast",
            "media": [
                "coverPath": "/cover.jpg",
                "metadata": ["title": "Daily Show", "author": "Some Host", "genres": ["News"]],
                "episodes": [
                    ["id": "ep_2", "index": 2, "title": "Second", "publishedAt": 1_700_100_000_000, "season": 1, "episode": 2,
                     "audioFile": ["ino": "22", "index": 1, "duration": 1200.0, "metadata": ["filename": "two.mp3", "ext": ".mp3", "size": 50]]],
                    ["id": "ep_1", "index": 1, "title": "First", "publishedAt": 1_700_000_000_000,
                     "audioFile": ["ino": "21", "index": 1, "duration": 600.0, "metadata": ["filename": "one.mp3", "ext": ".mp3", "size": 40]]],
                ],
            ],
        ]
        let item = try #require(AudiobookshelfCatalogItem(json: json))
        #expect(item.mediaType == .podcast)
        let songs = item.makeSongs(sourceID: "src")
        #expect(songs.map(\.title) == ["First", "Second"])
        #expect(songs.map(\.filePath) == [
            "/audiobookshelf/items/li_pod/episodes/ep_1.mp3",
            "/audiobookshelf/items/li_pod/episodes/ep_2.mp3",
        ])
        #expect(songs[1].trackNumber == 2)
        #expect(songs[1].discNumber == 1)
        #expect(songs[0].albumTitle == "Daily Show")
        #expect(songs[0].artistName == "Some Host")
        #expect(songs[0].year == 2023)
    }

    @Test("Libraries, progress and login payloads parse in both the new and the legacy shape")
    func payloads() throws {
        let library = try #require(AudiobookshelfLibrary(json: ["id": "lib", "name": "Books", "mediaType": "book", "displayOrder": 2]))
        #expect(library.descriptor.kind == .audiobooks)
        #expect(library.descriptor.defaultsToSpokenWord)
        #expect(AudiobookshelfLibrary(json: ["id": "p", "name": "Pods", "mediaType": "podcast"])?.descriptor.kind == .podcasts)

        let progress = try #require(AudiobookshelfMediaProgress(json: [
            "libraryItemId": "li_book", "episodeId": NSNull(), "currentTime": 75.5, "duration": 180.0,
            "isFinished": false, "lastUpdate": 1_700_000_900_000,
        ]))
        #expect(progress.episodeID == nil)
        #expect(progress.currentTime == 75.5)
        #expect(progress.lastUpdate == Date(timeIntervalSince1970: 1_700_000_900))

        let jwt = try #require(AudiobookshelfServiceClient.bearerToken(fromLoginPayload: [
            "user": ["id": "u", "accessToken": "access", "refreshToken": "refresh", "token": "legacy"],
        ]))
        #expect(jwt.token == "access")
        #expect(jwt.refreshToken == "refresh")
        #expect(!jwt.isLegacy)
        let legacy = try #require(AudiobookshelfServiceClient.bearerToken(fromLoginPayload: ["user": ["token": "legacy"]]))
        #expect(legacy.token == "legacy")
        #expect(legacy.isLegacy)
        #expect(AudiobookshelfServiceClient.bearerToken(fromLoginPayload: ["user": ["id": "u"]]) == nil)
    }
}
