import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI distribution availability")
struct AIDistributionAvailabilityTests {
    @Test func testingDistributionAllowsBundledRelayInEveryRegion() {
        for region in [
            AICommercialRegion.mainlandChina,
            .international,
            .unknown,
        ] {
            let context = AIRegionContext(
                region: region,
                source: .appStorefront,
                distributionEnvironment: .testing
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

    @Test func productionDistributionKeepsBundledRelayRegionRestrictions() {
        let mainland = AIRegionContext(
            region: .mainlandChina,
            source: .appStorefront,
            countryCode: "CHN",
            distributionEnvironment: .production
        )
        let unknown = AIRegionContext(
            region: .unknown,
            source: .unresolved,
            distributionEnvironment: .production
        )

        #expect(AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: mainland
        ).denialReason == .regionRestricted)
        #expect(AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: unknown
        ).denialReason == .regionUndetermined)
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
        #expect(!AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: context
        ).isAllowed)
    }
}
