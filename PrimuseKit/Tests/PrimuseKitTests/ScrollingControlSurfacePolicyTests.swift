import Testing
@testable import PrimuseKit

@Suite("Scrolling control surface")
struct ScrollingControlSurfacePolicyTests {
    @Test("macOS 15 及更早的滚动内容用点按手势,不登记按钮的指针区域")
    func legacyMacUsesTapGesture() {
        for major in [13, 14, 15] {
            #expect(ScrollingControlSurfacePolicy.surface(macOSMajorVersion: major) == .tapGesture, "\(major)")
        }
    }

    @Test("macOS 26 起照旧用系统按钮")
    func currentMacKeepsButtons() {
        for major in [26, 27, 28] {
            #expect(ScrollingControlSurfacePolicy.surface(macOSMajorVersion: major) == .button, "\(major)")
        }
    }

    @Test("老 SDK 兼容号 16 仍算老系统那条路")
    func compatibilityVersionIsLegacy() {
        // 用老 SDK 链接的进程在 macOS 26 上读到的是 16;那时系统照新办法处理,换成点按也只是少了按下变暗。
        #expect(ScrollingControlSurfacePolicy.surface(macOSMajorVersion: 16) == .tapGesture)
    }

    @Test("调试开关在新系统上也走点按手势")
    func debugOverrideForcesTapGesture() {
        #expect(ScrollingControlSurfacePolicy.surface(macOSMajorVersion: 27, forcesLegacy: true) == .tapGesture)
        #expect(ScrollingControlSurfacePolicy.legacyOverrideEnvironmentKey == "PRIMUSE_DEBUG_LEGACY_POINTER_REGIONS")
    }

    @Test("只有老系统在滚动期间暂停滚动内容的点按判定")
    func pausesHitTestingOnlyOnLegacyMac() {
        for major in [13, 14, 15, 16] {
            #expect(ScrollingControlSurfacePolicy.pausesHitTestingWhileScrolling(macOSMajorVersion: major), "\(major)")
        }
        for major in [26, 27, 28] {
            #expect(!ScrollingControlSurfacePolicy.pausesHitTestingWhileScrolling(macOSMajorVersion: major), "\(major)")
        }
        #expect(ScrollingControlSurfacePolicy.pausesHitTestingWhileScrolling(macOSMajorVersion: 27, forcesLegacy: true))
    }
}
