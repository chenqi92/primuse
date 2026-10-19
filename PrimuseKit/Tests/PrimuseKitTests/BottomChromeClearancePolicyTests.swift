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

    @Test("The tab pages reserve the measured overlay height only while it is up")
    func reservesMeasuredOverlayHeight() {
        #expect(BottomChromeClearancePolicy.overlayInset(
            legacyOverlayActive: true,
            accessoryHeight: 56
        ) == 56)
        #expect(BottomChromeClearancePolicy.overlayInset(
            legacyOverlayActive: false,
            accessoryHeight: 56
        ) == 0)
    }

    @Test("An unmeasured or bogus height never reserves space")
    func ignoresUnmeasuredHeight() {
        #expect(BottomChromeClearancePolicy.overlayInset(
            legacyOverlayActive: true,
            accessoryHeight: 0
        ) == 0)
        #expect(BottomChromeClearancePolicy.overlayInset(
            legacyOverlayActive: true,
            accessoryHeight: -8
        ) == 0)
    }
}
