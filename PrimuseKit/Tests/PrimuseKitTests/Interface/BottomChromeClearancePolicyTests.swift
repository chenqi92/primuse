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

    /// 竖屏 iPhone 的窗口，键盘 frame 已经换算到这个坐标系。
    private let phoneWindow = CGRect(x: 0, y: 0, width: 393, height: 852)

    @Test("A docked keyboard collapses the safe-area dock instead of lifting it")
    func dockedKeyboardCollapsesDock() {
        let keyboard = CGRect(x: 0, y: 852 - 336, width: 393, height: 336)
        #expect(BottomChromeClearancePolicy.collapsesSafeAreaDock(
            keyboardFrameInWindow: keyboard,
            windowBounds: phoneWindow
        ))
        // 外接键盘时只剩贴底的一条快捷栏，同样算停靠。
        let shortcutBar = CGRect(x: 0, y: 852 - 55, width: 393, height: 55)
        #expect(BottomChromeClearancePolicy.collapsesSafeAreaDock(
            keyboardFrameInWindow: shortcutBar,
            windowBounds: phoneWindow
        ))
    }

    @Test("No keyboard, or one moving off screen, keeps the dock")
    func hiddenKeyboardKeepsDock() {
        #expect(!BottomChromeClearancePolicy.collapsesSafeAreaDock(
            keyboardFrameInWindow: nil,
            windowBounds: phoneWindow
        ))
        // keyboardWillChangeFrame 收起时给的终点在窗口下面。
        let offscreen = CGRect(x: 0, y: 852, width: 393, height: 336)
        #expect(!BottomChromeClearancePolicy.collapsesSafeAreaDock(
            keyboardFrameInWindow: offscreen,
            windowBounds: phoneWindow
        ))
    }

    @Test("Floating and split keyboards leave the dock where it is")
    func undockedKeyboardKeepsDock() {
        let padWindow = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let floating = CGRect(x: 300, y: 700, width: 320, height: 260)
        #expect(!BottomChromeClearancePolicy.collapsesSafeAreaDock(
            keyboardFrameInWindow: floating,
            windowBounds: padWindow
        ))
        let splitHalf = CGRect(x: 0, y: 1366 - 300, width: 400, height: 300)
        #expect(!BottomChromeClearancePolicy.collapsesSafeAreaDock(
            keyboardFrameInWindow: splitHalf,
            windowBounds: padWindow
        ))
    }

    @Test("A docked keyboard under a split-view window still collapses its dock")
    func dockedKeyboardUnderNarrowWindow() {
        // 分屏时窗口只占屏幕左半边；键盘横跨整块屏幕，换算后两头超出窗口。
        let window = CGRect(x: 0, y: 0, width: 507, height: 1366)
        let keyboard = CGRect(x: 0, y: 1366 - 380, width: 1024, height: 380)
        #expect(BottomChromeClearancePolicy.collapsesSafeAreaDock(
            keyboardFrameInWindow: keyboard,
            windowBounds: window
        ))
    }
}
