import SwiftUI
#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#endif

extension View {
    /// 歌曲行的按压态:手指按住一小会儿(不是在滚动)就轻轻缩一点、垫上一层浅底,松手按 pop 那一档回弹。
    ///
    /// 只做观察、不抢点按:行的点按(开播、多选勾选)仍由各页面原来的 `onTapGesture` 处理,
    /// 承载长按菜单的宿主也不换。状态全在这个修饰符里,按下、松开只重画这一行。
    ///
    /// - Parameters:
    ///   - showsPlate: 垫不垫浅底。列表样式垫;别的样式自己有底,只缩放。
    ///   - trailingExclusion: 尾部这么宽的一截不算(那里是 ⋯ 菜单键,它自己有按下的样子)。
    ///   - onTap: 一次干脆的点按(没挪动、没被滚动或长按菜单接走)松手时调用。
    ///
    /// Mac 上原样返回:点击没有按住的过程,悬停另有自己的反馈。
    func songRowPressFeedback(
        showsPlate: Bool,
        trailingExclusion: CGFloat,
        onTap: @escaping @MainActor () -> Void
    ) -> some View {
        #if os(iOS)
        modifier(SongRowPressFeedbackModifier(
            showsPlate: showsPlate,
            trailingExclusion: trailingExclusion,
            onTap: onTap
        ))
        #else
        self
        #endif
    }
}

#if os(iOS)
private enum SongRowPressEvent {
    /// 按住够久、没挪动:显示按压态。
    case pressBegan
    /// 松手、挪开、被滚动或长按菜单接走:回到原样。`bounces` 为真时(松手)带回弹。
    case pressEnded(bounces: Bool)
    /// 一次干脆的点按。
    case tapped
}

private struct SongRowPressFeedbackModifier: ViewModifier {
    let showsPlate: Bool
    let trailingExclusion: CGFloat
    let onTap: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    /// 只在尺寸变时回调,滚动时行的大小不变,不会每帧都来。
    @State private var rowWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                if showsPlate {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isPressed ? Self.plateOpacity : 0))
                        .padding(.horizontal, -8)
                        .padding(.vertical, -4)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(isPressed && !reduceMotion ? Self.pressedScale : 1)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                rowWidth = width
            }
            .gesture(SongRowPressGesture(
                trailingExclusion: trailingExclusion,
                rowWidth: rowWidth,
                onEvent: handle
            ))
    }

    private func handle(_ event: SongRowPressEvent) {
        switch event {
        case .pressBegan:
            withAnimation(PMMotion.press.animation) { isPressed = true }
        case .pressEnded(let bounces):
            let animation = bounces
                ? (PMMotion.pop.resolved(reduceMotion: reduceMotion) ?? PMMotion.press.animation)
                : PMMotion.press.animation
            withAnimation(animation) { isPressed = false }
        case .tapped:
            onTap()
        }
    }

    private static let pressedScale: CGFloat = 0.985
    private static let plateOpacity: Double = 0.07
}

private struct SongRowPressGesture: UIGestureRecognizerRepresentable {
    let trailingExclusion: CGFloat
    let rowWidth: CGFloat
    let onEvent: @MainActor (SongRowPressEvent) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> SongRowPressRecognizer {
        let recognizer = SongRowPressRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        let coordinator = context.coordinator
        recognizer.localPoint = { coordinator.converter.localLocation }
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: SongRowPressRecognizer,
        context: Context
    ) {
        recognizer.trailingExclusion = trailingExclusion
        recognizer.rowWidth = rowWidth
        recognizer.onEvent = onEvent
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: SongRowPressRecognizer,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var converter: UIGestureRecognizerRepresentableCoordinateSpaceConverter

        init(converter: UIGestureRecognizerRepresentableCoordinateSpaceConverter) {
            self.converter = converter
        }

        /// 这个识别器从不「识别成功」,只是旁观,和谁都可以同时存在。别的拖动(列表滚动、
        /// 行的左右滑)或长按(长按菜单)要开始时 UIKit 会来问这一句,正好趁这时收起按压态。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if otherGestureRecognizer is UIPanGestureRecognizer
                || otherGestureRecognizer is UILongPressGestureRecognizer {
                (gestureRecognizer as? SongRowPressRecognizer)?.abandon()
            }
            return true
        }
    }
}

/// 只看不抢的按压识别器:一直停在 `.possible`,手指抬起或被别的手势接走时直接判失败,
/// 不会让任何点按、滚动、长按菜单等它。
private final class SongRowPressRecognizer: UIGestureRecognizer {
    var onEvent: (@MainActor (SongRowPressEvent) -> Void)?
    var localPoint: (@MainActor () -> CGPoint)?
    var trailingExclusion: CGFloat = 0
    var rowWidth: CGFloat = 0

    private var startPoint: CGPoint = .zero
    private var startTimestamp: TimeInterval = 0
    private var isTracking = false
    private var isShowingPress = false
    private var pressTask: Task<Void, Never>?
    private var longHoldTask: Task<Void, Never>?

    /// 按住多久才显示按压态。滚动起手的那一下通常在这之前就已经挪出容差了。
    private static let pressDelay: Duration = .milliseconds(80)
    /// 点按很快、按压态还没来得及出来时,补一下按下再弹回,至少停这么久才看得见。
    private static let quickTapHold: Duration = .milliseconds(90)
    /// 按住这么久还没松手,多半是要长按菜单了:先把按压态收起来,别和系统菜单的抬起叠在一起。
    private static let longHoldRelease: Duration = .milliseconds(420)
    /// 超过这么久才松手的不算点按(长按菜单没弹出来、手指停在原地松开的情况)。
    private static let maximumTapDuration: TimeInterval = 0.5
    private static let movementTolerance: CGFloat = 10

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard !isTracking,
              touches.count == 1,
              (event.allTouches?.count ?? 1) == 1,
              let touch = touches.first,
              let view else {
            abandon()
            return
        }
        if trailingExclusion > 0, rowWidth > trailingExclusion,
           let local = localPoint?(), local.x > rowWidth - trailingExclusion {
            state = .failed
            return
        }
        isTracking = true
        startPoint = touch.location(in: view)
        startTimestamp = touch.timestamp

        pressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pressDelay)
            guard !Task.isCancelled else { return }
            self?.showPress()
        }
        longHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.longHoldRelease)
            guard !Task.isCancelled else { return }
            self?.releasePress(bounces: false)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard isTracking, let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        if hypot(point.x - startPoint.x, point.y - startPoint.y) > Self.movementTolerance {
            abandon()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard isTracking else {
            if state == .possible { state = .failed }
            return
        }
        let duration = (touches.first?.timestamp ?? startTimestamp) - startTimestamp
        cancelPendingWork()
        isTracking = false
        if duration <= Self.maximumTapDuration {
            if isShowingPress {
                releasePress(bounces: true)
            } else {
                // 快到按压态还没出来:补一下按下,停一小会儿再弹回来,点了要看得见。
                isShowingPress = true
                send(.pressBegan)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.quickTapHold)
                    self?.releasePress(bounces: true)
                }
            }
            send(.tapped)
        } else {
            releasePress(bounces: false)
        }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        abandon()
    }

    override func reset() {
        super.reset()
        cancelPendingWork()
        isTracking = false
    }

    /// 被滚动、左右滑、长按菜单接走,或者挪出了容差:收起按压态,这一下不再算点按。
    func abandon() {
        cancelPendingWork()
        isTracking = false
        releasePress(bounces: false)
        if state == .possible {
            state = .failed
        }
    }

    private func showPress() {
        guard isTracking, !isShowingPress else { return }
        isShowingPress = true
        send(.pressBegan)
    }

    private func releasePress(bounces: Bool) {
        guard isShowingPress else { return }
        isShowingPress = false
        send(.pressEnded(bounces: bounces))
    }

    private func cancelPendingWork() {
        pressTask?.cancel()
        pressTask = nil
        longHoldTask?.cancel()
        longHoldTask = nil
    }

    private func send(_ event: SongRowPressEvent) {
        onEvent?(event)
    }
}
#endif
