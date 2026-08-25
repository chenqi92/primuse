import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class OpenAICompatibleProviderTests: XCTestCase {
    func testModelsRequestUsesConfiguredEndpointAndReturnsNormalizedModels() async throws {
        let host = "intelligence-models.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"object":"list","data":[{"id":" text-embedding-3-small ","owned_by":"openai","created":1715367049},{"id":"gpt-4.1","owned_by":"openai"},{"id":"GPT-4.1"},{"id":""}]}"#
        )
        let (provider, session) = makeProvider(host: host, apiStyle: .responses)
        defer { session.invalidateAndCancel() }

        let models = try await provider.listModels()

        XCTAssertEqual(models.map(\.id), ["gpt-4.1", "text-embedding-3-small"])
        XCTAssertEqual(models.first?.ownedBy, "openai")
        XCTAssertNotNil(models.last?.createdAt)
        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertNil(request.httpBody)
    }

    func testModelsRequestRejectsInvalidResponse() async throws {
        let host = "intelligence-models-invalid.invalid"
        IntelligenceURLProtocol.configure(host: host, statusCode: 200, body: #"{"models":[]}"#)
        let (provider, session) = makeProvider(host: host, apiStyle: .responses)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await provider.listModels()
            XCTFail("Expected an invalid models response")
        } catch OpenAICompatibleProviderError.invalidResponse {
            XCTAssertEqual(IntelligenceURLProtocol.requests(host: host).count, 1)
        }
    }

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

    func testProviderDoesNotReuseAPIKeyFromAnotherOrigin() async throws {
        let profileID = UUID(uuidString: "6B7C2032-A642-45D1-8C7D-C58DD17AD20D")!
        let oldConfiguration = AIRemoteProviderConfiguration(
            id: profileID,
            baseURL: "https://old-origin.invalid/v1",
            generationModel: "test-generation-model",
            isEnabled: true
        )
        let newConfiguration = AIRemoteProviderConfiguration(
            id: profileID,
            baseURL: "https://new-origin.invalid/v1",
            generationModel: "test-generation-model",
            isEnabled: true
        )
        let credentialStore = TestAICredentialStore()
        try await credentialStore.seed("old-origin-key", configuration: oldConfiguration)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: newConfiguration,
            credentialStore: credentialStore,
            session: session
        )

        guard case .unavailable(.missingCredential) = await provider.runtimeAvailability() else {
            XCTFail("A new origin must require a new API key")
            return
        }
        do {
            _ = try await provider.interpretSearch(
                AISemanticSearchRequest(query: "quiet evening")
            )
            XCTFail("Expected the provider to reject the missing origin-bound key")
        } catch OpenAICompatibleProviderError.missingCredential {
            XCTAssertTrue(IntelligenceURLProtocol.requests(host: "new-origin.invalid").isEmpty)
        }
    }

    func testRegionRevisionIsRecheckedBeforeSendingRequest() async throws {
        let host = "intelligence-region-change.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"output_text":"{\"expanded_terms\":[\"calm\"]}"}"#
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: AIRemoteProviderConfiguration(
                baseURL: "https://\(host)/v1",
                generationModel: "test-generation-model",
                isEnabled: true
            ),
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "must-not-be-sent",
            requestAuthorization: { false },
            session: session
        )

        do {
            _ = try await provider.interpretSearch(
                AISemanticSearchRequest(query: "quiet evening")
            )
            XCTFail("Expected the stale region revision to cancel the request")
        } catch is CancellationError {
            XCTAssertTrue(IntelligenceURLProtocol.requests(host: host).isEmpty)
        }
    }

    func testInvalidRuntimeTimeoutFailsClosedWithoutSendingRequest() async throws {
        let host = "intelligence-invalid-timeout.invalid"
        IntelligenceURLProtocol.configure(host: host, statusCode: 200, body: "{}")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        var configuration = AIRemoteProviderConfiguration(
            baseURL: "https://\(host)/v1",
            generationModel: "test-generation-model",
            isEnabled: true
        )
        configuration.requestTimeout = .nan
        let provider = OpenAICompatibleProvider(
            configuration: configuration,
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "must-not-be-sent",
            session: session
        )

        let availability = await provider.runtimeAvailability()
        XCTAssertEqual(availability, .unavailable(.missingConfiguration))
        do {
            _ = try await provider.interpretSearch(
                AISemanticSearchRequest(query: "quiet evening")
            )
            XCTFail("Expected the invalid timeout to fail closed")
        } catch OpenAICompatibleProviderError.invalidConfiguration(.invalidRequestTimeout) {
            XCTAssertTrue(IntelligenceURLProtocol.requests(host: host).isEmpty)
        }
    }

    func testResponseIsCancelledAsSoonAsStreamingBodyExceedsLimit() async throws {
        let host = "intelligence-oversized.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            chunks: [
                Data(repeating: 0x61, count: 1_024 * 1_024),
                Data(repeating: 0x62, count: 1_024 * 1_024),
                Data([0x63]),
                Data(repeating: 0x64, count: 1_024),
            ]
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: AIRemoteProviderConfiguration(
                baseURL: "https://\(host)/v1",
                generationModel: "test-generation-model",
                isEnabled: true
            ),
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "test-key",
            session: session
        )

        do {
            _ = try await provider.interpretSearch(
                AISemanticSearchRequest(query: "quiet evening")
            )
            XCTFail("Expected the streaming response limit to cancel the request")
        } catch OpenAICompatibleProviderError.responseTooLarge {
            XCTAssertGreaterThanOrEqual(
                IntelligenceURLProtocol.deliveredChunkCount(host: host),
                3
            )
            for _ in 0..<50 where IntelligenceURLProtocol.stopLoadingCount(host: host) == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThanOrEqual(IntelligenceURLProtocol.stopLoadingCount(host: host), 1)
        }
    }

    @MainActor
    func testServiceDeletesOnlyTheCurrentOriginAPIKey() async throws {
        let profileID = UUID(uuidString: "78805B85-F9A8-4325-B624-C393DC35D600")!
        let first = AIRemoteProviderConfiguration(
            id: profileID,
            baseURL: "https://first-origin.invalid/v1"
        )
        let second = AIRemoteProviderConfiguration(
            id: profileID,
            baseURL: "https://second-origin.invalid/v1"
        )
        let credentialStore = TestAICredentialStore()
        try await credentialStore.seed("first-key", configuration: first)
        try await credentialStore.seed("second-key", configuration: second)
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        let service = MusicIntelligenceService(
            settingsStore: AISettingsStore(defaults: defaults),
            credentialStore: credentialStore
        )

        try await service.deleteAPIKey(configuration: second)

        guard case .ready("first-key") = await credentialStore.lookupAPIKey(
            configuration: first
        ) else {
            XCTFail("Deleting the current origin must preserve other origins")
            return
        }
        guard case .notConfigured = await credentialStore.lookupAPIKey(
            configuration: second
        ) else {
            XCTFail("The current origin key should be deleted")
            return
        }
    }

    @MainActor
    func testSettingsRejectInvalidTimeoutBeforePersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        let store = AISettingsStore(defaults: defaults)
        let original = store.configuration
        var invalid = original
        invalid.requestTimeout = .infinity

        XCTAssertThrowsError(try store.save(
            configuration: invalid,
            hasExplicitRemoteConsent: true
        )) { error in
            XCTAssertEqual(
                error as? AIRemoteEndpointValidationError,
                .invalidRequestTimeout
            )
        }
        XCTAssertEqual(store.configuration, original)
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

private actor TestAICredentialStore: AICredentialStoring {
    private var keys: [String: String] = [:]

    func seed(
        _ key: String,
        configuration: AIRemoteProviderConfiguration
    ) throws {
        keys[try account(for: configuration)] = key
    }

    func lookupAPIKey(configuration: AIRemoteProviderConfiguration) -> AICredentialLookup {
        guard let account = try? account(for: configuration),
              let key = keys[account] else {
            return .notConfigured
        }
        return .ready(key)
    }

    func requireAPIKey(configuration: AIRemoteProviderConfiguration) throws -> String {
        guard case .ready(let key) = lookupAPIKey(configuration: configuration) else {
            throw MusicIntelligenceError.unavailable(.missingCredential)
        }
        return key
    }

    @discardableResult
    func saveAPIKey(
        _ rawValue: String,
        configuration: AIRemoteProviderConfiguration
    ) throws -> Bool {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = try account(for: configuration)
        keys[account] = key.isEmpty ? nil : key
        return !key.isEmpty
    }

    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) throws {
        keys[try account(for: configuration)] = nil
    }

    private func account(for configuration: AIRemoteProviderConfiguration) throws -> String {
        try AICredentialStoragePolicy.account(
            profileID: configuration.id,
            baseURL: configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
    }
}

private final class IntelligenceURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var statusCode: Int
        var chunks: [Data]
        var requests: [URLRequest] = []
        var deliveredChunkCount = 0
        var stopLoadingCount = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    private let instanceLock = NSLock()
    private var isStopped = false

    static func configure(host: String, statusCode: Int, body: String) {
        configure(host: host, statusCode: statusCode, chunks: [Data(body.utf8)])
    }

    static func configure(host: String, statusCode: Int, chunks: [Data]) {
        lock.lock()
        states[host] = State(statusCode: statusCode, chunks: chunks)
        lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return states[host]?.requests ?? []
    }

    static func deliveredChunkCount(host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return states[host]?.deliveredChunkCount ?? 0
    }

    static func stopLoadingCount(host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return states[host]?.stopLoadingCount ?? 0
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
        deliver(state.chunks, host: host, index: 0)
    }

    override func stopLoading() {
        instanceLock.lock()
        isStopped = true
        instanceLock.unlock()
        guard let host = request.url?.host else { return }
        Self.lock.lock()
        Self.states[host]?.stopLoadingCount += 1
        Self.lock.unlock()
    }

    private func deliver(_ chunks: [Data], host: String, index: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.002) { [weak self] in
            guard let self else { return }
            self.instanceLock.lock()
            let stopped = self.isStopped
            self.instanceLock.unlock()
            guard !stopped else { return }
            guard index < chunks.count else {
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }

            Self.lock.lock()
            Self.states[host]?.deliveredChunkCount += 1
            Self.lock.unlock()
            self.client?.urlProtocol(self, didLoad: chunks[index])
            self.deliver(chunks, host: host, index: index + 1)
        }
    }

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
