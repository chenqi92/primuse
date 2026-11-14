import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audiobookshelf")
struct AudiobookshelfServiceTests {
    @Test func catalogUsesBoundedLargePagesAndPreservesThePartialLastPage() async throws {
        let requests = AudiobookshelfPageRequests()
        let transport = AudiobookshelfRequestTransport(data: { request in
            let url = try #require(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let limit = try #require(Int(query.first { $0.name == "limit" }?.value ?? ""))
            let page = try #require(Int(query.first { $0.name == "page" }?.value ?? ""))
            await requests.append(page: page, limit: limit)
            let start = page * limit
            let rows = (start..<min(start + limit, 501)).map { index -> [String: Any] in
                var book = Self.bookJSON
                book["id"] = "book-\(index)"
                return book
            }
            let data = try JSONSerialization.data(withJSONObject: ["results": rows, "total": 501, "page": page])
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, download: { _ in throw URLError(.unsupportedURL) })
        let client = AudiobookshelfServiceClient(sourceID: UUID().uuidString, host: "books.invalid",
            port: nil, useSSL: true, basePath: nil, username: "", secret: "fixture", authType: .apiKey, transport: transport)
        let first = try await client.libraryItemsPage(libraryID: "books", page: 0)
        let last = try await client.libraryItemsPage(libraryID: "books", page: 1)
        #expect(first.rawCount == 500)
        #expect(last.rawCount == 1)
        #expect((first.items + last.items).map(\.id) == (0..<501).map { "book-\($0)" })
        #expect(await requests.pages == [0, 1])
        #expect(await requests.limits == [500, 500])
    }

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
        #expect(AudiobookshelfAPIProtocol.trackReference(from: "/audiobookshelf/items/li_1/files/42.lrc") == nil)
        #expect(AudiobookshelfAPIProtocol.trackReference(from: "/audiobookshelf/items/li_2/episodes/ep_9.vtt") == nil)

        // 删除：书里的文件删文件本身，播客单集要带 hard=1 才连文件一起删。
        let fileDeletion = AudiobookshelfAPIProtocol.deletionEndpoint(for: file)
        #expect(fileDeletion.path == "/api/items/li_1/file/42")
        #expect(fileDeletion.queryItems.isEmpty)
        let episodeDeletion = AudiobookshelfAPIProtocol.deletionEndpoint(for: episode)
        #expect(episodeDeletion.path == "/api/podcasts/li_2/episode/ep_9")
        #expect(episodeDeletion.queryItems == [URLQueryItem(name: "hard", value: "1")])
        #expect(AudiobookshelfAPIProtocol.trackReference(from: "/audiobookshelf/items/li_1/files/42-cover.jpg") == nil)

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
        #expect(first.genre == "Fiction; Thriller")
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

@Suite("Audiobookshelf expanded items")
struct AudiobookshelfExpansionTests {
    private static func minifiedRow(_ id: String) -> [String: Any] {
        ["id": id, "libraryId": "lib_books", "mediaType": "book",
         "media": ["metadata": ["title": id], "numAudioFiles": 2, "duration": 180.0]]
    }

    private static func expandedRow(_ id: String) -> [String: Any] {
        ["id": id, "libraryId": "lib_books", "mediaType": "book",
         "media": ["metadata": ["title": id], "duration": 180.0,
                   "audioFiles": [["ino": "\(id)-1", "index": 1, "duration": 180.0,
                                   "metadata": ["filename": "01.mp3", "ext": ".mp3", "size": 1000]]]]]
    }

    private static func response(_ url: URL, status: Int = 200, json: Any) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: json),
         HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private static func client(
        rows: [String],
        batch: @escaping @Sendable ([String]) throws -> (status: Int, json: Any),
        item: @escaping @Sendable (String) throws -> [String: Any],
        recorder: AudiobookshelfExpansionRequests
    ) -> AudiobookshelfServiceClient {
        let transport = AudiobookshelfRequestTransport(data: { request in
            let url = try #require(request.url)
            await recorder.append("\(request.httpMethod ?? "GET") \(url.path)")
            if url.path.hasSuffix("/items/batch/get") {
                let body = try #require(request.httpBody)
                let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                let ids = try #require(payload["libraryItemIds"] as? [String])
                let answer = try batch(ids)
                return try Self.response(url, status: answer.status, json: answer.json)
            }
            if url.path.contains("/api/items/") {
                return try Self.response(url, json: try item(url.lastPathComponent))
            }
            return try Self.response(url, json: ["results": rows.map(Self.minifiedRow), "total": rows.count, "page": 0])
        }, download: { _ in throw URLError(.unsupportedURL) })
        return AudiobookshelfServiceClient(sourceID: UUID().uuidString, host: "books.invalid",
            port: nil, useSSL: true, basePath: nil, username: "", secret: "fixture", authType: .apiKey, transport: transport)
    }

    @Test("Minified list rows are expanded with one batch request")
    func batchExpansion() async throws {
        let recorder = AudiobookshelfExpansionRequests()
        let client = Self.client(
            rows: ["a", "b", "c"],
            batch: { ids in (200, ["libraryItems": ids.map(Self.expandedRow)]) },
            item: { _ in throw URLError(.badServerResponse) },
            recorder: recorder
        )
        let page = try await client.libraryItemsPage(libraryID: "lib_books", page: 0)
        #expect(page.items.map(\.id) == ["a", "b", "c"])
        #expect(page.unexpandedItemCount == 0)
        let songCount = page.items.flatMap { $0.makeSongs(sourceID: "src") }.count
        #expect(songCount == 3)
        let requests = await recorder.requests
        #expect(requests == ["GET /api/libraries/lib_books/items", "POST /api/items/batch/get"])
    }

    @Test("Without the batch endpoint items load one by one, and one that times out is skipped")
    func perItemFallbackSkipsStalledItem() async throws {
        let recorder = AudiobookshelfExpansionRequests()
        let client = Self.client(
            rows: ["a", "slow", "c"],
            batch: { _ in (404, ["error": "Not Found"]) },
            item: { id in
                if id == "slow" { throw URLError(.timedOut) }
                return Self.expandedRow(id)
            },
            recorder: recorder
        )
        let first = try await client.libraryItemsPage(libraryID: "lib_books", page: 0)
        #expect(first.items.map(\.id) == ["a", "c"])
        #expect(first.unexpandedItemCount == 1)
        #expect(first.rawCount == 3)
        let slowAttempts = await recorder.requests.filter { $0 == "GET /api/items/slow" }.count
        #expect(slowAttempts == 2)

        // 批量接口不在,之后不再去试。
        _ = try await client.libraryItemsPage(libraryID: "lib_books", page: 0)
        let batchRequests = await recorder.requests.filter { $0.hasPrefix("POST") }.count
        #expect(batchRequests == 1)
    }

    @Test("A page whose items all fail to expand is an error, not an empty page")
    func wholePageFailureThrows() async throws {
        let recorder = AudiobookshelfExpansionRequests()
        let client = Self.client(
            rows: ["a", "b"],
            batch: { _ in throw URLError(.timedOut) },
            item: { _ in throw URLError(.timedOut) },
            recorder: recorder
        )
        await #expect(throws: URLError.self) {
            _ = try await client.libraryItemsPage(libraryID: "lib_books", page: 0)
        }
    }

    @Test("A batch that misses an item fills it in from the single-item endpoint")
    func batchGapFallsBackPerItem() async throws {
        let recorder = AudiobookshelfExpansionRequests()
        let client = Self.client(
            rows: ["a", "b"],
            batch: { _ in (200, ["libraryItems": [Self.expandedRow("a")]]) },
            item: { id in Self.expandedRow(id) },
            recorder: recorder
        )
        let page = try await client.libraryItemsPage(libraryID: "lib_books", page: 0)
        #expect(page.items.map(\.id) == ["a", "b"])
        #expect(page.unexpandedItemCount == 0)
        let singles = await recorder.requests.filter { $0.hasPrefix("GET /api/items/") }
        #expect(singles == ["GET /api/items/b"])
    }
}

private actor AudiobookshelfExpansionRequests {
    private(set) var requests: [String] = []
    func append(_ request: String) { requests.append(request) }
}

private actor AudiobookshelfPageRequests {
    var pages: [Int] = []
    var limits: [Int] = []
    func append(page: Int, limit: Int) {
        pages.append(page)
        limits.append(limit)
    }
}

@Suite("Audiobookshelf deletion")
struct AudiobookshelfDeletionTests {
    private static func client(status: Int, recorder: AudiobookshelfDeletionRequests) -> AudiobookshelfServiceClient {
        let transport = AudiobookshelfRequestTransport(data: { request in
            let url = try #require(request.url)
            await recorder.append(method: request.httpMethod ?? "GET", url: url)
            return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, download: { _ in throw URLError(.unsupportedURL) })
        return AudiobookshelfServiceClient(sourceID: UUID().uuidString, host: "books.invalid",
            port: nil, useSSL: true, basePath: nil, username: "", secret: "fixture", authType: .apiKey, transport: transport)
    }

    @Test func bookFilesAndEpisodesAreDeletedWithTheirFiles() async throws {
        let recorder = AudiobookshelfDeletionRequests()
        let client = Self.client(status: 200, recorder: recorder)
        let file = try #require(AudiobookshelfAPIProtocol.trackReference(from: "/audiobookshelf/items/li_1/files/42.m4b"))
        let episode = try #require(AudiobookshelfAPIProtocol.trackReference(from: "/audiobookshelf/items/li_2/episodes/ep_9.mp3"))
        #expect(try await client.deleteTrack(reference: file) == .deleted)
        #expect(try await client.deleteTrack(reference: episode) == .deleted)
        let requests = await recorder.requests
        #expect(requests.map(\.method) == ["DELETE", "DELETE"])
        #expect(requests.map(\.url.path) == ["/api/items/li_1/file/42", "/api/podcasts/li_2/episode/ep_9"])
        #expect(requests.last?.url.query == "hard=1")
    }

    /// 403 是账号没有删除权限，不换 token 重试，交给界面说清楚去哪里开权限。
    @Test func forbiddenIsAPermissionRefusalNotAnExpiredSession() async throws {
        let recorder = AudiobookshelfDeletionRequests()
        let client = Self.client(status: 403, recorder: recorder)
        let file = try #require(AudiobookshelfAPIProtocol.trackReference(from: "/audiobookshelf/items/li_1/files/42.mp3"))
        #expect(try await client.deleteTrack(reference: file) == .notPermitted)
        #expect(await recorder.requests.count == 1)
    }

    /// 404 不当成「已经不在了」：地址或反向代理配错时也会这样回。
    @Test func missingItemIsAnErrorNotADeletion() async throws {
        let recorder = AudiobookshelfDeletionRequests()
        let client = Self.client(status: 404, recorder: recorder)
        let file = try #require(AudiobookshelfAPIProtocol.trackReference(from: "/audiobookshelf/items/li_1/files/42.mp3"))
        await #expect(throws: AudiobookshelfServiceError.badServerResponse(404)) {
            _ = try await client.deleteTrack(reference: file)
        }
    }
}

private actor AudiobookshelfDeletionRequests {
    struct Request: Sendable {
        let method: String
        let url: URL
    }
    private(set) var requests: [Request] = []
    func append(method: String, url: URL) { requests.append(Request(method: method, url: url)) }
}
