import Foundation
import Testing
@testable import PrimuseKit

struct AppleIntelligenceConfigurationTests {
    @Test func appleProfilesDoNotInheritHTTPOrAudioCredentials() throws {
        let remote = AIRemoteProviderConfiguration(
            baseURL: "https://example.com", generationModel: "remote",
            additionalGenerationModels: ["other"], embeddingModel: "embed",
            transcriptionModel: "gemini-audio", isEnabled: true
        )
        for preset in [AIProviderPreset.appleOnDevice, .applePrivateCloudCompute] {
            let profile = preset.applying(to: remote)
            try profile.validateGenerationConfiguration()
            #expect(!profile.backend.requiresAPIKey)
            #expect(profile.baseURL.isEmpty)
            #expect(profile.embeddingModel.isEmpty)
            #expect(profile.transcriptionModel.isEmpty)
            #expect(profile.additionalGenerationModels.isEmpty)
            #expect(!profile.supportsEmbeddings)
            #expect(AIProviderPreset.matching(configuration: profile) == preset)
            #expect(try JSONDecoder().decode(AIRemoteProviderConfiguration.self,
                        from: JSONEncoder().encode(profile)) == profile)
        }
    }

    @Test func hybridOptInRoundTripsAndClearsWhenChangingPresets() throws {
        var local = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
        local.allowsPrivateCloudComputeFallback = true
        let restored = try JSONDecoder().decode(AIRemoteProviderConfiguration.self, from: JSONEncoder().encode(local))
        #expect(restored.allowsPrivateCloudComputeFallback)
        #expect(restored.descriptor.executionClass == .appleSystemModel)
        #expect(!AIProviderPreset.groq.applying(to: restored).allowsPrivateCloudComputeFallback)
    }

    @Test func oldProfilesRemainHTTPProviders() throws {
        let original = AIRemoteProviderConfiguration(generationModel: "model")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "backend")
        let decoded = try JSONDecoder().decode(AIRemoteProviderConfiguration.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.backend == .remote)
        #expect(decoded.backend.requiresAPIKey)
        #expect(!decoded.allowsPrivateCloudComputeFallback)
    }

    @Test func onDeviceRoutingDoesNotAuthorizeCloudFallback() {
        let local = AIProviderPreset.appleOnDevice.applying(to: .init(isEnabled: true))
        let cloud = AIProviderPreset.applePrivateCloudCompute.applying(to: .init(isEnabled: true))
        let region = AIRegionContext(region: .mainlandChina, source: .appStorefront)
        let profiles = [local.descriptor, cloud.descriptor]
        let allowed = AIProviderRoutingPolicy.candidates(from: profiles, capability: .lyricsTranslation,
            regionContext: region, hasExplicitRemoteConsent: false)
        #expect(allowed.map(\.id) == [local.id])
        #expect(AIProviderRegionPolicy.allows(configuration: local, region: .unknown, purpose: .generation))
    }

    @Test func featureRoutesPreserveAppleBackendAndFallbackOrder() {
        let apple = AIProviderPreset.applePrivateCloudCompute.applying(to: .init(isEnabled: true))
        let remote = AIRemoteProviderConfiguration(generationModel: "model", isEnabled: true)
        var providers = AIRemoteProviderSet(providers: [remote, apple], primaryProviderID: remote.id, fallbackEnabled: true)
        providers.setRoute(.provider(id: apple.id, model: ""), for: .spokenChapters)
        #expect(providers.routedProviders(for: .spokenChapters).map(\.backend) == [.applePrivateCloudCompute, .remote])
    }
}
