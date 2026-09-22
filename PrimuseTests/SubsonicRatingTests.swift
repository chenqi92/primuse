import Foundation
import PrimuseKit
import XCTest
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
    enum Mode { case success, authenticationFailure, mismatchedRating, missingSong, wrongSong, invalidRating }
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
