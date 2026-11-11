import PrimuseKit
import SwiftUI
#if os(iOS)
import QuartzCore
#endif

// MARK: - 面里的横向控件告诉转轮别翻页

private struct NowPlayingCarouselControlEditingKey: EnvironmentKey {
    static var defaultValue: (Bool) -> Void { { _ in } }
}

private struct NowPlayingCarouselGestureRegionsKey: EnvironmentKey {
    static let defaultValue: NowPlayingCarouselGestureRegions? = nil
}

extension EnvironmentValues {
    /// 嵌在播放页转轮里的横向滑杆、可拖的曲线按下 / 松开时调用,转轮在这期间不认横滑。
    /// 不在转轮里时是空操作(设置页、全屏卡拉 OK、macOS 都一样)。
    var nowPlayingCarouselControlEditing: (Bool) -> Void {
        get { self[NowPlayingCarouselControlEditingKey.self] }
        set { self[NowPlayingCarouselControlEditingKey.self] = newValue }
    }

    /// 转轮记下的「横向内容区」:从这些地方起手的横滑留给内容自己(横向滚动条、滑杆),不翻页。
    /// 不在转轮里时为 nil。
    var nowPlayingCarouselGestureRegions: NowPlayingCarouselGestureRegions? {
        get { self[NowPlayingCarouselGestureRegionsKey.self] }
        set { self[NowPlayingCarouselGestureRegionsKey.self] = newValue }
    }
}

/// 面里横向内容区在屏幕上的位置。拖动时逐帧都可能写(面在滚动),不可观察,只在手势起手时读一次。
@MainActor
final class NowPlayingCarouselGestureRegions {
    private var frames: [UUID: CGRect] = [:]

    func set(_ id: UUID, frame: CGRect) {
        frames[id] = frame
    }

    func remove(_ id: UUID) {
        frames[id] = nil
    }

    func contains(_ point: CGPoint) -> Bool {
        frames.values.contains { $0.contains(point) }
    }
}

private struct NowPlayingCarouselHorizontalRegion: ViewModifier {
    @Environment(\.nowPlayingCarouselGestureRegions) private var regions
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if let regions {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    regions.set(id, frame: frame)
                }
                .onDisappear { regions.remove(id) }
        } else {
            content
        }
    }
}

extension View {
    /// 横向滚动条、滑杆这类横向内容:在转轮里从这里起手的横滑不翻页。不在转轮里时什么也不做。
    func nowPlayingCarouselHorizontalRegion() -> some View {
        modifier(NowPlayingCarouselHorizontalRegion())
    }
}

// MARK: - 面与卡片的名字、图标

extension NowPlayingCarouselPanel {
    var titleKey: LocalizedStringKey {
        switch self {
        case .sound: "player_carousel_face_sound"
        case .explore: "player_carousel_face_explore"
        case .upNext: "player_carousel_face_up_next"
        case .stage: "player_carousel_face_stage"
        }
    }

    var localizedTitle: String {
        switch self {
        case .sound: String(localized: "player_carousel_face_sound")
        case .explore: String(localized: "player_carousel_face_explore")
        case .upNext: String(localized: "player_carousel_face_up_next")
        case .stage: String(localized: "player_carousel_face_stage")
        }
    }

    /// 一句话说这一面是干什么的(设置页副标题)。
    var summaryKey: LocalizedStringKey {
        switch self {
        case .sound: "player_carousel_face_sound_summary"
        case .explore: "player_carousel_face_explore_summary"
        case .upNext: "player_carousel_face_up_next_summary"
        case .stage: "player_carousel_face_stage_summary"
        }
    }

    var symbolName: String {
        switch self {
        case .sound: "slider.horizontal.3"
        case .explore: "sparkles"
        case .upNext: "list.bullet.indent"
        case .stage: "music.mic"
        }
    }

    /// 设置页图标底色、面里卡片图标与转动途中占位的主色。
    var tint: Color {
        switch self {
        case .sound: Color(red: 0.30, green: 0.52, blue: 1.0)
        case .explore: Color(red: 1.0, green: 0.60, blue: 0.20)
        case .upNext: Color(red: 0.20, green: 0.72, blue: 0.58)
        case .stage: Color(red: 1.0, green: 0.30, blue: 0.48)
        }
    }
}

extension NowPlayingCarouselCard {
    var titleKey: LocalizedStringKey {
        switch self {
        case .equalizer: "equalizer"
        case .audioEffects: "audio_effects"
        case .speedAndPitch: "player_carousel_card_speed_pitch"
        case .outputAndQuality: "player_carousel_card_output_quality"
        case .album: "player_carousel_card_album"
        case .artist: "player_carousel_card_artist"
        case .similarSongs: "similar_songs"
        case .playbackModes: "player_carousel_card_playback_modes"
        case .queue: "queue_title"
        case .karaoke: "karaoke_title"
        case .fullscreenEffects: "player_carousel_card_fullscreen_effects"
        }
    }

    var symbolName: String {
        switch self {
        case .equalizer: "slider.vertical.3"
        case .audioEffects: "waveform"
        case .speedAndPitch: "speedometer"
        case .outputAndQuality: "hifispeaker"
        case .album: "square.stack"
        case .artist: "music.mic"
        case .similarSongs: "sparkles"
        case .playbackModes: "repeat"
        case .queue: "list.bullet"
        case .karaoke: "music.mic.circle"
        case .fullscreenEffects: "viewfinder.rectangular"
        }
    }
}

#if os(iOS)

// MARK: - 状态

/// 转轮停在哪一面、拖到哪儿。播放页本体只读 `settledPage`(换页时才变),
/// 拖动中每一帧变的 `dragTranslation` 只有转轮自己读,整页播放器不跟着重算。
@MainActor
@Observable
final class NowPlayingCarouselState {
    private(set) var settledPage: NowPlayingCarouselPage = .player
    /// 手指横向拖了多少(已按书写方向换算成「往右为正」)。
    var dragTranslation: CGFloat = 0
    var isDragging = false
    /// 从舞台进卡拉 OK 全屏时,面里那一份先卸下(会话停掉),全屏那一份才挂上;全屏收起后再挂回来。
    var isKaraokeHandedOff = false
    /// 临时指定的全屏效果(从调音、接下来进全屏时)。只给这一次全屏用,不写回用户选定的效果。
    var fullscreenEffectOverride: FullscreenPlayerEffect?

    /// 转轮暂时不能转(转横屏、进全屏歌词)时停在的那一面;能转了再转回去。
    @ObservationIgnored private(set) var suspendedPage: NowPlayingCarouselPage?
    /// 从某一面进了原生全屏歌词:退出后收起歌词、回到那一面。
    @ObservationIgnored var restoresFaceAfterImmersiveLyrics = false
    /// 转横屏时从某一面进的全屏去了哪儿:转回竖屏时收起(卡拉 OK 全屏要另外收)。
    @ObservationIgnored var landscapeDestination: NowPlayingCarouselFullscreenDestination?
    /// 手势认方向的记录,拖动时每一帧都写,不可观察。
    @ObservationIgnored var gestureStart: CGPoint?
    @ObservationIgnored var gestureAxis: NowPlayingCarouselPolicy.Axis?
    @ObservationIgnored var gestureAllowed = false
    @ObservationIgnored var isControlEditing = false
    let gestureRegions = NowPlayingCarouselGestureRegions()
    /// 相似歌曲按种子歌缓存的结果:来回翻面不再整库重算、也不再问一遍 Last.fm。
    @ObservationIgnored var similarResults: [String: [MusicDiscoveryResult]] = [:]
    @ObservationIgnored var lastFmSimilar: [String: [Song]] = [:]

    var isAwayFromPlayer: Bool { settledPage != .player }

    /// 停着的那一面;转轮暂时不能转时是它停着的那一面。
    var currentOrSuspendedPage: NowPlayingCarouselPage {
        settledPage != .player ? settledPage : (suspendedPage ?? .player)
    }

    static let settleAnimation = Animation.spring(response: 0.52, dampingFraction: 0.86)

    func settle(on page: NowPlayingCarouselPage, animated: Bool = true) {
        let apply = {
            self.settledPage = page
            self.dragTranslation = 0
            self.isDragging = false
        }
        if animated {
            withAnimation(Self.settleAnimation, apply)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, apply)
        }
    }

    func returnToPlayer(animated: Bool = true) {
        guard settledPage != .player || isDragging || dragTranslation != 0 else { return }
        settle(on: .player, animated: animated)
    }

    /// 转轮暂时不能转:记下停着的那一面,先回到播放器。
    func suspend() {
        if settledPage != .player { suspendedPage = settledPage }
        returnToPlayer(animated: false)
    }

    /// 又能转了:回到暂停前那一面(那一面这时还在转轮里的话)。
    func resume(in pages: [NowPlayingCarouselPage]) {
        guard let page = suspendedPage else { return }
        suspendedPage = nil
        guard settledPage == .player, pages.contains(page) else { return }
        settle(on: page, animated: false)
    }

    /// 收进休眠:转回播放器,忘掉暂停时停着的那一面和临时的全屏去向。
    func reset() {
        suspendedPage = nil
        restoresFaceAfterImmersiveLyrics = false
        landscapeDestination = nil
        isKaraokeHandedOff = false
        fullscreenEffectOverride = nil
        returnToPlayer(animated: false)
    }

    func resetGesture() {
        gestureStart = nil
        gestureAxis = nil
        gestureAllowed = false
    }
}

/// 某一面现在的状态。卡拉 OK 这种一挂上就开始干活的只在 `.settled` 时才挂真身。
enum NowPlayingCarouselPanelPhase: Hashable {
    /// 正被拖着或转动途中露出来。
    case preview
    /// 停稳在这一面。
    case settled
}

/// 一面要画成什么样:阶段、要不要入场、此刻露不露在外面、放哪几张卡。
struct NowPlayingCarouselFaceContext: Hashable {
    var phase: NowPlayingCarouselPanelPhase
    /// 转轮已经认定停在这一面(松手那一刻起):卡片的错峰入场从这时开始,不等转动停稳。
    var isCommitted: Bool
    /// 播放页此刻露在外面(没收起、没被弹出页盖住):频谱这类持续干活的东西只在这时动。
    var isSurfaceExposed: Bool
    var cards: [NowPlayingCarouselCard]

    var isSettled: Bool { phase == .settled }
}

// MARK: - 容器

/// 播放页的转轮:播放器居中,两侧按设置排几面,左右滑动像转一个立方体一样转过去。
///
/// 播放器那一面始终挂着(身份不变,歌词 / 封面的转场照旧);两侧的面只在露出来的时候才挂上。
/// `isActive` 为 false 时(横屏、歌词、有声内容等)只画播放器,不认横滑,结构不变;停着的那一面先记下,
/// 能转了再转回去。
struct NowPlayingCarouselContainer<Center: View>: View {
    let isActive: Bool
    let configuration: NowPlayingCarouselConfiguration
    let cardSettings: NowPlayingCarouselCardSettings
    let cardContext: NowPlayingCarouselCardContext
    let state: NowPlayingCarouselState
    let size: CGSize
    let safeInsets: EdgeInsets
    let appearance: NowPlayingAppearance
    /// 播放页此刻露在外面:首次回弹提示只在这时做,面里的频谱也只在这时听。
    let isSurfaceExposed: Bool
    /// 卡拉 OK 全屏开着。收起时面里那一份挂回来。
    let isKaraokeCoverPresented: Bool
    /// 停在播放器上时,横滑只从这片区域起手才算(封面那一块;下面的进度条、音量条留给它们自己)。
    let playerSwipeRegion: (CGPoint) -> Bool
    let panel: (NowPlayingCarouselPanel, NowPlayingCarouselFaceContext) -> AnyView
    let center: Center

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isGestureActive = false
    @AppStorage(NowPlayingCarouselHintPolicy.shownStorageKey) private var hintShown = false

    init(
        isActive: Bool,
        configuration: NowPlayingCarouselConfiguration,
        cardSettings: NowPlayingCarouselCardSettings,
        cardContext: NowPlayingCarouselCardContext,
        state: NowPlayingCarouselState,
        size: CGSize,
        safeInsets: EdgeInsets,
        appearance: NowPlayingAppearance,
        isSurfaceExposed: Bool,
        isKaraokeCoverPresented: Bool,
        playerSwipeRegion: @escaping (CGPoint) -> Bool,
        panel: @escaping (NowPlayingCarouselPanel, NowPlayingCarouselFaceContext) -> AnyView,
        @ViewBuilder center: () -> Center
    ) {
        self.isActive = isActive
        self.configuration = configuration
        self.cardSettings = cardSettings
        self.cardContext = cardContext
        self.state = state
        self.size = size
        self.safeInsets = safeInsets
        self.appearance = appearance
        self.isSurfaceExposed = isSurfaceExposed
        self.isKaraokeCoverPresented = isKaraokeCoverPresented
        self.playerSwipeRegion = playerSwipeRegion
        self.panel = panel
        self.center = center()
    }

    /// 这一刻转得到的排布:当前这首一张卡都没有的面临时跳过。
    private var visibleConfiguration: NowPlayingCarouselConfiguration {
        configuration.skippingPanels { cardSettings.visibleCards(on: $0, in: cardContext).isEmpty }
    }

    private var direction: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }

    /// 页里的横向滑杆按下 / 松开。
    private var controlEditingHandler: (Bool) -> Void {
        { [state] editing in
            MainActor.assumeIsolated {
                state.isControlEditing = editing
                if editing, state.isDragging { state.settle(on: state.settledPage) }
            }
        }
    }

    var body: some View {
        let visible = visibleConfiguration
        let pages = visible.pages
        let playerIndex = visible.playerPageIndex
        let settledIndex = pages.firstIndex(of: state.settledPage) ?? playerIndex
        let position = isActive
            ? NowPlayingCarouselPolicy.position(
                current: settledIndex,
                translation: Double(state.dragTranslation),
                pageWidth: Double(size.width),
                pageCount: pages.count
            )
            : Double(playerIndex)

        NowPlayingCarouselStage(
            position: position,
            pages: pages,
            playerIndex: playerIndex,
            settledIndex: settledIndex,
            isActive: isActive,
            isDragging: state.isDragging,
            direction: Double(direction),
            safeInsets: safeInsets,
            appearance: appearance,
            isSurfaceExposed: isSurfaceExposed,
            cards: { cardSettings.visibleCards(on: $0, in: cardContext) },
            panel: panel,
            onSelect: { index in
                guard pages.indices.contains(index) else { return }
                state.settle(on: pages[index])
            },
            center: center
        )
        .contentShape(Rectangle())
        .simultaneousGesture(carouselDrag(pages: pages, settledIndex: settledIndex, playerIndex: playerIndex), including: isActive ? .all : .subviews)
        .environment(\.nowPlayingCarouselControlEditing, controlEditingHandler)
        .environment(\.nowPlayingCarouselGestureRegions, state.gestureRegions)
        .sensoryFeedback(.selection, trigger: state.settledPage)
        .onChange(of: isGestureActive) { _, active in
            // 手势被系统打断时没有 onEnded:弹回停着的那一页。
            guard !active else { return }
            state.resetGesture()
            if state.isDragging || state.dragTranslation != 0 {
                state.settle(on: state.settledPage)
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                state.resume(in: pages)
            } else {
                state.suspend()
            }
        }
        .onChange(of: pages) { _, newPages in
            if !newPages.contains(state.settledPage) { state.returnToPlayer(animated: false) }
        }
        .onChange(of: isKaraokeCoverPresented) { _, presented in
            if !presented { state.isKaraokeHandedOff = false }
        }
        .onAppear {
            // 全屏效果收起后普通播放页重新装上:临时指定的效果用完了,停着的那一面照旧在。
            state.fullscreenEffectOverride = nil
            if isActive { state.resume(in: pages) }
        }
        .task(id: hintTrigger) {
            await playHintIfNeeded(visible)
        }
        #if DEBUG
        .task {
            // 取证:`PRIMUSE_DEBUG_CAROUSEL_FACE=sound|explore|upNext|stage` 让播放页一出现就停在那一面。
            guard let name = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_CAROUSEL_FACE"],
                  let face = NowPlayingCarouselPanel(rawValue: name) else { return }
            try? await Task.sleep(for: .seconds(2))
            if pages.contains(.panel(face)) { state.settle(on: .panel(face)) }
        }
        #endif
    }

    private func carouselDrag(pages: [NowPlayingCarouselPage], settledIndex: Int, playerIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($isGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if state.gestureStart != value.startLocation {
                    state.gestureStart = value.startLocation
                    state.gestureAxis = nil
                    state.gestureAllowed = (settledIndex != playerIndex || playerSwipeRegion(value.startLocation))
                        && !state.gestureRegions.contains(value.startLocation)
                }
                guard state.gestureAllowed, !state.isControlEditing else { return }
                if state.gestureAxis == nil {
                    state.gestureAxis = NowPlayingCarouselPolicy.recognizedAxis(
                        translationX: Double(value.translation.width),
                        translationY: Double(value.translation.height)
                    )
                }
                guard state.gestureAxis == .horizontal else { return }
                if !state.isDragging { state.isDragging = true }
                state.dragTranslation = value.translation.width * direction
            }
            .onEnded { value in
                defer { state.resetGesture() }
                guard state.gestureAxis == .horizontal, state.isDragging else { return }
                let target = NowPlayingCarouselPolicy.settledIndex(
                    current: settledIndex,
                    translation: Double(value.translation.width * direction),
                    predictedEndTranslation: Double(value.predictedEndTranslation.width * direction),
                    pageWidth: Double(size.width),
                    pageCount: pages.count
                )
                state.settle(on: pages[target])
            }
    }

    // MARK: 首次回弹

    /// 打开转轮后第一次停在露出来的播放器上。
    private var hintTrigger: Bool {
        isActive && isSurfaceExposed && !hintShown && state.settledPage == .player
    }

    /// 轻轻往右边、再往左边各露一点,让人知道两边有东西。只做一次;减弱动态效果时不动,只记下做过了。
    private func playHintIfNeeded(_ visible: NowPlayingCarouselConfiguration) async {
        guard hintTrigger else { return }
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled, hintTrigger, !state.isDragging else { return }
        hintShown = true
        guard !reduceMotion else { return }
        let steps = NowPlayingCarouselHintPolicy.bounceSteps(
            hasLeading: !visible.leading.isEmpty,
            hasTrailing: !visible.trailing.isEmpty
        )
        for step in steps {
            guard !state.isDragging, state.settledPage == .player else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) {
                state.dragTranslation = CGFloat(step) * size.width
            }
            try? await Task.sleep(for: .milliseconds(step == 0 ? 0 : 420))
        }
    }
}

// MARK: - 舞台(逐帧)

/// 转轮的画面。`position` 是可动画的:换页时 SwiftUI 逐帧插值、逐帧重算哪几页露出来,
/// 一次跳好几页(点顶上的转盘)时中间的页也会依次转过,像真的转了一圈。
private struct NowPlayingCarouselStage<Center: View>: View, Animatable {
    var position: Double
    let pages: [NowPlayingCarouselPage]
    let playerIndex: Int
    let settledIndex: Int
    let isActive: Bool
    let isDragging: Bool
    let direction: Double
    let safeInsets: EdgeInsets
    let appearance: NowPlayingAppearance
    let isSurfaceExposed: Bool
    let cards: (NowPlayingCarouselPanel) -> [NowPlayingCarouselCard]
    let panel: (NowPlayingCarouselPanel, NowPlayingCarouselFaceContext) -> AnyView
    let onSelect: (Int) -> Void
    let center: Center

    nonisolated var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    private var isAtRest: Bool {
        !isDragging && abs(position - Double(settledIndex)) < 0.0005
    }

    var body: some View {
        let visible = isActive
            ? NowPlayingCarouselPolicy.visiblePageIndices(position: position, pageCount: pages.count)
            : playerIndex...playerIndex
        let centerProgress = isActive ? (Double(playerIndex) - position) * direction : 0

        ZStack {
            center
                .overlay { NowPlayingCarouselFaceShade(progress: centerProgress) }
                .modifier(NowPlayingCarouselFaceEffect(progress: centerProgress))
                .opacity(abs(centerProgress) >= 0.999 ? 0 : 1)
                .allowsHitTesting(!isActive || settledIndex == playerIndex)
                .accessibilityHidden(isActive && settledIndex != playerIndex)

            if isActive {
                ForEach(Array(visible), id: \.self) { index in
                    if let kind = pages[index].panel {
                        let progress = (Double(index) - position) * direction
                        let context = NowPlayingCarouselFaceContext(
                            phase: index == settledIndex && isAtRest ? .settled : .preview,
                            isCommitted: index == settledIndex,
                            isSurfaceExposed: isSurfaceExposed,
                            cards: cards(kind)
                        )
                        NowPlayingCarouselPanelSlot(
                            key: .init(panel: kind, context: context, isLight: appearance.isLight),
                            make: { panel(kind, context) }
                        )
                        .equatable()
                        .overlay { NowPlayingCarouselFaceShade(progress: progress) }
                        .modifier(NowPlayingCarouselFaceEffect(progress: progress))
                        .opacity(abs(progress) >= 0.999 ? 0 : 1)
                        .allowsHitTesting(index == settledIndex)
                        .accessibilityHidden(index != settledIndex)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if isActive, pages.count > 1 {
                let chrome = NowPlayingCarouselPolicy.dialChrome(position: position, playerIndex: playerIndex)
                NowPlayingCarouselDial(
                    pages: pages,
                    position: position,
                    chrome: chrome,
                    appearance: appearance,
                    onSelect: onSelect
                )
                .padding(.top, safeInsets.top + 4)
                // 停在播放器上时整条往上挪,图标排在把手两边。
                .offset(y: -12.5 * (1 - chrome))
                .opacity(dialOpacity)
                .allowsHitTesting(dialOpacity > 0.5)
            }
        }
    }

    /// 转动中总在;停在播放器上时淡淡地露在把手两边;停在整页自带顶栏的卡拉 OK 舞台上时让给它。
    private var dialOpacity: Double {
        if !isAtRest { return 1 }
        guard let kind = pages[settledIndex].panel else { return 1 }
        return kind == .stage && cards(kind).contains(.karaoke) ? 0 : 1
    }
}

/// 两侧的面按 (面, 状态, 深浅) 比较:拖动中逐帧重算舞台时,面里的内容不跟着每帧重算。
private struct NowPlayingCarouselPanelSlot: View, Equatable {
    struct Key: Equatable {
        let panel: NowPlayingCarouselPanel
        let context: NowPlayingCarouselFaceContext
        let isLight: Bool
    }

    let key: Key
    let make: () -> AnyView

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View { make() }
}

/// 立方体的一面:`progress` 为 0 时正对着人,±1 时转到侧面。右边那面以左边沿为轴、
/// 左边那面以右边沿为轴,透视中心在这一面的中心。动画由舞台逐帧驱动,这里自己不插值。
private struct NowPlayingCarouselFaceEffect: GeometryEffect {
    var progress: Double

    var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = CGFloat(min(max(progress, -1), 1))
        guard p != 0, size.width > 0, size.height > 0 else { return ProjectionTransform() }
        let width = size.width
        let height = size.height
        let hingeX: CGFloat = p > 0 ? 0 : width

        var transform = CATransform3DMakeTranslation(-hingeX, -height / 2, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(p * .pi / 2, 0, 1, 0))
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(hingeX + p * width, height / 2, 0))
        // 透视以这一面的中心为灭点,不然整面会往左上角歪。
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (max(width, height) * 1.5)
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(-width / 2, -height / 2, 0))
        transform = CATransform3DConcat(transform, perspective)
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(width / 2, height / 2, 0))
        return ProjectionTransform(transform)
    }
}

/// 转到侧面的那一面压暗一些,立体感靠它。
private struct NowPlayingCarouselFaceShade: View {
    let progress: Double

    var body: some View {
        let amount = min(abs(progress), 1)
        LinearGradient(
            colors: [Color.black.opacity(amount * 0.42), Color.black.opacity(amount * 0.22)],
            startPoint: progress > 0 ? .trailing : .leading,
            endPoint: progress > 0 ? .leading : .trailing
        )
        .opacity(amount > 0.001 ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 顶上的转盘

/// 一排小图标,当前页放大、亮起,跟着转轮连续过渡;点一下转到那一页。
///
/// `chrome` 为 0 时(停在播放器上)只剩两边几个淡淡的小图标,中间空出播放器的把手;离开播放器
/// 逐渐长成整条胶囊。
private struct NowPlayingCarouselDial: View {
    let pages: [NowPlayingCarouselPage]
    let position: Double
    let chrome: Double
    let appearance: NowPlayingAppearance
    let onSelect: (Int) -> Void

    /// 停在播放器上时中间让出的宽度:把手 48 点,两边各留一点空。
    private static let grabberGap: CGFloat = 64

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                let emphasis = max(0, 1 - abs(Double(index) - position))
                Button { onSelect(index) } label: {
                    Image(systemName: page.panel?.symbolName ?? "music.note")
                        .font(.system(size: 11 + 4 * emphasis * chrome, weight: .semibold))
                        .foregroundStyle(appearance.primary.opacity(iconOpacity(page: page, emphasis: emphasis)))
                        .frame(width: slotWidth(page: page, emphasis: emphasis), height: 28)
                        .background {
                            Capsule()
                                .fill(appearance.primary.opacity(0.16 * emphasis * chrome))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(page.panel?.titleKey ?? "player_carousel_player"))
                .accessibilityAddTraits(index == Int(position.rounded()) ? .isSelected : [])
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(appearance.primary.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .opacity(chrome)
        }
    }

    private func iconOpacity(page: NowPlayingCarouselPage, emphasis: Double) -> Double {
        if page == .player { return (0.45 + 0.55 * emphasis) * chrome }
        let full = 0.45 + 0.55 * emphasis
        return 0.34 + (full - 0.34) * chrome
    }

    private func slotWidth(page: NowPlayingCarouselPage, emphasis: Double) -> CGFloat {
        let full = 26 + 10 * emphasis
        guard page == .player else { return 22 + (full - 22) * chrome }
        return Self.grabberGap + (full - Self.grabberGap) * chrome
    }
}

// MARK: - 两侧普通面的外壳

/// 两侧普通面共用的外壳:顶上留出转盘,标题、进全屏与「回到播放器」,中间是内容,底下一条正在播放。
/// 双指张开也进全屏(去向由调用方按面定)。
struct NowPlayingCarouselPanelPage<Content: View>: View {
    let panel: NowPlayingCarouselPanel
    let side: NowPlayingCarouselConfiguration.Side
    let safeInsets: EdgeInsets
    let appearance: NowPlayingAppearance
    var showsNowPlayingStrip = true
    let onExpand: () -> Void
    let onReturnToPlayer: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, safeInsets.top + 46)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showsNowPlayingStrip {
                NowPlayingCarouselNowPlayingStrip(appearance: appearance, onTap: onReturnToPlayer)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, max(safeInsets.bottom, 12))
            }
        }
        .padding(.leading, safeInsets.leading)
        .padding(.trailing, safeInsets.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { NowPlayingCarouselFaceBackground(appearance: appearance) }
        .nowPlayingCarouselPinchToExpand(onExpand)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(panel.tint.gradient)
                Image(systemName: panel.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: panel.tint.opacity(0.35), radius: 8, y: 3)
            .accessibilityHidden(true)

            Text(panel.titleKey)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(appearance.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            NowPlayingCarouselHeaderButton(
                symbol: "arrow.up.left.and.arrow.down.right",
                label: "player_carousel_expand",
                appearance: appearance,
                action: onExpand
            )

            NowPlayingCarouselHeaderButton(
                symbol: side == .leading ? "chevron.forward" : "chevron.backward",
                label: "player_carousel_back",
                appearance: appearance,
                action: onReturnToPlayer
            )
        }
    }
}

/// 面标题栏右边的圆钮。
struct NowPlayingCarouselHeaderButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let appearance: NowPlayingAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(appearance.primary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(appearance.primary.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.pmPressable)
        .accessibilityLabel(Text(label))
    }
}

/// 底下的播放页背景(封面取色)是静止的;每一面盖一层半透明的玻璃,转起来能看出面的轮廓。
struct NowPlayingCarouselFaceBackground: View {
    let appearance: NowPlayingAppearance

    var body: some View {
        ZStack {
            (appearance.isLight ? Color.white.opacity(0.34) : Color.black.opacity(0.26))
            LinearGradient(
                colors: [appearance.primary.opacity(0.06), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 双指张开进全屏

private struct NowPlayingCarouselPinchToExpand: ViewModifier {
    let onExpand: () -> Void

    @Environment(\.nowPlayingCarouselControlEditing) private var reportsControlEditing
    @GestureState private var isPinching = false
    @State private var hasFired = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.02)
                    .updating($isPinching) { _, pinching, _ in pinching = true }
                    .onChanged { value in
                        guard !hasFired,
                              NowPlayingCarouselFullscreenPolicy.pinchCommits(magnification: Double(value.magnification))
                        else { return }
                        hasFired = true
                        onExpand()
                    }
            )
            // 两根手指按着的时候转轮不翻页;松开(或被系统打断)后再认横滑。
            .onChange(of: isPinching) { _, pinching in
                reportsControlEditing(pinching)
                if !pinching { hasFired = false }
            }
    }
}

extension View {
    /// 在转轮的面上双指张开过了门槛就进全屏,一次手势只进一次。
    func nowPlayingCarouselPinchToExpand(_ onExpand: @escaping () -> Void) -> some View {
        modifier(NowPlayingCarouselPinchToExpand(onExpand: onExpand))
    }
}

// MARK: - 卡片

/// 面里一张卡片的底:圆角玻璃、标题行(图标、名字、右侧附件)、内容。
struct NowPlayingCarouselCardContainer<Accessory: View, Content: View>: View {
    let card: NowPlayingCarouselCard
    let appearance: NowPlayingAppearance
    var subtitle: String? = nil
    var contentPadding = true
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: card.symbolName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(card.panel.tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.titleKey)
                        .font(.headline)
                        .foregroundStyle(appearance.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundStyle(appearance.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 16)

            content
                .padding(.horizontal, contentPadding ? 16 : 0)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(appearance.isLight ? Color.white.opacity(0.5) : Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(appearance.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}

extension NowPlayingCarouselCardContainer where Accessory == EmptyView {
    init(
        card: NowPlayingCarouselCard,
        appearance: NowPlayingAppearance,
        subtitle: String? = nil,
        contentPadding: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.card = card
        self.appearance = appearance
        self.subtitle = subtitle
        self.contentPadding = contentPadding
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// 落到一面时卡片一张接一张升上来;转动途中先压低一点、淡一点。减弱动态效果时不动。
private struct NowPlayingCarouselCardEntrance: ViewModifier {
    let index: Int
    let isCommitted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let lowered = !isCommitted && !reduceMotion
        content
            .offset(y: lowered ? 18 : 0)
            .opacity(lowered ? 0.6 : 1)
            .animation(
                PMMotion.list.resolved(reduceMotion: reduceMotion)?.delay(Double(min(index, 6)) * 0.05),
                value: isCommitted
            )
    }
}

extension View {
    func nowPlayingCarouselCardEntrance(index: Int, isCommitted: Bool) -> some View {
        modifier(NowPlayingCarouselCardEntrance(index: index, isCommitted: isCommitted))
    }
}

/// 一面里竖着排的几张卡片。
struct NowPlayingCarouselCardStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - 底下一条正在播放

/// 两侧页底部那一条:封面、歌名、播放 / 暂停、下一首,下沿一根细进度。点空白处回到播放器。
struct NowPlayingCarouselNowPlayingStrip: View {
    let appearance: NowPlayingAppearance
    let onTap: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        let song = player.currentSong
        HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song?.coverArtFileName,
                songID: song?.id ?? "",
                size: 44,
                cornerRadius: 9,
                sourceID: song?.sourceID,
                filePath: song?.filePath,
                fileFormat: song?.fileFormat,
                loadsHighResolution: false,
                revisionToken: player.coverRevision
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: song?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)
                Text(verbatim: song.flatMap { library.artistDisplayName(for: $0) } ?? song?.artistName ?? "")
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(appearance.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(player.isPlaying ? LocalizedStringKey("pause") : LocalizedStringKey("play")))

            Button {
                Task { await player.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(appearance.primary)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("next"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    NowPlayingCarouselStripProgress(appearance: appearance)
                        .padding(.horizontal, 18)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(appearance.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onTap)
    }
}

/// 进度单独一层:只有它跟着播放时间刷新。
private struct NowPlayingCarouselStripProgress: View {
    let appearance: NowPlayingAppearance
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let fraction = player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
        GeometryReader { geometry in
            Capsule()
                .fill(appearance.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(appearance.primary.opacity(0.7))
                        .frame(width: geometry.size.width * fraction)
                }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - 面里的小部件

struct NowPlayingCarouselSongRow: View {
    enum Leading {
        case artwork
        case trackNumber(Int)
    }

    let song: Song
    let detail: String?
    let leading: Leading
    let isCurrent: Bool
    let appearance: NowPlayingAppearance
    var horizontalPadding: CGFloat = 22
    var showsDuration = true

    @Environment(MusicLibrary.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            switch leading {
            case .artwork:
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 40,
                    cornerRadius: 8,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    loadsHighResolution: false
                )
                .frame(width: 40, height: 40)
            case .trackNumber(let number):
                Group {
                    if isCurrent {
                        Image(systemName: "waveform")
                            .font(.system(size: 13, weight: .bold))
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    } else {
                        Text(number, format: .number.grouping(.never))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                .foregroundStyle(isCurrent ? appearance.primary : appearance.tertiary)
                .frame(width: 26)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: song.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsDuration, song.duration > 0 {
                Text(Duration.seconds(song.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appearance.tertiary)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let artist = library.artistDisplayName(for: song) ?? song.artistName ?? ""
        guard let detail, !detail.isEmpty else { return artist }
        return artist.isEmpty ? detail : "\(artist) · \(detail)"
    }
}

struct NowPlayingCarouselRowButtonStyle: ButtonStyle {
    let appearance: NowPlayingAppearance
    var inset: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appearance.primary.opacity(configuration.isPressed ? 0.10 : 0))
                    .padding(.horizontal, inset)
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct NowPlayingCarouselCapsuleButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let isProminent: Bool
    var isBusy = false
    var isCompact = false
    let appearance: NowPlayingAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: isCompact ? 11 : 13, weight: .bold))
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font((isCompact ? Font.caption : Font.subheadline).weight(.semibold))
            .foregroundStyle(isProminent ? prominentInk : appearance.primary)
            .padding(.horizontal, isCompact ? 11 : 16)
            .padding(.vertical, isCompact ? 6 : 11)
            .frame(maxWidth: isCompact ? nil : .infinity)
            .background(
                Capsule().fill(isProminent ? appearance.primary : appearance.primary.opacity(0.12))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.pmPressable)
        .disabled(isBusy)
    }

    /// 实心钮上的字用底色的反色。
    private var prominentInk: Color {
        appearance.isLight ? .white : .black
    }
}

struct NowPlayingCarouselEmptyNote: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let appearance: NowPlayingAppearance

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(appearance.tertiary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.primary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(appearance.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }
}

/// 还没算好时的几行骨架。
struct NowPlayingCarouselLoadingRows: View {
    let appearance: NowPlayingAppearance
    var count = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().frame(width: CGFloat(150 - index * 9), height: 10)
                        Capsule().frame(width: CGFloat(96 + index * 7), height: 8)
                    }
                }
            }
        }
        .foregroundStyle(appearance.primary.opacity(0.08))
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

/// 卡片里一行「这里现在用不了」的说明,可带一颗解决的按钮。
struct NowPlayingCarouselCardNotice: View {
    let message: String
    var actionTitle: LocalizedStringKey? = nil
    let appearance: NowPlayingAppearance
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.secondary)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(appearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(appearance.primary.opacity(0.12)))
                }
                .buttonStyle(.pmPressable)
            }
        }
    }
}

#endif
