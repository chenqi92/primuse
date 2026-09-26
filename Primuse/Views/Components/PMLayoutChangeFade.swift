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

// MARK: - 换屏时的整屏归位（iPhone Duo 合上 / 展开）

extension View {
    /// 换屏过渡的样子：`trigger` 每变一次，内容从轻微模糊、沿开合方向略微拉伸、略微变淡的样子
    /// 平滑回到原样（`ScreenChangeTransitionPolicy`）；开了减弱动态效果时只做一次很短的淡入。
    /// 页面里的元素照旧在下面各自滑到新位置。平时（没在过渡里）原样不动。
    /// `rampsIn`：接在系统自己的开合过渡之后开始（内容已经清楚了）时，先很快地淡进起点，不硬切到模糊。
    func pmScreenChangeSettle(
        trigger: Int,
        axis: ScreenChangeTransitionPolicy.Axis,
        rampsIn: Bool = false
    ) -> some View {
        modifier(PMScreenChangeSettleEffect(trigger: trigger, axis: axis, rampsIn: rampsIn))
    }
}

private struct PMScreenChangeSettleEffect: ViewModifier {
    let trigger: Int
    let axis: ScreenChangeTransitionPolicy.Axis
    let rampsIn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let reduceMotion = reduceMotion
        let axis = axis
        let rampsIn = rampsIn
        let rampDuration = rampsIn ? ScreenChangeTransitionPolicy.rampInDuration : 0.001
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, progress in
            let frame = ScreenChangeTransitionPolicy.frame(progress: progress, axis: axis, reduceMotion: reduceMotion)
            view
                .scaleEffect(x: frame.scaleX, y: frame.scaleY)
                .blur(radius: frame.blurRadius, opaque: true)
                .opacity(frame.opacity)
        } keyframes: { _ in
            // 换屏那一刻直接到起点（接在系统过渡之后时很快地淡进起点），再按面板那样的缓出回到原样。
            MoveKeyframe(rampsIn ? 0.0 : 1.0)
            LinearKeyframe(1.0, duration: rampDuration * PMLayoutSwitchTiming.slowFactor)
            CubicKeyframe(
                0.0,
                duration: (reduceMotion
                    ? ScreenChangeTransitionPolicy.reducedMotionDuration
                    : ScreenChangeTransitionPolicy.duration) * PMLayoutSwitchTiming.slowFactor
            )
        }
    }
}

private struct PMWindowCanvasSizeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    /// 承载界面的窗口尺寸。只有折叠屏 iPhone 的根视图写入（`pmScreenChangeTransition()`，和尺寸等级在同一次
    /// 更新里变），按画布宽窄换栏数的页面（首页）据此在开合的第一帧就排对，不必等自己量出来的尺寸晚一帧。
    /// 其它设备与取证框之外为 nil，页面照旧用自己量出来的尺寸。
    var pmWindowCanvasSize: CGSize? {
        get { self[PMWindowCanvasSizeKey.self] }
        set { self[PMWindowCanvasSizeKey.self] = newValue }
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
    /// 窗口的尺寸或所在屏幕变了（探针回报）、铰链或复查定下了一次归位，让下面重新比一次。
    @State private var windowRevision = 0

    func body(content: Content) -> some View {
        if PMFoldableDevice.isFoldable {
            // 在这次更新里就比：没有铰链读数时新尺寸的第一帧已经是过渡的起点，不会先清楚地闪一下再糊上去。
            let _ = tracker.setRefresh { windowRevision &+= 1 }
            let _ = tracker.observe(
                isRegularWidth: horizontalSizeClass == .regular,
                isRegularHeight: verticalSizeClass == .regular,
                revision: windowRevision
            )
            content
                .environment(\.pmWindowCanvasSize, tracker.windowSize)
                .pmScreenChangeSettle(trigger: tracker.generation, axis: tracker.axis, rampsIn: tracker.rampsIn)
                .background {
                    PMScreenChangeWindowProbe(tracker: tracker) { windowRevision &+= 1 }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .modifier(PMHingeObservation(tracker: tracker))
        } else {
            content
        }
    }
}

/// iOS 27.1 起读铰链（`onHingeChange`）：开合按铰链停稳的时刻安排整屏归位，见
/// `ScreenChangeTransitionPolicy.HingeSequencer`。Xcode 27.0 构建与 iOS 27.1 以前原样返回，只按尺寸判定。
private struct PMHingeObservation: ViewModifier {
    let tracker: PMScreenChangeTracker

    func body(content: Content) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                tracker.hingeChanged(context.hinge.map { PMHingeReading($0) })
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// 一次铰链读数：状态与角度（度）。
struct PMHingeReading {
    var status: ScreenChangeTransitionPolicy.HingeSequencer.HingeStatus
    var degrees: Double

    #if canImport(SwiftUI, _version: 8.0.85)
    @available(iOS 27.1, *)
    init(_ hinge: DeviceHinge) {
        if hinge.status == .closed {
            status = .closed
        } else if hinge.status == .fullyOpen {
            status = .fullyOpen
        } else {
            status = .partiallyOpen
        }
        degrees = hinge.angle.degrees
    }
    #endif
}

/// 记着上一次看到的画布，比出「换了一块屏幕」就把代数加一。不是可观察对象：只在根视图求值、
/// 铰链回报与到点复查时读写（都在主线程）。
///
/// 有铰链读数时换屏交给 `HingeSequencer` 排时间：铰链停稳、窗口也换了屏才开始归位，接在系统自己的
/// 开合过渡后面；没有铰链读数时换屏那一刻就开始。调试构建把每一步写进日志（🪟 开头）。
@MainActor
final class PMScreenChangeTracker {
    weak var window: UIWindow?
    private(set) var generation = 0
    /// 这次求值时窗口的尺寸（还没拿到窗口时为 nil）。
    var windowSize: CGSize? { window?.bounds.size }
    private(set) var axis: ScreenChangeTransitionPolicy.Axis = .horizontal
    /// 这一次归位接在系统的开合过渡之后（按铰链定的时间），先淡进起点。
    private(set) var rampsIn = false
    /// 求值之外定下了归位（铰链回报、到点复查）时请根视图重新求值；根视图每次求值时交进来。
    private var requestRefresh: (() -> Void)?

    func setRefresh(_ refresh: @escaping () -> Void) {
        requestRefresh = refresh
    }
    private var last: ScreenChangeTransitionPolicy.Canvas?
    private var sequencer = ScreenChangeTransitionPolicy.HingeSequencer()
    #if DEBUG
    private var lastLoggedHinge: (status: ScreenChangeTransitionPolicy.HingeSequencer.HingeStatus, degrees: Double, at: Double)?
    #endif

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

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
        #if DEBUG
        plog("🪟 canvas \(Self.describe(canvas)) scene=\(Self.describe(scene.activationState)) \(Self.orientationSummary(window))")
        #endif
        if let last {
            // 求值当中不改状态：定下来就直接加代数（这次求值接着就读到），要复查就排到之后。
            handle(sequencer.canvasChanged(from: last, to: canvas, at: Self.now), inRootEvaluation: true)
        }
        last = canvas
        return generation
    }

    /// 铰链回报（`nil` 是这里拿不到铰链读数）。只有状态变化交给排程，角度只进日志。
    func hingeChanged(_ reading: PMHingeReading?) {
        let time = Self.now
        #if DEBUG
        logHinge(reading, at: time)
        #endif
        let changed = reading.map { $0.status != sequencer.status } ?? sequencer.hasHinge
        guard changed else { return }
        handle(sequencer.hingeChanged(to: reading?.status, at: time), inRootEvaluation: false)
    }

    /// `inRootEvaluation`：正在根视图求值里（代数改了这次求值就读到）；不在的话定下归位后请根视图重新求值。
    private func handle(
        _ decision: ScreenChangeTransitionPolicy.HingeSequencer.Decision,
        inRootEvaluation: Bool
    ) {
        switch decision {
        case .fire(let axis, let reason):
            generation &+= 1
            self.axis = axis
            rampsIn = sequencer.hasHinge
            plog("🪟 settle FIRE #\(generation) axis=\(axis) rampIn=\(rampsIn) — \(reason)")
            if !inRootEvaluation { requestRefresh?() }
        case .recheck(let delay, let reason):
            #if DEBUG
            plog("🪟 settle wait \(Int(delay * 1000))ms — \(reason)")
            #endif
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.handle(self.sequencer.tick(at: Self.now), inRootEvaluation: false)
            }
        case .skip(let reason):
            #if DEBUG
            plog("🪟 settle skip — \(reason)")
            #endif
        }
    }

    #if DEBUG
    /// 状态变化都记；只有角度在变时最多每 100ms、变化超过 2° 才记一行。
    private func logHinge(_ reading: PMHingeReading?, at time: Double) {
        guard let reading else {
            plog("🪟 hinge unavailable")
            lastLoggedHinge = nil
            return
        }
        if let lastLoggedHinge, lastLoggedHinge.status == reading.status,
           time - lastLoggedHinge.at < 0.1 || abs(reading.degrees - lastLoggedHinge.degrees) < 2 {
            return
        }
        let first = lastLoggedHinge == nil
        let statusChanged = lastLoggedHinge?.status != reading.status
        lastLoggedHinge = (reading.status, reading.degrees, time)
        plog("🪟 hinge \(first ? "initial " : "")\(reading.status.rawValue) \(String(format: "%.1f", reading.degrees))°"
            + (statusChanged ? " \(Self.orientationSummary(window))" : ""))
    }

    /// 界面朝向、设备朝向、所在屏幕与生效的朝向掩码(只记录,判断开合后界面倒置是谁的问题)。
    static func orientationSummary(_ window: UIWindow?) -> String {
        guard let window, let scene = window.windowScene else { return "iface=- (no window)" }
        let screen = scene.screen
        let native = screen.nativeBounds.size
        let appMask = UIApplication.shared.supportedInterfaceOrientations(for: window)
        let rootMask = window.rootViewController?.supportedInterfaceOrientations
        return "iface=\(describe(scene.effectiveGeometry.interfaceOrientation)) "
            + "device=\(describe(UIDevice.current.orientation)) "
            + "screen=\(String(UInt(bitPattern: ObjectIdentifier(screen).hashValue), radix: 16)) "
            + "native=\(Int(native.width))×\(Int(native.height)) "
            + "mask=\(describe(appMask)) root=\(rootMask.map { describe($0) } ?? "-")"
    }

    static func describe(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .unknown: "unknown"
        @unknown default: "?\(orientation.rawValue)"
        }
    }

    static func describe(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .faceUp: "faceUp"
        case .faceDown: "faceDown"
        case .unknown: "unknown"
        @unknown default: "?\(orientation.rawValue)"
        }
    }

    static func describe(_ mask: UIInterfaceOrientationMask) -> String {
        var parts: [String] = []
        if mask.contains(.portrait) { parts.append("portrait") }
        if mask.contains(.portraitUpsideDown) { parts.append("upsideDown") }
        if mask.contains(.landscapeLeft) { parts.append("landscapeLeft") }
        if mask.contains(.landscapeRight) { parts.append("landscapeRight") }
        return parts.isEmpty ? "none" : parts.joined(separator: "|")
    }

    static func describe(_ canvas: ScreenChangeTransitionPolicy.Canvas) -> String {
        "screen=\(canvas.screenID.map { String(UInt(bitPattern: $0), radix: 16) } ?? "-") "
            + "\(Int(canvas.width))×\(Int(canvas.height)) of \(Int(canvas.screenWidth))×\(Int(canvas.screenHeight)) "
            + "size=\(canvas.isRegularWidth ? "R" : "C")/\(canvas.isRegularHeight ? "R" : "C") "
            + "fills=\(canvas.fillsScreen)"
    }

    static func describe(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .foregroundActive: "active"
        case .foregroundInactive: "inactive"
        case .background: "background"
        case .unattached: "unattached"
        @unknown default: "unknown"
        }
    }
    #endif
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
            #if DEBUG
            observeSceneActivation()
            #endif
            publishIfNeeded()
        }

        #if DEBUG
        private var sceneObservers: [NSObjectProtocol] = []
        private weak var observedScene: UIScene?

        /// 调试构建：场景激活状态的变化也记一行（🪟），和铰链、窗口的日志排在一起看开合时的先后。
        private func observeSceneActivation() {
            guard let scene = window?.windowScene, scene !== observedScene else { return }
            sceneObservers.forEach(NotificationCenter.default.removeObserver)
            observedScene = scene
            let events: [(Notification.Name, String)] = [
                (UIScene.willDeactivateNotification, "willDeactivate"),
                (UIScene.didActivateNotification, "didActivate"),
                (UIScene.didEnterBackgroundNotification, "didEnterBackground"),
                (UIScene.willEnterForegroundNotification, "willEnterForeground"),
            ]
            sceneObservers = events.map { name, label in
                NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { _ in
                    plog("🪟 scene \(label)")
                }
            }
            // 设备朝向每变一次也记(连同界面朝向、所在屏幕与朝向掩码)。
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            sceneObservers.append(NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    plog("🪟 device orientation changed \(PMScreenChangeTracker.orientationSummary(self?.window))")
                }
            })
        }
        #endif

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
