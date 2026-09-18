import PrimuseKit
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// 全 App 共用的动效词汇。
///
/// 时长与曲线一旦各写各的，同一种交互在不同页面就会快慢不一 —— 同样是「换页」，
/// 这边 0.15 那边 0.3，用起来像两个 app。所以这里按「这次变化在表达什么」分档，
/// 调用处只写档位名，不写秒数。
///
/// 曲线由当前界面皮肤的动效表给出(`PMMotionSkin`);经典皮肤的表就是下面 `classicAnimation`
/// 里的字面量，所以经典外观不变，别的皮肤可以整体换一套节奏。
enum PMMotion: Sendable {
    /// 悬停高亮、选中底色这类微反馈。
    case hover
    /// 按压反馈。
    case press
    /// 图标与加载圈互换、小浮层出入。
    case control
    /// 页面或标签的内容替换。
    case pageSwitch
    /// 加载态换成内容、空态与内容互换。
    case contentAppear
    /// 列表项增删重排、进出编辑与选择态、横幅出入。
    case list
    /// 面板、侧栏、抽屉的出入。
    case panel
    /// 选中指示在同级项之间移动。
    case selection
    /// 换歌时封面与标题的交叉淡入。
    case trackChange
    /// 取色背景、氛围层这类慢速铺垫。
    case ambient

    /// 当前皮肤给这一档定的曲线。
    @MainActor
    var animation: Animation {
        PMMotionSkin.animation(for: self)
    }

    /// 皮肤动效表里对应的位。
    var skinToken: SkinMotionToken {
        switch self {
        case .hover: return .hover
        case .press: return .press
        case .control: return .control
        case .pageSwitch: return .pageSwitch
        case .contentAppear: return .contentAppear
        case .list: return .list
        case .panel: return .panel
        case .selection: return .selection
        case .trackChange: return .trackChange
        case .ambient: return .ambient
        }
    }

    /// 经典皮肤的取值,也是皮肤表里缺项时的兜底。与 Kit 里经典表的同名位一致,有测试钉住。
    var classicAnimation: Animation {
        switch self {
        case .hover: return .easeOut(duration: 0.12)
        case .press: return .easeOut(duration: 0.12)
        case .control: return .easeOut(duration: 0.18)
        case .pageSwitch: return .easeOut(duration: 0.18)
        case .contentAppear: return .easeOut(duration: 0.2)
        case .list: return .snappy(duration: 0.22)
        case .panel: return .easeInOut(duration: 0.25)
        case .selection: return .spring(response: 0.3, dampingFraction: 0.86)
        case .trackChange: return .easeInOut(duration: 0.28)
        case .ambient: return .easeInOut(duration: 0.5)
        }
    }

    /// 这一档会不会让界面上的东西挪位置。只改透明度的档位不算。
    var involvesMovement: Bool {
        switch self {
        case .press, .list, .panel, .selection:
            return true
        case .hover, .control, .pageSwitch, .contentAppear, .trackChange, .ambient:
            return false
        }
    }

    /// 开启「减少动态效果」时位移类档位直接不做动画；纯淡入淡出不构成前庭负担，照常返回。
    @MainActor
    func resolved(reduceMotion: Bool) -> Animation? {
        if reduceMotion, involvesMovement { return nil }
        return animation
    }
}

/// 当前皮肤的动效表。皮肤运行时在换皮肤时写入;没有皮肤运行时的平台(Mac)保持经典。
///
/// 做成一处全局而不是从环境读,是因为 `PMMotion` 也在按钮的 action、服务层回调这些
/// 读不到环境的地方使用(`pmWithAnimation`),两条路径必须给出同一条曲线。
@MainActor
enum PMMotionSkin {
    static var motion: [SkinMotionToken: SkinMotionSpec] = SkinCatalog.classic.motion

    static func animation(for motion: PMMotion) -> Animation {
        let token = motion.skinToken
        let spec = Self.motion[token] ?? SkinCatalog.classic.motion[token]
        return spec?.swiftUIAnimation ?? motion.classicAnimation
    }
}

/// 附在过渡本身上的曲线。
///
/// `resolved` 把位移档位判成 nil 是为了「不要动」，但过渡这边此时已经退化成纯淡入淡出，
/// 再不附曲线就成了硬切 —— 开了减少动态效果的人反而看到更生硬的画面。所以这种情况下
/// 换成 `control` 的淡入淡出曲线。
@MainActor
private func pmTransitionAnimation(_ motion: PMMotion?, reduceMotion: Bool) -> Animation? {
    guard let motion else { return nil }
    if reduceMotion, motion.involvesMovement { return PMMotion.control.animation }
    return motion.resolved(reduceMotion: reduceMotion)
}

extension View {
    /// 按档位给某个值挂动画，等价于 `.animation(_:value:)`，但会照顾「减少动态效果」。
    ///
    /// 挂在能代表这次变化的最小容器上，`value` 用小的 `Equatable`。
    func pmAnimation<V: Equatable>(_ motion: PMMotion, value: V) -> some View {
        modifier(PMAnimationModifier(motion: motion, value: value))
    }

    /// 出现时淡入。
    ///
    /// 给被 `.id(...)` 整块重建的页面用：重建本身没有新旧两棵子树可以交叉过渡，
    /// 把重建放进动画事务又会让整页布局跟着抖。这里只在新内容出现后淡一下透明度，
    /// 不加位移。
    func pmAppearFade(_ motion: PMMotion = .pageSwitch) -> some View {
        modifier(PMAppearFadeModifier(motion: motion))
    }

    /// 从某一边推入推出的过渡。开启「减少动态效果」时退化成纯淡入淡出。
    ///
    /// 挂在 `if` / `switch` 分支里的那个视图上，不是挂在外面的容器上。
    /// `motion` 留空表示曲线由外部事务给（调用点自己包了 `withAnimation`）；
    /// 传了档位就把曲线附在过渡上，服务层裸赋值触发的切换也能动起来。
    func pmSlideTransition(edge: Edge, motion: PMMotion? = nil) -> some View {
        modifier(PMSlideTransitionModifier(edge: edge, motion: motion))
    }

    /// 纯淡入淡出的过渡。挂法与 `pmSlideTransition` 相同。
    func pmFadeTransition(motion: PMMotion? = nil) -> some View {
        modifier(PMFadeTransitionModifier(motion: motion))
    }

    /// 指针悬停时轻微抬起。iOS 上原样返回，共用的视图不必为它写 `#if`。
    ///
    /// 悬停状态记在修饰符自己身上：卡片的 body 里可能有整库级的计算，
    /// 把 hover 放进卡片的 `@State` 会让每次划过都重算一遍。
    ///
    /// - Parameter cornerRadius: 给出的话，悬停时在卡片背后垫一块同圆角的浅色底。
    func pmHoverLift(scale: CGFloat = 1.02, cornerRadius: CGFloat? = nil) -> some View {
        modifier(PMHoverLiftModifier(hoverScale: scale, cornerRadius: cornerRadius))
    }
}

extension Binding {
    /// 让这个绑定的写入自带动画事务，等价于 SwiftUI 的 `animation(_:)`，但会照顾「减少动态效果」。
    ///
    /// 给「开关一开就展开几行子项」这类设置项用：`Toggle(isOn: $enabled.pmAnimated())`。
    /// 被它带出来的行自己挂过渡。
    @MainActor
    func pmAnimated(_ motion: PMMotion = .list) -> Binding<Value> {
        animation(motion.resolved(reduceMotion: PMMotionAccessibility.reduceMotion))
    }
}

/// 给读不到环境的调用点用 —— 按钮的 action、服务层回调这些地方没有 `@Environment`。
///
/// 只包住要变的那几个状态；范围一大，无关的视图也会跟着一起动。
@MainActor
func pmWithAnimation<Result>(_ motion: PMMotion, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(motion.resolved(reduceMotion: PMMotionAccessibility.reduceMotion), body)
}

/// 按下时缩一下、暗一点。调用处写 `.buttonStyle(.pmPressable)`。
struct PMPressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PMPressableLabel(configuration: configuration)
    }
}

extension ButtonStyle where Self == PMPressableButtonStyle {
    static var pmPressable: PMPressableButtonStyle { PMPressableButtonStyle() }
}

// MARK: - 实现

private struct PMAnimationModifier<V: Equatable>: ViewModifier {
    let motion: PMMotion
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.resolved(reduceMotion: reduceMotion), value: value)
    }
}

private struct PMAppearFadeModifier: ViewModifier {
    let motion: PMMotion

    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(motion.animation) { appeared = true }
            }
    }
}

private struct PMSlideTransitionModifier: ViewModifier {
    let edge: Edge
    let motion: PMMotion?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(transition)
    }

    private var transition: AnyTransition {
        let base = shape
        guard let animation = pmTransitionAnimation(motion, reduceMotion: reduceMotion) else { return base }
        return base.animation(animation)
    }

    private var shape: AnyTransition {
        if reduceMotion { return .opacity }
        return AnyTransition.move(edge: edge).combined(with: .opacity)
    }
}

private struct PMFadeTransitionModifier: ViewModifier {
    let motion: PMMotion?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(transition)
    }

    private var transition: AnyTransition {
        let base = AnyTransition.opacity
        guard let animation = pmTransitionAnimation(motion, reduceMotion: reduceMotion) else { return base }
        return base.animation(animation)
    }
}

private struct PMHoverLiftModifier: ViewModifier {
    let hoverScale: CGFloat
    let cornerRadius: CGFloat?

    #if os(macOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(alignment: .center) { plate }
            .scaleEffect(currentScale)
            .brightness(currentBrightness)
            .onHover { hovering = $0 }
            .animation(PMMotion.hover.animation, value: hovering)
    }

    @ViewBuilder
    private var plate: some View {
        if let cornerRadius, hovering {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(Self.plateOpacity))
        }
    }

    private var currentScale: CGFloat {
        guard hovering, !reduceMotion else { return 1 }
        return hoverScale
    }

    /// 不缩放时总得留点反馈，提亮一档代替。
    private var currentBrightness: Double {
        guard hovering, reduceMotion else { return 0 }
        return Self.reducedBrightness
    }

    private static let plateOpacity: Double = 0.06
    private static let reducedBrightness: Double = 0.06
    #else
    func body(content: Content) -> some View { content }
    #endif
}

/// `ButtonStyle` 不是视图，里面的 `@Environment` 不会被填。要读环境就得进一层真视图。
private struct PMPressableLabel: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(currentScale)
            .opacity(currentOpacity)
            // 缩放已经按「减少动态效果」去掉了，剩下的透明度变化不是位移，两种设置下都走同一条曲线。
            .animation(PMMotion.press.animation, value: configuration.isPressed)
    }

    private var currentScale: CGFloat {
        guard configuration.isPressed, !reduceMotion else { return 1 }
        return Self.pressedScale
    }

    private var currentOpacity: Double {
        configuration.isPressed ? Self.pressedOpacity : 1
    }

    private static let pressedScale: CGFloat = 0.97
    private static let pressedOpacity: Double = 0.82
}

/// 环境之外读「减少动态效果」。
@MainActor
private enum PMMotionAccessibility {
    static var reduceMotion: Bool {
        #if os(macOS)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #elseif os(iOS)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }
}
