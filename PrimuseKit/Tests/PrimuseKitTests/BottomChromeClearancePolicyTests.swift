import Foundation
import Testing
@testable import PrimuseKit

@Suite("Bottom chrome clearance policy")
struct BottomChromeClearancePolicyTests {
    @Test("Legacy overlay only on standard tabs without the system accessory")
    func detectsLegacyOverlay() {
        #expect(BottomChromeClearancePolicy.usesLegacyOverlayAccessory(
            rootLayoutIsStandardTabs: true,
            miniPlayerVisible: true,
            systemAccessoryAvailable: false
        ))
        #expect(!BottomChromeClearancePolicy.usesLegacyOverlayAccessory(
            rootLayoutIsStandardTabs: true,
            miniPlayerVisible: true,
            systemAccessoryAvailable: true
        ))
    }

    @Test("A hidden mini player or a non-tab root never reserves the overlay")
    func requiresVisibleMiniPlayerAndTabRoot() {
        #expect(!BottomChromeClearancePolicy.usesLegacyOverlayAccessory(
            rootLayoutIsStandardTabs: true,
            miniPlayerVisible: false,
            systemAccessoryAvailable: false
        ))
        #expect(!BottomChromeClearancePolicy.usesLegacyOverlayAccessory(
            rootLayoutIsStandardTabs: false,
            miniPlayerVisible: true,
            systemAccessoryAvailable: false
        ))
        #expect(!BottomChromeClearancePolicy.usesLegacyOverlayAccessory(
            rootLayoutIsStandardTabs: false,
            miniPlayerVisible: false,
            systemAccessoryAvailable: true
        ))
    }

    @Test("Clearance switches between the legacy reserve and the baseline")
    func picksClearance() {
        #expect(BottomChromeClearancePolicy.clearance(
            legacyOverlayActive: true,
            legacy: 112,
            baseline: 16
        ) == 112)
        #expect(BottomChromeClearancePolicy.clearance(
            legacyOverlayActive: false,
            legacy: 112,
            baseline: 16
        ) == 16)
    }

    @Test("A zero baseline collapses the reserve entirely")
    func supportsZeroBaseline() {
        #expect(BottomChromeClearancePolicy.clearance(
            legacyOverlayActive: false,
            legacy: 90,
            baseline: 0
        ) == 0)
        #expect(BottomChromeClearancePolicy.clearance(
            legacyOverlayActive: true,
            legacy: 90,
            baseline: 0
        ) == 90)
    }
}
