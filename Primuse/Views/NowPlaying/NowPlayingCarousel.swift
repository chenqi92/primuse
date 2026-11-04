import PrimuseKit
import SwiftUI
#if os(iOS)
import QuartzCore
#endif

// MARK: - 拖滑杆时告诉转轮别翻页

private struct NowPlayingCarouselControlEditingKey: EnvironmentKey {
    static var defaultValue: (Bool) -> Void { { _ in } }
}

extension EnvironmentValues {
    /// 嵌在播放页转轮里的横向滑杆按下 / 松开时调用,转轮在这期间不认横滑。
    /// 不在转轮里时是空操作(设置页、macOS 都一样)。
    var nowPlayingCarouselControlEditing: (Bool) -> Void {
        get { self[NowPlayingCarouselControlEditingKey.self] }
        set { self[NowPlayingCarouselControlEditingKey.self] = newValue }
    }
}

extension NowPlayingCarouselPanel {
    var titleKey: LocalizedStringKey {
        switch self {
        case .equalizer: "player_carousel_panel_equalizer"
        case .audioEffects: "player_carousel_panel_audio_effects"
        case .similarSongs: "player_carousel_panel_similar_songs"
        case .albumAndArtist: "player_carousel_panel_album_artist"
        case .queue: "player_carousel_panel_queue"
        case .karaoke: "player_carousel_panel_karaoke"
        }
    }

    var symbolName: String {
        switch self {
        case .equalizer: "slider.vertical.3"
        case .audioEffects: "waveform"
        case .similarSongs: "sparkles"
        case .albumAndArtist: "square.stack"
        case .queue: "list.bullet"
        case .karaoke: "music.mic"
        }
    }

    /// 设置页图标底色与转轮占位页的主色。
    var tint: Color {
        switch self {
        case .equalizer: Color(red: 0.25, green: 0.56, blue: 1.0)
        case .audioEffects: Color(red: 0.62, green: 0.38, blue: 0.98)
        case .similarSongs: Color(red: 1.0, green: 0.62, blue: 0.18)
        case .albumAndArtist: Color(red: 0.18, green: 0.74, blue: 0.56)
        case .queue: Color(red: 0.40, green: 0.48, blue: 0.62)
        case .karaoke: Color(red: 1.0, green: 0.30, blue: 0.48)
        }
    }
}

#if os(iOS)

// MARK: - 状态

/// 转轮停在哪一页、拖到哪儿。播放页本体只读 `settledPage`(换页时才变),
/// 拖动中每一帧变的 `dragTranslation` 只有转轮自己读,整页播放器不跟着重算。
@MainActor
@Observable
final class NowPlayingCarouselState {
    private(set) var settledPage: NowPlayingCarouselPage = .player
    /// 手指横向拖了多少(已按书写方向换算成「往右为正」)。
    var dragTranslation: CGFloat = 0
    var isDragging = false

    /// 手势认方向的记录,拖动时每一帧都写,不可观察。
    @ObservationIgnored var gestureStart: CGPoint?
    @ObservationIgnored var gestureAxis: NowPlayingCarouselPolicy.Axis?
    @ObservationIgnored var gestureAllowed = false
    @ObservationIgnored var isControlEditing = false
    /// 相似歌曲那一页按种子歌缓存的结果:来回翻页不再整库重算。
    @ObservationIgnored var similarResults: [String: [MusicDiscoveryResult]] = [:]

    var isAwayFromPlayer: Bool { settledPage != .player }

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

    func resetGesture() {
        gestureStart = nil
        gestureAxis = nil
        gestureAllowed = false
    }
}

// MARK: - 容器

/// 播放页的转轮:播放器居中,两侧按设置排几页,左右滑动像转一个立方体一样转过去。
///
/// 播放器那一面始终挂着(身份不变,歌词 / 封面的转场照旧);两侧的页只在露出来的时候才挂上。
/// `isActive` 为 false 时(横屏、歌词、有声内容等)只画播放器,不认横滑,结构不变。
struct NowPlayingCarouselContainer<Center: View>: View {
    let isActive: Bool
    let configuration: NowPlayingCarouselConfiguration
    let state: NowPlayingCarouselState
    let size: CGSize
    let safeInsets: EdgeInsets
    let appearance: NowPlayingAppearance
    /// 停在播放器上时,横滑只从这片区域起手才算(封面那一块;下面的进度条、音量条留给它们自己)。
    let playerSwipeRegion: (CGPoint) -> Bool
    let panel: (NowPlayingCarouselPanel, NowPlayingCarouselPanelPhase) -> AnyView
    let center: Center

    @Environment(\.layoutDirection) private var layoutDirection
    @GestureState private var isGestureActive = false

    init(
        isActive: Bool,
        configuration: NowPlayingCarouselConfiguration,
        state: NowPlayingCarouselState,
        size: CGSize,
        safeInsets: EdgeInsets,
        appearance: NowPlayingAppearance,
        playerSwipeRegion: @escaping (CGPoint) -> Bool,
        panel: @escaping (NowPlayingCarouselPanel, NowPlayingCarouselPanelPhase) -> AnyView,
        @ViewBuilder center: () -> Center
    ) {
        self.isActive = isActive
        self.configuration = configuration
        self.state = state
        self.size = size
        self.safeInsets = safeInsets
        self.appearance = appearance
        self.playerSwipeRegion = playerSwipeRegion
        self.panel = panel
        self.center = center()
    }

    private var pages: [NowPlayingCarouselPage] { configuration.pages }
    private var playerIndex: Int { configuration.playerPageIndex }
    private var settledIndex: Int { pages.firstIndex(of: state.settledPage) ?? playerIndex }
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
            panel: panel,
            onSelect: { index in
                guard pages.indices.contains(index) else { return }
                state.settle(on: pages[index])
            },
            center: center
        )
        .contentShape(Rectangle())
        .simultaneousGesture(carouselDrag, including: isActive ? .all : .subviews)
        .environment(\.nowPlayingCarouselControlEditing, controlEditingHandler)
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
            if !active { state.returnToPlayer(animated: false) }
        }
        .onChange(of: pages) { _, newPages in
            if !newPages.contains(state.settledPage) { state.returnToPlayer(animated: false) }
        }
    }

    private var carouselDrag: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($isGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if state.gestureStart != value.startLocation {
                    state.gestureStart = value.startLocation
                    state.gestureAxis = nil
                    state.gestureAllowed = settledIndex != playerIndex || playerSwipeRegion(value.startLocation)
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
}

/// 某一页现在的状态。卡拉 OK 这种一挂上就开始干活的页只在 `.settled` 时才挂真身。
enum NowPlayingCarouselPanelPhase: Hashable {
    /// 正被拖着或转动途中露出来。
    case preview
    /// 停稳在这一页。
    case settled
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
    let panel: (NowPlayingCarouselPanel, NowPlayingCarouselPanelPhase) -> AnyView
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
                        let phase: NowPlayingCarouselPanelPhase = index == settledIndex && isAtRest
                            ? .settled
                            : .preview
                        NowPlayingCarouselPanelSlot(
                            key: .init(panel: kind, phase: phase, isLight: appearance.isLight),
                            make: { panel(kind, phase) }
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
            if isActive {
                NowPlayingCarouselDial(
                    pages: pages,
                    position: position,
                    appearance: appearance,
                    onSelect: onSelect
                )
                .padding(.top, safeInsets.top + 4)
                .opacity(dialOpacity)
                .allowsHitTesting(dialOpacity > 0.5)
            }
        }
    }

    /// 转盘只在转动中、或停在两侧的普通页上时出现;停在播放器与卡拉 OK 上时让给它们自己的顶栏。
    private var dialOpacity: Double {
        if !isAtRest { return 1 }
        guard let kind = pages[settledIndex].panel else { return 0 }
        return kind == .karaoke ? 0 : 1
    }
}

/// 两侧的页按 (页, 阶段, 深浅) 比较:拖动中逐帧重算舞台时,页里的内容不跟着每帧重算。
private struct NowPlayingCarouselPanelSlot: View, Equatable {
    struct Key: Equatable, Sendable {
        let panel: NowPlayingCarouselPanel
        let phase: NowPlayingCarouselPanelPhase
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
private struct NowPlayingCarouselDial: View {
    let pages: [NowPlayingCarouselPage]
    let position: Double
    let appearance: NowPlayingAppearance
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                let emphasis = max(0, 1 - abs(Double(index) - position))
                Button { onSelect(index) } label: {
                    Image(systemName: symbol(for: page))
                        .font(.system(size: 12 + 3 * emphasis, weight: .semibold))
                        .foregroundStyle(appearance.primary.opacity(0.45 + 0.55 * emphasis))
                        .frame(width: 26 + 10 * emphasis, height: 28)
                        .background {
                            Capsule()
                                .fill(appearance.primary.opacity(0.16 * emphasis))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title(for: page)))
                .accessibilityAddTraits(index == Int(position.rounded()) ? .isSelected : [])
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(appearance.primary.opacity(0.10), lineWidth: 0.5))
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func symbol(for page: NowPlayingCarouselPage) -> String {
        page.panel?.symbolName ?? "music.note"
    }

    private func title(for page: NowPlayingCarouselPage) -> LocalizedStringKey {
        page.panel?.titleKey ?? "player_carousel_player"
    }
}

// MARK: - 两侧普通页的外壳

/// 两侧普通页共用的外壳:顶上留出转盘,标题与「回到播放器」,中间是内容,底下一条正在播放。
struct NowPlayingCarouselPanelPage<Content: View>: View {
    let panel: NowPlayingCarouselPanel
    let side: NowPlayingCarouselConfiguration.Side
    let safeInsets: EdgeInsets
    let appearance: NowPlayingAppearance
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

            NowPlayingCarouselNowPlayingStrip(appearance: appearance, onTap: onReturnToPlayer)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, max(safeInsets.bottom, 12))
        }
        .padding(.leading, safeInsets.leading)
        .padding(.trailing, safeInsets.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { faceBackground }
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

            Text(panel.titleKey)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(appearance.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 8)

            Button(action: onReturnToPlayer) {
                Image(systemName: side == .leading ? "chevron.forward" : "chevron.backward")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(appearance.primary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(appearance.primary.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("player_carousel_back"))
        }
    }

    /// 底下的播放页背景(封面取色)是静止的;每一面盖一层半透明的玻璃,转起来能看出面的轮廓。
    private var faceBackground: some View {
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

/// 两侧页底部那一条:封面、歌名、播放 / 暂停、下一首,下沿一根细进度。点空白处回到播放器。
private struct NowPlayingCarouselNowPlayingStrip: View {
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

// MARK: - 卡拉 OK 页

/// 卡拉 OK 舞台自带整页的界面,不套外壳。只有停稳在这一页时才挂真身(一挂上就开始分离人声、
/// 开麦克风),转动途中与拖动中画一张同色调的占位。
struct NowPlayingCarouselKaraokePage: View {
    let phase: NowPlayingCarouselPanelPhase
    let safeInsets: EdgeInsets
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.05, blue: 0.14), Color(red: 0.03, green: 0.02, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if phase == .settled {
                KaraokeStageView(onClose: onClose)
                    .safeAreaPadding(EdgeInsets(
                        top: safeInsets.top,
                        leading: safeInsets.leading,
                        bottom: safeInsets.bottom,
                        trailing: safeInsets.trailing
                    ))
                    .transition(.opacity)
            } else {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(NowPlayingCarouselPanel.karaoke.tint.gradient)
                            .frame(width: 88, height: 88)
                            .shadow(color: NowPlayingCarouselPanel.karaoke.tint.opacity(0.5), radius: 24)
                        Image(systemName: NowPlayingCarouselPanel.karaoke.symbolName)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(NowPlayingCarouselPanel.karaoke.titleKey)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("player_carousel_karaoke_hint")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: phase)
    }
}

// MARK: - 相似歌曲页

struct NowPlayingCarouselSimilarPanel: View {
    let phase: NowPlayingCarouselPanelPhase
    let state: NowPlayingCarouselState
    let appearance: NowPlayingAppearance

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    /// 这一页挂上时的那首歌。在这页里点歌播放后列表不跟着换,免得点到一半整列都变了。
    @State private var seed: Song?
    @State private var results: [MusicDiscoveryResult]?
    @State private var isBuildingRadio = false

    init(phase: NowPlayingCarouselPanelPhase, state: NowPlayingCarouselState, appearance: NowPlayingAppearance) {
        self.phase = phase
        self.state = state
        self.appearance = appearance
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let seed {
                    Text("player_carousel_similar_seed \(seed.title)")
                        .font(.footnote)
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 12)
                }

                if let results {
                    if results.isEmpty {
                        NowPlayingCarouselEmptyNote(
                            symbol: "sparkles",
                            title: "similar_songs_empty",
                            message: "similar_songs_empty_desc",
                            appearance: appearance
                        )
                    } else {
                        actionRow(results: results)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 14)
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button { play(result.song, results: results) } label: {
                                NowPlayingCarouselSongRow(
                                    song: result.song,
                                    detail: String(localized: LocalizedStringResource(stringLiteral: result.primaryReason.localizationKey)),
                                    leading: .artwork,
                                    isCurrent: player.currentSong?.id == result.song.id,
                                    appearance: appearance
                                )
                            }
                            .buttonStyle(NowPlayingCarouselRowButtonStyle(appearance: appearance))
                            .id(index)
                        }
                    }
                } else {
                    NowPlayingCarouselLoadingRows(appearance: appearance)
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            if seed == nil { seed = player.currentSong }
        }
        .task(id: TaskKey(seedID: seed?.id, isSettled: phase == .settled)) {
            await loadResults()
        }
    }

    private struct TaskKey: Equatable {
        let seedID: String?
        let isSettled: Bool
    }

    private func loadResults() async {
        guard let seed else {
            results = []
            return
        }
        if let cached = state.similarResults[seed.id] {
            results = cached
            return
        }
        // 整库扫描在主线程上,只在停稳后才算,转动途中不卡。
        guard phase == .settled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        let computed = MusicDiscoveryEngine.similarSongs(to: seed, in: library, limit: 30)
        state.similarResults[seed.id] = computed
        results = computed
    }

    private func actionRow(results: [MusicDiscoveryResult]) -> some View {
        HStack(spacing: 10) {
            NowPlayingCarouselCapsuleButton(
                title: "start_similar_mix",
                symbol: "play.fill",
                isProminent: true,
                appearance: appearance
            ) {
                guard let seed else { return }
                startQueue(([seed] + results.map(\.song)).filteredPlayable())
            }
            NowPlayingCarouselCapsuleButton(
                title: "start_song_radio",
                symbol: "dot.radiowaves.left.and.right",
                isProminent: false,
                isBusy: isBuildingRadio,
                appearance: appearance
            ) {
                startRadio()
            }
        }
    }

    private func play(_ song: Song, results: [MusicDiscoveryResult]) {
        let rest = results.map(\.song).filter { $0.id != song.id }
        startQueue(([song] + rest).filteredPlayable())
    }

    private func startQueue(_ queue: [Song]) {
        guard !queue.isEmpty else { return }
        player.shuffleEnabled = false
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func startRadio() {
        guard let seed, !isBuildingRadio else { return }
        isBuildingRadio = true
        Task { @MainActor in
            await Task.yield()
            let queue = await SongRadioBuilder.queue(from: seed, in: library, limit: 48).filteredPlayable()
            isBuildingRadio = false
            startQueue(queue)
        }
    }
}

// MARK: - 专辑与艺人页

struct NowPlayingCarouselAlbumArtistPanel: View {
    let appearance: NowPlayingAppearance
    let onOpenAlbum: (Album) -> Void
    let onOpenArtist: (Artist) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    /// 同一艺人的其他歌最多列这么多首。
    private static let artistSongLimit = 30

    init(
        appearance: NowPlayingAppearance,
        onOpenAlbum: @escaping (Album) -> Void,
        onOpenArtist: @escaping (Artist) -> Void
    ) {
        self.appearance = appearance
        self.onOpenAlbum = onOpenAlbum
        self.onOpenArtist = onOpenArtist
    }

    var body: some View {
        let song = player.currentSong
        let album = song.flatMap { library.linkedAlbum(for: $0) }
        let artist = song.flatMap { library.linkedArtists(for: $0).first }
        let albumSongs = album.map { library.songs(forAlbum: $0.id) } ?? []
        let albumSongIDs = Set(albumSongs.map(\.id))
        let artistSongs = artist.map {
            Array(library.songs(forArtist: $0.id).lazy.filter { !albumSongIDs.contains($0.id) }.prefix(Self.artistSongLimit))
        } ?? []

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if song == nil {
                    NowPlayingCarouselEmptyNote(
                        symbol: "music.note",
                        title: "player_carousel_nothing_playing",
                        message: nil,
                        appearance: appearance
                    )
                } else {
                    if let album {
                        albumHeader(album, songs: albumSongs)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 10)
                        ForEach(Array(albumSongs.enumerated()), id: \.element.id) { index, track in
                            Button { play(albumSongs, startingAt: track) } label: {
                                NowPlayingCarouselSongRow(
                                    song: track,
                                    detail: nil,
                                    leading: .trackNumber(track.trackNumber ?? index + 1),
                                    isCurrent: track.id == song?.id,
                                    appearance: appearance
                                )
                            }
                            .buttonStyle(NowPlayingCarouselRowButtonStyle(appearance: appearance))
                        }
                    } else {
                        NowPlayingCarouselEmptyNote(
                            symbol: "square.stack",
                            title: "player_carousel_no_album",
                            message: nil,
                            appearance: appearance
                        )
                    }

                    if let artist, !artistSongs.isEmpty {
                        sectionHeader(artist: artist)
                            .padding(.horizontal, 22)
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        ForEach(artistSongs) { track in
                            Button { play(artistSongs, startingAt: track) } label: {
                                NowPlayingCarouselSongRow(
                                    song: track,
                                    detail: track.albumTitle,
                                    leading: .artwork,
                                    isCurrent: track.id == song?.id,
                                    appearance: appearance
                                )
                            }
                            .buttonStyle(NowPlayingCarouselRowButtonStyle(appearance: appearance))
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func albumHeader(_ album: Album, songs: [Song]) -> some View {
        HStack(alignment: .center, spacing: 14) {
            CachedArtworkView(
                albumID: album.id,
                albumTitle: album.title,
                artistName: album.artistName,
                year: album.year,
                trackCount: album.songCount,
                size: 92,
                cornerRadius: 12
            )
            .frame(width: 92, height: 92)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: album.title)
                    .font(.headline)
                    .foregroundStyle(appearance.primary)
                    .lineLimit(2)
                if let artistName = album.artistName, !artistName.isEmpty {
                    Text(verbatim: artistName)
                        .font(.subheadline)
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(1)
                }
                Text(verbatim: albumFacts(album, songCount: songs.count))
                    .font(.caption)
                    .foregroundStyle(appearance.tertiary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    NowPlayingCarouselCapsuleButton(
                        title: "play",
                        symbol: "play.fill",
                        isProminent: true,
                        isCompact: true,
                        appearance: appearance
                    ) {
                        play(songs, startingAt: nil)
                    }
                    NowPlayingCarouselCapsuleButton(
                        title: "player_carousel_open_album",
                        symbol: "chevron.forward",
                        isProminent: false,
                        isCompact: true,
                        appearance: appearance
                    ) {
                        onOpenAlbum(album)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func albumFacts(_ album: Album, songCount: Int) -> String {
        var facts: [String] = []
        if let year = album.year, year > 0 { facts.append(String(year)) }
        if songCount > 0 {
            facts.append(String(localized: "player_carousel_song_count \(songCount)"))
        }
        return facts.joined(separator: " · ")
    }

    private func sectionHeader(artist: Artist) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("player_carousel_more_by_artist \(artist.name)")
                .font(.headline)
                .foregroundStyle(appearance.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { onOpenArtist(artist) } label: {
                HStack(spacing: 3) {
                    Text("player_carousel_open_artist")
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(appearance.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func play(_ songs: [Song], startingAt song: Song?) {
        let queue = songs.filteredPlayable()
        guard !queue.isEmpty else { return }
        let index = song.flatMap { target in queue.firstIndex { $0.id == target.id } } ?? 0
        Task { await player.play(queue: queue, startingAt: index) }
    }
}

// MARK: - 页里的小部件

private struct NowPlayingCarouselSongRow: View {
    enum Leading {
        case artwork
        case trackNumber(Int)
    }

    let song: Song
    let detail: String?
    let leading: Leading
    let isCurrent: Bool
    let appearance: NowPlayingAppearance

    @Environment(MusicLibrary.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            switch leading {
            case .artwork:
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 44,
                    cornerRadius: 8,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    loadsHighResolution: false
                )
                .frame(width: 44, height: 44)
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
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if song.duration > 0 {
                Text(Duration.seconds(song.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(appearance.tertiary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let artist = library.artistDisplayName(for: song) ?? song.artistName ?? ""
        guard let detail, !detail.isEmpty else { return artist }
        return artist.isEmpty ? detail : "\(artist) · \(detail)"
    }
}

private struct NowPlayingCarouselRowButtonStyle: ButtonStyle {
    let appearance: NowPlayingAppearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appearance.primary.opacity(configuration.isPressed ? 0.10 : 0))
                    .padding(.horizontal, 10)
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct NowPlayingCarouselCapsuleButton: View {
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
            }
            .font((isCompact ? Font.caption : Font.subheadline).weight(.semibold))
            .foregroundStyle(isProminent ? prominentInk : appearance.primary)
            .padding(.horizontal, isCompact ? 11 : 16)
            .padding(.vertical, isCompact ? 6 : 10)
            .frame(maxWidth: isCompact ? nil : .infinity)
            .background(
                Capsule().fill(isProminent ? appearance.primary : appearance.primary.opacity(0.12))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    /// 实心钮上的字用底色的反色。
    private var prominentInk: Color {
        appearance.isLight ? .white : .black
    }
}

private struct NowPlayingCarouselEmptyNote: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let appearance: NowPlayingAppearance

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(appearance.tertiary)
            Text(title)
                .font(.headline)
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
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }
}

/// 相似歌曲还没算好时的几行骨架。
private struct NowPlayingCarouselLoadingRows: View {
    let appearance: NowPlayingAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<6, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().frame(width: CGFloat(150 - index * 9), height: 10)
                        Capsule().frame(width: CGFloat(96 + index * 7), height: 8)
                    }
                }
            }
        }
        .foregroundStyle(appearance.primary.opacity(0.08))
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .accessibilityHidden(true)
    }
}

#endif
