import Foundation
import Observation
import SwiftUI
import PrimuseKit
import XCTest
@testable import Primuse

final class SharedScraperRequestTests: XCTestCase {
    func testLyricsSourceCandidatesKeepPriorityContinueAfterFailureAndStopAtThree() async {
        let a = StubDirectLyricsScraper(.success("[00:01.00]Paper lanterns"))
        let b = StubDirectLyricsScraper(.failure(ScraperError.networkError("fixture unavailable")))
        let c = StubDirectLyricsScraper(.success("[00:01.00]Across the bay"))
        let d = StubDirectLyricsScraper(.success("[00:01.00]A silver trail"))
        let e = StubDirectLyricsScraper(.success("[00:01.00]Never requested"))
        let stubs = ["a": a, "b": b, "c": c, "d": d, "e": e]
        let manager = ScraperManager(scraperFactory: { stubs[$0.id] ?? e })
        let settings = ScraperSettings(sources: ["e", "c", "b", "d", "a"].map { id in
            ScraperSourceConfig(id: id, type: .lrclib, isEnabled: true, priority: ["a", "b", "c", "d", "e"].firstIndex(of: id)!)
        })
        let song = Song(id: "candidate-test", title: "Lantern Bay", fileFormat: .flac, filePath: "/fixture.flac", sourceID: "fixture", fileSize: 1)
        let result = await manager.lyricsSourceCandidates(for: song, settings: settings)
        XCTAssertEqual(result.compactMap { $0.first?.text }, ["Paper lanterns", "Across the bay", "A silver trail"])
        XCTAssertTrue(result.allSatisfy { LyricsDocumentSource.of($0)?.kind == .online })
        let skipped = await e.requestCount
        XCTAssertEqual(skipped, 0)
    }

    func testLegacyConfigRoundTripPreservesUserFieldsAndFallback() throws {
        let original = Data(#"{"id":"kugou","name":"My source","version":6,"cookie":"fixture-cookie","modifiedAt":12345,"sslTrustDomains":["fixture.test"],"capabilities":["lyrics"],"lyrics":{"url":"https://fixture.test/lyrics","method":"GET","script":"return response;"},"secrets":{"testKey":"fixture-secret"}}"#.utf8)
        let config = try JSONDecoder().decode(ScraperConfig.self, from: original)
        let encoded = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(ScraperConfig.self, from: encoded)
        XCTAssertEqual(restored.id, config.id)
        XCTAssertEqual(restored.name, config.name)
        XCTAssertEqual(restored.version, config.version)
        XCTAssertEqual(restored.cookie, config.cookie)
        XCTAssertEqual(restored.modifiedAt, config.modifiedAt)
        XCTAssertEqual(restored.sslTrustDomains, config.sslTrustDomains)
        XCTAssertEqual(restored.lyrics?.script, config.lyrics?.script)
        XCTAssertNil(restored.secrets)
        XCTAssertNil(restored.lyricsFallback)
        XCTAssertNil(restored.responseValidation)
        XCTAssertNotNil(LegacyScraperCompatibility.lyricsFallback(for: restored))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-secret"))
    }

    func testConfiguredFallbackRoundTripAndImportPreview() throws {
        let fixture = ScraperHTTPFixture { _ in .init() }
        defer { fixture.close() }
        var config = fixture.config()
        config.lyricsFallback = .init(url: "https://lyrics.fixture.test/get?id={{id}}", contentField: "text",
                                      encoding: .utf8, requiredVariables: ["id"])
        config.responseValidation = .init(codePaths: ["status", "operations.*.status"], successCodes: [200])
        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(ScraperConfig.self, from: data)
        XCTAssertEqual(restored.lyricsFallback?.requiredVariables, ["id"])
        XCTAssertEqual(restored.responseValidation?.successCodes, [200])
        let summary = try ScraperConfigStore.shared.previewImportFromJSON(String(decoding: data, as: UTF8.self))
        XCTAssertTrue(summary.domains.contains("lyrics.fixture.test"))
        XCTAssertEqual(summary.endpointCount, 2)
    }

    func testConfiguredFallbackSupportsBothEncodingsAndEscapesVariables() async throws {
        for encoding in [LyricsFallbackConfig.ContentEncoding.utf8, .base64UTF8] {
            let expected = "[00:01.00]Paper boats cross the bay"
            let content = encoding == .utf8 ? expected : Data(expected.utf8).base64EncodedString()
            let body = try JSONSerialization.data(withJSONObject: ["text": content])
            let fixture = ScraperHTTPFixture { request in
                request.url?.path == "/lyrics"
                    ? .init(body: Data(#"{"_fetchLyrics":true,"vars":{"id":"a&other=1"}}"#.utf8))
                    : .init(body: body)
            }
            defer { fixture.close() }
            // Explicit configuration also overrides the legacy source's default URL.
            var config = ScraperConfig(id: "kugou", name: "Fixture", version: 7, rateLimit: 0, capabilities: ["lyrics"])
            config.lyrics = fixture.encryptedConfig().lyrics
            config.lyricsFallback = .init(url: fixture.url("fallback?id={{id}}"), contentField: "text",
                                          encoding: encoding, requiredVariables: ["id"])
            let result = try await ConfigurableScraper(config: config, session: fixture.session).getLyrics(externalId: "song")
            XCTAssertEqual(result?.lrcContent, expected)
            let url = try XCTUnwrap(fixture.requests.last?.url)
            XCTAssertEqual(url.host, URL(string: fixture.url(""))?.host)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                           [.init(name: "id", value: "a&other=1")])
        }
    }

    func testMissingFallbackVariablesDoNotSendSecondRequest() async throws {
        let fixture = ScraperHTTPFixture { _ in
            .init(body: Data(#"{"_fetchLyrics":true,"vars":{"id":"123"}}"#.utf8))
        }
        defer { fixture.close() }
        var config = fixture.config()
        config.lyrics = fixture.encryptedConfig().lyrics
        config.lyricsFallback = .init(url: fixture.url("fallback"), contentField: "content", encoding: .base64UTF8,
                                      requiredVariables: ["ticket"])
        let result = try await ConfigurableScraper(config: config, session: fixture.session).getLyrics(externalId: "song")
        XCTAssertNil(result)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testConfiguredBusinessFailureReachesCircuitBreaker() async throws {
        let fixture = ScraperHTTPFixture { _ in
            .init(body: Data(#"{"status":200,"operations":{"search":{"status":401}}}"#.utf8))
        }
        defer { fixture.close() }
        var config = fixture.config()
        config.responseValidation = .init(codePaths: ["status", "operations.*.status"], successCodes: [200])
        let scraper = ConfigurableScraper(config: config, session: fixture.session, requestPool: ScraperRequestPool())
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let settings = ScraperSettings(sources: [.init(id: config.id, type: .itunes, isEnabled: true, priority: 0)])
        for index in 0..<8 {
            _ = await manager.scrapeMetadata(title: "Song \(index)", artist: nil, album: nil, duration: nil,
                needs: .init(metadata: true, cover: false, lyrics: false), settings: settings)
        }
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testExplicitBusinessRulesOverrideLegacyDefaults() async throws {
        let fixture = ScraperHTTPFixture { _ in .init(body: Data(#"{"code":200,"items":[]}"#.utf8)) }
        defer { fixture.close() }
        var config = ScraperConfig(id: "qqmusic", name: "Fixture", version: 2, rateLimit: 0, capabilities: ["metadata"])
        config.search = .init(url: fixture.url("search"), method: "GET", script: "return response.items;")
        config.responseValidation = .init(codePaths: ["code"], successCodes: [200])
        let result = try await ConfigurableScraper(config: config, session: fixture.session).search(query: "Song", artist: nil, album: nil, limit: 1)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testScriptErrorsAreFailuresWhileExplicitEmptyResultsRemainSuccessful() async throws {
        let fixture = ScraperHTTPFixture { _ in .init() }
        defer { fixture.close() }
        for script in ["throw new Error('fixture');", "return (;", "return missingVariable.value;"] {
            var config = fixture.config()
            config.search = .init(url: fixture.url("search"), method: "GET", script: script)
            do {
                _ = try await ConfigurableScraper(config: config, session: fixture.session).search(query: "Song", artist: nil, album: nil, limit: 1)
                XCTFail("Script failure must not become a search miss")
            } catch ScraperError.parseError { }
        }
        for script in ["return null;", "return undefined;", "return [];"] {
            var config = fixture.config()
            config.search = .init(url: fixture.url("search"), method: "GET", script: script)
            let result = try await ConfigurableScraper(config: config, session: fixture.session).search(query: "Song", artist: nil, album: nil, limit: 1)
            XCTAssertTrue(result.items.isEmpty)
        }
    }

    func testKugouWithoutPrivateConfigurationFetchesPublicLRC() async throws {
        let expected = "[00:01.00]A line\n[00:02.00]Another line"
        let fixture = ScraperHTTPFixture { request in
            if request.url?.path == "/lyrics" {
                return .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":[{"id":"123","accesskey":"fixture-key"}]}"#.utf8))
            }
            return .init(body: Data("{\"status\":200,\"content\":\"\(Data(expected.utf8).base64EncodedString())\"}".utf8))
        }
        defer { fixture.close() }
        var config = ScraperConfig(id: "kugou", name: "Fixture", version: 6, rateLimit: 0, capabilities: ["lyrics"])
        config.lyrics = fixture.encryptedConfig().lyrics
        let result = try await ConfigurableScraper(config: config, session: fixture.session).getLyrics(externalId: "song")
        XCTAssertEqual(result?.lrcContent, expected)
        let request = try XCTUnwrap(fixture.requests.last)
        XCTAssertEqual(request.url?.host, "lyrics.kugou.com")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "fmt" }?.value, "lrc")
        XCTAssertEqual(query?.first { $0.name == "id" }?.value, "123")
    }

    func testKugouPlainFallbackPreservesRateLimit() async {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/lyrics"
                ? .init(body: Data(#"{"_fetchEncryptedLyrics":true,"vars":{"id":"123","accesskey":"fixture-key"}}"#.utf8))
                : .init(status: 429, headers: ["Retry-After": "3600"])
        }
        defer { fixture.close() }
        var config = ScraperConfig(id: "kugou", name: "Fixture", version: 6, rateLimit: 0, capabilities: ["lyrics"])
        config.lyrics = fixture.encryptedConfig().lyrics
        await assertRateLimited {
            _ = try await ConfigurableScraper(config: config, session: fixture.session, requestPool: ScraperRequestPool()).getLyrics(externalId: "song")
        }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testQQBusinessFailuresReachCircuitBreakerInsteadOfBecomingSearchMisses() async throws {
        for usesProxy in [false, true] {
            let fixture = ScraperHTTPFixture { _ in
                .init(body: Data(#"{"code":0,"req_1":{"code":2001,"data":{"body":{"song":{"list":[]}}}}}"#.utf8))
            }
            defer { fixture.close() }
            let config = ScraperConfig(id: usesProxy ? "qqmusic" : fixture.id, name: "Fixture", version: 1,
                rateLimit: 0, capabilities: ["metadata", "lyrics"], search: .init(
                    url: usesProxy ? fixture.url("search") : "https://u.y.qq.com/cgi-bin/musicu.fcg",
                    method: "POST", bodyTemplate: "{}", script: "return [];"))
            let scraper = ConfigurableScraper(config: config, session: fixture.session, requestPool: ScraperRequestPool())
            let manager = ScraperManager(scraperFactory: { _ in scraper })
            let settings = ScraperSettings(sources: [
                .init(id: config.id, type: .itunes, isEnabled: true, priority: 0)
            ])
            for index in 0..<8 {
                _ = await manager.scrapeMetadata(title: "Song \(index)", artist: nil, album: nil, duration: nil,
                    needs: .init(metadata: true, cover: false, lyrics: false), settings: settings)
            }
            XCTAssertEqual(fixture.requests.count, 3, "Repeated API failures must open the existing source circuit")
        }
    }

    func testQQEmptySuccessAndUnrelatedProviderCodesDoNotOpenCircuit() async throws {
        for (host, body) in [
            ("u.y.qq.com", #"{"code":0,"req_1":{"code":0,"data":{}}}"#),
            ("unrelated.test", #"{"code":2001,"req_1":{"code":2001}}"#)
        ] {
            let fixture = ScraperHTTPFixture { _ in .init(body: Data(body.utf8)) }
            defer { fixture.close() }
            var config = fixture.config()
            config.search = .init(url: "https://\(host)/search", method: "GET", script: "return [];")
            let scraper = ConfigurableScraper(config: config, session: fixture.session)
            for _ in 0..<4 {
                let result = try await scraper.search(query: "Song", artist: nil, album: nil, limit: 1)
                XCTAssertTrue(result.items.isEmpty)
            }
            XCTAssertEqual(fixture.requests.count, 4)
        }
    }

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

        let lookup = ScraperManager.lyricsLookupIdentity(query: "小海 Singer", title: "小海", artist: "Singer")
        let found = await manager.manualLyricsCandidates(
            title: lookup.title, artist: lookup.artist, album: nil, duration: 200, settings: settings
        )
        XCTAssertEqual(found.map(\.config.id), ["lyrics"])
        XCTAssertEqual(found.first?.lyrics.map(\.text), ["第一句", "第二句"])

        let miss = await manager.manualLyricsCandidates(
            title: "别的歌", artist: "Singer", album: nil, duration: 200, settings: settings
        )
        XCTAssertTrue(miss.isEmpty)

        let disabled = await manager.manualLyricsCandidates(
            title: "小海", artist: "Singer", album: nil, duration: 200,
            settings: ScraperSettings(sources: [.init(id: "lyrics", type: .lyricsServer, isEnabled: false, priority: 0)])
        )
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertEqual(fixture.requests.count, 2, "A disabled lyrics API is never asked")
    }

    func testManualLyricsLookupPreservesVersionsWhenSplittingTitleAndArtist() {
        func lookup(_ query: String, title: String = "小海", artist: String? = "Singer") -> [String?] {
            let identity = ScraperManager.lyricsLookupIdentity(query: query, title: title, artist: artist)
            return [identity.title, identity.artist]
        }
        XCTAssertEqual(lookup("小海 Singer"), ["小海", "Singer"], "The suggested query is title + artist")
        XCTAssertEqual(lookup("小海"), ["小海", "Singer"], "A title-only query keeps the song's artist")
        XCTAssertEqual(lookup("小海 (Live) singer"), ["小海 (Live)", "Singer"], "Artist suffix is matched case-insensitively")
        XCTAssertEqual(lookup("小海 (Live)"), ["小海 (Live)", "Singer"])
        XCTAssertEqual(lookup("周杰伦 - 稻香 (Remix摇滚版)", artist: nil), ["稻香 (Remix摇滚版)", "周杰伦"])
        XCTAssertEqual(lookup("调查中 - Live", artist: nil), ["调查中 - Live", nil])
        XCTAssertEqual(MusicScraperService.searchQuery(title: "01. 调查中 (Live)【无损】", artist: "周深"), "调查中 (Live) 周深")
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

    func testAMLLAutomaticLookupPreservesRecordingVersionThroughManager() async {
        for (input, expected, artist) in [
            ("01. 调查中 (Live)【无损】", "调查中 (Live)", "周深"),
            ("周杰伦 - 稻香 (Remix摇滚版)", "稻香 (Remix摇滚版)", "周杰伦"),
            ("调查中（Live）", "调查中（Live）", "周深"),
            ("调查中 [Live]", "调查中 [Live]", "周深")
        ] {
            let fixture = ScraperHTTPFixture { request in
                let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                if components?.path == "/v1/lyrics/get" {
                    return .init(body: Self.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
                }
                let title = components?.queryItems?.first { $0.name == "musicName" }?.value
                return .init(body: Self.amllSearchBody(title == expected ? [(7, expected, artist)] : []))
            }
            defer { fixture.close() }
            let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
            let manager = ScraperManager(scraperFactory: { _ in amll })
            let result = await manager.scrapeMetadata(title: input, artist: artist, album: nil, duration: 240,
                needs: .init(metadata: false, cover: false, lyrics: true),
                settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
            XCTAssertEqual(result.lyrics?.count, 2, input)
            XCTAssertTrue(result.lyrics?.allSatisfy(\.isWordLevel) ?? false, input)
            XCTAssertEqual(fixture.requests.count, 2, input)
        }
    }

    func testAMLLLiveQueryDoesNotAcceptStudioLyricsThroughManager() async {
        let fixture = ScraperHTTPFixture { _ in
            .init(body: Self.amllSearchBody([(7, "调查中", "周深")]))
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in amll })
        let result = await manager.scrapeMetadata(title: "调查中 (Live)", artist: "周深", album: nil, duration: 240,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
        XCTAssertNil(result.lyrics)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.url?.path == "/v1/lyrics/search" })
    }

    func testAMLLRetriesTitleWhenArtistSearchReturnsOnlyIncompatibleVersions() async throws {
        let fixture = ScraperHTTPFixture { request in
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            if components?.path == "/v1/lyrics/get" {
                return .init(body: Self.amllLyricsBody(id: 8, lastLineEnd: "03:20.000"))
            }
            let hasArtist = components?.queryItems?.contains { $0.name == "artistName" } ?? false
            return .init(body: Self.amllSearchBody(hasArtist
                ? [(7, "Song (Live)", "Singer")] : [(8, "Song", "Singer")]))
        }
        defer { fixture.close() }
        let scraper = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.fetchLyrics(title: "Song", artist: "Singer", album: nil, duration: 240)
        XCTAssertTrue(result?.hasLyrics ?? false)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/v1/lyrics/search", "/v1/lyrics/search", "/v1/lyrics/get"])
        let lastURL = try XCTUnwrap(fixture.requests.last?.url)
        XCTAssertEqual(URLComponents(url: lastURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "8")
    }

    func testManualAMLLAliasCandidateUsesUpstreamIdentityAndExactLyricsID() async throws {
        let fixture = ScraperHTTPFixture { request in
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            if components?.path == "/v1/lyrics/get" {
                return .init(body: Self.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
            }
            let hasArtist = components?.queryItems?.contains { $0.name == "artistName" } ?? false
            return .init(body: Self.amllSearchBody(hasArtist ? [] : [(7, "晴天", "周杰伦")]))
        }
        defer { fixture.close() }
        let scraper = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let automatic = try await scraper.fetchLyrics(title: "晴天", artist: "Jay Chou", album: nil, duration: 269)
        XCTAssertNil(automatic, "An unverified alias must not silently bypass automatic identity matching")
        let candidates = await manager.manualLyricsCandidates(title: "晴天", artist: "Jay Chou", album: nil, duration: 269,
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.item.artist, "周杰伦")
        XCTAssertEqual(candidates.first?.item.title, "晴天")
        XCTAssertEqual(candidates.first?.item.externalId, "amll:7")
        XCTAssertEqual(candidates.first?.lyrics.count, 2)
        XCTAssertTrue(candidates.first?.lyrics.allSatisfy(\.isWordLevel) ?? false)
        XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/v1/lyrics/get" }.count, 1)
    }

    func testManualAMLLCandidatesRespectDisabledSourcesAndDuration() async {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/v1/lyrics/get"
                ? .init(body: Self.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
                : .init(body: Self.amllSearchBody([(7, "Song", "Singer")]))
        }
        defer { fixture.close() }
        let scraper = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let disabled = await manager.manualLyricsCandidates(title: "Song", artist: "Singer", album: nil, duration: 240,
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: false, priority: 0)]))
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
        let tooLong = await manager.manualLyricsCandidates(title: "Song", artist: "Singer", album: nil, duration: 100,
            settings: .init(sources: [.init(id: "amll", type: .amll, isEnabled: true, priority: 0)]))
        XCTAssertTrue(tooLong.isEmpty)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testManualAMLLFailureStillQueriesLyricsServer() async {
        let fixture = ScraperHTTPFixture { request in
            request.url?.host == "api.amll.dev"
                ? .init(status: 503, headers: ["Retry-After": "60"])
                : .init(body: Data("[00:01.00]歌词".utf8))
        }
        defer { fixture.close() }
        let amll = AMLLScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let server = LyricsAPIServerScraper(servers: [.init(address: fixture.url("api"))], session: fixture.session)
        let manager = ScraperManager(scraperFactory: { config in
            if config.type == .amll { return amll }
            return server
        })
        let settings = ScraperSettings(sources: [
            .init(id: "amll", type: .amll, isEnabled: true, priority: 0),
            .init(id: "server", type: .lyricsServer, isEnabled: true, priority: 1)
        ])
        for _ in 0..<2 {
            let candidates = await manager.manualLyricsCandidates(title: "Song", artist: "Singer", album: nil,
                duration: 240, settings: settings)
            XCTAssertEqual(candidates.map(\.config.id), ["server"])
        }
        XCTAssertEqual(fixture.requests.filter { $0.url?.host == "api.amll.dev" }.count, 1,
            "The manual path must share the source cooldown")
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

    func testLineTimedLyricsAskTheNextSourceForWordTiming() async {
        let fixture = ScraperHTTPFixture { request in
            switch request.url?.path {
            case "/api/get":
                return .init(body: Data(#"{"syncedLyrics":"[00:10.00]Hello\n[03:10.00]World"}"#.utf8))
            case "/v1/lyrics/search":
                return .init(body: SharedScraperRequestTests.amllSearchBody([(7, "Song", "Artist")]))
            case "/v1/lyrics/get":
                return .init(body: SharedScraperRequestTests.amllLyricsBody(id: 7, lastLineEnd: "03:20.000"))
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
        // LRCLIB 排在前面、只给逐行：再问后面的 AMLL，拿到逐字就用逐字。
        let result = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: 269,
            needs: .init(metadata: false, cover: false, lyrics: true), settings: .init(sources: [
                .init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 0),
                .init(id: "amll", type: .amll, isEnabled: true, priority: 1)
            ]))
        XCTAssertEqual(result.lyrics?.count, 2)
        XCTAssertTrue(result.lyrics?.allSatisfy(\.isWordLevel) ?? false)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/api/get", "/v1/lyrics/search", "/v1/lyrics/get"])
    }

    func testTimingPickAsksTwoMoreSourcesAndKeepsWhatItHas() async {
        let first = StubDirectLyricsScraper(.success("[00:01.00]Hello\n[00:03.00]World"))
        let failing = StubDirectLyricsScraper(.failure(ScraperError.networkError("HTTP 500")))
        let sameLevel = StubDirectLyricsScraper(.success("[00:01.00]Other\n[00:03.00]Lyrics"))
        let wordTimed = StubDirectLyricsScraper(.success("[00:01.00]<00:01.00>Hel<00:01.50>lo"))
        let stubs = ["a": first, "b": failing, "c": sameLevel, "d": wordTimed]
        let manager = ScraperManager(scraperFactory: { config in stubs[config.id] ?? wordTimed })
        let result = await manager.scrapeMetadata(title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true), settings: .init(sources: [
                .init(id: "a", type: .lrclib, isEnabled: true, priority: 0),
                .init(id: "b", type: .lrclib, isEnabled: true, priority: 1),
                .init(id: "c", type: .lrclib, isEnabled: true, priority: 2),
                .init(id: "d", type: .lrclib, isEnabled: true, priority: 3)
            ]))
        // 出错的和同级的都不顶掉先拿到的那份；多问两个之后就停，第四个源不问。
        XCTAssertEqual(result.lyrics?.map(\.text), ["Hello", "World"])
        XCTAssertEqual(result.errors.count, 1)
        let first1 = await first.requestCount
        let failing1 = await failing.requestCount
        let same1 = await sameLevel.requestCount
        let word1 = await wordTimed.requestCount
        XCTAssertEqual([first1, failing1, same1, word1], [1, 1, 1, 0])
    }

    func testWordDiscoveryContinuesPastLineTimedFallbackLimit() async {
        let line = StubDirectLyricsScraper(.success("[00:01.00]Hello"))
        let word = StubDirectLyricsScraper(.success("[00:01.00]<00:01.00>Hel<00:01.50>lo"))
        let manager = ScraperManager(scraperFactory: { config in config.id == "word" ? word : line })
        let sources = (0..<4).map { index in
            ScraperSourceConfig(id: "line-\(index)", type: .lrclib, isEnabled: true, priority: index)
        } + [ScraperSourceConfig(id: "word", type: .lrclib, isEnabled: true, priority: 4)]
        let result = await manager.scrapeMetadata(
            title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: sources), requiresWordTiming: true
        )
        XCTAssertEqual(result.lyrics.map { LyricsTimingLevel(lines: $0) }, .word)
        let lineCount = await line.requestCount
        let wordCount = await word.requestCount
        XCTAssertEqual(lineCount, 4)
        XCTAssertEqual(wordCount, 1)
    }

    func testWordDiscoveryDoesNotReturnLineTimedLyricsAsSuccess() async {
        let line = StubDirectLyricsScraper(.success("[00:01.00]Hello"))
        let manager = ScraperManager(scraperFactory: { _ in line })
        let result = await manager.scrapeMetadata(
            title: "Song", artist: "Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "line", type: .lrclib, isEnabled: true, priority: 0)]),
            requiresWordTiming: true
        )
        XCTAssertNil(result.lyrics)
        XCTAssertTrue(result.errors.isEmpty)
    }

    @MainActor
    func testPlayerActivitiesStayWithTheirSongAndKeepOtherTasksVisible() async throws {
        let store = PlayerActivityStore()
        let first = UUID(), second = UUID(), batch = UUID()
        store.publish(.init(id: first, songID: "a", title: "lyrics", progress: nil))
        store.publish(.init(id: second, songID: "b", title: "cover", progress: nil))
        XCTAssertEqual(store.status(for: "a")?.id, first)
        XCTAssertEqual(store.status(for: "b")?.id, second)
        XCTAssertNil(store.status(for: "c"))
        XCTAssertNil(store.status(for: nil))
        store.publish(.init(id: batch, songID: nil, title: "batch", progress: 0.5))
        store.remove(first)
        XCTAssertEqual(store.status(for: "a")?.id, batch)
        store.remove(batch)
        XCTAssertEqual(store.status(for: "b")?.id, second)
        let preview = VStack(spacing: 20) {
            ForEach([false, true], id: \.self) { activityFirst in
                PlayerStatusItemsRow(items: activityFirst ? [.activity, .source] : [.source, .activity]) { item in
                    if item == .source {
                        Label("Navidrome", systemImage: "externaldrive")
                    } else {
                        PlayerActivityStatusView(status: .init(
                            id: first, songID: "a", title: "正在获取逐字歌词", progress: 0.5
                        ))
                    }
                }
            }
            PlayerStatusItemsRow(items: [.source, .output, .activity]) { item in
                switch item {
                case .source: Label("Navidrome", systemImage: "externaldrive")
                case .output: Label("AirPods", systemImage: "headphones")
                case .activity:
                    PlayerActivityStatusView(status: .init(
                        id: first, songID: "a", title: "逐字歌词已下载", progress: nil, isRunning: false
                    ))
                case .sleepTimer: EmptyView()
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(24)
        .frame(width: 390)
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
        let inline = UIHostingController(rootView: PlayerStatusItemsRow(items: [.source, .activity]) { item in
            if item == .source {
                Label("Navidrome", systemImage: "externaldrive")
            } else {
                PlayerActivityStatusView(status: .init(
                    id: first, songID: "a", title: "正在从 AMLL 获取逐字歌词", progress: 0.5
                ))
            }
        })
        inline.safeAreaRegions = []
        let fitted = inline.sizeThatFits(in: CGSize(width: 338, height: 100))
        XCTAssertLessThanOrEqual(fitted.height, 20, "Task activity must stay within the existing footer line")
        let host = UIHostingController(rootView: preview)
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 184)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "player-activity-status"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPlaybackDiscoveryInstallsLyricsWithoutALyricsView() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.close() }
        LyricsDocumentPinStore.shared.setAutomaticPick("song.lrc", forSongID: fixture.song.id)
        let completed = expectation(description: "installed")
        fixture.start { _, _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: fixture.song.id)
        XCTAssertEqual(cached.map { LyricsTimingLevel(lines: $0) }, .word)
        XCTAssertEqual(fixture.state.song?.id, fixture.song.id)
    }

    @MainActor
    func testPlaybackDiscoveryPreservesConcurrentEdits() async throws {
        let fixture = try DiscoveryFixture(delay: .milliseconds(200))
        defer { fixture.close() }
        fixture.start()
        await fixture.waitForRequest()
        var edited = [LyricLine(timestamp: 1, text: "Edited by user")]
        edited[0].documentIsLocalOverride = true
        _ = await MetadataAssetStore.shared.cacheLyrics(edited, forSongID: fixture.song.id, force: true)
        try await Task.sleep(for: .milliseconds(300))
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: fixture.song.id)
        XCTAssertEqual(cached?.first?.text, "Edited by user")
        XCTAssertEqual(cached?.first?.documentIsLocalOverride, true)
    }

    @MainActor
    func testPlaybackDiscoveryCancelsOnSongChangeAndCanRetry() async throws {
        let fixture = try DiscoveryFixture(delay: .milliseconds(200))
        defer { fixture.close() }
        fixture.start()
        await fixture.waitForRequest()
        fixture.state.song = nil
        try await Task.sleep(for: .milliseconds(40))
        let cancelledCache = await MetadataAssetStore.shared.cachedLyrics(forSongID: fixture.song.id)
        XCTAssertNil(cancelledCache)
        XCTAssertNil(PlayerActivityStore.shared.status(for: fixture.song.id))
        let completed = expectation(description: "retry installed")
        fixture.installed = { _, _ in completed.fulfill() }
        fixture.state.song = fixture.song
        await fulfillment(of: [completed], timeout: 3)
        let requests = await fixture.stub.requestCount
        XCTAssertEqual(requests, 2)
    }

    @MainActor
    func testPlaybackDiscoveryTurningOffCancelsPendingResult() async throws {
        let fixture = try DiscoveryFixture(delay: .milliseconds(200))
        defer { fixture.close() }
        fixture.start()
        await fixture.waitForRequest()
        fixture.defaults.set(false, forKey: WordLyricsDiscoveryPreferences.enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: fixture.defaults)
        try await Task.sleep(for: .milliseconds(300))
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: fixture.song.id)
        XCTAssertNil(cached)
        XCTAssertNil(PlayerActivityStore.shared.status(for: fixture.song.id))
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
        XCTAssertEqual(loaded.sources.first { $0.type == .amll }?.isEnabled, true)
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

/// 直接按歌名取歌词的源的替身：固定返回一份歌词、没有或出错，并记下被问了几次。
private actor StubDirectLyricsScraper: MusicScraper, DirectLyricsLookup {
    let type = MusicScraperType.lrclib
    private let reply: Result<String?, any Error>
    private let delay: Duration
    private(set) var requestCount = 0

    init(_ reply: Result<String?, any Error>, delay: Duration = .zero) {
        self.reply = reply
        self.delay = delay
    }

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        .empty(.lrclib)
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? { nil }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] { [] }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }

    func fetchLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> ScraperLyricsResult? {
        requestCount += 1
        try? await Task.sleep(for: delay)
        return try reply.get().map { ScraperLyricsResult(source: .lrclib, lrcContent: $0) }
    }
}

/// 只剩歌名可比(没有歌手、也没有时长)时,括号里的版本说明要照写对上。
final class ScraperTitleOnlyMatchTests: XCTestCase {
    private func item(_ title: String, artist: String? = nil, durationMs: Int? = nil) -> ScraperSearchItem {
        ScraperSearchItem(externalId: title, source: .itunes, title: title, artist: artist, durationMs: durationMs)
    }

    func testVersionNoteKeepsTheOriginalSongFromMatching() {
        let written = "The Final Countdown (&TEAM ver.)"
        let cleaned = ScraperManager.cleanTitle(written)
        XCTAssertFalse(ScraperManager.isConfidentAutoMatch(
            item("The Final Countdown"), title: cleaned, artist: nil, durationMs: nil, writtenTitle: written
        ))
        XCTAssertNil(ScraperManager.bestMatch(
            in: [item("The Final Countdown")], title: cleaned, artist: nil, durationMs: nil, writtenTitle: written
        ))
    }

    func testSameVersionNoteStillMatches() {
        let written = "04. The Final Countdown（&TEAM Ver.）"
        let cleaned = ScraperManager.cleanTitle(written)
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(
            item("The Final Countdown (&TEAM ver.)"), title: cleaned, artist: nil, durationMs: nil, writtenTitle: written
        ))
    }

    func testPlainTitleWithoutNotesStillMatches() {
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(
            item("Hello"), title: "Hello", artist: nil, durationMs: nil, writtenTitle: "Hello"
        ))
    }

    func testArtistEvidenceStillDecidesWhenPresent() {
        let written = "The Final Countdown (&TEAM ver.)"
        let cleaned = ScraperManager.cleanTitle(written)
        XCTAssertFalse(ScraperManager.isConfidentAutoMatch(
            item("The Final Countdown", artist: "Europe"), title: cleaned, artist: "&TEAM", durationMs: nil,
            writtenTitle: written
        ))
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(
            item("The Final Countdown (&TEAM ver.)", artist: "&TEAM"), title: cleaned, artist: "&TEAM",
            durationMs: nil, writtenTitle: written
        ))
    }
}


@MainActor @Observable
private final class DiscoveryPlaybackState {
    var song: Song?
}

@MainActor
private final class DiscoveryFixture {
    let suite = "word-discovery-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let song: Song
    let state = DiscoveryPlaybackState()
    let stub: StubDirectLyricsScraper
    var coordinator: PlaybackWordLyricsDiscovery?
    var installed: (Song, [LyricLine]) -> Void = { _, _ in }

    init(delay: Duration = .zero) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: WordLyricsDiscoveryPreferences.enabledKey)
        song = Song(id: UUID().uuidString, title: "Song", fileFormat: .mp3, filePath: "song.mp3", sourceID: "test")
        state.song = song
        stub = StubDirectLyricsScraper(.success("[00:01.00]<00:01.00>Hel<00:01.50>lo"), delay: delay)
    }

    func start(installed: @escaping (Song, [LyricLine]) -> Void = { _, _ in }) {
        self.installed = installed
        let state = state
        let stub = stub
        coordinator = PlaybackWordLyricsDiscovery(
            playback: { .init(song: state.song, isPlaying: state.song != nil, isSpokenWord: false) },
            load: { _ in [] },
            didInstall: { [weak self] song, lines in self?.installed(song, lines) },
            scraper: ScraperManager(scraperFactory: { _ in stub }),
            defaults: defaults,
            settings: { .init(sources: [.init(id: "test", type: .lrclib, isEnabled: true, priority: 0)]) },
            debounce: .zero
        )
    }

    func waitForRequest() async {
        for _ in 0..<200 {
            if await stub.requestCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Discovery did not request lyrics")
    }

    func close() {
        state.song = nil
        coordinator = nil
        defaults.removePersistentDomain(forName: suite)
        let songID = song.id
        LyricsDocumentPinStore.shared.forgetFile(named: "song.lrc", forSongID: songID)
        if let status = PlayerActivityStore.shared.status(for: songID) {
            PlayerActivityStore.shared.remove(status.id)
        }
        Task { _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID) }
    }
}

final class BuiltInScraperRegressionTests: XCTestCase {
    private static let lyric = "[00:01.00]小船停在清晨的岸边\n[00:03.00]纸灯照亮未写的明天"

    private static func row(id: Int = 1, title: String = "纸灯", artist: String = "林舟", duration: Double = 180) -> [String: Any] {
        ["id": id, "trackName": title, "artistName": artist, "albumName": "岸边", "duration": duration, "syncedLyrics": lyric]
    }

    private static func data(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private static func query(_ request: URLRequest, _ key: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
    }

    func testManualMusicBrainzUsesSeparateFieldsAndKeepsLuceneEscaping() async throws {
        let fixture = ScraperHTTPFixture { _ in .init(body: Data(#"{"recordings":[]}"#.utf8)) }
        defer { fixture.close() }
        let identity = ScraperManager.manualSearchIdentity(query: "纸灯 林舟", title: "纸灯", artist: "林舟", source: .musicBrainz)
        _ = try await MusicBrainzScraper(session: fixture.session, requestExecutor: RequestExecutor()).search(
            query: identity.title, artist: identity.artist, album: nil, limit: 20)
        XCTAssertEqual(Self.query(try XCTUnwrap(fixture.requests.first), "query"), "recording:\"纸灯\" AND artist:\"林舟\"")
        let custom = ScraperManager.manualSearchIdentity(query: "纸灯 林舟", title: "纸灯", artist: "林舟", source: .custom("existing"))
        XCTAssertEqual(custom.title, "纸灯 林舟")
        XCTAssertNil(custom.artist)
    }

    func testLRCLIBManualCandidatesUseRealIDsAndCachedLyrics() async throws {
        let fixture = ScraperHTTPFixture { _ in .init(body: Self.data([Self.row(), Self.row(id: 2, title: "纸灯 (Live)")])) }
        defer { fixture.close() }
        let scraper = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let results = await manager.manualLyricsCandidates(title: "纸灯", artist: "林舟", album: nil, duration: 180,
            settings: .init(sources: [.init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 0)]))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.item.externalId, "lrclib:1")
        XCTAssertEqual(results.first?.lyrics.count, 2)
        XCTAssertEqual(fixture.requests.count, 1, "Search already returns lyrics; selecting candidates must not refetch them")
    }

    func testLRCLIBExactMissFallsBackWithoutAlbumAndRejectsWrongArtistVersionAndDuration() async throws {
        let fixture = ScraperHTTPFixture { request in
            if request.url?.path == "/api/get" { return .init(status: 404) }
            return .init(body: Self.data([
                Self.row(id: 1, artist: "别的歌手"), Self.row(id: 2, title: "纸灯 (Live)"),
                Self.row(id: 3, duration: 240), Self.row(id: 4, title: "紙燈", artist: "林舟", duration: 182)
            ]))
        }
        defer { fixture.close() }
        let result = try await LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor()).fetchLyrics(
            title: "纸灯", artist: "林舟", album: "本地文件夹名称", duration: 180)
        XCTAssertEqual(result?.lrcContent, Self.lyric)
        XCTAssertEqual(fixture.requests.map(\.url?.path), ["/api/get", "/api/search"])
        XCTAssertNil(Self.query(fixture.requests[1], "album_name"))
    }

    func testLRCLIBFailureDoesNotTriggerBroaderSearch() async throws {
        for status in [429, 500] {
            let fixture = ScraperHTTPFixture { _ in .init(status: status, headers: ["Retry-After": "60"]) }
            defer { fixture.close() }
            do {
                _ = try await LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor()).fetchLyrics(title: "纸灯", artist: "林舟")
                XCTFail("A service failure must remain distinguishable from a miss")
            } catch { }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testLRCLIBWrongArtistIsNeverAcceptedByAutomaticFallback() async throws {
        let fixture = ScraperHTTPFixture { request in
            request.url?.path == "/api/get" ? .init(status: 404)
                : .init(body: Self.data([Self.row(artist: "别的歌手")]))
        }
        defer { fixture.close() }
        let result = try await LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor()).fetchLyrics(title: "纸灯", artist: "林舟", duration: 180)
        XCTAssertNil(result)
    }

    func testAppleChineseStorefrontSurvivesDetailLookupAndTraditionalNamesMatch() async throws {
        let fixture = ScraperHTTPFixture { _ in
            .init(body: Self.data(["resultCount": 1, "results": [["trackId": 7, "artistId": 8, "trackName": "紙燈", "artistName": "林舟", "trackTimeMillis": 180000]]]))
        }
        defer { fixture.close() }
        let scraper = ITunesScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.search(query: "纸灯", artist: "林舟", album: nil, limit: 15)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(Self.query(fixture.requests[0], "country"), "TW")
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(try XCTUnwrap(result.items.first), title: "纸灯", artist: "林舟", durationMs: 180000))
        let reopened = ITunesScraper(session: fixture.session, requestExecutor: RequestExecutor())
        _ = try await reopened.getDetail(externalId: try XCTUnwrap(result.items.first?.externalId))
        XCTAssertEqual(Self.query(fixture.requests.last!, "country"), "TW")
        XCTAssertEqual(Self.query(fixture.requests.last!, "id"), "7")
    }

    func testAppleFallbackVerifiesAliasByArtistIDAndRepairsFilenameTitle() async throws {
        let fixture = ScraperHTTPFixture { request in
            let artist = Self.query(request, "country") == "TW" ? "林舟" : "Paper Boat"
            return .init(body: Self.data(["resultCount": 1, "results": [["trackId": 7, "artistId": 8, "trackName": "纸灯", "artistName": artist, "trackTimeMillis": 180000]]]))
        }
        defer { fixture.close() }
        let scraper = ITunesScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.search(query: "林舟 - 纸灯", artist: "Paper Boat", album: nil, limit: 15)
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(Set(item.artistAliases), ["林舟", "Paper Boat"])
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(item, title: "林舟 - 纸灯", artist: "Paper Boat", durationMs: 180000))
        XCTAssertFalse(ScraperManager.isConfidentAutoMatch(item, title: "纸灯", artist: "另一歌手", durationMs: 180000))
    }

    func testAppleDifferentArtistIDsDoNotCreateAliases() async throws {
        let fixture = ScraperHTTPFixture { request in
            let native = Self.query(request, "country") == "TW"
            return .init(body: Self.data(["resultCount": 1, "results": [["trackId": native ? 9 : 7, "artistId": native ? 10 : 8,
                                                                       "trackName": "纸灯", "artistName": native ? "林舟" : "Paper Boat"]]]))
        }
        defer { fixture.close() }
        let scraper = ITunesScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.search(query: "林舟 - 纸灯", artist: "Paper Boat", album: nil, limit: 15)
        XCTAssertFalse(result.items.contains { ScraperManager.isConfidentAutoMatch($0, title: "林舟 - 纸灯", artist: "Paper Boat", durationMs: 180000) })
    }

    func testMusicBrainzArtistAliasesRemainAttachedToDetail() async throws {
        let artistID = "10000000-0000-0000-0000-000000000001"
        let recordingID = "20000000-0000-0000-0000-000000000001"
        let fixture = ScraperHTTPFixture { request in
            if request.url?.path.contains("/artist/") == true {
                return .init(body: Self.data(["id": artistID, "name": "林舟", "aliases": [["name": "Paper Boat"]]]))
            }
            let recording: [String: Any] = ["id": recordingID, "title": "纸灯", "length": 180000,
                                            "artist-credit": [["name": "林舟", "artist": ["id": artistID, "name": "林舟"]]]]
            let isSearch = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "ws/2/recording"
            let searchesAlias = Self.query(request, "query")?.contains("artist:") == true
            let body: [String: Any] = isSearch ? ["recordings": searchesAlias ? [] : [recording]] : recording
            return .init(body: Self.data(body))
        }
        defer { fixture.close() }
        let scraper = MusicBrainzScraper(session: fixture.session, requestExecutor: RequestExecutor())
        let result = try await scraper.search(query: "纸灯", artist: "Paper Boat", album: nil, limit: 15)
        XCTAssertTrue(ScraperManager.isConfidentAutoMatch(try XCTUnwrap(result.items.first), title: "纸灯", artist: "Paper Boat", durationMs: 180000))
        let detail = try await scraper.getDetail(externalId: recordingID)
        XCTAssertTrue(detail?.artistAliases.contains("Paper Boat") == true)
    }

    func testNativeAutomaticMatchDoesNotReplaceLiveWithStudio() {
        let candidate = ScraperSearchItem(externalId: "7", source: .itunes, title: "纸灯", artist: "林舟", durationMs: 180000)
        XCTAssertFalse(ScraperManager.isConfidentAutoMatch(candidate, title: "纸灯", artist: "林舟", durationMs: 180000, writtenTitle: "纸灯 (Live)"))
    }

    func testCooldownIsReportedWithoutSendingRequests() async throws {
        let clock = ScraperTestClock()
        let fixture = ScraperHTTPFixture { _ in .init(status: 429, headers: ["Retry-After": "600"]) }
        defer { fixture.close() }
        let scraper = LRCLIBScraper(session: fixture.session, requestExecutor: RequestExecutor(timing: clock.timing))
        do { _ = try await scraper.fetchLyrics(title: "纸灯", artist: "林舟") } catch { }
        let manager = ScraperManager(scraperFactory: { _ in scraper })
        let result = await manager.scrapeMetadata(title: "纸灯", artist: "林舟", album: nil, duration: 180,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "lrclib", type: .lrclib, isEnabled: true, priority: 0)]))
        XCTAssertEqual(result.unavailableParts, .lyrics)
        XCTAssertEqual(result.retryAfter, 600, accuracy: 0.01)
        XCTAssertEqual(fixture.requests.count, 1)
    }
}

@MainActor
final class BatchScraperRecoveryTests: XCTestCase {
    func testTransientFailureRetriesCurrentSongAndReturnsLyrics() async throws {
        try await withFixture(failures: 1) { service, _, song, _, _, _ in
            var delays: [TimeInterval] = []
            let result = try await service.processedSongForBatch(song, forceRescrape: true, parts: .lyrics,
                                                                 sleep: { delays.append($0) })
            XCTAssertEqual(result?.lyricsLines?.count, 2)
            XCTAssertEqual(delays, [5])
            XCTAssertTrue(result?.unavailableParts.isEmpty == true)
        }
    }

    func testUnavailableBatchPreservesCheckpointAndCanResumeAfterRestart() async throws {
        try await withFixture(failures: .max) { service, _, song, root, source, library in
            var second = song
            second.id = UUID().uuidString
            library.addSongs([song, second])
            _ = service.scrapeMissingMetadata(songs: [song, second], in: library, parts: .lyrics)
            await service.waitUntilScrapeIdle()
            XCTAssertTrue(service.hasPendingScrape)
            XCTAssertEqual(service.processedCount, 0)
            XCTAssertEqual(service.skippedCount, 0)
            XCTAssertNil(service.lastCompletion)
            let checkpoint = try Data(contentsOf: root.appendingPathComponent("checkpoint/scrape-checkpoint.json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: checkpoint) as? [String: Any])
            XCTAssertEqual(json["nextSongIndex"] as? Int, 0)
            let healthy = RecoveryLyricsProbe(failures: 0, returnsLyrics: false)
            let resumed = MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [source] }),
                metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in healthy })),
                checkpointDirectory: root.appendingPathComponent("checkpoint"), scrapeRetrySleep: { _ in })
            resumed.resumePendingScrape(in: library)
            await resumed.waitUntilScrapeIdle()
            XCTAssertFalse(resumed.hasPendingScrape)
            XCTAssertEqual(resumed.lastCompletion?.processedSongCount, 2)
            XCTAssertEqual(resumed.lastCompletion?.skippedCount, 2, "Confirmed misses may complete; unavailable lookups may not")
        }
    }

    func testCancellationDuringRetryDoesNotTryAnotherSong() async throws {
        try await withFixture(failures: .max) { service, probe, song, _, _, _ in
            do {
                _ = try await service.processedSongForBatch(song, forceRescrape: true, parts: .lyrics,
                    sleep: { _ in throw CancellationError() })
                XCTFail("Cancellation must leave the request pending")
            } catch is CancellationError { }
            let requests = await probe.requests
            XCTAssertEqual(requests, 1)
        }
    }

    func testUnrequestedLyricsFailureDoesNotBlockMetadataBatch() async throws {
        try await withFixture(failures: .max) { service, _, song, _, _, _ in
            let result = try await service.processedSongForBatch(song, forceRescrape: true, parts: .metadata,
                sleep: { _ in XCTFail("Unrequested assets must not hold this batch") })
            XCTAssertNotNil(result)
        }
    }

    private func withFixture(failures: Int, body: (MusicScraperService, RecoveryLyricsProbe, Song, URL, MusicSource, MusicLibrary) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ScraperSettings.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: ScraperSettings.defaultsKey) }
            else { defaults.removeObject(forKey: ScraperSettings.defaultsKey) }
        }
        var settings = ScraperSettings.load()
        for index in settings.sources.indices { settings.sources[index].isEnabled = settings.sources[index].type == .lrclib }
        settings.save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrape-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var wav = Data("RIFF".utf8)
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        wav.append(u32(196)); wav.append(Data("WAVEfmt ".utf8)); wav.append(u32(16)); wav.append(contentsOf: [1, 0, 1, 0])
        wav.append(u32(8000)); wav.append(u32(16000)); wav.append(contentsOf: [2, 0, 16, 0])
        wav.append(Data("data".utf8)); wav.append(u32(160)); wav.append(Data(repeating: 0, count: 160))
        try wav.write(to: root.appendingPathComponent("Paper Lantern.wav"))
        let source = MusicSource(id: UUID().uuidString, name: "Recovery fixture", type: .local, basePath: root.path)
        let probe = RecoveryLyricsProbe(failures: failures)
        let service = MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [source] }),
            metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in probe })),
            checkpointDirectory: root.appendingPathComponent("checkpoint"), scrapeRetrySleep: { _ in })
        let song = Song(id: UUID().uuidString, title: "Paper Lantern", fileFormat: .wav, filePath: "/Paper Lantern.wav", sourceID: source.id)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        defer { service.cancel() }
        try await body(service, probe, song, root, source, library)
    }
}

private actor RecoveryLyricsProbe: MusicScraper, DirectLyricsLookup {
    let type = MusicScraperType.lrclib
    private var failures: Int
    private let returnsLyrics: Bool
    private(set) var requests = 0
    init(failures: Int, returnsLyrics: Bool = true) { self.failures = failures; self.returnsLyrics = returnsLyrics }
    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult { .empty(.lrclib) }
    func getDetail(externalId: String) async throws -> ScraperDetail? { nil }
    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] { [] }
    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }
    func fetchLyrics(title: String, artist: String?, album: String?, duration: TimeInterval?) async throws -> ScraperLyricsResult? {
        requests += 1
        if failures > 0 { failures -= 1; throw URLError(.timedOut) }
        return returnsLyrics ? .init(source: .lrclib, lrcContent: "[00:01.00]Paper lights along the shore\n[00:03.00]Footsteps find an open door") : nil
    }
}
