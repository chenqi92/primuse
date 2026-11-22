import Foundation
import PrimuseKit
import SwiftUI

// 全屏「封面流」(#191)的唱片架：画面零件与三端共用的浏览状态。几何与规则在
// `AlbumFlowLayoutPolicy` / `AlbumFlowBrowsePolicy`，舞台在 `ImmersiveStageView.albumFlowScene`，
// 手势、方向键、遥控器由各端全屏页接进 `ImmersiveAlbumFlowBrowser`。

/// 封面流里一张唱片书脊上写什么、涂什么颜色，由平台容器按播放队列给。
struct ImmersiveAlbumFlowCardInfo {
    let title: String
    /// 这首歌自己封面的取色；还没取到时为 nil，书脊先用专辑色。
    let tint: Color?
}

/// 封面流舞台上那行小提示：停在别的唱片上时说一声怎么选，排到下一首之后说一声排好了。
enum ImmersiveAlbumFlowHint: Equatable {
    /// 手机：轻点播放 · 上拉排到下一首。
    case tapOrSwipeUp
    /// Mac：点按播放。
    case click
    /// 电视：按确认键播放。
    case select
    /// 已设为下一首播放。
    case queuedNext

    struct Item: Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol }
    }

    var items: [Item] {
        switch self {
        case .tapOrSwipeUp:
            [
                Item(symbol: "hand.tap", text: String(localized: "immersive_flow_hint_tap_play")),
                Item(symbol: "arrow.up", text: String(localized: "immersive_flow_hint_swipe_up_next")),
            ]
        case .click:
            [Item(symbol: "cursorarrow.click", text: String(localized: "immersive_flow_hint_click_play"))]
        case .select:
            [Item(symbol: "play.circle", text: String(localized: "immersive_flow_hint_select_play"))]
        case .queuedNext:
            [Item(symbol: "text.line.first.and.arrowtriangle.forward", text: String(localized: "apple_music_queued_next"))]
        }
    }
}

// MARK: - 浏览状态

/// 封面流的浏览状态，三端的全屏页各持一份：左右拨动只是浏览，停住的那张抽出来，选它才换歌；
/// 三秒没动静就自己回到正在播的那张。舞台只读 `position` / `settle` / `queueLift` / `hint` 这几个值。
@MainActor
@Observable
final class ImmersiveAlbumFlowBrowser {
    /// 浏览到哪：0 是正在播的这张，k 是往右第 k 张（负数往左）；拖动途中是小数。
    private(set) var position: Double = 0
    /// 架子张开多少：1 是停住（停住的那张整个抽出来），0 是拖动中（架子合拢，路过的只稍稍抽出一点）。
    private(set) var settle: Double = 1
    /// 上拉排到下一首时，抽出的那张跟着手往上抬了多少点。
    private(set) var queueLift: Double = 0
    /// 舞台上那行小提示；nil 不显示。
    private(set) var hint: ImmersiveAlbumFlowHint? = nil

    /// 停在哪一张（整数格）。
    var browseIndex: Int { Int(position.rounded()) }
    /// 停在别的唱片上（不是正在播的这张）。
    var isBrowsing: Bool { browseIndex != 0 }

    /// 停住时提示怎么选：各端的说法不同（轻点 / 点按 / 按确认键）。
    @ObservationIgnored var browseHint: ImmersiveAlbumFlowHint
    /// 减弱动态效果：直接到位，不带动画。
    @ObservationIgnored var reduceMotion = false
    /// 手指（或触控板）正按着拖。
    @ObservationIgnored private(set) var isTracking = false
    /// 浏览中的那张的队列身份：换歌、队列变了时据此找回它的新位置。nil 是跟着正在播的这张。
    @ObservationIgnored private var browsedItemID: String? = nil
    @ObservationIgnored private var dragAnchor: Double = 0
    @ObservationIgnored private var dragStartSettle: Double = 1
    @ObservationIgnored private var lastDetent = 0
    @ObservationIgnored private var lastInteraction: TimeInterval = 0
    /// 这一趟浏览（离开正在播的这张到回来）里提示过怎么选没有：只提示一次，不每停一张都冒出来。
    @ObservationIgnored private var hasShownBrowseHint = false
    @ObservationIgnored private var motionTask: Task<Void, Never>? = nil
    @ObservationIgnored private var returnTask: Task<Void, Never>? = nil
    @ObservationIgnored private var hintTask: Task<Void, Never>? = nil

    init(browseHint: ImmersiveAlbumFlowHint) {
        self.browseHint = browseHint
    }

    // MARK: 拖动（手指、触控板）

    /// 起手：接下来书脊跟着手走，抽出的那张随着手一动插回去、架子合拢。
    func beginDrag() {
        motionTask?.cancel()
        returnTask?.cancel()
        isTracking = true
        dragAnchor = position
        dragStartSettle = settle
        lastDetent = browseIndex
        noteInteraction()
        clearBrowseHint()
    }

    /// 拖到 `translation` 点。
    /// - Returns: 这一下拖过了一张（给一下轻触感）。
    @discardableResult
    func updateDrag(translation: Double, layout: AlbumFlowLayoutPolicy.Layout, before: Int, after: Int) -> Bool {
        guard isTracking else { return false }
        noteInteraction()
        position = layout.browsePosition(from: dragAnchor, translation: translation, before: before, after: after)
        // 插回去跟着手走，不另起动画：位置和架子张开是同一份动画数据，一个带动画一个不带会互相打断。
        settle = AlbumFlowBrowsePolicy.dragSettle(from: dragStartSettle, travelled: abs(position - dragAnchor))
        let detent = AlbumFlowBrowsePolicy.detent(at: position, before: before, after: after)
        guard detent != lastDetent else { return false }
        lastDetent = detent
        return true
    }

    /// 松手：按势头吸附到最近的一张，把它抽出来。
    func endDrag(predictedTranslation: Double, layout: AlbumFlowLayoutPolicy.Layout, neighbors: AlbumFlowNeighbors) {
        guard isTracking else { return }
        isTracking = false
        let before = neighbors.before.count
        let after = neighbors.after.count
        let predicted = layout.browsePosition(
            from: dragAnchor,
            translation: predictedTranslation,
            before: before,
            after: after
        )
        let target = AlbumFlowBrowsePolicy.releaseTarget(
            position: position,
            predictedPosition: predicted,
            before: before,
            after: after
        )
        move(to: target, itemID: neighbors.itemID(at: target))
    }

    /// 拖动被系统接走（没有结束回调）：就近停下。
    func cancelDrag(neighbors: AlbumFlowNeighbors) {
        guard isTracking else { return }
        isTracking = false
        let target = AlbumFlowBrowsePolicy.detent(
            at: position,
            before: neighbors.before.count,
            after: neighbors.after.count
        )
        move(to: target, itemID: neighbors.itemID(at: target))
    }

    // MARK: 方向键、遥控器、点书脊

    /// 往一边挪一张。到头时不动，返回 false。
    @discardableResult
    func step(by delta: Int, neighbors: AlbumFlowNeighbors) -> Bool {
        noteInteraction()
        guard !isTracking else { return false }
        let target = AlbumFlowBrowsePolicy.step(
            from: browseIndex,
            by: delta,
            before: neighbors.before.count,
            after: neighbors.after.count
        )
        guard target != browseIndex else { return false }
        move(to: target, itemID: neighbors.itemID(at: target))
        return true
    }

    /// 点中一张书脊：把它抽出来（不换歌）。
    func select(_ offset: Int, neighbors: AlbumFlowNeighbors) {
        noteInteraction()
        let target = AlbumFlowBrowsePolicy.step(
            from: offset,
            by: 0,
            before: neighbors.before.count,
            after: neighbors.after.count
        )
        guard !isTracking, target != browseIndex else { return }
        move(to: target, itemID: neighbors.itemID(at: target))
    }

    /// 选中浏览中的那张去播放：返回沿播放顺序要跳几首；没在浏览时为 nil。
    /// 那张先停在原处，换歌落地时由 `reconcile` 接成正在播的这张；没换成就调 `returnToPlaying`。
    func commitBrowsedCard() -> Int? {
        guard isBrowsing, !isTracking else { return nil }
        returnTask?.cancel()
        clearBrowseHint()
        return browseIndex
    }

    /// 回到正在播的那张。
    func returnToPlaying() {
        guard !isTracking else { return }
        guard position != 0 || settle != 1 || browsedItemID != nil else { return }
        move(to: 0, itemID: nil)
    }

    /// 别的操作（点舞台、动控件）也算有人在看：回位的三秒从现在重新算。
    func noteInteraction() {
        lastInteraction = ProcessInfo.processInfo.systemUptime
    }

    // MARK: 上拉排到下一首（手机）

    func updateQueueLift(translation: Double, centerSide: Double) {
        noteInteraction()
        queueLift = AlbumFlowBrowsePolicy.queueLiftOffset(translation: translation, centerSide: centerSide)
    }

    /// 松手：抽出的那张落回原处。
    /// - Returns: 该不该排到下一首。
    func endQueueLift(translation: Double, predictedTranslation: Double, centerSide: Double) -> Bool {
        noteInteraction()
        animate(.spring(response: 0.36, dampingFraction: 0.8)) { queueLift = 0 }
        return AlbumFlowBrowsePolicy.queueLiftCommits(
            translation: translation,
            predictedTranslation: predictedTranslation,
            centerSide: centerSide
        )
    }

    /// 排到下一首之后：回到正在播的那张，说一声排好了。
    func didQueueNext() {
        returnToPlaying()
        show(.queuedNext, for: AlbumFlowBrowsePolicy.confirmationDuration)
    }

    // MARK: 队列变化

    /// 队列变了（换歌、加歌、调序）：浏览中的那张按身份找回新位置，画面不跳；
    /// 找不到了，或者换歌后正在播的就是它，回到正在播的这张。
    func reconcile(with neighbors: AlbumFlowNeighbors) {
        let before = neighbors.before.count
        let after = neighbors.after.count
        if isTracking {
            // 拖动途中：手下照旧跟着手走，只是不出两头。
            let clamped = min(max(position, -Double(before)), Double(after))
            dragAnchor += clamped - position
            position = clamped
            return
        }
        motionTask?.cancel()
        let target = browsedItemID.flatMap { neighbors.offset(ofItemID: $0) } ?? 0
        if target == 0 {
            browsedItemID = nil
            hasShownBrowseHint = false
            returnTask?.cancel()
            clearBrowseHint()
        }
        position = Double(target)
        settle = 1
    }

    /// 全屏页收起、换了别的效果：一切归位，不带动画。
    func reset() {
        motionTask?.cancel()
        returnTask?.cancel()
        hintTask?.cancel()
        isTracking = false
        browsedItemID = nil
        hasShownBrowseHint = false
        position = 0
        settle = 1
        queueLift = 0
        hint = nil
    }

    // MARK: 动起来

    /// 挪到第 `target` 张：只差一张时位置与抽出一起动；差得远时先插回、合拢，整排滑过去，再抽出来。
    private func move(to target: Int, itemID: String?) {
        motionTask?.cancel()
        browsedItemID = target == 0 ? nil : itemID
        let destination = Double(target)
        let motion = AlbumFlowBrowsePolicy.motion(distance: abs(destination - position), reduceMotion: reduceMotion)
        if motion.collapse == 0 && motion.expand == 0 {
            animate(.smooth(duration: max(motion.travel, 0.3))) {
                position = destination
                settle = 1
            }
        } else {
            let collapses = settle > 0.01
            if collapses {
                animate(.easeIn(duration: motion.collapse)) { settle = 0 }
            }
            // 每一段只动一样（先架子、再位置、再架子），一段走完才起下一段：两样是同一份动画数据，
            // 叠在一起起动画会互相打断。
            motionTask = Task { @MainActor [weak self] in
                if collapses {
                    try? await Task.sleep(for: .seconds(motion.collapse))
                }
                guard !Task.isCancelled, let self else { return }
                self.animate(.smooth(duration: motion.travel)) { self.position = destination }
                try? await Task.sleep(for: .seconds(motion.travel))
                guard !Task.isCancelled else { return }
                self.animate(.smooth(duration: motion.expand)) { self.settle = 1 }
            }
        }
        landed(on: target)
    }

    private func landed(on target: Int) {
        returnTask?.cancel()
        guard target != 0 else {
            hasShownBrowseHint = false
            clearBrowseHint()
            return
        }
        if !hasShownBrowseHint {
            hasShownBrowseHint = true
            show(browseHint, for: AlbumFlowBrowsePolicy.hintDuration)
        }
        scheduleReturn()
    }

    private func scheduleReturn() {
        returnTask?.cancel()
        returnTask = Task { @MainActor [weak self] in
            while let wait = self?.nextReturnCheck() {
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
            }
        }
    }

    /// 到点就回到正在播的那张并返回 nil；还没到点返回还要等几秒。
    private func nextReturnCheck() -> Double? {
        guard isBrowsing || browsedItemID != nil else { return nil }
        let idle = ProcessInfo.processInfo.systemUptime - lastInteraction
        if AlbumFlowBrowsePolicy.shouldReturnToPlaying(
            browseIndex: browseIndex,
            isInteracting: isTracking || queueLift != 0,
            idle: idle
        ) {
            returnToPlaying()
            return nil
        }
        return max(AlbumFlowBrowsePolicy.idleReturnDelay - idle, 0.25)
    }

    private func show(_ value: ImmersiveAlbumFlowHint, for duration: Double) {
        hintTask?.cancel()
        animate(.easeOut(duration: 0.22)) { hint = value }
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.hint == value else { return }
            self.animate(.easeOut(duration: 0.3)) { self.hint = nil }
        }
    }

    /// 收起「怎么选」那行提示；「排好了」照常露完。
    private func clearBrowseHint() {
        guard let hint, hint != .queuedNext else { return }
        hintTask?.cancel()
        animate(.easeOut(duration: 0.2)) { self.hint = nil }
    }

    private func animate(_ animation: Animation, _ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : animation, changes)
    }
}

// MARK: - 画面零件

/// 封面流里的一张唱片：插在架子里时只露书脊，抽出来时抬高、放大，正面从书脊那一条往两边展开
/// （不是绕竖轴转过来）。位置与架子张开的程度一帧帧插值，路过中间时那一下抽出、插回也跟着动画走；
/// 封面、书脊这些子视图不随拖动重建，只改变换与透明度。
struct ImmersiveAlbumFlowRackCard: View, Animatable {
    let layout: AlbumFlowLayoutPolicy.Layout
    /// 离浏览中心几格，负数在左。
    var position: Double
    var settle: Double
    let cornerRadius: CGFloat
    let spine: ImmersiveAlbumFlowSpine
    /// 这一张的静态封面，按抽出来的边长取图；滑进滑出都是同一张图，不重新取。
    let cover: AnyView
    /// 正在播的那张叠在上面的成品卡片（动态封面、玻璃描边、专辑色投影）；别的为 nil。
    let hero: AnyView?

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(position, settle) }
        set {
            position = newValue.first
            settle = newValue.second
        }
    }

    var body: some View {
        let placement = layout.placement(at: position, settle: settle)
        let base = CGFloat(max(layout.centerSide, 1))
        let spineShare = CGFloat(layout.spineFaceShare)
        let reveal = spineShare + (1 - spineShare) * CGFloat(placement.faceReveal)
        ZStack {
            cover
                .frame(width: base, height: base)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .mask { Rectangle().scaleEffect(x: reveal, y: 1) }
                .opacity(placement.faceOpacity)
            if let hero {
                hero
                    .frame(width: base, height: base)
                    .opacity(placement.heroOpacity)
                    .transition(.opacity)
            }
            spine
                .overlay {
                    RoundedRectangle(cornerRadius: spine.cornerRadius, style: .continuous)
                        .fill(.black.opacity(placement.shade))
                }
                .opacity(placement.spineOpacity)
        }
        .frame(width: base, height: base)
        .scaleEffect(CGFloat(placement.scale), anchor: .bottom)
        .opacity(placement.opacity)
        .position(x: CGFloat(placement.midX), y: CGFloat(placement.bottomY) - base / 2)
        .accessibilityHidden(hero == nil)
    }
}

/// 竖插在架子里的唱片露出来的书脊：用这首歌自己的取色，带一点塑料盒的弧面高光，竖排印歌名。
/// 按抽出来的边长画（高度就是那张的边长），随整张一起缩放。
struct ImmersiveAlbumFlowSpine: View {
    let title: String
    let tint: Color
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat
    let cornerRadius: CGFloat
    /// 正在播的那张：书脊顶上一道亮线，浏览到别处时也找得到它在哪。
    let isPlaying: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(tint)
            .frame(width: width, height: height)
            .overlay {
                // 塑料盒的弧面：左边受光、右边背光，再压一点暗，白字才看得清。
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.24), location: 0),
                            .init(color: .white.opacity(0.04), location: 0.32),
                            .init(color: .black.opacity(0.16), location: 0.68),
                            .init(color: .black.opacity(0.40), location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
            .overlay(alignment: .leading) {
                // 盒子边上那道竖着的反光。
                Rectangle()
                    .fill(.white.opacity(0.32))
                    .frame(width: max(width * 0.05, 1))
                    .padding(.leading, width * 0.18)
                    .padding(.vertical, height * 0.04)
            }
            .overlay { ImmersiveAlbumFlowSpineCaps(height: height) }
            .overlay {
                Text(verbatim: title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: height * 0.8, height: width)
                    .rotationEffect(.degrees(90))
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(isPlaying ? 0.95 : 0))
                    .frame(width: width * 0.34, height: max(height * 0.014, 2))
                    .shadow(color: .white.opacity(isPlaying ? 0.6 : 0), radius: 3)
                    .padding(.top, height * 0.065)
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 1) }
    }
}

/// 书脊上下两头的盒盖接缝。
private struct ImmersiveAlbumFlowSpineCaps: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black.opacity(0.22)).frame(height: max(height * 0.035, 1))
            Spacer(minLength: 0)
            Rectangle().fill(.black.opacity(0.22)).frame(height: max(height * 0.035, 1))
        }
    }
}

/// 正在播、没在浏览时，抽出的那张随音乐很轻地起伏：四五秒一个来回，只有一两点高。和台面的光一样
/// 只按时间走、不读频谱；暂停、省电、减弱动态效果时停在原处。
struct ImmersiveAlbumFlowBob: ViewModifier {
    @Environment(\.immersiveFrameRate) private var frameRate
    @Environment(\.immersiveMotionIntensity) private var motion
    let amplitude: CGFloat
    let isAnimating: Bool

    private static let period = 4.6

    func body(content: Content) -> some View {
        TimelineView(.animation(
            minimumInterval: frameRate.minimumInterval(base: 1.0 / 20, televisionFloor: 1.0 / 30),
            paused: !isAnimating
        )) { context in
            let time = context.date.timeIntervalSinceReferenceDate * motion.speed
            let wave = isAnimating ? sin(time / Self.period * 2 * .pi) * motion.amplitude : 0
            content.offset(y: CGFloat(wave) * amplitude)
        }
    }
}

/// 抽出那张在台面上的影子：架子张开时浓，合拢（拖动中）时淡掉。
struct ImmersiveAlbumFlowFloorShadow: View {
    let width: CGFloat

    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [.black.opacity(0.5), .black.opacity(0.18), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: width / 2
                )
            )
            .frame(width: width, height: width * 0.12)
            .allowsHitTesting(false)
    }
}

/// 舞台上那行小提示的样子：一枚半透明的胶囊，图标加一两句短话。
struct ImmersiveAlbumFlowHintView: View {
    let hint: ImmersiveAlbumFlowHint
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: fontSize * 1.1) {
            ForEach(hint.items) { item in
                Label {
                    Text(verbatim: item.text)
                } icon: {
                    Image(systemName: item.symbol)
                }
            }
        }
        .font(.system(size: fontSize, weight: .medium))
        .foregroundStyle(ImmersiveStagePalette.text.opacity(0.9))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, fontSize)
        .padding(.vertical, fontSize * 0.55)
        .background(.black.opacity(0.26), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
    }
}
