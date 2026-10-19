import Foundation

/// 底部 chrome 的让位高度。
///
/// 只有仍然用叠加式 mini player（iOS 26.1 之前的 standardTabs 根布局）时，
/// 才需要替浮在标签栏上方的 accessory 让位：每个标签页外层垫一块与它等高的
/// 透明区，页面里的列表、表单（包括推进去的详情页）都滚到它上面为止。系统 accessory、
/// regular 宽度下的 safeAreaInset 面板以及极简模式的 safeAreaBar 都会自己
/// 进入安全区，这时不再垫。
public enum BottomChromeClearancePolicy {
    /// 是否仍由叠加式 accessory 占住底部，需要调用方自行让位。
    public static func usesLegacyOverlayAccessory(
        rootLayoutIsStandardTabs: Bool,
        miniPlayerVisible: Bool,
        systemAccessoryAvailable: Bool
    ) -> Bool {
        rootLayoutIsStandardTabs && miniPlayerVisible && !systemAccessoryAvailable
    }

    /// 标签页外层要垫出的高度：叠加式 accessory 生效时取它的实测高度，否则为 0。
    public static func overlayInset(
        legacyOverlayActive: Bool,
        accessoryHeight: CGFloat
    ) -> CGFloat {
        legacyOverlayActive ? max(0, accessoryHeight) : 0
    }
}
