import CryptoKit
import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class MediaServerSTRMRedirectTests: XCTestCase {
    func testMissingJellyfinLyricsAndEmbyItemsRemainAbsent() async throws {
        for kind in [MediaServerSource.Kind.jellyfin, .emby] {
            let host = uniqueHost("missing-lyrics")
            MediaServerRedirectURLProtocol.configure(host: host) { request in
                if request.url?.path == "/Users/Me" { return .json(#"{"Id":"user"}"#) }
                return .init(status: 404)
            }
            let source = makeSource(host: host, kind: kind)
            let result = await source.readServerLyrics(for: "/items/song.flac")
            guard case .absent = result else {
                XCTFail("Missing lyrics must permit writing and successful deletion verification")
                await source.disconnect()
                continue
            }
            let requests = MediaServerRedirectURLProtocol.requests(host: host)
            XCTAssertEqual(requests.count, 2, "A missing lyric must not probe another route or renew credentials")
            await source.disconnect()
        }
    }

    func testServerSTRMUsesMediaFormatAndKeepsExistingSongIdentity() async throws {
        for kind in [MediaServerSource.Kind.emby, .jellyfin] {
            let host = uniqueHost("catalog")
            MediaServerRedirectURLProtocol.configure(host: host) { request in
                switch request.url?.path {
                case "/Users/Me":
                    return .json(#"{"Id":"user"}"#)
                case "/Users/user/Views":
                    return .json(#"{"Items":[{"Id":"music","Name":"Music","CollectionType":"music"}]}"#)
                case "/Library/VirtualFolders", "/Library/VirtualFolders/Query":
                    return .json("[]")
                case "/Users/user/Items":
                    return .json(#"""
                    {"Items":[
                      {"Id":"wrapper","Name":"Wrapper","Path":"/Music/wrapper.strm","MediaSources":[{"Path":"/Music/wrapper.strm","Container":"flac","Size":1000}]},
                      {"Id":"opaque","Name":"Opaque","Path":"/Music/opaque.strm","MediaSources":[{"Path":"https://cdn.invalid/audio?id=42","Container":"m4a","Size":2000}]},
                      {"Id":"codec","Name":"Codec","Path":"/Music/codec.strm","MediaSources":[{"Container":"strm","Size":132,"MediaStreams":[{"Type":"Audio","Codec":"vorbis"}]}]},
                      {"Id":"signed","Name":"Signed","Path":"/Music/signed.strm","MediaSources":[{"Path":"https://cdn.invalid/song.flac?token=opaque","Container":"flac","Size":3000}]},
                      {"Id":"unknown","Name":"Unknown","Path":"/Music/unknown.strm","MediaSources":[{"Path":"/Music/unknown.strm","Size":88}]},
                      {"Id":"ordinary","Name":"Ordinary","Path":"/Music/ordinary.mp3","MediaSources":[{"Container":"flac","Size":4000}]},
                      {"Id":"mp4","Name":"MP4","Path":"/Music/audio.mp4","MediaSources":[{"Container":"mp4","Size":5000}]}
                    ],"TotalRecordCount":7}
                    """#)
                default:
                    return .init(status: 404)
                }
            }
            let source = makeSource(host: host, kind: kind)
            var songs: [Song] = []
            for try await scanned in try await source.scanSongs(from: "/") {
                songs.append(scanned.song)
            }
            XCTAssertEqual(songs.map(\.fileFormat), [.flac, .m4a, .ogg, .flac, .mp3, .mp3, .m4a])
            XCTAssertFalse(songs.contains(where: \.isStreamDescriptor))
            XCTAssertEqual(songs.map(\.fileSize), [1000, 2000, 0, 3000, 0, 4000, 5000])
            XCTAssertEqual(songs.first?.filePath, "/items/wrapper.flac")
            let previousID = SHA256.hash(data: Data("\(host):/items/wrapper.strm".utf8))
                .prefix(16).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(songs.first?.id, previousID)
            let previousMP4ID = SHA256.hash(data: Data("\(host):/items/mp4.mp4".utf8))
                .prefix(16).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(songs.last?.id, previousMP4ID)
            XCTAssertEqual(songs.last?.filePath, "/items/mp4.m4a")
            await source.disconnect()
        }
    }

    func testCrossEndpointRedirectPreservesInitialAndSeekByteRanges() async throws {
        for kind in [MediaServerSource.Kind.emby, .jellyfin] {
            let host = uniqueHost("range")
            let cdn = uniqueHost("cdn")
            let content = Data("0123456789abcdef".utf8)
            configureOrigin(host, location: "https://\(cdn)/song.flac?signature=cdn-only")
            MediaServerRedirectURLProtocol.configure(host: cdn) { request in
                Self.rangedReply(request, content: content)
            }
            let source = makeSource(host: host, kind: kind)
            let first = try await source.fetchRange(path: "/items/song.flac", offset: 0, length: 4)
            let seek = try await source.fetchRange(path: "/items/song.flac", offset: 8, length: 4)
            XCTAssertEqual(first, Data("0123".utf8))
            XCTAssertEqual(seek, Data("89ab".utf8))
            let requests = MediaServerRedirectURLProtocol.requests(host: cdn)
            XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Range") }, ["bytes=0-3", "bytes=8-11"])
            XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Accept-Encoding") }, ["identity", "identity"])
            for request in requests {
                XCTAssertEqual(request.url?.query, "signature=cdn-only")
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Emby-Token"))
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Emby-Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertFalse(request.httpShouldHandleCookies)
            }
            await source.disconnect()
        }
    }

    func testLegacySTRMCompleteDownloadUsesRealExtensionAndCachesMediaBytes() async throws {
        let host = uniqueHost("download")
        let cdn = uniqueHost("cdn")
        let content = Data("fLaC-media-fixture".utf8)
        MediaServerRedirectURLProtocol.configure(host: host) { request in
            switch request.url?.path {
            case "/Users/Me":
                return .json(#"{"Id":"user"}"#)
            case "/Users/user/Items/song":
                return .json(#"{"Id":"song","Name":"Song","Path":"/Music/song.strm","MediaSources":[{"Container":"flac"}]}"#)
            default:
                return .init(status: 302, headers: ["Location": "https://\(cdn)/audio?signature=download"])
            }
        }
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            .init(headers: ["Content-Type": "audio/flac"], body: content)
        }
        let source = makeSource(host: host)
        let local = try await source.localURL(for: "/items/song.strm")
        defer { try? FileManager.default.removeItem(at: local) }
        XCTAssertEqual(local.pathExtension, "flac")
        XCTAssertEqual(try Data(contentsOf: local), content)
        let cached = try await source.localURL(for: "/items/song.strm")
        XCTAssertEqual(cached, local)
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).count, 1)
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).first?.url?.query, "signature=download")
        await source.disconnect()
    }

    func testDownloadDoesNotCacheRedirectedHTMLAsAudio() async throws {
        let host = uniqueHost("html")
        let cdn = uniqueHost("cdn")
        configureOrigin(host, location: "https://\(cdn)/audio")
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            .init(headers: ["Content-Type": "text/html"], body: Data("<html>Login</html>".utf8))
        }
        let source = makeSource(host: host)
        do {
            _ = try await source.localURL(for: "/items/song.flac")
            XCTFail("An HTML response must not become a cached media file")
        } catch is SourceError {}
        let content = Data("fLaC-media-fixture".utf8)
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            .init(headers: ["Content-Type": "audio/flac"], body: content)
        }
        let local = try await source.localURL(for: "/items/song.flac")
        defer { try? FileManager.default.removeItem(at: local) }
        XCTAssertEqual(try Data(contentsOf: local), content)
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).count, 2)
        await source.disconnect()
    }

    func testExpiredCDNLinkRetriesOnlyOnceWithoutLoggingInAgain() async throws {
        let host = uniqueHost("expired")
        let cdn = uniqueHost("cdn")
        configureOrigin(host, location: "https://\(cdn)/audio?signature=expired")
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in .init(status: 403) }
        let source = makeSource(host: host, authType: .password)
        do {
            _ = try await source.fetchRange(path: "/items/song.flac", offset: 0, length: 4)
            XCTFail("The final HTTP failure must remain observable")
        } catch let error as RemoteMediaHTTPError {
            XCTAssertEqual(error.statusCode, 403)
        }
        let requests = MediaServerRedirectURLProtocol.requests(host: host)
        XCTAssertEqual(requests.filter { $0.url?.path == "/Users/AuthenticateByName" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path == "/Audio/song/stream" }.count, 2)
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).count, 2)
        await source.disconnect()
    }

    func testRateLimitedCDNPreservesRetryAfterWithoutImmediateRetries() async throws {
        let host = uniqueHost("limited")
        let cdn = uniqueHost("cdn")
        configureOrigin(host, location: "https://\(cdn)/audio")
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            .init(status: 429, headers: ["Retry-After": "7"])
        }
        let source = makeSource(host: host)
        do {
            _ = try await source.fetchRange(path: "/items/song.flac", offset: 0, length: 4)
            XCTFail("Expected a structured rate limit response")
        } catch let error as RemoteMediaHTTPError {
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(error.retryAfter, 7)
        }
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).count, 1)
        await source.disconnect()
    }

    func testMediaRedirectLoopHasAFiniteHopLimit() async throws {
        let host = uniqueHost("loop")
        configureOrigin(host, location: "https://\(host)/loop")
        let source = makeSource(host: host)
        do {
            _ = try await source.fetchRange(path: "/items/song.flac", offset: 0, length: 4)
            XCTFail("Expected the media redirect limit")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .httpTooManyRedirects)
        }
        let mediaRequests = MediaServerRedirectURLProtocol.requests(host: host)
            .filter { $0.url?.path != "/Users/Me" }
        XCTAssertEqual(mediaRequests.count, HTTPMediaRedirectRequestPolicy.maximumRedirects + 1)
        await source.disconnect()
    }

    func testAPIRequestDoesNotFollowMediaRedirects() async throws {
        let host = uniqueHost("api")
        let cdn = uniqueHost("cdn")
        MediaServerRedirectURLProtocol.configure(host: host) { _ in
            .init(status: 302, headers: ["Location": "https://\(cdn)/users"])
        }
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            .json(#"{"Id":"unexpected"}"#)
        }
        let source = makeSource(host: host)
        do {
            try await source.connect()
            XCTFail("An authentication API redirect must stay on its source endpoint")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 302)
        }
        XCTAssertTrue(MediaServerRedirectURLProtocol.requests(host: cdn).isEmpty)
        await source.disconnect()
    }

    func testDisconnectStopsOldRedirectRetriesAndExplicitReconnectWorks() async throws {
        let host = uniqueHost("disconnect")
        let cdn = uniqueHost("cdn")
        let reachedCDN = expectation(description: "The original request reached the CDN")
        let responseGate = MediaServerResponseGate()
        defer { responseGate.release() }
        configureOrigin(host, location: "https://\(cdn)/audio")
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            reachedCDN.fulfill()
            return .init(status: 503, responseGate: responseGate)
        }
        let source = makeSource(host: host)
        let pending = Task { try await source.fetchRange(path: "/items/song.flac", offset: 0, length: 4) }
        await fulfillment(of: [reachedCDN], timeout: 2)
        await source.disconnect()
        MediaServerRedirectURLProtocol.configure(host: cdn) { request in
            Self.rangedReply(request, content: Data("01234567".utf8))
        }
        let fresh = try await source.fetchRange(path: "/items/song.flac", offset: 4, length: 4)
        XCTAssertEqual(fresh, Data("4567".utf8))
        do {
            _ = try await pending.value
            XCTFail("The disconnected request must not complete or retry in the new session")
        } catch is CancellationError {
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let sourceRequests = MediaServerRedirectURLProtocol.requests(host: host)
        XCTAssertEqual(sourceRequests.filter { $0.url?.path == "/Audio/song/stream" }.count, 2)
        XCTAssertEqual(sourceRequests.filter { $0.url?.path == "/Users/Me" }.count, 2)
        await source.disconnect()
    }

    /// Jellyfin 对同一用户同一设备号只留最后一次登录。同一个源的播放、写回、诊断等实例共用一次
    /// 登录，设备号每台设备各一个（不再是随 iCloud 同步到所有设备的 `primuse-<源 ID>`）。
    func testConnectorsForOneMediaSourceShareOneLoginOnThisDeviceID() async throws {
        let host = uniqueHost("shared-login")
        let server = SharedLoginServer()
        MediaServerRedirectURLProtocol.configure(host: host) { server.reply(to: $0) }
        let playback = makeSource(host: host, kind: .jellyfin, authType: .password)
        let writeback = makeSource(host: host, kind: .jellyfin, authType: .password)

        _ = try await playback.listFiles(at: "/")
        _ = try await writeback.listFiles(at: "/")
        XCTAssertEqual(server.loginCount, 1)
        XCTAssertEqual(server.rejectedCount, 0)

        let login = try XCTUnwrap(MediaServerRedirectURLProtocol.requests(host: host)
            .first { $0.url?.path == "/Users/AuthenticateByName" })
        let authorization = login.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(authorization.contains("DeviceId=\"\(MediaServerDeviceIdentity.deviceID(sourceID: host))\""))
        XCTAssertFalse(authorization.contains("primuse-\(host)"))
        await writeback.disconnect()
        await playback.disconnect()
    }

    /// 会话在服务端过期后，先发现的一方重新登录一次，另一方被拒后直接改用新的 token。
    func testExpiredSharedMediaSessionIsRenewedOnceForAllConnectors() async throws {
        let host = uniqueHost("renewed-login")
        let server = SharedLoginServer()
        MediaServerRedirectURLProtocol.configure(host: host) { server.reply(to: $0) }
        let playback = makeSource(host: host, kind: .emby, authType: .password)
        let library = makeSource(host: host, kind: .emby, authType: .password)
        _ = try await playback.listFiles(at: "/")
        _ = try await library.listFiles(at: "/")

        server.expireSessions()
        _ = try await playback.listFiles(at: "/")
        _ = try await library.listFiles(at: "/")
        XCTAssertEqual(server.loginCount, 2)
        XCTAssertEqual(server.rejectedCount, 2)
        await library.disconnect()
        await playback.disconnect()
    }

    func testRawPublicHTTPRedirectDropsSourceCredentialsAndKeepsRange() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://media.example:8096/Audio/song/stream?api_key=source")))
        request.setValue("bytes=128-255", forHTTPHeaderField: "Range")
        for header in ["Authorization", "Cookie", "X-Emby-Token", "X-Emby-Authorization", "X-MediaBrowser-Token", "X-Plex-Token"] {
            request.setValue("source-secret", forHTTPHeaderField: header)
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://cdn.example/audio?signature=destination"]
        ))
        let redirected = try XCTUnwrap(MediaServerSource.redirectedMediaRequest(from: request, response: response))
        XCTAssertEqual(redirected.url?.absoluteString, "https://cdn.example/audio?signature=destination")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Range"), "bytes=128-255")
        for header in ["Authorization", "Cookie", "X-Emby-Token", "X-Emby-Authorization", "X-MediaBrowser-Token", "X-Plex-Token"] {
            XCTAssertNil(redirected.value(forHTTPHeaderField: header))
        }
        XCTAssertFalse(redirected.httpShouldHandleCookies)
    }

    private func uniqueHost(_ label: String) -> String {
        "\(label)-\(UUID().uuidString.lowercased()).invalid"
    }

    func testSubsonicRedirectPreservesInitialAndSeekRangesWithoutSourceCredentials() async throws {
        let host = uniqueHost("subsonic")
        let cdn = uniqueHost("cdn")
        let content = Data("0123456789abcdef".utf8)
        configureSubsonicOrigin(host, location: "https://\(cdn)/audio?signature=cdn-only")
        MediaServerRedirectURLProtocol.configure(host: cdn) { request in
            Self.rangedReply(request, content: content)
        }
        let (source, session) = makeSubsonicSource(host: host)
        defer { session.invalidateAndCancel() }
        let first = try await source.fetchRange(path: "/songs/song.strm", offset: 0, length: 4)
        let seek = try await source.fetchRange(path: "/songs/song.strm", offset: 8, length: 4)
        XCTAssertEqual(first, Data("0123".utf8))
        XCTAssertEqual(seek, Data("89ab".utf8))
        let requests = MediaServerRedirectURLProtocol.requests(host: cdn)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Range") }, ["bytes=0-3", "bytes=8-11"])
        for request in requests {
            XCTAssertEqual(request.url?.query, "signature=cdn-only")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
        await source.disconnect()
    }

    func testSubsonicSTRMDownloadsResolvedMediaAndDetectsItsActualFormat() async throws {
        for (prefix, expectedExtension) in [("fLaC", "flac"), ("OggS", "ogg")] {
            let host = uniqueHost("subsonic-download")
            let cdn = uniqueHost("cdn")
            let content = Data((prefix + "-media-fixture").utf8)
            configureSubsonicOrigin(host, location: "https://\(cdn)/opaque?signature=download")
            MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
                .init(headers: ["Content-Type": "application/octet-stream"], body: content)
            }
            let (source, session) = makeSubsonicSource(host: host)
            defer { session.invalidateAndCancel() }
            let local = try await source.localURL(for: "/songs/song.strm")
            defer { try? FileManager.default.removeItem(at: local) }
            XCTAssertEqual(local.pathExtension, expectedExtension)
            XCTAssertEqual(try Data(contentsOf: local), content)
            let cached = try await source.localURL(for: "/songs/song.strm")
            XCTAssertEqual(cached, local)
            XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).count, 1)
            let origin = MediaServerRedirectURLProtocol.requests(host: host)
            XCTAssertEqual(origin.compactMap(\.url?.lastPathComponent), ["ping.view", "stream.view"])
            let streamURL = try XCTUnwrap(origin.last?.url)
            let query = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "format" }?.value, "raw")
            await source.disconnect()
        }
    }

    func testSubsonicOrdinaryDownloadStillUsesDownloadEndpoint() async throws {
        let host = uniqueHost("subsonic-original")
        let cdn = uniqueHost("cdn")
        let content = Data("fLaC-media-fixture".utf8)
        configureSubsonicOrigin(host, location: "https://\(cdn)/song.flac")
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            .init(headers: ["Content-Type": "audio/flac"], body: content)
        }
        let (source, session) = makeSubsonicSource(host: host)
        defer { session.invalidateAndCancel() }
        let local = try await source.localURL(for: "/songs/song.flac")
        defer { try? FileManager.default.removeItem(at: local) }
        XCTAssertEqual(try Data(contentsOf: local), content)
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: host).last?.url?.lastPathComponent, "download.view")
        await source.disconnect()
    }

    func testSubsonicRejectsRedirectedErrorDocumentsAndDoesNotCacheThem() async throws {
        let host = uniqueHost("subsonic-error")
        let cdn = uniqueHost("cdn")
        configureSubsonicOrigin(host, location: "https://\(cdn)/song.flac")
        let (source, session) = makeSubsonicSource(host: host)
        defer { session.invalidateAndCancel() }
        for contentType in ["text/html", "text/xml", "application/octet-stream"] {
            MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
                .init(headers: ["Content-Type": contentType], body: Data("<error>Expired</error>".utf8))
            }
            do {
                _ = try await source.localURL(for: "/songs/song.strm")
                XCTFail("An error document must not become a cached media file")
            } catch is SourceError {}
            do {
                _ = try await source.fetchRange(path: "/songs/song.strm", offset: 0, length: 100)
                XCTFail("An error document must not become a media range")
            } catch is SourceError {}
        }
        let content = Data("fLaC-media-fixture".utf8)
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in .init(body: content) }
        let local = try await source.localURL(for: "/songs/song.strm")
        defer { try? FileManager.default.removeItem(at: local) }
        XCTAssertEqual(try Data(contentsOf: local), content)
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).count, 7)
        await source.disconnect()
    }

    func testSubsonicExpiredRedirectRetriesOnceAndRateLimitPreservesRetryAfter() async throws {
        for status in [403, 429] {
            let host = uniqueHost("subsonic-retry")
            let cdn = uniqueHost("cdn")
            configureSubsonicOrigin(host, location: "https://\(cdn)/song.flac?signature=expired")
            MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
                .init(status: status, headers: status == 429 ? ["Retry-After": "7"] : [:])
            }
            let (source, session) = makeSubsonicSource(host: host)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await source.fetchRange(path: "/songs/song.strm", offset: 0, length: 4)
                XCTFail("The final HTTP failure must remain observable")
            } catch let error as RemoteMediaHTTPError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertEqual(error.retryAfter, status == 429 ? 7 : nil)
            }
            XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).count, status == 429 ? 1 : 2)
            XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: host).filter { $0.url?.lastPathComponent == "ping.view" }.count, 1)
            await source.disconnect()
        }
    }

    func testSubsonicRedirectLoopHasFiniteHopLimit() async throws {
        let host = uniqueHost("subsonic-loop")
        configureSubsonicOrigin(host, location: "https://\(host)/again")
        let (source, session) = makeSubsonicSource(host: host)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await source.fetchRange(path: "/songs/song.strm", offset: 0, length: 4)
            XCTFail("Expected the redirect limit")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .httpTooManyRedirects)
        }
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: host).count, HTTPMediaRedirectRequestPolicy.maximumRedirects + 2)
        await source.disconnect()
    }

    func testSubsonicDisconnectRejectsPendingMediaResponse() async throws {
        let host = uniqueHost("subsonic-disconnect")
        let cdn = uniqueHost("cdn")
        let gate = MediaServerResponseGate()
        let requested = expectation(description: "CDN requested")
        configureSubsonicOrigin(host, location: "https://\(cdn)/song.flac")
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            requested.fulfill()
            return .init(body: Data("fLaC-media-fixture".utf8), responseGate: gate)
        }
        let (source, session) = makeSubsonicSource(host: host)
        defer { session.invalidateAndCancel() }
        let transfer = Task { try await source.localURL(for: "/songs/song.strm") }
        await fulfillment(of: [requested], timeout: 3)
        await source.disconnect()
        gate.release()
        do {
            _ = try await transfer.value
            XCTFail("A disconnected request must not install or return a cache file")
        } catch is CancellationError {}
    }

    private func configureSubsonicOrigin(_ host: String, location: String) {
        MediaServerRedirectURLProtocol.configure(host: host) { request in
            if request.url?.lastPathComponent == "ping.view" {
                return .json(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#)
            }
            return .init(status: 302, headers: ["Location": location])
        }
    }

    func testDirectHTTPPlaybackFollowsRedirectForInitialAndSeekRanges() async throws {
        let host = uniqueHost("direct-http")
        let cdn = uniqueHost("cdn")
        let content = Data("0123456789abcdef".utf8)
        MediaServerRedirectURLProtocol.configure(host: host) { _ in
            .init(status: 302, headers: ["Location": "https://\(cdn)/audio?signature=cdn-only"])
        }
        MediaServerRedirectURLProtocol.configure(host: cdn) { request in
            Self.rangedReply(request, content: content)
        }
        let session = makeDirectMediaSession()
        defer { session.invalidateAndCancel() }
        let fetcher = HTTPRangeFetcher(
            url: try XCTUnwrap(URL(string: "https://\(host)/rest/stream.view?u=user&t=source-token&s=salt")),
            totalLength: Int64(content.count), session: session
        )
        let first = try await fetcher.fetch(offset: 0, length: 4)
        let seek = try await fetcher.fetch(offset: 8, length: 4)
        XCTAssertEqual(first, Data("0123".utf8))
        XCTAssertEqual(seek, Data("89ab".utf8))
        for request in MediaServerRedirectURLProtocol.requests(host: cdn) {
            XCTAssertEqual(request.url?.query, "signature=cdn-only")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
    }

    func testDirectHTTPRedirectPreservesWholeFileAndInvalidRangeValidation() async throws {
        let host = uniqueHost("direct-whole")
        let cdn = uniqueHost("cdn")
        let content = Data("fLaC-media-fixture".utf8)
        MediaServerRedirectURLProtocol.configure(host: host) { _ in
            .init(status: 302, headers: ["Location": "https://\(cdn)/audio"])
        }
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in .init(body: content) }
        let session = makeDirectMediaSession()
        defer { session.invalidateAndCancel() }
        let fetcher = HTTPRangeFetcher(
            url: try XCTUnwrap(URL(string: "https://\(host)/rest/stream.view")),
            totalLength: Int64(content.count), session: session
        )
        let whole = try await fetcher.fetch(offset: 0, length: 4)
        XCTAssertEqual(whole, content)
        do {
            _ = try await fetcher.fetch(offset: 4, length: 4)
            XCTFail("A whole response cannot be installed at a nonzero offset")
        } catch is AudioDecoderError {}
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            .init(status: 206, headers: ["Content-Range": "bytes 8-11/999"], body: Data("89ab".utf8))
        }
        do {
            _ = try await fetcher.fetch(offset: 8, length: 4)
            XCTFail("A redirect cannot bypass the known media length")
        } catch is AudioDecoderError {}
    }

    func testMediaRedirectRejectsDowngradeAndKeepsAPITrafficRestricted() async throws {
        let host = uniqueHost("restricted")
        let cdn = uniqueHost("cdn")
        configureSubsonicOrigin(host, location: "http://\(cdn):8002/song.flac")
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            .init(body: Data("fLaC-media-fixture".utf8))
        }
        let (source, session) = makeSubsonicSource(host: host)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await source.fetchRange(path: "/songs/song.strm", offset: 0, length: 4)
            XCTFail("HTTPS cannot redirect to an unencrypted custom-port endpoint")
        } catch let error as RemoteMediaHTTPError {
            XCTAssertEqual(error.statusCode, 302)
        }
        // API calls continue to use their own transport; media permissions
        // must not turn an arbitrary API redirect into another host's JSON.
        do {
            _ = try await source.fetchServerCatalogScanStatus(changedSince: nil)
            XCTFail("An API redirect must remain rejected")
        } catch {}
        XCTAssertTrue(MediaServerRedirectURLProtocol.requests(host: cdn).isEmpty)
        await source.disconnect()
    }

    func testExternalSTRMMetadataFollowsMultipleRedirectsAndKeepsRange() async throws {
        let host = uniqueHost("external-metadata")
        let relay = uniqueHost("relay")
        let cdn = uniqueHost("cdn")
        let content = Data("0123456789abcdef".utf8)
        configureMediaChain(host: host, relay: relay, cdn: cdn)
        MediaServerRedirectURLProtocol.configure(host: cdn) { request in
            Self.rangedReply(request, content: content)
        }
        let result = try await SourceManager.fetchRemoteMetadataRange(
            url: XCTUnwrap(URL(string: "https://\(host)/song.flac?signature=origin")),
            offset: 8, length: 4, intent: .bulkBounded,
            sessionConfiguration: mediaFixtureConfiguration()
        )
        XCTAssertEqual(result, Data("89ab".utf8))
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).last?.value(forHTTPHeaderField: "Range"), "bytes=8-11")
    }

    func testMediaDownloadPreservesLimitsAfterMultipleRedirects() async throws {
        let host = uniqueHost("bounded-download")
        let relay = uniqueHost("relay")
        let cdn = uniqueHost("cdn")
        let content = Data("fLaC-0123456789abcdef".utf8)
        configureMediaChain(host: host, relay: relay, cdn: cdn)
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in .init(body: content) }
        let configuration = mediaFixtureConfiguration()
        configuration.httpAdditionalHeaders = ["Authorization": "source-secret", "Cookie": "source-cookie"]
        let session = TrustedHTTPTransport.makeMediaSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://\(host)/audio.flac")))
        let (file, response) = try await TrustedHTTPTransport.mediaDownload(
            for: request, session: session, maximumRangedBodyBytes: content.count
        )
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(response.url?.host, cdn)
        XCTAssertNil(MediaServerRedirectURLProtocol.requests(host: cdn).last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(MediaServerRedirectURLProtocol.requests(host: cdn).last?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(try Data(contentsOf: file), content)
        do {
            _ = try await TrustedHTTPTransport.mediaDownload(
                for: request, session: session, maximumRangedBodyBytes: content.count - 1
            )
            XCTFail("A redirect must not remove the complete-file download limit")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
    }

    func testExternalSTRMMetadataKeepsBoundedPrefixAndRejectsUnsupportedSuffix() async throws {
        let host = uniqueHost("metadata-prefix")
        let relay = uniqueHost("relay")
        let cdn = uniqueHost("cdn")
        let content = Data(repeating: 0x61, count: 512 * 1024)
        configureMediaChain(host: host, relay: relay, cdn: cdn)
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in .init(body: content) }
        let url = try XCTUnwrap(URL(string: "https://\(host)/audio.flac"))
        let prefix = try await SourceManager.fetchRemoteMetadataRange(
            url: url, offset: 0, length: 16, intent: .bulkBounded,
            sessionConfiguration: mediaFixtureConfiguration()
        )
        XCTAssertEqual(prefix, content.prefix(16))
        do {
            _ = try await SourceManager.fetchRemoteMetadataRange(
                url: url, offset: -16, length: 16, intent: .bulkBounded,
                sessionConfiguration: mediaFixtureConfiguration()
            )
            XCTFail("Redirects must not make bulk metadata download a whole file for a suffix")
        } catch MetadataRangeReadError.suffixRangeUnsupported {}
    }

    func testTingReaderSTRMMediaRedirectsKeepTokenAtOrigin() async throws {
        let host = uniqueHost("tingreader")
        let relay = uniqueHost("relay")
        let cdn = uniqueHost("cdn")
        let content = Data("fLaC-0123456789abcdef".utf8)
        MediaServerRedirectURLProtocol.configure(host: host) { request in
            switch request.url?.path {
            case "/api/auth/login": return .json(#"{"token":"reader-token"}"#)
            case "/api/libraries": return .json("[]")
            default: return .init(status: 302, headers: ["Location": "https://\(relay)/audio"])
            }
        }
        MediaServerRedirectURLProtocol.configure(host: relay) { _ in
            .init(status: 307, headers: ["Location": "https://\(cdn)/audio?signature=cdn-only"])
        }
        MediaServerRedirectURLProtocol.configure(host: cdn) { request in
            request.value(forHTTPHeaderField: "Range") == nil
                ? .init(body: content) : Self.rangedReply(request, content: content)
        }
        let source = TingReaderSource(
            sourceID: host, host: host, port: nil, useSSL: true, basePath: nil,
            username: "reader", password: "secret", sessionConfiguration: mediaFixtureConfiguration()
        )
        let path = "/tingreader/books/book/chapters/chapter.bin"
        let bytes = try await source.fetchRange(path: path, offset: 8, length: 4)
        XCTAssertEqual(bytes, content.subdata(in: 8..<12))
        let file = try await source.localURL(for: path)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), content)
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: host).last?.value(forHTTPHeaderField: "Authorization"), "Bearer reader-token")
        for destination in [relay, cdn] {
            for request in MediaServerRedirectURLProtocol.requests(host: destination) {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            }
        }
        let mediaRequests = MediaServerRedirectURLProtocol.requests(host: cdn).count
        MediaServerRedirectURLProtocol.configure(host: host) { _ in
            .init(status: 302, headers: ["Location": "https://\(relay)/catalogue"])
        }
        do {
            _ = try await source.listFiles(at: "/")
            XCTFail("The catalogue API must not follow a media redirect")
        } catch TingReaderServiceError.badServerResponse(302) {}
        XCTAssertEqual(MediaServerRedirectURLProtocol.requests(host: cdn).count, mediaRequests)
        await source.disconnect()
    }

    func testOpenListSTRMDownloadAndMetadataFollowMultipleRedirects() async throws {
        let host = uniqueHost("openlist")
        let relay = uniqueHost("relay")
        let cdn = uniqueHost("cdn")
        let content = Data("fLaC-0123456789abcdef".utf8)
        configureMediaChain(host: host, relay: relay, cdn: cdn)
        MediaServerRedirectURLProtocol.configure(host: cdn) { request in
            request.value(forHTTPHeaderField: "Range") == nil
                ? .init(body: content) : Self.rangedReply(request, content: content)
        }
        let source = WebDAVSource(
            sourceID: host, host: host, port: nil, useSsl: true, basePath: "/dav",
            username: "reader", password: "secret", sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MediaServerRedirectURLProtocol.self]
                return configuration
            }
        )
        let bytes = try await source.fetchOpenListSTRMMetadataRange(for: "/d/song.flac", offset: 8, length: 4)
        XCTAssertEqual(bytes, content.subdata(in: 8..<12))
        let file = try await source.downloadBoundedOpenListSTRM(for: "/d/song.flac", maximumBytes: Int64(content.count))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), content)
        do {
            _ = try await source.downloadBoundedOpenListSTRM(for: "/d/song.flac", maximumBytes: 8)
            XCTFail("The OpenList redirect must retain the offline storage cap")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
        XCTAssertNotNil(MediaServerRedirectURLProtocol.requests(host: host).last?.value(forHTTPHeaderField: "Authorization"))
        for destination in [relay, cdn] {
            XCTAssertTrue(MediaServerRedirectURLProtocol.requests(host: destination).allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil
            })
        }
        await source.disconnect()
    }

    func testOpenListDisconnectDiscardsPendingRedirectedDownload() async throws {
        let host = uniqueHost("openlist-disconnect")
        let relay = uniqueHost("relay")
        let cdn = uniqueHost("cdn")
        let gate = MediaServerResponseGate()
        let requested = expectation(description: "OpenList CDN requested")
        configureMediaChain(host: host, relay: relay, cdn: cdn)
        MediaServerRedirectURLProtocol.configure(host: cdn) { _ in
            requested.fulfill()
            return .init(body: Data("fLaC-media-fixture".utf8), responseGate: gate)
        }
        let source = WebDAVSource(
            sourceID: host, host: host, port: nil, useSsl: true, basePath: "/dav",
            username: "reader", password: "secret", sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MediaServerRedirectURLProtocol.self]
                return configuration
            }
        )
        let transfer = Task { try await source.localOpenListSTRMURL(for: "/d/song.flac") }
        await fulfillment(of: [requested], timeout: 3)
        await source.disconnect()
        gate.release()
        do {
            _ = try await transfer.value
            XCTFail("Disconnect must prevent installing or returning a late media file")
        } catch is CancellationError {}
    }

    private func configureMediaChain(host: String, relay: String, cdn: String) {
        MediaServerRedirectURLProtocol.configure(host: host) { _ in
            .init(status: 302, headers: ["Location": "https://\(relay)/audio"])
        }
        MediaServerRedirectURLProtocol.configure(host: relay) { _ in
            .init(status: 307, headers: ["Location": "https://\(cdn)/audio?signature=cdn-only"])
        }
    }

    private func mediaFixtureConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaServerRedirectURLProtocol.self]
        return configuration
    }

    private func makeDirectMediaSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaServerRedirectURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: MediaHTTPRedirectSessionDelegate(trust: SmartSSLDelegate()),
            delegateQueue: nil
        )
    }

    private func makeSubsonicSource(host: String) -> (SubsonicSource, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaServerRedirectURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "source-secret", "Cookie": "source-session"]
        let session = URLSession(configuration: configuration)
        return (SubsonicSource(
            sourceID: host, sourceType: .subsonic, host: host, port: nil,
            useSsl: true, basePath: nil, username: "user", password: "source-secret", session: session
        ), session)
    }

    private func makeSource(
        host: String,
        kind: MediaServerSource.Kind = .emby,
        authType: SourceAuthType = .apiKey
    ) -> MediaServerSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaServerRedirectURLProtocol.self]
        return MediaServerSource(
            sourceID: host, kind: kind, host: host, port: nil, useSsl: true,
            basePath: nil, username: "user", secret: "source-token", authType: authType,
            sessionConfiguration: configuration
        )
    }

    private func configureOrigin(_ host: String, location: String) {
        MediaServerRedirectURLProtocol.configure(host: host) { request in
            switch request.url?.path {
            case "/Users/Me":
                return .json(#"{"Id":"user"}"#)
            case "/Users/AuthenticateByName":
                return .json(#"{"AccessToken":"source-token","User":{"Id":"user"}}"#)
            default:
                return .init(status: 302, headers: ["Location": location])
            }
        }
    }

    private static func rangedReply(_ request: URLRequest, content: Data) -> MediaServerRedirectURLProtocol.Reply {
        let range = request.value(forHTTPHeaderField: "Range")?
            .replacingOccurrences(of: "bytes=", with: "").split(separator: "-") ?? []
        guard range.count == 2, let lower = Int(range[0]), let upper = Int(range[1]),
              lower >= 0, upper >= lower, upper < content.count else {
            return .init(status: 416)
        }
        return .init(
            status: 206,
            headers: ["Content-Type": "audio/flac", "Content-Range": "bytes \(lower)-\(upper)/\(content.count)"],
            body: content.subdata(in: lower..<(upper + 1))
        )
    }
}

/// 只认最后一次登录发出的 token，和 Jellyfin 同一设备号的规则一样。
private final class SharedLoginServer: @unchecked Sendable {
    private let lock = NSLock()
    private var logins = 0
    private var rejected = 0
    private var validToken: String?

    var loginCount: Int { lock.withLock { logins } }
    var rejectedCount: Int { lock.withLock { rejected } }
    func expireSessions() { lock.withLock { validToken = nil } }

    func reply(to request: URLRequest) -> MediaServerRedirectURLProtocol.Reply {
        lock.withLock {
            switch request.url?.path {
            case "/Users/AuthenticateByName":
                logins += 1
                validToken = "token-\(logins)"
                return .json(#"{"AccessToken":"token-\#(logins)","User":{"Id":"user"}}"#)
            case "/Users/user/Views":
                guard let token = request.value(forHTTPHeaderField: "X-Emby-Token"), token == validToken else {
                    rejected += 1
                    return .init(status: 401)
                }
                return .json(#"{"Items":[]}"#)
            default:
                return .init(status: 404)
            }
        }
    }
}

private final class MediaServerRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var responseGate: MediaServerResponseGate?

        static func json(_ json: String) -> Reply {
            Reply(headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> Reply] = [:]
    nonisolated(unsafe) private static var captured: [String: [URLRequest]] = [:]
    private let stateLock = NSLock()
    private var stopped = false

    static func configure(host: String, handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.withLock { handlers[host] = handler }
    }

    static func requests(host: String) -> [URLRequest] {
        lock.withLock { captured[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let handler = Self.lock.withLock {
            Self.captured[host, default: []].append(request)
            return Self.handlers[host]
        }
        let reply = handler?(request) ?? Reply(status: 404)
        let deliver: @Sendable () -> Void = { [self] in
            guard stateLock.withLock({ !stopped }) else { return }
            var headers = reply.headers
            headers["Content-Length"] = String(reply.body.count)
            guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if let gate = reply.responseGate {
            gate.hold(deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }
}

private final class MediaServerResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiting: (@Sendable () -> Void)?

    func hold(_ response: @escaping @Sendable () -> Void) {
        let shouldDeliver = lock.withLock {
            if released { return true }
            waiting = response
            return false
        }
        if shouldDeliver { response() }
    }

    func release() {
        let response = lock.withLock {
            released = true
            let response = waiting
            waiting = nil
            return response
        }
        response?()
    }
}
