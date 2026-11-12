import Foundation

/// Mac 上跟着页面一起滚动的卡片、行,点按面用系统按钮还是点按手势。
///
/// macOS 15 的 SwiftUI 给每个按钮(`Button`、`NavigationLink`)登记一块「在这里按下不拖窗口」的
/// 指针区域。内容一滚,滚动区里每个按钮的这块区域都要重新登记,而且每登记一块就把这一轮待处理的
/// 回调整条拷一遍,一轮的开销随滚动区里按钮数的平方涨:卡片一多,首页滚动就掉帧、转圈。
/// 点按手势不登记这种区域。macOS 26 起系统按整块内容的轮廓判断能不能拖窗口,不再逐个按钮登记,
/// 所以只在老系统上换,新系统照旧用按钮。
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
}
