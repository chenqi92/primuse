import SwiftUI
import PrimuseKit

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
    /// 容器上：那一次更新里整副构图是新插入的，列表的行不会一行一行做动画。刚出现、尺寸还在定的那几帧
    /// 不动，开了减弱动态效果时不动，`isEnabled` 为假时（比如播放页还在进场）也不动。
    ///
    /// 换构图那一次强制带上动画：开合、转屏时尺寸等级是系统在自己的过渡里改的，那次更新可能标着
    /// 「不要动画」，只挂 `.animation(_:value:)` 会被它压掉，元素就硬切过去。
    func pmLayoutSwitchAnimation<Key: Equatable>(_ key: Key, isEnabled: Bool = true) -> some View {
        modifier(PMLayoutSwitchAnimation(key: key, isEnabled: isEnabled))
    }
}

private struct PMLayoutSwitchAnimation<Key: Equatable>: ViewModifier {
    let key: Key
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 出现之后构图已经定下来了：之后的变化才算「换版式」。
    @State private var hasSettled = false
    @State private var settleRequest = 0

    func body(content: Content) -> some View {
        let animates = hasSettled && isEnabled && !reduceMotion
        content
            .transaction(value: key) { transaction in
                if animates {
                    transaction.animation = Self.animation
                    transaction.disablesAnimations = false
                } else {
                    transaction.animation = nil
                }
            }
            // 按生命周期而不是按时间认「刚出现」：出现以后、构图连续几帧没再变，才算定下来。
            // 刚出现时画布可能还在从零长到整屏（首页量出尺寸才决定分不分两栏），这期间的变化不算换版式；
            // 定下来以后哪怕视图是刚建的（开合时新插进来的分支），下一次换构图照样有动画。
            .onAppear { scheduleSettle() }
            .onChange(of: key) { _, _ in
                if !hasSettled { scheduleSettle() }
            }
    }

    private func scheduleSettle() {
        guard !hasSettled else { return }
        settleRequest += 1
        let request = settleRequest
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            if request == settleRequest { hasSettled = true }
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

    /// 被换下去的那一份很快淡出（按压档位的时长）。
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

// MARK: - 换屏时的整屏归位（iPhone Duo 合上 / 展开）

extension View {
    /// 换屏过渡的样子：`trigger` 每变一次，内容从轻微模糊、沿开合方向略微拉伸、略微变淡的样子
    /// 平滑回到原样（`ScreenChangeTransitionPolicy`）；开了减弱动态效果时只做一次很短的淡入。
    /// 页面里的元素照旧在下面各自滑到新位置。平时（没在过渡里）原样不动。
    func pmScreenChangeSettle(trigger: Int, axis: ScreenChangeTransitionPolicy.Axis) -> some View {
        modifier(PMScreenChangeSettleEffect(trigger: trigger, axis: axis))
    }
}

private struct PMScreenChangeSettleEffect: ViewModifier {
    let trigger: Int
    let axis: ScreenChangeTransitionPolicy.Axis

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let reduceMotion = reduceMotion
        let axis = axis
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, progress in
            let frame = ScreenChangeTransitionPolicy.frame(progress: progress, axis: axis, reduceMotion: reduceMotion)
            view
                .scaleEffect(x: frame.scaleX, y: frame.scaleY)
                .blur(radius: frame.blurRadius, opaque: true)
                .opacity(frame.opacity)
        } keyframes: { _ in
            // 换屏那一刻直接到起点，再按面板那样的缓出回到原样。
            MoveKeyframe(1.0)
            CubicKeyframe(
                0.0,
                duration: (reduceMotion
                    ? ScreenChangeTransitionPolicy.reducedMotionDuration
                    : ScreenChangeTransitionPolicy.duration) * PMLayoutSwitchTiming.slowFactor
            )
        }
    }
}

#if os(iOS)
import UIKit

extension View {
    /// 挂在 App 的根上：iPhone Duo 合上、展开（窗口换到另一块屏幕）时整屏做一次归位过渡，
    /// 判定见 `ScreenChangeTransitionPolicy`。普通 iPhone 转屏、分屏里拖宽拖窄、iPad 都不触发；
    /// 不是折叠屏的 iPhone 与 iPad 上整个修饰符原样返回（视图树、渲染与改之前完全一样）。
    func pmScreenChangeTransition() -> some View {
        modifier(PMScreenChangeTransition())
    }
}

/// 这台设备是不是折叠屏 iPhone：按承载 App 的屏幕的物理像素宽高比判定，一个进程里不会变
/// （根上的修饰符按它选分支，这个值要是中途变了整棵树会重建）。
@MainActor
enum PMFoldableDevice {
    static let isFoldable: Bool = {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        guard let bounds = screen?.nativeBounds else { return false }
        return ScreenChangeTransitionPolicy.isFoldableScreen(
            nativeWidth: Double(bounds.width),
            nativeHeight: Double(bounds.height)
        )
    }()
}

private struct PMScreenChangeTransition: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var tracker = PMScreenChangeTracker()
    /// 窗口的尺寸或所在屏幕变了（探针回报），让下面重新比一次。
    @State private var windowRevision = 0

    func body(content: Content) -> some View {
        if PMFoldableDevice.isFoldable {
            // 在这次更新里就比：新尺寸的第一帧已经是过渡的起点，不会先清楚地闪一下再糊上去。
            let _ = tracker.observe(
                isRegularWidth: horizontalSizeClass == .regular,
                isRegularHeight: verticalSizeClass == .regular,
                revision: windowRevision
            )
            content
                .pmScreenChangeSettle(trigger: tracker.generation, axis: tracker.axis)
                .background {
                    PMScreenChangeWindowProbe(tracker: tracker) { windowRevision &+= 1 }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

/// 记着上一次看到的画布，比出「换了一块屏幕」就把代数加一。不是可观察对象：只在根视图求值时读写。
@MainActor
final class PMScreenChangeTracker {
    weak var window: UIWindow?
    private(set) var generation = 0
    private(set) var axis: ScreenChangeTransitionPolicy.Axis = .horizontal
    private var last: ScreenChangeTransitionPolicy.Canvas?

    @discardableResult
    func observe(isRegularWidth: Bool, isRegularHeight: Bool, revision: Int) -> Int {
        guard let window, let scene = window.windowScene else { return generation }
        let screen = scene.screen
        let traits = window.traitCollection
        let canvas = ScreenChangeTransitionPolicy.Canvas(
            screenID: ObjectIdentifier(screen).hashValue,
            width: Double(window.bounds.width),
            height: Double(window.bounds.height),
            screenWidth: Double(screen.bounds.width),
            screenHeight: Double(screen.bounds.height),
            isRegularWidth: traits.horizontalSizeClass == .unspecified
                ? isRegularWidth : traits.horizontalSizeClass == .regular,
            isRegularHeight: traits.verticalSizeClass == .unspecified
                ? isRegularHeight : traits.verticalSizeClass == .regular,
            isPhone: traits.userInterfaceIdiom == .phone
        )
        guard canvas != last else { return generation }
        if let change = ScreenChangeTransitionPolicy.change(from: last, to: canvas) {
            generation &+= 1
            axis = change.axis
            if let last {
                plog("📱 Screen change \(change.isUnfolding ? "unfold" : "fold") "
                    + "\(Int(last.width))×\(Int(last.height)) → \(Int(canvas.width))×\(Int(canvas.height)) "
                    + "regular=\(canvas.isRegularWidth)/\(canvas.isRegularHeight) screenChanged=\(last.screenID != canvas.screenID)")
            }
        }
        last = canvas
        return generation
    }
}

/// 零尺寸探针：拿到承载界面的那扇窗，窗口尺寸、所在屏幕或尺寸等级变了就回报一次。
private struct PMScreenChangeWindowProbe: UIViewRepresentable {
    let tracker: PMScreenChangeTracker
    let onChange: () -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.tracker = tracker
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.tracker = tracker
        uiView.onChange = onChange
    }

    final class ProbeView: UIView {
        weak var tracker: PMScreenChangeTracker?
        var onChange: (() -> Void)?
        private var lastSignature: String?

        override init(frame: CGRect) {
            super.init(frame: frame)
            // 换屏时尺寸等级跟着变；探针自己是零尺寸，窗口变大变小时不一定轮到它重新布局。
            registerForTraitChanges(
                [UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]
            ) { (view: ProbeView, _: UITraitCollection) in
                view.publishIfNeeded()
            }
        }

        required init?(coder: NSCoder) { return nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tracker?.window = window
            publishIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publishIfNeeded()
        }

        private func publishIfNeeded() {
            guard let window, let screen = window.windowScene?.screen else { return }
            let signature = "\(ObjectIdentifier(screen).hashValue) \(window.bounds.size) \(screen.bounds.size) "
                + "\(window.traitCollection.horizontalSizeClass.rawValue)\(window.traitCollection.verticalSizeClass.rawValue)"
            guard signature != lastSignature else { return }
            lastSignature = signature
            DispatchQueue.main.async { [weak self] in
                self?.onChange?()
            }
        }
    }
}
#endif
