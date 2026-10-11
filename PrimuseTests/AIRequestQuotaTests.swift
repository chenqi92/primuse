import Foundation
import PrimuseKit
import XCTest
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class AIRequestQuotaTests: XCTestCase {
    func testModelsGenerationStreamingAndEmbeddingsShareQuotaAcrossInstances() async throws {
        for status in [429, 503] {
            let host = UUID().uuidString.lowercased() + ".invalid"
            AIQuotaProtocol.configure(host, status: status)
            let (first, firstSession) = provider(host)
            let (second, secondSession) = provider(host)
            defer { firstSession.invalidateAndCancel(); secondSession.invalidateAndCancel() }
            await expectFailure { _ = try await first.listModels() }
            await expectFailure { _ = try await second.translateLyrics(self.candidates, targetLanguageCode: "zh") }
            await expectFailure { _ = try await second.translateLyrics(self.candidates, targetLanguageCode: "zh", onTranslation: { _, _ in XCTFail("No output on quota rejection") }) }
            await expectFailure { _ = try await second.embeddings(.init(texts: ["music"])) }
            XCTAssertEqual(AIQuotaProtocol.requests(host).count, 1, "Every entry point shares the server deadline")
        }
    }

    func testStreamQuotaDoesNotTriggerBufferedRetryOrModelRequest() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        AIQuotaProtocol.configure(host, status: 429, retryAfter: formatter.string(from: Date().addingTimeInterval(3600)))
        let (provider, session) = provider(host)
        defer { session.invalidateAndCancel() }
        await expectFailure { _ = try await provider.translateLyrics(self.candidates, targetLanguageCode: "zh", onTranslation: { _, _ in XCTFail("No output") }) }
        await expectFailure { _ = try await provider.listModels() }
        XCTAssertEqual(AIQuotaProtocol.requests(host).count, 1)
    }

    func testDifferentCredentialsDoNotShareQuotaAndPermanentFailuresDoNotRetry() async throws {
        for status in [429, 403, 404] {
            let host = UUID().uuidString.lowercased() + ".invalid"
            AIQuotaProtocol.configure(host, status: status, retryAfter: status == 429 ? "3600" : nil)
            for key in ["fixture-a", "fixture-b"] {
                let (provider, session) = provider(host, key: key)
                defer { session.invalidateAndCancel() }
                await expectFailure { _ = try await provider.listModels() }
            }
            XCTAssertEqual(AIQuotaProtocol.requests(host).count, 2)
        }
    }

    func testUnknownGenerationOutcomeIsNeverReplayed() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        AIQuotaProtocol.configure(host, status: 500, retryAfter: nil)
        let (provider, session) = provider(host)
        defer { session.invalidateAndCancel() }
        await expectFailure { _ = try await provider.translateLyrics(self.candidates, targetLanguageCode: "zh") }
        XCTAssertEqual(AIQuotaProtocol.requests(host).count, 1)
    }

    func testPartiallyProducedStreamDoesNotReplayAfterAnErrorEvent() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let delta = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": "{\"translations\":["]]]])
        let body = "data: " + String(decoding: delta, as: UTF8.self) + "\n\ndata: {\"error\":{\"message\":\"upstream failed\"}}\n\n"
        AIQuotaProtocol.configure(host, status: 200, retryAfter: nil, body: body, contentType: "text/event-stream")
        let (provider, session) = provider(host)
        defer { session.invalidateAndCancel() }
        await expectFailure { _ = try await provider.translateLyrics(self.candidates, targetLanguageCode: "zh", onTranslation: { _, _ in XCTFail("No complete translation") }) }
        XCTAssertEqual(AIQuotaProtocol.requests(host).count, 1, "Partial generated text also forbids replay")
    }

    func testCancellationStopsOrdinaryAndStreamingRequestsWithoutReplay() async throws {
        for streaming in [false, true] {
            let host = UUID().uuidString.lowercased() + ".invalid"
            AIQuotaProtocol.configure(host, status: 200, retryAfter: nil, holdOpen: true)
            let (provider, session) = provider(host)
            defer { session.invalidateAndCancel() }
            let finished = expectation(description: "Cancelled provider request finishes")
            let input = candidates
            let task = Task {
                defer { finished.fulfill() }
                do {
                    if streaming {
                        _ = try await provider.translateLyrics(input, targetLanguageCode: "zh", onTranslation: { _, _ in XCTFail("No generated text") })
                    } else {
                        _ = try await provider.listModels()
                    }
                    XCTFail("Cancelled request must fail")
                } catch is CancellationError { }
                catch { XCTFail("Cancellation classification was lost: \(error)") }
            }
            for _ in 0..<200 {
                if !AIQuotaProtocol.requests(host).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(AIQuotaProtocol.requests(host).count, 1)
            task.cancel()
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(AIQuotaProtocol.requests(host).count, 1)
        }
    }

    private var candidates: [LyricTranslationCandidate] {
        [.init(id: "line", text: "The road home", sourceLanguageCode: "en")]
    }
    private func expectFailure(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected HTTP failure") }
        catch {
            XCTAssertTrue(error is OpenAICompatibleProviderError, "Unexpected failure: \(error)")
            if case .requestFailed(let status, let retryAfter) = error as? OpenAICompatibleProviderError,
               [429, 503].contains(status) {
                XCTAssertGreaterThan(retryAfter ?? 0, 3590, "The complete server deadline must survive")
            }
        }
    }
    private func provider(_ host: String, key: String = "fixture") -> (OpenAICompatibleProvider, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIQuotaProtocol.self]
        let session = URLSession(configuration: config)
        let provider = OpenAICompatibleProvider(configuration: .init(baseURL: "https://\(host)/v1",
            apiStyle: .chatCompletions, generationModel: "fixture", embeddingModel: "fixture", isEnabled: true),
            credentialStore: AICredentialStore(), apiKeyOverride: key, session: session)
        return (provider, session)
    }
}

private final class AIQuotaProtocol: URLProtocol, @unchecked Sendable {
    struct State { let status: Int; let retryAfter: String?; let body: String; let contentType: String; let holdOpen: Bool; var requests: [URLRequest] = [] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    static func configure(_ host: String, status: Int, retryAfter: String? = "3600", body: String = "{}", contentType: String = "application/json", holdOpen: Bool = false) {
        lock.withLock { states[host] = State(status: status, retryAfter: retryAfter, body: body, contentType: contentType, holdOpen: holdOpen) }
    }
    static func requests(_ host: String) -> [URLRequest] { lock.withLock { states[host]!.requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let state = Self.lock.withLock { () -> State in
            Self.states[url.host!]!.requests.append(request)
            return Self.states[url.host!]!
        }
        if state.holdOpen { return }
        var headers = ["Content-Type": state.contentType]
        headers["Retry-After"] = state.retryAfter
        let response = HTTPURLResponse(url: url, statusCode: state.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(state.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
