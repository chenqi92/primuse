import Foundation
import Testing
@testable import PrimuseKit

struct AIFeatureRoutingTests {
    private let deepSeekID = UUID()
    private let kimiID = UUID()
    private let openAIID = UUID()

    private func provider(
        _ id: UUID,
        _ name: String,
        model: String,
        extra: [String] = [],
        enabled: Bool = true
    ) -> AIRemoteProviderConfiguration {
        AIRemoteProviderConfiguration(
            id: id,
            displayName: name,
            baseURL: "https://api.example.com/v1",
            generationModel: model,
            additionalGenerationModels: extra,
            isEnabled: enabled
        )
    }

    private func set(
        fallback: Bool = true,
        routes: [AIFeature: AIFeatureRoute] = [:],
        kimiEnabled: Bool = true
    ) -> AIRemoteProviderSet {
        var set = AIRemoteProviderSet(
            providers: [
                provider(deepSeekID, "DeepSeek", model: "deepseek-chat", extra: ["deepseek-reasoner"]),
                provider(kimiID, "Kimi", model: "kimi-k2", enabled: kimiEnabled),
                provider(openAIID, "OpenAI", model: "gpt-5-mini"),
            ],
            primaryProviderID: deepSeekID,
            fallbackEnabled: fallback
        )
        for (feature, route) in routes { set.setRoute(route, for: feature) }
        return set
    }

    @Test func unroutedFeatureFollowsDefaultChain() {
        let providers = set().routedProviders(for: .lyricsTranslation)
        #expect(providers.map(\.id) == [deepSeekID, kimiID, openAIID])
        #expect(providers.first?.generationModel == "deepseek-chat")
    }

    @Test func routedProviderGoesFirstWithChosenModel() {
        let routed = set(routes: [.lyricsTranslation: .provider(id: openAIID, model: "gpt-5")])
        let providers = routed.routedProviders(for: .lyricsTranslation)
        #expect(providers.map(\.id) == [openAIID, deepSeekID, kimiID])
        #expect(providers[0].generationModel == "gpt-5")
        // 其余服务仍用各自的默认模型,别的功能不受影响。
        #expect(providers[1].generationModel == "deepseek-chat")
        #expect(routed.routedProviders(for: .recommendations).map(\.id) == [deepSeekID, kimiID, openAIID])
    }

    @Test func sameProviderDifferentModelsPerFeature() {
        let routed = set(routes: [
            .libraryInsight: .provider(id: deepSeekID, model: "deepseek-reasoner"),
            .tagCleanup: .provider(id: deepSeekID, model: ""),
        ])
        #expect(routed.routedProviders(for: .libraryInsight)[0].generationModel == "deepseek-reasoner")
        #expect(routed.routedProviders(for: .tagCleanup)[0].generationModel == "deepseek-chat")
    }

    @Test func routeWithoutFallbackAsksOnlyTheChosenService() {
        let routed = set(fallback: false, routes: [.songDiscovery: .provider(id: kimiID, model: "")])
        #expect(routed.routedProviders(for: .songDiscovery).map(\.id) == [kimiID])
    }

    @Test func routeToDisabledServiceFallsBackToDefault() {
        let routed = set(routes: [.semanticSearch: .provider(id: kimiID, model: "")], kimiEnabled: false)
        #expect(routed.effectiveRoute(for: .semanticSearch) == nil)
        #expect(routed.route(for: .semanticSearch) == .provider(id: kimiID, model: ""))
        #expect(routed.routedProviders(for: .semanticSearch).map(\.id) == [deepSeekID, openAIID])
        #expect(routed.asksBuiltInFirst(for: .semanticSearch, relayEnabled: true))
    }

    @Test func builtInRouteDecidesRelayPerFeature() {
        let routed = set(routes: [
            .recommendations: .builtIn,
            .lyricsTranslation: .provider(id: deepSeekID, model: ""),
        ])
        #expect(routed.asksBuiltInFirst(for: .recommendations, relayEnabled: false))
        #expect(!routed.asksBuiltInFirst(for: .lyricsTranslation, relayEnabled: true))
        #expect(routed.asksBuiltInFirst(for: .semanticSearch, relayEnabled: true))
        #expect(!routed.asksBuiltInFirst(for: .semanticSearch, relayEnabled: false))
    }

    @Test func removingServiceDropsItsRoutesOnNormalize() {
        var routed = set(routes: [
            .tagCleanup: .provider(id: kimiID, model: ""),
            .recommendations: .builtIn,
        ])
        routed.providers.removeAll { $0.id == kimiID }
        let normalized = routed.normalized()
        #expect(normalized.route(for: .tagCleanup) == nil)
        #expect(normalized.route(for: .recommendations) == .builtIn)
    }

    @Test func selectableModelsPutDefaultFirstWithoutDuplicates() {
        let configuration = provider(
            deepSeekID,
            "DeepSeek",
            model: " deepseek-chat ",
            extra: ["deepseek-reasoner", "", "deepseek-chat", "deepseek-reasoner"]
        )
        #expect(configuration.selectableGenerationModels == ["deepseek-chat", "deepseek-reasoner"])
    }

    @Test func routesRoundTripThroughJSON() throws {
        let routed = set(routes: [
            .lyricsTranslation: .provider(id: openAIID, model: "gpt-5"),
            .recommendations: .builtIn,
        ])
        let data = try JSONEncoder().encode(routed)
        let decoded = try JSONDecoder().decode(AIRemoteProviderSet.self, from: data)
        #expect(decoded == routed)
        #expect(decoded.providers[0].additionalGenerationModels == ["deepseek-reasoner"])
    }

    @Test func settingsWithoutRoutesStayByteCompatible() throws {
        let plain = AIRemoteProviderSet(
            providers: [provider(deepSeekID, "DeepSeek", model: "deepseek-chat")],
            primaryProviderID: deepSeekID
        )
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("featureRoutes"))
        #expect(!json.contains("additionalGenerationModels"))
    }

    @Test func legacyJSONDecodesWithoutRoutes() throws {
        let legacy = """
        {"providers":[{"id":"\(deepSeekID.uuidString)","displayName":"DeepSeek",
        "baseURL":"https://api.deepseek.com","apiStyle":"chatCompletions","generationModel":"deepseek-chat",
        "embeddingModel":"","requestTimeout":12,"allowInsecureLocalHTTP":false,"isEnabled":true}],
        "primaryProviderID":"\(deepSeekID.uuidString)","fallbackEnabled":true}
        """
        let decoded = try JSONDecoder().decode(AIRemoteProviderSet.self, from: Data(legacy.utf8))
        #expect(decoded.featureRoutes.isEmpty)
        #expect(decoded.providers[0].additionalGenerationModels.isEmpty)
        #expect(decoded.routedProviders(for: .recommendations).map(\.id) == [deepSeekID])
    }

    @Test func unreadableRouteIsDroppedAndUnknownFeatureKept() throws {
        let json = """
        {"providers":[{"id":"\(deepSeekID.uuidString)","displayName":"DeepSeek",
        "baseURL":"https://api.deepseek.com","apiStyle":"chatCompletions","generationModel":"deepseek-chat",
        "embeddingModel":"","requestTimeout":12,"allowInsecureLocalHTTP":false,"isEnabled":true}],
        "primaryProviderID":"\(deepSeekID.uuidString)","fallbackEnabled":true,
        "featureRoutes":{"recommendations":{"kind":"somethingNew"},"futureFeature":{"kind":"builtIn"},
        "tagCleanup":{"kind":"provider","providerID":"\(deepSeekID.uuidString)","model":"deepseek-reasoner"}}}
        """
        let decoded = try JSONDecoder().decode(AIRemoteProviderSet.self, from: Data(json.utf8))
        #expect(decoded.route(for: .recommendations) == nil)
        #expect(decoded.featureRoutes["futureFeature"] == .builtIn)
        #expect(decoded.route(for: .tagCleanup) == .provider(id: deepSeekID, model: "deepseek-reasoner"))
    }
}
