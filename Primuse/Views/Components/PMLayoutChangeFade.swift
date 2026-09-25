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

extension View {
    /// 版式在几副构图之间换（iPhone Duo 开合、转屏让播放页 / 详情页换排法）时，让换构图的那一次更新走
    /// 面板档位的动画：挂了 `matchedGeometryEffect` 的主元素（封面、标题、进度条、控制条、详情页头图）
    /// 从旧位置连续滑到新位置，其余元素随新构图淡入、旧构图淡出。
    ///
    /// `key` 是「用的是哪一副构图」，只在它变化的那一次更新里生效，别的变化照旧。挂在只装着几副构图分支的
    /// 容器上：那一次更新里整副构图是新插入的，列表的行不会一行一行做动画。第一次出现（尺寸还在定的那几帧）
    /// 不动，开了减弱动态效果时不动，`isEnabled` 为假时（比如播放页还在进场）也不动。
    func pmLayoutSwitchAnimation<Key: Equatable>(_ key: Key, isEnabled: Bool = true) -> some View {
        modifier(PMLayoutSwitchAnimation(key: key, isEnabled: isEnabled))
    }
}

private struct PMLayoutSwitchAnimation<Key: Equatable>: ViewModifier {
    let key: Key
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasSettled = false

    func body(content: Content) -> some View {
        content
            .animation(hasSettled && isEnabled && !reduceMotion ? Self.animation : nil, value: key)
            .task {
                // 刚出现时画布可能还在从零长到整屏，这期间换构图不算「换版式」。
                try? await Task.sleep(for: .milliseconds(400))
                hasSettled = true
            }
    }

    private static var animation: Animation {
        let factor = PMLayoutSwitchTiming.slowFactor
        return factor == 1 ? PMMotion.panel.animation : PMMotion.panel.animation.speed(1 / factor)
    }
}

/// 换构图过渡的时长，给要等过渡走完再做事的地方用（和 `pmLayoutSwitchAnimation` 同一个面板档位）。
enum PMLayoutSwitchTiming {
    /// 面板档位的时长，与 `PMMotion.panel` 一致。
    private static let panelDuration: Double = 0.25

    /// 被换下去的那一份很快淡出（按压档位的时长）。曲线取自当前界面皮肤的动效表，只在主线程读。
    @MainActor
    static var quickFadeOut: Animation {
        PMMotion.press.animation.speed(1 / slowFactor)
    }

    /// 过渡走完、退场的旧构图已经移除之后。
    static var settleDelay: Duration {
        .milliseconds(Int((panelDuration * slowFactor + 0.15) * 1000))
    }

    /// 取证录屏用：`PRIMUSE_DEBUG_SLOW_LAYOUT_SWITCH=4` 把换构图放慢到四分之一速度，逐帧看得清。平时是 1。
    static var slowFactor: Double {
        #if DEBUG
        if let factor = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SLOW_LAYOUT_SWITCH"].flatMap(Double.init),
           factor > 0 {
            return factor
        }
        #endif
        return 1
    }
}

/// 换构图时整副构图的进出场：自己不整体淡入淡出 —— 挂了 `matchedGeometryEffect` 的主元素要以不透明的
/// 样子从旧位置滑过来 —— 只把「进场到哪一步」交给子树，标了 `pmLayoutSwitchFade()` 的其余元素跟着淡入淡出。
/// 挂在 `pmLayoutSwitchAnimation` 管着的那几副构图分支上。
struct PMLayoutSwitchTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .environment(\.pmLayoutSwitchSettled, phase.isIdentity)
            .environment(\.pmLayoutSwitchLeaving, phase == .didDisappear)
    }
}

private struct PMLayoutSwitchSettledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct PMLayoutSwitchLeavingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 所在的构图已经在位（不在换构图的进出场途中）。
    var pmLayoutSwitchSettled: Bool {
        get { self[PMLayoutSwitchSettledKey.self] }
        set { self[PMLayoutSwitchSettledKey.self] = newValue }
    }

    /// 所在的构图正在退场（换构图时被换下去的那一副）。
    var pmLayoutSwitchLeaving: Bool {
        get { self[PMLayoutSwitchLeavingKey.self] }
        set { self[PMLayoutSwitchLeavingKey.self] = newValue }
    }
}

extension View {
    /// 换构图时跟着新构图淡入的元素（主元素以外的：把手、底栏、音量条、侧栏……）。平时原样不动。
    func pmLayoutSwitchFade() -> some View {
        modifier(PMLayoutSwitchFade())
    }
}

private struct PMLayoutSwitchFade: ViewModifier {
    @Environment(\.pmLayoutSwitchSettled) private var isSettled

    func body(content: Content) -> some View {
        content.opacity(isSettled ? 1 : 0)
    }
}

extension View {
    /// 换构图时新构图里这一份保持不透明，被换下去的那一份很快淡出 —— 两份同时在场的时间很短，
    /// 不会叠成两份实心的。平时原样不动。
    func pmLayoutSwitchQuickFadeOut() -> some View {
        modifier(PMLayoutSwitchQuickFadeOut())
    }
}

private struct PMLayoutSwitchQuickFadeOut: ViewModifier {
    @Environment(\.pmLayoutSwitchLeaving) private var isLeaving

    func body(content: Content) -> some View {
        content
            .opacity(isLeaving ? 0 : 1)
            .animation(PMLayoutSwitchTiming.quickFadeOut, value: isLeaving)
    }
}
