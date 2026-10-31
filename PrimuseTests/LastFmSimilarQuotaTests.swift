import Foundation
import XCTest
import PrimuseKit
@testable import Primuse
#if os(macOS)
import AppKit
import SwiftUI
import Vision
#endif

final class LastFmSimilarQuotaTests: XCTestCase {
    private var insightSubject: LibraryInsightSubject {
        .album(title: "A & B", artist: "Artist + Band", year: nil, genres: [], tracks: [])
    }

    #if os(macOS)
    @MainActor
    func testIntroEditorOffersAIFillSetupWithoutAConfiguredService() async throws {
        let (library, intelligence, _) = try makeInsightUIContext()
        XCTAssertFalse(intelligence.isLibraryInsightAvailable)
        XCTAssertFalse(intelligence.libraryInsightNeedsRemoteConsent)
        for subject in [insightSubject, .artist(name: "Artist", genres: [], albums: [], tracks: [])] {
            let view = LibraryInsightEditorSheet(subject: subject, details: { subject }, record: nil) {}
                .environment(library)
                .environment(intelligence)
            let text = try await insightText(in: view)
            XCTAssertTrue(text.contains(withoutSpaces(String(localized: "library_insight_ai_fill"))), text)
            XCTAssertTrue(text.contains(withoutSpaces(String(localized: "library_insight_lastfm_fetch"))), text)
            XCTAssertNil(LibraryInsightStore.shared.record(for: subject, in: library))
        }
    }

    @MainActor
    func testEmptyOrFailedLastFmFetchRetainsAIActionForAlbumsAndArtists() async throws {
        let (library, intelligence, directory) = try makeInsightUIContext()
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        let manager = SourceManager(sourcesProvider: { [] })
        for subject in [insightSubject, .artist(name: "Artist", genres: [], albums: [], tracks: [])] {
            for status in [200, 503] {
                let fixture = SimilarFixture(status: status, body: status == 200
                    ? #"{"error":6,"message":"Not found"}"# : "{}")
                let store = LibraryInsightStore(lastFm: fixture.api())
                let saved = await store.fetchLastFm(subject, library: library)
                XCTAssertFalse(saved)
                XCTAssertEqual(store.lastFmFailure(for: subject), status == 200
                    ? String(localized: "library_insight_lastfm_empty")
                    : String(localized: "library_insight_lastfm_failed"))
                let view = LibraryInsightSynopsis(subject: subject, details: { subject }, songs: { [] }, store: store)
                    .padding(16)
                    .background(Color.black)
                    .environment(library)
                    .environment(intelligence)
                    .environment(sources)
                    .environment(manager)
                let text = try await insightText(in: view, width: 320)
                XCTAssertTrue(text.contains(withoutSpaces(String(localized: "library_insight_generate"))), text)
                XCTAssertTrue(text.contains(withoutSpaces(String(localized: "library_insight_lastfm_fetch"))), text)
                XCTAssertNil(store.record(for: subject, in: library))
            }
        }
    }

    @MainActor
    private func makeInsightUIContext() throws -> (MusicLibrary, MusicIntelligenceService, URL) {
        let suite = "LibraryInsightUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let settings = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        let intelligence = MusicIntelligenceService(settingsStore: settings, recommendationReuseDefaults: defaults)
        let library = MusicLibrary(storageDirectory: directory)
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (library, intelligence, directory)
    }

    @MainActor
    private func insightText(in view: some View, width: CGFloat = 800) async throws -> String {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let screenshot = NSImage(size: host.bounds.size)
        screenshot.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Introduction actions"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage)).perform([request])
        return withoutSpaces((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined())
    }

    private func withoutSpaces(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    #endif

    func testInsightUsesAlbumAndArtistAndFallsBackToEnglishOnlyForMissingText() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"album":{"wiki":{"content":""}}}"#,
                                     englishBody: #"{"album":{"wiki":{"content":"English description"}}}"#)
        let result = try await fixture.api().libraryInsight(for: insightSubject, languageCode: "zh-Hans")
        XCTAssertEqual(result?.summary, "English description")
        let queries = fixture.requests.map { request in
            Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(queries.map { $0["lang"] }, ["zh", "en"])
        XCTAssertEqual(queries.first?["method"], "album.getInfo")
        XCTAssertEqual(queries.first?["album"], "A & B")
        XCTAssertEqual(queries.first?["artist"], "Artist + Band")
        XCTAssertNil(queries.first?["sk"])
    }

    func testInsightWithLocalizedTextDoesNotFetchEnglish() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"artist":{"bio":{"content":"本地语言简介"}}}"#)
        let subject = LibraryInsightSubject.artist(name: "Artist", genres: [], albums: [], tracks: [])
        let result = try await fixture.api().libraryInsight(for: subject, languageCode: "zh-Hans")
        XCTAssertEqual(result?.summary, "本地语言简介")
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testInsightMissingEntryIsNotAnErrorAndDoesNotRetryInAnotherLanguage() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"error":6,"message":"Album not found"}"#)
        let result = try await fixture.api().libraryInsight(for: insightSubject, languageCode: "zh-Hans")
        XCTAssertNil(result)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testInsightAndRecommendationsShareTheAPIKeyCooldown() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"error":29,"message":"Rate limit exceeded"}"#)
        do {
            _ = try await fixture.api().libraryInsight(for: insightSubject, languageCode: "zh-Hans")
            XCTFail("Expected a quota failure")
        } catch LastFmSimilarAPI.SimilarError.api(let code, _, _) { XCTAssertEqual(code, 29) }
        _ = try? await fixture.api().similarTracks(artist: "Artist", track: "Track")
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testFailedInsightFetchKeepsExistingRecordAndSuccessfulFetchPersistsAsImported() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let empty = SimilarFixture(status: 200, body: #"{"album":{"tags":{"tag":[{"name":"Rock"}]}}}"#)
        let store = LibraryInsightStore(lastFm: empty.api())
        store.saveEdit(insightSubject, summary: "My introduction", tags: ["Jazz"], aiDraft: nil, library: library)
        let before = store.record(for: insightSubject, in: library)
        let savedEmpty = await store.fetchLastFm(insightSubject, library: library)
        XCTAssertFalse(savedEmpty)
        XCTAssertEqual(store.record(for: insightSubject, in: library), before)
        XCTAssertNotNil(store.lastFmFailure(for: insightSubject))

        let success = SimilarFixture(status: 200, body: #"{"album":{"wiki":{"content":"Imported introduction"},"tags":{"tag":[{"name":"Pop"}]}}}"#)
        let importing = LibraryInsightStore(lastFm: success.api())
        let saved = await importing.fetchLastFm(insightSubject, library: library)
        XCTAssertTrue(saved)
        let record = try XCTUnwrap(importing.record(for: insightSubject, in: library))
        XCTAssertEqual(record.summary, "Imported introduction")
        XCTAssertEqual(record.importedFrom, "Last.fm")
        XCTAssertNotNil(record.importedURL)
        XCTAssertFalse(record.isUserEdited)
        XCTAssertNil(record.aiProviderName)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Could not persist") }
        let reopened = MusicLibrary(storageDirectory: directory)
        let persisted = try XCTUnwrap(importing.record(for: insightSubject, in: reopened))
        XCTAssertEqual(persisted.summary, record.summary)
        XCTAssertEqual(persisted.tags, record.tags)
        XCTAssertEqual(persisted.importedFrom, record.importedFrom)
        XCTAssertEqual(persisted.importedURL, record.importedURL)
        XCTAssertFalse(persisted.isUserEdited)
    }

    @MainActor
    func testInsightResponseDoesNotOverwriteAnEditMadeDuringTheRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let subject = insightSubject
        let fixture = SimilarFixture(
            status: 200, body: #"{"album":{"wiki":{"content":"Fetched description"}}}"#,
            beforeReply: { @MainActor in
                LibraryInsightStore().saveEdit(subject, summary: "New manual edit", tags: [], aiDraft: nil, library: library)
            }
        )
        let store = LibraryInsightStore(lastFm: fixture.api())
        let saved = await store.fetchLastFm(subject, library: library)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.record(for: subject, in: library)?.summary, "New manual edit")
        XCTAssertEqual(store.record(for: subject, in: library)?.isUserEdited, true)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Could not persist") }
    }

    @MainActor
    func testCancelledInsightFetchDoesNotSaveOrLeaveTheSubjectBusy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let fixture = SimilarFixture(status: 0)
        let store = LibraryInsightStore(lastFm: fixture.api())
        let subject = insightSubject
        let task = Task { await store.fetchLastFm(subject, library: library) }
        for _ in 0..<200 {
            if !fixture.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.isFetchingLastFm(subject))
        XCTAssertFalse(store.beginBatchGeneration(subject))
        task.cancel()
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertNil(store.record(for: subject, in: library))
        XCTAssertNil(store.lastFmFailure(for: subject))
        XCTAssertFalse(store.isGenerating(subject))
        XCTAssertFalse(store.isFetchingLastFm(subject))
    }

    func testBusinessRateLimitIsNotCachedAsEmptyRecommendations() async throws {
        for status in [200, 400, 403, 503] {
            let fixture = SimilarFixture(status: status, body: #"{"error":29,"message":"Rate limit exceeded"}"#)
            let service = fixture.service()
            for _ in 0..<2 {
                do { _ = try await service.fetchSimilar(to: seed, library: []); XCTFail("A business failure is not a successful empty list") }
                catch { }
            }
            XCTAssertEqual(fixture.requests.count, 1, "HTTP \(status): track and artist lookups share a business cooldown")
        }
    }

    func testHTTPThrottleDoesNotFallBackToArtist() async throws {
        let fixture = SimilarFixture(status: 429, headers: ["Retry-After": "3600"])
        do { _ = try await fixture.service().fetchSimilar(to: seed, library: []); XCTFail("Expected throttling") }
        catch { }
        XCTAssertEqual(fixture.requests.count, 1, "Fallback must not spend a cooling quota")
    }

    func testHTTPStatusAndFullDateCooldownArePreservedAcrossServices() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for status in [429, 503] {
            let fixture = SimilarFixture(status: status, headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(172800))])
            for _ in 0..<2 {
                do { _ = try await fixture.service().fetchSimilar(to: seed, library: []); XCTFail("Expected throttle") }
                catch let failure as HTTPResponseFailure {
                    XCTAssertEqual(failure.statusCode, status)
                    XCTAssertGreaterThan(failure.retryAfter ?? 0, 172790)
                }
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testBusinessQuotaOnHTTP400SharesTheCooldown() async throws {
        let fixture = SimilarFixture(status: 400, body: #"{"error":29,"message":"Rate limit exceeded"}"#)
        do { _ = try await fixture.api().similarTracks(artist: "Artist", track: "Seed"); XCTFail("Expected the business quota") }
        catch LastFmSimilarAPI.SimilarError.api(let code, _, let response) {
            XCTAssertEqual(code, 29)
            XCTAssertEqual(response.statusCode, 400)
            XCTAssertTrue(response.isRateLimitFailure)
            XCTAssertGreaterThan(response.retryAfter ?? 0, 0)
        }
        do { _ = try await fixture.api().similarArtistTracks(artist: "Artist"); XCTFail("Artist fallback bypassed the quota") }
        catch let failure as HTTPResponseFailure { XCTAssertTrue(failure.isRateLimitFailure) }
        catch LastFmSimilarAPI.SimilarError.api(let code, _, _) { XCTAssertEqual(code, 29) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testTrackAndArtistClientsSpendTheSameAPIKeyQuota() async throws {
        let fixture = SimilarFixture(status: 429, headers: ["Retry-After": "3600"])
        _ = try? await fixture.api().similarTracks(artist: "Artist", track: "Seed")
        do { _ = try await fixture.api().similarArtistTracks(artist: "Artist"); XCTFail("Artist lookup must share the track cooldown") }
        catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testBusinessErrorRetainsCodeMessageAndHTTPResponse() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for status in [200, 400, 503] {
            for header in [nil, "86400", formatter.string(from: Date().addingTimeInterval(86400))] as [String?] {
                let fixture = SimilarFixture(status: status, headers: header.map { ["Retry-After": $0] } ?? [:],
                    body: #"{"error":29,"message":"Rate limit exceeded"}"#)
                do { _ = try await fixture.api().similarTracks(artist: "Artist", track: "Seed"); XCTFail("Expected business error") }
                catch LastFmSimilarAPI.SimilarError.api(let code, let message, let response) {
                    XCTAssertEqual(code, 29); XCTAssertEqual(message, "Rate limit exceeded")
                    XCTAssertEqual(response.statusCode, status); XCTAssertTrue(response.isRateLimited)
                    XCTAssertGreaterThan(response.retryAfter ?? 0, header == nil ? 0 : 86390)
                }
                do { _ = try await fixture.api().similarArtistTracks(artist: "Artist"); XCTFail("Artist bypassed the same API-key quota") }
                catch let failure as HTTPResponseFailure { XCTAssertTrue(failure.isRateLimited) }
                catch LastFmSimilarAPI.SimilarError.api(_, _, let response) { XCTAssertTrue(response.isRateLimited) }
                XCTAssertEqual(fixture.requests.count, 1)
                // The common admission boundary used by other Last.fm features
                // must see the recommendation-established application-key quota.
                let quota = RequestQuota(service: .lastFM,
                    url: URL(string: "https://ws.audioscrobbler.com/2.0/")!, account: .init(stableID: fixture.key))!
                do {
                    _ = try await fixture.registry.execute(for: quota, replay: .never, operation: {
                        XCTFail("Another Last.fm entry bypassed recommendation cooldown"); return true
                    })
                } catch let failure as HTTPResponseFailure { XCTAssertTrue(failure.isRateLimited) }
            }
        }
    }

    func testNonQuotaBusinessErrorsKeepTheirCodeWithoutInventingCooldown() async throws {
        let fixture = SimilarFixture(status: 400, body: #"{"error":6,"message":"Invalid parameters"}"#)
        for _ in 0..<2 {
            do { _ = try await fixture.api().similarTracks(artist: "Artist", track: "Seed"); XCTFail("Expected business rejection") }
            catch LastFmSimilarAPI.SimilarError.api(let code, _, let response) {
                XCTAssertEqual(code, 6); XCTAssertEqual(response.statusCode, 400)
                XCTAssertFalse(response.isRateLimitFailure); XCTAssertNil(response.retryAfter)
            }
        }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testSuccessfulEmptyResponsesAreCachedAfterArtistFallback() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"similartracks":{"track":[]},"similarartists":{"artist":[]}}"#)
        let service = fixture.service()
        for _ in 0..<2 {
            let result = try await service.fetchSimilar(to: seed, library: [])
            XCTAssertTrue(result.isEmpty)
        }
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertTrue(fixture.requests[1].url!.absoluteString.contains("artist.getSimilar"))
    }

    func testValidCandidatesAndMatchingArePreserved() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"similartracks":{"track":[{"name":"Result","artist":{"name":"Artist"},"match":"0.9","url":"https://www.last.fm/music/fixture"}]}}"#)
        var song = seed; song.id = "result"; song.title = "Result"
        let service = fixture.service()
        let result = try await service.fetchSimilar(to: seed, library: [song])
        XCTAssertEqual(result.first?.librarySong?.id, "result")
        XCTAssertEqual(result.first?.match, 0.9)
        _ = try await service.fetchSimilar(to: seed, library: [song])
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMalformedAndPermanentBusinessFailuresAreNotCached() async throws {
        for body in ["{}", #"{"error":6,"message":"Invalid parameters"}"#] {
            let fixture = SimilarFixture(status: 200, body: body)
            let service = fixture.service()
            for _ in 0..<2 {
                do { _ = try await service.fetchSimilar(to: seed, library: []); XCTFail("Failure must not become empty content") }
                catch { }
            }
            XCTAssertEqual(fixture.requests.count, 4)
            XCTAssertEqual(fixture.requests.map { $0.url!.absoluteString.contains("track.getSimilar") }, [true, false, true, false])
        }
    }

    func testUnknownTrackStillFallsBackToSimilarArtists() async throws {
        let fixture = SimilarFixture(
            status: 200,
            body: #"{"error":6,"message":"Track not found"}"#,
            artistBody: #"{"similarartists":{"artist":[{"name":"Neighbour","match":"0.8"}]}}"#
        )
        let service = fixture.service()
        for _ in 0..<2 {
            let result = try await service.fetchSimilar(to: seed, library: [], includeUnmatched: true)
            XCTAssertEqual(result.map(\.artist), ["Neighbour"])
        }
        XCTAssertEqual(fixture.requests.count, 2, "The artist result is cached like any successful lookup")
        XCTAssertTrue(fixture.requests[1].url!.absoluteString.contains("artist.getSimilar"))
    }

    func testFailedArtistFallbackDoesNotCacheAnEmptyTrackResult() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"similartracks":{"track":[]}}"#)
        let service = fixture.service()
        for _ in 0..<2 {
            do { _ = try await service.fetchSimilar(to: seed, library: []); XCTFail("Malformed artist response must remain a failure") }
            catch { }
        }
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testDifferentAPIKeysKeepIndependentQuotas() async throws {
        for status in [429, 400] {
            let registry = RequestQuotaRegistry()
            let first = SimilarFixture(status: status, headers: ["Retry-After": "3600"],
                body: #"{"error":29}"#, registry: registry)
            let second = SimilarFixture(status: 200, body: #"{"similartracks":{"track":[]},"similarartists":{"artist":[]}}"#, registry: registry)
            _ = try? await first.service().fetchSimilar(to: seed, library: [])
            let result = try await second.service().fetchSimilar(to: seed, library: [])
            XCTAssertTrue(result.isEmpty); XCTAssertEqual(second.requests.count, 2)
        }
    }

    func testCancelledRequestDoesNotStartFallback() async throws {
        let fixture = SimilarFixture(status: 0)
        let service = fixture.service()
        let seed = seed
        let done = expectation(description: "Cancelled promptly")
        let task = Task {
            defer { done.fulfill() }
            do { _ = try await service.fetchSimilar(to: seed, library: []); XCTFail("Expected cancellation") }
            catch is CancellationError { }
            catch { XCTFail("Cancellation lost: \(error)") }
        }
        for _ in 0..<200 {
            if !fixture.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.requests.count, 1)
        task.cancel()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    private var seed: Song {
        Song(id: "seed", title: "Seed", artistName: "Artist", duration: 1,
             fileFormat: .mp3, filePath: "seed.mp3", sourceID: "fixture", fileSize: 1)
    }
}

private final class SimilarFixture: @unchecked Sendable {
    let key = UUID().uuidString
    let status: Int
    let headers: [String: String]
    let body: Data
    let artistBody: Data?
    let englishBody: Data?
    let beforeReply: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    let registry: RequestQuotaRegistry
    lazy var session: URLSession = {
        SimilarProtocol.lock.withLock { SimilarProtocol.fixtures[key] = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SimilarProtocol.self]
        return URLSession(configuration: config)
    }()
    init(status: Int, headers: [String: String] = [:], body: String = "{}", artistBody: String? = nil, englishBody: String? = nil,
         beforeReply: (@Sendable () async -> Void)? = nil,
         registry: RequestQuotaRegistry = RequestQuotaRegistry()) {
        self.registry = registry
        self.status = status; self.headers = headers; self.body = Data(body.utf8)
        self.artistBody = artistBody.map { Data($0.utf8) }
        self.englishBody = englishBody.map { Data($0.utf8) }
        self.beforeReply = beforeReply
    }
    func body(for request: URLRequest) -> Data {
        if let englishBody,
           URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "lang" && $0.value == "en" }) == true {
            return englishBody
        }
        guard let artistBody, request.url!.absoluteString.contains("artist.getSimilar") else { return body }
        return artistBody
    }
    func api() -> LastFmSimilarAPI {
        let key = key
        return LastFmSimilarAPI(apiKey: { key }, session: session, quotaRegistry: registry)
    }
    func service() -> SimilarTracksService { SimilarTracksService(api: api()) }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
}

private final class SimilarProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixtures: [String: SimilarFixture] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "api_key" }?.value ?? ""
        guard let fixture = Self.lock.withLock({ Self.fixtures[key] }) else { return }
        fixture.record(request)
        if fixture.status == 0 { return }
        if let beforeReply = fixture.beforeReply {
            Task { @Sendable [self, fixture, beforeReply] in
                await beforeReply()
                reply(with: fixture)
            }
        } else {
            reply(with: fixture)
        }
    }
    private func reply(with fixture: SimilarFixture) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: nil, headerFields: fixture.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body(for: request))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
