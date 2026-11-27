import Foundation

/// 播放页宿主被系统问到「状态栏听谁的」时怎么答。
///
/// 播放页挂在根控制器下面的一个子控制器里；SwiftUI 的根控制器自己没定状态栏时，交给最后加进来的那个
/// 子控制器，播放页第一次展开以后就是它。下面的资料库、首页的导航控制器不再管状态栏，iOS 18 上
/// 整条导航栏从状态栏底下挪到安全区顶（灵动岛机型差 5pt），展开时往下跳、收起又跳回来。
/// 所以播放页没开着、或开着但没要求藏状态栏、没定字色时，都交还给下层页面。
public enum PlayerStatusBarOwnershipPolicy {
    public enum Owner: Equatable, Sendable {
        /// 播放页自己定。
        case player
        /// 交给下层页面（标签页、导航栈），和播放页没挂上时一样。
        case underlyingContent
    }

    /// 藏不藏状态栏听谁的。播放页里的全屏效果、MV 要藏，这时听播放页的。
    public static func visibilityOwner(
        isPlayerShowing: Bool,
        playerHidesStatusBar: Bool,
        hasUnderlyingContent: Bool
    ) -> Owner {
        guard hasUnderlyingContent else { return .player }
        return isPlayerShowing && playerHidesStatusBar ? .player : .underlyingContent
    }

    /// 状态栏字色听谁的。播放页自己定了字色（深色的有声书、卡拉OK）或者要藏状态栏时听播放页的。
    public static func styleOwner(
        isPlayerShowing: Bool,
        playerHidesStatusBar: Bool,
        playerDeclaresStyle: Bool,
        hasUnderlyingContent: Bool
    ) -> Owner {
        guard hasUnderlyingContent else { return .player }
        return isPlayerShowing && (playerHidesStatusBar || playerDeclaresStyle) ? .player : .underlyingContent
    }
}
