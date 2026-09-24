import Foundation

/// 极简外壳底部停靠播放条的宽度。
///
/// 竖屏 iPhone 上它左右各内缩 12、铺满整行；手机横屏与折叠屏内屏这类宽视口里整行有八九百点，
/// 一条通栏的条子太长、封面与播放键隔得老远，所以最宽只给到一段「可读宽度」，在屏幕中间。
/// 进度线、点击热区、左右滑切歌都长在条子里面，跟着宽度一起走。
public enum DockedPlayerBarLayoutPolicy {
    /// 条子左右离容器边缘的距离。
    public static let horizontalInset: Double = 12
    /// 宽视口里条子最宽多少（不含左右内缩）。
    public static let maximumWidth: Double = 560

    /// 容器（左右安全区以内）这么宽时，条子本身多宽。
    public static func barWidth(containerWidth: Double) -> Double {
        let available = max(0, containerWidth - horizontalInset * 2)
        return min(available, maximumWidth)
    }

    /// 条子是不是比整行窄（宽视口里居中）。
    public static func isConstrained(containerWidth: Double) -> Bool {
        barWidth(containerWidth: containerWidth) < containerWidth - horizontalInset * 2
    }
}
