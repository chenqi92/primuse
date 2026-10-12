import Foundation
import XCTest
import PrimuseKit
@testable import Primuse

final class ExternalPlaylistQuotaTests: XCTestCase {
    private let netEase = "https://music.163.com/playlist?id=123"
    private let qq = "https://y.qq.com/n/ryqq/playlist/123"
    private let youtube = "https://www.youtube.com/playlist?list=PLfixture"

    func testPermanentHTTPFailuresAreNotReplayed() async throws {
        for status in [400, 401, 403, 404] {
            let fixture = PlaylistFixture([.init(status: status)])
            do { _ = try await fixture.fetcher().fetch(sharedText: netEase); XCTFail("Expected failure") }
            catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, status) }
            XCTAssertEqual(fixture.requests.count, 1, "HTTP \(status) must not be replayed")
        }
    }

    func testFailedShortLinkDoesNotStartPlaylistImport() async throws {
        let fixture = PlaylistFixture([.init(status: 503, headers: ["Retry-After": "3600"], responseURL: URL(string: netEase))])
        do { _ = try await fixture.fetcher().fetch(sharedText: "https://163cn.tv/fixture"); XCTFail("Expected failure") }
        catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 503); XCTAssertEqual(failure.retryAfter, 3600)
        }
        XCTAssertEqual(fixture.requests.count, 1, "A failed redirect must not be consumed as a playlist URL")
    }

    func testFullNumericAndDateCooldownSurvivesNewImporterInstances() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for header in ["172800", formatter.string(from: Date().addingTimeInterval(172800))] {
            let fixture = PlaylistFixture([.init(status: 429, headers: ["Retry-After": header])])
            for id in [123, 456] {
                do { _ = try await fixture.fetcher().fetch(sharedText: "https://music.163.com/playlist?id=\(id)"); XCTFail("Expected quota failure") }
                catch let failure as HTTPResponseFailure {
                    XCTAssertEqual(failure.statusCode, 429); XCTAssertGreaterThan(failure.retryAfter ?? 0, 172790)
                }
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testIndependentPlaylistHostsKeepSeparateQuotas() async throws {
        let fixture = PlaylistFixture([.init(status: 429, headers: ["Retry-After": "3600"]), .init(body: qqPage("one", total: 1))])
        _ = try? await fixture.fetcher().fetch(sharedText: netEase)
        let playlist = try await fixture.fetcher().fetch(sharedText: qq)
        XCTAssertEqual(playlist.tracks.map(\.title), ["one"])
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testTransientFailureRecoversWithinBoundedBudget() async throws {
        let fixture = PlaylistFixture([.init(status: 502), .init(body: qqPage("one", total: 1))])
        let playlist = try await fixture.fetcher().fetch(sharedText: qq)
        XCTAssertEqual(playlist.tracks.map(\.title), ["one"])
        XCTAssertEqual(fixture.requests.count, 2)
        let exhausted = PlaylistFixture([.init(status: 500)])
        do { _ = try await exhausted.fetcher().fetch(sharedText: qq); XCTFail("Expected finite retry failure") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 500) }
        XCTAssertEqual(exhausted.requests.count, 2)
    }

    func testPaginationPreservesOrderAndStopsWhenComplete() async throws {
        let fixture = PlaylistFixture([.init(body: qqPage("one")), .init(body: qqPage("two"))])
        let playlist = try await fixture.fetcher().fetch(sharedText: qq)
        XCTAssertEqual(playlist.name, "Fixture")
        XCTAssertEqual(playlist.tracks.map(\.title), ["one", "two"])
        XCTAssertEqual(fixture.requests.count, 2)
        let items = URLComponents(url: fixture.requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "song_begin" }?.value, "1")
    }

    func testPaginationThrottleIsNotRetriedOrReturnedAsComplete() async throws {
        let fixture = PlaylistFixture([.init(body: qqPage("one")), .init(status: 429, headers: ["Retry-After": "3600"])])
        do { _ = try await fixture.fetcher().fetch(sharedText: qq); XCTFail("Expected page failure") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.retryAfter, 3600) }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testReadOnlyYouTubePOSTExplicitlyReplaysAndKeepsBody() async throws {
        let fixture = PlaylistFixture([.init(body: youtubePage), .init(status: 502), .init(body: "{\"items\":[\(youtubeItem("two"))]}")])
        let playlist = try await fixture.fetcher().fetch(sharedText: youtube)
        XCTAssertEqual(playlist.tracks.map(\.title), ["one", "two"])
        XCTAssertFalse(playlist.isPartial)
        XCTAssertEqual(fixture.requests.map(\.httpMethod), ["GET", "POST", "POST"])
        XCTAssertEqual(fixture.bodies[1], fixture.bodies[2])
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixture.bodies[1]) as? [String: Any])
        XCTAssertEqual(payload["continuation"] as? String, "NEXT")
    }

    func testYouTubeThrottleRetainsRetryAfterInsteadOfSilentPartialSuccess() async throws {
        let fixture = PlaylistFixture([.init(body: youtubePage), .init(status: 503, headers: ["Retry-After": "3600"])])
        do { _ = try await fixture.fetcher().fetch(sharedText: youtube); XCTFail("Expected throttling") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.retryAfter, 3600) }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testOptionalPlaylistNameCannotSwallowCancellationOrCooldown() async throws {
        let page = #"{"code":0,"data":{"totalSize":1,"data":[{"id":1,"title":"Song","author":"Artist","duration":120}]}}"#
        for reply in [PlaylistReply(status: 429, headers: ["Retry-After": "3600"]), PlaylistReply(error: .init(.cancelled))] {
            let fixture = PlaylistFixture([.init(body: page), reply])
            do { _ = try await fixture.fetcher().fetch(sharedText: "https://www.bilibili.com/audio/am123"); XCTFail("Expected name request failure") }
            catch is CancellationError { XCTAssertNotNil(reply.error) }
            catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 429) }
            XCTAssertEqual(fixture.requests.count, 2)
        }
    }

    func testCancelledTransportIsNotReplayed() async throws {
        let fixture = PlaylistFixture([.init(error: .init(.cancelled))])
        do { _ = try await fixture.fetcher().fetch(sharedText: netEase); XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testTaskCancellationStopsRequestAndPaginationPromptly() async throws {
        let fixture = PlaylistFixture([.init(body: qqPage("one")), .init(status: 0)])
        let fetcher = fixture.fetcher()
        let link = qq
        let done = expectation(description: "Import cancelled promptly")
        let task = Task {
            defer { done.fulfill() }
            do { _ = try await fetcher.fetch(sharedText: link); XCTFail("Expected cancellation") }
            catch is CancellationError { }
            catch { XCTFail("Cancellation lost: \(error)") }
        }
        for _ in 0..<200 {
            if fixture.requests.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.requests.count, 2)
        task.cancel()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    private func qqPage(_ title: String, total: Int = 2) -> String {
        "{\"cdlist\":[{\"dissname\":\"Fixture\",\"total_song_num\":\(total),\"songlist\":[{\"songname\":\"\(title)\",\"singer\":[{\"name\":\"Artist\"}]}]}]}"
    }
    private func youtubeItem(_ title: String) -> String {
        "{\"lockupViewModel\":{\"contentId\":\"\(title)\",\"metadata\":{\"lockupMetadataViewModel\":{\"title\":{\"content\":\"\(title)\"}}}}}"
    }
    private var youtubePage: String {
        "<title>Fixture - YouTube</title><script>var ytInitialData = {\"items\":[\(youtubeItem("one")),{\"continuationItemViewModel\":{\"continuationCommand\":{\"token\":\"NEXT\"}}}]};</script><script>ytcfg.set({\"INNERTUBE_CLIENT_VERSION\":\"2.fixture\"})</script>"
    }
}

private struct PlaylistReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = "{}"
    var responseURL: URL? = nil
    var error: URLError? = nil
}

private final class PlaylistFixture: @unchecked Sendable {
    let key = UUID().uuidString
    let replies: [PlaylistReply]
    let registry = RequestQuotaRegistry()
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var recordedBodies: [Data] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    var bodies: [Data] { lock.withLock { recordedBodies } }
    lazy var session: URLSession = {
        PlaylistProtocol.lock.withLock { PlaylistProtocol.fixtures[key] = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaylistProtocol.self]
        config.httpAdditionalHeaders = ["X-Fixture-ID": key]
        return URLSession(configuration: config)
    }()
    init(_ replies: [PlaylistReply]) { self.replies = replies }
    func fetcher() -> ExternalPlaylistFetcher { .init(session: session, quotaRegistry: registry) }
    func record(_ request: URLRequest) -> PlaylistReply {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        return lock.withLock {
            let reply = replies[min(recorded.count, replies.count - 1)]
            recorded.append(request); recordedBodies.append(body)
            return reply
        }
    }
}

private final class PlaylistProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixtures: [String: PlaylistFixture] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: "X-Fixture-ID"), let fixture = Self.lock.withLock({ Self.fixtures[key] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let reply = fixture.record(request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        if reply.status == 0 { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: reply.responseURL ?? request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
