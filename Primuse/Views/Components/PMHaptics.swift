#if os(iOS)
import UIKit
#endif

/// 点心形按钮（喜欢一首歌、一集节目，收藏专辑、艺人、歌单、目录、有声书）时手上那一下（#282），
/// 以及播放页上传输键、模式键的那一下（#356）。
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

    /// 点播放页、迷你条、全屏效果页上的播放 / 暂停、上一首 / 下一首、快退 / 快进这几颗传输键时
    /// 手上那一下(#356)。这几颗键按得最勤,只给最轻的一下;按住快退快进开始时另有自己的一下。
    @MainActor
    static func transportTapped() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// 播放页上点随机、循环这类开关式的键时那一下,和系统分段选择器换一档一样轻(#356)。
    @MainActor
    static func playbackModeToggled() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// 按住一颗键、触发它的长按动作时(按住文字稿键打开全屏文稿)手上那一下,
    /// 轻重和系统长按弹出菜单时差不多(#283)。
    @MainActor
    static func longPressActivated() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}
