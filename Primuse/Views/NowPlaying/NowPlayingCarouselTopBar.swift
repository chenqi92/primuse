#if os(iOS)
import PrimuseKit
import SwiftUI
import UIKit

/// 播放页转轮顶部的导航条宿主：负责无交互自动隐藏与横滑 / 切页唤醒。
///
/// 逐帧变的 `state.offset` 隔离在内部子视图 `NowPlayingCarouselTopBarDialLayer` 里，
/// 避免 120Hz 拖动 / 回弹期间让倒计时器与触摸观察器跟着重算。
struct NowPlayingCarouselTopBarHost: View {
    let state: NowPlayingCarouselState
    let lyricsPresentation: NowPlayingLyricsPresentation?
    let pages: [NowPlayingCarouselPage]
    let playerIndex: Int
    let settledIndex: Int
    let departingIndex: Int?
    let darkPageIndices: Set<Int>
    let appearance: NowPlayingAppearance
    let isActive: Bool
    let isSurfaceExposed: Bool
    let width: CGFloat
    let safeInsets: EdgeInsets
    let onSelect: (Int) -> Void

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var hideStage: NowPlayingCarouselTopBarPolicy.HideStage = .visible
    @State private var idleClock = NowPlayingCarouselTopBarIdleClock()
    @State private var hideSequenceTask: Task<Void, Never>?
    @State private var wakeGeneration: UInt = 0

    private struct CountdownKey: Equatable {
        let mayAutoHide: Bool
        let settledPage: NowPlayingCarouselPage
        let wakeGeneration: UInt
    }

    var body: some View {
        let isLyricsOverlayVisible = lyricsPresentation?.isVisible ?? false
        let conditions = NowPlayingCarouselTopBarPolicy.Conditions(
            settledPage: state.settledPage,
            pageCount: pages.count,
            isActive: isActive,
            isSurfaceExposed: isSurfaceExposed,
            isLyricsOverlayVisible: isLyricsOverlayVisible,
            isDragging: state.isDragging,
            isSettling: state.isSettling,
            isControlEditing: state.isControlEditing,
            isVoiceOverRunning: voiceOverEnabled
        )
        let tracksActivity = NowPlayingCarouselTopBarPolicy.tracksActivity(conditions)
        let mayAutoHide = NowPlayingCarouselTopBarPolicy.mayAutoHide(conditions)
        let isRightToLeft = layoutDirection == .rightToLeft

        ZStack(alignment: .topLeading) {
            NowPlayingCarouselTopBarDialLayer(
                state: state,
                pages: pages,
                playerIndex: playerIndex,
                settledIndex: settledIndex,
                departingIndex: departingIndex,
                darkPageIndices: darkPageIndices,
                appearance: appearance,
                width: width,
                safeInsets: safeInsets,
                hideStage: hideStage,
                reduceMotion: reduceMotion,
                isRightToLeft: isRightToLeft,
                onSelect: { index in
                    wakeTopBar(animated: true)
                    onSelect(index)
                }
            )
            .opacity(isLyricsOverlayVisible ? 0 : 1)
            .allowsHitTesting(!isLyricsOverlayVisible && hideStage.allowsDirectBarHitTesting)
            .accessibilityHidden(isLyricsOverlayVisible || hideStage.isFullyHidden)

            // 非主播放页顶部栏收入侧边后，在原起始角留一块不挡右侧按钮的轻触唤醒区。
            if !isLyricsOverlayVisible, state.settledPage != .player, hideStage.isFullyHidden {
                Color.clear
                    .frame(width: 56, height: NowPlayingCarouselDial.rowHeight + 12)
                    .contentShape(Rectangle())
                    .onTapGesture { wakeTopBar(animated: true) }
                    .padding(.top, max(safeInsets.top + NowPlayingCarouselDial.topInset - 6, 0))
                    .padding(.leading, max(safeInsets.leading + NowPlayingCarouselDial.edgeInset - 8, 0))
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: tracksActivity, initial: true) { _, tracks in
            configureTouchObserver(enabled: tracks)
            if !tracks {
                cancelHideSequence()
                hideStage = .visible
            }
        }
        .onChange(of: state.isDragging) { _, dragging in
            if dragging { wakeTopBar(animated: true) }
        }
        .onChange(of: state.isSettling) { _, settling in
            if settling { wakeTopBar(animated: true) }
        }
        .onChange(of: state.settledPage) { _, _ in
            wakeTopBar(animated: true)
        }
        .onChange(of: isSurfaceExposed) { _, exposed in
            if exposed { wakeTopBar(animated: false) }
        }
        .onChange(of: voiceOverEnabled) { _, running in
            if running { wakeTopBar(animated: false) }
        }
        .onAppear {
            configureTouchObserver(enabled: tracksActivity)
            wakeTopBar(animated: false)
        }
        .onDisappear {
            cancelHideSequence()
            idleClock.setObservesTouches(false)
        }
        .task(id: CountdownKey(
            mayAutoHide: mayAutoHide,
            settledPage: state.settledPage,
            wakeGeneration: wakeGeneration
        )) {
            guard mayAutoHide else { return }
            idleClock.noteActivity()
            while !Task.isCancelled {
                let isBusy = idleClock.isTouching || state.isControlEditing
                let remaining = NowPlayingCarouselTopBarPolicy.remainingDelay(
                    sinceLastActivity: idleClock.idleSeconds,
                    isInteracting: isBusy
                )
                guard remaining > 0 else { break }
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            guard !state.isDragging, !state.isSettling, !state.isControlEditing, !voiceOverEnabled else { return }
            beginAutoHide(for: state.settledPage)
        }
    }

    private func configureTouchObserver(enabled: Bool) {
        idleClock.onTouchActivity = { [state] in
            // 收球中途手指落下则立刻弹回可见；已彻底隐藏时不打扰正常滚动与播放操作。
            if NowPlayingCarouselTopBarPolicy.shouldAbortHideOnGeneralTouch(stage: hideStage) {
                wakeTopBar(animated: true)
            } else if state.isControlEditing, hideStage != .visible {
                wakeTopBar(animated: true)
            }
        }
        idleClock.setObservesTouches(enabled)
    }

    private func cancelHideSequence() {
        hideSequenceTask?.cancel()
        hideSequenceTask = nil
    }

    private func wakeTopBar(animated: Bool) {
        cancelHideSequence()
        idleClock.noteActivity()
        wakeGeneration &+= 1
        guard hideStage != .visible else { return }
        if animated {
            let animation: Animation = reduceMotion
                ? .easeInOut(duration: 0.2)
                : .spring(response: 0.38, dampingFraction: 0.74)
            withAnimation(animation) {
                hideStage = .visible
            }
        } else {
            hideStage = .visible
        }
    }

    private func beginAutoHide(for page: NowPlayingCarouselPage) {
        cancelHideSequence()
        let presentation = NowPlayingCarouselTopBarPolicy.hiddenPresentation(for: page)
        guard presentation.isHidden else { return }

        if !NowPlayingCarouselTopBarPolicy.usesBallTuckAnimation(for: presentation, reduceMotion: reduceMotion) {
            let fadeDuration = reduceMotion ? 0.24 : 0.45
            withAnimation(.easeInOut(duration: fadeDuration)) {
                switch presentation {
                case .visible:
                    hideStage = .visible
                case .fadedOnPlayer:
                    hideStage = .fadedOnPlayer
                case .tuckedToEdge(let edge):
                    hideStage = .tuckedOffEdge(edge: edge)
                }
            }
            return
        }

        guard case .tuckedToEdge(let edge) = presentation else { return }
        // 第一段：胶囊带弹性收拢为圆形玻璃球。
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            hideStage = .collapsedToBall(edge: edge)
        }
        // 第二段：短暂停顿后弹入侧边边缘并淡出。
        hideSequenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(NowPlayingCarouselTopBarPolicy.ballCollapseDuration))
            } catch {
                return
            }
            guard !Task.isCancelled, hideStage == .collapsedToBall(edge: edge) else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.80)) {
                hideStage = .tuckedOffEdge(edge: edge)
            }
        }
    }
}

/// 顶上的转盘定位与动效层：唯一逐帧读取 `state.offset` 的顶栏层。
/// 停在播放器上时整条居中、绕着把手；转到两侧的面时滑到起始侧，尾侧让给这一面的两颗键。
private struct NowPlayingCarouselTopBarDialLayer: View {
    let state: NowPlayingCarouselState
    let pages: [NowPlayingCarouselPage]
    let playerIndex: Int
    let settledIndex: Int
    let departingIndex: Int?
    let darkPageIndices: Set<Int>
    let appearance: NowPlayingAppearance
    let width: CGFloat
    let safeInsets: EdgeInsets
    let hideStage: NowPlayingCarouselTopBarPolicy.HideStage
    let reduceMotion: Bool
    let isRightToLeft: Bool
    let onSelect: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let position = NowPlayingCarouselPagingPolicy.dialPosition(
            settledIndex: settledIndex,
            offset: state.offset,
            departingIndex: departingIndex
        )
        let chrome = NowPlayingCarouselPolicy.dialChrome(position: position, playerIndex: playerIndex)
        let nearest = min(max(Int(position.rounded()), 0), max(pages.count - 1, 0))
        let isOverDarkPage = darkPageIndices.contains(nearest)
        let edge = NowPlayingCarouselDial.edgeInset + safeInsets.leading
        let spread = CGFloat(chrome)
        let isBallCollapsed: Bool = {
            guard !reduceMotion else { return false }
            switch hideStage {
            case .collapsedToBall, .tuckedOffEdge:
                return true
            case .visible, .fadedOnPlayer:
                return false
            }
        }()
        let tuckX: CGFloat = {
            guard !reduceMotion, case .tuckedOffEdge(let side) = hideStage else { return 0 }
            return CGFloat(NowPlayingCarouselTopBarPolicy.tuckOffsetX(
                edge: side,
                barLeadingInset: Double(edge),
                ballDiameter: Double(NowPlayingCarouselDial.rowHeight),
                isRightToLeft: isRightToLeft
            ))
        }()
        let scale: CGFloat = {
            guard !reduceMotion else { return 1 }
            switch hideStage {
            case .visible: return 1
            case .fadedOnPlayer: return 0.88
            case .collapsedToBall: return 0.96
            case .tuckedOffEdge: return 0.45
            }
        }()
        let opacity: Double = {
            switch hideStage {
            case .visible, .collapsedToBall: return 1
            case .fadedOnPlayer, .tuckedOffEdge: return 0
            }
        }()
        let playerCollapseLift: CGFloat = (!reduceMotion && hideStage == .fadedOnPlayer) ? -2 : 0

        NowPlayingCarouselDial(
            pages: pages,
            position: position,
            chrome: chrome,
            appearance: isOverDarkPage ? NowPlayingAppearance(colorScheme: .dark, contrast: .standard) : appearance,
            isCollapsedToBall: isBallCollapsed,
            onSelect: onSelect
        )
        .environment(\.colorScheme, isOverDarkPage ? .dark : colorScheme)
        .scaleEffect(scale, anchor: .center)
        .opacity(opacity)
        // 按转盘自己的宽度在居中与靠起始侧之间插值：对齐线当场量，不经过一次状态回写再排一遍。
        .alignmentGuide(.leading) { dimensions in
            let centered = max((width - dimensions.width) / 2, 0)
            return -(centered + (edge - centered) * spread)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, safeInsets.top + NowPlayingCarouselDial.topInset)
        // 停在播放器上时整条收矮、往上挪，图标与把手中心对齐，整条的下沿在封面上沿之上。
        .offset(x: tuckX, y: -NowPlayingCarouselDial.restingLift * (1 - spread) + playerCollapseLift)
    }
}

/// 一排小图标，当前页放大、亮起，跟着转轮连续过渡；点一下转到那一页。停在两侧的面上时，那一面的图标
/// 换成它的名字（转到一半时图标淡出、名字淡入，格子跟着撑开），这一面就不用再另起一行写标题。
///
/// `chrome` 为 0 时（停在播放器上）只剩两边几个淡淡的小图标，中间空出播放器的把手；离开播放器
/// 逐渐长成整条胶囊。自动隐藏第一阶段 `isCollapsedToBall` 为真时收拢为圆形玻璃球，仅居中保留当前面图标。
struct NowPlayingCarouselDial: View {
    let pages: [NowPlayingCarouselPage]
    let position: Double
    let chrome: Double
    let appearance: NowPlayingAppearance
    var isCollapsedToBall = false
    let onSelect: (Int) -> Void

    /// 各面名字写出来有多宽（按下标），量好以前按图标格算。
    @State private var titleWidths: [Int: CGFloat] = [:]

    /// 整条离安全区上沿多远。两侧面右上角那两颗键和它对齐。
    static let topInset: CGFloat = 4
    /// 转到两侧的面时整条靠起始侧，离屏幕边多远；尾侧那两颗键离尾侧也是这么多。
    static let edgeInset: CGFloat = 16
    /// 停在播放器上时中间让出的宽度：把手 48 点，两边各留一点空。
    private static let grabberGap: CGFloat = 64
    /// 一格的高度：长全时 28 点；停在播放器上时只有 18 点，整条的下沿不碰封面上沿。
    private static let fullSlotHeight: CGFloat = 28
    private static let restingSlotHeight: CGFloat = 18
    private static let fullVerticalPadding: CGFloat = 3
    /// 长全时整条的高度，也是收拢成圆球时的直径。两侧面右上角的两颗键也是这么高。
    static let rowHeight: CGFloat = fullSlotHeight + fullVerticalPadding * 2
    /// 名字两边留的空。
    private static let titlePadding: CGFloat = 12
    private static let titleFont = Font.system(size: 13, weight: .semibold, design: .rounded)
    /// 图标最大时（当前页、整条长全）的字号；其余时候按比例缩小。
    private static let iconMaximumSize: CGFloat = 15
    /// 停在播放器上时整条往上挪多少：收矮后图标中心挪到把手中心（安全区下 8.5 点）。
    static let restingLift: CGFloat = topInset + restingSlotHeight / 2 - 8.5

    var body: some View {
        let activeIndex = min(max(Int(position.rounded()), 0), max(pages.count - 1, 0))
        let slotHeight = Self.restingSlotHeight + (Self.fullSlotHeight - Self.restingSlotHeight) * chrome

        HStack(spacing: isCollapsedToBall ? 0 : 4) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                let isSelected = index == activeIndex
                let emphasis = max(0, 1 - abs(Double(index) - position))
                let reveal = isCollapsedToBall ? 0 : titleReveal(page: page, emphasis: emphasis)
                let width: CGFloat = {
                    if isCollapsedToBall {
                        return isSelected ? Self.fullSlotHeight : 0
                    }
                    return slotWidth(page: page, index: index, emphasis: emphasis, reveal: reveal)
                }()
                let itemOpacity: Double = isCollapsedToBall ? (isSelected ? 1 : 0) : 1

                Button { onSelect(index) } label: {
                    ZStack {
                        // 字号固定，大小靠缩放：逐帧改字号每帧都要重新排、重新画这几个符号，缩放只改图层变换。
                        Image(systemName: page.panel?.symbolName ?? "music.note")
                            .font(.system(size: Self.iconMaximumSize, weight: .semibold))
                            .scaleEffect(
                                isCollapsedToBall && isSelected
                                    ? 1.0
                                    : CGFloat(11 + 4 * emphasis * chrome) / Self.iconMaximumSize
                            )
                            .opacity(1 - reveal)
                        if let panel = page.panel {
                            Text(panel.titleKey)
                                .font(Self.titleFont)
                                .lineLimit(1)
                                .fixedSize()
                                .opacity(reveal)
                        }
                    }
                    .foregroundStyle(
                        appearance.primary.opacity(
                            isCollapsedToBall && isSelected ? 1 : iconOpacity(page: page, emphasis: emphasis)
                        )
                    )
                    .frame(width: width, height: slotHeight)
                    .clipped()
                    .background {
                        Capsule()
                            .fill(appearance.primary.opacity(isCollapsedToBall ? 0 : 0.16 * emphasis * chrome))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(itemOpacity)
                .accessibilityLabel(Text(page.panel?.titleKey ?? "player_carousel_player"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, isCollapsedToBall ? Self.fullVerticalPadding : 5)
        .padding(.vertical, Self.fullVerticalPadding * chrome)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(appearance.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .opacity(isCollapsedToBall ? max(chrome, 1) : chrome)
        }
        .background { titleMeasurements }
    }

    /// 各面的名字量一遍宽度，不画出来。
    private var titleMeasurements: some View {
        ZStack {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                if let panel = page.panel {
                    Text(panel.titleKey)
                        .font(Self.titleFont)
                        .lineLimit(1)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            if titleWidths[index] != width { titleWidths[index] = width }
                        }
                }
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// 名字露出来多少：离这一面不到半格才开始换，停稳时全是名字；停在播放器上（`chrome` 为 0）时不换。
    private func titleReveal(page: NowPlayingCarouselPage, emphasis: Double) -> Double {
        guard page.panel != nil else { return 0 }
        let t = min(max((emphasis - 0.5) * 2, 0), 1)
        return t * t * (3 - 2 * t) * chrome
    }

    private func iconOpacity(page: NowPlayingCarouselPage, emphasis: Double) -> Double {
        if page == .player { return (0.45 + 0.55 * emphasis) * chrome }
        let full = 0.45 + 0.55 * emphasis
        return 0.34 + (full - 0.34) * chrome
    }

    private func slotWidth(page: NowPlayingCarouselPage, index: Int, emphasis: Double, reveal: Double) -> CGFloat {
        let full = 26 + 10 * emphasis
        guard page == .player else {
            let iconWidth = 22 + (full - 22) * chrome
            let titleWidth = titleWidths[index].map { $0 + Self.titlePadding * 2 } ?? iconWidth
            return iconWidth + (max(titleWidth, iconWidth) - iconWidth) * reveal
        }
        return Self.grabberGap + (full - Self.grabberGap) * chrome
    }
}

/// 转轮顶栏的空闲计时器与无侵入触摸观察。不可观察，触摸时不引起任何 SwiftUI 视图重绘。
@MainActor
private final class NowPlayingCarouselTopBarIdleClock {
    private(set) var lastActivityAt = ProcessInfo.processInfo.systemUptime
    private(set) var isTouching = false
    var onTouchActivity: (@MainActor () -> Void)?
    private var touchObservers: [NowPlayingCarouselTopBarTouchObserver] = []

    var idleSeconds: TimeInterval {
        ProcessInfo.processInfo.systemUptime - lastActivityAt
    }

    func noteActivity() {
        lastActivityAt = ProcessInfo.processInfo.systemUptime
    }

    private func setTouching(_ touching: Bool) {
        isTouching = touching
        noteActivity()
        if touching {
            onTouchActivity?()
        }
    }

    func setObservesTouches(_ observes: Bool) {
        if observes {
            guard touchObservers.isEmpty else { return }
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                      windowScene.session.role == .windowApplication else { continue }
                for window in windowScene.windows {
                    let observer = NowPlayingCarouselTopBarTouchObserver(target: nil, action: nil)
                    observer.cancelsTouchesInView = false
                    observer.delaysTouchesBegan = false
                    observer.delaysTouchesEnded = false
                    observer.requiresExclusiveTouchType = false
                    observer.onTouchesChanged = { [weak self] touching in
                        self?.setTouching(touching)
                    }
                    window.addGestureRecognizer(observer)
                    touchObservers.append(observer)
                }
            }
        } else {
            for observer in touchObservers {
                observer.view?.removeGestureRecognizer(observer)
            }
            touchObservers = []
            isTouching = false
        }
    }
}

/// 只看不抢的触摸观察器：不拦、不延后任何触摸，也不与其它手势互斥。
private final class NowPlayingCarouselTopBarTouchObserver: UIGestureRecognizer {
    var onTouchesChanged: (@MainActor (Bool) -> Void)?
    private var activeTouches = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        activeTouches += touches.count
        onTouchesChanged?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(touches)
    }

    override func reset() {
        super.reset()
        if activeTouches > 0 {
            activeTouches = 0
            onTouchesChanged?(false)
        }
    }

    private func finish(_ touches: Set<UITouch>) {
        activeTouches = max(0, activeTouches - touches.count)
        guard activeTouches == 0 else { return }
        onTouchesChanged?(false)
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
