import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class AIStreamingIntegrationTests: XCTestCase {
    func testLinesArriveBeforeTheResponseFinishesAndKeepTheirIDs() async throws {
        let host = "lyrics-stream.invalid"
        let first = #"{"translations":[{"id":"line-1","text":"回家的路"}"#
        let last = #",{"id":"unknown","text":"忽略"},{"id":"line-1","text":"重复"},{"id":"line-2","text":"雨夜"}]}"#
        StreamingURLProtocol.configure(host, responses: [
            .init(status: 200, contentType: "text/event-stream", chunks: [sse(first), sse(last), Data("data: [DONE]\n\n".utf8)]),
        ])
        let (provider, session) = provider(host)
        defer { session.invalidateAndCancel() }
        let progress = StreamingValues<[String]>([])
        let counts = StreamingValues<[Int]>([])
        let result = try await provider.translateLyrics(candidates, targetLanguageCode: "zh-Hans") { id, _ in
            progress.update { $0.append(id) }
            counts.update { $0.append(StreamingURLProtocol.delivered(host)) }
        }
        XCTAssertEqual(progress.value, ["line-1", "line-2"])
        XCTAssertLessThan(try XCTUnwrap(counts.value.first), 3)
        XCTAssertEqual(result, ["line-1": "重复", "line-2": "雨夜"])
        let request = try XCTUnwrap(StreamingURLProtocol.requests(host).first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testTruncatedResponseKeepsCompletedProgressAndDoesNotRetry() async throws {
        let host = "lyrics-truncated.invalid"
        StreamingURLProtocol.configure(host, responses: [
            .init(status: 200, contentType: "text/event-stream", chunks: [sse(#"{"translations":[{"id":"line-1","text":"回家的路"},{"id":"line-2","text":"雨"#)]),
        ])
        let (provider, session) = provider(host)
        defer { session.invalidateAndCancel() }
        let progress = StreamingValues<[String: String]>([:])
        do {
            _ = try await provider.translateLyrics(candidates, targetLanguageCode: "zh-Hans") { id, text in
                progress.update { $0[id] = text }
            }
            XCTFail("A truncated final answer cannot succeed")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleProviderError, .invalidResponse)
        }
        XCTAssertEqual(progress.value, ["line-1": "回家的路"])
        XCTAssertEqual(StreamingURLProtocol.requests(host).count, 1)
    }

    func testUnsupportedStreamingRetriesOnceUsingAnOrdinaryRequest() async throws {
        let host = "lyrics-buffered.invalid"
        let content = #"{"translations":[{"id":"line-1","text":"回家的路"},{"id":"line-2","text":"雨夜"}]}"#
        let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        StreamingURLProtocol.configure(host, responses: [
            .init(status: 400, contentType: "application/json", chunks: [Data("{}".utf8)]),
            .init(status: 200, contentType: "application/json", chunks: [body]),
        ])
        let (provider, session) = provider(host)
        defer { session.invalidateAndCancel() }
        let result = try await provider.translateLyrics(candidates, targetLanguageCode: "zh-Hans", onTranslation: { _, _ in })
        XCTAssertEqual(result.count, 2)
        let requests = StreamingURLProtocol.requests(host)
        XCTAssertEqual(requests.count, 2)
        let fallback = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last?.httpBody)) as? [String: Any])
        XCTAssertNil(fallback["stream"])
    }

    func testAuthenticationFailureDoesNotRepeatTheRequest() async throws {
        let host = "lyrics-unauthorized.invalid"
        StreamingURLProtocol.configure(host, responses: [.init(status: 401, contentType: "application/json", chunks: [Data("{}".utf8)])])
        let (provider, session) = provider(host)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await provider.translateLyrics(candidates, targetLanguageCode: "zh-Hans", onTranslation: { _, _ in })
            XCTFail("Expected an authentication failure")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleProviderError, .requestFailed(statusCode: 401))
        }
        XCTAssertEqual(StreamingURLProtocol.requests(host).count, 1)
    }

    private var candidates: [LyricTranslationCandidate] {
        [.init(id: "line-1", text: "The road home", sourceLanguageCode: "en"),
         .init(id: "line-2", text: "Rainy night", sourceLanguageCode: "en")]
    }

    private func provider(_ host: String) -> (OpenAICompatibleProvider, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (OpenAICompatibleProvider(
            configuration: .init(baseURL: "https://\(host)/v1", apiStyle: .chatCompletions,
                                 generationModel: "test", isEnabled: true),
            credentialStore: AICredentialStore(), apiKeyOverride: "isolated-test-key", session: session
        ), session)
    }

    private func sse(_ text: String) -> Data {
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]])
        return Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
    }
}

private final class StreamingValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func update(_ operation: (inout Value) -> Void) { lock.withLock { operation(&storage) } }
}

private final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let contentType: String
        let chunks: [Data]
    }
    private struct State {
        let responses: [Reply]
        var requests: [URLRequest] = []
        var delivered = 0
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    private let stopped = StreamingValues(false)
    static func configure(_ host: String, responses: [Reply]) {
        lock.withLock { states[host] = State(responses: responses) }
    }
    static func requests(_ host: String) -> [URLRequest] { lock.withLock { states[host]?.requests ?? [] } }
    static func delivered(_ host: String) -> Int { lock.withLock { states[host]?.delivered ?? 0 } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        var captured = request
        if captured.httpBody == nil, let body = captured.httpBodyStream {
            body.open()
            defer { body.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while body.hasBytesAvailable {
                let count = body.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        let reply: Reply? = Self.lock.withLock {
            guard var state = Self.states[host], !state.responses.isEmpty else { return nil }
            let reply = state.responses[min(state.requests.count, state.responses.count - 1)]
            state.requests.append(captured)
            Self.states[host] = state
            return reply
        }
        guard let reply, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                       headerFields: ["Content-Type": reply.contentType]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(reply.chunks, host: host, index: 0)
    }
    override func stopLoading() { stopped.update { $0 = true } }
    private func deliver(_ chunks: [Data], host: String, index: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, !self.stopped.value else { return }
            guard index < chunks.count else { self.client?.urlProtocolDidFinishLoading(self); return }
            Self.lock.withLock { Self.states[host]?.delivered += 1 }
            self.client?.urlProtocol(self, didLoad: chunks[index])
            self.deliver(chunks, host: host, index: index + 1)
        }
    }
}
