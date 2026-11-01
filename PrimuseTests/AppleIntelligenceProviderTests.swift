import Foundation
import PrimuseKit
import XCTest
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
