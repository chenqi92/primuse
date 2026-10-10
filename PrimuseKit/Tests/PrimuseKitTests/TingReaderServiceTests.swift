import Foundation
import Testing
@testable import PrimuseKit

@Suite("Ting Reader")
struct TingReaderServiceTests {
    @Test("Server endpoints keep the prefix; track and cover references round-trip")
    func protocolReferences() throws {
        let base = try #require(TingReaderAPIProtocol.serverBaseURL(
            host: "nas.example.com",
            port: 3000,
            useSSL: false,
            basePath: "/ting"
        ))
        #expect(base.absoluteString == "http://nas.example.com:3000/ting")
        #expect(TingReaderAPIProtocol.endpointURL(serverBaseURL: base, path: "/api/books")?.path == "/ting/api/books")
        #expect(TingReaderAPIProtocol.streamURL(serverBaseURL: base, chapterID: "c 1")?.absoluteString
            == "http://nas.example.com:3000/ting/api/stream/c%201")
        let unicodePrefix = try #require(TingReaderAPIProtocol.serverBaseURL(
            host: "nas.example.com", port: nil, useSSL: true, basePath: "听书"
        ))
        let books = try #require(TingReaderAPIProtocol.endpointURL(serverBaseURL: unicodePrefix, path: "/api/books"))
        #expect(books.absoluteString == "https://nas.example.com/%E5%90%AC%E4%B9%A6/api/books")

        let path = TingReaderAPIProtocol.trackPath(bookID: "book-1", chapterID: "chap-9", fileExtension: ".M4A")
        #expect(path == "/tingreader/books/book-1/chapters/chap-9.m4a")
        let reference = try #require(TingReaderAPIProtocol.trackReference(from: path))
        #expect(reference == .init(bookID: "book-1", chapterID: "chap-9", fileExtension: "m4a"))
        #expect(TingReaderAPIProtocol.trackReference(from: "/tingreader/books/book-1/other/chap-9.mp3") == nil)
        #expect(TingReaderAPIProtocol.trackReference(from: "/audiobookshelf/items/li_1/files/42.m4b") == nil)

        for cover in ["/app/storage/三体/cover.jpg", "https://imagev2.example.com/a.jpg#referer=https://example.com"] {
            let encoded = TingReaderAPIProtocol.coverReference(bookID: "book-1", libraryID: "lib:1", coverPath: cover)
            #expect(!encoded.contains("/"))
            let decoded = try #require(TingReaderAPIProtocol.coverReference(from: encoded))
            #expect(decoded == .init(bookID: "book-1", libraryID: "lib:1", path: cover))
        }
        #expect(TingReaderAPIProtocol.coverReference(from: "audiobookshelf:cover:li_1:0") == nil)
        #expect(TingReaderAPIProtocol.coverReference(from: "tingreader:cover:book-1:lib:") == nil)
    }

    @Test("Audio suffixes come from the server path; notes and unknown suffixes become bin")
    func audioFileExtensions() {
        #expect(TingReaderAPIProtocol.audioFileExtension(forServerPath: "/app/storage/书/01 第一章.MP3") == "mp3")
        #expect(TingReaderAPIProtocol.audioFileExtension(forServerPath: "/dav/books/a.m4b") == "m4b")
        #expect(TingReaderAPIProtocol.audioFileExtension(forServerPath: "https://cdn.example.com/ep1.mp3?sign=x") == "mp3")
        #expect(TingReaderAPIProtocol.audioFileExtension(forServerPath: "/app/storage/book/01.strm") == "bin")
        #expect(TingReaderAPIProtocol.audioFileExtension(forServerPath: "/app/storage/book/01") == "bin")
        #expect(TingReaderAPIProtocol.audioFileExtension(forServerPath: "/app/storage/v1.2 final/chapter") == "bin")
        #expect(TingReaderAPIProtocol.audioFileExtension(forServerPath: "C:\\books\\01.flac") == "flac")
    }

    @Test("Server timestamps parse with nanoseconds, offsets and SQLite's format")
    func timestamps() throws {
        let nanos = try #require(tingReaderDate("2026-10-09T12:34:56.123456789+00:00"))
        #expect(abs(nanos.timeIntervalSince1970 - 1_791_549_296.123) < 0.001)
        let offset = try #require(tingReaderDate("2026-10-09T20:34:56+08:00"))
        #expect(offset.timeIntervalSince1970 == 1_791_549_296)
        let sqlite = try #require(tingReaderDate("2026-10-09 12:34:56"))
        #expect(sqlite.timeIntervalSince1970 == 1_791_549_296)
        #expect(tingReaderDate("yesterday") == nil)
    }

    @Test("Books and chapters parse; chapters become songs grouped under the book")
    func catalogueMapping() throws {
        let book = try #require(TingReaderBook(json: try Self.object(Self.bookJSON)))
        #expect(book.title == "三体")
        #expect(book.author == "刘慈欣")
        #expect(book.narrator == "冯雪松")
        #expect(book.year == 2008)
        #expect(book.createdAt != nil)
        #expect(TingReaderBook(json: ["id": "b", "title": " ", "path": "/app/storage/鬼吹灯/"])?.title == "鬼吹灯")
        #expect(TingReaderBook(json: ["id": "b"])?.title == "b")
        let chapters = try Self.array(Self.chaptersJSON).compactMap(TingReaderChapter.init(json:))
        #expect(chapters.count == 3)
        #expect(chapters[2].isExtra)
        #expect(chapters[0].duration == 1800)
        #expect(chapters[0].progressPosition == 1790.5)

        let catalogBook = TingReaderCatalogBook(book: book, chapters: chapters)
        let songs = catalogBook.makeSongs(sourceID: "src")
        #expect(songs.map(\.title) == ["第一章 科学边界", "02 射手和农场主", "番外 1"])
        #expect(songs.map(\.trackNumber) == [1, 2, 3])
        #expect(songs.allSatisfy { $0.albumTitle == "三体" && $0.albumID == "book-1" })
        #expect(songs.allSatisfy { $0.artistName == "冯雪松" && $0.albumArtistName == "刘慈欣" })
        #expect(songs.allSatisfy { $0.serverLibraryID == "lib-1" && $0.sourceID == "src" })
        #expect(songs[0].filePath == "/tingreader/books/book-1/chapters/ch-1.mp3")
        #expect(songs[1].fileFormat == .m4a)
        #expect(songs[2].filePath.hasSuffix(".bin"))
        let cover = try #require(songs[0].coverArtFileName.flatMap(TingReaderAPIProtocol.coverReference(from:)))
        #expect(cover.path == "/app/storage/三体/cover.jpg")
        #expect(cover.libraryID == "lib-1")

        // 章节挪到别的书(合并书籍)时歌曲 id 不变,进度跟着走。
        let moved = TingReaderCatalogBook(
            book: TingReaderBook(id: "book-2", libraryID: "lib-1", title: "Other"),
            chapters: [chapters[0]]
        )
        #expect(moved.makeSongs(sourceID: "src")[0].id == songs[0].id)
        #expect(moved.makeSongs(sourceID: "src")[0].title == "Other")
        #expect(TingReaderCatalogBook(book: book, chapters: chapters).makeSongs(sourceID: "other")[0].id != songs[0].id)
    }

    @Test("macOS resource forks and folder files are not chapters")
    func systemSidecars() {
        let sidecar = TingReaderChapter(id: "x", bookID: "b", path: "/app/storage/书/._01 第一章.mp3", duration: 0)
        let store = TingReaderChapter(id: "y", bookID: "b", path: "/dav/book/.DS_Store", duration: 0)
        let audio = TingReaderChapter(id: "z", bookID: "b", path: "/app/storage/书/01 第一章.mp3", duration: 180)
        let hidden = TingReaderChapter(id: "w", bookID: "b", path: "/app/storage/书/.intro.mp3", duration: 30)
        #expect(sidecar.isSystemSidecar)
        #expect(store.isSystemSidecar)
        #expect(!audio.isSystemSidecar)
        #expect(!hidden.isSystemSidecar)
        #expect(TingReaderChapter(id: "v", bookID: "b", path: "C:\\books\\._02.m4a", duration: 0).isSystemSidecar)
    }

    @Test("A chapter counts as finished only near its end and past half way")
    func progressPolicy() throws {
        #expect(TingReaderProgressPolicy.isFinished(position: 1790, duration: 1800))
        #expect(!TingReaderProgressPolicy.isFinished(position: 1700, duration: 1800))
        #expect(!TingReaderProgressPolicy.isFinished(position: 3, duration: 20))
        #expect(TingReaderProgressPolicy.isFinished(position: 15, duration: 20))
        #expect(!TingReaderProgressPolicy.isFinished(position: 0, duration: 0))
        #expect(TingReaderProgressPolicy.reportedPosition(position: 100, duration: 1800, isFinished: true) == 1800)
        #expect(TingReaderProgressPolicy.reportedPosition(position: 2000, duration: 1800, isFinished: false) == 1800)
        #expect(TingReaderProgressPolicy.reportedPosition(position: -3, duration: 0, isFinished: false) == 0)

        let chapters = try Self.array(Self.chaptersJSON).compactMap(TingReaderChapter.init(json:))
        let finished = try #require(TingReaderProgressPolicy.progress(for: chapters[0]))
        #expect(finished.isFinished)
        #expect(finished.position == 1800)
        let partial = try #require(TingReaderProgressPolicy.progress(for: chapters[1]))
        #expect(!partial.isFinished)
        #expect(partial.position == 600)
        #expect(TingReaderProgressPolicy.progress(for: chapters[2]) == nil)
    }

    @Test("The public stats fingerprint the catalogue")
    func stats() throws {
        let stats = try #require(TingReaderCatalogStats(json: try Self.object(
            #"{"total_books":12,"total_chapters":340,"total_duration":98765,"last_scan_time":"2026-10-09 12:00:00"}"#
        )))
        #expect(stats.contentRevision == "12:340:98765")
        #expect(stats.lastScanAt != nil)
        #expect(TingReaderCatalogStats(json: ["status": "ok"]) == nil)
        let libraries = try Self.array(#"[{"id":"a","name":"书库","library_type":"local"},{"id":"b","name":"播客","library_type":"rss"}]"#)
            .compactMap(TingReaderLibrary.init(json:))
        #expect(libraries.map(\.descriptor.kind) == [.audiobooks, .podcasts])
    }

    @Test("Login once, list the catalogue, and sign in again after a rejected token")
    func clientCatalogue() async throws {
        let fixture = TingReaderFixture(mode: .expireFirstToken)
        let client = fixture.client()
        let libraries = try await client.libraries()
        #expect(libraries.map(\.id) == ["lib-1"])
        let books = try await client.books()
        #expect(books.map(\.id) == ["book-1", "gone"])

        var walked: [String] = []
        try await TingReaderCatalogWalk.forEachBook(books, client: client) { walked.append($0.book.id) }
        #expect(walked == ["book-1"])

        let requests = await fixture.requests
        let logins = requests.filter { $0.url?.path == "/ting/api/auth/login" }
        #expect(logins.count == 2)
        let body = try #require(logins.first?.httpBody)
        #expect(try Self.object(String(decoding: body, as: UTF8.self))["username"] as? String == "reader")
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-2")
    }

    @Test("Ranges, covers, progress and stats hit the right endpoints")
    func clientMedia() async throws {
        let fixture = TingReaderFixture()
        let client = fixture.client()
        let path = "/tingreader/books/book-1/chapters/ch-1.mp3"
        let bytes = try await client.fetchRange(trackPath: path, offset: 0, length: 2)
        #expect(bytes == Data([0x49, 0x44]))
        await #expect(throws: TingReaderServiceError.rangeNotSupported) {
            try await client.fetchRange(trackPath: "/tingreader/books/book-1/chapters/feed.mp3", offset: 0, length: 2)
        }

        let reference = TingReaderAPIProtocol.coverReference(bookID: "book-1", libraryID: "lib-1", coverPath: "/app/storage/三体/cover.jpg")
        let cover = try await client.coverData(reference: reference, maximumBytes: 1_000)
        #expect(cover == Data([0xFF, 0xD8]))
        #expect(try await client.coverData(reference: reference, maximumBytes: 1) == nil)

        try await client.updateProgress(bookID: "book-1", chapterID: "ch-1", position: 42.5, duration: 1800)
        let stats = try await client.catalogStats()
        #expect(stats.totalChapters == 3)

        let stream = try await client.resolvedStream(trackPath: path)
        #expect(stream.url.path == "/ting/api/stream/ch-1")
        #expect(stream.headers["Authorization"] == "Bearer token-1")

        let requests = await fixture.requests
        let coverRequest = try #require(requests.first { $0.url?.path == "/ting/api/proxy/cover" })
        let query = URLComponents(url: try #require(coverRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "path" }?.value == "/app/storage/三体/cover.jpg")
        #expect(query.first { $0.name == "library_id" }?.value == "lib-1")
        #expect(query.first { $0.name == "book_id" }?.value == "book-1")

        let progress = try #require(requests.first { $0.url?.path == "/ting/api/progress" })
        #expect(progress.httpMethod == "POST")
        let payload = try Self.object(String(decoding: try #require(progress.httpBody), as: UTF8.self))
        #expect(payload["book_id"] as? String == "book-1")
        #expect(payload["chapter_id"] as? String == "ch-1")
        #expect(payload["position"] as? Double == 42.5)

        let statsRequest = try #require(requests.first { $0.url?.path == "/ting/api/stats" })
        #expect(statsRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Booklists and favorites read and write the account's own lists")
    func clientPlaylistsAndFavorites() async throws {
        let fixture = TingReaderFixture()
        let client = fixture.client()
        let playlists = try await client.playlists()
        #expect(playlists == [
            TingReaderPlaylist(id: "pl-1", title: "通勤", bookIDs: ["book-1", "book-2"]),
            TingReaderPlaylist(id: "pl-2", title: "", bookIDs: ["book-3"]),
        ])
        #expect(try await client.favoriteBookIDs() == ["book-1"])
        try await client.setFavorite(bookID: "book-1", isFavorite: false)
        try await client.setFavorite(bookID: "book 2", isFavorite: true)
        let writes = await fixture.requests.filter { $0.url?.path.hasPrefix("/ting/api/favorites/") == true }
        #expect(writes.map { $0.httpMethod ?? "" } == ["DELETE", "POST"])
        #expect(writes.last?.url?.absoluteString == "http://nas.example.com:3000/ting/api/favorites/book%202")

        // 书单镜像按章节 id 对回本机的歌:和歌曲路径末段读出来的一致。
        let path = TingReaderAPIProtocol.trackPath(bookID: "book-1", chapterID: "ch 1", fileExtension: "mp3")
        #expect(ServerPlaylistIdentity.serverItemID(fromFilePath: path) == TingReaderAPIProtocol.serverItemID(chapterID: "ch 1"))
    }

    @Test("Missing or rejected credentials surface as sign-in errors")
    func credentialErrors() async {
        let missing = TingReaderServiceClient(
            sourceID: "x", host: "nas.example.com", port: 3000, useSSL: false, basePath: nil,
            username: "", password: ""
        )
        await #expect(throws: TingReaderServiceError.missingCredential) { try await missing.libraries() }

        let fixture = TingReaderFixture(mode: .wrongPassword)
        await #expect(throws: TingReaderServiceError.authenticationFailed) { try await fixture.client().libraries() }
        #expect(TingReaderServiceClient.token(fromLoginPayload: ["user": ["id": "1"], "token": "jwt"]) == "jwt")
        #expect(TingReaderServiceClient.token(fromLoginPayload: ["user": ["id": "1"]]) == nil)
    }

    // MARK: - Fixtures

    static let bookJSON = #"""
    {"id":"book-1","library_id":"lib-1","title":"三体","author":"刘慈欣","narrator":"冯雪松",
     "cover_url":"/app/storage/三体/cover.jpg","genre":"科幻","year":2008,"skip_intro":0,"skip_outro":0,
     "path":"/app/storage/三体","hash":"h","tags":null,"created_at":"2026-01-02 03:04:05","library_type":"local",
     "is_favorite":false,"progress_percent":40.0,"manual_corrected":false}
    """#

    static let chaptersJSON = #"""
    [{"id":"ch-1","book_id":"book-1","title":"第一章 科学边界","path":"/app/storage/三体/01.mp3","duration":1800,
      "chapter_index":1,"is_extra":0,"created_at":"2026-01-02 03:04:05","progress_position":1790.5,
      "progress_updated_at":"2026-10-09T12:34:56.123456789+00:00"},
     {"id":"ch-2","book_id":"book-1","title":null,"path":"/app/storage/三体/02 射手和农场主.m4a","duration":1800,
      "chapter_index":2,"is_extra":0,"created_at":"2026-01-02 03:04:05","progress_position":600,
      "progress_updated_at":"2026-10-09T12:00:00+00:00"},
     {"id":"ch-3","book_id":"book-1","title":"番外 1","path":"/app/storage/三体/extra.strm","duration":300,
      "chapter_index":1,"is_extra":1,"created_at":"2026-01-02 03:04:05","progress_position":null,
      "progress_updated_at":null}]
    """#

    static func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    static func array(_ json: String) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }
}

private actor TingReaderFixture {
    enum Mode { case normal, expireFirstToken, wrongPassword }
    let mode: Mode
    var requests: [URLRequest] = []
    private var logins = 0

    init(mode: Mode = .normal) { self.mode = mode }

    nonisolated func client() -> TingReaderServiceClient {
        TingReaderServiceClient(
            source: MusicSource(id: "src", name: "Ting", type: .tingReader, host: "nas.example.com",
                                port: 3000, useSsl: false, username: "reader", basePath: "/ting"),
            credential: SourceCredential(username: "reader", password: "secret"),
            transport: TingReaderRequestTransport(data: { try await self.reply($0) }, download: { request in
                let (data, response) = try await self.reply(request)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try data.write(to: file)
                return (file, response)
            })
        )
    }

    func reply(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let path = String(url.path.dropFirst("/ting".count))
        if path == "/api/auth/login" {
            if mode == .wrongPassword { return response(url, status: 401, json: #"{"error":"AuthenticationError"}"#) }
            logins += 1
            return response(url, json: #"{"user":{"id":"u1","username":"reader","role":"user"},"token":"token-\#(logins)"}"#)
        }
        if path == "/api/stats" {
            return response(url, json: #"{"total_books":1,"total_chapters":3,"total_duration":3900,"last_scan_time":null}"#)
        }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        if mode == .expireFirstToken, authorization == "Bearer token-1" {
            return response(url, status: 401, json: #"{"error":"AuthenticationError"}"#)
        }
        guard authorization?.hasPrefix("Bearer token-") == true else { return response(url, status: 401, json: "{}") }
        switch path {
        case "/api/libraries":
            return response(url, json: #"[{"id":"lib-1","name":"书库","library_type":"local","url":"/app/storage","root_path":"/"}]"#)
        case "/api/books":
            return response(url, json: "[\(TingReaderServiceTests.bookJSON),{\"id\":\"gone\",\"library_id\":\"lib-1\",\"title\":\"Gone\"}]")
        case "/api/books/book-1/chapters":
            return response(url, json: TingReaderServiceTests.chaptersJSON)
        case "/api/books/gone/chapters":
            return response(url, status: 404, json: #"{"error":"NotFound"}"#)
        case "/api/stream/ch-1":
            return (Data([0x49, 0x44]), HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                "Content-Type": "audio/mpeg", "Content-Length": "2", "Content-Range": "bytes 0-1/1000",
            ])!)
        case "/api/stream/feed":
            return (Data(repeating: 0, count: 8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": "audio/mpeg",
            ])!)
        case "/api/proxy/cover":
            return (Data([0xFF, 0xD8]), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": "image/jpeg",
            ])!)
        case "/api/playlists":
            return response(url, json: #"""
            [{"id":"pl-1","title":"通勤","book_ids":["book-1","book-2","book-1"],"books":[],"items":[]},
             {"id":"pl-2","title":null,"books":[{"id":"book-3"}],"items":[]},
             {"title":"broken"}]
            """#)
        case "/api/favorites":
            return response(url, json: "[\(TingReaderServiceTests.bookJSON)]")
        case "/api/favorites/book-1", "/api/favorites/book 2":
            return response(url, status: request.httpMethod == "POST" ? 201 : 200, json: #"{"message":"ok"}"#)
        case "/api/progress":
            return response(url, json: #"{"id":"p1","book_id":"book-1","chapter_id":"ch-1","position":42.5}"#)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func response(_ url: URL, status: Int = 200, json: String) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
