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

    func testLyricsTranslationPreservesLineIdentityAndUsesGenerationEndpoint() async throws {
        let host = "intelligence-lyrics.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"output_text":"{\"translations\":[{\"id\":\"line-1\",\"text\":\"回家的路\"},{\"id\":\"line-2\",\"text\":\"雨夜\"}]}"}"#
        )
        let (provider, session) = makeProvider(host: host, apiStyle: .responses)
        defer { session.invalidateAndCancel() }

        let translations = try await provider.translateLyrics(
            [
                LyricTranslationCandidate(
                    id: "line-1",
                    text: "The road home",
                    sourceLanguageCode: "en"
                ),
                LyricTranslationCandidate(
                    id: "line-2",
                    text: "Rainy night",
                    sourceLanguageCode: "en"
                ),
            ],
            targetLanguageCode: "zh-Hans"
        )

        XCTAssertEqual(translations["line-1"], "回家的路")
        XCTAssertEqual(translations["line-2"], "雨夜")
        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "test-generation-model")
        XCTAssertEqual(object["max_output_tokens"] as? Int, 4_000)
        XCTAssertTrue((object["input"] as? String)?.contains("line-1") == true)
    }

    func testRecommendationsUseOpaqueCandidateIDsAndReturnLocalSongIDs() async throws {
        let host = "intelligence-recommendations.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"output_text":"{\"summary\":\"A quieter progression\",\"recommendations\":[{\"id\":\"c1\",\"reason\":\"gentle pacing\"},{\"id\":\"c0\",\"reason\":\"familiar opener\"},{\"id\":\"unknown\",\"reason\":\"ignore\"}]}"}"#
        )
        let (provider, session) = makeProvider(host: host, apiStyle: .responses)
        defer { session.invalidateAndCancel() }
        let request = AIRecommendationRequest(
            scene: .bedtime,
            intent: "quiet rain and homesickness",
            languageCode: "en",
            preferences: [
                AIRecommendationPreference(
                    title: "Often Played",
                    artist: "Listener Favorite",
                    playCount: 12
                )
            ],
            candidates: [
                AIRecommendationCandidate(
                    songID: "private-song-id-1",
                    title: "First Candidate",
                    artist: "Artist A"
                ),
                AIRecommendationCandidate(
                    songID: "private-song-id-2",
                    title: "Second Candidate",
                    artist: "Artist B"
                ),
            ],
            maximumResults: 2,
            minimumResults: 2
        )

        let plan = try await provider.recommendations(request)

        XCTAssertEqual(plan.selections.map(\.songID), [
            "private-song-id-2", "private-song-id-1",
        ])
        XCTAssertEqual(plan.summary, "A quieter progression")
        let sentRequest = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        let body = try XCTUnwrap(sentRequest.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap(object["input"] as? String)
        XCTAssertTrue(input.contains("First Candidate"))
        XCTAssertTrue(input.contains("quiet rain and homesickness"))
        XCTAssertTrue(input.contains("\"id\":\"c0\""))
        XCTAssertTrue(input.contains("\"maximum_results\":2"))
        XCTAssertTrue(input.contains("\"minimum_results\":2"))
        XCTAssertFalse(input.contains("private-song-id"))
        XCTAssertFalse(input.contains("filePath"))
        XCTAssertFalse(input.contains("sourceID"))
        XCTAssertFalse(input.contains("lyrics"))
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

    func testGeminiGenerateContentUsesNativeHeadersBodyAndResponse() async throws {
        let host = "intelligence-gemini.invalid"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"candidates":[{"content":{"role":"model","parts":[{"text":"{\"expanded_terms\":[\"night drive\"],\"themes\":[\"road\"],\"moods\":[\"calm\"]}"}]}}]}"#
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: AIRemoteProviderConfiguration(
                baseURL: "https://\(host)/v1beta",
                apiStyle: .geminiGenerateContent,
                apiPathMode: .asEntered,
                authenticationStyle: .automatic,
                generationModel: "gemini-test",
                isEnabled: true
            ),
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "gemini-api-key",
            session: session
        )

        let plan = try await provider.interpretSearch(
            AISemanticSearchRequest(query: "calm music for a night drive", languageCode: "en")
        )

        XCTAssertEqual(plan.expandedTerms, ["night drive"])
        XCTAssertEqual(plan.themes, ["road"])
        XCTAssertEqual(plan.moods, ["calm"])
        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://\(host)/v1beta/models/gemini-test:generateContent"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-api-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["model"])
        XCTAssertNotNil(object["systemInstruction"] as? [String: Any])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["role"] as? String, "user")
        let generationConfig = try XCTUnwrap(object["generationConfig"] as? [String: Any])
        XCTAssertEqual(generationConfig["maxOutputTokens"] as? Int, 320)
        XCTAssertEqual(generationConfig["responseMimeType"] as? String, "application/json")
    }

    func testGeminiAudioTranscriptionUploadsInteractsAndDeletesTemporaryFile() async throws {
        let host = "generativelanguage.googleapis.com"
        IntelligenceURLProtocol.configureSequence(
            host: host,
            responses: [
                (
                    200,
                    "{}",
                    ["x-goog-upload-url": "https://\(host)/upload-session"]
                ),
                (
                    200,
                    #"{"file":{"name":"files/primuse-test","uri":"https://generativelanguage.googleapis.com/v1beta/files/primuse-test","mimeType":"audio/mpeg"}}"#,
                    [:]
                ),
                (
                    200,
                    #"{"output_text":"故乡 的 雨","output":[{"annotations":[{"type":"word_info","text":"故乡","start_offset":"0.2s","end_offset":"0.8s"},{"type":"word_info","text":"的","start_offset":"0.9s","end_offset":"1.1s"},{"type":"word_info","text":"雨","start_offset":"1.2s","end_offset":"1.6s"}]}]}"#,
                    [:]
                ),
                (200, "{}", [:]),
            ]
        )
        var configuration = AIProviderPreset.gemini.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        configuration.transcriptionModel = "gemini-test-transcribe"
        let credentialStore = TestAICredentialStore()
        try await credentialStore.seed("gemini-transcribe-key", configuration: configuration)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = GeminiAudioTranscriptionProvider(
            configuration: configuration,
            credentialStore: credentialStore,
            session: session
        )
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-transcription-\(UUID().uuidString).mp3")
        try Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let result = try await provider.transcribeAudio(
            AIAudioTranscriptionRequest(
                audioFileURL: audioURL,
                mimeType: "audio/mpeg",
                displayName: "故乡.mp3",
                languageCodes: ["zh-CN"],
                customVocabulary: ["故乡", "猿音"]
            )
        )

        XCTAssertEqual(result.transcript, "故乡 的 雨")
        XCTAssertEqual(result.words.map(\.text), ["故乡", "的", "雨"])
        XCTAssertEqual(result.words.first?.startTime, 0.2)
        XCTAssertEqual(result.words.last?.endTime, 1.6)

        let requests = IntelligenceURLProtocol.requests(host: host)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/upload/v1beta/files",
            "/upload-session",
            "/v1beta/interactions",
            "/v1beta/files/primuse-test",
        ])
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "x-goog-api-key"),
            "gemini-transcribe-key"
        )
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "X-Goog-Upload-Command"),
            "upload, finalize"
        )
        XCTAssertEqual(requests[1].httpBody, Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]))
        let interactionBody = try XCTUnwrap(requests[2].httpBody)
        let interaction = try XCTUnwrap(
            JSONSerialization.jsonObject(with: interactionBody) as? [String: Any]
        )
        XCTAssertEqual(interaction["model"] as? String, "gemini-test-transcribe")
        XCTAssertEqual(interaction["store"] as? Bool, false)
        let generation = try XCTUnwrap(interaction["generation_config"] as? [String: Any])
        let transcription = try XCTUnwrap(
            generation["transcription_config"] as? [String: Any]
        )
        XCTAssertEqual(transcription["language_codes"] as? [String], ["zh-CN"])
        XCTAssertEqual(transcription["custom_vocabulary"] as? [String], ["故乡", "猿音"])
        let mode = try XCTUnwrap(transcription["mode"] as? [String: Any])
        XCTAssertEqual(mode["type"] as? String, "verbatim")
        XCTAssertEqual(mode["timestamp_granularities"] as? [String], ["word"])
        XCTAssertEqual(requests[3].httpMethod, "DELETE")
        XCTAssertEqual(
            requests[3].value(forHTTPHeaderField: "x-goog-api-key"),
            "gemini-transcribe-key"
        )
    }

    func testGeminiModelsFollowPaginationAndOnlyReturnGenerateContentModels() async throws {
        let host = "intelligence-gemini-models.invalid"
        IntelligenceURLProtocol.configureSequence(
            host: host,
            responses: [
                (
                    200,
                    #"{"models":[{"name":"models/gemini-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"page-2"}"#
                ),
                (
                    200,
                    #"{"models":[{"name":"models/gemini-future-transcribe","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-pro","supportedGenerationMethods":["generateContent","countTokens"]}]}"#
                ),
            ]
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: AIRemoteProviderConfiguration(
                baseURL: "https://\(host)/v1beta",
                apiStyle: .geminiGenerateContent,
                apiPathMode: .asEntered,
                generationModel: "gemini-flash",
                isEnabled: true
            ),
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "gemini-api-key",
            session: session
        )

        let models = try await provider.listModels()

        XCTAssertEqual(models.map(\.id), ["gemini-flash", "gemini-future-transcribe", "gemini-pro"])
        XCTAssertTrue(models.allSatisfy { $0.ownedBy == "Google" })
        XCTAssertEqual(
            AIAudioTranscriptionPolicy.supportedModels(from: models).map(\.id),
            ["gemini-future-transcribe"]
        )
        let requests = IntelligenceURLProtocol.requests(host: host)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-goog-api-key"), "gemini-api-key")
        XCTAssertEqual(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pageSize" })?.value,
            "1000"
        )
        XCTAssertEqual(
            URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pageToken" })?.value,
            "page-2"
        )
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

    func testOfficialDeepSeekRecommendationDisablesThinking() async throws {
        let host = "api.deepseek.com"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"choices":[{"message":{"content":"{\"summary\":\"A calm sequence\",\"recommendations\":[{\"id\":\"c0\",\"reason\":\"gentle pacing\"}]}"}}]}"#
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: AIProviderPreset.deepSeekOpenAI.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            ),
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "deepseek-test-key",
            session: session
        )

        let plan = try await provider.recommendations(AIRecommendationRequest(
            scene: .bedtime,
            preferences: [],
            candidates: [
                AIRecommendationCandidate(
                    songID: "local-song-id",
                    title: "Quiet Night",
                    artist: "Test Artist"
                )
            ]
        ))

        XCTAssertEqual(plan.selections.map(\.songID), ["local-song-id"])
        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try XCTUnwrap(object["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")
    }

    func testOfficialDeepSeekResponsesDisablesReasoning() async throws {
        let host = "api.deepseek.com"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"output_text":"{\"translations\":[{\"id\":\"line-1\",\"text\":\"安静的夜晚\"}]}"}"#
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: AIRemoteProviderConfiguration(
                baseURL: "https://api.deepseek.com/v1",
                apiStyle: .responses,
                apiPathMode: .asEntered,
                generationModel: "deepseek-v4-flash",
                isEnabled: true
            ),
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "deepseek-test-key",
            session: session
        )

        let translations = try await provider.translateLyrics(
            [
                LyricTranslationCandidate(
                    id: "line-1",
                    text: "Quiet night",
                    sourceLanguageCode: "en"
                )
            ],
            targetLanguageCode: "zh-Hans"
        )

        XCTAssertEqual(translations["line-1"], "安静的夜晚")
        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try XCTUnwrap(object["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
    }

    func testOfficialDeepSeekAnthropicDisablesReasoning() async throws {
        let host = "api.deepseek.com"
        IntelligenceURLProtocol.configure(
            host: host,
            statusCode: 200,
            body: #"{"content":[{"type":"text","text":"{\"expanded_terms\":[\"calm\"],\"themes\":[],\"moods\":[\"quiet\"]}"}]}"#
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

        let plan = try await provider.interpretSearch(
            AISemanticSearchRequest(query: "quiet music")
        )

        XCTAssertEqual(plan.expandedTerms, ["calm"])
        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reasoning = try XCTUnwrap(object["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "none")
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

    func testMainlandProviderControlsDisableOptionalThinking() async throws {
        let zhipu = try await capturedSearchBody(
            for: AIProviderPreset.zhipu.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(
            (zhipu["thinking"] as? [String: Any])?["type"] as? String,
            "disabled"
        )

        let mimo = try await capturedSearchBody(
            for: AIProviderPreset.xiaomiMiMo.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(
            (mimo["thinking"] as? [String: Any])?["type"] as? String,
            "disabled"
        )
        XCTAssertEqual(mimo["max_completion_tokens"] as? Int, 320)
        XCTAssertNil(mimo["max_tokens"])

        let ark = try await capturedSearchBody(
            for: AIProviderPreset.volcengineArk.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(
            (ark["thinking"] as? [String: Any])?["type"] as? String,
            "disabled"
        )

        let tokenHub = try await capturedSearchBody(
            for: AIProviderPreset.tencentTokenHub.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(
            (tokenHub["thinking"] as? [String: Any])?["type"] as? String,
            "disabled"
        )

        let qianfan = try await capturedSearchBody(
            for: AIProviderPreset.baiduQianfan.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(qianfan["model"] as? String, "ernie-4.5-turbo-32k")
        XCTAssertNil(qianfan["thinking"])
        XCTAssertNil(qianfan["enable_thinking"])

        var qianfanDeepSeekConfiguration = AIProviderPreset.baiduQianfan.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        qianfanDeepSeekConfiguration.generationModel = "deepseek-v4-flash"
        let qianfanDeepSeek = try await capturedSearchBody(for: qianfanDeepSeekConfiguration)
        XCTAssertEqual(
            (qianfanDeepSeek["thinking"] as? [String: Any])?["type"] as? String,
            "disabled"
        )

        var qianfanErniePreviewConfiguration = AIProviderPreset.baiduQianfan.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        qianfanErniePreviewConfiguration.generationModel = "ernie-5.0-thinking-preview"
        let qianfanErniePreview = try await capturedSearchBody(for: qianfanErniePreviewConfiguration)
        XCTAssertEqual(qianfanErniePreview["enable_thinking"] as? Bool, false)

        var qwenConfiguration = AIProviderPreset.qwen.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        qwenConfiguration.generationModel = "qwen3.5-plus"
        let qwen = try await capturedSearchBody(for: qwenConfiguration)
        XCTAssertEqual(qwen["enable_thinking"] as? Bool, false)

        let qwenAlias = try await capturedSearchBody(
            for: AIProviderPreset.qwen.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(qwenAlias["enable_thinking"] as? Bool, false)

        var siliconFlowConfiguration = AIProviderPreset.siliconFlow.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        siliconFlowConfiguration.generationModel = "Qwen/Qwen3.5-235B-A22B"
        let siliconFlow = try await capturedSearchBody(for: siliconFlowConfiguration)
        XCTAssertEqual(siliconFlow["enable_thinking"] as? Bool, false)
    }

    func testGlobalProviderControlsMatchDocumentedReasoningParameters() async throws {
        let openAI = try await capturedSearchBody(
            for: AIProviderPreset.openAI.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(
            (openAI["reasoning"] as? [String: Any])?["effort"] as? String,
            "none"
        )

        let nvidia = try await capturedSearchBody(
            for: AIProviderPreset.nvidiaNIM.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(
            (nvidia["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool,
            false
        )

        let mistral = try await capturedSearchBody(
            for: AIProviderPreset.mistral.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(mistral["reasoning_effort"] as? String, "none")
    }

    func testReasoningOnlyProvidersUseLowEffortAndSufficientOutputBudget() async throws {
        let gemini = try await capturedSearchBody(
            for: AIProviderPreset.gemini.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        let generationConfig = try XCTUnwrap(gemini["generationConfig"] as? [String: Any])
        XCTAssertEqual(
            (generationConfig["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String,
            "low"
        )
        XCTAssertEqual(generationConfig["maxOutputTokens"] as? Int, 4_000)

        let kimi = try await capturedSearchBody(
            for: AIProviderPreset.kimi.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(kimi["reasoning_effort"] as? String, "low")
        XCTAssertEqual(kimi["max_tokens"] as? Int, 16_000)

        let miniMax = try await capturedSearchBody(
            for: AIProviderPreset.miniMax.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(miniMax["model"] as? String, "MiniMax-M3")
        XCTAssertEqual(
            (miniMax["thinking"] as? [String: Any])?["type"] as? String,
            "disabled"
        )
        XCTAssertEqual(miniMax["max_completion_tokens"] as? Int, 320)
        XCTAssertNil(miniMax["max_tokens"])

        var miniMaxM2Configuration = AIProviderPreset.miniMax.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        miniMaxM2Configuration.generationModel = "MiniMax-M2.7"
        let miniMaxM2 = try await capturedSearchBody(for: miniMaxM2Configuration)
        XCTAssertEqual(miniMaxM2["reasoning_split"] as? Bool, true)
        XCTAssertEqual(miniMaxM2["max_completion_tokens"] as? Int, 65_536)
        XCTAssertNil(miniMaxM2["thinking"])
        XCTAssertNil(miniMaxM2["max_tokens"])

        var kimiCodeConfiguration = AIProviderPreset.kimi.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        kimiCodeConfiguration.generationModel = "kimi-k2.7-code"
        let kimiCode = try await capturedSearchBody(for: kimiCodeConfiguration)
        XCTAssertNil(kimiCode["reasoning_effort"])
        XCTAssertNil(kimiCode["thinking"])
        XCTAssertEqual(kimiCode["max_tokens"] as? Int, 16_000)

        let stepFun = try await capturedSearchBody(
            for: AIProviderPreset.stepFun.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(stepFun["model"] as? String, "step-3.5-flash-2603")
        XCTAssertEqual(stepFun["reasoning_effort"] as? String, "low")
        XCTAssertEqual(stepFun["max_tokens"] as? Int, 4_000)

        let xAI = try await capturedSearchBody(
            for: AIProviderPreset.xAI.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(xAI["reasoning_effort"] as? String, "low")
        XCTAssertEqual(xAI["max_tokens"] as? Int, 4_000)

        let groq = try await capturedSearchBody(
            for: AIProviderPreset.groq.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(groq["reasoning_effort"] as? String, "low")
        XCTAssertEqual(groq["max_completion_tokens"] as? Int, 4_000)
        XCTAssertNil(groq["max_tokens"])

        let together = try await capturedSearchBody(
            for: AIProviderPreset.togetherAI.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertEqual(together["reasoning_effort"] as? String, "low")
        XCTAssertEqual(together["max_tokens"] as? Int, 4_000)
    }

    func testDynamicAndCustomEndpointsDoNotReceiveUnsupportedControls() async throws {
        let openRouter = try await capturedSearchBody(
            for: AIProviderPreset.openRouter.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertNil(openRouter["reasoning"])
        XCTAssertNil(openRouter["reasoning_effort"])

        let fireworks = try await capturedSearchBody(
            for: AIProviderPreset.fireworksAI.applying(
                to: AIRemoteProviderConfiguration(isEnabled: true)
            )
        )
        XCTAssertNil(fireworks["reasoning"])
        XCTAssertNil(fireworks["reasoning_effort"])
        XCTAssertNil(fireworks["thinking"])

        let custom = try await capturedSearchBody(
            for: AIRemoteProviderConfiguration(
                baseURL: "https://api.deepseek.com.compat.invalid/v1",
                apiStyle: .chatCompletions,
                apiPathMode: .asEntered,
                authenticationStyle: .bearer,
                generationModel: "deepseek-v4-flash",
                isEnabled: true
            )
        )
        XCTAssertNil(custom["thinking"])
        XCTAssertNil(custom["reasoning"])
        XCTAssertEqual(custom["max_tokens"] as? Int, 320)
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
    func testSettingsRejectAudioTranscriptionWithoutACompatibleProvider() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        let provider = AIRemoteProviderConfiguration(
            baseURL: "https://text-only.invalid/v1",
            generationModel: "text-only-model",
            isEnabled: true
        )
        let store = AISettingsStore(defaults: defaults, syncsThroughICloud: false)

        XCTAssertThrowsError(try store.save(
            providerSet: AIRemoteProviderSet(
                providers: [provider],
                primaryProviderID: provider.id
            ),
            semanticSearchEnabled: false,
            recommendationsEnabled: false,
            audioTranscriptionEnabled: true,
            hasExplicitRemoteConsent: false,
            hasExplicitListeningContextConsent: false,
            hasExplicitAudioUploadConsent: true
        )) { error in
            XCTAssertEqual(
                error as? AIRemoteEndpointValidationError,
                .unsupportedCapability
            )
        }
        XCTAssertFalse(store.audioTranscriptionEnabled)
        XCTAssertFalse(store.hasExplicitAudioUploadConsent)
    }

    @MainActor
    func testSettingsPersistMultipleProvidersPrimaryAndFallbackOrder() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        let first = AIRemoteProviderConfiguration(
            displayName: "First",
            baseURL: "https://first.invalid/v1",
            generationModel: "first-model",
            isEnabled: true
        )
        var second = AIProviderPreset.gemini.applying(
            to: AIRemoteProviderConfiguration(
                displayName: "Second",
                isEnabled: true
            )
        )
        second.transcriptionModel = "gemini-legacy-transcribe"
        let store = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        try store.save(
            providerSet: AIRemoteProviderSet(
                providers: [first, second],
                primaryProviderID: second.id,
                fallbackEnabled: true
            ),
            semanticSearchEnabled: true,
            recommendationsEnabled: true,
            audioTranscriptionEnabled: true,
            hasExplicitRemoteConsent: true,
            hasExplicitListeningContextConsent: true,
            hasExplicitAudioUploadConsent: true
        )

        let reloaded = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        XCTAssertEqual(reloaded.providerSet.routedProviders.map(\.id), [second.id, first.id])
        XCTAssertTrue(reloaded.providerSet.fallbackEnabled)
        XCTAssertTrue(reloaded.semanticSearchEnabled)
        XCTAssertTrue(reloaded.recommendationsEnabled)
        XCTAssertTrue(reloaded.audioTranscriptionEnabled)
        XCTAssertTrue(reloaded.hasExplicitRemoteConsent)
        XCTAssertTrue(reloaded.hasExplicitListeningContextConsent)
        XCTAssertTrue(reloaded.hasExplicitAudioUploadConsent)
    }

    @MainActor
    func testVersionTwoSettingsMigrateWithoutGrantingListeningContextConsent() throws {
        struct LegacySettingsV2: Codable {
            var schemaVersion: Int
            var providerSet: AIRemoteProviderSet
            var semanticSearchEnabled: Bool
            var hasExplicitRemoteConsent: Bool
        }
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        let provider = AIRemoteProviderConfiguration(
            generationModel: "legacy-model",
            isEnabled: true
        )
        defaults.set(
            try JSONEncoder().encode(LegacySettingsV2(
                schemaVersion: 2,
                providerSet: AIRemoteProviderSet(
                    providers: [provider],
                    primaryProviderID: provider.id,
                    fallbackEnabled: false
                ),
                semanticSearchEnabled: true,
                hasExplicitRemoteConsent: true
            )),
            forKey: AISettingsStore.storageKey
        )

        let migrated = AISettingsStore(defaults: defaults, syncsThroughICloud: false)

        XCTAssertTrue(migrated.semanticSearchEnabled)
        XCTAssertTrue(migrated.hasExplicitRemoteConsent)
        XCTAssertFalse(migrated.recommendationsEnabled)
        XCTAssertFalse(migrated.hasExplicitListeningContextConsent)
        XCTAssertFalse(migrated.audioTranscriptionEnabled)
        XCTAssertFalse(migrated.hasExplicitAudioUploadConsent)
    }

    @MainActor
    func testLyricsTranscriptionSettingsMigrateWithoutChangingGeneralIntelligence() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        var legacyProvider = AIProviderPreset.gemini.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        legacyProvider.transcriptionModel = "gemini-legacy-transcribe"
        let general = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        try general.save(
            providerSet: AIRemoteProviderSet(
                providers: [legacyProvider],
                primaryProviderID: legacyProvider.id,
                fallbackEnabled: false
            ),
            semanticSearchEnabled: true,
            recommendationsEnabled: true,
            audioTranscriptionEnabled: true,
            hasExplicitRemoteConsent: true,
            hasExplicitListeningContextConsent: true,
            hasExplicitAudioUploadConsent: true
        )
        let dedicatedID = UUID()

        let lyrics = LyricsTranscriptionSettingsStore(
            defaults: defaults,
            legacySettingsStore: general,
            syncsThroughICloud: false,
            identifier: dedicatedID
        )

        XCTAssertEqual(lyrics.configuration.id, dedicatedID)
        XCTAssertNotEqual(lyrics.configuration.id, legacyProvider.id)
        XCTAssertEqual(
            lyrics.configuration.transcriptionModel,
            legacyProvider.transcriptionModel
        )
        XCTAssertTrue(lyrics.configuration.generationModel.isEmpty)
        XCTAssertTrue(lyrics.isEnabled)
        XCTAssertTrue(lyrics.hasExplicitAudioUploadConsent)
        XCTAssertFalse(lyrics.credentialMigrationCompleted)
        XCTAssertEqual(lyrics.legacyCredentialConfiguration?.id, legacyProvider.id)
        XCTAssertEqual(general.providerSet.primaryProvider.id, legacyProvider.id)
        XCTAssertTrue(general.semanticSearchEnabled)
        XCTAssertTrue(general.recommendationsEnabled)

        let reloaded = LyricsTranscriptionSettingsStore(
            defaults: defaults,
            legacySettingsStore: general,
            syncsThroughICloud: false,
            identifier: UUID()
        )
        XCTAssertEqual(reloaded.configuration.id, dedicatedID)
    }

    @MainActor
    func testLyricsTranscriptionCredentialMigrationCopiesWithoutRemovingLegacyKey() async throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        var legacyProvider = AIProviderPreset.gemini.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        legacyProvider.transcriptionModel = "gemini-legacy-transcribe"
        let general = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        try general.save(
            providerSet: AIRemoteProviderSet(
                providers: [legacyProvider],
                primaryProviderID: legacyProvider.id,
                fallbackEnabled: false
            ),
            semanticSearchEnabled: false,
            recommendationsEnabled: false,
            audioTranscriptionEnabled: true,
            hasExplicitRemoteConsent: false,
            hasExplicitListeningContextConsent: false,
            hasExplicitAudioUploadConsent: true
        )
        let lyrics = LyricsTranscriptionSettingsStore(
            defaults: defaults,
            legacySettingsStore: general,
            syncsThroughICloud: false,
            identifier: UUID()
        )
        let credentials = TestAICredentialStore()
        let ephemeralCredential = UUID().uuidString
        try await credentials.seed(ephemeralCredential, configuration: legacyProvider)
        let service = MusicIntelligenceService(
            settingsStore: general,
            lyricsTranscriptionSettingsStore: lyrics,
            credentialStore: credentials
        )

        await service.prepareLyricsTranscriptionCredentialMigration()
        XCTAssertTrue(service.lyricsTranscriptionCredentialAvailable)

        guard case .ready(let dedicatedCredential) = await credentials.lookupAPIKey(
            configuration: lyrics.configuration
        ), dedicatedCredential == ephemeralCredential else {
            XCTFail("The dedicated transcription credential should be copied")
            return
        }
        guard case .ready(let preservedCredential) = await credentials.lookupAPIKey(
            configuration: legacyProvider
        ), preservedCredential == ephemeralCredential else {
            XCTFail("The general intelligence credential should remain available")
            return
        }
        XCTAssertTrue(lyrics.credentialMigrationCompleted)
    }

    @MainActor
    func testGeneralCredentialDeletionIsBlockedUntilTranscriptionCopySucceeds() async throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        var legacyProvider = AIProviderPreset.gemini.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        legacyProvider.transcriptionModel = "gemini-legacy-transcribe"
        let general = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        try general.save(
            providerSet: AIRemoteProviderSet(
                providers: [legacyProvider],
                primaryProviderID: legacyProvider.id,
                fallbackEnabled: false
            ),
            semanticSearchEnabled: false,
            recommendationsEnabled: false,
            audioTranscriptionEnabled: true,
            hasExplicitRemoteConsent: false,
            hasExplicitListeningContextConsent: false,
            hasExplicitAudioUploadConsent: true
        )
        let lyrics = LyricsTranscriptionSettingsStore(
            defaults: defaults,
            legacySettingsStore: general,
            syncsThroughICloud: false,
            identifier: UUID()
        )
        let credentials = TestAICredentialStore(
            blockedSaveProfileIDs: [lyrics.configuration.id]
        )
        let ephemeralCredential = UUID().uuidString
        try await credentials.seed(ephemeralCredential, configuration: legacyProvider)
        let service = MusicIntelligenceService(
            settingsStore: general,
            lyricsTranscriptionSettingsStore: lyrics,
            credentialStore: credentials
        )

        do {
            try await service.deleteAPIKey(configuration: legacyProvider)
            XCTFail("The legacy key must remain while the dedicated copy cannot be written")
        } catch {
            XCTAssertTrue(error is AICredentialStoreError)
        }
        guard case .ready(let preservedCredential) = await credentials.lookupAPIKey(
            configuration: legacyProvider
        ), preservedCredential == ephemeralCredential else {
            XCTFail("The legacy credential must remain available after a failed copy")
            return
        }
        XCTAssertFalse(lyrics.credentialMigrationCompleted)

        await credentials.allowSaves(for: lyrics.configuration.id)
        try await service.deleteAPIKey(configuration: legacyProvider)

        guard case .ready(let dedicatedCredential) = await credentials.lookupAPIKey(
            configuration: lyrics.configuration
        ), dedicatedCredential == ephemeralCredential else {
            XCTFail("The dedicated credential should exist before the legacy key is removed")
            return
        }
        guard case .notConfigured = await credentials.lookupAPIKey(
            configuration: legacyProvider
        ) else {
            XCTFail("The legacy credential should be removed after the copy succeeds")
            return
        }
        XCTAssertTrue(lyrics.credentialMigrationCompleted)
    }

    @MainActor
    func testFreshLyricsTranscriptionSettingsDoNotAssumeModelRelease() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        let general = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        let lyrics = LyricsTranscriptionSettingsStore(
            defaults: defaults,
            legacySettingsStore: general,
            syncsThroughICloud: false,
            identifier: UUID()
        )

        XCTAssertTrue(lyrics.configuration.transcriptionModel.isEmpty)
        XCTAssertFalse(lyrics.isEnabled)
        XCTAssertTrue(lyrics.credentialMigrationCompleted)
        XCTAssertTrue(lyrics.awaitsLegacySettingsMigration)
        XCTAssertNotNil(defaults.data(forKey: LyricsTranscriptionSettingsStore.storageKey))
    }

    @MainActor
    func testLyricsTranscriptionSettingsAdoptLegacyConfigurationThatArrivesLater() throws {
        let defaults = try XCTUnwrap(UserDefaults(
            suiteName: "OpenAICompatibleProviderTests.\(UUID().uuidString)"
        ))
        let general = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        let dedicatedID = UUID()
        let lyrics = LyricsTranscriptionSettingsStore(
            defaults: defaults,
            legacySettingsStore: general,
            syncsThroughICloud: false,
            identifier: dedicatedID
        )
        var legacyProvider = AIProviderPreset.gemini.applying(
            to: AIRemoteProviderConfiguration(isEnabled: true)
        )
        legacyProvider.transcriptionModel = "gemini-later-transcribe"
        try general.save(
            providerSet: AIRemoteProviderSet(
                providers: [legacyProvider],
                primaryProviderID: legacyProvider.id,
                fallbackEnabled: false
            ),
            semanticSearchEnabled: true,
            recommendationsEnabled: true,
            audioTranscriptionEnabled: true,
            hasExplicitRemoteConsent: true,
            hasExplicitListeningContextConsent: true,
            hasExplicitAudioUploadConsent: true
        )

        XCTAssertTrue(lyrics.adoptLegacySettingsIfNeeded(from: general))
        XCTAssertEqual(lyrics.configuration.id, dedicatedID)
        XCTAssertEqual(
            lyrics.configuration.transcriptionModel,
            legacyProvider.transcriptionModel
        )
        XCTAssertTrue(lyrics.isEnabled)
        XCTAssertTrue(lyrics.hasExplicitAudioUploadConsent)
        XCTAssertEqual(lyrics.legacyCredentialConfiguration?.id, legacyProvider.id)
        XCTAssertFalse(lyrics.credentialMigrationCompleted)
        XCTAssertFalse(lyrics.awaitsLegacySettingsMigration)

        let reloaded = LyricsTranscriptionSettingsStore(
            defaults: defaults,
            legacySettingsStore: general,
            syncsThroughICloud: false,
            identifier: UUID()
        )
        XCTAssertEqual(reloaded.configuration.id, dedicatedID)
        XCTAssertFalse(reloaded.awaitsLegacySettingsMigration)
    }

    @MainActor
    func testSystemAndIntelligentLyricsCachesRemainMutuallyExclusive() {
        let cache = LyricsTranslationCache.shared
        cache.clearAll()
        defer { cache.clearAll() }

        cache.setTranslation(
            "system result",
            for: "source line",
            sourceLang: "en",
            targetLang: "zh-Hans",
            provider: .system
        )
        XCTAssertEqual(
            cache.translation(
                for: "source line",
                sourceLang: "en",
                targetLang: "zh-Hans",
                provider: .system
            ),
            "system result"
        )
        XCTAssertNil(cache.translation(
            for: "source line",
            sourceLang: "en",
            targetLang: "zh-Hans",
            provider: .intelligent
        ))

        cache.setTranslation(
            "intelligent result",
            for: "source line",
            sourceLang: "en",
            targetLang: "zh-Hans",
            provider: .intelligent
        )
        XCTAssertEqual(
            cache.translation(
                for: "source line",
                sourceLang: "en",
                targetLang: "zh-Hans",
                provider: .intelligent
            ),
            "intelligent result"
        )
        XCTAssertEqual(
            cache.translation(
                for: "source line",
                sourceLang: "en",
                targetLang: "zh-Hans",
                provider: .system
            ),
            "system result"
        )
    }

    @MainActor
    func testConnectionDiagnosticsDoNotRequireContentSharingConsent() {
        let editor = AISettingsEditorModel()
        editor.apiKeyDraft = "test-key"
        editor.draftConfiguration.baseURL = "https://api.example.com/v1"
        editor.draftConfiguration.generationModel = "test-model"

        XCTAssertFalse(editor.canFetchModels)
        XCTAssertFalse(editor.canTestConnection)
        editor.didLoad = true
        XCTAssertTrue(editor.canFetchModels)
        XCTAssertTrue(editor.canTestConnection)
        XCTAssertFalse(editor.consent)
    }

    @MainActor
    func testOpenAIPlatformSettingsCopyAndCredentialValidationStayScopedToOfficialAPI() {
        let editor = AISettingsEditorModel()
        editor.applyProviderPreset(.openAI)

        XCTAssertTrue(editor.usesOpenAIPlatformAPI)
        XCTAssertEqual(
            editor.apiKeyTitle,
            String(localized: "ai_openai_platform_api_key")
        )
        XCTAssertTrue(editor.providerFooterText.contains(
            String(localized: "ai_provider_footer")
        ))
        XCTAssertTrue(editor.providerFooterText.contains(
            String(localized: "ai_openai_platform_billing_footer")
        ))
        XCTAssertEqual(
            AISettingsEditorModel.message(
                for: OpenAICompatibleProviderError.missingCredential,
                configuration: editor.draftConfiguration
            ),
            String(localized: "ai_error_missing_openai_platform_key")
        )

        editor.draftConfiguration.baseURL = "https://relay.example.invalid/v1"

        XCTAssertFalse(editor.usesOpenAIPlatformAPI)
        XCTAssertEqual(editor.apiKeyTitle, String(localized: "ai_api_key"))
        XCTAssertEqual(
            editor.providerFooterText,
            String(localized: "ai_provider_footer")
        )
        XCTAssertEqual(
            AISettingsEditorModel.message(
                for: OpenAICompatibleProviderError.missingCredential,
                configuration: editor.draftConfiguration
            ),
            String(localized: "ai_error_missing_key")
        )
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
        XCTAssertTrue(editor.draftConfiguration.prefersCustomConfiguration)
        XCTAssertEqual(
            AIProviderPreset.matching(configuration: editor.draftConfiguration),
            .custom
        )
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

    @MainActor
    func testProviderReorderingAndSwitchesControlFallbackOrder() {
        let editor = AISettingsEditorModel()
        let primaryID = editor.draftProviderSet.primaryProviderID
        editor.addProvider()
        let secondID = editor.selectedProviderID
        editor.addProvider()
        let thirdID = editor.selectedProviderID

        editor.moveProvider(thirdID, offset: -1)

        XCTAssertEqual(
            editor.draftProviderSet.routedProviders.map(\.id),
            [primaryID, thirdID, secondID]
        )

        editor.providerEnabledBinding(thirdID).wrappedValue = false

        XCTAssertEqual(
            editor.draftProviderSet.routedProviders.map(\.id),
            [primaryID, secondID]
        )
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

    private func capturedSearchBody(
        for configuration: AIRemoteProviderConfiguration
    ) async throws -> [String: Any] {
        let host = try XCTUnwrap(URL(string: configuration.baseURL)?.host)
        let responseBody: String
        switch configuration.apiStyle {
        case .responses:
            responseBody = #"{"output_text":"{\"expanded_terms\":[\"calm\"],\"themes\":[],\"moods\":[]}"}"#
        case .chatCompletions:
            responseBody = #"{"choices":[{"message":{"content":"{\"expanded_terms\":[\"calm\"],\"themes\":[],\"moods\":[]}"}}]}"#
        case .anthropicMessages:
            responseBody = #"{"content":[{"type":"text","text":"{\"expanded_terms\":[\"calm\"],\"themes\":[],\"moods\":[]}"}]}"#
        case .geminiGenerateContent:
            responseBody = #"{"candidates":[{"content":{"parts":[{"text":"{\"expanded_terms\":[\"calm\"],\"themes\":[],\"moods\":[]}"}]}}]}"#
        }
        IntelligenceURLProtocol.configure(host: host, statusCode: 200, body: responseBody)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [IntelligenceURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = OpenAICompatibleProvider(
            configuration: configuration,
            credentialStore: TestAICredentialStore(),
            apiKeyOverride: "provider-test-key",
            session: session
        )

        _ = try await provider.interpretSearch(
            AISemanticSearchRequest(query: "quiet music")
        )

        let request = try XCTUnwrap(IntelligenceURLProtocol.requests(host: host).first)
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

private actor TestAICredentialStore: AICredentialStoring {
    private var keys: [String: String] = [:]
    private var blockedSaveProfileIDs: Set<UUID>

    init(blockedSaveProfileIDs: Set<UUID> = []) {
        self.blockedSaveProfileIDs = blockedSaveProfileIDs
    }

    func allowSaves(for profileID: UUID) {
        blockedSaveProfileIDs.remove(profileID)
    }

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
        guard !blockedSaveProfileIDs.contains(configuration.id) else {
            throw AICredentialStoreError.persistenceFailed
        }
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
        var headerFields: [String: String] = [:]
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

    static func configureSequence(
        host: String,
        responses: [(statusCode: Int, body: String, headerFields: [String: String])]
    ) {
        lock.lock()
        states[host] = State(responses: responses.map {
            StubResponse(
                statusCode: $0.statusCode,
                chunks: [Data($0.body.utf8)],
                headerFields: $0.headerFields
            )
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

        var headerFields = stub.headerFields
        if !headerFields.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            headerFields["Content-Type"] = "application/json"
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: headerFields
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
