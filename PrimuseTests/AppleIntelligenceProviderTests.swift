import Foundation
import PrimuseKit
import XCTest
#if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
import FoundationModels
#endif
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class AppleIntelligenceProviderTests: XCTestCase {
    @MainActor
    func testAppleSettingsPersistAndDoNotGrantRemoteConsent() async throws {
        let suite = "AppleIntelligenceSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        let intelligence = MusicIntelligenceService(settingsStore: settings, credentialStore: AppleTestCredentials())
        let editor = AISettingsEditorModel()
        editor.applyProviderPreset(.appleOnDevice)
        var local = editor.draftConfiguration
        local.isEnabled = true
        try settings.save(providerSet: .init(providers: [local], primaryProviderID: local.id, fallbackEnabled: true),
            primuseRelayEnabled: false, semanticSearchEnabled: true, recommendationsEnabled: false,
            audioTranscriptionEnabled: false, hasExplicitRemoteConsent: false, hasExplicitListeningContextConsent: false,
            hasExplicitAudioUploadConsent: false)
        let restored = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        XCTAssertEqual(restored.providerSet.primaryProvider.backend, .appleOnDevice)
        XCTAssertFalse(restored.hasExplicitRemoteConsent)
        #if os(tvOS)
        XCTAssertFalse(intelligence.isSemanticSearchConfigured)
        XCTAssertFalse(intelligence.isSpokenChaptersAvailable)
        #else
        XCTAssertTrue(intelligence.isSemanticSearchConfigured)
        XCTAssertTrue(intelligence.isSpokenChaptersAvailable)
        #endif
        XCTAssertTrue(editor.hasUsableAPIKey)
        XCTAssertFalse(editor.hasStoredAPIKeyForDraft)
        XCTAssertTrue(editor.apiKeyDraft.isEmpty)
    }

    #if os(tvOS)
    @MainActor
    func testTVRoutesSyncedAppleProfilesOnlyToExplicitlyEnabledFallbacks() throws {
        let suite = "AppleIntelligenceTV-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AISettingsStore(defaults: defaults, syncsThroughICloud: false)
        let local = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
        let cloud = AIProviderPreset.applePrivateCloudCompute.applying(to: .init(isEnabled: true))
        let remote = AIProviderPreset.groq.applying(to: .init(isEnabled: true))
        var providerSet = AIRemoteProviderSet(providers: [local, cloud, remote],
            primaryProviderID: local.id, fallbackEnabled: true)
        let intelligence = MusicIntelligenceService(settingsStore: settings, credentialStore: AppleTestCredentials())
        let editor = AISettingsEditorModel()
        editor.draftProviderSet = providerSet
        XCTAssertEqual(editor.routableProviders.map(\.id), [remote.id])
        for fallback in [true, false] {
            providerSet.fallbackEnabled = fallback
            providerSet.setRoute(.provider(id: cloud.id, model: ""), for: .spokenChapters)
            try settings.save(providerSet: providerSet, primuseRelayEnabled: false,
                semanticSearchEnabled: true, recommendationsEnabled: false,
                audioTranscriptionEnabled: false, hasExplicitRemoteConsent: false,
                hasExplicitListeningContextConsent: false, hasExplicitAudioUploadConsent: false)
            XCTAssertEqual(intelligence.routedProviders(for: .spokenChapters).map(\.id), fallback ? [remote.id] : [])
            XCTAssertEqual(intelligence.routedProviders(for: .semanticSearch).map(\.id), fallback ? [remote.id] : [])
            XCTAssertFalse(intelligence.isSemanticSearchConfigured)
            XCTAssertFalse(intelligence.isSpokenChaptersAvailable)
            XCTAssertEqual(settings.providerSet.providers.map(\.backend), [.appleOnDevice, .applePrivateCloudCompute, .remote])
            XCTAssertFalse(settings.hasExplicitRemoteConsent)
        }
    }

    func testTVNativeModelsRemainUnavailableWithoutCredentialAccess() async throws {
        let credentials = AppleTestCredentials()
        for preset in [AIProviderPreset.appleOnDevice, .applePrivateCloudCompute] {
            let provider = OpenAICompatibleProvider(configuration: preset.applying(to: .init(isEnabled: true)),
                credentialStore: credentials)
            let availability = await provider.runtimeAvailability()
            XCTAssertEqual(availability, .unavailable(.unsupportedDevice))
            do {
                _ = try await provider.interpretSearch(.init(query: "quiet music", languageCode: "en"))
                XCTFail("tvOS must not call Apple inference")
            } catch {
                XCTAssertEqual(error as? AppleIntelligenceError, .unavailable)
            }
        }
        let accesses = await credentials.accesses
        XCTAssertEqual(accesses, 0)
    }
    #endif

    func testOnDeviceFirstEscalatesOnlyForCapacityOrAvailabilityWithConsent() async throws {
        for enabled in [true, false] {
            for consent in [true, false] {
                let recorder = AppleRequestRecorder()
                var configuration = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
                configuration.allowsPrivateCloudComputeFallback = enabled
                let provider = OpenAICompatibleProvider(configuration: configuration, credentialStore: AppleTestCredentials(),
                    appleIntelligence: .init(availability: { _ in .available }, generate: { backend, _, _, _ in
                        await recorder.record([backend.rawValue])
                        if backend == .appleOnDevice { throw AppleIntelligenceError.contextLimit }
                        return #"{"expanded_terms":["piano"],"moods":[],"themes":[]}"#
                    }), appleCloudAuthorization: { consent })
                do {
                    _ = try await provider.interpretSearch(.init(query: "quiet music", languageCode: "en"))
                    XCTAssertTrue(enabled && consent)
                } catch { XCTAssertFalse(enabled && consent) }
                let requests = await recorder.requests.flatMap { $0 }
                XCTAssertEqual(requests, enabled && consent
                    ? [AIProviderBackend.appleOnDevice.rawValue, AIProviderBackend.applePrivateCloudCompute.rawValue]
                    : [AIProviderBackend.appleOnDevice.rawValue])
            }
        }
    }

    func testHybridKeepsSuccessfulLocalOutputAndNeverEscalatesRefusalOrQuota() async throws {
        for failure in [nil, AppleIntelligenceError.refused, .quotaReached] {
            let recorder = AppleRequestRecorder()
            var configuration = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
            configuration.allowsPrivateCloudComputeFallback = true
            let provider = OpenAICompatibleProvider(configuration: configuration, credentialStore: AppleTestCredentials(),
                appleIntelligence: .init(availability: { _ in .available }, generate: { backend, _, _, _ in
                    await recorder.record([backend.rawValue])
                    if let failure { throw failure }
                    return #"{"expanded_terms":["piano"],"moods":[],"themes":[]}"#
                }), appleCloudAuthorization: { true })
            do { _ = try await provider.interpretSearch(.init(query: "quiet music", languageCode: "en")); XCTAssertNil(failure) }
            catch { XCTAssertNotNil(failure) }
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testHybridCancellationDoesNotStartCloudInference() async throws {
        let recorder = AppleRequestRecorder()
        var configuration = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
        configuration.allowsPrivateCloudComputeFallback = true
        let provider = OpenAICompatibleProvider(configuration: configuration, credentialStore: AppleTestCredentials(),
            appleIntelligence: .init(availability: { _ in .available }, generate: { backend, _, _, _ in
                await recorder.record([backend.rawValue]); throw CancellationError()
            }), appleCloudAuthorization: { true })
        do {
            _ = try await provider.interpretSearch(.init(query: "quiet music", languageCode: "en"))
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testHybridRechecksConsentBeforeAndAfterCloudInference() async throws {
        for revokeDuringCloud in [true, false] {
            let consent = AppleCloudConsent()
            let recorder = AppleRequestRecorder()
            var configuration = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
            configuration.allowsPrivateCloudComputeFallback = true
            let provider = OpenAICompatibleProvider(configuration: configuration, credentialStore: AppleTestCredentials(),
                appleIntelligence: .init(availability: { _ in .available }, generate: { backend, _, _, _ in
                    await recorder.record([backend.rawValue])
                    if backend == .appleOnDevice {
                        if !revokeDuringCloud { await consent.revoke() }
                        throw AppleIntelligenceError.contextLimit
                    }
                    await consent.revoke()
                    return #"{"expanded_terms":["piano"],"moods":[],"themes":[]}"#
                }), appleCloudAuthorization: { await consent.allowed })
            do {
                _ = try await provider.interpretSearch(.init(query: "quiet music", languageCode: "en"))
                XCTFail("Revoked cloud consent must not publish a cloud result")
            } catch {}
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, revokeDuringCloud ? 2 : 1)
        }
    }

    func testDailyQuotaIsReportedAsQuotaRatherThanNetworkFailure() {
        XCTAssertEqual(AIRecommendationFallbackReason.classify(AppleIntelligenceError.quotaReached), .dailyLimit)
        XCTAssertEqual(AIRecommendationFallbackReason.classify(AppleIntelligenceQuotaFailure(resetDate: Date())), .dailyLimit)
        XCTAssertEqual(AIRecommendationFallbackReason.classify(AppleIntelligenceError.modelNotReady), .unavailable)
    }

    func testNativeSearchUsesValidatedPlanWithoutReadingCredentials() async throws {
        let credentials = AppleTestCredentials()
        let provider = provider(.applePrivateCloudCompute, credentials: credentials) { _, _, _, _ in
            #"{"expanded_terms":["piano","piano"],"moods":["calm"],"themes":[]}"#
        }
        let availability = await provider.runtimeAvailability()
        XCTAssertEqual(availability, .available)
        let plan = try await provider.interpretSearch(.init(query: "quiet music", languageCode: "en"))
        XCTAssertEqual(plan.expandedTerms, ["piano"])
        XCTAssertEqual(plan.moods, ["calm"])
        let accesses = await credentials.accesses
        XCTAssertEqual(accesses, 0)
    }

    func testLocalLyricsBatchingPreservesEveryLine() async throws {
        let recorder = AppleRequestRecorder()
        let provider = provider(.appleOnDevice) { _, _, input, _ in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let lines = try XCTUnwrap(object["lines"] as? [[String: String]])
            XCTAssertLessThanOrEqual(lines.count, 4)
            let ids = lines.compactMap { $0["id"] }
            await recorder.record(ids)
            let response = ["translations": ids.map { ["id": $0, "text": "Translated \($0)"] }]
            return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        }
        let lines = (0..<11).map { LyricTranslationCandidate(id: String($0), text: "Line \($0)", sourceLanguageCode: "en") }
        let result = try await provider.translateLyrics(lines, targetLanguageCode: "zh-Hans")
        XCTAssertEqual(Set(result.keys), Set(lines.map(\.id)))
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.count), [4, 4, 3])
        XCTAssertEqual(requests.flatMap { $0 }, lines.map(\.id))
    }

    func testNativeProviderCannotBypassRevokedAuthorization() async throws {
        let configuration = AIProviderPreset.applePrivateCloudCompute.applying(to: .init(isEnabled: true))
        let provider = OpenAICompatibleProvider(configuration: configuration, credentialStore: AppleTestCredentials(),
            requestAuthorization: { false }, appleIntelligence: .init(availability: { _ in .available }, generate: { _, _, _, _ in
                XCTFail("No model request after authorization is revoked")
                return "{}"
            }))
        do {
            _ = try await provider.interpretSearch(.init(query: "music"))
            XCTFail("Expected authorization failure")
        } catch MusicIntelligenceError.unavailable(.regionRestricted) { }
    }

    func testLocalRecommendationsVisitAllCandidatesAndKeepOriginalIDs() async throws {
        let recorder = AppleRequestRecorder()
        let provider = provider(.appleOnDevice) { _, _, input, _ in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let songs = try XCTUnwrap(object["candidates"] as? [[String: Any]])
            let count = try XCTUnwrap(object["maximum_results"] as? Int)
            XCTAssertLessThanOrEqual(songs.count, 12)
            await recorder.record(songs.compactMap { $0["title"] as? String })
            let selections = songs.prefix(count).map { ["id": $0["id"] as! String, "reason": "Fits the scene"] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["recommendations": selections]), as: UTF8.self)
        }
        let songs = (0..<35).map { AIRecommendationCandidate(songID: "song-\($0)", title: "Title \($0)", artist: "Artist \($0)") }
        let plan = try await provider.recommendations(.init(scene: .focus, preferences: [], candidates: songs,
                                                           maximumResults: 9, minimumResults: 9))
        let requests = await recorder.requests
        XCTAssertEqual(requests.flatMap { $0 }, songs.map(\.title))
        XCTAssertEqual(plan.selections.count, 9)
        XCTAssertTrue(Set(plan.selections.map(\.songID)).isSubset(of: Set(songs.map(\.songID))))
    }

    func testQuotaAndCancellationAreNotReplayed() async throws {
        for quota in [true, false] {
            let recorder = AppleRequestRecorder()
            let provider = provider(.applePrivateCloudCompute) { _, _, _, _ in
                await recorder.record(["called"])
                if quota { throw AppleIntelligenceError.quotaReached }
                throw CancellationError()
            }
            do {
                _ = try await provider.interpretSearch(.init(query: "music"))
                XCTFail("Expected failure")
            } catch {
                if quota { XCTAssertEqual(error as? AppleIntelligenceError, .quotaReached) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testUnsupportedOrPreparingModelDoesNotLookForAPIKey() async {
        for reason: AIProviderUnavailableReason in [.unsupportedDevice, .modelNotReady, .missingConfiguration] {
            let credentials = AppleTestCredentials()
            let provider = OpenAICompatibleProvider(
                configuration: AIProviderPreset.applePrivateCloudCompute.applying(to: .init(isEnabled: true)),
                credentialStore: credentials,
                appleIntelligence: .init(availability: { _ in .unavailable(reason) }, generate: { _, _, _, _ in "" }))
            let availability = await provider.runtimeAvailability()
            XCTAssertEqual(availability, .unavailable(reason))
            let accesses = await credentials.accesses
            XCTAssertEqual(accesses, 0)
        }
    }

    func testAppleChapterResponseRejectsInventedTimeline() async throws {
        let provider = provider(.applePrivateCloudCompute) { _, _, _, _ in
            #"{"summary":"Story","chapters":[{"lineID":"invented","title":"Opening"}]}"#
        }
        do {
            _ = try await provider.spokenChapters(.init(title: "Book", language: "en",
                lines: [.init(id: "0", start: 0, text: "Opening")]))
            XCTFail("Unknown boundaries must never become seek positions")
        } catch { XCTAssertEqual(error as? SpokenChapterGeneration.Failure, .invalidResponse) }
    }

    func testChaptersUseStructuredGenerationAndPreserveOriginalBoundaries() async throws {
        let credentials = AppleTestCredentials()
        let recorder = AppleRequestRecorder()
        let provider = OpenAICompatibleProvider(
            configuration: AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true)),
            credentialStore: credentials,
            appleIntelligence: .init(availability: { _ in .available }, generate: { _, _, _, _ in
                XCTFail("Chapters must use guided generation when available")
                return ""
            }, generateChapters: { backend, request in
                await recorder.record([backend.rawValue, request.stage.rawValue])
                return .init(summary: "Story", chapters: request.stage == .curate ? request.candidates
                    : request.lines.map { .init(lineID: $0.id, title: "Chapter \($0.id)") })
            }))
        let chapters = try await SpokenChapterGeneration.generate(title: "Book", language: "en",
            lines: [.init(id: "a", start: 17, text: "Opening"), .init(id: "b", start: 720, text: "Next topic")],
            ask: { try await provider.spokenChapters($0) })
        XCTAssertEqual(chapters.map(\.startTime), [17, 720])
        let calls = await recorder.requests
        XCTAssertEqual(calls, [["appleOnDevice", "analyze"], ["appleOnDevice", "curate"]])
        let accesses = await credentials.accesses
        XCTAssertEqual(accesses, 0)
    }

    func testInvalidChapterJSONFallsBackOnlyWithBothOptInAndConsent() async throws {
        for enabled in [false, true] {
            for consent in [false, true] {
                let recorder = AppleRequestRecorder()
                var configuration = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
                configuration.allowsPrivateCloudComputeFallback = enabled
                let provider = OpenAICompatibleProvider(configuration: configuration, credentialStore: AppleTestCredentials(),
                    appleIntelligence: .init(availability: { _ in .available }, generate: { backend, _, _, _ in
                        await recorder.record([backend.rawValue])
                        if backend == .appleOnDevice { return #"{"summary":"Story","chapters":["# }
                        return #"{"summary":"Story","chapters":[{"lineID":"0","title":"Opening"}]}"#
                    }), appleCloudAuthorization: { consent })
                do {
                    let answer = try await provider.spokenChapters(chapterRequest)
                    XCTAssertTrue(enabled && consent)
                    XCTAssertEqual(answer.chapters.map(\.lineID), ["0"])
                } catch {
                    XCTAssertFalse(enabled && consent)
                    XCTAssertEqual(error as? SpokenChapterGeneration.Failure, .invalidResponse)
                }
                let calls = await recorder.requests
                XCTAssertEqual(calls.count, enabled && consent ? 2 : 1)
                XCTAssertEqual(calls.last?.first, enabled && consent ? "applePrivateCloudCompute" : "appleOnDevice")
            }
        }
    }

    func testGuidedChapterOutputStillValidatesIDsOrderAndCurationAnchorBeforeFallback() async throws {
        let request = SpokenChapterGeneration.Request(title: "Book", language: "en", stage: .curate,
            lines: [.init(id: "0", start: 0, text: "Opening"), .init(id: "1", start: 600, text: "Next topic")],
            candidates: [.init(lineID: "0", title: "Opening"), .init(lineID: "1", title: "Next")])
        for ids in [["invented"], ["1", "0"], ["0", "0"], ["1"]] {
            let recorder = AppleRequestRecorder()
            let provider = chapterProvider(recorder: recorder) { backend, request in
                .init(summary: "Story", chapters: backend == .appleOnDevice
                    ? ids.map { .init(lineID: $0, title: "Topic") } : request.candidates)
            }
            let result = try await provider.spokenChapters(request)
            XCTAssertEqual(result.chapters, request.candidates)
            let calls = await recorder.requests
            XCTAssertEqual(calls.flatMap { $0 }, ["appleOnDevice", "applePrivateCloudCompute"])
        }
    }

    func testChapterFallbackDoesNotReplayCloudFailureOrLoseQuotaResetDate() async throws {
        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        for quota in [false, true] {
            let recorder = AppleRequestRecorder()
            let provider = chapterProvider(recorder: recorder) { backend, _ in
                if backend == .applePrivateCloudCompute && quota { throw AppleIntelligenceQuotaFailure(resetDate: reset) }
                throw SpokenChapterGeneration.Failure.invalidResponse
            }
            do { _ = try await provider.spokenChapters(chapterRequest); XCTFail("Expected failure") }
            catch {
                if quota { XCTAssertEqual((error as? AppleIntelligenceQuotaFailure)?.resetDate, reset) }
                else { XCTAssertEqual(error as? SpokenChapterGeneration.Failure, .invalidResponse) }
            }
            let calls = await recorder.requests
            XCTAssertEqual(calls.flatMap { $0 }, ["appleOnDevice", "applePrivateCloudCompute"])
        }
    }

    func testChapterRefusalQuotaNetworkAndCancellationDoNotEscalate() async throws {
        let errors: [any Error] = [AppleIntelligenceError.refused, AppleIntelligenceQuotaFailure(resetDate: nil),
                                  URLError(.notConnectedToInternet), CancellationError()]
        for error in errors {
            let recorder = AppleRequestRecorder()
            let provider = chapterProvider(recorder: recorder) { _, _ in throw error }
            do { _ = try await provider.spokenChapters(chapterRequest); XCTFail("Expected failure") }
            catch { }
            let calls = await recorder.requests
            XCTAssertEqual(calls.flatMap { $0 }, ["appleOnDevice"])
        }
    }

    func testChapterValidationFallbackRechecksCloudConsent() async throws {
        for revokeDuringCloud in [false, true] {
            let consent = AppleCloudConsent()
            let recorder = AppleRequestRecorder()
            let provider = chapterProvider(recorder: recorder, consent: { await consent.allowed }) { backend, _ in
                if backend == .appleOnDevice {
                    if !revokeDuringCloud { await consent.revoke() }
                    throw SpokenChapterGeneration.Failure.invalidResponse
                }
                await consent.revoke()
                return .init(summary: "Story", chapters: [.init(lineID: "0", title: "Opening")])
            }
            do { _ = try await provider.spokenChapters(chapterRequest); XCTFail("Revoked consent must stop the result") }
            catch { }
            let calls = await recorder.requests
            XCTAssertEqual(calls.count, revokeDuringCloud ? 2 : 1)
        }
    }

    func testDirectPCCChapterValidationFailureIsNotRetried() async throws {
        let recorder = AppleRequestRecorder()
        let provider = provider(.applePrivateCloudCompute) { backend, _, _, _ in
            await recorder.record([backend.rawValue])
            return "not JSON"
        }
        do { _ = try await provider.spokenChapters(chapterRequest); XCTFail("Expected invalid response") }
        catch { XCTAssertEqual(error as? SpokenChapterGeneration.Failure, .invalidResponse) }
        let calls = await recorder.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testStructuredResponseBudgetCountsSchemaAndReservesOutputSpace() throws {
        XCTAssertEqual(try AppleIntelligenceRuntime.responseBudget(contextSize: 4_096, inputTokens: 1_000,
            instructionTokens: 500, schemaTokens: 400, maximumTokens: 4_000, minimumTokens: 1_024), 1_940)
        XCTAssertEqual(try AppleIntelligenceRuntime.responseBudget(contextSize: 8_192, inputTokens: 1_000,
            instructionTokens: 500, schemaTokens: 400, maximumTokens: 4_000, minimumTokens: 1_024), 4_000)
        XCTAssertThrowsError(try AppleIntelligenceRuntime.responseBudget(contextSize: 4_096, inputTokens: 2_000,
            instructionTokens: 500, schemaTokens: 400, maximumTokens: 4_000, minimumTokens: 1_024)) {
            XCTAssertEqual($0 as? AppleIntelligenceError, .contextLimit)
        }
    }

    #if canImport(FoundationModels) && !os(tvOS) && !os(watchOS)
    func testNativeChapterSchemaSupportsAnalysisAndCurationWithSplitCueIDs() throws {
        guard #available(iOS 26, macOS 26, visionOS 26, *) else { throw XCTSkip("Requires Foundation Models") }
        var request = chapterRequest
        request.lines.append(.init(id: "1.2", start: 600, text: "Split cue"))
        let analyze = try AppleIntelligenceRuntime.chapterSchema(for: request)
        request.stage = .curate
        request.candidates = [.init(lineID: "1.2", title: "Topic")]
        let curate = try AppleIntelligenceRuntime.chapterSchema(for: request)
        func enumValues(_ value: Any) -> [String] {
            if let object = value as? [String: Any] {
                return (object["enum"] as? [String] ?? []) + object.filter { $0.key != "enum" }.values.flatMap(enumValues)
            }
            return (value as? [Any] ?? []).flatMap(enumValues)
        }
        XCTAssertEqual(Set(enumValues(try JSONSerialization.jsonObject(with: JSONEncoder().encode(analyze)))), ["0", "1.2"])
        XCTAssertEqual(Set(enumValues(try JSONSerialization.jsonObject(with: JSONEncoder().encode(curate)))), ["1.2"])
    }
    #endif

    private var chapterRequest: SpokenChapterGeneration.Request {
        .init(title: "Book", language: "en", lines: [.init(id: "0", start: 0, text: "Opening")])
    }

    private func chapterProvider(recorder: AppleRequestRecorder,
        consent: @escaping @Sendable () async -> Bool = { true },
        generate: @escaping @Sendable (AIProviderBackend, SpokenChapterGeneration.Request) async throws -> SpokenChapterGeneration.Answer
    ) -> OpenAICompatibleProvider {
        var configuration = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
        configuration.allowsPrivateCloudComputeFallback = true
        return OpenAICompatibleProvider(configuration: configuration, credentialStore: AppleTestCredentials(),
            appleIntelligence: .init(availability: { _ in .available }, generate: { _, _, _, _ in
                XCTFail("Expected structured generation"); return ""
            }, generateChapters: { backend, request in
                await recorder.record([backend.rawValue])
                return try await generate(backend, request)
            }), appleCloudAuthorization: consent)
    }

    private func provider(_ preset: AIProviderPreset, credentials: AppleTestCredentials = .init(),
        generate: @escaping @Sendable (AIProviderBackend, String, String, Int) async throws -> String
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(configuration: preset.applying(to: .init(isEnabled: true)),
            credentialStore: credentials, appleIntelligence: .init(availability: { _ in .available }, generate: generate))
    }
}

private actor AppleRequestRecorder {
    var requests: [[String]] = []
    func record(_ values: [String]) { requests.append(values) }
}

private actor AppleTestCredentials: AICredentialStoring {
    var accesses = 0
    func lookupAPIKey(configuration: AIRemoteProviderConfiguration) -> AICredentialLookup {
        accesses += 1; return .notConfigured
    }
    func requireAPIKey(configuration: AIRemoteProviderConfiguration) throws -> String {
        accesses += 1; throw AICredentialStoreError.persistenceFailed
    }
    func saveAPIKey(_ rawValue: String, configuration: AIRemoteProviderConfiguration) throws -> Bool {
        accesses += 1; return false
    }
    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) throws { accesses += 1 }
}

private actor AppleCloudConsent {
    var allowed = true
    func revoke() { allowed = false }
}
