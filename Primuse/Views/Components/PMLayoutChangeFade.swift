import SwiftUI

extension View {
    /// 版式在两种排法之间换（iPhone Duo 开合、转屏让播放页 / 详情页 / 全屏效果换一副构图）时，
    /// 新构图从浅到实淡入，而不是闪一下整块换掉。`key` 是「用的是哪一副构图」，只在它变化时生效；
    /// 第一次出现不动，开了减弱动态效果时也不动。整块做透明度，不进大列表的动画事务。
    func pmLayoutChangeFade<Key: Equatable>(_ key: Key) -> some View {
        modifier(PMLayoutChangeFade(key: key))
    }
}

private struct PMLayoutChangeFade<Key: Equatable>: ViewModifier {
    let key: Key

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 换构图那一刻先压到这么淡，再按面板档位的曲线回到不透明。
    private static var dimmedOpacity: Double { 0.25 }

    func body(content: Content) -> some View {
        content.phaseAnimator([1.0, Self.dimmedOpacity], trigger: key) { view, opacity in
            view.opacity(reduceMotion ? 1 : opacity)
        } animation: { opacity in
            // 压淡那一步不做动画（瞬间），回到不透明那一步走面板档位。
            opacity == Self.dimmedOpacity || reduceMotion ? nil : PMMotion.panel.animation
        }
    }
}
