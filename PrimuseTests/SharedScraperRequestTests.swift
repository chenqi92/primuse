import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class SharedScraperRequestTests: XCTestCase {
    func testCustomInstancesAndResourcesShareCooldown() async {
        let fixture = ScraperHTTPFixture { _ in .init(status: 429, headers: ["Retry-After": "3600"]) }
        defer { fixture.close() }
        let config = fixture.config()
        for _ in 0..<2 {
            let scraper = ConfigurableScraper(config: config, session: fixture.session)
            await assertRateLimited {
                _ = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
            }
        }
        await assertRateLimited {
            _ = try await ConfigurableScraper.downloadResource(
                from: fixture.url("cover"),
                sourceConfig: .init(id: "another-row", type: .custom(config.id), isEnabled: true, priority: 0),
                session: fixture.session
            )
        }
        XCTAssertEqual(fixture.requests.count, 1, "Recreating a scraper or downloading artwork must respect the same quota")
    }

    func testEncryptedLyricsStopsAtRateLimit() async {
        let fixture = encryptedFixture(status: 429, headers: ["Retry-After": "3600"])
        defer { fixture.close() }
        let scraper = ConfigurableScraper(config: fixture.encryptedConfig(), session: fixture.session)
        await assertRateLimited { _ = try await scraper.getLyrics(externalId: "song") }
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/lyrics", "/encrypted/one"])
    }

    func testEncryptedLyricsPreservesServerFailureAndCancellation() async {
        for cancelled in [false, true] {
            let fixture = encryptedFixture(status: 500, error: cancelled ? URLError(.cancelled) : nil)
            defer { fixture.close() }
            let scraper = ConfigurableScraper(config: fixture.encryptedConfig(), session: fixture.session)
            do {
                _ = try await scraper.getLyrics(externalId: "song")
                XCTFail("Secondary failures must not become missing lyrics")
            } catch let error as URLError where cancelled {
                XCTAssertEqual(error.code, .cancelled)
            } catch ScraperError.networkError(let message) where !cancelled {
                XCTAssertTrue(message.contains("500"))
            } catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertEqual(fixture.requests.count, 2, "Stop before requesting another candidate")
        }
    }

    func testLyricsServersKeepIndependentCooldownAcrossInstancesAndMisses() async {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/a"
                ? .init(status: 429, headers: ["Retry-After": "3600"])
                : .init(status: 404)
        }
        defer { fixture.close() }
        let servers = [LyricsAPIServer(address: fixture.url("a")), LyricsAPIServer(address: fixture.url("b"))]
        for _ in 0..<2 {
            let scraper = LyricsAPIServerScraper(servers: servers, session: fixture.session)
            await assertRateLimited {
                _ = try await scraper.fetchLyrics(title: "Song", artist: nil, album: nil, duration: nil)
            }
        }
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/a", "/b", "/b"],
                       "A's cooldown must survive B's miss without blocking B")
    }

    func testManagerObservesManualLRCLIBCooldownUntilServerDeadline() async throws {
        let clock = ScraperTestClock()
        let fixture = ScraperHTTPFixture { _ in .init(status: 429, headers: ["Retry-After": "3600"]) }
        defer { fixture.close() }
        let scraper = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor(timing: clock.timing))
        await assertRateLimited { _ = try await scraper.fetchLyrics(title: "Song", artist: "Artist") }
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        for time in [0.0, 301, 3599] {
            clock.advance(to: time)
            let result = await scrape(manager, type: .lrclib)
            XCTAssertTrue(result.errors.isEmpty, "Skip the shared cooldown, including beyond the old 300s cap")
        }
        XCTAssertEqual(fixture.requests.count, 1)
        clock.advance(to: 3600)
        let resumed = await scrape(manager, type: .lrclib)
        XCTAssertEqual(resumed.errors.count, 1)
        XCTAssertEqual(fixture.requests.count, 2, "Resume only once the server deadline expires")
    }

    func testManagerContinuesHealthyLyricsEndpointWhileAnotherIsCooling() async {
        let phase = ScraperTestClock()
        let fixture = ScraperHTTPFixture { request in
            if request.url?.path == "/a" { return .init(status: 429, headers: ["Retry-After": "3600"]) }
            return phase.now == 0 ? .init(status: 404) : .init(body: Data("[00:01.00]Fixture lyrics".utf8))
        }
        defer { fixture.close() }
        let scraper = LyricsAPIServerScraper(servers: [
            .init(address: fixture.url("a")), .init(address: fixture.url("b"))
        ], session: fixture.session)
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let first = await scrape(manager, type: .lyricsServer)
        XCTAssertEqual(first.errors.count, 1, "A 404 on B must not erase A's error")
        phase.advance(to: 1)
        let next = await scrape(manager, type: .lyricsServer)
        XCTAssertFalse(next.lyrics?.isEmpty ?? true, "B remains available during A's cooldown")
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/a", "/b", "/b"])
    }

    func testEncryptedLyricsFallsBackOnlyForMissingCandidates() async throws {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/lyrics":
                return .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":[{"id":"one"},{"id":"two"}]}"#.utf8))
            case "/encrypted/one": return .init(status: 404)
            default:
                // Synthetic zlib text, XOR key 01, magic 00; no provider secrets.
                return .init(body: Data(#"{"content":"AHmdijc1MTHRABCwNxFbxsHPIjQmJh4BTWkHTw=="}"#.utf8))
            }
        }
        defer { fixture.close() }
        let scraper = ConfigurableScraper(config: fixture.encryptedConfig(), session: fixture.session)
        let result = try await scraper.getLyrics(externalId: "song")
        XCTAssertTrue(result?.lrcContent?.contains("Hello") == true)
        XCTAssertTrue(result?.lrcContent?.contains("[00:01.00]") == true)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/lyrics", "/encrypted/one", "/encrypted/two"])
    }

    /// 已经解出一份时, 后面的候选出错不把整首歌词丢掉。
    func testEncryptedLyricsKeepsDecodedCandidateWhenALaterOneFails() async throws {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/lyrics":
                return .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":[{"id":"one"},{"id":"two"}]}"#.utf8))
            case "/encrypted/two": return .init(status: 500)
            default:
                return .init(body: Data(#"{"content":"AHmdijc1MTHRABCwNxFbxsHPIjQmJh4BTWkHTw=="}"#.utf8))
            }
        }
        defer { fixture.close() }
        let scraper = ConfigurableScraper(config: fixture.encryptedConfig(), session: fixture.session)
        let result = try await scraper.getLyrics(externalId: "song")
        XCTAssertTrue(result?.lrcContent?.contains("Hello") == true)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/lyrics", "/encrypted/one", "/encrypted/two"])
    }

    /// 一台歌词服务器明确说没有时, 另一台宕机不算这个源失败, 免得连着几首把能用的那台一起熔断。
    func testLyricsServerMissOutweighsAnotherServersOutage() async throws {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/a" ? .init(status: 500) : .init(status: 404)
        }
        defer { fixture.close() }
        let scraper = LyricsAPIServerScraper(servers: [
            .init(address: fixture.url("a")), .init(address: fixture.url("b"))
        ], session: fixture.session)
        let result = try await scraper.fetchLyrics(title: "Song", artist: nil, album: nil, duration: nil)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/a", "/b"])
    }

    func testCustomEndpointParsingHeadersAndHTTPUpgradeArePreserved() async throws {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/search": return .init(body: Data(#"[{"id":"one","title":"Song","artist":"Artist"}]"#.utf8))
            case "/detail": return .init(body: Data(#"{"title":"Song","album":"Album"}"#.utf8))
            case "/cover": return .init(body: Data(#"[{"coverUrl":"https://images.test/cover"}]"#.utf8))
            default: return .init(body: Data(#"{"lrcContent":"[00:01.00]Hello"}"#.utf8))
            }
        }
        defer { fixture.close() }
        var config = fixture.config()
        config.headers = ["X-Global": "global", "X-Override": "global"]
        config.cookie = "session=fixture"
        config.search = .init(url: fixture.url("search").replacingOccurrences(of: "https:", with: "http:"),
                              method: "GET", headers: ["X-Override": "endpoint"], script: "return response;")
        config.detail = .init(url: fixture.url("detail"), method: "GET", script: "return response;")
        config.cover = .init(url: fixture.url("cover"), method: "GET", script: "return response;")
        config.lyrics = .init(url: fixture.url("lyrics"), method: "GET", script: "return response;")
        let scraper = ConfigurableScraper(config: config, session: fixture.session)
        let search = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
        let detail = try await scraper.getDetail(externalId: "one")
        let covers = try await scraper.getCoverArt(externalId: "one")
        let lyrics = try await scraper.getLyrics(externalId: "one")
        XCTAssertEqual(search.items.first?.title, "Song")
        XCTAssertEqual(detail?.album, "Album")
        XCTAssertEqual(covers.first?.coverUrl, "https://images.test/cover")
        XCTAssertEqual(lyrics?.lrcContent, "[00:01.00]Hello")
        XCTAssertEqual(fixture.requests.first?.url?.scheme, "https")
        XCTAssertEqual(fixture.requests.first?.value(forHTTPHeaderField: "X-Override"), "endpoint")
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "session=fixture" })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Global") == "global" })
    }

    func testCustomPOSTIsNotReplayedAfterAnUncertainTransportOutcome() async {
        let fixture = ScraperHTTPFixture { _ in .init(error: URLError(.networkConnectionLost)) }
        defer { fixture.close() }
        var config = fixture.config()
        config.search = .init(url: fixture.url("search"), method: "POST",
                              bodyTemplate: #"{"query":"{{query}}"}"#, script: "return response;")
        let scraper = ConfigurableScraper(config: config, session: fixture.session)
        do {
            _ = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
            XCTFail("Expected transport failure")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
        catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.httpMethod, "POST")
    }

    func testResponseSizeLimitsRemainAtTheAdapterBoundary() async throws {
        let fixture = ScraperHTTPFixture { request in
            let limit = request.url?.path == "/cover"
                ? ConfigurableScraper.maxResourceResponseBytes : ConfigurableScraper.maxEndpointResponseBytes
            return .init(body: Data(repeating: 32, count: limit + 1))
        }
        defer { fixture.close() }
        let scraper = ConfigurableScraper(config: fixture.config(), session: fixture.session)
        do {
            _ = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
            XCTFail("Oversized JSON must not enter the script")
        } catch ScraperError.networkError(let message) { XCTAssertTrue(message.contains("too large")) }
        catch { XCTFail("Unexpected failure: \(error)") }
        let resource = try await ConfigurableScraper.downloadResource(from: fixture.url("cover"), session: fixture.session)
        XCTAssertNil(resource)
    }

    func testResourcesReturnBytesWithoutInvalidatingBorrowedSession() async throws {
        let bytes = Data([1, 2, 3, 4])
        let fixture = ScraperHTTPFixture { _ in .init(body: bytes) }
        defer { fixture.close() }
        for path in ["first", "second"] {
            let data = try await ConfigurableScraper.downloadResource(from: fixture.url(path), session: fixture.session)
            XCTAssertEqual(data, bytes)
        }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testResourceMissServerFailureAndCancellationStayDistinct() async throws {
        for status in [403, 404, 500, 503] {
            let fixture = ScraperHTTPFixture { _ in .init(status: status) }
            defer { fixture.close() }
            do {
                let data = try await ConfigurableScraper.downloadResource(from: fixture.url("cover"), session: fixture.session)
                XCTAssertNil(data)
                XCTAssertLessThan(status, 500)
            } catch ScraperError.networkError(let message) where status == 500 {
                XCTAssertTrue(message.contains("500"))
            } catch ScraperError.rateLimited where status == 503 {
            } catch { XCTFail("Unexpected failure for \(status): \(error)") }
            XCTAssertEqual(fixture.requests.count, 1)
        }
        let fixture = ScraperHTTPFixture { _ in .init(error: URLError(.cancelled)) }
        defer { fixture.close() }
        do {
            _ = try await ConfigurableScraper.downloadResource(from: fixture.url("cover"), session: fixture.session)
            XCTFail("Cancellation must reach caller")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
    }

    func testSettingsProbeAndEquivalentEndpointShareHTTPDateCooldown() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = formatter.string(from: Date().addingTimeInterval(3600))
        let fixture = ScraperHTTPFixture { _ in .init(status: 503, headers: ["Retry-After": date]) }
        defer { fixture.close() }
        let server = LyricsAPIServer(address: fixture.url("api"), authorization: "Bearer draft")
        let probe = await LyricsAPIServerScraper.probe(server: server, title: "Song", artist: nil, album: nil,
                                                     duration: nil, session: fixture.session)
        guard case .failed = probe else { return XCTFail("Expected probe failure") }
        var alias = server
        alias.id = UUID().uuidString
        alias.address = "HTTPS://" + fixture.id.uppercased() + ".TEST:443/api#ignored"
        let scraper = LyricsAPIServerScraper(servers: [alias], session: fixture.session)
        let deadline = formatter.date(from: date)!
        let earliest = Date()
        do {
            _ = try await scraper.getLyrics(externalId: "Song|Artist")
            XCTFail("Expected the probe's shared cooldown")
        } catch ScraperError.rateLimited(let delay) {
            let latest = Date()
            XCTAssertGreaterThanOrEqual(delay ?? 0, Int(ceil(deadline.timeIntervalSince(latest))))
            XCTAssertLessThanOrEqual(delay ?? Int.max, Int(ceil(deadline.timeIntervalSince(earliest))))
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1, "New settings rows and equivalent URLs share the endpoint quota")
        XCTAssertEqual(fixture.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer draft")
    }

    func testMissingLyricsAPIStillFallsBackToNextProvider() async throws {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/api/get"
                ? .init(body: Data(#"{"syncedLyrics":"[00:01.00]Hello"}"#.utf8))
                : .init(status: 404)
        }
        defer { fixture.close() }
        let server = LyricsAPIServerScraper(servers: [.init(address: fixture.url("api"))], session: fixture.session)
        let lrclib = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { config in
            if config.type == .lyricsServer { return server }
            return lrclib
        })
        let result = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true), settings: .init(sources: [
                .init(id: "first", type: .lyricsServer, isEnabled: true, priority: 0),
                .init(id: "second", type: .lrclib, isEnabled: true, priority: 1)
            ]))
        XCTAssertFalse(result.lyrics?.isEmpty ?? true)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/api", "/api/get"])
    }

    func testManualSearchListsLyricsAPIResultForTheSongIdentity() async {
        let fixture = ScraperHTTPFixture { request in
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            let title = items.first { $0.name == "title" }?.value
            let artist = items.first { $0.name == "artist" }?.value
            return title == "小海" && artist == "Singer"
                ? .init(body: Data("[00:01.00]第一句\n[00:05.00]第二句".utf8))
                : .init(status: 404)
        }
        defer { fixture.close() }
        let server = LyricsAPIServerScraper(servers: [.init(address: fixture.url("api"))], session: fixture.session)
        let manager = ScraperManager(scraperFactory: { _ in server })
        let settings = ScraperSettings(sources: [
            .init(id: "itunes", type: .itunes, isEnabled: true, priority: 0),
            .init(id: "lyrics", type: .lyricsServer, isEnabled: true, priority: 1)
        ])

        let lookup = ScraperManager.lyricsServerLookupIdentity(query: "小海 Singer", title: "小海", artist: "Singer")
        let found = await manager.lyricsServerCandidate(
            title: lookup.title, artist: lookup.artist, album: nil, duration: 200, settings: settings
        )
        XCTAssertEqual(found?.config.id, "lyrics")
        XCTAssertEqual(found?.lyrics.map(\.text), ["第一句", "第二句"])

        let miss = await manager.lyricsServerCandidate(
            title: "别的歌", artist: "Singer", album: nil, duration: 200, settings: settings
        )
        XCTAssertNil(miss)

        let disabled = await manager.lyricsServerCandidate(
            title: "小海", artist: "Singer", album: nil, duration: 200,
            settings: ScraperSettings(sources: [.init(id: "lyrics", type: .lyricsServer, isEnabled: false, priority: 0)])
        )
        XCTAssertNil(disabled)
        XCTAssertEqual(fixture.requests.count, 2, "A disabled lyrics API is never asked")
    }

    func testLyricsAPILookupSplitsTheSearchBoxIntoTitleAndArtist() {
        func lookup(_ query: String, title: String = "小海", artist: String? = "Singer") -> [String?] {
            let identity = ScraperManager.lyricsServerLookupIdentity(query: query, title: title, artist: artist)
            return [identity.title, identity.artist]
        }
        XCTAssertEqual(lookup("小海 Singer"), ["小海", "Singer"], "The suggested query is title + artist")
        XCTAssertEqual(lookup("小海"), ["小海", "Singer"], "A title-only query keeps the song's artist")
        XCTAssertEqual(lookup("小海 (Live) singer"), ["小海", "Singer"], "Artist suffix is matched case-insensitively")
        XCTAssertEqual(lookup("别的歌 Singer"), ["别的歌", "Singer"])
        XCTAssertEqual(lookup("Other Artist - 别的歌"), ["别的歌", "Other Artist"])
        XCTAssertEqual(lookup("完全不同", artist: nil), ["完全不同", nil])
    }

    func testLyricsAPICancellationDoesNotTryNextEndpoint() async {
        let fixture = ScraperHTTPFixture { _ in .init(error: URLError(.cancelled)) }
        defer { fixture.close() }
        let scraper = LyricsAPIServerScraper(servers: [
            .init(address: fixture.url("a")), .init(address: fixture.url("b"))
        ], session: fixture.session)
        do {
            _ = try await scraper.getLyrics(externalId: "Song|Artist")
            XCTFail("Expected cancellation")
        } catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testDirectMusicBrainzCoverFetchPreservesHTTPFailure() async {
        let fixture = ScraperHTTPFixture { _ in .init(status: 500) }
        defer { fixture.close() }
        let scraper = MusicBrainzScraper(session: fixture.session, requestExecutor: RequestExecutor())
        do {
            _ = try await scraper.fetchCoverData(releaseID: "fixture-release")
            XCTFail("A cover service outage is not a missing image")
        } catch ScraperError.networkError(let message) { XCTAssertTrue(message.contains("500")) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testAMLLFallsBackToTitleSearchAndReturnsWordLevelLyrics() async {
        let fixture = ScraperHTTPFixture { request in
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let items = components?.queryItems ?? []
            switch components?.path {
            case "/v1/lyrics/search" where items.contains(where: { $0.name == "artistName" }):
                return .init(body: SharedScraperRequestTests.amllSearchBody([]))
            case "/v1/lyrics/search":
                return .init(body: SharedScraperRequestTests.amllSearchBody([(7, "晴天", "周杰伦")]))
            case "/v1/lyrics/get" where items.first(where: { $0.name == "id" })?.value == "7":
                return .init(body: SharedScraperRequestTests.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
            default:
                return .init(status: 404)
            }
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in amll })
        // 曲库里写的是繁体歌手名：接口按歌手搜不到，只按歌名搜出来后本地认出是同一位。
        let result = await manager.scrapeMetadata(title: "晴天", artist: "周杰倫", album: nil, duration: 269,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
        XCTAssertEqual(result.lyrics?.count, 2)
        XCTAssertTrue(result.lyrics?.allSatisfy(\.isWordLevel) ?? false)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/v1/lyrics/search", "/v1/lyrics/search", "/v1/lyrics/get"])
    }

    func testAMLLLyricsLongerThanTheSongFallThroughToLRCLIB() async {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/v1/lyrics/search":
                return .init(body: SharedScraperRequestTests.amllSearchBody([(7, "Song", "Artist")]))
            case "/v1/lyrics/get":
                return .init(body: SharedScraperRequestTests.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
            case "/api/get":
                return .init(body: Data(#"{"syncedLyrics":"[00:01.00]Hello"}"#.utf8))
            default:
                return .init(status: 404)
            }
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let lrclib = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { config in
            if config.type == .amll { return amll }
            return lrclib
        })
        let result = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: 150,
            needs: .init(metadata: false, cover: false, lyrics: true), settings: .init(sources: [
                .init(id: "amll", type: .amll, isEnabled: true, priority: 0),
                .init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 1)
            ]))
        XCTAssertEqual(result.lyrics?.map(\.text), ["Hello"])
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/v1/lyrics/search", "/v1/lyrics/get", "/api/get"])
    }

    func testExistingSettingsGainAMLLRightBeforeLRCLIB() throws {
        let suite = "amll-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = ScraperSettings(sources: [
            .init(id: "itunes", type: .itunes, isEnabled: true, priority: 0),
            .init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 1),
            .init(id: "musicbrainz", type: .musicBrainz, isEnabled: false, priority: 2),
            .init(id: "server", type: .lyricsServer, isEnabled: false, priority: 3)
        ])
        saved.save(defaults: defaults)

        let loaded = ScraperSettings.load(defaults: defaults)
        let builtIns = loaded.sources.filter(\.type.isBuiltIn).map(\.type)
        XCTAssertEqual(builtIns, [.itunes, .amll, .lrclib, .musicBrainz, .lyricsServer])
        XCTAssertEqual(loaded.sources.first { $0.type == .amll }?.isEnabled, false)
        XCTAssertEqual(loaded.sources.map(\.priority), Array(loaded.sources.indices))
    }

    private static func amllSearchBody(_ songs: [(id: Int, title: String, artist: String)]) -> Data {
        let items: [[String: Any]] = songs.map {
            ["id": $0.id, "musicNames": [$0.title], "artistNames": [$0.artist], "albumNames": []]
        }
        let body: [String: Any] = ["status": 200, "data": ["items": items, "pagination": [
            "page": 1, "pageSize": 50, "total": items.count, "totalPages": items.isEmpty ? 0 : 1, "hasMore": false
        ]]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static func amllLyricsBody(id: Int, lastLineEnd: String) -> Data {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>\
        <p begin="00:10.000" end="00:12.000" ttm:agent="v1"><span begin="00:10.000" end="00:11.000">故</span>\
        <span begin="00:11.000" end="00:12.000">事</span></p>\
        <p begin="03:10.000" end="\(lastLineEnd)" ttm:agent="v1"><span begin="03:10.000" end="03:15.000">的</span>\
        <span begin="03:15.000" end="\(lastLineEnd)">花</span></p></div></body></tt>
        """
        let body: [String: Any] = ["status": 200, "data": [
            "id": id, "musicNames": ["x"], "artistNames": ["y"], "albumNames": [], "lyrics": ttml, "format": "ttml"
        ]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func scrape(_ manager: ScraperManager, type: MusicScraperType) async -> ScrapeResult {
        await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "row", type: type, isEnabled: true, priority: 0)]))
    }

    private func encryptedFixture(
        status: Int, headers: [String: String] = [:], error: URLError? = nil
    ) -> ScraperHTTPFixture {
        ScraperHTTPFixture { request in
            if request.url?.path == "/lyrics" {
                return .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":[{"id":"one"},{"id":"two"}]}"#.utf8))
            }
            return .init(status: status, headers: headers, error: error)
        }
    }

    private func assertRateLimited(
        file: StaticString = #filePath, line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected server cooldown", file: file, line: line)
        } catch ScraperError.rateLimited(let delay) {
            XCTAssertGreaterThanOrEqual(delay ?? 0, 3599, file: file, line: line)
        } catch {
            XCTFail("Expected rate limit, got \(error)", file: file, line: line)
        }
    }
}

/// Only the HTTP transport is replaced: requests still pass through the real
/// scraper, request executor, response validation and JavaScript/decryption.
private final class ScraperHTTPFixture: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let session: URLSession
    private let state: ScraperFixtureProtocol.State

    init(reply: @escaping @Sendable (URLRequest) -> ScraperFixtureProtocol.Reply) {
        state = .init(reply: reply)
        ScraperFixtureProtocol.register(state, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScraperFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Scraper-Fixture": id]
        session = URLSession(configuration: configuration)
    }

    var requests: [URLRequest] { state.requests }
    func url(_ path: String) -> String { "https://\(id).test/\(path)" }
    func config() -> ScraperConfig {
        .init(id: id, name: "Fixture", version: 1, rateLimit: 0,
              capabilities: ["metadata", "cover", "lyrics"],
              search: .init(url: url("search"), method: "GET", script: "return response;"))
    }
    func encryptedConfig() -> ScraperConfig {
        var value = config()
        value.lyrics = .init(url: url("lyrics"), method: "GET", script: "return response;")
        value.secrets = ["lyricsFetchUrl": url("encrypted/{{id}}"), "lyricsContentField": "content",
                         "lyricsMagicHex": "00", "lyricsXorKeyHex": "01"]
        return value
    }
    func close() {
        session.invalidateAndCancel()
        ScraperFixtureProtocol.remove(id: id)
    }
}

private final class ScraperFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body = Data("[]".utf8)
        var error: URLError?
    }
    final class State: @unchecked Sendable {
        let reply: @Sendable (URLRequest) -> Reply
        private let lock = NSLock()
        private var captured: [URLRequest] = []
        init(reply: @escaping @Sendable (URLRequest) -> Reply) { self.reply = reply }
        var requests: [URLRequest] { lock.withLock { captured } }
        func record(_ request: URLRequest) { lock.withLock { captured.append(request) } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    static func register(_ state: State, id: String) { lock.withLock { states[id] = state } }
    static func remove(id: String) { _ = lock.withLock { states.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let id = request.value(forHTTPHeaderField: "X-Scraper-Fixture"),
              let state = Self.lock.withLock({ Self.states[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        state.record(request)
        let reply = state.reply(request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ScraperTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(to time: TimeInterval) { lock.withLock { value = time } }
    var timing: RequestExecutor.Timing { .init(now: { self.now }) }
}
