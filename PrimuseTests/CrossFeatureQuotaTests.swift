import Foundation
import XCTest
import PrimuseKit
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class CrossFeatureQuotaTests: XCTestCase {
    #if !os(tvOS)
    @MainActor
    func testPodcastCooldownAlsoDefersUpdateChecks() async throws {
        let registry = RequestQuotaRegistry()
        let fixture = CatalogQuotaFixture { _ in (429, ["Retry-After": "3600"], Data()) }
        let suite = "QuotaTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try? await PodcastNetwork.json(from: URL(string: "https://itunes.apple.com/search?entity=podcast")!, session: fixture.session, quotaRegistry: registry)
        let checker = AppUpdateChecker(defaults: defaults, session: fixture.session, quotaRegistry: registry)
        await checker.checkForUpdate(force: true)
        XCTAssertNotNil(checker.lastErrorMessage)
        XCTAssertNil(checker.lastCheckedAt, "A deferred lookup must not count as a successful update check")
        XCTAssertEqual(fixture.requests.count, 1, "Storefront fallback must spend the same catalog quota")
    }

    @MainActor
    func testUpdateQuotaDefersOtherFeaturesWithoutCachingAnEmptySuccess() async throws {
        let registry = RequestQuotaRegistry()
        let fixture = CatalogQuotaFixture { _ in
            (503, ["Retry-After": "3600"], Data(#"{"results":[]}"#.utf8))
        }
        let suite = "QuotaTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = AppUpdateChecker(defaults: defaults, session: fixture.session, quotaRegistry: registry)
        await checker.checkForUpdate(force: true)
        XCTAssertNotNil(checker.lastErrorMessage)
        XCTAssertNil(checker.lastCheckedAt)
        _ = try? await PodcastNetwork.json(from: URL(string: "https://itunes.apple.com/search?entity=podcast")!, session: fixture.session, quotaRegistry: registry)
        let scraper = ITunesScraper(session: fixture.session, quotaRegistry: registry)
        do { _ = try await scraper.getDetail(externalId: "123"); XCTFail("Update lookup's cooldown must protect metadata detail") }
        catch ScraperError.rateLimited(let delay) { XCTAssertGreaterThan(delay ?? 0, 3590) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testSuccessfulUpdateLookupRetainsVersionAndStorefrontSelection() async throws {
        let registry = RequestQuotaRegistry()
        #if os(macOS)
        let kind = "mac-software"
        #else
        let kind = "software"
        #endif
        let fixture = CatalogQuotaFixture { request in
            let regional = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "country" } == true
            let body = try! JSONSerialization.data(withJSONObject: ["results": [[
                "version": regional ? "98.0" : "99.0", "kind": kind,
                "trackViewUrl": regional ? "https://apps.apple.com/local/id123" : "https://apps.apple.com/default/id123"
            ]]])
            return (200, [:], body)
        }
        let suite = "QuotaTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = AppUpdateChecker(defaults: defaults, session: fixture.session, quotaRegistry: registry)
        await checker.checkForUpdate(force: true)
        XCTAssertNil(checker.lastErrorMessage)
        XCTAssertNotNil(checker.lastCheckedAt)
        XCTAssertEqual(checker.latestStoreVersion, "99.0")
        let hadRegion = fixture.requests.contains { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "country" } == true }
        XCTAssertEqual(checker.storeURL?.path, hadRegion ? "/local/id123" : "/default/id123")
        let before = fixture.requests.count
        await checker.checkForUpdate()
        XCTAssertEqual(fixture.requests.count, before, "Successful checks retain the daily application throttle")
    }

    @MainActor
    func testAutomaticUpdateCheckWaitsForAUsableNetwork() async throws {
        let registry = RequestQuotaRegistry()
        let fixture = CatalogQuotaFixture { _ in (200, [:], Data(#"{"results":[]}"#.utf8)) }
        let suite = "QuotaTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = AppUpdateChecker(
            defaults: defaults,
            session: fixture.session,
            quotaRegistry: registry,
            automaticCheckIsAllowed: { false }
        )
        await checker.checkForUpdate()
        XCTAssertEqual(fixture.requests.count, 0, "Without network access every request makes iOS show its data-access alert again")
        XCTAssertNil(checker.lastCheckedAt)
        await checker.checkForUpdate(force: true, userInitiated: true)
        XCTAssertGreaterThan(fixture.requests.count, 0, "A check the user asks for still goes out")
    }

    @MainActor
    func testFailedAutomaticUpdateCheckIsNotRepeatedOnEveryForeground() async throws {
        let registry = RequestQuotaRegistry()
        let fixture = CatalogQuotaFixture { _ in (200, [:], Data("not json".utf8)) }
        let suite = "QuotaTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = AppUpdateChecker(
            defaults: defaults,
            session: fixture.session,
            quotaRegistry: registry,
            automaticCheckIsAllowed: { true }
        )
        await checker.checkForUpdate()
        XCTAssertNotNil(checker.lastErrorMessage)
        XCTAssertNil(checker.lastCheckedAt)
        let afterFailure = fixture.requests.count
        XCTAssertGreaterThan(afterFailure, 0)
        await checker.checkForUpdate()
        XCTAssertEqual(fixture.requests.count, afterFailure, "Coming back to the foreground right after a failed check must not ask again")
        await checker.checkForUpdate(force: true)
        XCTAssertGreaterThan(fixture.requests.count, afterFailure, "A forced check ignores the automatic retry wait")
    }
    #endif

    func testPodcastQuotaDefersMetadataLookups() async throws {
        let registry = RequestQuotaRegistry()
        let fixture = CatalogQuotaFixture { _ in
            (429, ["Retry-After": "3600"], Data())
        }
        _ = try? await PodcastNetwork.json(from: URL(string: "https://itunes.apple.com/search?entity=podcast")!, session: fixture.session, quotaRegistry: registry)
        _ = try? await ITunesScraper(session: fixture.session, quotaRegistry: registry).search(query: "fixture", artist: nil, album: nil, limit: 1)
        XCTAssertEqual(fixture.requests.count, 1, "Metadata must respect the same catalog quota as podcast search")
    }

    func testMetadataQuotaIncludingHeaderless403DefersPodcastDirectory() async throws {
        for status in [403, 429, 503] {
            let registry = RequestQuotaRegistry()
            let fixture = CatalogQuotaFixture { _ in
                (status, status == 403 ? [:] : ["Retry-After": "3600"], Data())
            }
            let scraper = ITunesScraper(session: fixture.session, quotaRegistry: registry)
            _ = try? await scraper.search(query: "fixture", artist: nil, album: nil, limit: 1)
            let cooling = await scraper.isCoolingDown()
            XCTAssertTrue(cooling)
            do {
                _ = try await PodcastNetwork.json(from: URL(string: "https://itunes.apple.com/lookup?id=123&entity=podcast")!, session: fixture.session, quotaRegistry: registry)
                XCTFail("Podcast lookup must inherit Apple's quota status policy")
            } catch PodcastNetwork.Failure.httpStatus(let code, let remaining) {
                XCTAssertEqual(code, status)
                XCTAssertGreaterThan(remaining ?? 0, status == 403 ? 20 : 3590)
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testUnrelatedAssetsDoNotInheritCatalog403OrItsCooldown() async throws {
        let registry = RequestQuotaRegistry()
        let fixture = CatalogQuotaFixture { request in
            if request.url?.host == "itunes.apple.com" { return (429, ["Retry-After": "3600"], Data()) }
            return request.url?.path == "/denied" ? (403, [:], Data()) : (200, [:], Data("asset".utf8))
        }
        _ = try? await ITunesScraper(session: fixture.session, quotaRegistry: registry).getDetail(externalId: "123")
        do {
            _ = try await PodcastNetwork.json(from: URL(string: "https://assets.invalid/denied")!, session: fixture.session, quotaRegistry: registry)
            XCTFail("Expected an ordinary asset permission failure")
        } catch PodcastNetwork.Failure.httpStatus(let code, _) { XCTAssertEqual(code, 403) }
        let data = try await PodcastNetwork.json(from: URL(string: "https://assets.invalid/allowed")!, session: fixture.session, quotaRegistry: registry)
        XCTAssertEqual(data, Data("asset".utf8))
        XCTAssertEqual(fixture.requests.count, 3)
    }
}

private final class CatalogQuotaFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    let id = UUID().uuidString
    let handler: Handler
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    lazy var session: URLSession = {
        CatalogQuotaProtocol.register(self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogQuotaProtocol.self]
        config.httpAdditionalHeaders = ["X-Quota-Fixture": id]
        return URLSession(configuration: config)
    }()
    init(_ handler: @escaping Handler) { self.handler = handler }
    func response(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock { captured.append(request) }
        return handler(request)
    }
}

private final class CatalogQuotaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: CatalogQuotaFixture] = [:]
    static func register(_ fixture: CatalogQuotaFixture) { lock.withLock { fixtures[fixture.id] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let fixture = Self.lock.withLock({ Self.fixtures[request.value(forHTTPHeaderField: "X-Quota-Fixture") ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let (status, headers, body) = fixture.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
