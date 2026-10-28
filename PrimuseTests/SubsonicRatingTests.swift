import Foundation
import PrimuseKit
import XCTest
import SwiftUI
import UIKit
@testable import Primuse

final class SubsonicRatingTests: XCTestCase {
    func testSetAndClearUseOpaqueIDAndReadBackCurrentUserRating() async throws {
        let fixture = RatingHTTPFixture()
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        let rated = try await source.setServerRating(itemID: "song.a-42", rating: 4)
        let cleared = try await source.setServerRating(itemID: "song.a-42", rating: nil)
        XCTAssertEqual(rated, 4)
        XCTAssertNil(cleared)
        let requests = fixture.requests
        XCTAssertEqual(requests.compactMap(\.url?.lastPathComponent), [
            "ping.view", "setRating.view", "getSong.view", "setRating.view", "getSong.view"
        ])
        let writes = requests.filter { $0.url?.lastPathComponent == "setRating.view" }
        XCTAssertEqual(writes.map { query($0)["rating"] }, ["4", "0"])
        for request in writes {
            XCTAssertEqual(query(request)["id"], "song.a-42")
            XCTAssertEqual(query(request)["c"], "Primuse")
            XCTAssertNotNil(query(request)["t"])
            XCTAssertNil(query(request)["albumId"])
            XCTAssertNil(query(request)["artistId"])
        }
    }

    func testInvalidRatingAndIDsNeverReachNetwork() async {
        let fixture = RatingHTTPFixture()
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        for (id, rating) in [("song", 6), ("song", -1), ("song", 0), ("", 3), ("nested/song", 3), ("..", 3)] {
            do {
                _ = try await source.setServerRating(itemID: id, rating: rating)
                XCTFail("Expected invalid input to fail")
            } catch {}
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testHTTP200AuthenticationFailureIsNotSuccess() async {
        let fixture = RatingHTTPFixture(mode: .authenticationFailure)
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await source.setServerRating(itemID: "song", rating: 4)
            XCTFail("Expected authentication failure")
        } catch SourceError.authenticationFailed {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMismatchedMissingAndInvalidReadbackNeverConfirm() async {
        for mode in [RatingHTTPFixture.Mode.mismatchedRating, .missingSong, .wrongSong, .invalidRating] {
            let fixture = RatingHTTPFixture(mode: mode)
            let (source, session) = makeSource(fixture)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await source.setServerRating(itemID: "song", rating: 4)
                XCTFail("Expected readback failure for \(mode)")
            } catch {}
        }
    }

    func testAlbumRatingWritesAlbumIDAndReadsItBackFromTheAlbum() async throws {
        let fixture = RatingHTTPFixture()
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        let rated = try await source.setServerAlbumRating(albumID: "al-1", rating: 5)
        XCTAssertEqual(rated, 5)
        XCTAssertEqual(fixture.requests.compactMap(\.url?.lastPathComponent), [
            "ping.view", "setRating.view", "getAlbum.view"
        ])
        let write = try XCTUnwrap(fixture.requests.first { $0.url?.lastPathComponent == "setRating.view" })
        XCTAssertEqual(query(write)["id"], "al-1")
        XCTAssertEqual(query(write)["rating"], "5")
    }

    func testRatedAlbumListComesFromHighestAndNeedsUserRatings() async throws {
        let fixture = RatingHTTPFixture()
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        let rated = try await source.fetchRatedServerAlbums()
        XCTAssertEqual(rated, ["al-1": 4, "al-2": 5])
        let list = try XCTUnwrap(fixture.requests.first { $0.url?.lastPathComponent == "getAlbumList2.view" })
        XCTAssertEqual(query(list)["type"], "highest")

        // 列表不带 userRating 的服务器:说不清哪张评了几分,不能当成「都没评分」。
        let silent = RatingHTTPFixture(mode: .albumListWithoutRatings)
        let (silentSource, silentSession) = makeSource(silent)
        defer { silentSession.invalidateAndCancel() }
        let unknown = try await silentSource.fetchRatedServerAlbums()
        XCTAssertNil(unknown)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, rhs in rhs })
    }

    private func makeSource(_ fixture: RatingHTTPFixture) -> (SubsonicSource, URLSession) {
        let host = "rating-\(UUID().uuidString.lowercased()).invalid"
        RatingHTTPProtocol.register(fixture, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RatingHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        let source = SubsonicSource(sourceID: host, sourceType: .navidrome, host: host, port: nil,
                                    useSsl: true, basePath: nil, username: "qa", password: "qa", session: session)
        return (source, session)
    }
}

private final class RatingHTTPFixture: @unchecked Sendable {
    enum Mode {
        case success, authenticationFailure, mismatchedRating, missingSong, wrongSong, invalidRating
        case albumListWithoutRatings
    }
    let mode: Mode
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var rating = 0
    var requests: [URLRequest] { lock.withLock { recorded } }
    init(mode: Mode = .success) { self.mode = mode }

    func response(_ request: URLRequest) -> Data {
        lock.withLock {
            recorded.append(request)
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            func param(_ name: String) -> String? { items.first { $0.name == name }?.value }
            var body: [String: Any] = ["status": "ok"]
            switch request.url?.lastPathComponent {
            case "ping.view":
                body["type"] = "navidrome"
                body["openSubsonic"] = true
            case "setRating.view":
                if mode == .authenticationFailure {
                    body = ["status": "failed", "error": ["code": 40, "message": "Wrong credentials"]]
                } else { rating = Int(param("rating") ?? "") ?? 0 }
            case "getSong.view":
                if mode != .missingSong {
                    var song: [String: Any] = ["id": mode == .wrongSong ? "wrong" : (param("id") ?? "")]
                    if rating != 0 {
                        song["userRating"] = mode == .invalidRating ? 9 : (mode == .mismatchedRating ? 2 : rating)
                    }
                    // averageRating is not the authenticated user's personal score.
                    song["averageRating"] = 3.5
                    body["song"] = song
                }
            case "getAlbum.view":
                var album: [String: Any] = ["id": param("id") ?? ""]
                if rating != 0 { album["userRating"] = rating }
                body["album"] = album
            case "getAlbumList2.view":
                let albums: [[String: Any]]
                if mode == .albumListWithoutRatings {
                    albums = [["id": "al-1", "name": "One"]]
                } else if param("type") == "highest", (Int(param("offset") ?? "0") ?? 0) == 0 {
                    albums = [["id": "al-1", "userRating": 4], ["id": "al-2", "userRating": 5]]
                } else {
                    albums = []
                }
                body["albumList2"] = ["album": albums]
            default:
                body = ["status": "failed", "error": ["code": 70, "message": "Unknown method"]]
            }
            return try! JSONSerialization.data(withJSONObject: ["subsonic-response": body])
        }
    }
}

private final class RatingHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: RatingHTTPFixture] = [:]
    static func register(_ fixture: RatingHTTPFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.response(request))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AirsonicMetadataWritebackTests: XCTestCase {
    func testLegacyEditorUsesSeparateCookieSessionAndPreservesUneditedServerTags() async throws {
        let fixture = AirsonicTagHTTPFixture()
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel(); AirsonicTagHTTPProtocol.remove(host: fixture.host) }
        var original = song(fixture)
        original.albumTitle = "Stale local album"
        var updated = original
        updated.title = "歌名\n&=+"
        updated.discNumber = 2
        let result = await source.writeScrapedMetadata(original: original, updated: updated, coverData: Data([1]), lyricsLines: nil, lyricsContent: nil)
        XCTAssertTrue(result.metadataWritten)
        XCTAssertTrue(result.errors.isEmpty, result.errors.description)
        XCTAssertEqual(result.fieldResults.first { $0.field == .title }?.disposition, .written)
        XCTAssertEqual(result.fieldResults.filter { if case .unsupported = $0.disposition { return true }; return false }.count, 2)
        XCTAssertEqual(fixture.written["title"] as? String, "歌名\n&=+")
        XCTAssertEqual(fixture.written["album"] as? String, "Fresh remote album")
        XCTAssertEqual(fixture.written["artist"] as? String, "Remote artist")
        XCTAssertTrue(fixture.problems.isEmpty, fixture.problems.description)
        XCTAssertEqual(fixture.mutationCount, 1)
    }

    func testAdvancedEditorUsesIndexCSRFAndTypedFieldsThenReadsBack() async {
        let fixture = AirsonicTagHTTPFixture(mode: .advanced)
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel(); AirsonicTagHTTPProtocol.remove(host: fixture.host) }
        let original = song(fixture)
        var updated = original
        updated.title = "新版标题"
        updated.year = nil
        updated.trackNumber = 4
        let result = await source.writeScrapedMetadata(original: original, updated: updated, coverData: nil, lyricsLines: nil, lyricsContent: nil)
        XCTAssertTrue(result.metadataWritten)
        XCTAssertTrue(result.errors.isEmpty, result.errors.description)
        XCTAssertEqual(fixture.written["title"] as? String, "新版标题")
        XCTAssertEqual(fixture.written["track"] as? Int, 4)
        XCTAssertTrue(fixture.written["year"] is NSNull)
        XCTAssertEqual(result.fieldResults.filter { $0.disposition == .written }.count, 3)
        XCTAssertTrue(fixture.problems.isEmpty, fixture.problems.description)
    }

    func testPermissionLoginAndProtocolFailuresNeverClaimSuccess() async {
        for mode in [AirsonicTagHTTPFixture.Mode.denied, .loginFailure, .legacyError, .advancedError, .mismatchedReadback] {
            let fixture = AirsonicTagHTTPFixture(mode: mode)
            let (source, session) = makeSource(fixture)
            defer { session.invalidateAndCancel(); AirsonicTagHTTPProtocol.remove(host: fixture.host) }
            let original = song(fixture)
            var updated = original
            updated.title = "Edited title"
            let result = await source.writeScrapedMetadata(original: original, updated: updated, coverData: nil, lyricsLines: nil, lyricsContent: nil)
            XCTAssertFalse(result.metadataWritten, "\(mode)")
            XCTAssertFalse(result.errors.isEmpty, "\(mode)")
            XCTAssertFalse(result.fieldResults.contains { $0.disposition == .written }, "\(mode)")
            if mode == .denied || mode == .loginFailure { XCTAssertEqual(fixture.mutationCount, 0) }
        }
    }

    func testOtherSubsonicServersNeverReachNativeWriteEndpoints() async {
        for type in [MusicSourceType.subsonic, .navidrome, .gonic] {
            let fixture = AirsonicTagHTTPFixture()
            let (source, session) = makeSource(fixture, type: type)
            defer { session.invalidateAndCancel(); AirsonicTagHTTPProtocol.remove(host: fixture.host) }
            let original = song(fixture)
            var updated = original
            updated.title = "New title"
            let result = await source.writeScrapedMetadata(original: original, updated: updated, coverData: nil, lyricsLines: nil, lyricsContent: nil)
            XCTAssertFalse(result.metadataWritten)
            XCTAssertFalse(result.unsupported.isEmpty)
            XCTAssertEqual(fixture.requestCount, 0)
        }
    }

    private func song(_ fixture: AirsonicTagHTTPFixture) -> Song {
        Song(id: "song", title: "Old title", albumTitle: "Fresh remote album", artistName: "Remote artist",
             trackNumber: 1, fileFormat: .mp3, filePath: "42.mp3", sourceID: fixture.host, fileSize: 100, year: 2020)
    }

    private func makeSource(_ fixture: AirsonicTagHTTPFixture, type: MusicSourceType = .airsonic) -> (SubsonicSource, URLSession) {
        AirsonicTagHTTPProtocol.register(fixture)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AirsonicTagHTTPProtocol.self]
        let session = URLSession(configuration: config)
        return (SubsonicSource(sourceID: fixture.host, sourceType: type, host: fixture.host, port: nil,
            useSsl: true, basePath: "/music", username: "editor", password: "中&=+", session: session), session)
    }
}

private final class AirsonicTagHTTPFixture: @unchecked Sendable {
    enum Mode { case legacy, advanced, denied, loginFailure, legacyError, advancedError, mismatchedReadback }
    let host = "airsonic-tags-\(UUID().uuidString.lowercased()).invalid"
    let mode: Mode
    private let lock = NSLock()
    private var edits: [String: Any] = [:]
    private var failures: [String] = []
    private var requests = 0
    private var mutations = 0
    private var polls = 0
    var written: [String: Any] { lock.withLock { edits } }
    var problems: [String] { lock.withLock { failures } }
    var requestCount: Int { lock.withLock { requests } }
    var mutationCount: Int { lock.withLock { mutations } }
    init(mode: Mode = .legacy) { self.mode = mode }

    func response(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        try lock.withLock {
            requests += 1
            let path = request.url!.path
            func text(_ value: String, status: Int = 200, headers: [String: String] = [:]) -> (Int, [String: String], Data) { (status, headers, Data(value.utf8)) }
            func json(_ value: [String: Any]) throws -> (Int, [String: String], Data) {
                (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: ["subsonic-response": value]))
            }
            func require(_ condition: Bool, _ detail: String) { if !condition { failures.append(detail) } }
            if path.contains("/rest/") {
                switch request.url!.lastPathComponent {
                case "ping.view": return try json(["status": "ok", "type": "airsonic"])
                case "getUser.view": return try json(["status": "ok", "user": ["username": "editor", "coverArtRole": mode != .denied]])
                case "getSong.view":
                    var song: [String: Any] = ["id": "42", "title": "Old title", "artist": "Remote artist", "album": "Fresh remote album", "genre": "Rock", "year": 2020, "track": 1]
                    if !edits.isEmpty && mode != .mismatchedReadback { song.merge(edits, uniquingKeysWith: { _, new in new }) }
                    return try json(["status": "ok", "song": song])
                default: throw URLError(.badURL)
                }
            }
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if path == "/music/login" {
                if request.httpMethod == "GET" {
                    return text(#"<form><input name="_csrf" type="hidden" value="login-csrf"/></form>"#, headers: ["Set-Cookie": "JSESSIONID=before-login; Path=/music; HttpOnly"])
                }
                let body = String(decoding: Self.body(request), as: UTF8.self)
                var components = URLComponents()
                components.percentEncodedQuery = body
                let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                require(cookie.contains("JSESSIONID=before-login"), "Missing pre-login cookie")
                require(fields["_csrf"] == "login-csrf" && fields["j_password"] == "中&=+" && fields["j_username"] == "editor", "Login form encoding")
                if mode == .loginFailure { return text("Forbidden", status: 403) }
                return text("", status: 302, headers: ["Set-Cookie": "JSESSIONID=authenticated; Path=/music; HttpOnly", "Location": "/music/index"])
            }
            require(cookie.contains("JSESSIONID=authenticated"), "Missing authenticated cookie at \(path)")
            switch path {
            case "/music/index": return text(#"var csrfheaderName = "X-CSRF-TOKEN"; var csrftoken = "index-csrf";"#)
            case "/music/editTags": return text(mode == .advanced || mode == .advancedError ? "top.StompClient.send('/app/tags/edit');" : "tagService.setTags(id,track,artist,album,title,year,genre);")
            case "/music/dwr/call/plaincall/__System.pageLoaded.dwr":
                require(String(decoding: Self.body(request), as: UTF8.self).contains("scriptSessionId=null\n"), "Missing DWR handshake")
                return text(#"dwr.engine.remote.handleNewScriptSession("script-session"); dwr.engine.remote.handleCallback("0","0",null);"#)
            case "/music/dwr/call/plaincall/tagService.setTags.dwr":
                mutations += 1
                let body = String(decoding: Self.body(request), as: UTF8.self)
                let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "\n").map { line in
                    let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return (String(pair[0]), String(pair[1]))
                })
                require(fields["httpSessionId"] == "authenticated" && fields["scriptSessionId"] == "script-session", "DWR session mismatch")
                require(fields["c0-param0"] == "number:42", "Wrong media ID")
                if mode == .legacyError { return text(#"dwr.engine.remote.handleException("1","0",{});"#) }
                func string(_ index: Int) -> String { String((fields["c0-param\(index)"] ?? "").dropFirst(7)).removingPercentEncoding ?? "" }
                edits = ["title": string(4), "artist": string(2), "album": string(3), "genre": string(6), "track": Int(string(1)).map { $0 as Any } ?? NSNull(), "year": Int(string(5)).map { $0 as Any } ?? NSNull()]
                return text(#"dwr.engine.remote.handleCallback("1","0","UPDATED");"#)
            default:
                guard path.hasPrefix("/music/websocket/000/") else { throw URLError(.badURL) }
                if path.hasSuffix("/xhr_send") {
                    let frames = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String]
                    for frame in frames {
                        let decoded = try AirsonicTagEditingProtocol.stompResponse(frame)
                        if decoded.command == "CONNECT" { require(decoded.headers["X-CSRF-TOKEN"] == "index-csrf", "Wrong STOMP CSRF") }
                        if decoded.command == "SUBSCRIBE" { require(decoded.headers["destination"] == "/user/queue/tags/edit", "Wrong result subscription") }
                        if decoded.command == "SEND" {
                            mutations += 1
                            require(decoded.headers["destination"] == "/app/tags/edit", "Wrong mutation destination")
                            edits = try JSONSerialization.jsonObject(with: Data(decoded.body.utf8)) as! [String: Any]
                            require(edits["mediaFileId"] as? Int == 42, "Wrong Advanced media ID")
                        }
                    }
                    return text("", status: 204)
                }
                polls += 1
                if polls == 1 { return text("o\n") }
                let frame: String
                if polls == 2 { frame = "CONNECTED\nversion:1.2\n\n\0" }
                else if mode == .advancedError { frame = "ERROR\n\nDenied\0" }
                else { frame = "MESSAGE\nsubscription:primuse-tags\ncontent-type:text/plain\n\nUPDATED\0" }
                return text("a" + String(decoding: try JSONSerialization.data(withJSONObject: [frame]), as: UTF8.self) + "\n")
            }
        }
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class AirsonicTagHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: AirsonicTagHTTPFixture] = [:]
    static func register(_ fixture: AirsonicTagHTTPFixture) { lock.withLock { fixtures[fixture.host] = fixture } }
    static func remove(host: String) { _ = lock.withLock { fixtures.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasPrefix("airsonic-tags-") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else { return }
        do {
            let (status, headers, data) = try fixture.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class ServerPlaylistDescriptionTests: XCTestCase {
    func testLiveNavidromeDescriptionRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_QA_PLAYLIST_SERVER"] == "1" else {
            throw XCTSkip("Requires the isolated local Navidrome QA server")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (credentials, _) = try await session.data(from: URL(string: "http://127.0.0.1:14537/bootstrap")!)
        let account = try JSONDecoder().decode([String: String].self, from: credentials)
        let username = try XCTUnwrap(account["username"])
        let password = try XCTUnwrap(account["password"])
        let sourceID = UUID().uuidString
        let connector = SubsonicSource(sourceID: sourceID, sourceType: .navidrome, host: "127.0.0.1",
            port: 14536, useSsl: false, basePath: nil, username: username, password: password, session: session)
        let source = MusicSource(id: sourceID, name: "Navidrome QA", type: .navidrome, host: "127.0.0.1",
                                 port: 14536, useSsl: false,
                                 connectionConfiguration: SourceConnectionConfiguration(
                                    localEndpoint: SourceConnectionEndpoint(host: "127.0.0.1", port: 14536, useSsl: false),
                                    publicEndpoint: SourceConnectionEndpoint(host: "localhost", port: 14536, useSsl: false)))
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: root)
        let sources = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        sources.add(source)
        func api(_ method: String, _ items: [URLQueryItem]) async throws -> [String: Any] {
            var url = URLComponents(string: "http://127.0.0.1:14536/rest/\(method).view")!
            url.queryItems = [URLQueryItem(name: "u", value: username), URLQueryItem(name: "p", value: password),
                URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "Primuse-QA"),
                URLQueryItem(name: "f", value: "json")] + items
            let data: Data
            do { (data, _) = try await session.data(from: FormSafeQueryURLBuilder.url(from: url)!) }
            catch { throw URLError(.cannotConnectToHost) }
            let response = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["subsonic-response"] as? [String: Any]
            guard let response, response["status"] as? String == "ok" else { throw URLError(.badServerResponse) }
            return response
        }
        let created = try await connector.createServerPlaylist(named: "Primuse 简介 QA " + String(UUID().uuidString.prefix(8)))
        do {
            let id = ServerPlaylistIdentity.playlistID(sourceID: sourceID, serverPlaylistID: created.id)
            _ = try await api("updatePlaylist", [URLQueryItem(name: "playlistId", value: created.id),
                URLQueryItem(name: "comment", value: "服务器修改\n中文 & + =")])
            _ = await ServerPlaylistSyncService.sync(source: source, sourceManager: manager, library: library)
            XCTAssertEqual(library.playlist(id: id)?.descriptionText, "服务器修改\n中文 & + =")
            let playlist = try XCTUnwrap(library.playlist(id: id))
            try await capturePlaylist(playlist, library: library, manager: manager, sources: sources)
            try await PlaylistDescriptionService.save("App 修改\n保留换行 & + =", playlist: playlist,
                library: library, sourcesStore: sources, sourceManager: manager)
            let server = try await api("getPlaylist", [URLQueryItem(name: "id", value: created.id)])
            XCTAssertEqual((server["playlist"] as? [String: Any])?["comment"] as? String, "App 修改\n保留换行 & + =")
            try await PlaylistDescriptionService.save("", playlist: playlist, library: library,
                sourcesStore: sources, sourceManager: manager)
            XCTAssertEqual(library.playlist(id: id)?.descriptionText, "")
            _ = await ServerPlaylistSyncService.sync(source: source, sourceManager: manager, library: library)
            XCTAssertEqual(library.playlist(id: id)?.descriptionText, "")
            _ = try await api("deletePlaylist", [URLQueryItem(name: "id", value: created.id)])
            await connector.disconnect()
        } catch {
            _ = try? await api("deletePlaylist", [URLQueryItem(name: "id", value: created.id)])
            await connector.disconnect()
            throw error
        }
    }

    private func capturePlaylist(_ playlist: Playlist, library: MusicLibrary,
                                 manager: SourceManager, sources: SourcesStore) async throws {
        let services = AppServices.shared
        let player = services.playerService
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { PlaylistDetailView(playlist: playlist) }
                .environment(player).environment(library).environment(manager).environment(sources)
                .environment(services.metadataBackfill).environment(services.scraperService)
                .environment(services.scraperSettingsStore).environment(services.themeService)
                .environment(services.coverTintProvider).environment(services.playbackSettingsStore)
                .environment(services.scanService).environment(services.appleMusic).environment(services.dlnaRenderer)
                .environment(services.audioCacheSync).environment(services.batchRemoval)
                .environment(services.duplicateCleanup).environment(services.serverListeningStats)
                .environment(services.serverCatalogAutoRefresh).environment(services.cloudSync)
                .environment(services.appleMusicLibrary).environment(services.musicIntelligence)
                .environment(services.radioStationsStore).environment(services.updateChecker)
                .environment(player.audioEngine).environment(player.equalizerService)
                .environment(player.audioEffectsService).environment(services.visualizer))
        window.windowLevel = .alert
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .seconds(2))
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "navidrome-playlist-description"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSubsonicFamilyImportsUpdatesAndClearsOnlyComment() async throws {
        for type: MusicSourceType in [.navidrome, .subsonic, .airsonic, .gonic] {
            let fixture = PlaylistDescriptionHTTPFixture()
            let (source, session) = makeSource(fixture, type: type)
            defer { session.invalidateAndCancel() }
            let before = try await source.fetchServerPlaylists()
            XCTAssertEqual(before.playlists.first?.descriptionText, "服务器简介")
            let text = "第一行 & = +\n第二行"
            let updated = try await source.updateServerPlaylistDescription(id: "list.a-42", description: text)
            XCTAssertEqual(updated.descriptionText, text)
            XCTAssertEqual(updated.trackIDs, ["song.a-1", "song.a-2"])
            let cleared = try await source.updateServerPlaylistDescription(id: "list.a-42", description: "")
            XCTAssertEqual(cleared.descriptionText, "")
            let writes = fixture.requests.filter { $0.url?.lastPathComponent == "updatePlaylist.view" }
            XCTAssertEqual(writes.count, 2)
            XCTAssertEqual(fixture.query(writes[0])["comment"], text)
            XCTAssertEqual(fixture.query(writes[1])["comment"], "")
            for request in writes {
                let query = fixture.query(request)
                XCTAssertEqual(query["playlistId"], "list.a-42")
                for key in ["name", "public", "songIdToAdd", "songIndexToRemove"] { XCTAssertNil(query[key]) }
            }
        }
    }

    func testFailedOrUnconfirmedWritesDoNotReportSuccess() async throws {
        for mode in [PlaylistDescriptionHTTPFixture.Mode.rejected, .mismatch, .readOnly, .smart] {
            let fixture = PlaylistDescriptionHTTPFixture(mode: mode)
            let (source, session) = makeSource(fixture)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await source.updateServerPlaylistDescription(id: "list.a-42", description: "Changed")
                XCTFail("Expected failure for \(mode)")
            } catch {}
            if mode == .readOnly || mode == .smart {
                XCTAssertFalse(fixture.requests.contains { $0.url?.lastPathComponent == "updatePlaylist.view" })
            }
        }
    }

    func testEmptyDetailCommentOverridesStaleListComment() async throws {
        let fixture = PlaylistDescriptionHTTPFixture(mode: .emptyDetail)
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        let snapshot = try await source.fetchServerPlaylists()
        XCTAssertEqual(snapshot.playlists.first?.descriptionText, "")
    }

    func testMirrorRefreshClearAndReloadKeepDescriptionSeparateFromMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: root)
        let source = MusicSource(id: UUID().uuidString, name: "Server", type: .navidrome)
        let id = ServerPlaylistIdentity.playlistID(sourceID: source.id, serverPlaylistID: "list")
        func snapshot(_ text: String?) -> ServerPlaylistSnapshot {
            ServerPlaylistSnapshot(playlists: [ServerPlaylist(id: "list", name: "List", trackIDs: ["missing"],
                descriptionText: text)])
        }
        _ = ServerPlaylistMirror.apply(snapshot: snapshot("Remote"), source: source, library: library)
        XCTAssertEqual(library.playlist(id: id)?.descriptionText, "Remote")
        _ = ServerPlaylistMirror.apply(snapshot: snapshot(nil), source: source, library: library)
        XCTAssertEqual(library.playlist(id: id)?.descriptionText, "Remote", "Unsupported snapshots must not clear text")
        let cleared = try XCTUnwrap(snapshot("").playlists.first)
        ServerPlaylistMirror.ProgressiveApplier(source: source, library: library).apply(cleared)
        XCTAssertEqual(library.playlist(id: id)?.descriptionText, "")
        let staleRead = ServerPlaylistMirror.ProgressiveApplier(source: source, library: library)
        ServerPlaylistMirror.applyAppended(snapshot("Changed remotely").playlists[0], source: source, library: library)
        staleRead.apply(snapshot("Old snapshot").playlists[0])
        _ = ServerPlaylistMirror.apply(snapshot: snapshot("Old snapshot"), source: source, library: library,
                                       descriptionReadRevision: staleRead.descriptionReadRevision)
        XCTAssertEqual(library.playlist(id: id)?.descriptionText, "Changed remotely")
        let local = library.createPlaylist(name: "Local", descriptionText: "Created with description")
        XCTAssertTrue(library.updatePlaylistDescription(id: local.id, description: "Local edit"))
        XCTAssertFalse(library.updatePlaylistDescription(id: id, description: "Unconfirmed local edit"))
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persist failed") }
        let reloaded = MusicLibrary(storageDirectory: root)
        XCTAssertEqual(reloaded.playlist(id: id)?.descriptionText, "Changed remotely")
        XCTAssertEqual(reloaded.playlist(id: local.id)?.descriptionText, "Local edit")
    }

    private func makeSource(_ fixture: PlaylistDescriptionHTTPFixture, type: MusicSourceType = .navidrome)
        -> (SubsonicSource, URLSession) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        PlaylistDescriptionHTTPProtocol.register(fixture, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaylistDescriptionHTTPProtocol.self]
        let session = URLSession(configuration: config)
        return (SubsonicSource(sourceID: host, sourceType: type, host: host, port: nil, useSsl: true,
                               basePath: nil, username: "qa", password: "qa", session: session), session)
    }
}

private final class PlaylistDescriptionHTTPFixture: @unchecked Sendable {
    enum Mode { case success, rejected, mismatch, readOnly, smart, emptyDetail }
    let mode: Mode
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var comment = "服务器简介"
    var requests: [URLRequest] { lock.withLock { recorded } }
    init(mode: Mode = .success) { self.mode = mode }
    func query(_ request: URLRequest) -> [String: String] {
        var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        return Dictionary((parts.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, rhs in rhs })
    }
    func response(_ request: URLRequest) -> Data {
        lock.withLock {
            recorded.append(request)
            var body: [String: Any] = ["status": "ok", "version": "1.16.1", "type": "navidrome", "openSubsonic": true]
            var playlist: [String: Any] = ["id": "list.a-42", "name": "List", "comment": comment,
                "owner": mode == .readOnly ? "another-user" : "qa", "readonly": mode == .smart, "songCount": 2,
                "entry": [["id": "song.a-1"], ["id": "song.a-2"]]]
            switch request.url!.lastPathComponent {
            case "ping.view": break
            case "getPlaylists.view": body["playlists"] = ["playlist": [playlist]]
            case "getPlaylist.view":
                if mode == .emptyDetail { playlist["comment"] = "" }
                body["playlist"] = playlist
            case "getStarred2.view": body["starred2"] = [:] as [String: String]
            case "getUser.view": body["user"] = ["adminRole": false]
            case "updatePlaylist.view":
                if mode == .rejected { body = ["status": "failed", "error": ["code": 50, "message": "Denied"]] }
                else if mode != .mismatch { comment = query(request)["comment"] ?? comment }
            default: body = ["status": "failed", "error": ["code": 70, "message": "Unknown method"]]
            }
            return try! JSONSerialization.data(withJSONObject: ["subsonic-response": body])
        }
    }
}

private final class PlaylistDescriptionHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: PlaylistDescriptionHTTPFixture] = [:]
    static func register(_ fixture: PlaylistDescriptionHTTPFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.response(request))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
