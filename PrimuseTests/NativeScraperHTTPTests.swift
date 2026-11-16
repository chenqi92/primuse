import Foundation
import ImageIO
import XCTest
import PrimuseKit
@testable import Primuse

final class NativeScraperHTTPTests: XCTestCase {
    func testLiveJSONSourcesAndPrepareVersionedFeed() async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_RUN_LIVE_SCRAPERS"] == "1" else {
            throw XCTSkip("Live source verification is opt-in")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let evidence = root.appendingPathComponent("Docs/QA/scraper-json-20261116/live")
        let raw = try Data(contentsOf: evidence.appendingPathComponent("online-bundle.json"))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let overrides = (try? Data(contentsOf: evidence.appendingPathComponent("source-overrides.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
        document["sources"] = (document["sources"] as? [[String: Any]] ?? []).map { source in
            source.merging(overrides[source["id"] as? String ?? ""] ?? [:]) { _, updated in updated }
        }
        let input = try JSONSerialization.data(withJSONObject: document)
        struct Bundle: Decodable { let sources: [ScraperConfig] }
        var configs = try JSONDecoder().decode(Bundle.self, from: input).sources
        var staged: [[String: Any]] = []
        let destination = root.appendingPathComponent("ScraperConfigs/1")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for config in configs {
            for endpoint in ScraperNetworkScope.endpoints(config).values { try endpoint.validateRules() }
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
            json["version"] = config.version + 1
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Script\""))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"script\""))
            try data.write(to: destination.appendingPathComponent(config.id + ".json"), options: .atomic)
            staged.append(json)
        }
        let bundle: [String: Any] = ["schema": 2, "sources": staged]
        try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
            .write(to: destination.appendingPathComponent("bundle.json"), options: .atomic)
        let index: [String: Any] = ["schema": 2, "bundleUrl": "bundle.json", "sources": staged.map { config in
            var item = config.filter { ["id", "name", "version", "icon", "color", "capabilities"].contains($0.key) }
            item["url"] = (config["id"] as? String ?? "") + ".json"
            return item
        }]
        try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("index.json"), options: .atomic)
        let stagedData = try Data(contentsOf: destination.appendingPathComponent("bundle.json"))
        try stagedData.write(to: root.appendingPathComponent("ScraperConfigs/1.json"), options: .atomic)
        configs = try JSONDecoder().decode(Bundle.self, from: stagedData).sources
        configs += ScraperConfig.builtInConfigs.filter { $0.id == "m8tec" }
        let runtimeData = ProcessInfo.processInfo.environment["PRIMUSE_LIVE_USE_PROTOCOL_PARAMETERS"] == "1"
            ? try? Data(contentsOf: evidence.appendingPathComponent("runtime-parameters.json")) : nil
        let runtimeParameters = runtimeData.flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        let selectedIDs = ProcessInfo.processInfo.environment["PRIMUSE_LIVE_SCRAPER_IDS"]?.components(separatedBy: ",")
        let remainingOnly = ProcessInfo.processInfo.environment["PRIMUSE_LIVE_SCRAPER_REMAINING"] == "1"
        if let selectedIDs { configs = configs.filter { selectedIDs.contains($0.id) } }
        let caseData = try? Data(contentsOf: evidence.appendingPathComponent("live-cases.json"))
        let cases = caseData.flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        var records: [[String: Any]] = []
        func failure(_ error: Error) -> String {
            let ns = error as NSError
            if case ScraperError.parseError(let message) = error { return "parseError: " + String(message.prefix(180)) }
            if case ScraperError.networkError(let message) = error,
               message.range(of: #"^(HTTP |Scraper API error |Response too large)"#, options: .regularExpression) != nil { return message }
            return "\(type(of: error)): \(ns.domain) (\(ns.code))"
        }
        for var config in configs {
            config.secrets = AppSecrets.scraperSecrets[config.id]
            config.secrets = (config.secrets ?? [:]).merging(runtimeParameters[config.id] ?? [:]) { _, runtime in runtime }
            let localParameters = root.appendingPathComponent("ScraperConfigs/\(config.id).secrets.json")
            if let data = try? Data(contentsOf: localParameters),
               let parameters = try? JSONDecoder().decode([String: String].self, from: data) {
                config.secrets = (config.secrets ?? [:]).merging(parameters) { _, local in local }
            }
            let scraper = ConfigurableScraper(config: config, requestPool: .init())
            var row: [String: Any] = ["source": config.id, "version": config.version]
            var selected: ScraperSearchItem?
            if config.search != nil {
                do {
                    let title = cases[config.id]?["title"] ?? "晴天"
                    let artist = cases[config.id]?["artist"] ?? "周杰伦"
                    let result = try await scraper.search(query: title, artist: artist, album: nil, limit: 5)
                    selected = ScraperManager.bestMatch(in: result.items, title: title, artist: artist, durationMs: nil)
                    row["identityMatched"] = selected != nil
                    row["candidates"] = result.items.prefix(5).map { ["title": $0.title, "artist": $0.artist ?? "", "album": $0.album ?? ""] }
                    XCTAssertNotNil(selected, config.id + " no confident identity match")
                    row["searchCount"] = result.items.count
                    row["selectedTitle"] = selected?.title
                    row["selectedArtist"] = selected?.artist
                    row["selectedTrackID"] = selected?.externalId.components(separatedBy: "|").first
                    XCTAssertFalse(result.isEmpty, config.id + " search returned no candidates")
                } catch { row["searchError"] = failure(error); XCTFail(config.id + " search: " + failure(error)) }
            }
            if let item = selected, !remainingOnly || ![ScraperJSONRule.Format.albumCatalogSearch, .hashCatalogSearch].contains(config.search?.rule?.format ?? .none) {
                do {
                    let detail = try await scraper.getDetail(externalId: item.externalId)
                    row["detail"] = detail?.title.isEmpty == false
                    XCTAssertFalse(detail?.title.isEmpty ?? true, config.id + " detail")
                } catch { row["detailError"] = failure(error); XCTFail(config.id + " detail: " + failure(error)) }
                do {
                    let covers = try await scraper.getCoverArt(externalId: item.externalId)
                    let cover = try XCTUnwrap(covers.first?.coverUrl, config.id + " cover URL")
                    let transport = ScraperSessionManager(headers: config.headers ?? [:], trustDomains: config.sslTrustDomains ?? [],
                        credentialOrigins: ScraperNetworkScope.credentialOrigins(config), isResource: true)
                    let (data, response) = try await transport.data(for: URLRequest(url: try XCTUnwrap(URL(string: cover))), maxBytes: ConfigurableScraper.maxResourceResponseBytes)
                    row["coverHTTP"] = (response as? HTTPURLResponse)?.statusCode
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, config.id + " cover HTTP")
                    row["coverBytes"] = data.count
                    row["coverDecodes"] = CGImageSourceCreateWithData(data as CFData, nil) != nil
                    XCTAssertTrue(row["coverDecodes"] as? Bool == true, config.id + " cover decode")
                } catch { row["coverError"] = failure(error); XCTFail(config.id + " cover: " + failure(error)) }
                if config.lyrics != nil {
                    do {
                        let lyrics = try await scraper.getLyrics(externalId: item.externalId)
                        let text = lyrics?.lrcContent ?? ""
                        row["lyricCharacters"] = text.count
                        row["wordTiming"] = text.contains("<00:") || WordTimedLyricsParser.detect(text) != nil
                        XCTAssertFalse(text.isEmpty, config.id + " lyrics")
                    } catch { row["lyricsError"] = failure(error); XCTFail(config.id + " lyrics: " + failure(error)) }
                }
            }
            if config.dynamicCover != nil {
                do {
                    let m8 = config.id == "m8tec"
                    let input = MotionArtworkLookupInput(albumArtist: m8 ? "Taylor Swift" : selected?.artist,
                        albumTitle: m8 ? "Midnights" : selected?.album, storefront: "us")
                    let result = try await scraper.motionArtwork(input: input, title: selected?.title,
                        trackArtist: selected?.artist, durationMs: selected?.durationMs, client: MotionArtworkEndpointClient())
                    switch result {
                    case .video(let bytes): row["dynamicCover"] = "decodedVideo"; row["dynamicBytes"] = bytes.count
                    case .downloaded: row["dynamicCover"] = "decodedAnimation"
                    case .notFound: row["dynamicCover"] = "notFound"
                    case .ambiguous: row["dynamicCover"] = "ambiguous"
                    case .unsupported: row["dynamicCover"] = "unsupported"
                    case .temporarilyUnavailable: row["dynamicCover"] = "temporarilyUnavailable"
                    }
                } catch { row["dynamicError"] = failure(error); XCTFail(config.id + " dynamic cover: " + failure(error)) }
            }
            records.append(row)
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent(remainingOnly ? "remaining-results.json" : "results.json"), options: .atomic)
            print("LIVE_SCRAPER_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }
    }

    func testNativeInstancesShareCooldownAndPreserveSchedulerSignal() async throws {
        for type in [MusicScraperType.musicBrainz, .itunes] {
            let id = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RateLimitedNativeProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel(); RateLimitedNativeProtocol.counts.remove(id) }
            let executor = RequestExecutor()
            let scrapers: [any MusicScraper] = type == .musicBrainz
                ? [MusicBrainzScraper(session: session, requestExecutor: executor),
                   MusicBrainzScraper(session: session, requestExecutor: executor)]
                : [ITunesScraper(session: session, requestExecutor: executor),
                   ITunesScraper(session: session, requestExecutor: executor)]
            for scraper in scrapers {
                do {
                    _ = try await scraper.search(query: "cooldown", artist: nil, album: nil, limit: 1)
                    XCTFail("Expected rate limiting")
                } catch ScraperError.rateLimited(let delay) {
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(delay), 3599)
                }
            }
            XCTAssertEqual(RateLimitedNativeProtocol.counts.count(id), 1)
        }
    }

    func testITunesForbiddenQuotaResponseDefersEverySharedCaller() async throws {
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForbiddenITunesProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ForbiddenITunesProtocol.counts.remove(id) }
        let executor = RequestExecutor(policy: ITunesScraper.servicePolicy)
        for scraper in [ITunesScraper(session: session, requestExecutor: executor),
                        ITunesScraper(session: session, requestExecutor: executor)] {
            do {
                _ = try await scraper.search(query: "quota", artist: nil, album: nil, limit: 1)
                XCTFail("Apple's 403 quota response must defer the source")
            } catch ScraperError.rateLimited(_) {}
        }
        XCTAssertEqual(ForbiddenITunesProtocol.counts.count(id), 1)
    }

    func testITunesServerFailureIsNotAnEmptySearchResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailedMusicBrainzProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ITunesScraper(session: session).search(
                query: "HTTP failure fixture", artist: nil, album: nil, limit: 1
            )
            XCTFail("HTTP 500 must remain a failure so callers can back off")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 500)
            XCTAssertEqual(failure.body, FailedMusicBrainzProtocol.body)
        }
    }

    func testMusicBrainzServerFailureIsNotAnEmptySearchResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailedMusicBrainzProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await MusicBrainzScraper(session: session).search(
                query: "HTTP failure fixture", artist: nil, album: nil, limit: 1
            )
            XCTFail("HTTP 500 must remain a failure so callers can back off")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 500)
            XCTAssertEqual(failure.body, FailedMusicBrainzProtocol.body)
        }
    }
}

private final class FailedMusicBrainzProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data(#"{"error":"Temporary server error","resultCount":0,"results":[]}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        ["musicbrainz.org", "itunes.apple.com"].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class NativeRequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ id: String) { lock.withLock { values[id, default: 0] += 1 } }
    func count(_ id: String) -> Int { lock.withLock { values[id, default: 0] } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
}

private final class RateLimitedNativeProtocol: URLProtocol, @unchecked Sendable {
    static let counts = NativeRequestCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.counts.increment(id)
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                       headerFields: ["Retry-After": "3600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ForbiddenITunesProtocol: URLProtocol, @unchecked Sendable {
    static let counts = NativeRequestCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.counts.increment(id)
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
