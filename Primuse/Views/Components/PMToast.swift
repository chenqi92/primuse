import SwiftUI
import PrimuseKit

/// 底部提示条：做完一件事之后说一句「已加入队列」「已清理 12 MB」「已删除，可撤销」。
///
/// 全 App 一个样子：玻璃胶囊，从底部（迷你条上方）弹簧浮入、停留、下沉淡出；连续触发时
/// 原地换内容，不叠成一摞（排队规则见 Kit 的 `ToastSchedule`）。减少动态效果时只淡入淡出。
///
/// 两种挂法：
/// - 跟着页面走的（撤销删除、清理缓存、歌单里的刮削结果）：页面自己持有一个
///   `PMToastPresenter`，`.pmToastHost(presenter)` 挂在页面上。页面在弹出层里时也看得见，
///   离开页面就跟着没了。
/// - 跟页面无关、要活过发起页的（滑动入队、批量删除的进度与结果）：用 `PMToastPresenter.shared`，
///   由根视图挂一份 `.pmToastHost(.shared, placement: .appRoot(...))`。
struct PMToastItem {
    enum Tone {
        /// 玻璃底、正文色。
        case standard
        /// 出错：红底白字，压在任何背景上都看得出来。
        case error
    }

    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    /// 来源。同一个来源只留最新的一条。
    var key: String
    var message: String
    var systemImage: String?
    /// 图标颜色；nil 时跟随强调色。
    var tint: Color?
    var tone: Tone = .standard
    /// 图标位置换成转圈（进度类常驻提示）。
    var showsProgress = false
    /// nil 表示常驻，等发起方 `dismiss(key:)`。
    var duration: TimeInterval? = 3
    var action: Action?
}

/// 一组提示的排队与计时。页面各持一个，或者用全 App 共用的 `shared`。
@MainActor
@Observable
final class PMToastPresenter {
    /// 跟页面无关的提示：滑动入队、批量删除。由根视图挂宿主。
    static let shared = PMToastPresenter()

    struct Presented: Identifiable {
        let serial: UInt64
        let item: PMToastItem
        var id: UInt64 { serial }
    }

    /// 现在该露出来的那一条。只有宿主读它。
    private(set) var current: Presented?

    @ObservationIgnored private var schedule = ToastSchedule()
    @ObservationIgnored private var items: [UInt64: PMToastItem] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    init() {}

    func show(_ item: PMToastItem) {
        let entry = schedule.show(key: item.key, duration: item.duration, now: Self.now)
        items[entry.serial] = item
        sync()
    }

    func dismiss(key: String) {
        guard schedule.dismiss(key: key) else { return }
        sync()
    }

    func dismissAll() {
        schedule.removeAll()
        sync()
    }

    private func sync() {
        let live = Set([schedule.transient?.serial, schedule.persistent?.serial].compactMap { $0 })
        items = items.filter { live.contains($0.key) }
        if let visible = schedule.visible, let item = items[visible.serial] {
            if current?.serial != visible.serial {
                current = Presented(serial: visible.serial, item: item)
            }
        } else if current != nil {
            current = nil
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let deadline = schedule.nextDeadline else {
            expiryTask = nil
            return
        }
        let delay = max(0, deadline - Self.now)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if self.schedule.expire(now: Self.now) {
                self.sync()
            } else {
                // 醒早了一点：按剩下的时间再睡。
                self.scheduleExpiry()
            }
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// 提示条浮在哪儿。
enum PMToastPlacement {
    /// 挂在页面上：贴着页面的安全区下沿（标签栏、迷你条都已经算在安全区里）。
    case page
    /// 挂在 App 根视图上：根视图不知道标签栏和迷你条多高，按迷你条胶囊在窗口里的实际位置
    /// 浮在它上面；没有迷你条时离安全区下沿 `fallbackClearance`。
    case appRoot(fallbackClearance: CGFloat)
}

extension View {
    /// 在这一层底部显示 `presenter` 的提示条。
    func pmToastHost(_ presenter: PMToastPresenter, placement: PMToastPlacement = .page) -> some View {
        overlay(alignment: .bottom) {
            PMToastStage(presenter: presenter, placement: placement)
        }
    }

    /// 提示条自己的进出场：从 `edge` 那一侧弹簧浮入，原路下沉淡出；减少动态效果时只淡入淡出。
    /// 不经过 `PMToastPresenter`、由状态直接控制显隐的提示条（播放页的出错提示）挂这个。
    func pmToastTransition(edge: VerticalEdge = .bottom) -> some View {
        modifier(PMToastTransitionModifier(edge: edge))
    }
}

/// 提示条的外观。播放页的出错提示这类不走 presenter 的地方也直接用它，样子与动效保持一致。
struct PMToastCapsule<Accessory: View>: View {
    let message: String
    var systemImage: String?
    var tint: Color?
    var tone: PMToastItem.Tone = .standard
    var showsProgress = false
    /// 小一号：嵌在版面里、不想把下面的东西挤开太多时（播放页的出错提示）。
    var isCompact = false
    /// 操作键放在正文右边还是下面一行（两颗以上的键放下面）。
    var accessoryBelow = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Group {
            if accessoryBelow {
                VStack(spacing: 8) {
                    lead
                    accessory
                }
            } else {
                HStack(spacing: 10) {
                    lead
                    accessory
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isCompact ? 8 : 11)
        .frame(maxWidth: 560)
        .background { PMToastBackground(tone: tone, cornerRadius: isCompact ? 16 : 21) }
        .shadow(color: .black.opacity(tone == .error ? 0.18 : 0.14), radius: 12, y: 4)
    }

    private var lead: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(tone == .error ? Color.white : nil)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(isCompact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(iconStyle)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(verbatim: message)
                .font(isCompact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .foregroundStyle(tone == .error ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .multilineTextAlignment(accessoryBelow ? .center : .leading)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                // 进度这类只换数字的提示逐位翻动，整句换掉时也是原地过渡，不闪。
                .contentTransition(.numericText())
        }
    }

    private var iconStyle: AnyShapeStyle {
        if tone == .error { return AnyShapeStyle(Color.white) }
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(.tint)
    }
}

extension PMToastCapsule where Accessory == EmptyView {
    init(
        message: String,
        systemImage: String? = nil,
        tint: Color? = nil,
        tone: PMToastItem.Tone = .standard,
        showsProgress: Bool = false
    ) {
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.tone = tone
        self.showsProgress = showsProgress
        self.accessory = EmptyView()
    }
}

/// 提示条上的操作键（撤销）。
struct PMToastActionButton: View {
    let title: String
    var tone: PMToastItem.Tone = .standard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone == .error ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
                .padding(.horizontal, tone == .error ? 12 : 4)
                .padding(.vertical, tone == .error ? 5 : 2)
                .background {
                    if tone == .error {
                        Capsule().fill(.white.opacity(0.22))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PMToastBackground: View {
    let tone: PMToastItem.Tone
    /// 单行时的半高：单行就是胶囊，多行时成了圆角矩形，不会变成一颗药丸。
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        switch tone {
        case .error:
            shape.fill(Color.red.opacity(0.82))
        case .standard:
            #if os(iOS) || os(macOS)
            if #available(iOS 26.0, macOS 26.0, *) {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
                    .overlay { shape.strokeBorder(.quaternary, lineWidth: 0.5) }
            }
            #else
            shape.fill(.regularMaterial)
            #endif
        }
    }
}

private struct PMToastTransitionModifier: ViewModifier {
    let edge: VerticalEdge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(PMToastTransitions.transition(edge: edge, reduceMotion: reduceMotion))
    }
}

private enum PMToastTransitions {
    /// 浮入、下沉的距离。不用 `.move(edge:)`：根视图上的提示条离屏幕底边一百多点，
    /// 整段滑上来太远。
    static let travel: CGFloat = 28

    static func transition(edge: VerticalEdge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return AnyTransition.opacity.animation(PMMotion.control.animation)
        }
        let anchor: UnitPoint = edge == .bottom ? .bottom : .top
        return AnyTransition.offset(y: edge == .bottom ? travel : -travel)
            .combined(with: .scale(scale: 0.92, anchor: anchor))
            .combined(with: .opacity)
            .animation(PMMotion.toast.animation)
    }
}

/// 读 presenter 的只有这一层：提示条换内容只重画它自己，不牵动挂它的页面。
private struct PMToastStage: View {
    let presenter: PMToastPresenter
    let placement: PMToastPlacement

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 换了一条新的临时提示（比如连着加了两首进队列）：胶囊原地轻轻顶一下，告诉人这是新的一条。
    @State private var replacePulse = 0
    /// 根视图挂法要知道自己的下沿在窗口里的位置，才能算出迷你条在它上面多高。
    @State private var stageBottomInWindow: CGFloat = 0

    var body: some View {
        let presented = presenter.current
        ZStack(alignment: .bottom) {
            if let presented {
                capsule(for: presented.item)
                    .modifier(PMToastReplacePulse(trigger: replacePulse, isEnabled: !reduceMotion))
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomPadding)
                    .transition(PMToastTransitions.transition(edge: .bottom, reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // 内容换了（不是出现、消失）时尺寸和文字按提示条那一档过渡。
        .animation(reduceMotion ? PMMotion.control.animation : PMMotion.toast.animation, value: presented?.serial)
        .onChange(of: presented?.serial) { old, new in
            guard old != nil, new != nil, presented?.item.duration != nil else { return }
            replacePulse &+= 1
        }
        .modifier(PMToastStageGeometry(placement: placement, bottomInWindow: $stageBottomInWindow))
    }

    @ViewBuilder
    private func capsule(for item: PMToastItem) -> some View {
        if let action = item.action {
            PMToastCapsule(
                message: item.message,
                systemImage: item.systemImage,
                tint: item.tint,
                tone: item.tone,
                showsProgress: item.showsProgress
            ) {
                Spacer(minLength: 8)
                PMToastActionButton(title: action.title, tone: item.tone) {
                    action.perform()
                }
            }
            .accessibilityElement(children: .contain)
        } else {
            PMToastCapsule(
                message: item.message,
                systemImage: item.systemImage,
                tint: item.tint,
                tone: item.tone,
                showsProgress: item.showsProgress
            )
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: item.message))
        }
    }

    private var bottomPadding: CGFloat {
        switch placement {
        case .page:
            return 12
        case .appRoot(let fallbackClearance):
            #if os(iOS)
            if let capsule = NowPlayingCapsuleGeometry.shared.frameInWindow(), stageBottomInWindow > 0 {
                return max(12, stageBottomInWindow - capsule.minY + 10)
            }
            #endif
            return fallbackClearance
        }
    }
}

/// 根视图挂法量一下自己的下沿；页面挂法用不着，不登记几何回调。
private struct PMToastStageGeometry: ViewModifier {
    let placement: PMToastPlacement
    @Binding var bottomInWindow: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        switch placement {
        case .page:
            content
        case .appRoot:
            content.onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxY
            } action: { maxY in
                bottomInWindow = maxY
            }
        }
    }
}

private struct PMToastReplacePulse: ViewModifier {
    let trigger: Int
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: isEnabled ? trigger : 0) { view, scale in
            view.scaleEffect(scale, anchor: .bottom)
        } keyframes: { _ in
            // 顶一下就回来：先在一小段里放大一点点，再按「pop」那种带回弹的弹簧落回原大小。
            KeyframeTrack {
                CubicKeyframe(1.04, duration: 0.09)
                SpringKeyframe(1.0, duration: 0.36, spring: Spring(response: 0.34, dampingRatio: 0.56))
            }
        }
    }
}

// MARK: - 入队回执

/// 歌被加进播放队列的那一刻。迷你条有好几种外壳，各自的封面读它弹一下；
/// 发起方只管发信号（同 `NowPlayingCollapseSignal`）。
@MainActor
@Observable
final class QueueReceiptSignal {
    static let shared = QueueReceiptSignal()
    private(set) var revision: UInt = 0

    private init() {}

    func ping() {
        revision &+= 1
    }
}

/// 加进队列之后看得见、摸得着的回执：手上一下、迷你条封面弹一下、底部说一句。
/// 滑动入队与菜单里的「下一首播放」走同一份，说法复用 Apple Music 入队提示那两句。
@MainActor
enum QueueReceipt {
    enum Placement {
        case next
        case last
    }

    static func announce(_ placement: Placement, systemImage: String) {
        PMHaptics.queued()
        QueueReceiptSignal.shared.ping()
        PMToastPresenter.shared.show(PMToastItem(
            key: "queue.receipt",
            message: placement == .next
                ? String(localized: "apple_music_queued_next")
                : String(localized: "apple_music_queued_last"),
            systemImage: systemImage,
            duration: 1.8
        ))
    }
}
