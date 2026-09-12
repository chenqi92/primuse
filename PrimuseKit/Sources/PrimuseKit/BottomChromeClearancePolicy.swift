import Foundation

/// 底部 chrome 的让位高度。
///
/// 只有仍然用叠加式 mini player（iOS 26.1 之前的 standardTabs 根布局）时，
/// 列表底部才需要替 accessory + tab bar 预留一段死区。系统 accessory、
/// regular 宽度下的 safeAreaInset 面板以及极简模式的 safeAreaBar 都会自己
/// 进入安全区，这时再加固定高度就是多余留白，而且系统栏移到侧边时数值也不成立。
public enum BottomChromeClearancePolicy {
    /// 是否仍由叠加式 accessory 占住底部，需要调用方自行让位。
    public static func usesLegacyOverlayAccessory(
        rootLayoutIsStandardTabs: Bool,
        miniPlayerVisible: Bool,
        systemAccessoryAvailable: Bool
    ) -> Bool {
        rootLayoutIsStandardTabs && miniPlayerVisible && !systemAccessoryAvailable
    }

    /// 叠加式 accessory 生效时给出原有留白，否则退回常规基线间距。
    public static func clearance(
        legacyOverlayActive: Bool,
        legacy: CGFloat,
        baseline: CGFloat
    ) -> CGFloat {
        legacyOverlayActive ? legacy : baseline
    }
}
