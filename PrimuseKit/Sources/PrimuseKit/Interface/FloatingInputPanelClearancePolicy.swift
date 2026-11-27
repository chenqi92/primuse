import Foundation

/// 未停靠输入面板（浮动键盘、拆分键盘、Apple Pencil 手写面板）的底部让位计算。
///
/// UIKit 只把「停靠」在窗口底边的键盘算进 safe area。浮动面板不改 safe area,
/// SwiftUI 的自动键盘避让因此对它完全失效 —— 面板会直接压在输入框和底部操作条
/// 上面。iPadOS 上用 Apple Pencil 唤起的手写输入浮窗正是这一类:它跟着笔停在
/// 内容区上方,app 却完全不知情。
///
/// 这里只做纯几何判断:面板与窗口的交集落在哪里、系统是不是已经让过位、
/// 还欠多少。UIKit 侧只负责把键盘通知里的屏幕坐标转成窗口坐标再传进来。
public enum FloatingInputPanelClearancePolicy {

    /// 面板是否已经停靠在窗口底边。
    ///
    /// 判据是「铺满窗口宽度」且「底边贴着窗口底边」——这正是系统会把高度算进
    /// safe area 的形态。此时调用方再补一次让位就是双倍留白。
    public static func isDocked(
        panelFrameInWindow panel: CGRect,
        windowBounds window: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        guard isUsable(panel), isUsable(window) else { return false }
        let overlap = panel.intersection(window)
        guard isUsable(overlap) else { return false }
        return overlap.width >= window.width - tolerance
            && abs(overlap.maxY - window.maxY) <= tolerance
    }

    /// 内容区底部还需要额外空出多少,才不会被未停靠的输入面板压住。
    ///
    /// 返回 0 的三种情况:面板不存在或与窗口不相交;面板已经停靠(系统让过位了);
    /// 面板顶边还在窗口上半部分——这时面板盖住的是内容中段,底部让位解决不了,
    /// 硬推只会让整个界面跳一下,而浮窗本来就可以由用户自己拖开。
    ///
    /// - Parameters:
    ///   - panel: 输入面板在**窗口**坐标系下的 frame,键盘收起时传 nil。
    ///   - window: 承载内容的窗口 bounds。分屏 / 台前调度下它小于整块屏幕,
    ///     所以必须先把键盘通知里的屏幕坐标转换过来。
    ///   - minimumClearance: 低于这个值就当作没被遮挡,避免 1pt 抖动引起跳动。
    ///   - maximumFraction: 让位高度相对窗口高度的上限,兜住异常 frame。
    public static func bottomClearance(
        panelFrameInWindow panel: CGRect?,
        windowBounds window: CGRect,
        minimumClearance: CGFloat = 8,
        maximumFraction: CGFloat = 0.6
    ) -> CGFloat {
        guard let panel, isUsable(panel), isUsable(window) else { return 0 }
        let overlap = panel.intersection(window)
        guard isUsable(overlap) else { return 0 }
        guard !isDocked(panelFrameInWindow: panel, windowBounds: window) else { return 0 }
        // 面板顶边必须落在窗口下半部分,底部让位才是对症的解法。
        guard overlap.minY >= window.midY else { return 0 }

        let needed = window.maxY - overlap.minY
        guard needed >= minimumClearance else { return 0 }
        return min(needed, window.height * maximumFraction)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty
            && rect.width.isFinite && rect.height.isFinite
            && rect.minX.isFinite && rect.minY.isFinite
    }
}
