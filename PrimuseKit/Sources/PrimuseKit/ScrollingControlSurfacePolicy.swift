import Foundation

/// Mac 上跟着页面一起滚动的卡片、行,点按面用系统按钮还是点按手势,以及滚动时要不要暂停点按判定。
///
/// macOS 15 的 SwiftUI 给滚动内容里的按钮、悬停提示、悬停区域各登记一块指针区域,并顺带算
/// 「在这里按下不拖窗口」。内容一滚,每块区域都要重新登记,而且每登记一块就把这一轮待处理的
/// 回调整条拷一遍,开销随区域数成倍往上涨:卡片一多,首页滚动就掉帧、转圈、CPU 占满。
/// 点按手势比按钮登记得少。macOS 26 起系统按整块内容的轮廓判断能不能拖窗口,不再逐块登记,
/// 所以只在老系统上换,新系统照旧用按钮。
///
/// 换成点按手势后首页滚动仍然卡(1.13.1 构建 133–135 的诊断 PM-W2Z0Z9:每次滚动主线程连续
/// 忙 0.4–1.3 秒),所以老系统上滚动期间再整块暂停滚动内容的点按判定,停下后恢复。
/// 滚动当中用不上悬停、提示和点按,暂停时不参与点按的区域也就不用逐帧重新登记。
public enum ScrollingControlSurfacePolicy {
    public enum Surface: Equatable, Sendable {
        /// 系统按钮:按下变暗、键盘焦点、默认动作都由系统给。
        case button
        /// 点按手势加按钮的辅助功能特征和默认动作,不登记指针区域。
        case tapGesture
    }

    /// 调试开关:在新系统上也走老系统那条路,好在编译机上看点按面的样子与行为。
    public static let legacyOverrideEnvironmentKey = "PRIMUSE_DEBUG_LEGACY_POINTER_REGIONS"

    /// 从这一版 macOS 起按钮不再各自登记拖窗口用的指针区域。
    public static let firstMacOSWithoutPerButtonRegions = 26

    public static func surface(macOSMajorVersion: Int, forcesLegacy: Bool = false) -> Surface {
        if forcesLegacy { return .tapGesture }
        return macOSMajorVersion >= firstMacOSWithoutPerButtonRegions ? .button : .tapGesture
    }

    /// 滚动期间要不要暂停滚动内容的点按判定(悬停、提示、点按都先不响应,停下后恢复)。
    public static func pausesHitTestingWhileScrolling(macOSMajorVersion: Int, forcesLegacy: Bool = false) -> Bool {
        surface(macOSMajorVersion: macOSMajorVersion, forcesLegacy: forcesLegacy) == .tapGesture
    }
}
