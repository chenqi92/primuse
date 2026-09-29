import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI distribution availability")
struct AIDistributionAvailabilityTests {
    @Test(arguments: [AIDistributionEnvironment.production, .testing])
    func bundledRelayIsAvailableInEveryRegion(distribution: AIDistributionEnvironment) {
        for region in [
            AICommercialRegion.mainlandChina,
            .international,
            .unknown,
        ] {
            let context = AIRegionContext(
                region: region,
                source: .appStorefront,
                distributionEnvironment: distribution
            )
            let decision = AIAvailabilityPolicy.decision(
                for: .bundledRemote,
                regionContext: context
            )

            #expect(decision.isAllowed)
            #expect(decision.shouldExposeConfiguration)
            #expect(decision.requiresExplicitConsent)
            #expect(decision.denialReason == nil)
        }
    }

    @Test(arguments: [AICommercialRegion.mainlandChina, .international, .unknown])
    func productionBundledRelayRoutingStillRequiresConsent(region: AICommercialRegion) {
        let context = AIRegionContext(
            region: region,
            source: .appStorefront,
            distributionEnvironment: .production
        )
        let relay = AIProviderDescriptor(
            id: UUID(),
            displayName: "Built-in AI",
            kind: .openAICompatible,
            executionClass: .bundledRemote,
            capabilities: [.semanticSearchInterpretation]
        )

        #expect(AIProviderRoutingPolicy.candidates(
            from: [relay],
            capability: .semanticSearchInterpretation,
            regionContext: context,
            hasExplicitRemoteConsent: false
        ).isEmpty)
        #expect(AIProviderRoutingPolicy.candidates(
            from: [relay],
            capability: .semanticSearchInterpretation,
            regionContext: context,
            hasExplicitRemoteConsent: true
        ).map(\.id) == [relay.id])
    }

    @Test func testingDistributionDoesNotBypassAppleModelAvailability() {
        let mainland = AIRegionContext(
            region: .mainlandChina,
            source: .appStorefront,
            countryCode: "CHN",
            distributionEnvironment: .testing
        )

        let decision = AIAvailabilityPolicy.decision(
            for: .appleSystemModel,
            regionContext: mainland
        )
        #expect(!decision.isAllowed)
        #expect(decision.denialReason == .regionRestricted)
    }

    @Test func legacyRegionContextDecodesAsProduction() throws {
        let data = Data(#"{"region":"mainlandChina","source":"appStorefront","countryCode":"CHN"}"#.utf8)
        let context = try JSONDecoder().decode(AIRegionContext.self, from: data)

        #expect(context.distributionEnvironment == .production)
        #expect(AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: context
        ).isAllowed)
    }
}
