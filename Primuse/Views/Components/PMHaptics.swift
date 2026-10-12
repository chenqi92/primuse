#if os(iOS)
import UIKit
#endif

/// 点心形按钮（喜欢一首歌、一集节目，收藏专辑、艺人、歌单、目录、有声书）时手上那一下（#282）。
///
/// 只在用户亲手点的地方调：CarPlay、Siri、锁屏、服务端同步改的喜欢不震。iPhone 才有触感，
/// iPad 没有马达、Mac 和电视上什么都不做；系统设置里关掉「系统触感反馈」时系统自己会静音。
enum PMHaptics {
    /// 点亮时实一点、取消时轻一点，不看屏幕也分得出这一下是加上还是撤掉。
    @MainActor
    static func likeToggled(isLiked: Bool) {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: isLiked ? .medium : .light).impactOccurred()
        #endif
    }
}
