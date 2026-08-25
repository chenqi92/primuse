import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class OpenAICompatibleProviderTests: XCTestCase {
    func testResponsesRequestUsesConfiguredEndpointAndReturnsNormalizedPlan() async throws {
        let host = "intelligence-responses.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"output":[{"content":[{"type":"output_text","text":"{\"expanded_terms\":[\"homecoming\",\"homecoming\"],\"themes\":[\"memory\"],\"moods\":[\"wistful\"]}"}]}]}"#
        )
        let (provider, session) = makeProvider(host: host, apiStyle: .responses)
        defer { session.invalidateAndCancel() }

        let plan = try await provider.interpretSearch(
            AISemanticSearchRequest(query: "nostalgia", languageCode: "en")
        )

        XCTAssertEqual(plan.expandedTerms, ["homecoming"])
        XCTAssertEqual(plan.themes, ["memory"])
        XCTAssertEqual(plan.moods, ["wistful"])

        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "test-generation-model")
        XCTAssertEqual(object["store"] as? Bool, false)
        XCTAssertTrue((object["input"] as? String)?.contains("nostalgia") == true)
        XCTAssertNil(object["songs"])
        XCTAssertNil(object["lyrics"])
        XCTAssertNil(object["listening_history"])
        XCTAssertNil(object["audio"])
    }

    func testChatCompletionsResponseIsSupportedThroughTheSameInterface() async throws {
        let host = "intelligence-chat.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"{\"expanded_terms\":[\"rainy night\"],\"themes\":[],\"moods\":[\"calm\"]}"}}]}"#
        )
        let (provider, session) = makeProvider(host: host, apiStyle: .chatCompletions)
        defer { session.invalidateAndCancel() }

        let plan = try await provider.interpretSearch(
            AISemanticSearchRequest(query: "music before sleep", languageCode: "en")
        )

        XCTAssertEqual(plan.expandedTerms, ["rainy night"])
        XCTAssertEqual(plan.moods, ["calm"])
        XCTAssertEqual(
            IntelligenceURLProtocol.requests(host: host).first?.url?.path,
            "/v1/chat/completions"
        )
    }

    func testHTTPStatusIsReportedWithoutParsingTheResponseBody() async throws {
        let host = "intelligence-status.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 429,
            body: #"{"error":{"message":"provider detail must not escape"}}"#
        )
        let (provider, session) = makeProvider(host: host, apiStyle: .responses)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await provider.interpretSearch(
                AISemanticSearchRequest(query: "quiet driving")
            )
            XCTFail("Expected the provider to report an HTTP status error")
        } catch OpenAICompatibleProviderError.requestFailed(let statusCode) {
            XCTAssertEqual(statusCode, 429)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    private func makeProvider(
        host: String,
        apiStyle: AICompatibleAPIStyle
    ) -> (OpenAICompatibleProvider, URLSession) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = OpenAICompatibleProvider(
            configuration: AIRemoteProviderConfiguration(
                baseURL: "https://\(host)/v1",
                apiStyle: apiStyle,
                generationModel: "test-generation-model",
                isEnabled: true
            ),
            credentialStore: AICredentialStore(),
            apiKeyOverride: "test-api-key",
            session: session
        )
        return (provider, session)
    }
}

private final class IntelligenceURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var statusCode: Int
        var body: String
        var requests: [URLRequest] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]

    static func configure(host: String, statusCode: Int, body: String) {
        lock.lock()
        states[host] = State(statusCode: statusCode, body: body)
        lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return states[host]?.requests ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        guard var state = Self.states[host] else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var capturedRequest = request
        if capturedRequest.httpBody == nil,
           let bodyStream = request.httpBodyStream {
            capturedRequest.httpBody = Self.readBody(from: bodyStream)
        }
        state.requests.append(capturedRequest)
        Self.states[host] = state
        Self.lock.unlock()

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: state.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(state.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
