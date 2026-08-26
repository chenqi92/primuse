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

    func testAnthropicMessagesUsesNativeHeadersBodyAndResponse() async throws {
        let host = "intelligence-anthropic.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"id":"msg_test","type":"message","content":[{"type":"text","text":"{\"expanded_terms\":[\"acoustic\"],\"themes\":[\"nature\"],\"moods\":[\"quiet\"]}"}]}"#
        )
        let (provider, session) = makeProvider(
            host: host,
            apiStyle: .anthropicMessages
        )
        defer { session.invalidateAndCancel() }

        let plan = try await provider.interpretSearch(
            AISemanticSearchRequest(query: "quiet forest", languageCode: "en")
        )

        XCTAssertEqual(plan.expandedTerms, ["acoustic"])
        XCTAssertEqual(plan.themes, ["nature"])
        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-api-key")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "test-generation-model")
        XCTAssertEqual(object["max_tokens"] as? Int, 320)
        XCTAssertNotNil(object["system"] as? String)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    func testAnthropicModelsFollowPaginationAndParseDates() async throws {
        let host = "intelligence-anthropic-models.invalid"
        IntelligenceURLProtocol.configureSequence(
            host: host,
            responses: [
                (
                    200,
                    #"{"data":[{"id":"claude-a","display_name":"Claude A","created_at":"2026-01-02T03:04:05Z"}],"has_more":true,"last_id":"claude-a"}"#
                ),
                (
                    200,
                    #"{"data":[{"id":"claude-b","display_name":"Claude B","created_at":"2026-02-03T04:05:06.123Z"}],"has_more":false,"last_id":"claude-b"}"#
                ),
            ]
        )
        let (provider, session) = makeProvider(
            host: host,
            apiStyle: .anthropicMessages
        )
        defer { session.invalidateAndCancel() }

        let models = try await provider.listModels()

        XCTAssertEqual(models.map(\.id), ["claude-a", "claude-b"])
        XCTAssertTrue(models.allSatisfy { $0.createdAt != nil })
        let requests = IntelligenceURLProtocol.requests(host: host)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "limit" })?.value,
            "100"
        )
        XCTAssertEqual(
            URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after_id" })?.value,
            "claude-a"
        )
    }

    func testAnthropicWireFormatCanUseBearerForCompatibleRelay() async throws {
        let host = "intelligence-anthropic-bearer.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"{\"expanded_terms\":[\"calm\"]}"}]}"#
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: AIRemoteProviderConfiguration(
                baseURL: "https://\(host)/anthropic",
                apiStyle: .anthropicMessages,
                apiPathMode: .appendV1,
                authenticationStyle: .bearer,
                generationModel: "relay-model",
                isEnabled: true
            ),
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "relay-key",
            session: session
        )

        _ = try await provider.interpretSearch(AISemanticSearchRequest(query: "calm"))

        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        XCTAssertEqual(request.url?.path, "/anthropic/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer relay-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01"
        )
    }

    func testDeepSeekAnthropicUsesOpenAIModelCatalogAtProviderRoot() async throws {
        let host = "api.deepseek.com"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"object":"list","data":[{"id":"deepseek-v4-flash","owned_by":"deepseek"},{"id":"deepseek-v4-pro","owned_by":"deepseek"}]}"#
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: AIProviderPreset.deepSeekAnthropic.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            ),
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "deepseek-test-key",
            session: session
        )

        let models = try await provider.listModels()

        XCTAssertEqual(models.map(\.id), ["deepseek-v4-flash", "deepseek-v4-pro"])
        XCTAssertTrue(models.allSatisfy { $0.ownedBy == "deepseek" })
        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/models")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer deepseek-test-key"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))
    }

    func testDeepSeekAnthropicUsesNativeAuthenticationForMessages() async throws {
        let host = "deepseek-anthropic-messages.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"{\"expanded_terms\":[\"calm\"]}"}]}"#
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        var configuration = AIProviderPreset.deepSeekAnthropic.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        configuration.baseURL = "https://\(host)/anthropic"
        let provider = OpenAICompatibleProvider(
            configuration: configuration,
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "deepseek-test-key",
            session: session
        )

        _ = try await provider.interpretSearch(AISemanticSearchRequest(query: "calm"))

        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        XCTAssertEqual(request.url?.path, "/anthropic/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "deepseek-test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01"
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

    @MainActor
    func testModelFetchRequiresExplicitRemoteConsent() {
        let editor = AISettingsEditorModel()
        editor.apiKeyDraft = "test-key"
        editor.draftConfiguration.baseURL = "https://api.example.com/v1"

        XCTAssertFalse(editor.canFetchModels)

        editor.consent = true
        XCTAssertTrue(editor.canFetchModels)
    }

    @MainActor
    func testProviderPresetSelectionHasStableExplicitState() {
        let editor = AISettingsEditorModel()
        editor.apiKeyDraft = "temporary-key"

        editor.applyProviderPreset(.anthropic)

        XCTAssertEqual(editor.selectedProviderPreset, .anthropic)
        XCTAssertEqual(editor.providerPresetBinding.wrappedValue, .anthropic)
        XCTAssertEqual(editor.draftConfiguration.baseURL, "https://api.anthropic.com")
        XCTAssertEqual(editor.draftConfiguration.apiStyle, .anthropicMessages)
        XCTAssertTrue(editor.apiKeyDraft.isEmpty)

        editor.applyProviderPreset(.custom)

        XCTAssertEqual(editor.selectedProviderPreset, .custom)
        XCTAssertEqual(editor.providerPresetBinding.wrappedValue, .custom)
        XCTAssertEqual(editor.draftConfiguration.baseURL, "https://api.anthropic.com")
    }

    @MainActor
    func testEditingProviderConnectionRecomputesPresetWithoutMenuFeedback() {
        let editor = AISettingsEditorModel()
        editor.applyProviderPreset(.openAI)

        editor.configurationBinding(
            \.baseURL,
            clearModels: true,
            updatesProviderPreset: true
        ).wrappedValue = "https://relay.example.com"

        XCTAssertEqual(editor.selectedProviderPreset, .custom)

        editor.configurationBinding(
            \.baseURL,
            clearModels: true,
            updatesProviderPreset: true
        ).wrappedValue = "https://api.openai.com"

        XCTAssertEqual(editor.selectedProviderPreset, .openAI)
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
        try AICredentialStoragePolicy.scopedAccount(configuration: configuration)
    }
}

private final class IntelligenceURLProtocol: URLProtocol, @unchecked Sendable {
    private struct StubResponse {
        var statusCode: Int
        var chunks: [Data]
    }

    private struct State {
        var responses: [StubResponse]
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
        states[host] = State(responses: [
            StubResponse(statusCode: statusCode, chunks: chunks),
        ])
        lock.unlock()
    }

    static func configureSequence(
        host: String,
        responses: [(statusCode: Int, body: String)]
    ) {
        lock.lock()
        states[host] = State(responses: responses.map {
            StubResponse(statusCode: $0.statusCode, chunks: [Data($0.body.utf8)])
        })
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
        let responseIndex = min(state.requests.count, state.responses.count - 1)
        let stub = state.responses[responseIndex]
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
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(stub.chunks, host: host, index: 0)
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
