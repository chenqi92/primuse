import AVKit
import SwiftUI
import Translation
import PrimuseKit
#if os(iOS)
import UIKit
import MediaPlayer
#elseif os(macOS)
import AppKit
#endif

private struct NowPlayingAppearance {
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast

    var isLight: Bool { colorScheme == .light }
    private var usesIncreasedContrast: Bool { contrast == .increased }

    var primary: Color {
        if isLight {
            return .black.opacity(usesIncreasedContrast ? 0.96 : 0.88)
        }
        return .white
    }

    var secondary: Color {
        if isLight {
            return .black.opacity(usesIncreasedContrast ? 0.78 : 0.64)
        }
        return .white.opacity(usesIncreasedContrast ? 0.88 : 0.72)
    }

    var tertiary: Color {
        if isLight {
            return .black.opacity(usesIncreasedContrast ? 0.64 : 0.48)
        }
        return .white.opacity(usesIncreasedContrast ? 0.72 : 0.52)
    }

    var faint: Color {
        if isLight {
            return .black.opacity(usesIncreasedContrast ? 0.52 : 0.38)
        }
        return .white.opacity(usesIncreasedContrast ? 0.60 : 0.38)
    }

    var divider: Color {
        primary.opacity(usesIncreasedContrast ? 0.18 : 0.10)
    }

    var track: Color {
        primary.opacity(usesIncreasedContrast ? 0.28 : 0.18)
    }

    var backgroundBase: Color {
        isLight
            ? Color(red: 0.94, green: 0.945, blue: 0.955)
            : Color(red: 0.035, green: 0.043, blue: 0.055)
    }

    var artworkAccentOpacity: Double {
        isLight ? (usesIncreasedContrast ? 0.38 : 0.46) : 0.88
    }

    var fallbackAccentOpacity: Double {
        isLight ? (usesIncreasedContrast ? 0.09 : 0.13) : 0.34
    }

    var artworkLowerAccentOpacity: Double {
        isLight ? (usesIncreasedContrast ? 0.26 : 0.32) : 0.70
    }

    var fallbackLowerAccentOpacity: Double {
        isLight ? (usesIncreasedContrast ? 0.06 : 0.09) : 0.26
    }

    var pastLyricOpacity: Double {
        usesIncreasedContrast ? 0.56 : (isLight ? 0.40 : 0.32)
    }

    var futureLyricOpacity: Double {
        usesIncreasedContrast ? 0.70 : (isLight ? 0.56 : 0.46)
    }

    var inactiveSyllableOpacity: Double {
        usesIncreasedContrast ? 0.58 : (isLight ? 0.46 : 0.42)
    }
}

/// 播放页浮动圆钮的玻璃底样式。
private enum NowPlayingChromeGlass: Equatable {
    /// 固定深色玻璃。沉浸歌词与全屏画面背后永远是深色画面，`ImmersiveGlassActionLabel`
    /// 就是照这个前提做的。
    case immersive
    /// 跟随明暗外观。普通模式的背景是取色渐变，浅色外观下底也得是浅的 ——
    /// 深色圆底会把同样是深色的图标吃掉。
    case adaptive
    /// iPhone Duo 竖栏那一列里：只有图标，玻璃底由整组的胶囊给。
    case barColumn(itemSize: CGFloat)
}

/// 跟随明暗外观的玻璃底。
///
/// 浅色外观下在材质上再叠一层白色提亮、描边用极淡的深色；深色外观下的取值与
/// `ImmersiveGlassActionLabel` 对齐，从普通模式切到沉浸歌词时圆钮的观感不跳。
/// 材质本身不再强制 colorScheme —— 它跟着环境走，正好等于 `appearance` 的明暗。
private struct NowPlayingAdaptiveGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let appearance: NowPlayingAppearance
    let tint: Color
    var isSelected = false

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(.ultraThinMaterial)
                shape.fill(plateTint)
            }
            .overlay {
                shape.strokeBorder(strokeTint, lineWidth: strokeWidth)
            }
            .contentShape(shape)
    }

    private var plateTint: Color {
        if isSelected {
            return tint.opacity(appearance.isLight ? 0.16 : 0.18)
        }
        return appearance.isLight ? .white.opacity(0.42) : .black.opacity(0.16)
    }

    private var strokeTint: Color {
        if isSelected {
            return tint.opacity(appearance.isLight ? 0.48 : 0.62)
        }
        return appearance.isLight ? .black.opacity(0.07) : .white.opacity(0.20)
    }

    private var strokeWidth: CGFloat { isSelected ? 1.1 : 0.8 }
}

extension View {
    fileprivate func nowPlayingAdaptiveGlass<S: InsettableShape>(
        _ shape: S,
        appearance: NowPlayingAppearance,
        tint: Color,
        isSelected: Bool = false
    ) -> some View {
        modifier(
            NowPlayingAdaptiveGlass(
                shape: shape,
                appearance: appearance,
                tint: tint,
                isSelected: isSelected
            )
        )
    }
}

/// `ImmersiveGlassActionLabel` 的自适应版本。尺寸与字重照抄，只换底。
private struct NowPlayingGlassActionLabel: View {
    var symbol: String
    var appearance: NowPlayingAppearance
    var tint: Color
    var diameter: CGFloat = 44
    var isSelected = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.34, weight: .semibold))
            .foregroundStyle(isSelected ? tint : tint.opacity(0.88))
            .frame(width: diameter, height: diameter)
            .nowPlayingAdaptiveGlass(
                Circle(),
                appearance: appearance,
                tint: tint,
                isSelected: isSelected
            )
    }
}

private struct NowPlayingGlassActionButton: View {
    var symbol: String
    var label: LocalizedStringKey
    var appearance: NowPlayingAppearance
    var tint: Color
    var diameter: CGFloat = 44
    var isSelected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            NowPlayingGlassActionLabel(
                symbol: symbol,
                appearance: appearance,
                tint: tint,
                diameter: diameter,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// iPhone Duo 竖栏那一列里的一颗：只有图标，玻璃底是整组共用的胶囊（和系统竖栏一样）；
/// 选中时图标换成强调色，下面垫一个淡淡的圆。
private struct NowPlayingBarColumnIcon: View {
    var symbol: String
    var appearance: NowPlayingAppearance
    var size: CGFloat
    var tint: Color? = nil
    var isSelected = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(isSelected ? (tint ?? appearance.primary) : appearance.primary.opacity(0.86))
            .frame(width: size, height: size)
            .background {
                if isSelected {
                    Circle().fill(appearance.primary.opacity(appearance.isLight ? 0.1 : 0.16))
                }
            }
            .contentShape(Circle())
    }
}

#if os(iOS)
/// 播放页与外接显示器各持一份租约，谁最后释放谁关掉常亮。
@MainActor
private enum PlayerScreenWakeCoordinator {
    private static var owners: Set<UUID> = []

    static func update(ownerID: UUID, shouldHold: Bool) {
        owners = NowPlayingInteractionPolicy.updatedScreenWakeOwners(
            owners,
            ownerID: ownerID,
            shouldHold: shouldHold
        )

        let shouldDisableIdleTimer = !owners.isEmpty
        guard UIApplication.shared.isIdleTimerDisabled != shouldDisableIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = shouldDisableIdleTimer
    }
}

/// `UIDevice.batteryState` only reports a real value while monitoring is on,
/// so monitoring runs just for the window in which the charging rule matters.
@MainActor
private enum DeviceChargingState {
    static var isCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        case .unplugged, .unknown: false
        @unknown default: false
        }
    }

    static func setMonitoring(_ enabled: Bool) {
        guard UIDevice.current.isBatteryMonitoringEnabled != enabled else { return }
        UIDevice.current.isBatteryMonitoringEnabled = enabled
    }
}

/// 整个播放器界面（封面、歌词、全屏效果）只要是当前展示面就持有常亮租约，
/// 不再区分歌词有没有显示。
private struct PlayerScreenWakeLeaseModifier: ViewModifier {
    let isVisible: Bool
    let sceneIsActive: Bool

    @AppStorage(PlayerAppearancePreferences.keepsScreenAwakeInPlayerKey)
    private var isEnabled = PlayerAppearancePreferences.keepsScreenAwakeInPlayerByDefault
    @AppStorage(PlayerAppearancePreferences.playerScreenWakeRequiresChargingKey)
    private var requiresCharging = PlayerAppearancePreferences.playerScreenWakeRequiresChargingByDefault
    @State private var ownerID = UUID()
    @State private var isCharging = false

    private var observesCharging: Bool {
        isEnabled && requiresCharging && isVisible && sceneIsActive
    }

    private var shouldHoldLease: Bool {
        NowPlayingInteractionPolicy.shouldKeepScreenAwake(
            settingEnabled: isEnabled,
            requiresCharging: requiresCharging,
            isCharging: isCharging,
            playerVisible: isVisible,
            sceneIsActive: sceneIsActive
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: observesCharging, initial: true) { _, observes in
                DeviceChargingState.setMonitoring(observes)
                isCharging = DeviceChargingState.isCharging
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            ) { _ in
                isCharging = DeviceChargingState.isCharging
            }
            .onChange(of: shouldHoldLease, initial: true) { _, shouldHold in
                PlayerScreenWakeCoordinator.update(
                    ownerID: ownerID,
                    shouldHold: shouldHold
                )
            }
            .onDisappear {
                DeviceChargingState.setMonitoring(false)
                PlayerScreenWakeCoordinator.update(ownerID: ownerID, shouldHold: false)
            }
    }
}

extension View {
    func playerScreenWakeLease(isVisible: Bool, sceneIsActive: Bool) -> some View {
        modifier(PlayerScreenWakeLeaseModifier(
            isVisible: isVisible,
            sceneIsActive: sceneIsActive
        ))
    }
}
#endif

/// A single low-frequency color field shared by the standard iOS and macOS
/// players. The artwork palette remains visible when motion is unavailable;
/// only the decorative timeline is suspended.
struct AdaptiveNowPlayingBackdrop: View {
    let baseColor: Color
    let primaryAccent: Color
    let secondaryAccent: Color
    let darkAccent: Color
    let primaryOpacity: Double
    let secondaryOpacity: Double
    let hasArtworkPalette: Bool
    let isVisible: Bool
    let isSceneActive: Bool
    let isPlaying: Bool
    let paletteVibrancy: Double
    let paletteLuminance: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runtimeRevision: UInt = 0
    @State private var activeMotionElapsed: TimeInterval = 0
    @State private var motionStartedAt: Date?

    var body: some View {
        let policy = motionPolicy
        let _ = runtimeRevision

        GeometryReader { geometry in
            TimelineView(.animation(
                minimumInterval: policy.minimumInterval ?? 1,
                paused: !policy.shouldAnimate
            )) { context in
                colorField(
                    size: geometry.size,
                    date: context.date,
                    policy: policy
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        )) { _ in
            runtimeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )) { _ in
            runtimeRevision &+= 1
        }
        .onAppear {
            updateMotionClock(isRunning: policy.shouldAnimate, at: .now)
        }
        .onChange(of: policy.shouldAnimate) { _, shouldAnimate in
            updateMotionClock(isRunning: shouldAnimate, at: .now)
        }
        .onDisappear {
            updateMotionClock(isRunning: false, at: .now)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var motionPolicy: NowPlayingAmbientMotionPolicy {
        NowPlayingAmbientMotionPolicy(
            hasArtworkPalette: hasArtworkPalette,
            isAmbientVisible: max(primaryOpacity, secondaryOpacity) > 0.001,
            isVisible: isVisible,
            isSceneActive: isSceneActive,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalCondition: Self.thermalCondition(ProcessInfo.processInfo.thermalState),
            paletteVibrancy: paletteVibrancy
        )
    }

    private func colorField(
        size: CGSize,
        date: Date,
        policy: NowPlayingAmbientMotionPolicy
    ) -> some View {
        let radius = max(size.width, size.height) * 0.94
        let phase = motionElapsed(at: date) / policy.cycleDuration * 2 * Double.pi
        let amplitude = CGFloat(policy.motionAmplitude)
        let primaryCenter = UnitPoint(
            x: 0.16 + CGFloat(sin(phase)) * amplitude,
            y: 0.13 + CGFloat(cos(phase * 0.83)) * amplitude
        )
        let secondaryCenter = UnitPoint(
            x: 0.86 + CGFloat(cos(phase * 0.71 + 1.2)) * amplitude,
            y: 0.84 + CGFloat(sin(phase * 0.91 + 0.6)) * amplitude
        )
        let middleCenter = UnitPoint(
            x: 0.54 + CGFloat(sin(phase * 0.57 + 2.1)) * amplitude * 0.72,
            y: 0.48 + CGFloat(cos(phase * 0.63 + 1.7)) * amplitude * 0.72
        )
        let restrainedOpacity = paletteOpacityScale

        return ZStack {
            baseColor

            RadialGradient(
                colors: [
                    primaryAccent.opacity(primaryOpacity * restrainedOpacity),
                    primaryAccent.opacity(primaryOpacity * restrainedOpacity * 0.34),
                    .clear
                ],
                center: primaryCenter,
                startRadius: 0,
                endRadius: radius
            )

            RadialGradient(
                colors: [
                    secondaryAccent.opacity(secondaryOpacity * restrainedOpacity),
                    secondaryAccent.opacity(secondaryOpacity * restrainedOpacity * 0.30),
                    .clear
                ],
                center: secondaryCenter,
                startRadius: 0,
                endRadius: radius * 0.92
            )

            RadialGradient(
                colors: [
                    darkAccent.opacity(secondaryOpacity * 0.42),
                    .clear
                ],
                center: middleCenter,
                startRadius: 0,
                endRadius: radius * 0.72
            )
        }
    }

    private func updateMotionClock(isRunning: Bool, at date: Date) {
        if isRunning {
            if motionStartedAt == nil {
                motionStartedAt = date
            }
        } else if let motionStartedAt {
            activeMotionElapsed += max(0, date.timeIntervalSince(motionStartedAt))
            self.motionStartedAt = nil
        }
    }

    private func motionElapsed(at date: Date) -> TimeInterval {
        guard let motionStartedAt else { return activeMotionElapsed }
        return activeMotionElapsed + max(0, date.timeIntervalSince(motionStartedAt))
    }

    private var paletteOpacityScale: Double {
        let vibrancy = min(max(paletteVibrancy, 0), 1)
        let luminance = min(max(paletteLuminance, 0), 1)
        let saturationRestraint = 1 - max(0, vibrancy - 0.72) * 0.28
        let brightnessRestraint = luminance > 0.62 ? 0.88 : 1
        return saturationRestraint * brightnessRestraint
    }

    private static func thermalCondition(
        _ state: ProcessInfo.ThermalState
    ) -> ArtworkThermalCondition {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}

#if os(iOS)
private struct WindowSafeAreaInsetsReader: UIViewRepresentable {
    let onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
        uiView.publishIfNeeded()
    }

    final class ReaderView: UIView {
        var onChange: ((UIEdgeInsets) -> Void)?
        private var lastInsets: UIEdgeInsets?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishIfNeeded()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            publishIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publishIfNeeded()
        }

        func publishIfNeeded() {
            guard let window else { return }
            let insets = window.safeAreaInsets
            guard insets != lastInsets else { return }
            lastInsets = insets
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(insets)
            }
        }
    }
}

private struct NowPlayingAlbumTransitionID: Hashable {
    let albumID: String
}

private struct NowPlayingAlbumTransitionSourceModifier: ViewModifier {
    let albumID: String?
    let namespace: Namespace.ID
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if let albumID {
            content.matchedTransitionSource(
                id: NowPlayingAlbumTransitionID(albumID: albumID),
                in: namespace
            ) { source in
                source.clipShape(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            }
        } else {
            content
        }
    }
}
#endif

/// 把一段视图的构造推迟到这一层自己的 `body` 里，由 SwiftUI 单独求值。
///
/// Debug（-Onone）构建不复用栈槽：一个构造视图的闭包里，每个分支、每个中间值都各占一块栈，
/// 没走到的分支也照样预留。播放页 `body` 的 GeometryReader 闭包原先在两层 ZStack 闭包里
/// 现场构造全部布局，这几帧都要为「所有布局拼成的条件类型」留好几份，再叠上
/// 竖屏布局 → 歌名栏 → 「更多」菜单这一串，iPhone 主线程 1MB 的栈会被吃满，
/// 打开播放页就撞上栈保护页崩溃。包进这一层后，外层闭包只持有一个闭包大小的值，
/// 布局本身等到这一层更新时才构造，那时外层那几帧已经返回。
private struct NowPlayingDeferredContent<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
    }
}

struct NowPlayingView: View {
    private enum AmbientBackdropTuning {
        static let transitionDuration = 0.5
    }

    var onOpenAlbum: ((Album) -> Void)? = nil
    var onOpenArtist: ((Artist) -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    var onTopMinimizeDragChanged: ((CGFloat) -> Void)? = nil
    var onTopMinimizeDragEnded: ((Bool) -> Void)? = nil
    var onLeadingMinimizeDragChanged: ((CGFloat) -> Void)? = nil
    var onLeadingMinimizeDragEnded: ((Bool) -> Void)? = nil
    /// The overlay mounts off-screen first. Expensive, nonessential work stays
    /// suspended until its entrance animation has actually completed.
    var isPresentationSettled = true
    var isPresentationActive = true
    @State private var showChapterList = false
    @State private var bookmarkFeedbackToken = 0
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.pmIsPhoneIdiom) private var isPhoneIdiomEnvironment
    #if DEBUG
    @Environment(\.pmDebugFoldAxis) private var debugFoldAxis
    #endif
    /// iPhone Duo 内屏分栏时右栏(歌词 / 接下来播放)收起了。收起后播放器按整屏重新排开,
    /// 不再停在左半屏。
    @State private var sidePaneHidden = false
    /// 这块画布能左右分栏(内屏横握):队列键与歌词键改为开合右栏,右栏收着也一样。
    @State private var isPlayerSplit = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsPlayerVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault

    /// Apple Music 歌的 catalog URL ── 用来给"在 Apple Music 打开"按钮跳转。
    /// 跳转后用户能看到 Apple Music 自家的歌词 / 添加收藏 / 看艺人页等
    /// 我们没办法对 DRM 流提供的能力。
    private var appleMusicCatalogURL: URL? {
        guard let song = player.currentSong, player.isAppleMusicMode else { return nil }
        return AppServices.shared.appleMusicLibrary.catalogURL(for: song)
    }
    @Namespace private var lyricsArtworkNamespace
    /// 换构图(竖版 / 手机横屏骨架 / iPhone Duo 内屏分栏与半折)时，歌名、进度条、传输键从旧位置滑到新位置。
    /// 封面走的是上面那个命名空间(与歌词小封面同一个身份)。
    @Namespace private var layoutNamespace
    #if os(iOS)
    @Namespace private var albumPresentationNamespace
    @State private var presentedAlbum: Album?
    @State private var albumPresentationSourceID: NowPlayingAlbumTransitionID?
    /// 「转到这本书」: 有声内容的书详情, 用法同 `presentedAlbum`。
    @State private var presentedBook: NowPlayingBookRoute?
    #endif
    @State private var showLyrics = false
    @State private var activeMinimizeDragAxis: NowPlayingDismissGesturePolicy.Axis?
    @State private var activeMinimizeDragStartLocation: CGPoint?
    @State private var isLyricsImmersive = false
    #if DEBUG && os(iOS)
    @Environment(\.pmDebugPlayerMode) private var debugPlayerMode
    /// 取证框里模拟别的视口:遮挡区与窗口安全区都按框的来,不读外屏自己的。
    @Environment(\.pmDebugSuppressesVerticalBar) private var debugSuppressesVerticalBar
    @Environment(\.pmDebugViewportSafeArea) private var debugViewportSafeArea
    #endif
    @State private var isFullscreenPlayerPresented = false
    @State private var immersiveControlsState = ImmersiveControlsState.inactive
    @State private var immersiveControlsAutoHideTask: Task<Void, Never>?
    @State private var showsImmersiveEffectPicker = false
    /// 手机横屏普通模式自己的「锁」。沉浸歌词那套 `immersiveControlsState` 带自动
    /// 隐藏计时，语义不同，不能共用。离开这个布局时会自动解锁，免得用户在别的
    /// 布局里找不到解锁入口。
    @State private var isCompactLandscapeLocked = false
    /// 手机横屏右栏窄到放不下两端的随机 / 循环时置真，让「更多」菜单补上入口。
    /// 由布局函数在 `onChange` 里写入，`body` 里不做这类赋值。
    @State private var compactLandscapeHidesModeToggles = false
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    /// 当前歌词各行的译文（文件自带的优先，其次是翻译任务给出的）。翻译任务挂在
    /// 播放页常驻的零尺寸视图上，这份结果同时供歌词面板、全屏舞台和歌词海报读取。
    @State private var lyricTranslationsByLineID: [String: String] = [:]
    @State private var lyricsTranslationActivity: LyricsTranslationActivity = .idle
    @State private var lyricPosterComposer: LyricPosterComposer?
    @State private var lyricsWritingDirection: LyricWritingDirection = .natural
    @State private var lyricsRevision: UInt = 0
    @State private var lyricsLoadRevision: UInt = 0
    /// 歌词还没有结论的那段时间属于哪一次加载。切歌 / 重新刮削会推进
    /// lyricsLoadRevision, 晚到的收尾因此不会把新一轮的加载态抹掉。
    @State private var lyricsResolvingRevision: UInt?
    @State private var lyricsResolutionTimeoutTask: Task<Void, Never>?
    /// 占位最多显示这么久。NAS 不可达时 Tier 3 能挂很长时间, 不封顶的话
    /// "暂无歌词 + 去刮削"就一直出不来, 用户连手动刮削都点不到。
    private static let lyricsResolutionTimeout: Duration = .seconds(6)
    @State private var isResolvingScrapeTarget = false
    @State private var scrapeAlertMessage: String?
    @State private var showNoScraperSourceAlert = false
    @State private var sourceLyricsReloadAlertMessage: String?
    @State private var sourceLyricsReloadingSongID: String?
    /// Freeze the canonical song identity used by the scrape sheet. MusicKit
    /// can temporarily expose a catalog ID while the library row uses an
    /// `i.*` ID; reading `player.currentSong` again inside the sheet could then
    /// save the chosen lyrics under a different song on each presentation.
    @State private var scrapeTargetSong: Song?
    @State private var showAddToPlaylist = false
    @State private var shareSong: Song?
    /// 分享页里点了「分享歌词」。海报是播放页自己的一层 sheet，要等分享页收完再弹，
    /// 两层同时在场后一层会被系统直接丢掉。
    @State private var presentsLyricPosterAfterShare = false
    @State private var showCastPicker = false
    @State private var showSongInfo = false
    @State private var showSleepTimer = false
    /// A medley waiting for the listener to agree to use mobile data.
    @State private var pendingMedleySongs: [Song]?
    /// 电台的「刚播过」:这个台上听到过的曲目标题。
    @State private var radioDetailStationID: String?
    @State private var showKaraoke = false
    @State private var showDeleteConfirm = false
    @State private var deleteErrorMessage: String?
    @State private var showTagEditor = false
    /// 歌词编辑跟标签编辑平级；打开时冻结目标，避免自然切歌后写错歌曲。
    @State private var lyricsEditorTargetSong: Song?
    @State private var lyricsEditorAutoStartsAudioTranscription = false
    @State private var showSimilarSongs = false
    @State private var showMusicVideoFullScreen = false
    #if os(iOS)
    @State private var windowSafeAreaInsets = UIEdgeInsets.zero
    /// 系统竖栏在哪一侧(iPhone Duo 等);没有竖栏的设备与 Xcode 27.0 构建为 nil。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    #endif
    @State private var fullScreenMusicVideoPlayer: AVPlayer?
    @Environment(ThemeService.self) private var theme
    @AppStorage(AppThemePreferences.ambientStrengthKey)
    private var ambientStrength = AppThemePreferences.defaultAmbientStrength

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var isVisualSceneActive: Bool {
        #if os(iOS)
        scenePhase == .active
        #else
        true
        #endif
    }

    private var isAlbumPresentationActive: Bool {
        #if os(iOS)
        presentedAlbum != nil || presentedBook != nil
        #else
        false
        #endif
    }

    private var hasBlockingNowPlayingPresentation: Bool {
        showQueue
            || showsImmersiveEffectPicker
            || scrapeTargetSong != nil
            || showAddToPlaylist
            || shareSong != nil
            || showSongInfo
            || showTagEditor
            || lyricsEditorTargetSong != nil
            || lyricPosterComposer != nil
            || showSimilarSongs
            || showCastPicker
            || showMusicVideoFullScreen
            || isAlbumPresentationActive
            || showSleepTimer
            || showDeleteConfirm
            || scrapeAlertMessage != nil
            || sourceLyricsReloadAlertMessage != nil
            || deleteErrorMessage != nil
            || showNoScraperSourceAlert
    }

    /// Decorative artwork and ambient motion only run while the player itself
    /// is the exposed interaction surface. Modal content retains the static
    /// palette underneath without spending another animation clock.
    private var isNowPlayingSurfaceExposed: Bool {
        isPresentationSettled
            && isPresentationActive
            && !isFullscreenPlayerPresented
            && !hasBlockingNowPlayingPresentation
            && activeMinimizeDragAxis == nil
            && activeMinimizeDragStartLocation == nil
    }

    private var initialLyricsLoadIdentity: String {
        "\(player.currentSong?.id ?? "")|settled:\(isPresentationSettled)"
    }

    /// Keep startup buffering and playback-state changes from starting a second
    /// artwork spring while the full-player entrance spring is still running.
    private var artworkAppearsPlaying: Bool {
        !isPresentationSettled || player.isPlaying || player.isLoading
    }

    /// 只取当前歌前后这一段。`player.queue` 会把整条队列复制成 [Song],
    /// 整库随机后是几万首, 而这里每次视图更新都会跑。
    private func handoffQueueIDs() -> [String] {
        let entries = player.queueEntries
        guard !entries.isEmpty else { return [] }
        let index = min(max(player.currentIndex, 0), entries.count - 1)
        let lowerBound = max(0, index - 5)
        let upperBound = min(entries.count, lowerBound + 50)
        return entries[lowerBound..<upperBound].map(\.song.id)
    }

    private var isScrapingCurrentSong: Bool {
        guard let songID = player.currentSong?.id else { return isResolvingScrapeTarget }
        return isResolvingScrapeTarget || scraperService.isSingleScrapeActive(
            songID: songID,
            purposes: [.metadataApply, .lyricsApply]
        )
    }

    private var isScrapeActionUnavailable: Bool {
        isResolvingScrapeTarget
            || scraperService.isScraping
            || scraperService.isSingleScraping
    }

    private var canReloadLyricsFromSource: Bool {
        guard let song = player.currentSong else { return false }
        return LyricsAuthoritativeSourcePolicy.supportsServerDocument(
            sourcesStore.source(id: song.sourceID)?.type
        )
    }

    private var isReloadingLyricsFromSource: Bool {
        sourceLyricsReloadingSongID == player.currentSong?.id
    }

    // 父持有 @AppStorage 仅为了 onChange 触发 CloudKVS 同步;实际渲染字号由
    // LyricsScrollView 子 view 自己读 AppStorage("lyricsFontScale")。
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    @AppStorage(LyricPosterPreferences.styleKey) private var lyricPosterStyleRawValue = ""
    /// 只用来读当前界面皮肤建议的海报款式;皮肤很少变,不会给播放页带来额外的重绘。
    @Environment(\.skin) private var skin
    @AppStorage(LyricPosterPreferences.canvasKey) private var lyricPosterCanvasRawValue = ""
    @AppStorage(LyricPosterPreferences.prefersMotionKey)
    private var lyricPosterPrefersMotion = LyricPosterPreferences.prefersMotionByDefault
    @AppStorage(LyricPosterPreferences.includesTranslationKey)
    private var lyricPosterIncludesTranslation = LyricPosterPreferences.includesTranslationByDefault
    @AppStorage(LyricPosterPreferences.showsCreditKey)
    private var lyricPosterShowsCredit = LyricPosterPreferences.showsCreditByDefault
    @AppStorage(LyricPosterPreferences.filterKey) private var lyricPosterFilterRawValue = ""
    @AppStorage(LyricPosterPreferences.motionEffectKey)
    private var lyricPosterMotionEffectRawValue = ""
    @AppStorage(LyricPosterPreferences.signatureKey) private var lyricPosterSignature = ""
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var fullscreenPlayerEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    #if os(iOS)
    @AppStorage(FullscreenPlayerEffect.userSelectedKey)
    private var fullscreenPlayerEffectUserSelected = false
    /// 可选读取:播放页可能被放进一个没有注入皮肤运行时的宿主里,读不到就按存储值走。
    @Environment(SkinRuntime.self) private var skinRuntime: SkinRuntime?
    #endif

    /// 实际生效的全屏效果。亲手选过的照旧;从没选过时,用当前界面皮肤带来的那一款。
    private var fullscreenPlayerEffect: FullscreenPlayerEffect {
        let stored = FullscreenPlayerEffect(rawValue: fullscreenPlayerEffectRawValue) ?? .defaultValue
        #if os(iOS)
        guard let skinRuntime else { return stored }
        return skinRuntime.effectiveFullscreenEffect(
            stored: stored,
            userSelected: fullscreenPlayerEffectUserSelected
        )
        #else
        return stored
        #endif
    }

    private var fullscreenPlayerEffectBinding: Binding<FullscreenPlayerEffect> {
        Binding(
            get: { fullscreenPlayerEffect },
            set: { newValue in
                fullscreenPlayerEffectRawValue = newValue.rawValue
                FullscreenPlayerEffectSync.shared.select(newValue)
            }
        )
    }

    /// Whether the current song is in any playlist (not a dedicated "favorites" concept)
    private var isInAnyPlaylist: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.playlists.contains { library.contains(songID: songID, inPlaylist: $0.id) }
    }

    /// 当前歌是否已经被加进「我喜欢」── heart 按钮渲染态 & toggle 目标。
    /// 跟 isInAnyPlaylist 是两回事: "加任意歌单"是 moreMenu 里的 add_to_playlist,
    /// "喜欢"是 heart 按钮 toggle 这个固定 system 歌单。
    private var isCurrentLiked: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.isLiked(songID: songID)
    }

    /// Resolve the currently playing song back to the library entities used by
    /// the detail screens. Older scans may not have persisted artistID/albumID,
    /// so retain a normalized-name fallback instead of silently hiding links.
    private var currentArtists: [Artist] {
        guard let song = player.currentSong else { return [] }
        // 播放页每次更新都会读几遍, 按 id 走曲库的 O(1) 索引, 别整库建字典。
        return library.artistNames(for: song).compactMap { name in
            let id = MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey(name))
            if let artist = library.visibleArtist(id: id) { return artist }
            return library.visibleArtists.first {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
        }
    }

    private var currentArtist: Artist? {
        currentArtists.first
    }

    private var currentArtistDisplayName: String {
        guard let song = player.currentSong else { return "" }
        return library.artistDisplayName(for: song) ?? ""
    }

    private var currentAlbum: Album? {
        guard let song = player.currentSong else { return nil }
        if let albumID = song.albumID,
           let album = library.visibleAlbum(id: albumID) {
            return album
        }
        let albumTitle = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !albumTitle.isEmpty else { return nil }
        let artistName = (song.albumArtistName ?? library.artistNames(for: song).first)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return library.visibleAlbums.first {
            let titleMatches = $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(albumTitle) == .orderedSame
            let albumArtist = $0.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let artistMatches = artistName.isEmpty || albumArtist.isEmpty
                || albumArtist.localizedCaseInsensitiveCompare(artistName) == .orderedSame
            return titleMatches && artistMatches
        }
    }

    private var lyricsArtworkTransitionID: String {
        "now-playing-lyrics-artwork:\(player.currentSong?.id ?? "none")"
    }

    /// 只有非沉浸式歌词才会渲染紧凑小封面。沉浸式歌词布局 (横屏) 仍然显示大封面
    /// 且没有小封面, 此时大封面必须继续充当匹配几何的源, 否则命名空间里没有源。
    private var isLyricsCompactArtworkVisible: Bool {
        showLyrics && !isLyricsImmersive
    }

    private var standardLyricsAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(response: 0.48, dampingFraction: 0.82, blendDuration: 0.08)
    }

    /// 头部封面由 matchedGeometryEffect 负责位移与缩放, 这里只做淡入淡出,
    /// 避免两套动画互相争抢导致封面先平移后突变。
    private var lyricsHeaderTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity
    }

    private var lyricsPanelTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 34)
                .combined(with: .scale(scale: 0.965, anchor: .bottom))
                .combined(with: .opacity),
            removal: .offset(y: 22)
                .combined(with: .scale(scale: 0.98, anchor: .bottom))
                .combined(with: .opacity)
        )
    }

    /// 大封面同样交给 matchedGeometryEffect 驱动, 额外的 offset / scale 只会
    /// 和匹配几何冲突, 所以这里保持纯淡入淡出。
    private var playerArtworkTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity
    }

    private var canOpenCurrentAlbum: Bool {
        guard currentAlbum != nil else { return false }
        #if os(iOS)
        return true
        #else
        return onOpenAlbum != nil
        #endif
    }

    private func presentAlbum(
        _ album: Album,
        prefersMatchedArtworkSource: Bool
    ) {
        #if os(iOS)
        if prefersMatchedArtworkSource,
           !reduceMotion,
           !player.isMusicVideoPlaybackActive {
            albumPresentationSourceID = NowPlayingAlbumTransitionID(albumID: album.id)
        } else {
            albumPresentationSourceID = nil
        }
        presentedAlbum = album
        #else
        onOpenAlbum?(album)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func albumDetailPresentation(_ album: Album) -> some View {
        let detail = NavigationStack {
            AlbumDetailView(album: album)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationCornerRadius(28)

        if let sourceID = albumPresentationSourceID, !reduceMotion {
            detail.navigationTransition(
                .zoom(sourceID: sourceID, in: albumPresentationNamespace)
            )
        } else {
            detail
        }
    }
    #endif

    /// 有声内容的「转到这本书」: iPhone/iPad 在播放页上弹出书详情(和专辑一样
    /// 不收起播放页), Mac 交给主窗口的详情栈。
    private func presentCurrentBook() {
        guard let bookID = player.currentBookID else { return }
        #if os(iOS)
        presentedBook = NowPlayingBookRoute(id: bookID)
        #elseif os(macOS)
        NotificationCenter.default.post(name: .primuseDetailOpenSpokenWordBook, object: bookID)
        #endif
    }

    private func toggleLikedCurrent() {
        guard let songID = player.currentSong?.id else { return }
        library.toggleLiked(songID: songID)
    }

    private func presentImmersiveLyrics() {
        if fullscreenPlayerEffect == .native {
            withAnimation(.easeInOut(duration: 0.3)) {
                showLyrics = true
                isLyricsImmersive = true
                immersiveControlsState = immersiveControlsState.applying(.present)
            }
            scheduleImmersiveControlsAutoHide()
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                isFullscreenPlayerPresented = true
            }
        }
    }

    private func applyFullscreenEffectPresentation(_ effect: FullscreenPlayerEffect) {
        if effect == .native, isFullscreenPlayerPresented {
            withAnimation(.easeInOut(duration: 0.24)) {
                isFullscreenPlayerPresented = false
                showLyrics = true
                isLyricsImmersive = true
                immersiveControlsState = immersiveControlsState.applying(.present)
            }
            scheduleImmersiveControlsAutoHide()
        } else if effect != .native, isLyricsImmersive {
            immersiveControlsAutoHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.24)) {
                isLyricsImmersive = false
                immersiveControlsState = immersiveControlsState.applying(.dismiss)
                isFullscreenPlayerPresented = true
            }
        }
    }

    private func dismissFullscreenPlayer() {
        guard isFullscreenPlayerPresented else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFullscreenPlayerPresented = false
        }
    }

    private func minimizeFullscreenPlayer() {
        guard isFullscreenPlayerPresented else { return }
        dismissFullscreenPlayer()
        onMinimize?()
    }

    /// 分享页打开期间可能已经换歌：海报取的是当前这首的歌词，只在分享的还是它时才给入口。
    private func canShareLyricPoster(for song: Song) -> Bool {
        player.currentSong?.id == song.id && !lyrics.isEmpty
    }

    private func presentLyricPosterRequestedFromShare() {
        guard presentsLyricPosterAfterShare else { return }
        presentsLyricPosterAfterShare = false
        presentLyricPoster(anchorLineID: nil)
    }

    /// 打开歌词海报。`anchorLineID` 来自长按的那一句; 从分享页进入时
    /// 为 nil, 由策略按当前播放位置定位。
    /// 手选过款式就用手选的;从没选过时,用当前界面皮肤带来的那一款。
    private var initialLyricPosterStyleID: LyricPosterStyleID? {
        if !lyricPosterStyleRawValue.isEmpty {
            return LyricPosterStyleID(lyricPosterStyleRawValue)
        }
        return skin.skin.companions.preferredLyricPosterStyleID.map { LyricPosterStyleID($0) }
    }

    private func presentLyricPoster(anchorLineID: String?) {
        guard let song = player.currentSong else { return }
        let composer = LyricPosterComposer.make(
            song: song,
            lyrics: lyrics,
            translations: lyricTranslationsByLineID,
            playbackPosition: player.currentTime,
            anchorLineID: anchorLineID,
            writingDirection: lyricsWritingDirection,
            styleID: initialLyricPosterStyleID,
            canvas: LyricPosterCanvas(rawValue: lyricPosterCanvasRawValue),
            prefersMotion: lyricPosterPrefersMotion,
            includesTranslation: lyricPosterIncludesTranslation,
            showsCredit: lyricPosterShowsCredit,
            filterID: lyricPosterFilterRawValue.isEmpty
                ? nil
                : LyricPosterFilterID(lyricPosterFilterRawValue),
            motionEffectID: lyricPosterMotionEffectRawValue.isEmpty
                ? nil
                : LyricPosterMotionEffectID(lyricPosterMotionEffectRawValue),
            noteSignature: lyricPosterSignature
        )
        // 整首都是空行时没有可分享的内容, 静默返回好过弹一张空海报。
        guard !composer.lines.isEmpty else { return }
        lyricPosterComposer = composer
    }

    private func dismissImmersiveLyrics() {
        immersiveControlsAutoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) {
            isLyricsImmersive = false
            immersiveControlsState = immersiveControlsState.applying(.dismiss)
        }
    }

    private func setStandardLyricsVisible(_ isVisible: Bool) {
        // 能分栏的画布(内屏横握)上歌词在右栏:点封面打开右栏的歌词,而不是在播放器里换成歌词。
        if isVisible, isPlayerSplit {
            selectSidePane(showsQueue: false)
            return
        }
        immersiveControlsAutoHideTask?.cancel()
        withAnimation(standardLyricsAnimation) {
            showLyrics = isVisible
            isLyricsImmersive = false
            immersiveControlsState = immersiveControlsState.applying(.dismiss)
        }
    }

    private func toggleStandardLyrics() {
        setStandardLyricsVisible(!showLyrics)
    }

    private func handleImmersiveContentTap() {
        withAnimation(.easeInOut(duration: 0.2)) {
            immersiveControlsState = immersiveControlsState.applying(.contentTap)
        }
        if immersiveControlsState.isVisible {
            scheduleImmersiveControlsAutoHide()
        } else {
            immersiveControlsAutoHideTask?.cancel()
        }
    }

    private func lockImmersiveControls() {
        immersiveControlsAutoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            immersiveControlsState = immersiveControlsState.applying(.lock)
        }
    }

    private func unlockImmersiveControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            immersiveControlsState = immersiveControlsState.applying(.unlock)
        }
        scheduleImmersiveControlsAutoHide()
    }

    private func scheduleImmersiveControlsAutoHide() {
        immersiveControlsAutoHideTask?.cancel()
        #if DEBUG && os(iOS)
        // 取证页里控件一直留着，截图才看得到它们与内容的关系。
        if debugPlayerMode != nil { return }
        #endif
        guard isVisualSceneActive,
              isLyricsImmersive,
              immersiveControlsState.isVisible,
              !showsImmersiveEffectPicker else { return }
        immersiveControlsAutoHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isVisualSceneActive,
                  isLyricsImmersive,
                  !showsImmersiveEffectPicker else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                immersiveControlsState = immersiveControlsState.applying(.autoHide)
            }
        }
    }

    private func nowPlayingActionIcon(
        symbol: String,
        tint: Color,
        isSelected: Bool = false
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 38, height: 38)
            .background(appearance.primary.opacity(isSelected ? 0.10 : 0.065), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(appearance.primary.opacity(isSelected ? 0.24 : 0.14), lineWidth: 0.75)
            }
    }


    /// Top safe area height (dynamic island / status bar)
    private var topSafeArea: CGFloat {
        #if os(iOS)
        windowSafeAreaInsets.top
        #else
        // macOS 没有 dynamic island / 状态栏 safe area, 标题栏由窗口 chrome
        // 负责, NowPlayingView 内容直接顶到窗口客户区上沿即可。
        0
        #endif
    }

    private var bottomSafeArea: CGFloat {
        #if os(iOS)
        windowSafeAreaInsets.bottom
        #else
        0
        #endif
    }

    private func resolvedSafeAreaInsets(for geo: GeometryProxy) -> EdgeInsets {
        #if os(iOS)
        let windowInsets = windowSafeAreaInsets
        let logicalLeading = layoutDirection == .rightToLeft
            ? windowInsets.right
            : windowInsets.left
        let logicalTrailing = layoutDirection == .rightToLeft
            ? windowInsets.left
            : windowInsets.right
        return EdgeInsets(
            top: max(geo.safeAreaInsets.top, windowInsets.top),
            leading: max(geo.safeAreaInsets.leading, logicalLeading),
            bottom: max(geo.safeAreaInsets.bottom, windowInsets.bottom),
            trailing: max(geo.safeAreaInsets.trailing, logicalTrailing)
        )
        #else
        return geo.safeAreaInsets
        #endif
    }

    /// 系统竖栏的设备(iPhone Duo)上,播放页这种沉浸式、不滚动的界面按整屏居中,只让开遮挡区
    /// (竖排的状态栏与前置摄像头),见 HIG「Designing for iPhone Duo」。其它设备与 Xcode 27.0 构建为 false,
    /// 照旧按安全区排。
    private var centersOnFullScreen: Bool {
        #if os(iOS)
        verticalBarEdge != nil
        #else
        false
        #endif
    }

    /// 竖屏布局左右各让多少。不居中时就是安全区(按侧取值);整屏居中时:
    /// 封面宽度不超过「两边都不碰遮挡区」的上限,封面下面几行只在灵动岛长到它们那段高度时才两边一起让,
    /// 歌词模式的歌词与顶栏是会滚动 / 贴边的内容,在遮挡那一侧让开。
    private func portraitInsets(
        geo: GeometryProxy,
        safeInsets: EdgeInsets,
        occlusions: [OcclusionAvoidancePolicy.Region],
        keepsClearOf toolColumnEdge: HorizontalEdge? = nil
    ) -> NowPlayingPortraitInsets {
        // 竖栏里排着播放页自己那一列按钮时,竖栏那一条不再空着:播放器按安全区排在另一侧,
        // 和标签页里内容与系统竖栏的关系一样。
        guard centersOnFullScreen, toolColumnEdge == nil else {
            return NowPlayingPortraitInsets(
                containerLeading: safeInsets.leading,
                containerTrailing: safeInsets.trailing,
                artworkSize: min(geo.size.width - 60, geo.size.height * 0.38),
                mediaWidthLimit: .infinity,
                rows: 0,
                lyricsLeading: 0,
                lyricsTrailing: 0
            )
        }
        let width = Double(geo.size.width)
        let height = Double(geo.size.height)
        // 把手那一段:上安全区 + 6 + 5 + 10。
        let artworkTop = Double(topSafeArea) + 21
        let preferred = min(geo.size.width - 60, geo.size.height * 0.38)
        let limit = CGFloat(OcclusionAvoidancePolicy.centeredWidthLimit(
            regions: occlusions,
            bandMinY: artworkTop,
            bandMaxY: artworkTop + Double(preferred),
            width: width,
            gap: 16
        ))
        let artworkSize = max(0, min(preferred, limit))
        let rows = OcclusionAvoidancePolicy.sideClearance(
            regions: occlusions,
            bandMinY: artworkTop + Double(artworkSize),
            bandMaxY: height,
            width: width
        ).larger
        let lyrics = OcclusionAvoidancePolicy.sideClearance(
            regions: occlusions,
            bandMinY: 0,
            bandMaxY: height,
            width: width
        )
        let topRow = OcclusionAvoidancePolicy.sideClearance(
            regions: occlusions,
            bandMinY: 0,
            bandMaxY: Double(max(topSafeArea, 10) + 8 + 44),
            width: width
        )
        let lowest = OcclusionAvoidancePolicy.lowestEdge(of: occlusions)
        return NowPlayingPortraitInsets(
            containerLeading: 0,
            containerTrailing: 0,
            artworkSize: artworkSize,
            mediaWidthLimit: limit,
            rows: CGFloat(rows),
            lyricsLeading: CGFloat(lyrics.leading),
            lyricsTrailing: CGFloat(lyrics.trailing),
            immersiveContentTop: lowest > 0 ? CGFloat(lowest) + 8 : 0,
            immersiveTopRowLeading: CGFloat(topRow.leading),
            immersiveTopRowTrailing: CGFloat(topRow.trailing)
        )
    }

    // MARK: - iPhone Duo 内屏:分栏与桌面半折

    /// 常规宽度的 iPhone 画布(Duo 内屏)上播放页怎么排。只在有 `ArrangementView` 的构建与系统上、
    /// iPhone 上、非紧凑高度、不在放 MV / 全屏歌词时生效;其它情况返回 nil,走原来的版式
    /// (Xcode 27.0 构建里内屏横握是放大的手机横屏骨架)。
    private func playerArrangement(
        geo: GeometryProxy,
        landscapeMode: NowPlayingLandscapeMode
    ) -> NowPlayingArrangement? {
        guard PMArrangement.isAvailable || debugForcesArrangement,
              isPhoneCanvas,
              sizeClass == .regular,
              !heightClass.isCompact,
              !player.isMusicVideoPlaybackActive,
              landscapeMode == .none || landscapeMode == .standardLyrics
        else { return nil }
        // 桌面半折:折痕横在屏幕中间(上半屏立着、下半屏平放在桌上)。
        if let fold = activeFolds(in: geo).first(where: { $0.width > $0.height }),
           geo.size.height > geo.size.width {
            return .tabletop(foldMinY: CGFloat(fold.minY), foldMaxY: CGFloat(fold.maxY))
        }
        let canSplit = geo.size.width > geo.size.height
        // 右栏收起时不留分栏:`ArrangementView` 次视图为空也照样占着半屏,播放器会停在左半边。
        // 改走内屏不分栏时那副按内屏放大的横屏骨架,整屏排开;歌词、接下来播放键照旧打开右栏。
        if canSplit && sidePaneHidden { return nil }
        return .split(canSplit: canSplit)
    }

    /// 这块画布能不能左右分栏(右栏收着也算):队列键、歌词键据此开合右栏,而不是在同一栏里切换。
    private func playerCanSplit(geo: GeometryProxy, landscapeMode: NowPlayingLandscapeMode) -> Bool {
        guard !player.isLiveRadio,
              PMArrangement.isAvailable || debugForcesArrangement,
              isPhoneCanvas,
              sizeClass == .regular,
              !heightClass.isCompact,
              !player.isMusicVideoPlaybackActive,
              landscapeMode == .none || landscapeMode == .standardLyrics,
              geo.size.width > geo.size.height
        else { return false }
        return !activeFolds(in: geo).contains { $0.width > $0.height }
    }

    private var debugForcesArrangement: Bool {
        #if DEBUG
        debugFoldAxis != nil
        #else
        false
        #endif
    }

    private func activeFolds(in geo: GeometryProxy) -> [OcclusionAvoidancePolicy.Region] {
        var folds = PMReservedRegions.activeDivisions(in: geo)
        #if DEBUG
        // 取证页模拟半折:折痕宽 20,在正中间。
        switch debugFoldAxis {
        case .horizontal:
            folds.append(.init(x: 0, y: Double(geo.size.height) / 2 - 10, width: Double(geo.size.width), height: 20))
        case .vertical:
            folds.append(.init(x: Double(geo.size.width) / 2 - 10, y: 0, width: 20, height: Double(geo.size.height)))
        case nil:
            break
        }
        #endif
        return folds
    }

    /// 分栏(横握):左边是播放器(封面 + 控件,和外屏同一副竖版),右边是歌词或「接下来播放」;
    /// 右栏关着时播放器占满整幅,半折成书本时 `ArrangementView` 让分界对齐折痕。
    /// 竖握摊平时 `ArrangementView` 只显示播放器,歌词照旧在同一栏里切换。
    @ViewBuilder
    private func arrangedPlayerLayout(
        geo: GeometryProxy,
        arrangement: NowPlayingArrangement,
        safeInsets: EdgeInsets,
        usesToolColumn: Bool = false
    ) -> some View {
        switch arrangement {
        case .split(let canSplit):
            let showsSidePane = canSplit && !sidePaneHidden
            PMHorizontalArrangement {
                GeometryReader { pane in
                    let insets = portraitInsets(geo: pane, safeInsets: EdgeInsets(), occlusions: [])
                    portraitLayout(
                        geo: pane,
                        artSize: insets.artworkSize,
                        insets: insets,
                        lyricsInline: canSplit ? false : showLyrics,
                        usesToolColumn: usesToolColumn
                    )
                }
                // 内屏横握时系统竖栏在一侧：两栏各自只让开自己那一侧的安全区。
                .padding(.leading, safeInsets.leading)
                .padding(.trailing, showsSidePane ? 0 : safeInsets.trailing)
            } secondary: {
                if showsSidePane {
                    nowPlayingSidePane
                        .padding(.trailing, safeInsets.trailing)
                        .pmLayoutSwitchFade()
                        .transition(.opacity)
                }
            }
            .transition(PMLayoutSwitchTransition())
        case .tabletop(let foldMinY, let foldMaxY):
            tabletopPlayerLayout(geo: geo, foldMinY: foldMinY, foldMaxY: foldMaxY)
                .transition(PMLayoutSwitchTransition())
        }
    }

    /// 分栏时的右栏:顶上一排切换「歌词 / 接下来播放」和收起键,下面是歌词或队列本身。
    private var nowPlayingSidePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(selection: Binding(
                    get: { showLyrics ? 0 : 1 },
                    set: { selectSidePane(showsQueue: $0 == 1) }
                )) {
                    Text("lyrics_title").tag(0)
                    Text("up_next").tag(1)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Spacer(minLength: 0)

                Button {
                    closeSidePane()
                } label: {
                    Label("close", systemImage: "sidebar.trailing")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(appearance.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // 与左栏把手的上沿对齐。
            .padding(.top, topSafeArea + 12)
            .padding(.horizontal, 24)

            ZStack {
                if !showLyrics {
                    QueueView(player: player, isEmbedded: true)
                        .scrollContentBackground(.hidden)
                        .pmAppearFade(.contentAppear)
                } else {
                    lyricsFullView
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, bottomSafeArea)
        .overlay(alignment: .leading) {
            // 两栏之间一道很淡的分隔,和 iPad 横屏那套一样。
            Rectangle()
                .fill(appearance.divider)
                .frame(width: 1)
                .padding(.vertical, 40)
        }
    }

    private func selectSidePane(showsQueue: Bool) {
        withAnimation(standardLyricsAnimation) {
            sidePaneHidden = false
            showLyrics = !showsQueue
            isLyricsImmersive = false
        }
    }

    private func closeSidePane() {
        withAnimation(standardLyricsAnimation) {
            sidePaneHidden = true
            // 收起后整屏排开的是封面那一副;下次从歌词键或接下来播放键打开时再选右栏看哪一页。
            showLyrics = false
            isLyricsImmersive = false
        }
    }

    /// 队列键:分栏时打开右栏的「接下来播放」(已经在看就收起右栏),其它时候弹出半屏队列。
    private func openQueue() {
        guard isPlayerSplit else {
            showQueue = true
            return
        }
        if !sidePaneHidden, !showLyrics {
            closeSidePane()
        } else {
            selectSidePane(showsQueue: true)
        }
    }

    /// 歌词键:分栏时打开右栏的歌词(已经在看就收起右栏),其它时候在同一栏里切歌词。
    private func toggleLyricsForLayout() {
        guard isPlayerSplit else {
            toggleStandardLyrics()
            return
        }
        if !sidePaneHidden, showLyrics {
            closeSidePane()
        } else {
            selectSidePane(showsQueue: false)
        }
    }

    // MARK: - iPhone Duo 竖栏里的那一列

    /// 正在生效的遮挡区(竖排状态栏、前置摄像头)。取证框模拟有竖栏的视口时,按系统那一条的样子
    /// 在尾侧摆一块(框里读到的是外屏自己的遮挡区,位置对不上)。
    private func playerOcclusions(in geo: GeometryProxy) -> [OcclusionAvoidancePolicy.Region] {
        guard centersOnFullScreen else { return [] }
        #if DEBUG && os(iOS)
        if debugSuppressesVerticalBar {
            let width = Double(geo.size.width)
            return [
                .init(x: width - 84, y: 0, width: 84, height: 150),
                .init(x: width - 60.5, y: 24, width: 37, height: 37),
            ]
        }
        #endif
        return PMReservedRegions.activeOcclusions(in: geo)
    }

    /// 播放页这副构图要不要把次要操作排进系统竖栏那一列(iPhone Duo 外屏竖握 / 横握、内屏横握),
    /// 要的话在哪一侧。全屏歌词、全屏效果、MV 横屏、电台、桌面半折各有自己的控件,不排;
    /// 没有竖栏(普通 iPhone、iPad、Xcode 27.0 构建)时恒为 nil。
    private func barToolColumnEdge(
        arrangement: NowPlayingArrangement?,
        usesSkeleton: Bool,
        landscapeMode: NowPlayingLandscapeMode,
        layoutMode: NowPlayingPlayerLayoutMode
    ) -> HorizontalEdge? {
        #if os(iOS)
        guard let verticalBarEdge,
              !player.isLiveRadio,
              !isFullscreenPlayerPresented,
              !(showLyrics && isLyricsImmersive)
        else { return nil }
        if let arrangement {
            if case .split = arrangement { return verticalBarEdge }
            return nil
        }
        if usesSkeleton { return verticalBarEdge }
        switch landscapeMode {
        case .none:
            return layoutMode == .portrait ? verticalBarEdge : nil
        case .musicVideo:
            return player.musicVideoPlayer == nil ? verticalBarEdge : nil
        case .immersiveLyrics, .standardLyrics:
            return nil
        }
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// 播放页的次要操作(收起播放页 · 歌词 / 右栏、接下来播放 · 喜欢、投放、全屏效果、更多)排成竖栏那一列:
    /// 和系统竖栏同一套玻璃胶囊分组,对准前置摄像头的中线,从竖排状态栏下面开始;外屏横握时在左侧。
    /// 播放器这边只留封面、歌名、进度与传输键。高度不够(外屏横握)时每颗按钮一起缩一点,一个不少。
    private func barToolColumn(
        edge: HorizontalEdge,
        geo: GeometryProxy,
        safeInsets: EdgeInsets,
        occlusions: [OcclusionAvoidancePolicy.Region],
        offersLock: Bool
    ) -> some View {
        let width = Double(geo.size.width)
        let isRight = (edge == .trailing) == (layoutDirection == .leftToRight)
        let barWidth = Double(edge == .trailing ? safeInsets.trailing : safeInsets.leading)
        let band = isRight ? (width - max(barWidth, 60))...width : 0...max(barWidth, 60)
        let barRegions = occlusions.filter { $0.maxX > band.lowerBound && $0.minX < band.upperBound }
        // 摄像头是这一条里最小的那块遮挡区;系统竖栏的按钮就对着它的中线。
        let camera = barRegions.min { $0.width * $0.height < $1.width * $1.height }
        let centerX = camera.map { $0.minX + $0.width / 2 }
            ?? (isRight ? width - max(barWidth, 60) / 2 : max(barWidth, 60) / 2)
        let top = max(barRegions.map(\.maxY).max() ?? 0, Double(topSafeArea)) + 12
        let bottom = Double(bottomSafeArea) + 12
        let music = !usesSpokenWordTransport
        let groups = [
            1,
            2,
            (music ? 2 : 0) + 2 + (offersLock ? 1 : 0),
        ]
        let itemCount = Double(groups.reduce(0, +))
        let spacing = 12.0
        let capsulePadding = 4.0
        let fixed = spacing * Double(groups.count - 1) + capsulePadding * 2 * Double(groups.count)
        let available = Double(geo.size.height) - top - bottom
        let itemSize = CGFloat(min(44, max(34, ((available - fixed) / max(itemCount, 1)).rounded(.down))))
        let lyricsSelected = isPlayerSplit ? (!sidePaneHidden && showLyrics) : showLyrics
        let queueSelected = isPlayerSplit && !sidePaneHidden && !showLyrics

        return VStack(spacing: CGFloat(spacing)) {
            if isCompactLandscapeLocked {
                // 横屏锁上之后这一列只剩解锁键,控件照旧留在原位不挪。
                barColumnGroup {
                    Button {
                        isCompactLandscapeLocked = false
                    } label: {
                        NowPlayingBarColumnIcon(symbol: "lock.open.fill", appearance: appearance, size: itemSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("immersive_unlock_controls"))
                }
            } else {
                barColumnGroup {
                    Button {
                        onMinimize?()
                    } label: {
                        NowPlayingBarColumnIcon(symbol: "chevron.down", appearance: appearance, size: itemSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("mini_player"))
                }

                barColumnGroup {
                    Button {
                        toggleLyricsForLayout()
                    } label: {
                        NowPlayingBarColumnIcon(
                            symbol: "quote.bubble",
                            appearance: appearance,
                            size: itemSize,
                            tint: themedControlAccent,
                            isSelected: lyricsSelected
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(lyricsSelected ? "a11y_close_lyrics" : "a11y_open_lyrics"))

                    Button {
                        openQueue()
                    } label: {
                        NowPlayingBarColumnIcon(
                            symbol: "list.bullet",
                            appearance: appearance,
                            size: itemSize,
                            tint: themedControlAccent,
                            isSelected: queueSelected
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("a11y_queue"))
                }

                barColumnGroup {
                    // 「我喜欢」是音乐歌单, 有声内容不出现。
                    if music {
                        Button {
                            toggleLikedCurrent()
                        } label: {
                            NowPlayingBarColumnIcon(
                                symbol: isCurrentLiked ? "heart.fill" : "heart",
                                appearance: appearance,
                                size: itemSize,
                                tint: .red,
                                isSelected: isCurrentLiked
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(player.currentSong == nil)
                        .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                    }

                    AirPlayButton()
                        .frame(width: itemSize * 0.62, height: itemSize * 0.62)
                        .frame(width: itemSize, height: itemSize)

                    if music {
                        immersiveEffectButton(glass: .barColumn(itemSize: itemSize))
                    }

                    if offersLock {
                        Button {
                            immersiveControlsAutoHideTask?.cancel()
                            isCompactLandscapeLocked = true
                        } label: {
                            NowPlayingBarColumnIcon(symbol: "lock", appearance: appearance, size: itemSize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("immersive_lock_controls"))
                    }

                    makeMoreMenu(immersiveChrome: true, chromeGlass: .barColumn(itemSize: itemSize))
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, CGFloat(top))
        .padding(.bottom, CGFloat(bottom))
        .frame(width: itemSize + CGFloat(capsulePadding) * 2 + 8)
        .position(x: CGFloat(centerX), y: geo.size.height / 2)
        .frame(width: geo.size.width, height: geo.size.height)
        .pmAnimation(.control, value: isCompactLandscapeLocked)
    }

    /// 竖栏那一列里的一组按钮,竖着排在同一个玻璃胶囊里(和系统竖栏的分组一样)。
    @ViewBuilder
    private func barColumnGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let stack = VStack(spacing: 0) { content() }
            .padding(4)
        if #available(iOS 26.0, *) {
            stack.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            stack.nowPlayingAdaptiveGlass(Capsule(), appearance: appearance, tint: appearance.primary)
        }
    }
    #endif

    /// 桌面半折:上半屏立着、离人远,放封面(开着歌词时放歌词);下半屏平放在桌上、手够得着,
    /// 放歌名、进度与全部控件。同一个播放页换个排法,控件与其它形态一样一个不少。
    /// 队列里不止一首时,下半屏控件上方再横排一条「接下来播放」的封面,左右滑直接切歌。
    private func tabletopPlayerLayout(geo: GeometryProxy, foldMinY: CGFloat, foldMaxY: CGFloat) -> some View {
        let topHeight = max(0, foldMinY)
        let artworkSide = max(0, min(geo.size.width - 96, topHeight - topSafeArea - 44))
        #if os(iOS)
        let showsQueueStrip = player.queueCount > 1 && !player.isMusicVideoPlaybackActive
        #else
        let showsQueueStrip = false
        #endif
        // 下半屏放不下封面条时音量条先让位(与手机横屏骨架的让步顺序一致)，音量键照样能调。
        let showsVolumeRow = showsPlayerVolumeBar
            && !(showsQueueStrip && geo.size.height - foldMaxY < 560)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule()
                    .fill(appearance.tertiary)
                    .frame(width: 48, height: 5)
                    .padding(.top, topSafeArea + 6)
                    .padding(.bottom, 10)
                    .pmLayoutSwitchFade()
                ZStack {
                    if showLyrics {
                        lyricsFullView
                            .padding(.horizontal, 24)
                            .pmLayoutSwitchFade()
                            .transition(lyricsPanelTransition)
                    } else {
                        artworkOrMusicVideo(size: artworkSide, cornerRadius: 16)
                            .scaleEffect(artworkAppearsPlaying ? 1.0 : 0.92)
                            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: artworkAppearsPlaying)
                            .onTapGesture { setStandardLyricsVisible(true) }
                            .transition(playerArtworkTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 12)
            }
            .frame(height: topHeight)

            Color.clear
                .frame(height: max(0, foldMaxY - foldMinY))

            VStack(spacing: 0) {
                #if os(iOS)
                if showsQueueStrip {
                    // 吃掉下半屏控件以外的高度；放不下一张像样的封面时自己不显示。
                    TabletopQueueStrip(player: player)
                        .padding(.top, 14)
                        .frame(maxHeight: .infinity)
                        .pmLayoutSwitchFade()
                }
                #endif
                nowPlayingSongHeader(titleFont: .title2, metadataFont: .body)
                    .matchedLayoutElement(.songHeading, in: layoutNamespace)
                    .padding(.horizontal, 36)
                    .padding(.top, 18)
                PlaybackProgressBar(fillTint: themedControlAccent)
                    .matchedLayoutElement(.progress, in: layoutNamespace)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)
                portraitTransportRow
                    .matchedLayoutElement(.transport, in: layoutNamespace)
                    .padding(.top, 10)
                    .padding(.horizontal, 24)
                if showsVolumeRow {
                    playerVolumeRow
                        .padding(.horizontal, 36)
                        .padding(.top, 10)
                        .pmLayoutSwitchFade()
                }
                if !showsQueueStrip {
                    Spacer(minLength: 0)
                }
                portraitBottomBar
                    .padding(.top, showsQueueStrip ? 6 : 0)
                    .padding(.bottom, bottomSafeArea)
                    .pmLayoutSwitchFade()
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// iPad 横屏(regular size class + 宽 > 高)启用左右双栏 —— 左封面 + 控件,
    /// 右常驻歌词。其它(iPhone / iPad 竖屏 / 分屏小窗 compact)还走原来的
    /// 上下结构,showLyrics 切歌词 / 封面模式。
    private func shouldUseWideLayout(geo: GeometryProxy) -> Bool {
        // Plus / Pro Max 横屏也是常规宽度，只看宽度等级会把手机横屏送进 iPad 的
        // 两栏布局——那套尺寸是按整屏高度标定的，落在三四百点的高度上就是压扁的旧样子。
        // iPhone Duo 展开的内屏同理：常规宽高，但仍走手机的横屏骨架。
        NowPlayingPlayerLayoutPolicy.prefersWideColumns(
            isRegularWidth: sizeClass == .regular,
            isCompactHeight: heightClass.isCompact,
            isPhone: isPhoneCanvas
        ) && geo.size.width > geo.size.height
    }

    /// iPhone（含 iPhone Duo 的内外屏）。取证页在框里模拟内屏时由环境值给出。
    private var isPhoneCanvas: Bool {
        #if os(iOS)
        isPhoneIdiomEnvironment || UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// iPhone 上常规宽度、常规高度的横屏（iPhone Duo 内屏横握）：横屏骨架按内屏放大。
    private var usesExpandedLandscapeCanvas: Bool {
        isPhoneCanvas && sizeClass == .regular && !heightClass.isCompact
    }

    private func playerMinimizeDragGesture(
        containerWidth: CGFloat,
        verticalStartMaximumY: CGFloat
    ) -> some Gesture {
        // The player moves with this gesture, so a local coordinate space would
        // also move under the finger and feed the offset back into translation.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                let isRTL = layoutDirection == .rightToLeft
                if activeMinimizeDragStartLocation != value.startLocation {
                    activeMinimizeDragStartLocation = value.startLocation
                    activeMinimizeDragAxis = nil
                }
                let startDistance = NowPlayingDismissGesturePolicy.distanceFromLeadingEdge(
                    startX: Double(value.startLocation.x),
                    containerWidth: Double(containerWidth),
                    layoutIsRightToLeft: isRTL
                )
                let towardCenter = NowPlayingDismissGesturePolicy.translationTowardCenter(
                    translationX: Double(value.translation.width),
                    layoutIsRightToLeft: isRTL
                )
                let axis = activeMinimizeDragAxis
                    ?? NowPlayingDismissGesturePolicy.recognizedAxis(
                        startY: Double(value.startLocation.y),
                        startDistanceFromLeadingEdge: startDistance,
                        translationTowardCenter: towardCenter,
                        translationY: Double(value.translation.height),
                        verticalStartMaximumY: Double(verticalStartMaximumY)
                    )
                guard let axis else { return }
                activeMinimizeDragAxis = axis

                switch axis {
                case .horizontal:
                    onLeadingMinimizeDragChanged?(CGFloat(max(0, towardCenter)))
                case .vertical:
                    onTopMinimizeDragChanged?(max(0, value.translation.height))
                }
            }
            .onEnded { value in
                let axis = activeMinimizeDragAxis
                activeMinimizeDragAxis = nil
                activeMinimizeDragStartLocation = nil
                guard let axis else { return }

                let isRTL = layoutDirection == .rightToLeft
                let startDistance = NowPlayingDismissGesturePolicy.distanceFromLeadingEdge(
                    startX: Double(value.startLocation.x),
                    containerWidth: Double(containerWidth),
                    layoutIsRightToLeft: isRTL
                )
                let towardCenter = NowPlayingDismissGesturePolicy.translationTowardCenter(
                    translationX: Double(value.translation.width),
                    layoutIsRightToLeft: isRTL
                )
                let predictedTowardCenter = NowPlayingDismissGesturePolicy.translationTowardCenter(
                    translationX: Double(value.predictedEndTranslation.width),
                    layoutIsRightToLeft: isRTL
                )

                switch axis {
                case .horizontal:
                    let shouldDismiss = NowPlayingDismissGesturePolicy.shouldDismissFromLeadingEdge(
                        startX: startDistance,
                        translationX: towardCenter,
                        translationY: Double(value.translation.height),
                        predictedEndTranslationX: predictedTowardCenter
                    )
                    if let onLeadingMinimizeDragEnded {
                        onLeadingMinimizeDragEnded(shouldDismiss)
                    } else if shouldDismiss {
                        onMinimize?()
                    }
                case .vertical:
                    let shouldDismiss = NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                        startY: Double(value.startLocation.y),
                        translationX: Double(value.translation.width),
                        translationY: Double(value.translation.height),
                        predictedEndTranslationY: Double(value.predictedEndTranslation.height),
                        maximumStartY: Double(verticalStartMaximumY)
                    )
                    if let onTopMinimizeDragEnded {
                        onTopMinimizeDragEnded(shouldDismiss)
                    } else if shouldDismiss {
                        onMinimize?()
                    }
                }
            }
    }

    var body: some View {
        GeometryReader { geo in
            let safeInsets = resolvedSafeAreaInsets(for: geo)
            // 系统竖栏的设备(iPhone Duo)上播放页整屏居中,只让开遮挡区;其它设备这里恒为空。
            let occlusions = playerOcclusions(in: geo)
            let verticalDismissStartMaximumY = showLyrics
                ? CGFloat(NowPlayingDismissGesturePolicy.topStartMaximumY)
                : max(
                    CGFloat(NowPlayingDismissGesturePolicy.topStartMaximumY),
                    geo.size.height * 0.62
                )
            let landscapeMode = NowPlayingLandscapePolicy.mode(
                viewportWidth: Double(geo.size.width),
                viewportHeight: Double(geo.size.height),
                isMusicVideoActive: player.isMusicVideoPlaybackActive,
                areLyricsVisible: showLyrics,
                areLyricsImmersive: isLyricsImmersive
            )
            let playerLayoutMode = NowPlayingPlayerLayoutPolicy.mode(
                viewportWidth: Double(geo.size.width),
                viewportHeight: Double(geo.size.height),
                prefersWideColumns: shouldUseWideLayout(geo: geo)
            )
            // 手机横屏的封面模式、歌词模式与全屏歌词共用一副骨架：放在同一个分支里，切歌词时
            // 顶部圆钮排、进度条、传输键都保持同一个视图身份、留在原位，只有左栏换内容。
            // 分到 switch 的几个 case 里，整页会被当成几棵树换掉。
            let usesCompactLandscapeSkeleton = NowPlayingPlayerLayoutPolicy.usesLandscapeSkeleton(
                layoutMode: playerLayoutMode,
                landscapeMode: landscapeMode
            )
            let arrangement = player.isLiveRadio ? nil : playerArrangement(geo: geo, landscapeMode: landscapeMode)
            let canSplit = playerCanSplit(geo: geo, landscapeMode: landscapeMode)
            // iPhone Duo 竖栏:播放页的次要操作排进竖栏那一列,播放器留在另一侧(见 `barToolColumn`)。
            let toolColumnEdge = barToolColumnEdge(
                arrangement: arrangement,
                usesSkeleton: usesCompactLandscapeSkeleton,
                landscapeMode: landscapeMode,
                layoutMode: playerLayoutMode
            )
            let portraitLayoutInsets = portraitInsets(
                geo: geo,
                safeInsets: safeInsets,
                occlusions: occlusions,
                keepsClearOf: toolColumnEdge
            )
            let artSize = portraitLayoutInsets.artworkSize
            // 按尺寸选的是哪一副构图。它变了(开合、转屏)就让封面等主元素滑到新位置、其余淡入。
            let canvasKey = NowPlayingCanvasKey(layoutMode: playerLayoutMode, arrangement: arrangement)

            ZStack {
                #if os(iOS)
                WindowSafeAreaInsetsReader { insets in
                    var insets = insets
                    #if DEBUG
                    if let debugViewportSafeArea { insets = debugViewportSafeArea }
                    #endif
                    guard insets != windowSafeAreaInsets else { return }
                    windowSafeAreaInsets = insets
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                // 常亮租约挂在这个常驻的零尺寸视图上：播放页是当前展示面就持有，
                // 收成迷你条或整页消失就释放。
                .playerScreenWakeLease(
                    isVisible: isPresentationSettled && isPresentationActive,
                    sceneIsActive: isVisualSceneActive
                )
                #endif

                // 歌词翻译由这层常驻的零尺寸视图负责，歌词面板与全屏舞台只读结果。
                // 全屏打开时普通播放页整棵树会被卸载：任务若挂在歌词面板上，进全屏
                // 就会被取消，全屏里切歌也没有人再算新一首的译文，只能退出再进。
                // 只在歌词真的展示在某处时才挂上，封面模式不去请求翻译。
                if showLyrics || isFullscreenPlayerPresented {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .lyricsTranslationTaskIfAvailable(
                            songID: player.currentSong?.id,
                            lyricsRevision: lyricsRevision,
                            lyrics: lyrics,
                            settings: LyricsTranslationSettingsStore.shared,
                            translatedTextByLineID: $lyricTranslationsByLineID,
                            activity: $lyricsTranslationActivity
                        )
                }

                if !isFullscreenPlayerPresented {
                    ZStack {
                        // Opaque base — prevents content bleeding through
                        // 两层底色在换构图那一次立刻铺满新尺寸，不随换构图的动画慢慢长大(换歌时的取色过渡照旧)。
                        appearance.backgroundBase.ignoresSafeArea()
                            .animation(nil, value: canvasKey)
                        // Dynamic background from cover colors — fully opaque
                        backgroundGradient.ignoresSafeArea()
                            .animation(nil, value: canvasKey)

                        // 每套布局都经 NowPlayingDeferredContent 推迟构造，别直接内联回来：
                        // Debug 构建下这里会把主线程的栈吃满（见那个类型的说明）。
                        if player.isLiveRadio {
                            NowPlayingDeferredContent {
                                liveRadioLayout(geo: geo, safeInsets: safeInsets, occlusions: occlusions)
                            }
                        } else if let arrangement {
                            NowPlayingDeferredContent {
                                arrangedPlayerLayout(
                                    geo: geo,
                                    arrangement: arrangement,
                                    safeInsets: safeInsets,
                                    usesToolColumn: toolColumnEdge != nil
                                )
                            }
                            .transition(PMLayoutSwitchTransition())
                        } else if usesCompactLandscapeSkeleton {
                            NowPlayingDeferredContent {
                                compactLandscapePlayerLayout(
                                    geo: geo,
                                    safeInsets: safeInsets,
                                    occlusions: occlusions,
                                    toolColumnEdge: toolColumnEdge
                                )
                            }
                            .transition(PMLayoutSwitchTransition())
                        } else {
                            switch landscapeMode {
                            case .musicVideo:
                                if let videoPlayer = player.musicVideoPlayer {
                                    NowPlayingDeferredContent {
                                        landscapeMusicVideoLayout(videoPlayer: videoPlayer, safeInsets: safeInsets)
                                    }
                                } else {
                                    NowPlayingDeferredContent {
                                        portraitLayout(
                                            geo: geo,
                                            artSize: artSize,
                                            insets: portraitLayoutInsets,
                                            usesToolColumn: toolColumnEdge != nil
                                        )
                                    }
                                }
                            case .immersiveLyrics:
                                NowPlayingDeferredContent {
                                    immersiveLandscapeLyricsLayout(geo: geo)
                                }
                            case .standardLyrics:
                                NowPlayingDeferredContent {
                                    standardLandscapeLyricsLayout(geo: geo)
                                }
                                .transition(lyricsPanelTransition)
                            case .none:
                                switch playerLayoutMode {
                                case .portrait:
                                    NowPlayingDeferredContent {
                                        portraitLayout(
                                            geo: geo,
                                            artSize: artSize,
                                            insets: portraitLayoutInsets,
                                            usesToolColumn: toolColumnEdge != nil
                                        )
                                    }
                                    .transition(PMLayoutSwitchTransition())
                                case .compactLandscape:
                                    NowPlayingDeferredContent {
                                        compactLandscapePlayerLayout(
                                            geo: geo,
                                            safeInsets: safeInsets,
                                            occlusions: occlusions,
                                            toolColumnEdge: toolColumnEdge
                                        )
                                    }
                                    .transition(PMLayoutSwitchTransition())
                                case .wideLandscape:
                                    NowPlayingDeferredContent {
                                        wideLandscapeLayout(geo: geo, safeInsets: safeInsets)
                                    }
                                }
                            }
                        }

                        #if os(iOS)
                        // iPhone Duo 竖栏里那一列:换构图(分栏 ⇄ 收起右栏 ⇄ 转屏)时同一个身份留在竖栏里。
                        if let toolColumnEdge {
                            barToolColumn(
                                edge: toolColumnEdge,
                                geo: geo,
                                safeInsets: safeInsets,
                                occlusions: occlusions,
                                offersLock: arrangement == nil && usesCompactLandscapeSkeleton
                            )
                            .transition(.opacity)
                        }
                        #endif
                    }
                    .onChange(of: canSplit, initial: true) { _, split in
                        isPlayerSplit = split
                    }
                    // 开合、转屏换构图(竖版 / 横屏骨架 / iPad 双栏 / Duo 内屏分栏与半折)时，封面、歌名、
                    // 进度条与传输键从旧位置滑到新位置，其余元素淡入；播放页进场途中不算。
                    .pmLayoutSwitchAnimation(canvasKey, isEnabled: isPresentationSettled)
                    .contentShape(Rectangle())
                    // 横屏锁上、或者效果抽屉开着的时候，整页不再响应最小化手势：
                    // 前者是锁的语义，后者是抽屉之外的一切都只该用来收起抽屉。
                    .simultaneousGesture(
                        playerMinimizeDragGesture(
                            containerWidth: geo.size.width,
                            verticalStartMaximumY: verticalDismissStartMaximumY
                        ),
                        including: suppressesPlayerMinimizeGesture ? .subviews : .all
                    )
                    .transition(.opacity)
                }

                #if os(iOS)
                if isFullscreenPlayerPresented {
                    ImmersivePlayerView(
                        effect: fullscreenPlayerEffectBinding,
                        lyrics: lyrics,
                        lyricCompanions: {
                            LyricsScrollView.companionTexts(
                                for: $0,
                                translatedTextByLineID: lyricTranslationsByLineID
                            )
                        },
                        lyricsWritingDirection: lyricsWritingDirection,
                        isResolvingLyrics: isResolvingLyrics,
                        isSceneActive: isVisualSceneActive,
                        onDismiss: dismissFullscreenPlayer,
                        onMinimize: minimizeFullscreenPlayer,
                        onShowQueue: { showQueue = true },
                        occlusions: occlusions
                    )
                    .zIndex(100)
                }

                // 全屏播放器自带一份抽屉，这里只服务播放页本身的两个入口。
                if showsImmersiveEffectPicker, !isFullscreenPlayerPresented {
                    // 抽屉之外点一下就收起 —— 全屏里这件事是舞台的点击处理做的，
                    // 普通模式底下没有那一层。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showsImmersiveEffectPicker = false }
                        .accessibilityHidden(true)
                        .zIndex(60)

                    immersiveEffectDrawer(geo: geo, safeInsets: safeInsets)
                        .pmSlideTransition(
                            edge: ImmersiveEffectDrawer.transitionEdge(for: geo.size),
                            motion: .panel
                        )
                        .zIndex(61)
                }
                #endif
            }
        }
        .onAppear { FullscreenPlayerEffectSync.shared.install() }
        #if DEBUG
        // 编译机截图用:`PRIMUSE_DEBUG_FULLSCREEN=1` 时播放页打开三秒后进全屏(沉浸歌词或当前全屏效果)。
        .task {
            guard ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_FULLSCREEN"] == "1" else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            presentImmersiveLyrics()
        }
        #endif
        #if DEBUG && os(iOS)
        .task {
            // 取证页让播放页一出现就处在歌词 / 全屏歌词模式。真机上无人值守截图用
            // `PRIMUSE_DEBUG_PLAYER_MODE`(同样的取值,另有 `queueSheet`:弹出半屏的接下来播放)。
            switch debugPlayerMode ?? ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PLAYER_MODE"] {
            case "lyrics":
                showLyrics = true
            case "immersive":
                showLyrics = true
                isLyricsImmersive = true
                immersiveControlsState = .presented
            case "queue":
                showLyrics = false
                sidePaneHidden = false
            case "collapsed":
                // 分栏收起右栏之后的样子。
                showLyrics = false
                sidePaneHidden = true
            case "queueSheet":
                try? await Task.sleep(for: .seconds(1))
                showQueue = true
            default:
                break
            }
        }
        #endif
        .onChange(of: isVisualSceneActive) { _, isActive in
            if isActive {
                if isLyricsImmersive, immersiveControlsState.isVisible {
                    scheduleImmersiveControlsAutoHide()
                }
            } else {
                immersiveControlsAutoHideTask?.cancel()
                activeMinimizeDragAxis = nil
                activeMinimizeDragStartLocation = nil
            }
        }
        .onChange(of: showsImmersiveEffectPicker) { _, isPresented in
            if isPresented {
                immersiveControlsAutoHideTask?.cancel()
            } else if isLyricsImmersive, immersiveControlsState.isVisible {
                scheduleImmersiveControlsAutoHide()
            }
        }
        // 盯生效值而不是存储值:在皮肤带来的效果里亲手选回「原生」时,存储值并没有变。
        .onChange(of: fullscreenPlayerEffect) { _, effect in
            applyFullscreenEffectPresentation(effect)
        }
        .task(id: initialLyricsLoadIdentity) {
            guard isPresentationSettled else { return }
            consumeAutomaticScrapeCompletion()
            // 换歌就丢掉上一首的译文: 翻译任务没挂着时(封面模式)它不会自己清空,
            // 从"更多"菜单做海报会带上一首的翻译。
            lyricTranslationsByLineID = [:]
            if player.isLiveRadio {
                clearLyricsResolution()
                lyrics = []
            } else {
                await loadLyrics()
            }
            consumeAutomaticScrapeCompletion()
        }
        .onChange(of: scraperService.singleScrapeCompletionRevision) { _, _ in
            consumeAutomaticScrapeCompletion()
        }
        .sheet(isPresented: $showQueue) {
            QueueView(player: player)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showChapterList) {
            ChapterListView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #if os(iOS)
        .sheet(
            item: $presentedAlbum,
            onDismiss: { albumPresentationSourceID = nil }
        ) { album in
            albumDetailPresentation(album)
        }
        .sheet(item: $presentedBook) { route in
            NavigationStack {
                SpokenWordBookDetailView(bookID: route.id)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        #endif
        .sheet(item: $scrapeTargetSong) { song in
            ScrapeOptionsView(song: song) { u in
                CachedArtworkView.invalidateCache(for: u.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
                player.syncSongMetadata(u)
                player.forceRefreshNowPlayingArtwork()
                Task { await loadLyrics() }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.currentSong {
                AddToPlaylistSheet(song: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $shareSong, onDismiss: { presentLyricPosterRequestedFromShare() }) { song in
            SongShareSheet(
                song: song,
                onShareLyricPoster: canShareLyricPoster(for: song)
                    ? { presentsLyricPosterAfterShare = true }
                    : nil
            )
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = player.currentSong {
                SongInfoSheet(song: song)
                    .songInfoPresentationStyle()
            }
        }
        .sheet(isPresented: $showTagEditor) {
            if let song = player.currentSong {
                TagEditorView(song: song) { updated in
                    // 元数据变更后,封面缓存可能 stale; 同步路径由 PrimuseApp
                    // 监听 songReplacementToken 统一处理 player / theme,
                    // 这里只重拉歌词(标题改了可能影响 LRC 命中)。
                    Task { await loadLyrics() }
                    _ = updated
                }
                .presentationDetents([.large])
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showKaraoke) {
            KaraokeStageView()
        }
        #else
        .sheet(isPresented: $showKaraoke) {
            KaraokeStageView()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(item: $lyricsEditorTargetSong) { song in
            LyricsEditorSheet(
                song: song,
                autoStartsAudioTranscription: lyricsEditorAutoStartsAudioTranscription
            ) { updated in
                // 编辑期间若已经自然切歌，不要用旧歌的落盘结果刷新新歌歌词。
                guard player.currentSong?.id == updated.id else { return }
                Task { await loadLyrics() }
            }
        }
        #else
        .sheet(item: $lyricsEditorTargetSong) { song in
            LyricsEditorSheet(
                song: song,
                autoStartsAudioTranscription: lyricsEditorAutoStartsAudioTranscription
            ) { updated in
                // 编辑期间若已经自然切歌，不要用旧歌的落盘结果刷新新歌歌词。
                guard player.currentSong?.id == updated.id else { return }
                Task { await loadLyrics() }
            }
            .presentationDetents([.large])
        }
        #endif
        .sheet(item: $lyricPosterComposer) { composer in
            LyricPosterShareSheet(composer: composer)
                #if os(macOS)
                .presentationDetents([.large])
                #endif
        }
        .similarSongsPanel(isPresented: $showSimilarSongs, seed: player.currentSong)
        .sheet(isPresented: $showCastPicker) {
            CastDevicePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #if os(iOS)
        .fullScreenCover(
            isPresented: $showMusicVideoFullScreen,
            onDismiss: finishMusicVideoFullScreenDismissal
        ) {
            if let videoPlayer = fullScreenMusicVideoPlayer ?? player.musicVideoPlayer {
                MusicVideoFullScreenView(player: videoPlayer) {
                    dismissMusicVideoFullScreen()
                }
            } else {
                Color.black
                    .ignoresSafeArea()
            }
        }
        .onChange(of: player.isMusicVideoPlaybackActive) { _, active in
            if active, let videoPlayer = player.musicVideoPlayer {
                fullScreenMusicVideoPlayer = videoPlayer
            } else {
                dismissMusicVideoFullScreenIfNeeded()
            }
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            if player.isMusicVideoPlaybackActive, let videoPlayer = player.musicVideoPlayer {
                fullScreenMusicVideoPlayer = videoPlayer
            } else {
                dismissMusicVideoFullScreenIfNeeded()
            }
        }
        .onChange(of: player.isMusicVideoModeEnabled) { _, enabled in
            // 独立 MV 不受模式开关影响(始终播视频), 关模式不退全屏
            if !enabled, player.currentSong?.isStandaloneMusicVideo != true {
                dismissMusicVideoFullScreen()
            }
        }
        .onChange(of: player.musicVideoAudioFallbackToken) { _, _ in
            dismissMusicVideoFullScreen()
        }
        #endif
        .sheet(item: Binding(
            get: { radioDetailStationID.map(RadioDetailSheetID.init) },
            set: { radioDetailStationID = $0?.id }
        )) { item in
            RadioStationDetailView(stationID: item.id)
        }
        .confirmationDialog(String(localized: "sleep_timer"), isPresented: $showSleepTimer) {
            // 三种收听各有各的「到哪儿停」:电台只有分钟数,有声多出本章、本集、整本。
            ForEach(sleepTimerOptions, id: \.self) { option in
                sleepTimerOptionButton(option)
            }
            if player.isSleepTimerActive {
                Button(String(localized: "cancel_timer"), role: .destructive) { player.cancelSleep() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .medleyDataUsageConfirmation(pendingSongs: $pendingMedleySongs) { songs in
            Task { await player.playMedley(songs) }
        }
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(
                   get: { scrapeAlertMessage != nil },
                   set: { if !$0 { scrapeAlertMessage = nil } }
               )) {
            Button("done", role: .cancel) {}
        } message: {
            Text(scrapeAlertMessage ?? "")
        }
        .alert(
            String(localized: "lyrics_reload_from_source"),
            isPresented: Binding(
                get: { sourceLyricsReloadAlertMessage != nil },
                set: { if !$0 { sourceLyricsReloadAlertMessage = nil } }
            )
        ) {
            Button("done", role: .cancel) {}
        } message: {
            Text(sourceLyricsReloadAlertMessage ?? "")
        }
        .alert(String(localized: "delete_song"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "delete"), role: .destructive) {
                deleteCurrentSong()
            }
        } message: {
            Text(String(localized: "delete_song_message"))
        }
        .alert(
            String(localized: "delete_song_failed_title"),
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        .onChange(of: lyricsFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
        }
        .onChange(of: showLyrics) { _, isVisible in
            if !isVisible, isLyricsImmersive {
                dismissImmersiveLyrics()
            }
        }
        .onDisappear {
            immersiveControlsAutoHideTask?.cancel()
        }
        // Handoff —— 用户在当前设备播,旁边的 Mac / iPad 在 Spotlight / 任务
        // 切换器底部出现"在 Primuse 中继续"的 chip。打开后通过 ContentView
        // 的 onContinueUserActivity 拿到完整队列上下文,在另一台设备上无缝接
        // 着播下去 (同一首歌、同样的队列顺序、相同的播放位置、同样的播放/
        // 暂停状态)。
        //
        // 队列截 50 首是 payload size 安全垫: NSUserActivity userInfo 总
        // 大小 ~128KB,单 song.id (SHA256 hex) 64 字符,50 首 ~3.2KB,余量
        // 充裕。窗口以 currentIndex 为基准 (前 5 首上下文 + 之后 45 首),
        // 保证当前歌一定在 payload 内, 超出的尾部由 receiver 进入队列后下一
        // 首靠 setQueue 自然推进继续 ── 主接力点是当前歌 + 接下来几首。
        .userActivity(
            "com.welape.yuanyin.nowplaying",
            isActive: player.currentSong != nil && !player.isLiveRadio
        ) { activity in
            guard let song = player.currentSong, !player.isLiveRadio else { return }
            let by = library.artistDisplayName(for: song).map { " — \($0)" } ?? ""
            activity.title = "\(song.title)\(by)"
            activity.isEligibleForHandoff = true
            // 不把 song.id 暴露给搜索 / 公开索引,handoff 直接拿去就好
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false

            // 以 currentIndex 为基准取窗口而非整队列前 50 首: 长队列后段接力
            // 时, 整队前缀里根本不含当前歌, receiver 会找不到 songID 落入兜底
            // (整库从头播)。这里保证当前歌 + 接下来几首都在 payload 里 ——
            // 当前歌前 5 首给点上下文, 之后 45 首是真正的接力窗口。
            let queueIDs = handoffQueueIDs()
            activity.userInfo = [
                "songID": song.id,
                "queueIDs": queueIDs,
                // currentTime + snapshotTime 一起记录, receiver 用 (now -
                // snapshot) 推算"如果还在播,实际应该到哪里了",避免接力
                // 时听见同一段刚播过的内容。
                "currentTime": player.handoffPlaybackTimeSnapshot(),
                "snapshotTime": Date().timeIntervalSinceReferenceDate,
                "isPlaying": player.isPlaying,
                "shuffleEnabled": player.shuffleEnabled,
                "repeatMode": player.repeatMode.rawValue,
            ]
            activity.requiredUserInfoKeys = ["songID"]
        }
    }

    @ViewBuilder
    private func liveRadioLayout(
        geo: GeometryProxy,
        safeInsets: EdgeInsets,
        occlusions: [OcclusionAvoidancePolicy.Region] = []
    ) -> some View {
        let preferredArtworkSize = min(geo.size.width * (geo.size.width > geo.size.height ? 0.30 : 0.72), 430)
        // 整屏居中(iPhone Duo)时台标在遮挡区那段高度里两边都不碰它;其它设备不设限。
        let artworkSize = min(preferredArtworkSize, CGFloat(OcclusionAvoidancePolicy.centeredWidthLimit(
            regions: occlusions,
            bandMinY: Double(topSafeArea) + 11,
            bandMaxY: Double(topSafeArea + 11 + preferredArtworkSize),
            width: Double(geo.size.width),
            gap: 16
        )))

        VStack(spacing: 0) {
            Capsule()
                .fill(appearance.tertiary)
                .frame(width: 48, height: 5)
                .padding(.top, topSafeArea + 6)

            if let error = player.lastPlaybackError {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.82), in: Capsule())
                    .padding(.top, 14)
                    .pmSlideTransition(edge: .top, motion: .list)
            }

            // 台标只吃文字和控件之外剩下的高度。只按宽度取值时，iPhone Duo 外屏、
            // 内屏分屏半幅这类宽而矮的窗口会把底部控件顶出屏幕。
            GeometryReader { artworkGeometry in
                let fittedSize = min(artworkSize, artworkGeometry.size.height - 42)
                if let station = player.currentRadioStation, fittedSize >= 48 {
                    RadioStationArtworkView(
                        station: station,
                        size: fittedSize,
                        cornerRadius: max(18, fittedSize * 0.06)
                    )
                    .shadow(color: .black.opacity(0.34), radius: 28, y: 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            VStack(spacing: 8) {
                Text(player.currentRadioStation?.name ?? player.currentSong?.title ?? "")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)

                Text(player.radioMetadataTitle ?? currentArtistDisplayName)
                    .font(.body)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                HStack(spacing: 7) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("live_badge")
                        .font(.caption.weight(.bold))
                    if player.currentTime > 0 {
                        Text("·")
                        Text(player.currentTime.formattedDuration)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(appearance.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel(Text("radio_live"))
            }
            .padding(.horizontal, 32)

            HStack(spacing: 38) {
                Button {
                    Task { await player.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .disabled(!player.canSwitchRadioStation)
                .accessibilityLabel(Text("radio_previous_station"))

                Button { player.togglePlayPause() } label: {
                    Image(systemName: (player.isPlaying || player.isLoading) ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 68))
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(Text((player.isPlaying || player.isLoading) ? "radio_stop" : "a11y_play"))

                Button {
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .disabled(!player.canSwitchRadioStation)
                .accessibilityLabel(Text("radio_next_station"))
            }
            .foregroundStyle(appearance.primary)
            .padding(.top, 24)

            if showsPlayerVolumeBar {
                playerVolumeRow
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 36)
                    .padding(.top, 18)
            }

            HStack(spacing: 10) {
                AirPlayButton()
                    .frame(width: 36, height: 36)
                Text(radioTechnicalSummary)
                    .font(.caption2)
                    .foregroundStyle(appearance.faint)
                if let url = player.currentRadioStation?.url {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(Text("share"))
                }
                if let stationID = player.currentRadioStation?.id {
                    Button {
                        radioDetailStationID = stationID
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .frame(width: 36, height: 36)
                    }
                    .foregroundStyle(appearance.secondary)
                    .accessibilityLabel(Text("radio_detail_heard_title"))
                }
                radioSleepTimerButton
            }
            .padding(.top, 10)
            .padding(.bottom, max(bottomSafeArea, 16))
        }
        // 侧边安全区按侧取值，内容不会压到侧置系统控件或摄像头区域下面。
        // 整屏居中(iPhone Duo)时两侧都是 0,只由台标让开遮挡区。
        .padding(.leading, centersOnFullScreen ? 0 : safeInsets.leading)
        .padding(.trailing, centersOnFullScreen ? 0 : safeInsets.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sleepTimerOptions: [SleepTimerOption] {
        let space = player.currentListeningSpace ?? .music
        return SleepTimerOptionPolicy.options(for: space, hasChapters: player.hasChapters)
    }

    @ViewBuilder
    private func sleepTimerOptionButton(_ option: SleepTimerOption) -> some View {
        switch option {
        case .minutes(let minutes):
            Button("\(minutes) " + String(localized: "minutes")) { player.scheduleSleep(minutes: minutes) }
        case .endOfTrack:
            if player.currentListeningSpace == .spokenWord {
                Button(String(localized: "sleep_at_item_end")) { player.scheduleSleepAtTrackEnd() }
            } else {
                Button(String(localized: "sleep_at_track_end")) { player.scheduleSleepAtTrackEnd() }
                    .disabled(player.currentSong == nil)
            }
        case .endOfChapter:
            Button(String(localized: "sleep_at_chapter_end")) { player.scheduleSleepAtChapterEnd() }
                .disabled(player.currentChapterIndex == nil)
        case .endOfBook:
            Button(String(localized: "sleep_at_book_end")) { player.scheduleSleepAtBookEnd() }
        }
    }

    /// 电台没有曲终可等，睡眠定时是这里唯一的自动停止手段。歌曲布局把它收在
    /// 更多菜单里，电台布局没有那个菜单，所以直接摆进底部工具行。
    private var radioSleepTimerButton: some View {
        Button {
            showSleepTimer = true
        } label: {
            if let endDate = player.sleepTimerEndDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining: TimeInterval = max(0, endDate.timeIntervalSince(context.date))
                    HStack(spacing: 4) {
                        Image(systemName: "moon.zzz.fill")
                        Text(remaining.formattedDuration)
                            .font(.caption2.monospacedDigit())
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            } else {
                Image(systemName: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                    .frame(width: 36, height: 36)
            }
        }
        .foregroundStyle(player.isSleepTimerActive ? themedControlAccent : appearance.secondary)
        .accessibilityLabel(Text(
            player.isSleepTimerActive
                ? String(localized: "sleep_timer_active")
                : String(localized: "sleep_timer")
        ))
    }

    private var radioTechnicalSummary: String {
        var parts: [String] = [player.radioStreamFormat.displayName]
        if let bitRate = player.radioBitRate, bitRate > 0 {
            parts.append("\(bitRate / 1_000) kbps")
        }
        return parts.joined(separator: " · ")
    }

    private var playerVolumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(appearance.tertiary)
            #if os(iOS) && !targetEnvironment(simulator)
            SystemVolumeSlider()
                .frame(maxWidth: .infinity)
                .frame(height: SystemVolumeSlider.compactHeight)
                .offset(y: SystemVolumeSlider.verticalOffset)
            #elseif os(macOS)
            // 和底栏、迷你播放器共用同一套音量语义：高保真直通时交给输出设备
            // 硬件音量，其余情况走应用增益。各处各写一份曾让这里在高保真下
            // 读到恒为 1 的值，拖完立刻弹回。
            PMPlaybackVolumeSlider(tint: themedControlAccent)
            #else
            VolumeSlider(value: Binding(
                get: { Double(player.audioEngine.userVolume) },
                set: { player.setPlaybackVolume(Float($0)) }
            ))
            #endif
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(appearance.tertiary)
        }
        // Keep the route-owned MPVolumeView stable when switching between
        // artwork and lyrics without suppressing the player's entrance spring.
        .animation(nil, value: showLyrics)
    }

    // MARK: - Compact phone landscape

    /// 手机横屏的普通模式：顶部一排玻璃圆钮 + 左侧大封面 + 右栏信息与传输键。
    ///
    /// 竖屏那套控件直接压进右栏会把封面挤到只剩两百来点、字号全压到 `.headline`，
    /// 所以这里换成独立构图。所有几何都由 `NowPlayingCompactLandscapeLayoutPolicy`
    /// 给出，视图层不再自己散着算。
    ///
    /// 歌词模式是同一副骨架：左栏的大封面换成歌词、缩成右栏顶上的小封面，圆钮排、
    /// 进度条和传输键原地不动。原先歌词模式另起一套顶栏，再用一块悬浮面板放进度条
    /// 和传输键 —— 面板压在歌词上，圆钮排里的锁定 / 队列 / 投放 / 全屏也都没了。
    private func compactLandscapePlayerLayout(
        geo: GeometryProxy,
        safeInsets windowInsets: EdgeInsets,
        occlusions: [OcclusionAvoidancePolicy.Region] = [],
        toolColumnEdge: HorizontalEdge? = nil
    ) -> some View {
        // 系统竖栏的设备(iPhone Duo 外屏横握)上两栏整屏居中:两侧只留固定内边距,顶部圆钮排
        // 与歌词栏顶端单独让开遮挡区;封面落进遮挡区时策略会退回按安全区让位。其它设备原样。
        // 竖栏里排着播放页那一列按钮时,顶部这一排圆钮都在那一列里,两栏排在另一侧;内屏(收起右栏之后)
        // 宽度富余,两栏整屏居中、两侧都让出竖栏那么宽,封面不贴另一侧的屏幕边。
        let usesToolColumn = toolColumnEdge != nil
        let columnSide = max(windowInsets.leading, windowInsets.trailing)
        let safeInsets = usesToolColumn
            ? (usesExpandedLandscapeCanvas
                ? EdgeInsets(top: windowInsets.top, leading: columnSide, bottom: windowInsets.bottom, trailing: columnSide)
                : windowInsets)
            : compactLandscapeSafeInsets(geo: geo, windowInsets: windowInsets, occlusions: occlusions)
        let metrics = compactLandscapeMetrics(geo: geo, safeInsets: safeInsets)
        let lyricsMetrics = compactLandscapeLyricsMetrics(geo: geo, safeInsets: safeInsets)
        let chromeClearance = OcclusionAvoidancePolicy.sideClearance(
            regions: occlusions,
            bandMinY: metrics.topInset,
            bandMaxY: metrics.topInset + metrics.chromeRowHeight,
            width: Double(geo.size.width)
        )
        let chromeLeading = chromeClearance.leading > 0
            ? max(0, CGFloat(chromeClearance.leading + metrics.chromeBottomSpacing - metrics.leadingInset))
            : 0
        let chromeTrailing = chromeClearance.trailing > 0
            ? max(0, CGFloat(chromeClearance.trailing + metrics.chromeBottomSpacing - metrics.trailingInset))
            : 0
        let lyricsPaneTop = compactLandscapeLyricsPaneTopClearance(
            occlusions: occlusions,
            metrics: metrics,
            lyricsMetrics: lyricsMetrics
        )
        // 两端的随机 / 循环摆不摆得下，两种模式的右栏宽度不同，各算各的。
        let showsEdgeToggles = showLyrics
            ? lyricsMetrics.showsEdgeToggles
            : metrics.showsEdgeToggles

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                // 顶部圆钮排占位：圆钮本身画在上层，锁上之后换成解锁胶囊，
                // 下面的内容不跟着挪。圆钮排进了竖栏那一列时不占这一行。
                Color.clear
                    .frame(height: usesToolColumn ? 0 : CGFloat(metrics.chromeRowHeight + metrics.chromeBottomSpacing))

                compactLandscapeColumns(
                    metrics: metrics,
                    lyricsMetrics: lyricsMetrics,
                    lyricsPaneTopClearance: lyricsPaneTop
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!isCompactLandscapeLocked)

            if !usesToolColumn {
                compactLandscapeChromeLayer
                    .pmLayoutSwitchFade()
                    .padding(.leading, chromeLeading)
                    .padding(.trailing, chromeTrailing)
                    .opacity(compactLandscapeControlsHidden ? 0 : 1)
                    .allowsHitTesting(!compactLandscapeControlsHidden)
                    .accessibilityHidden(compactLandscapeControlsHidden)
            }
        }
        .padding(.leading, CGFloat(metrics.leadingInset))
        .padding(.trailing, CGFloat(metrics.trailingInset))
        .padding(.top, CGFloat(metrics.topInset))
        .padding(.bottom, CGFloat(metrics.bottomInset))
        .overlay {
            // 全屏歌词里控件淡出之后，点任意处叫回来（与竖屏全屏歌词同一套状态）。
            if compactLandscapeControlsHidden {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleImmersiveContentTap() }
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: showsEdgeToggles, initial: true) { _, showsToggles in
            compactLandscapeHidesModeToggles = !showsToggles
        }
        .onAppear {
            // 竖屏全屏歌词里锁上之后转到横屏：锁换成这副骨架自己的那把，解锁入口留在原位。
            if immersiveControlsState.isLocked {
                isCompactLandscapeLocked = true
                immersiveControlsState = immersiveControlsState.applying(.unlock)
            }
        }
        .onDisappear {
            // 转回竖屏、进沉浸歌词、进全屏效果、播放页收起都会走到这里。
            isCompactLandscapeLocked = false
            compactLandscapeHidesModeToggles = false
        }
    }

    private func compactLandscapeSafeInsets(
        geo: GeometryProxy,
        windowInsets: EdgeInsets,
        occlusions: [OcclusionAvoidancePolicy.Region]
    ) -> EdgeInsets {
        guard centersOnFullScreen else { return windowInsets }
        let sides = NowPlayingCompactLandscapeLayoutPolicy.centeredSideSafeArea(
            viewportWidth: Double(geo.size.width),
            viewportHeight: Double(geo.size.height),
            safeAreaTop: Double(windowInsets.top),
            safeAreaBottom: Double(windowInsets.bottom),
            safeAreaLeading: Double(windowInsets.leading),
            safeAreaTrailing: Double(windowInsets.trailing),
            occlusions: occlusions,
            prefersVolumeBar: showsPlayerVolumeBar,
            textScale: compactLandscapeTextScale
        )
        return EdgeInsets(
            top: windowInsets.top,
            leading: CGFloat(sides.leading),
            bottom: windowInsets.bottom,
            trailing: CGFloat(sides.trailing)
        )
    }

    /// 歌词栏在遮挡区下面才开始:只在它横向碰到遮挡区时把栏顶往下挪到遮挡区下沿。
    private func compactLandscapeLyricsPaneTopClearance(
        occlusions: [OcclusionAvoidancePolicy.Region],
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics,
        lyricsMetrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics
    ) -> CGFloat {
        guard !occlusions.isEmpty else { return 0 }
        let paneTop = metrics.topInset + metrics.chromeRowHeight + metrics.chromeBottomSpacing
        let paneMinX = metrics.leadingInset
        let paneMaxX = paneMinX + lyricsMetrics.lyricsPaneWidth
        let bottom = occlusions
            .filter { $0.maxX > paneMinX && $0.minX < paneMaxX && $0.maxY > paneTop }
            .map(\.maxY)
            .max()
        guard let bottom else { return 0 }
        return CGFloat(bottom + metrics.chromeBottomSpacing - paneTop)
    }

    private func compactLandscapeMetrics(
        geo: GeometryProxy,
        safeInsets: EdgeInsets
    ) -> NowPlayingCompactLandscapeLayoutPolicy.Metrics {
        NowPlayingCompactLandscapeLayoutPolicy.metrics(
            viewportWidth: Double(geo.size.width),
            viewportHeight: Double(geo.size.height),
            safeAreaTop: Double(safeInsets.top),
            safeAreaBottom: Double(safeInsets.bottom),
            safeAreaLeading: Double(safeInsets.leading),
            safeAreaTrailing: Double(safeInsets.trailing),
            prefersVolumeBar: showsPlayerVolumeBar,
            textScale: compactLandscapeTextScale,
            isExpandedCanvas: usesExpandedLandscapeCanvas
        )
    }

    private func compactLandscapeLyricsMetrics(
        geo: GeometryProxy,
        safeInsets: EdgeInsets
    ) -> NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics {
        NowPlayingCompactLandscapeLayoutPolicy.lyricsMetrics(
            viewportWidth: Double(geo.size.width),
            viewportHeight: Double(geo.size.height),
            safeAreaTop: Double(safeInsets.top),
            safeAreaBottom: Double(safeInsets.bottom),
            safeAreaLeading: Double(safeInsets.leading),
            safeAreaTrailing: Double(safeInsets.trailing),
            prefersVolumeBar: showsPlayerVolumeBar,
            textScale: compactLandscapeTextScale
        )
    }

    /// 动态字号等级折算成策略要的字号倍率。折算表在策略里，视图层只负责把
    /// `DynamicTypeSize` 换成它在 `allCases` 里的下标；读不出来就按默认档。
    private var compactLandscapeTextScale: Double {
        let index = DynamicTypeSize.allCases.firstIndex(of: dynamicTypeSize)
        return NowPlayingCompactLandscapeLayoutPolicy.textScale(
            forDynamicTypeIndex: index ?? 3
        )
    }

    /// 横屏骨架里的全屏歌词：与竖屏全屏歌词一样，控件过几秒淡出，只留歌词和右栏顶上的小封面、歌名；
    /// 点一下叫回来。控件原地淡出，不挪位置。
    private var compactLandscapeControlsHidden: Bool {
        showLyrics && isLyricsImmersive && !isCompactLandscapeLocked && !immersiveControlsState.isVisible
    }

    /// 锁上、或者效果抽屉开着的时候，播放页整体不再接最小化拖拽。
    private var suppressesPlayerMinimizeGesture: Bool {
        isCompactLandscapeLocked || showsImmersiveEffectPicker
    }

    private func compactLandscapeColumns(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics,
        lyricsMetrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics,
        lyricsPaneTopClearance: CGFloat = 0
    ) -> some View {
        let leftColumnWidth = CGFloat(
            showLyrics ? lyricsMetrics.lyricsPaneWidth : metrics.artworkColumnWidth
        )
        return HStack(alignment: .center, spacing: CGFloat(metrics.columnSpacing)) {
            // 封面和歌词叠在同一个定宽槽位里换场。直接并排放进 HStack 的话，过渡期间
            // 两个都在，右栏会被挤到只剩几个点再弹回来。
            ZStack {
                if showLyrics {
                    compactLandscapeLyricsPane(metrics: lyricsMetrics)
                        .padding(.top, lyricsPaneTopClearance)
                        .pmLayoutSwitchFade()
                        .transition(lyricsPanelTransition)
                } else {
                    compactLandscapeArtwork(metrics: metrics)
                        .transition(playerArtworkTransition)
                }
            }
            .frame(width: leftColumnWidth)
            .frame(maxHeight: .infinity)

            compactLandscapeDetailColumn(metrics: metrics, lyricsMetrics: lyricsMetrics)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactLandscapeArtwork(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics
    ) -> some View {
        let artworkSize = CGFloat(metrics.artworkSize)
        return artworkOrMusicVideo(size: artworkSize, cornerRadius: 18)
            .scaleEffect(artworkAppearsPlaying ? 1 : 0.96)
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.75),
                value: artworkAppearsPlaying
            )
            .onTapGesture { setStandardLyricsVisible(true) }
            .frame(width: CGFloat(metrics.artworkColumnWidth))
    }

    /// 歌词栏。滚动、淡出遮罩、点空白处回封面都是 `LyricsScrollView` 自己的，
    /// 这里只给它一块不会被任何控件压住的地方。
    private func compactLandscapeLyricsPane(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics
    ) -> some View {
        lyricsFullView
            .frame(width: CGFloat(metrics.lyricsPaneWidth))
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func compactLandscapeDetailColumn(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics,
        lyricsMetrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics
    ) -> some View {
        let showsEdgeToggles = showLyrics
            ? lyricsMetrics.showsEdgeToggles
            : metrics.showsEdgeToggles
        let showsVolumeBar = showLyrics
            ? lyricsMetrics.showsVolumeBar
            : metrics.showsVolumeBar

        VStack(alignment: .leading, spacing: 0) {
            // 两种模式只有这一块不同。叠在 ZStack 里换场，下面的进度条和传输键
            // 不会因为过渡期间多出一块而被顶下去。
            ZStack(alignment: .topLeading) {
                if showLyrics {
                    compactLandscapeLyricsHeader(metrics: lyricsMetrics)
                        .transition(lyricsHeaderTransition)
                } else {
                    compactLandscapeCoverHeading(metrics: metrics)
                        .matchedLayoutElement(.songHeading, in: layoutNamespace)
                        .transition(.opacity)
                }
            }

            PlaybackProgressBar(fillTint: themedControlAccent)
                .matchedLayoutElement(.progress, in: layoutNamespace)
                .padding(.top, CGFloat(NowPlayingCompactLandscapeLayoutPolicy.progressTopSpacing))
                .opacity(compactLandscapeControlsHidden ? 0 : 1)
                .allowsHitTesting(!compactLandscapeControlsHidden)
                .accessibilityHidden(compactLandscapeControlsHidden)

            compactLandscapeTransportRow(showsEdgeToggles: showsEdgeToggles)
                .matchedLayoutElement(.transport, in: layoutNamespace)
                .padding(.top, CGFloat(NowPlayingCompactLandscapeLayoutPolicy.transportTopSpacing))
                // 锁上时控件留在原位只是不再显示，右栏不会因为少一行而整体上移。
                .opacity(isCompactLandscapeLocked || compactLandscapeControlsHidden ? 0 : 1)
                .allowsHitTesting(!compactLandscapeControlsHidden)
                .accessibilityHidden(isCompactLandscapeLocked || compactLandscapeControlsHidden)
                .pmAnimation(.control, value: isCompactLandscapeLocked)

            if showsVolumeBar {
                playerVolumeRow
                    .pmLayoutSwitchFade()
                    .padding(.top, CGFloat(NowPlayingCompactLandscapeLayoutPolicy.volumeTopSpacing))
                    .opacity(isCompactLandscapeLocked || compactLandscapeControlsHidden ? 0 : 1)
                    .allowsHitTesting(!compactLandscapeControlsHidden)
                    .accessibilityHidden(isCompactLandscapeLocked || compactLandscapeControlsHidden)
                    .pmAnimation(.control, value: isCompactLandscapeLocked)
            }
        }
        // 左栏是定宽的，右栏吃掉剩下的空间：策略算出来的 detailColumnWidth
        // 正好是这个余量，这样写不会因为浮点余数差那么零点几点而被挤压。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 封面模式右栏的上半截：大歌名、艺人 / 专辑、当前歌词行。
    @ViewBuilder
    private func compactLandscapeCoverHeading(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            compactLandscapeTitle(lineLimit: metrics.titleLineLimit)

            compactLandscapeArtistRow
                .padding(.top, CGFloat(NowPlayingCompactLandscapeLayoutPolicy.titleBottomSpacing))

            if metrics.showsLyricLine {
                compactLandscapeLyricLine(metrics: metrics)
                    .padding(.top, CGFloat(NowPlayingCompactLandscapeLayoutPolicy.lyricLineTopSpacing))
            }
        }
    }

    /// 歌词模式右栏的上半截：小封面 + 歌名 / 艺人，整块点一下回封面模式。
    /// 大封面经 matchedGeometryEffect 缩到这张小封面的位置，和竖屏歌词头部是同一套。
    private func compactLandscapeLyricsHeader(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics
    ) -> some View {
        let thumbnail = CGFloat(metrics.thumbnailSize)
        return Button { setStandardLyricsVisible(false) } label: {
            HStack(
                alignment: .center,
                spacing: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.lyricsHeaderSpacing)
            ) {
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: thumbnail,
                    cornerRadius: 12,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath,
                    fileFormat: player.currentSong?.fileFormat,
                    fillsProposedSize: true,
                    revisionToken: player.coverRevision
                )
                .artworkCrossfade()
                .matchedGeometryEffect(
                    id: lyricsArtworkTransitionID,
                    in: lyricsArtworkNamespace,
                    isSource: isLyricsCompactArtworkVisible
                )
                .frame(width: thumbnail, height: thumbnail)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentSong?.title ?? "")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(appearance.primary)
                        .lineLimit(metrics.titleLineLimit)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)
                        .contentTransition(.opacity)
                        .pmAnimation(.trackChange, value: player.currentSong?.id)

                    Text(currentArtistDisplayName)
                        .font(.subheadline)
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("a11y_close_lyrics"))
    }

    private func compactLandscapeTitle(lineLimit: Int) -> some View {
        Text(player.currentSong?.title ?? "")
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(appearance.primary)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .pmAnimation(.trackChange, value: player.currentSong?.id)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var compactLandscapeArtistRow: some View {
        HStack(spacing: 8) {
            // 艺人 / 专辑沿用竖屏那套可点跳转的 Menu，横屏只是压成一行。
            nowPlayingMetadataLinks(font: .title3, lineLimit: 1)

            if let song = player.currentSong, song.audioQuality != .standard {
                AudioQualityBadge(quality: song.audioQuality)
                    .fixedSize()
            }
        }
    }

    private func compactLandscapeLyricLine(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics
    ) -> some View {
        CompactLandscapeLyricLine(
            lyrics: lyrics,
            player: player,
            songID: player.currentSong?.id,
            lyricsRevision: lyricsRevision,
            isSceneActive: isVisualSceneActive,
            tint: appearance.tertiary,
            lineHeight: CGFloat(metrics.lyricLineHeight),
            onTap: { setStandardLyricsVisible(true) }
        )
    }

    @ViewBuilder
    private func compactLandscapeTransportRow(showsEdgeToggles: Bool) -> some View {
        HStack(spacing: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.transportSpacing)) {
            if showsEdgeToggles {
                ctrlBtn("shuffle", active: player.shuffleEnabled) {
                    player.shuffleEnabled.toggle()
                }
            }

            Spacer(minLength: 0)

            compactLandscapeSkipButton(
                symbol: transportBackwardSymbol,
                label: transportBackwardLabel
            ) {
                transportBackward()
            }

            compactLandscapePlayButton

            compactLandscapeSkipButton(
                symbol: transportForwardSymbol,
                label: transportForwardLabel
            ) {
                transportForward()
            }

            Spacer(minLength: 0)

            if showsEdgeToggles {
                ctrlBtn(
                    player.repeatMode == .one ? "repeat.1" : "repeat",
                    active: player.repeatMode != .off
                ) {
                    cycleRepeatMode()
                }
            }
        }
        .frame(height: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.primaryTransportDiameter))
    }

    // MARK: - Transport: music vs spoken word

    /// 有声书、评书、相声用「后退 15 秒 / 前进 30 秒」代替切曲。一整本书就是
    /// 一个条目, 切到下一条目等于整本跳过; 真实需求是漏听一句往回倒。
    /// 电台那套控件在另一处单独实现, 不受影响。
    private var usesSpokenWordTransport: Bool {
        player.currentItemIsSpokenWord && !player.isLiveRadio
    }

    private var transportBackwardSymbol: String {
        usesSpokenWordTransport ? player.spokenWordSkipBackwardSymbol : "backward.fill"
    }

    private var transportForwardSymbol: String {
        usesSpokenWordTransport ? player.spokenWordSkipForwardSymbol : "forward.fill"
    }

    private var transportBackwardLabel: String {
        usesSpokenWordTransport
            ? String(localized: "a11y_skip_backward")
            : String(localized: "a11y_previous_track")
    }

    private var transportForwardLabel: String {
        usesSpokenWordTransport
            ? String(localized: "a11y_skip_forward")
            : String(localized: "a11y_next_track")
    }

    /// 有声的快退/快进长按:有章节时跳章,一本书有多集时跳集。
    @ViewBuilder
    private func bookJumpItems(forward: Bool) -> some View {
        if forward {
            if player.hasChapters {
                Button { player.seekToNextChapter() } label: {
                    Label("spoken_word_next_chapter", systemImage: "forward.end")
                }
            }
            if player.hasNextBookItem {
                Button { player.skipToNextBookItem() } label: {
                    Label("spoken_word_next_item", systemImage: "forward.end.alt")
                }
            }
        } else {
            if player.hasChapters {
                Button { player.seekToPreviousChapter() } label: {
                    Label("spoken_word_previous_chapter", systemImage: "backward.end")
                }
            }
            if player.hasPreviousBookItem {
                Button { player.skipToPreviousBookItem() } label: {
                    Label("spoken_word_previous_item", systemImage: "backward.end.alt")
                }
            }
        }
    }

    private func transportBackward() {
        if usesSpokenWordTransport {
            player.skipSpokenWordBackward()
        } else {
            Task { await player.previous() }
        }
    }

    private func transportForward() {
        if usesSpokenWordTransport {
            player.skipSpokenWordForward()
        } else {
            Task { await player.next() }
        }
    }

    private func compactLandscapeSkipButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let width = CGFloat(NowPlayingCompactLandscapeLayoutPolicy.secondaryTransportWidth)
        let height = CGFloat(NowPlayingCompactLandscapeLayoutPolicy.secondaryTransportHeight)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(appearance.primary)
                .frame(width: width, height: height)
                .nowPlayingAdaptiveGlass(
                    Capsule(),
                    appearance: appearance,
                    tint: appearance.primary
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var compactLandscapePlayButton: some View {
        let diameter = CGFloat(NowPlayingCompactLandscapeLayoutPolicy.primaryTransportDiameter)
        // 实心圆用前景色填充，图标反过来用背景底色，深浅两种外观下都是高对比。
        let glyphTint = appearance.backgroundBase
        return Button { player.togglePlayPause() } label: {
            ZStack {
                Circle()
                    .fill(appearance.primary)

                if player.isLoading {
                    ProgressView()
                        .tint(glyphTint)
                        .pmFadeTransition(motion: .control)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(glyphTint)
                        .contentTransition(.symbolEffect(.replace))
                        // symbolEffect 管不到 ProgressView 这一跳, 用透明度接上。
                        .pmFadeTransition(motion: .control)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(player.isLoading)
        .accessibilityLabel(player.isPlaying
            ? String(localized: "a11y_pause")
            : String(localized: "a11y_play"))
    }

    @ViewBuilder
    private var compactLandscapeChromeLayer: some View {
        // 两支都钉在同一个 ZStack 的左上角、同框重叠，可以走过渡。
        if isCompactLandscapeLocked {
            compactLandscapeUnlockControl
                .pmFadeTransition(motion: .control)
        } else {
            compactLandscapeChromeRow
                .pmFadeTransition(motion: .control)
        }
    }

    /// 这一排圆钮走自适应玻璃：普通模式的背景跟着明暗外观走，不能用沉浸那套
    /// 钉死深色的底（浅色外观下深底会把深色图标吃掉）。
    private var compactLandscapeChromeRow: some View {
        let diameter = CGFloat(NowPlayingCompactLandscapeLayoutPolicy.chromeButtonDiameter)
        return HStack(spacing: 10) {
            NowPlayingGlassActionButton(
                symbol: "lock",
                label: "immersive_lock_controls",
                appearance: appearance,
                tint: appearance.primary,
                diameter: diameter
            ) {
                immersiveControlsAutoHideTask?.cancel()
                isCompactLandscapeLocked = true
            }

            NowPlayingGlassActionButton(
                symbol: "list.bullet",
                label: "a11y_queue",
                appearance: appearance,
                tint: appearance.primary,
                diameter: diameter
            ) {
                openQueue()
            }

            compactLandscapeAirPlayButton

            Spacer(minLength: 0)

            if !usesSpokenWordTransport {
                immersiveEffectButton(glass: .adaptive)
            }

            // 「我喜欢」是音乐歌单, 有声内容不出现。
            if !usesSpokenWordTransport {
                NowPlayingGlassActionButton(
                    symbol: isCurrentLiked ? "heart.fill" : "heart",
                    label: isCurrentLiked ? "a11y_unlike" : "a11y_like",
                    appearance: appearance,
                    tint: isCurrentLiked ? .red : appearance.primary,
                    diameter: diameter,
                    isSelected: isCurrentLiked
                ) {
                    toggleLikedCurrent()
                }
                .disabled(player.currentSong == nil)
            }

            makeMoreMenu(immersiveChrome: true, chromeGlass: .adaptive)

            // 全屏歌词时这一颗退出全屏（回到普通歌词），其它时候收起播放页；图标两者相同。
            NowPlayingGlassActionButton(
                symbol: "arrow.down.right.and.arrow.up.left",
                label: showLyrics && isLyricsImmersive ? "lyrics_exit_full_screen" : "mini_player",
                appearance: appearance,
                tint: appearance.primary,
                diameter: diameter
            ) {
                if showLyrics && isLyricsImmersive {
                    dismissImmersiveLyrics()
                } else {
                    onMinimize?()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: diameter)
    }

    /// AirPlay 用系统的 `AVRoutePickerView`，套进与相邻圆钮同一套玻璃圆底里，
    /// 着色沿用它自己按明暗外观算出来的那套。
    private var compactLandscapeAirPlayButton: some View {
        let diameter = CGFloat(NowPlayingCompactLandscapeLayoutPolicy.chromeButtonDiameter)
        return AirPlayButton()
            .frame(width: 26, height: 26)
            .frame(width: diameter, height: diameter)
            .nowPlayingAdaptiveGlass(
                Circle(),
                appearance: appearance,
                tint: appearance.primary
            )
    }

    private var compactLandscapeUnlockControl: some View {
        let height = CGFloat(NowPlayingCompactLandscapeLayoutPolicy.chromeButtonDiameter)
        return HStack(spacing: 0) {
            Button {
                isCompactLandscapeLocked = false
                // 全屏歌词里解锁：控件先回来，再按原来的节奏淡出。
                if showLyrics && isLyricsImmersive {
                    immersiveControlsState = immersiveControlsState.applying(.unlock)
                    scheduleImmersiveControlsAutoHide()
                }
            } label: {
                Label("immersive_unlock_controls", systemImage: "lock.open.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.primary)
                    .padding(.horizontal, 16)
                    .frame(height: height)
                    .nowPlayingAdaptiveGlass(
                        Capsule(),
                        appearance: appearance,
                        tint: appearance.primary
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("immersive_unlock_controls"))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
    }

    private func cycleRepeatMode() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    // MARK: - iPad 横屏 layout (左封面 / 右歌词)
    //
    // 常规横屏下封面 + 歌词并排显示；用户点按右侧歌词后进入全屏歌词模式。
    // 封面这一侧复用原 portrait 模式的所有控件子组件(PlaybackProgressBar,
    // ctrlBtn, VolumeSlider, AirPlayButton, moreMenu), 只是改成一个独立
    // VStack 钉到左半屏。歌词复用 `lyricsFullView`。

    @ViewBuilder
    private func wideLandscapeLayout(geo: GeometryProxy, safeInsets: EdgeInsets) -> some View {
        let halfWidth = geo.size.width / 2
        // 左侧封面留 80pt 内边距,大小不超过列高 60%。这套尺寸在 iPad Pro
        // 13" 横屏 (1366x1024) 下封面 ~ 580pt,既不显空也不溢出。
        let artSize = min(halfWidth - 80, geo.size.height * 0.6)

        HStack(spacing: 0) {
            wideLeftPane(artSize: artSize)
                // 侧边安全区加在栏内，中缝仍按整幅宽度居中，两栏保持等宽。
                .padding(.leading, safeInsets.leading)
                .frame(width: halfWidth)

            // 中缝细分隔,跟随播放器前景色并保持低对比度
            Rectangle()
                .fill(appearance.divider)
                .frame(width: 1)
                .padding(.vertical, 40)

            wideRightPane()
                .padding(.trailing, safeInsets.trailing)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func wideLeftPane(artSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 顶部 grabber —— 跟 portrait 模式对齐,留出下拉关闭手势的视觉提示
            Capsule()
                .fill(appearance.tertiary)
                .frame(width: 48, height: 5)
                .padding(.top, topSafeArea + 6)
                .padding(.bottom, 10)

            if let error = player.lastPlaybackError {
                Text(error)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.red.opacity(0.8), in: Capsule())
                    // lastPlaybackError 由服务层裸赋值, 调用点包不住动画事务,
                    // 曲线只能附在过渡本身上。
                    .pmSlideTransition(edge: .top, motion: .list)
            }

            GeometryReader { artworkGeometry in
                let ratio: CGFloat = player.isMusicVideoPlaybackActive ? 16.0 / 9.0 : 1
                let fittedWidth = min(artSize, max(1, artworkGeometry.size.height - 24) * ratio)
                artworkOrMusicVideo(size: fittedWidth, cornerRadius: 16)
                    .scaleEffect(artworkAppearsPlaying ? 1.0 : 0.92)
                    .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: artworkAppearsPlaying)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            nowPlayingSongHeader(titleFont: .title2, metadataFont: .title3, showsQuality: true)
                .padding(.horizontal, 36)
                .padding(.top, 18)

            nowPlayingReviewSection
                .padding(.horizontal, 36)

            PlaybackProgressBar(fillTint: themedControlAccent)
                .padding(.horizontal, 36).padding(.top, 10)

            HStack(spacing: 0) {
                Spacer()
                ctrlBtn("shuffle", active: player.shuffleEnabled) { player.shuffleEnabled.toggle() }
                Spacer()
                Button { transportBackward() } label: {
                    Image(systemName: transportBackwardSymbol)
                        .font(.title).foregroundStyle(appearance.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 56, height: 56)
                .accessibilityLabel(transportBackwardLabel)
                .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: false) }
                Spacer()
                wideTransportPlayButton
                Spacer()
                Button { transportForward() } label: {
                    Image(systemName: transportForwardSymbol)
                        .font(.title).foregroundStyle(appearance.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 56, height: 56)
                .accessibilityLabel(transportForwardLabel)
                .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: true) }
                Spacer()
                ctrlBtn(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                    switch player.repeatMode {
                    case .off: player.repeatMode = .all
                    case .all: player.repeatMode = .one
                    case .one: player.repeatMode = .off
                    }
                }
                Spacer()
            }
            .padding(.top, 14)

            if showsPlayerVolumeBar {
                playerVolumeRow
                    .padding(.horizontal, 36).padding(.top, 12)
            }

            wideBottomBar
        }
    }

    /// 宽版式的播放键。分组面板那一套(`Player.sheetActions`)是实心圆,经典是系统的圆形符号。
    @ViewBuilder
    private var wideTransportPlayButton: some View {
        if skin.usesSheetActionsPlayer {
            Button { player.togglePlayPause() } label: {
                portraitPlayButtonLabel
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)
            .accessibilityLabel(player.isPlaying
                ? String(localized: "a11y_pause")
                : String(localized: "a11y_play"))
        } else {
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 60)).opacity(0)
                    if player.isLoading {
                        ProgressView().controlSize(.large).tint(appearance.primary)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 60)).foregroundStyle(appearance.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .disabled(player.isLoading)
            .accessibilityLabel(player.isPlaying
                ? String(localized: "a11y_pause")
                : String(localized: "a11y_play"))
        }
    }

    @ViewBuilder
    private var wideBottomBar: some View {
        if skin.usesSheetActionsPlayer {
            // 底部 bar —— 没有歌词切换按钮(歌词永远在右栏可见):中间是音质胶囊,
            // 右边隔空播放与队列,和竖屏同一套零件。
            HStack(spacing: 4) {
                Color.clear.frame(width: 88, height: 44)
                Spacer(minLength: 6)
                portraitQualityChip
                Spacer(minLength: 6)
                AirPlayButton()
                    .frame(width: 36, height: 36)
                    .frame(width: 44, height: 44)
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet").foregroundStyle(appearance.secondary)
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("a11y_queue")
            }
            .font(.body).padding(.horizontal, 40).padding(.top, 14).padding(.bottom, 16)
        } else {
            // 底部 bar —— 没有歌词切换按钮(歌词永远在右栏可见),保留 AirPlay
            // 和队列入口
            HStack {
                Spacer()
                AirPlayButton()
                    .frame(width: 36, height: 36)
                    .frame(width: 44, height: 44)
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet").foregroundStyle(appearance.secondary)
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("a11y_queue")
            }
            .font(.body).padding(.horizontal, 80).padding(.top, 14)

            if let song = player.currentSong {
                HStack(spacing: 4) {
                    Text(song.fileFormat.displayName)
                    if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
                    if sourcesStore.sources.count > 1,
                       let source = sourcesStore.source(id: song.sourceID) {
                        Text("·")
                        Image(systemName: source.type.iconName)
                        Text(source.name)
                    }
                }
                .font(.caption2).foregroundStyle(appearance.faint)
                .padding(.top, 6).padding(.bottom, 16)
            } else {
                Spacer().frame(height: 16)
            }
        }
    }

    @ViewBuilder
    private func wideRightPane() -> some View {
        VStack(spacing: 0) {
            // 跟左栏 grabber 顶端对齐
            Spacer().frame(height: topSafeArea + 21)
            lyricsFullView
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func standardLandscapeLyricsLayout(geo: GeometryProxy) -> some View {
        let safeInsets = resolvedSafeAreaInsets(for: geo)
        let baseHorizontalPadding = max(72, geo.size.width * 0.10)
        ZStack {
            lyricsFullView
                .padding(.leading, max(baseHorizontalPadding, safeInsets.leading + 18))
                .padding(.trailing, max(baseHorizontalPadding, safeInsets.trailing + 18))
                .padding(.top, 56)
                .padding(.bottom, 88)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { setStandardLyricsVisible(false) } label: {
                        HStack(spacing: 10) {
                            CachedArtworkView(
                                coverRef: player.currentSong?.coverArtFileName,
                                songID: player.currentSong?.id ?? "",
                                size: 40,
                                cornerRadius: 7,
                                sourceID: player.currentSong?.sourceID,
                                filePath: player.currentSong?.filePath,
                                fileFormat: player.currentSong?.fileFormat,
                                fillsProposedSize: true,
                                revisionToken: player.coverRevision
                            )
                            .artworkCrossfade()
                            .matchedGeometryEffect(
                                id: lyricsArtworkTransitionID,
                                in: lyricsArtworkNamespace,
                                isSource: isLyricsCompactArtworkVisible
                            )
                            .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(player.currentSong?.title ?? "")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(currentArtistDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(appearance.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(appearance.primary)
                        .padding(.trailing, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("a11y_close_lyrics"))

                    Spacer()

                    // 「我喜欢」是音乐歌单, 有声内容不出现。
                    if !usesSpokenWordTransport {
                        Button { toggleLikedCurrent() } label: {
                            nowPlayingActionIcon(
                                symbol: isCurrentLiked ? "heart.fill" : "heart",
                                tint: isCurrentLiked ? .red : appearance.secondary,
                                isSelected: isCurrentLiked
                            )
                        }
                        .frame(width: 44, height: 44)
                        .buttonStyle(.plain)
                        .disabled(player.currentSong == nil)
                        .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                    }

                    immersiveMoreMenu
                }
                .padding(.leading, max(safeInsets.leading, 18))
                .padding(.trailing, max(safeInsets.trailing, 18))
                .padding(.top, max(safeInsets.top, 10))

                Spacer()

                floatingPlaybackDock
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(safeInsets.bottom, 10))
            }
        }
    }

    @ViewBuilder
    private func immersiveLandscapeLyricsLayout(geo: GeometryProxy) -> some View {
        let safeInsets = resolvedSafeAreaInsets(for: geo)
        let playerWidth = min(max(geo.size.width * 0.34, 260), 410)
        let artSize = min(max(0, playerWidth - 52), geo.size.height * 0.56)

        immersiveLyricsExperience(
            isLandscape: true,
            leadingSafeInset: safeInsets.leading,
            trailingSafeInset: safeInsets.trailing
        ) {
            HStack(spacing: 28) {
                VStack(spacing: 18) {
                    Spacer(minLength: 0)

                    artworkOrMusicVideo(size: artSize, cornerRadius: 18)
                        .scaleEffect(artworkAppearsPlaying ? 1 : 0.96)
                        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
                        .animation(.spring(response: 0.5, dampingFraction: 0.76), value: artworkAppearsPlaying)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.currentSong?.title ?? "")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                            .foregroundStyle(appearance.primary)
                        nowPlayingMetadataLinks(font: .subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(width: playerWidth)
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(appearance.primary.opacity(0.09), lineWidth: 0.5)
                }

                lyricsFullView
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.leading, max(safeInsets.leading, 24))
            .padding(.trailing, max(safeInsets.trailing, 24))
            .padding(.top, max(safeInsets.top, 18))
            .padding(.bottom, max(safeInsets.bottom, 18))
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleImmersiveContentTap() }
            }
        }
    }

    @ViewBuilder
    private func landscapeMusicVideoLayout(videoPlayer: AVPlayer, safeInsets: EdgeInsets) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear

            #if os(iOS)
            Button {
                MusicVideoOrientationController.enterPortrait()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.50), in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            // 外层播放器容器整幅铺满，按钮改按解析出的安全区排布。
            .padding(.top, safeInsets.top + 16)
            .padding(.trailing, safeInsets.trailing + 20)
            .accessibilityLabel(Text("exit_landscape_video"))
            #endif
        }
        // 只有黑底与画面越过安全区；退出按钮仍按安全区排布。
        .background {
            ZStack {
                Color.black
                MusicVideoSurface(player: videoPlayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
        }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }

    // MARK: - 原 portrait layout (iPhone + iPad 竖屏 + 分屏小窗)

    @ViewBuilder
    private func portraitLayout(
        geo: GeometryProxy,
        artSize: CGFloat,
        insets: NowPlayingPortraitInsets,
        lyricsInline: Bool? = nil,
        usesToolColumn: Bool = false
    ) -> some View {
        // 分栏时歌词在右栏,这一栏始终是封面模式;其它时候跟着歌词开关走。
        let showLyrics = lyricsInline ?? self.showLyrics
        // MV 是 16:9，若沿用方形封面按高度推导出的宽度，会在竖屏里显得
        // 明显偏小。视频改为尽量吃满屏宽；方形封面仍保持原来的视觉尺度。
        let mediaWidth = player.isMusicVideoPlaybackActive
            ? min(max(0, geo.size.width - 20), 720, insets.mediaWidthLimit)
            : artSize

        VStack(spacing: 0) {
                    // Grabber handle (system-matching dimensions)
                    if !showLyrics || !isLyricsImmersive {
                        Capsule()
                            .fill(appearance.tertiary)
                            .frame(width: 48, height: 5)
                            .frame(maxWidth: .infinity)
                            .frame(height: 5)
                            .padding(.top, topSafeArea + 6)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 10)
                            .pmLayoutSwitchFade()
                    }

                    // Playback error toast
                    if (!showLyrics || !isLyricsImmersive),
                       let error = player.lastPlaybackError {
                        Text(error)
                            .font(.caption).fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.red.opacity(0.8), in: Capsule())
                            .pmSlideTransition(edge: .top, motion: .list)
                    }

                    if showLyrics {
                        // LYRICS MODE: compact header at top
                        if !isLyricsImmersive {
                            HStack(spacing: 10) {
                            // Explicit button rather than a hidden tap gesture:
                            // the artwork itself is now a discoverable way back.
                            Button { setStandardLyricsVisible(false) } label: {
                                HStack(spacing: 10) {
                                    CachedArtworkView(
                                        coverRef: player.currentSong?.coverArtFileName,
                                        songID: player.currentSong?.id ?? "",
                                        size: 44, cornerRadius: 6,
                                        sourceID: player.currentSong?.sourceID,
                                        filePath: player.currentSong?.filePath,
                                        fileFormat: player.currentSong?.fileFormat,
                                        fillsProposedSize: true,
                                        revisionToken: player.coverRevision
                                    )
                                    .artworkCrossfade()
                                    .matchedGeometryEffect(
                                        id: lyricsArtworkTransitionID,
                                        in: lyricsArtworkNamespace,
                                        isSource: isLyricsCompactArtworkVisible
                                    )
                                    .frame(width: 44, height: 44)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(player.currentSong?.title ?? "")
                                            .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                                            .foregroundStyle(appearance.primary)
                                        Text(currentArtistDisplayName)
                                            .font(.caption).foregroundStyle(appearance.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityLabel(Text("a11y_close_lyrics"))

                            Spacer()

                            musicVideoToggleButton(font: .title3, trailing: 4)

                            // 竖栏里排着那一列按钮时(iPhone Duo),喜欢与更多在那一列里。
                            if !usesToolColumn {
                                // 「我喜欢」是音乐歌单, 有声内容不出现。
                                if !usesSpokenWordTransport {
                                    Button { toggleLikedCurrent() } label: {
                                        nowPlayingActionIcon(
                                            symbol: isCurrentLiked ? "heart.fill" : "heart",
                                            tint: isCurrentLiked ? .red : appearance.secondary,
                                            isSelected: isCurrentLiked
                                        )
                                    }
                                    .frame(width: 44, height: 44)
                                    .disabled(player.currentSong == nil)
                                    .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                                }

                                // More menu
                                moreMenu
                            }
                            }
                            .padding(.horizontal, 20).padding(.bottom, 6)
                            .padding(.leading, insets.lyricsLeading)
                            .padding(.trailing, insets.lyricsTrailing)
                            .transition(lyricsHeaderTransition)
                        }

                        // Full screen lyrics
                        if isLyricsImmersive {
                            immersiveLyricsExperience(
                                isLandscape: false,
                                topRowLeadingInset: insets.immersiveTopRowLeading,
                                topRowTrailingInset: insets.immersiveTopRowTrailing,
                                contentTopInset: insets.immersiveContentTop
                            ) {
                                lyricsFullView
                            }
                            .transition(.opacity)
                        } else {
                            lyricsFullView
                                .padding(.leading, insets.lyricsLeading)
                                .padding(.trailing, insets.lyricsTrailing)
                                .pmLayoutSwitchFade()
                                .transition(lyricsPanelTransition)
                        }
                    } else {
                        GeometryReader { artworkGeometry in
                            // Text and controls retain their height; artwork uses the remaining space.
                            let ratio: CGFloat = player.isMusicVideoPlaybackActive ? 16.0 / 9.0 : 1
                            let fittedWidth = min(mediaWidth, max(1, artworkGeometry.size.height - 24) * ratio)
                            // 分组面板那一套(`Player.sheetActions`):封面浮在取色底上 ——
                            // 圆角加大、阴影更深更远,暂停时收小一档。
                            let floatsArtwork = skin.usesSheetActionsPlayer
                            artworkOrMusicVideo(size: fittedWidth, cornerRadius: floatsArtwork ? 16 : 12)
                                .scaleEffect(
                                    player.isMusicVideoPlaybackActive
                                        ? 1.0
                                        : (artworkAppearsPlaying ? 1.0 : (floatsArtwork ? 0.88 : 0.9))
                                )
                                .shadow(
                                    color: .black.opacity(floatsArtwork
                                        ? (artworkAppearsPlaying ? 0.45 : 0.28)
                                        : 0.3),
                                    radius: floatsArtwork ? 28 : 20,
                                    y: floatsArtwork ? 16 : 8
                                )
                                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: artworkAppearsPlaying)
                                .onTapGesture {
                                    guard !player.isMusicVideoPlaybackActive else { return }
                                    setStandardLyricsVisible(true)
                                }
                                .transition(playerArtworkTransition)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }

                    // Song info (player mode only — in lyrics mode it's in the top bar)
                    if !showLyrics {
                        nowPlayingSongHeader(titleFont: .title3, metadataFont: .body, inlineActions: !usesToolColumn)
                            .matchedLayoutElement(.songHeading, in: layoutNamespace)
                            .padding(.horizontal, 26)
                            .padding(.horizontal, insets.rows)
                            .padding(.top, 12)

                        nowPlayingReviewSection
                            .padding(.horizontal, 26)
                            .padding(.horizontal, insets.rows)
                            .pmLayoutSwitchFade()
                    }

                    // Progress — 抽成独立子 view 隔离 player.currentTime 的高频
                    // 重算,避免触发父 body re-render(进而让 toolbar Menu 的 submenu
                    // 被强制关闭)。SwiftUI Observation 是 per-body 追踪——子 view
                    // 自己读 player.currentTime,父 view body 完全不读高频属性。
                    if !showLyrics || !isLyricsImmersive {
                        PlaybackProgressBar(fillTint: themedControlAccent)
                            .matchedLayoutElement(.progress, in: layoutNamespace)
                            .padding(.horizontal, 26).padding(.top, 8)
                            .padding(.horizontal, insets.rows)

                        // Controls
                        portraitTransportRow
                        .matchedLayoutElement(.transport, in: layoutNamespace)
                        .padding(.top, 12)
                        .padding(.horizontal, insets.rows)

                        if showsPlayerVolumeBar {
                            playerVolumeRow
                                .padding(.horizontal, 26).padding(.top, 10)
                                .padding(.horizontal, insets.rows)
                                .pmLayoutSwitchFade()
                        }

                        // Bottom bar —— 三个槽位都是 44×44, HStack 的两个 Spacer 才
                        // 会把 AirPlay 分到正中, 左右图标到 padding 边的距离也才相等。
                        // 竖栏里排着那一列按钮时(iPhone Duo)这一排的键都在那一列里,这里不再重复。
                        if !usesToolColumn {
                            portraitBottomBar
                            .padding(.horizontal, insets.rows)
                            .pmLayoutSwitchFade()
                        }

                        // Format & source(分组面板那一套收进了底栏中间的音质胶囊;底栏的键排进 iPhone Duo
                        // 竖栏那一列、底栏不画时,和经典一样在这里单独一行)
                        if !skin.usesSheetActionsPlayer || usesToolColumn, let song = player.currentSong {
                            HStack(spacing: 4) {
                                Text(song.fileFormat.displayName)
                                if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
                                if sourcesStore.sources.count > 1,
                                   let source = sourcesStore.source(id: song.sourceID) {
                                    Text("·")
                                    Image(systemName: source.type.iconName)
                                    Text(source.name)
                                }
                            }
                            .font(.caption2).foregroundStyle(appearance.faint).padding(.top, 4).padding(.bottom, 6)
                            .pmLayoutSwitchFade()
                        }
                    }
                }
                // 侧边安全区按侧取值；上下仍沿用窗口安全区的既有处理。整屏居中(iPhone Duo)时两侧都是 0。
                .padding(.leading, insets.containerLeading)
                .padding(.trailing, insets.containerTrailing)
    }

    /// 竖版的传输键一行(随机 · 上一首 · 播放 · 下一首 · 循环)。桌面半折的下半屏也用这一行。
    private var portraitTransportRow: some View {
        HStack(spacing: 0) {
        Spacer()
        ctrlBtn("shuffle", active: player.shuffleEnabled) { player.shuffleEnabled.toggle() }
        Spacer()
        Button { transportBackward() } label: {
            Image(systemName: transportBackwardSymbol)
                .font(.title).foregroundStyle(appearance.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel(transportBackwardLabel)
        .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: false) }
        Spacer()
        portraitTransportPlayButton
        Spacer()
        Button { transportForward() } label: {
            Image(systemName: transportForwardSymbol)
                .font(.title).foregroundStyle(appearance.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel(transportForwardLabel)
        .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: true) }
        Spacer()
        ctrlBtn(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
            switch player.repeatMode {
            case .off: player.repeatMode = .all
            case .all: player.repeatMode = .one
            case .one: player.repeatMode = .off
            }
        }
        Spacer()
        }
    }

    /// 竖版最下面那一排(歌词 · 投放 · 队列)。三个槽位都是 44×44, HStack 的两个 Spacer 才
    /// 会把 AirPlay 分到正中, 左右图标到 padding 边的距离也才相等。
    @ViewBuilder
    private var portraitBottomBar: some View {
        if skin.usesSheetActionsPlayer {
            // Bottom bar —— 左边歌词开关,中间是音质与来源的玻璃胶囊(原来单独一行
            // 的小字收了进来),右边隔空播放与队列。两端都是 44×44 的点按区。
            HStack(spacing: 4) {
                Button { toggleLyricsForLayout() } label: {
                    Image(systemName: showLyrics ? "photo" : "quote.bubble")
                        .foregroundStyle(showLyrics ? appearance.primary : appearance.secondary)
                        .frame(width: 40, height: 36)
                        .background {
                            if showLyrics {
                                Capsule().fill(appearance.primary.opacity(0.16))
                            }
                        }
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text(showLyrics ? "a11y_close_lyrics" : "a11y_open_lyrics"))

                Spacer(minLength: 6)
                portraitQualityChip
                Spacer(minLength: 6)

                AirPlayButton()
                    .frame(width: 36, height: 36)
                    .frame(width: 44, height: 44)
                Button { openQueue() } label: {
                    Image(systemName: "list.bullet").foregroundStyle(appearance.secondary)
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("a11y_queue")
            }
            .font(.body)
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 6)
        } else {
            classicPortraitBottomBar
        }
    }

    private var classicPortraitBottomBar: some View {
        HStack {
        Button { toggleLyricsForLayout() } label: {
            Image(systemName: showLyrics ? "photo" : "quote.bubble")
                .foregroundStyle(showLyrics ? appearance.primary : appearance.tertiary)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text(showLyrics ? "a11y_close_lyrics" : "a11y_open_lyrics"))
        Spacer()
        AirPlayButton()
            .frame(width: 36, height: 36)
            .frame(width: 44, height: 44)
        Spacer()
        Button { openQueue() } label: {
            Image(systemName: "list.bullet").foregroundStyle(appearance.tertiary)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("a11y_queue")
        }
        .font(.body).padding(.horizontal, 46).padding(.top, 12)
    }

    @ViewBuilder
    private func immersiveLyricsExperience<Content: View>(
        isLandscape: Bool,
        leadingSafeInset: CGFloat = 0,
        trailingSafeInset: CGFloat = 0,
        topRowLeadingInset: CGFloat? = nil,
        topRowTrailingInset: CGFloat? = nil,
        contentTopInset: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            content()
                .padding(.top, contentTopInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())

            if immersiveControlsState.isLocked || !immersiveControlsState.isVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleImmersiveContentTap() }
            }

            immersiveLyricsChrome(
                isLandscape: isLandscape,
                leadingSafeInset: leadingSafeInset,
                trailingSafeInset: trailingSafeInset,
                topRowLeadingInset: topRowLeadingInset ?? leadingSafeInset,
                topRowTrailingInset: topRowTrailingInset ?? trailingSafeInset
            )
        }
    }

    @ViewBuilder
    private func immersiveLyricsChrome(
        isLandscape: Bool,
        leadingSafeInset: CGFloat,
        trailingSafeInset: CGFloat,
        topRowLeadingInset: CGFloat,
        topRowTrailingInset: CGFloat
    ) -> some View {
        if immersiveControlsState.showsPrimaryControls {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ImmersiveGlassActionButton(
                        symbol: "lock",
                        label: "immersive_lock_controls",
                        tint: appearance.primary,
                        diameter: 44
                    ) {
                        lockImmersiveControls()
                    }

                    Spacer()

                    if !usesSpokenWordTransport {
                        immersiveEffectButton()
                    }

                    // 「我喜欢」是音乐歌单, 有声内容不出现。
                    if !usesSpokenWordTransport {
                        ImmersiveGlassActionButton(
                            symbol: isCurrentLiked ? "heart.fill" : "heart",
                            label: isCurrentLiked ? "a11y_unlike" : "a11y_like",
                            tint: isCurrentLiked ? .red : appearance.primary,
                            diameter: 44,
                            isSelected: isCurrentLiked
                        ) {
                            toggleLikedCurrent()
                        }
                        .disabled(player.currentSong == nil)
                    }

                    immersiveMoreMenu

                    ImmersiveGlassActionButton(
                        symbol: "arrow.down.right.and.arrow.up.left",
                        label: "lyrics_exit_full_screen",
                        tint: appearance.primary,
                        diameter: 44
                    ) {
                        dismissImmersiveLyrics()
                    }
                }
                .padding(.leading, topRowLeadingInset + (isLandscape ? 24 : 20))
                .padding(.trailing, topRowTrailingInset + (isLandscape ? 24 : 20))
                .padding(.top, max(topSafeArea, 10) + (isLandscape ? 0 : 8))

                Spacer()

                floatingPlaybackDock
                    .frame(maxWidth: isLandscape ? 440 : 520)
                    .padding(.leading, leadingSafeInset + (isLandscape ? 28 : 20))
                    .padding(.trailing, trailingSafeInset + (isLandscape ? 28 : 20))
                    .padding(.bottom, max(bottomSafeArea, 12) + (isLandscape ? 0 : 8))
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(2)
        } else if immersiveControlsState.showsUnlockControl {
            HStack {
                Button { unlockImmersiveControls() } label: {
                    Label("immersive_unlock_controls", systemImage: "lock.open.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("immersive_unlock_controls"))

                Spacer()
            }
            .padding(.leading, leadingSafeInset + (isLandscape ? max(24, topSafeArea) : 20))
            .transition(.opacity.combined(with: .move(edge: .leading)))
            .zIndex(2)
        }
    }

    private var floatingPlaybackDock: some View {
        VStack(spacing: 8) {
            PlaybackProgressBar(fillTint: themedControlAccent)

            HStack(spacing: 34) {
                Button { transportBackward() } label: {
                    Image(systemName: transportBackwardSymbol)
                        .frame(width: 44, height: 36)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(transportBackwardLabel)
                .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: false) }

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(player.isLoading)
                .accessibilityLabel(player.isPlaying
                    ? String(localized: "a11y_pause")
                    : String(localized: "a11y_play"))

                Button { transportForward() } label: {
                    Image(systemName: transportForwardSymbol)
                        .frame(width: 44, height: 36)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(transportForwardLabel)
                .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: true) }
            }
            .font(.title3)
            .foregroundStyle(appearance.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(appearance.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func artworkOrMusicVideo(size: CGFloat, cornerRadius: CGFloat) -> some View {
        if player.isMusicVideoPlaybackActive, let videoPlayer = player.musicVideoPlayer {
            ZStack(alignment: .topTrailing) {
                MusicVideoSurface(player: videoPlayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: size, height: size * 9 / 16)
                    .background(Color.black)

                #if os(iOS)
                Button {
                    presentMusicVideoFullScreen(videoPlayer)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.44), in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel(Text("full_screen_player"))
                #endif
            }
            .frame(width: size, height: size * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
        } else {
            CachedArtworkView(
                coverRef: player.currentSong?.coverArtFileName,
                songID: player.currentSong?.id ?? "",
                size: size, cornerRadius: cornerRadius,
                sourceID: player.currentSong?.sourceID,
                filePath: player.currentSong?.filePath,
                fileFormat: player.currentSong?.fileFormat,
                presentationRole: .animatedHero,
                animationRequiresPlayback: true,
                isPlaying: player.isPlaying,
                isAnimationVisible: isNowPlayingSurfaceExposed,
                loadsHighResolution: isPresentationSettled,
                fillsProposedSize: true,
                revisionToken: player.coverRevision
            )
            .artworkCrossfade()
            // 尺寸约束放在 matchedGeometryEffect 之外: 内容只接受被匹配到的
            // frame, 切歌词时才能一边位移一边连续缩小到小图位置。
            .matchedGeometryEffect(
                id: lyricsArtworkTransitionID,
                in: lyricsArtworkNamespace,
                isSource: !isLyricsCompactArtworkVisible
            )
            .frame(width: size, height: size)
            .overlay(alignment: .bottom) {
                MusicVideoPreparationBadge(songID: player.currentSong?.id)
            }
            #if os(iOS)
            .modifier(
                NowPlayingAlbumTransitionSourceModifier(
                    albumID: currentAlbum?.id,
                    namespace: albumPresentationNamespace,
                    cornerRadius: cornerRadius
                )
            )
            #endif
        }
    }

    @ViewBuilder
    private func musicVideoToggleButton(font: Font, trailing: CGFloat) -> some View {
        // 独立 MV 始终走视频管线, 模式开关对它无意义, 不显示
        if player.canPlayMusicVideo, player.currentSong?.isStandaloneMusicVideo != true {
            Button { player.toggleMusicVideoMode() } label: {
                Image(systemName: player.isMusicVideoModeEnabled ? "play.rectangle.fill" : "play.rectangle")
                    .font(font)
                    .foregroundStyle(player.isMusicVideoModeEnabled ? appearance.primary : appearance.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(player.currentSong == nil || player.isLoading)
            .padding(.trailing, trailing)
            .accessibilityLabel(
                Text(player.isMusicVideoModeEnabled ? "a11y_disable_music_video" : "a11y_enable_music_video")
            )
        }
    }

    private func deleteCurrentSong() {
        guard let song = player.currentSong,
              SourceFileDeletionPolicy.shouldShowDeleteAction(
                  for: sourcesStore.source(id: song.sourceID)?.type
              )
        else { return }
        Task {
            // Move off the deleted song AND drop every queue entry that
            // points at it before touching the files. Otherwise the stale
            // entries linger in the queue (played / up-next), and repeat-all
            // wrap, previous(), or tapping the row would re-play a song whose
            // file is already gone + tombstoned → resolveURL throws.
            let remainingQueue = player.queue.filter { $0.id != song.id }
            if remainingQueue.isEmpty {
                // This was the only thing queued — replaying it via next()
                // would just decode the file we're about to delete. Tear the
                // queue down instead.
                player.stop()
                player.clearQueue()
            } else {
                // Skip to a different track first so playback keeps going,
                // then rebuild the queue without the deleted song. setQueue
                // resets currentIndex, bumps the queue generation, and (when
                // shuffle is on) rebuilds the shuffle order around the new
                // current song.
                await player.next()
                let newSongID = player.currentSong?.id
                let anchorIndex = remainingQueue.firstIndex { $0.id == newSongID } ?? 0
                player.setQueue(remainingQueue, startAt: anchorIndex)
            }
            let retainedSongs = library.songs.filter { $0.id != song.id }
            let deleteSidecars = sourceManager.shouldDeleteSidecars(for: song, retaining: retainedSongs)
            let result = await sourceManager.deleteSourceFilesAndCaches(
                for: song,
                deleteSidecars: deleteSidecars
            )
            guard result.shouldRemoveLibraryRecord else {
                deleteErrorMessage = deletionFailureMessage(result)
                return
            }
            // Remove from library and keep the source badge in sync.
            // 源文件已确认删除, 墓碑可以在同一路径换了文件时让路。
            let remaining = library.deleteSong(song, sourceFileDeleted: true)
            sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }
        }
    }

    private func deletionFailureMessage(_ result: SongFileDeletionResult) -> String {
        let summary = String(localized: "delete_song_failed_message")
        guard let detail = result.failedPaths.first?.message, !detail.isEmpty else { return summary }
        return "\(summary)\n\(detail)"
    }

    #if os(iOS)
    private func presentMusicVideoFullScreen(_ videoPlayer: AVPlayer) {
        fullScreenMusicVideoPlayer = videoPlayer
        showMusicVideoFullScreen = true
    }

    private func dismissMusicVideoFullScreenIfNeeded() {
        guard showMusicVideoFullScreen else {
            fullScreenMusicVideoPlayer = nil
            return
        }
        guard player.isMusicVideoModeEnabled || player.currentSong?.isStandaloneMusicVideo == true,
              player.currentSong != nil,
              player.currentSong?.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            dismissMusicVideoFullScreen()
            return
        }
    }

    private func dismissMusicVideoFullScreen() {
        guard showMusicVideoFullScreen else {
            finishMusicVideoFullScreenDismissal()
            return
        }
        // Keep the AVPlayer-backed cover stable until UIKit has actually
        // removed its presentation host. Clearing its content while the cover
        // and the window scene are rotating can leave an invisible modal view
        // above the portrait UI that consumes every tap.
        showMusicVideoFullScreen = false
    }

    private func finishMusicVideoFullScreenDismissal() {
        fullScreenMusicVideoPlayer = nil
        // fullScreenCover's onDismiss runs after the modal presentation has
        // been removed. Restore orientation here rather than from the close
        // button/onDisappear so geometry changes cannot race cover teardown.
        MusicVideoOrientationController.restorePreviousOrientation()
    }
    #endif

    // MARK: - More Menu

    private var moreMenu: some View {
        makeMoreMenu()
    }

    private var immersiveMoreMenu: some View {
        makeMoreMenu(immersiveChrome: true)
    }

    /// 全屏效果入口。面板本身是 `body` 里的 `ImmersiveEffectDrawer`，这里只负责
    /// 开关那个状态 —— 抽屉留在宿主的 ZStack 里，宿主才知道它开着，能继续暂停
    /// 浮动控件的自动隐藏。
    ///
    /// - Parameter glass: 圆钮底的样式。沉浸歌词与全屏沿用固定深色玻璃，普通模式
    ///   横屏传自适应的那套。
    private func immersiveEffectButton(glass: NowPlayingChromeGlass = .immersive) -> some View {
        Button {
            immersiveControlsAutoHideTask?.cancel()
            showsImmersiveEffectPicker = true
        } label: {
            immersiveEffectButtonLabel(glass: glass)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("fullscreen_effect_settings_title"))
    }

    @ViewBuilder
    private func immersiveEffectButtonLabel(glass: NowPlayingChromeGlass) -> some View {
        let isSelected = fullscreenPlayerEffect != .native
        switch glass {
        case .barColumn(let itemSize):
            NowPlayingBarColumnIcon(
                symbol: "viewfinder.rectangular",
                appearance: appearance,
                size: itemSize,
                isSelected: isSelected
            )
        case .immersive:
            ImmersiveGlassActionLabel(
                symbol: "viewfinder.rectangular",
                tint: appearance.primary,
                diameter: 44,
                isSelected: isSelected
            )
        case .adaptive:
            NowPlayingGlassActionLabel(
                symbol: "viewfinder.rectangular",
                appearance: appearance,
                tint: appearance.primary,
                diameter: 44,
                isSelected: isSelected
            )
        }
    }

    /// 全屏效果抽屉。放在 `body` 最外层的 ZStack 上层：沉浸歌词与普通模式横屏
    /// 共用同一个开关状态，抽屉只有一份；宿主自己持有它，才知道它开着并继续
    /// 暂停浮动控件的自动隐藏。
    #if os(iOS)
    private func immersiveEffectDrawer(
        geo: GeometryProxy,
        safeInsets: EdgeInsets
    ) -> some View {
        ImmersiveEffectDrawer(
            selection: fullscreenPlayerEffectBinding,
            effects: ImmersiveEffectDrawer.fullscreenCases,
            palette: ImmersiveArtworkPalette(
                primary: presentationAccentColor,
                secondary: presentationSecondaryDarkAccent
            ),
            // 播放页这边转轮只是浏览，点卡片才写回并自动收起。
            appliesOnSettle: false,
            viewportSize: geo.size,
            safeAreaInsets: safeInsets,
            onPick: { _ in enterFullscreenAfterPickingEffect() },
            onClose: { showsImmersiveEffectPicker = false }
        )
    }

    /// 从普通播放页挑了一个全屏效果就直接进全屏 —— 这个入口的图标本来就是「全屏」，
    /// 只记下偏好却留在原地，会让人以为没点上。沉浸歌词里的切换由效果变化的监听接管
    /// （它会先退出沉浸歌词再进全屏），这里不重复处理。
    private func enterFullscreenAfterPickingEffect() {
        guard !isFullscreenPlayerPresented, !isLyricsImmersive else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            isFullscreenPlayerPresented = true
        }
    }
    #endif

    private func makeMoreMenu(
        immersiveChrome: Bool = false,
        chromeGlass: NowPlayingChromeGlass = .immersive
    ) -> some View {
        // 有声内容只留听书用得上的项: 相似歌曲、串烧、卡拉OK、全屏效果、随机、
        // 在线刮削(查的是音乐库)与歌词动效都是音乐的玩法, 「转到专辑」换成
        // 「转到这本书」。
        let isSpokenWord = usesSpokenWordTransport
        let snapshot = NowPlayingMoreMenuSnapshot(
            songID: player.currentSong?.id,
            isSpokenWord: isSpokenWord,
            canOpenBook: isSpokenWord && player.currentBookID != nil,
            hasChapterList: player.hasChapters || isSpokenWord,
            hasSong: player.currentSong != nil,
            isScrapingCurrentSong: isScrapeActionUnavailable,
            canReloadLyricsFromSource: canReloadLyricsFromSource,
            isReloadingLyricsFromSource: isReloadingLyricsFromSource,
            isAppleMusicMode: player.isAppleMusicMode,
            canDeleteSourceFile: player.currentSong.map {
                SourceFileDeletionPolicy.shouldShowDeleteAction(
                    for: sourcesStore.source(id: $0.sourceID)?.type
                )
            } ?? false,
            appleMusicCatalogURL: appleMusicCatalogURL,
            showsLyricsPreferences: showLyrics,
            showsFullScreenAction: !isSpokenWord && !isLyricsImmersive && !isFullscreenPlayerPresented,
            albumID: currentAlbum?.id,
            artistID: currentArtist?.id,
            canOpenAlbum: canOpenCurrentAlbum,
            canOpenArtist: currentArtist != nil && onOpenArtist != nil,
            canShare: player.currentSong != nil,
            castingRendererName: player.castingRenderer?.friendlyName,
            isSleepTimerActive: player.isSleepTimerActive,
            lyricsFontScale: lyricsFontScale,
            canChangePlaybackRate: playbackSettings.outputMode == .effects,
            playbackRate: playbackSettings.outputMode == .highFidelity
                ? 1
                : (player.currentItemIsSpokenWord
                    ? player.currentSpokenWordRate
                    : playbackSettings.playbackRate),
            isLyricsTranslationEnabled: LyricsTranslationSettingsStore.shared.isEnabled,
            showsPlaybackModeActions: compactLandscapeHidesModeToggles && !isSpokenWord,
            isShuffleEnabled: player.shuffleEnabled,
            repeatMode: player.repeatMode,
            isMedleyActive: player.isMedleyActive,
            canStartMedley: !isSpokenWord && !player.isAppleMusicMode && !player.isLiveRadio
                && player.canPlayMedleyFromQueue,
            canStartKaraoke: !isSpokenWord && player.currentSong != nil && !player.isAppleMusicMode
                && !player.isLiveRadio,
            medleySegmentSeconds: playbackSettings.medleySegmentSeconds,
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast
        )

        return NowPlayingMoreMenu(
            snapshot: snapshot,
            lyricsFontScale: $lyricsFontScale,
            playbackRate: Binding(
                get: {
                    guard playbackSettings.outputMode != .highFidelity else { return 1 }
                    return player.currentItemIsSpokenWord
                        ? player.currentSpokenWordRate
                        : playbackSettings.playbackRate
                },
                set: {
                    guard playbackSettings.outputMode == .effects else { return }
                    // 有声内容与音乐各记一档速度, 菜单改的是正在播的这一类;
                    // 有声按书记,每本书可以有自己的速度。
                    if player.currentItemIsSpokenWord {
                        player.setSpokenWordRateForCurrentBook($0)
                    } else {
                        playbackSettings.playbackRate = $0
                    }
                }
            ),
            immersiveChrome: immersiveChrome,
            chromeGlass: chromeGlass,
            onEnterFullScreen: { presentImmersiveLyrics() },
            onAddToPlaylist: { showAddToPlaylist = true },
            onScrape: { openScrapeForCurrentSong() },
            onReloadLyricsFromSource: { reloadLyricsFromSource() },
            onShowSimilarSongs: { showSimilarSongs = true },
            onEditTags: { showTagEditor = true },
            onEditLyrics: {
                lyricsEditorAutoStartsAudioTranscription = false
                lyricsEditorTargetSong = player.currentSong
            },
            onShowSongInfo: { showSongInfo = true },
            onOpenAlbum: {
                guard let album = currentAlbum else { return }
                presentAlbum(
                    album,
                    prefersMatchedArtworkSource: !showLyrics
                )
            },
            onOpenArtist: {
                guard let artist = currentArtist else { return }
                onOpenArtist?(artist)
            },
            onOpenBook: { presentCurrentBook() },
            onShowChapterList: { showChapterList = true },
            onOpenInAppleMusic: {
                guard let url = appleMusicCatalogURL else { return }
                openURL(url)
            },
            onShare: { shareSong = player.currentSong },
            onShowCastPicker: { showCastPicker = true },
            onToggleLyricsTranslation: {
                LyricsTranslationSettingsStore.shared.isEnabled.toggle()
            },
            onShowSleepTimer: { showSleepTimer = true },
            onToggleShuffle: { player.shuffleEnabled.toggle() },
            onCycleRepeatMode: { cycleRepeatMode() },
            onStartMedley: {
                let songs = medleyCandidateSongs
                if player.medleyNeedsDataUsageConfirmation(for: songs) {
                    pendingMedleySongs = songs
                } else {
                    Task { await player.playMedley(songs) }
                }
            },
            onContinueMedleySongInFull: {
                Task { await player.continueCurrentMedleySongInFull() }
            },
            onStartKaraoke: { showKaraoke = true },
            onDelete: { showDeleteConfirm = true }
        )
        .equatable()
    }

    // MARK: - Ambient background from cover dominant color

    private var backgroundGradient: some View {
        let hasArtworkTheme = presentationHasArtworkTheme
        let strength = AppThemePreferences.normalizedAmbientStrength(ambientStrength)
        let accentOpacity = (hasArtworkTheme
            ? appearance.artworkAccentOpacity
            : appearance.fallbackAccentOpacity) * strength
        let lowerAccentOpacity = (hasArtworkTheme
            ? appearance.artworkLowerAccentOpacity
            : appearance.fallbackLowerAccentOpacity) * strength
        let lightOverlay = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: hasArtworkTheme,
            usesIncreasedContrast: colorSchemeContrast == .increased,
            strength: strength
        )
        let darkOverlay = NowPlayingAmbientLegibilityPolicy.darkOverlay(
            paletteLuminance: presentationArtworkLuminance,
            primaryOpacity: accentOpacity,
            secondaryOpacity: lowerAccentOpacity,
            usesIncreasedContrast: colorSchemeContrast == .increased
        )

        return ZStack {
            AdaptiveNowPlayingBackdrop(
                baseColor: appearance.backgroundBase,
                primaryAccent: presentationAccentColor,
                secondaryAccent: presentationSecondaryAccent,
                darkAccent: presentationDarkAccent,
                primaryOpacity: accentOpacity,
                secondaryOpacity: lowerAccentOpacity,
                hasArtworkPalette: hasArtworkTheme,
                isVisible: isNowPlayingSurfaceExposed,
                isSceneActive: isVisualSceneActive,
                isPlaying: player.isPlaying,
                paletteVibrancy: presentationArtworkVibrancy,
                paletteLuminance: presentationArtworkLuminance
            )

            if appearance.isLight {
                // Keep a stable light surface for dark controls without
                // washing the cover-driven hue back to near-neutral.
                LinearGradient(
                    colors: [
                        .white.opacity(lightOverlay.topOpacity),
                        .white.opacity(lightOverlay.bottomOpacity)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                // Bright covers receive a little more local protection while
                // the extracted color field remains visible around the art.
                LinearGradient(
                    stops: [
                        .init(
                            color: .black.opacity(darkOverlay.topOpacity),
                            location: 0
                        ),
                        .init(
                            color: .black.opacity(darkOverlay.middleOpacity),
                            location: 0.56
                        ),
                        .init(
                            color: .black.opacity(darkOverlay.bottomOpacity),
                            location: 1
                        )
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .animation(
            .easeInOut(duration: AmbientBackdropTuning.transitionDuration),
            value: presentationThemeColorID
        )
        .allowsHitTesting(false)
    }

    // MARK: - Full Lyrics

    private var lyricsFullView: some View {
        LyricsScrollView(
            lyrics: lyrics,
            lyricsWritingDirection: lyricsWritingDirection,
            lyricsRevision: lyricsRevision,
            isResolvingLyrics: isResolvingLyrics,
            player: player,
            songID: player.currentSong?.id,
            isSceneActive: isVisualSceneActive,
            isScrapingCurrentSong: isScrapingCurrentSong,
            canTranscribeAudio: canTranscribeCurrentSongAudio,
            isScrapeActionUnavailable: isScrapeActionUnavailable,
            onAutomaticScrape: { startAutomaticLyricsScrape() },
            onTranscribeAudio: { openAudioTranscriptionEditor() },
            onBackgroundTap: {
                if isLyricsImmersive {
                    // ScrollView owns the reliable surface gesture. Routing the
                    // immersive tap through it avoids the scroll recognizer
                    // swallowing the outer ZStack tap after chrome auto-hides.
                    handleImmersiveContentTap()
                } else {
                    setStandardLyricsVisible(false)
                }
            },
            onShareLyricLine: { lineID in
                presentLyricPoster(anchorLineID: lineID)
            },
            translatedTextByLineID: lyricTranslationsByLineID,
            translationActivity: lyricsTranslationActivity
        )
    }

    private func nowPlayingSongHeader(
        titleFont: Font,
        metadataFont: Font,
        showsQuality: Bool = false,
        inlineActions: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(player.currentSong?.title ?? "")
                    .font(titleFont.weight(.bold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .pmAnimation(.trackChange, value: player.currentSong?.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                if showsQuality, let song = player.currentSong, song.audioQuality != .standard {
                    AudioQualityBadge(quality: song.audioQuality)
                        .fixedSize()
                }

                HStack(spacing: 4) {
                    musicVideoToggleButton(font: .title3, trailing: 0)
                    // 「我喜欢」是音乐歌单, 有声内容不出现。竖栏那一列里已经有的就不在这里重复。
                    if inlineActions, !usesSpokenWordTransport {
                        Button { toggleLikedCurrent() } label: {
                            nowPlayingActionIcon(
                                symbol: isCurrentLiked ? "heart.fill" : "heart",
                                tint: isCurrentLiked ? .red : appearance.secondary,
                                isSelected: isCurrentLiked
                            )
                        }
                        .frame(width: 44, height: 44)
                        .buttonStyle(.plain)
                        .disabled(player.currentSong == nil)
                        .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                    }
                    if inlineActions {
                        moreMenu
                    }
                }
                .fixedSize()
            }
            nowPlayingMetadataLinks(font: metadataFont)
            nowPlayingChapterLink
            nowPlayingMedleyBadge
        }
    }

    /// 有声内容的一行小控件: 当前章节(点开是章节与书签列表)、上一章/下一章、
    /// 加书签、听书速度。放在这里而不是控件区: 三套布局共用这个头部, 所以在
    /// 竖屏、横屏和 iPad 上都在同一个位置。音乐且不带章节时整行不出现。
    @ViewBuilder
    private var nowPlayingChapterLink: some View {
        let isSpokenWord = player.currentItemIsSpokenWord && !player.isLiveRadio
        if player.hasChapters || isSpokenWord {
            HStack(spacing: 14) {
                if player.hasChapters || hasCurrentBookmarks {
                    Button { showChapterList = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: player.hasChapters ? "list.bullet.indent" : "bookmark")
                                .font(.caption2)
                            Text(player.hasChapters
                                ? (player.currentChapter?.title ?? String(localized: "chapters_title"))
                                : String(localized: "spoken_word_bookmarks_title"))
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("chapters_title"))
                    .layoutPriority(1)
                }

                if player.hasChapters {
                    Button { player.seekToPreviousChapter() } label: {
                        Image(systemName: "backward.end")
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(player.currentChapterIndex == nil)
                    .accessibilityLabel(Text("spoken_word_previous_chapter"))

                    Button { player.seekToNextChapter() } label: {
                        Image(systemName: "forward.end")
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled((player.currentChapterIndex ?? -1) + 1 >= player.spokenWordChapters.count)
                    .accessibilityLabel(Text("spoken_word_next_chapter"))
                }

                if isSpokenWord {
                    Button {
                        if player.addSpokenWordBookmark() { bookmarkFeedbackToken += 1 }
                    } label: {
                        Image(systemName: "bookmark")
                            .symbolEffect(.bounce, value: bookmarkFeedbackToken)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.success, trigger: bookmarkFeedbackToken)
                    .accessibilityLabel(Text("spoken_word_add_bookmark"))

                    Menu {
                        Picker(selection: spokenWordRateBinding) {
                            ForEach(SpokenWordPlaybackRatePolicy.presets, id: \.self) { rate in
                                Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate)).tag(rate)
                            }
                        } label: {
                            Text("spoken_word_playback_rate")
                        }
                    } label: {
                        Text(verbatim: SpokenWordPlaybackRatePolicy.label(
                            for: playbackSettings.outputMode == .effects
                                ? player.currentSpokenWordRate
                                : 1
                        ))
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 36, minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .disabled(playbackSettings.outputMode != .effects)
                    .accessibilityLabel(Text("spoken_word_playback_rate"))
                }
            }
            .font(.footnote)
            .foregroundStyle(appearance.secondary)
            .padding(.top, 2)
        }
    }

    /// What "medley from the queue" plays: the current song and what is
    /// still to come in this round, as their library rows.
    private var medleyCandidateSongs: [Song] { player.medleyCandidatesFromQueue }

    /// Shown while a medley plays, with the way out: keep listening to this
    /// song in full.
    @ViewBuilder
    private var nowPlayingMedleyBadge: some View {
        if player.isMedleyActive {
            Button {
                Task { await player.continueCurrentMedleySongInFull() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.caption2)
                    Text(String(
                        format: String(localized: "medley_badge_format"),
                        playbackSettings.medleySegmentSeconds
                    ))
                    .lineLimit(1)
                    Text("·")
                    Text("medley_continue_full_short")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(appearance.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(Text("medley_continue_full"))
        }
    }

    private var hasCurrentBookmarks: Bool {
        guard let songID = player.currentSong?.id else { return false }
        _ = SpokenWordStore.shared.revision
        return !SpokenWordStore.shared.bookmarks(forSongID: songID).isEmpty
    }

    private var spokenWordRateBinding: Binding<Float> {
        Binding(
            get: { player.currentSpokenWordRate },
            set: { player.setSpokenWordRateForCurrentBook($0) }
        )
    }

    @ViewBuilder
    private var nowPlayingReviewSection: some View {
        if let song = player.currentSong {
            LibraryReviewSection(
                subject: .song(song.id),
                compact: true,
                onArtwork: true,
                foregroundColor: appearance.primary,
                // 抵消进度条 44pt 命中区里不可见的上半部分。这个值原本还要
                // 兼顾评分卡片自己的外边界，卡片去掉之后星级直接暴露在页面上，
                // 再留 28pt 就显得这一块从上文飘走了。
                topSpacing: 14
            )
        }
    }

    /// - Parameter lineLimit: 手机横屏的右栏按固定高度排版，多出来的一行会顶开
    ///   下面的进度条与传输键，所以那边传 1。
    @ViewBuilder
    private func nowPlayingMetadataLinks(font: Font, lineLimit: Int = 2) -> some View {
        let artistName = currentArtistDisplayName
        let albumTitle = player.currentSong?.albumTitle ?? ""
        let metadata = [artistName, albumTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        let label = Text(verbatim: metadata)
            .font(font)
            .foregroundStyle(appearance.secondary)
            .multilineTextAlignment(.leading)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .pmAnimation(.trackChange, value: player.currentSong?.id)
            .frame(maxWidth: .infinity, alignment: .leading)

        // 有声内容这一行点开是它所在的书: 艺人页与专辑页只收音乐, 对它是空的。
        let opensBook = usesSpokenWordTransport && player.currentBookID != nil
        if opensBook {
            Button { presentCurrentBook() } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("spoken_word_go_to_book"))
        } else if (onOpenArtist != nil && !currentArtists.isEmpty) || canOpenCurrentAlbum {
            Menu {
                if onOpenArtist != nil {
                    ForEach(currentArtists) { artist in
                        Button { onOpenArtist?(artist) } label: {
                            Label(artist.name, systemImage: "music.mic")
                        }
                    }
                }
                if let album = currentAlbum, canOpenCurrentAlbum {
                    Button { presentAlbum(album, prefersMatchedArtworkSource: !showLyrics) } label: {
                        Label(album.title, systemImage: "square.stack")
                    }
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    // MARK: - Helpers

    /// 竖屏播放键:实心圆。深色外观下白圆配封面的深色调图标,浅色外观下反过来,
    /// 取不到封面色时图标用页面底色 —— 两种外观下都是高对比。
    private var portraitPlayButtonLabel: some View {
        let glyphTint: Color = (!appearance.isLight && presentationHasArtworkTheme)
            ? presentationDarkAccent
            : appearance.backgroundBase
        return ZStack {
            Circle()
                .fill(appearance.primary)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)

            if player.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(glyphTint)
                    .pmFadeTransition(motion: .control)
            } else {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(glyphTint)
                    .offset(x: player.isPlaying ? 0 : 2)
                    .contentTransition(.symbolEffect(.replace))
                    // symbolEffect 管不到 ProgressView 这一跳, 用透明度接上。
                    .pmFadeTransition(motion: .control)
            }
        }
        .frame(width: 72, height: 72)
        .contentShape(Circle())
    }

    /// 底栏中间的音质胶囊:格式 · 采样率 · 音乐源(多于一个源时才写源)。
    @ViewBuilder
    private var portraitQualityChip: some View {
        if let song = player.currentSong {
            HStack(spacing: 4) {
                Text(song.fileFormat.displayName)
                    .monospaced()
                if let sr = song.sampleRate {
                    Text("·")
                    Text("\(sr / 1000)kHz").monospaced()
                }
                if sourcesStore.sources.count > 1,
                   let source = sourcesStore.source(id: song.sourceID) {
                    Text("·")
                    Image(systemName: source.type.iconName)
                    Text(source.name)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(appearance.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .nowPlayingAdaptiveGlass(Capsule(), appearance: appearance, tint: appearance.primary)
            .accessibilityElement(children: .combine)
        } else {
            Color.clear.frame(height: 26)
        }
    }

    /// 竖屏的播放键。分组面板那一套(`Player.sheetActions`)是实心圆,经典是系统的圆形符号。
    @ViewBuilder
    private var portraitTransportPlayButton: some View {
        if skin.usesSheetActionsPlayer {
            Button { player.togglePlayPause() } label: {
                portraitPlayButtonLabel
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)
            .accessibilityLabel(player.isPlaying
                ? String(localized: "a11y_pause")
                : String(localized: "a11y_play"))
        } else {
            Button { player.togglePlayPause() } label: {
                ZStack {
                    // Anchor sizing so the button doesn't reflow.
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56)).opacity(0)
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.large)
                            .tint(appearance.primary)
                            .pmFadeTransition(motion: .control)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56)).foregroundStyle(appearance.primary)
                            .contentTransition(.symbolEffect(.replace))
                            // symbolEffect 管不到 ProgressView 这一跳, 用透明度接上。
                            .pmFadeTransition(motion: .control)
                    }
                }
            }
            .disabled(player.isLoading)
            .accessibilityLabel(player.isPlaying
                ? String(localized: "a11y_pause")
                : String(localized: "a11y_play"))
        }
    }

    private func ctrlBtn(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body)
                .foregroundStyle(active ? themedControlAccent : appearance.tertiary)
                .playbackToggleHighlight(
                    isActive: active,
                    tint: themedControlAccent,
                    diameter: 32
                )
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Self.iconA11yLabel(icon))
        .accessibilityValue(active
            ? String(localized: "a11y_value_on")
            : String(localized: "a11y_value_off"))
    }

    private var themedControlAccent: Color {
        guard isPresentationSettled,
              theme.colorID != "default" else { return appearance.primary }
        return appearance.isLight ? presentationDarkAccent : presentationAccentColor
    }

    private var presentationHasArtworkTheme: Bool {
        isPresentationSettled && theme.hasArtworkAmbient
    }

    private var presentationAccentColor: Color {
        isPresentationSettled ? theme.accentColor : theme.baseAccent
    }

    private var presentationSecondaryAccent: Color {
        isPresentationSettled ? theme.secondaryAccent : theme.baseDarkAccent
    }

    private var presentationSecondaryDarkAccent: Color {
        isPresentationSettled ? theme.secondaryDarkAccent : theme.baseDarkAccent
    }

    private var presentationDarkAccent: Color {
        isPresentationSettled ? theme.darkAccent : theme.baseDarkAccent
    }

    private var presentationArtworkVibrancy: Double {
        isPresentationSettled ? theme.artworkVibrancy : 0
    }

    private var presentationArtworkLuminance: Double {
        isPresentationSettled ? theme.artworkLuminance : 0.18
    }

    private var presentationThemeColorID: String {
        isPresentationSettled ? theme.colorID : "presentation-staging"
    }

    /// SF Symbol -> VoiceOver 标签的映射, 用在 transport 控件上。
    private static func iconA11yLabel(_ icon: String) -> LocalizedStringKey {
        switch icon {
        case "shuffle": return "a11y_shuffle"
        case "repeat", "repeat.1": return "a11y_repeat"
        default: return "a11y_button_generic"
        }
    }

    private func loadLyrics() async {
        lyricsLoadRevision &+= 1
        let loadRevision = lyricsLoadRevision
        beginLyricsResolution(loadRevision)
        guard let song = player.currentSong else { setLyrics([]); return }
        let loadStart = Date()

        // Apple Music 优先走 MusicKit 原生 catalog 歌词。先查
        // MetadataAssetStore songID cache 命中直接显示 (cache 一份避免每次切
        // 歌都走 catalog 网络); miss 再问 MusicKit, 拿到 TTML 解析后写回 cache。
        // 全失败 → setLyrics([])，emptyLyricsView 仍允许用户走和 macOS 相同的
        // 在线歌词刮削链路，而不是只能跳转 Apple Music。
        if song.sourceID == AppleMusicLibraryService.systemSourceID {
            let cacheSnapshot = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
            if let cached = cacheSnapshot,
               !cached.isEmpty {
                plog(String(format: "📜 Apple Music lyrics cache hit '%@' (%d lines)",
                            song.title, cached.count))
                setLyricsIfCurrent(cached, for: song, loadRevision: loadRevision)
                return
            }
            do {
                if let lyrics = try await AppServices.shared.appleMusicLibrary
                    .fetchLyrics(forAmID: song.filePath),
                   !lyrics.isEmpty {
                    guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
                    let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                        lyrics,
                        forSongID: song.id,
                        expectedFingerprint: cacheSnapshot.map(LyricsDocumentFingerprint.init(lines:)),
                        force: false
                    )
                    guard wrote else {
                        if let latest = await MetadataAssetStore.shared
                            .cachedLyrics(forSongID: song.id),
                           !latest.isEmpty {
                            setLyricsIfCurrent(latest, for: song, loadRevision: loadRevision)
                        }
                        // 这条分支可能一行歌词都没写出去, 但这次查询已经结束。
                        endLyricsResolution(loadRevision)
                        return
                    }
                    plog(String(format: "📜 Apple Music lyrics fetched '%@' in %.0fms (%d lines)",
                                song.title, Date().timeIntervalSince(loadStart) * 1000, lyrics.count))
                    setLyricsIfCurrent(lyrics, for: song, loadRevision: loadRevision)
                    return
                } else {
                    plog("📜 Apple Music lyrics: no official lyrics for '\(song.title)'")
                }
            } catch {
                plog("⚠️Apple Music lyrics fetch failed for '\(song.title)': \(error.localizedDescription)")
            }
            setLyricsIfCurrent([], for: song, loadRevision: loadRevision)
            return
        }

        // Tier 1a: songID hash cache —— 即使 NAS path 也读 (stale-while-revalidate)。
        // 历史污染 cache 现在通过 trustedSource:false + sidecar 写后回写 cache
        // 在根源上修复, 这里允许 cache hit 立即显示, 后台再校验。
        if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !cached.isEmpty {
            plog(String(format: "📜 loadLyrics '%@' Tier1a hit (songID hash) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, cached.count))
            guard setLyricsIfCurrent(cached, for: song, loadRevision: loadRevision) else { return }
            let sourceType = sourcesStore.source(id: song.sourceID)?.type
            if LyricsAuthoritativeSourcePolicy.supportsServerDocument(sourceType) {
                runServerLyricsRevalidation(
                    song: song,
                    sourceType: sourceType,
                    currentCache: cached,
                    loadRevision: loadRevision
                )
            } else if (song.lyricsFileName ?? "").contains("/") {
                // NAS sidecars retain their existing source-of-truth refresh.
                runLyricsTier3Fetch(
                    song: song,
                    currentCache: cached,
                    loadRevision: loadRevision
                )
            }
            return
        }

        let lyricsRefIsRemote = (song.lyricsFileName ?? "").contains("/")

        // Tier 1b: legacy named ref (only for non-NAS path)
        if !lyricsRefIsRemote,
           let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
            guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
            await MetadataAssetStore.shared.cacheLyrics(cached, forSongID: song.id)
            plog(String(format: "📜 loadLyrics '%@' Tier1b hit (named ref) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, cached.count))
            setLyricsIfCurrent(cached, for: song, loadRevision: loadRevision); return
        }

        // Tier 2: Check local audio cache for a lyrics sidecar (filesystem only, zero network)
        if let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
            await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
            plog(String(format: "📜 loadLyrics '%@' Tier2 hit (audio cache sidecar) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, parsed.count))
            setLyricsIfCurrent(parsed, for: song, loadRevision: loadRevision); return
        }

        // Tier 3: 首次必走 (无 cache, 无本地 sidecar)
        guard setLyricsIfCurrent([], for: song, loadRevision: loadRevision) else { return }
        // 上一行已经把"没有歌词"写进 UI, 但 Tier 3 还在路上。重新接上加载态,
        // 否则联网取词的这几百毫秒里播放页会先谎报一次"暂无歌词, 去刮削"。
        beginLyricsResolution(loadRevision)
        plog(String(format: "📜 loadLyrics '%@' miss Tier1+2, falling to Tier3 (NAS fetch)", song.title))
        runLyricsTier3Fetch(song: song, currentCache: nil, loadRevision: loadRevision)
    }

    private func runServerLyricsRevalidation(
        song: Song,
        sourceType: MusicSourceType?,
        currentCache: [LyricLine],
        loadRevision: UInt
    ) {
        let capturedSourceManager = sourceManager
        Task { @MainActor in
            let result = await LyricsLoader.refreshFromSource(
                for: song,
                sourceType: sourceType,
                sourceManager: capturedSourceManager,
                cachedDocument: currentCache,
                trigger: .automatic
            )
            guard isCurrentLyricsLoad(loadRevision, songID: song.id),
                  case let .updated(updated) = result else { return }
            setLyrics(updated)
        }
    }

    private func reloadLyricsFromSource() {
        guard !isReloadingLyricsFromSource,
              let song = player.currentSong else { return }
        let sourceType = sourcesStore.source(id: song.sourceID)?.type
        guard LyricsAuthoritativeSourcePolicy.supportsServerDocument(sourceType) else {
            sourceLyricsReloadAlertMessage = String(
                localized: "lyrics_source_reload_unsupported"
            )
            return
        }

        let currentDocument = lyrics.isEmpty ? nil : lyrics
        sourceLyricsReloadingSongID = song.id
        Task { @MainActor in
            let result = await LyricsLoader.refreshFromSource(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                cachedDocument: currentDocument,
                trigger: .explicit
            )
            if sourceLyricsReloadingSongID == song.id {
                sourceLyricsReloadingSongID = nil
            }
            guard LyricsAuthoritativeSourcePolicy.shouldApply(
                responseForSongID: song.id,
                currentlyPlayingSongID: player.currentSong?.id
            ) else { return }

            switch result {
            case let .updated(updated):
                setLyrics(updated)
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_success"
                )
            case .unchanged, .throttled:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_unchanged"
                )
            case .emptyPreservingCache:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_empty_kept"
                )
            case .failedPreservingCache:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_failed_kept"
                )
            case .unsupported:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_unsupported"
                )
            }
        }
    }

    /// Tier 3 NAS fetch + 校验。currentCache != nil 时为 stale-while-revalidate
    /// 模式: 已 setLyrics(currentCache), 这里只在 fingerprint 不一致时 update UI。
    private func runLyricsTier3Fetch(
        song: Song,
        currentCache: [LyricLine]?,
        loadRevision: UInt
    ) {
        let capturedSourceManager = sourceManager
        let capturedScraperService = scraperService
        let songID = song.id
        let songTitle = song.title
        let isRefresh = currentCache != nil

        Task {
            // Tier 3 的出口有十来个, 统一在这里收尾: 首次加载的占位只能由这次
            // 请求结束, 不论它是拿到歌词、拿到空结果还是抛错。
            defer { endLyricsResolution(loadRevision) }
            let tier3Start = Date()
            // 连接器已解析且不是服务端曲库源时才为 true：此时 sidecar 缺失才是
            // 「源里确实没有歌词」，首次加载可以进 Tier4 在线兜底。
            var resolvedPlainSource = false
            do {
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                let connector = try await capturedSourceManager.auxiliaryConnector(for: song)
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                let connectMs = Date().timeIntervalSince(tier3Start) * 1000

                // 服务端歌词 (Subsonic getLyricsBySongId 等) —— 服务端曲库源不是
                // "同目录歌词 sidecar" 模型, 走 connector 的 ServerLyricsConnector 能力。
                // 服务端源在此终结: 即使服务端没歌词也不去 fetchRange sidecar
                // (对 Subsonic 那会拉到音频流, 既浪费又解析失败)。
                if let server = connector as? ServerLyricsConnector {
                    let sourceResult = await LyricsLoader.refreshFromResolvedServer(
                        for: song,
                        server: server,
                        cachedDocument: currentCache,
                        trigger: isRefresh ? .automatic : .initial
                    )
                    guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                    if case let .updated(parsed) = sourceResult {
                        plog(String(format: "📜 loadLyrics '%@' server-lyrics OK in %.0fms (%d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, parsed.count))
                        setLyrics(parsed)
                        return
                    }
                    if sourceResult == .unchanged || sourceResult == .throttled {
                        return
                    }
                    guard sourceResult == .emptyPreservingCache else {
                        if let latest = await MetadataAssetStore.shared
                            .cachedLyrics(forSongID: songID),
                           !latest.isEmpty,
                           isCurrentLyricsLoad(loadRevision, songID: songID) {
                            setLyrics(latest)
                        }
                        return
                    }
                    plog(String(format: "📜 loadLyrics '%@' server-lyrics empty (connect=%.0fms)", songTitle, connectMs))

                    // Airsonic and other read-only servers often delegate
                    // lyrics to an external provider. A provider-side 404 is
                    // not a terminal app result: fall through to the same
                    // title-compatible online lyrics pipeline used by manual
                    // scraping, then bind the result to this local song ID.
                    if LyricsLoader.songAcceptsAutomaticOnlineLyrics(song),
                       let online = await capturedScraperService.fetchOnlineLyrics(
                        title: song.title,
                        artist: song.artistName,
                        album: song.albumTitle,
                        duration: song.duration > 0 ? song.duration : nil
                    ), !online.isEmpty {
                        guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                        let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                            online,
                            forSongID: songID,
                            expectedFingerprint: currentCache.map(
                                LyricsDocumentFingerprint.init(lines:)
                            ),
                            force: false
                        )
                        guard wrote else {
                            if let latest = await MetadataAssetStore.shared
                                .cachedLyrics(forSongID: songID),
                               !latest.isEmpty,
                               isCurrentLyricsLoad(loadRevision, songID: songID) {
                                setLyrics(latest)
                            }
                            return
                        }
                        plog(String(format: "📜 loadLyrics '%@' online fallback OK in %.0fms (%d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, online.count))
                        if isCurrentLyricsLoad(loadRevision, songID: songID) {
                            setLyrics(online)
                        }
                    }
                    return
                }

                resolvedPlainSource = true

                let songDir = (song.filePath as NSString).deletingLastPathComponent
                let baseName = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                let lyricsPath: String
                if let ref = song.lyricsFileName, ref.contains("/") {
                    lyricsPath = ref
                } else if let ref = song.lyricsFileName,
                          PrimuseConstants.readableLyricsExtensions.contains(
                            (ref as NSString).pathExtension.lowercased()
                          ) {
                    // 扫描记下的同名歌词可能是 .ttml/.lys/.vtt 等；只推 .lrc 会把
                    // 它们全都读空。本机缓存名(.json)仍走下面的同名推断。
                    lyricsPath = (songDir as NSString).appendingPathComponent(ref)
                } else {
                    lyricsPath = (songDir as NSString).appendingPathComponent("\(baseName).lrc")
                }

                let fetchStart = Date()
                let lyricsData = try await connector.fetchRange(
                    path: lyricsPath,
                    offset: 0,
                    length: 256 * 1024,
                    priority: .background
                )
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                let fetchMs = Date().timeIntervalSince(fetchStart) * 1000
                guard let lyricsContent = String(data: lyricsData, encoding: .utf8) else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 sidecar not utf8 (connect=%.0fms fetch=%.0fms)", songTitle, connectMs, fetchMs))
                    if !isRefresh {
                        await applyAutomaticOnlineLyrics(
                            song: song, currentCache: currentCache, loadRevision: loadRevision
                        )
                    }
                    return
                }
                var parsed = LyricsParser.parse(lyricsContent)
                guard !parsed.isEmpty else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 sidecar empty after parse (connect=%.0fms fetch=%.0fms %dB)", songTitle, connectMs, fetchMs, lyricsData.count))
                    if !isRefresh {
                        await applyAutomaticOnlineLyrics(
                            song: song, currentCache: currentCache, loadRevision: loadRevision
                        )
                    }
                    return
                }

                // 只有 `<歌名>.<语言>-orig.vtt` 这类原声轨才可能有译文轨。先按
                // 文件名判断, 免得每首歌都为此多列一次目录; refresh 也要走同一条
                // 合并, 否则每次刷新都会把译文再抹掉一遍。
                if let tagged = LyricsSidecarSelectionPolicy.languageTaggedComponents(
                    ofSidecarNamed: (lyricsPath as NSString).lastPathComponent
                ), LyricsSidecarSelectionPolicy.marksOriginalTrack(tagged.tag),
                   let track = await LyricsLoader.translationTrack(
                       for: song,
                       connector: connector
                   ) {
                    parsed = await LyricsLoader.mergingTranslationTrack(
                        into: parsed,
                        track: track,
                        connector: connector
                    )
                    guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                }

                // Refresh 模式: cache 与 NAS 一致就静默退出, 不写盘不 update UI
                if let currentCache,
                   Self.lyricsFingerprint(parsed) == Self.lyricsFingerprint(currentCache) {
                    plog(String(format: "📜 lyrics refresh '%@' cache fresh, no update (%.0fms)", songTitle, Date().timeIntervalSince(tier3Start) * 1000))
                    return
                }

                let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                    parsed,
                    forSongID: songID,
                    expectedFingerprint: currentCache.map(
                        LyricsDocumentFingerprint.init(lines:)
                    ),
                    force: false
                )
                if !wrote {
                    // 写入被「不降级」拦截 (现存字级, NAS 是行级 sidecar 自动
                    // 写回的) —— UI 保持原 cache 显示, 不切到行级。
                    plog(String(format: "📜 lyrics refresh '%@' SKIP downgrade (%.0fms, cache word-level kept)", songTitle, Date().timeIntervalSince(tier3Start) * 1000))
                    return
                }
                if isRefresh {
                    plog(String(format: "📜 lyrics refresh '%@' cache STALE → updated (%.0fms, %d→%d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, currentCache?.count ?? 0, parsed.count))
                } else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 OK in %.0fms (connect=%.0fms fetch=%.0fms %dB %d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, connectMs, fetchMs, lyricsData.count, parsed.count))
                }
                if isCurrentLyricsLoad(loadRevision, songID: songID) {
                    setLyrics(parsed)
                }
            } catch {
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                if isRefresh {
                    // refresh 失败不影响 user, 已经显示了 cache
                    plog(String(format: "📜 lyrics refresh '%@' FAILED in %.0fms (cache still shown): %@", songTitle, Date().timeIntervalSince(tier3Start) * 1000, error.localizedDescription))
                } else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 FAILED in %.0fms: %@", songTitle, Date().timeIntervalSince(tier3Start) * 1000, error.localizedDescription))
                    if resolvedPlainSource {
                        await applyAutomaticOnlineLyrics(
                            song: song, currentCache: currentCache, loadRevision: loadRevision
                        )
                    }
                }
            }
        }
    }

    /// Tier4：普通源首次加载确实没有歌词时，自动向在线歌词源取一次（开关、
    /// 台账与写缓存都在 `LyricsLoader.automaticOnlineLyrics` 里）。
    private func applyAutomaticOnlineLyrics(
        song: Song,
        currentCache: [LyricLine]?,
        loadRevision: UInt
    ) async {
        let songID = song.id
        guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
        let start = Date()
        guard let online = await LyricsLoader.automaticOnlineLyrics(
            for: song,
            expectedFingerprint: currentCache.map(LyricsDocumentFingerprint.init(lines:))
        ), !online.isEmpty else { return }
        guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
        plog(String(format: "📜 loadLyrics '%@' Tier4 online OK in %.0fms (%d lines)", song.title, Date().timeIntervalSince(start) * 1000, online.count))
        setLyrics(online)
    }

    /// Parser-generated IDs change on every load; compare the complete stable
    /// lyrics document instead, including middle rows, timing, syllables and
    /// structured cue metadata.
    private static func lyricsFingerprint(_ lines: [LyricLine]) -> String {
        LyricsDocumentFingerprint(lines: lines).rawValue
    }

    /// loadLyrics 的同步 tier (Tier1a/1b/2 + Apple Music) 在 await 之后写歌词
    /// 前的统一守卫: 切歌时 .task(id:) 会 cancel 旧任务, 但取消是协作式的, actor
    /// 跳跃的 await 不是取消点。除 song identity 外还校验 load revision，避免同一
    /// 首歌的旧 Tier 3 请求晚到后覆盖刚刮削出来的新歌词。
    @discardableResult
    private func setLyricsIfCurrent(
        _ value: [LyricLine],
        for song: Song,
        loadRevision: UInt
    ) -> Bool {
        guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return false }
        setLyrics(value)
        return true
    }

    private func isCurrentLyricsLoad(_ loadRevision: UInt, songID: String) -> Bool {
        !Task.isCancelled
            && lyricsLoadRevision == loadRevision
            && player.currentSong?.id == songID
    }

    /// 歌词结果未知: 本地缓存没命中, 正在问服务端 / 在线歌词源。歌词区这时
    /// 显示占位骨架, 而不是"暂无歌词 + 去刮削"。
    private var isResolvingLyrics: Bool {
        lyricsResolvingRevision == lyricsLoadRevision
    }

    private func beginLyricsResolution(_ loadRevision: UInt) {
        lyricsResolvingRevision = loadRevision
        lyricsResolutionTimeoutTask?.cancel()
        lyricsResolutionTimeoutTask = Task {
            try? await Task.sleep(for: Self.lyricsResolutionTimeout)
            guard !Task.isCancelled else { return }
            endLyricsResolution(loadRevision)
        }
    }

    private func endLyricsResolution(_ loadRevision: UInt) {
        guard lyricsResolvingRevision == loadRevision else { return }
        clearLyricsResolution()
    }

    private func clearLyricsResolution() {
        lyricsResolvingRevision = nil
        lyricsResolutionTimeoutTask?.cancel()
        lyricsResolutionTimeoutTask = nil
    }

    private func setLyrics(_ value: [LyricLine]) {
        clearLyricsResolution()
        lyricsWritingDirection = LyricWritingDirectionPolicy.resolve(in: value)
        lyrics = value
        lyricsRevision &+= 1
        let wordLevelCount = value.filter { $0.isWordLevel }.count
        plog("📜 setLyrics: lines=\(value.count) wordLevelLines=\(wordLevelCount) direction=\(String(describing: lyricsWritingDirection)) firstSyllables=\(value.first?.syllables?.count ?? -1)")
        // currentLineIndex / hasWordLevelLyrics 已迁移到 LyricsScrollView 子 view,
        // 子 view 自己 onChange(of: songID) 重置 + computed property 算 hasWord。
        consumePendingLyricsJump(from: value)
    }

    /// 搜索页点歌词命中结果时, player 上挂了一个 pending hint。歌词刚加载
    /// 完就在这里 fuzzy match 找对应行的 timestamp 并 seek。命中即清, 一次性。
    /// songID 必须匹配当前 currentSong, 避免用户快速切歌时 jump 到别首。
    private func consumePendingLyricsJump(from lines: [LyricLine]) {
        guard let hint = player.pendingLyricsJump,
              let currentID = player.currentSong?.id,
              hint.songID == currentID,
              !lines.isEmpty else { return }
        // snippet 可能包含上下文行 ("...prev\nmatch\nnext..."), 提取最长一行做匹配。
        let needle = hint.snippet
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .max(by: { $0.count < $1.count }) ?? hint.snippet
        guard !needle.isEmpty else { player.clearPendingLyricsJump(); return }
        if let match = lines.first(where: { $0.text.localizedCaseInsensitiveContains(needle) }) {
            player.seek(to: max(0, match.timestamp - 0.3))
            // 用户来这是为了看歌词上下文, 默认切到歌词面板
            setStandardLyricsVisible(true)
        }
        player.clearPendingLyricsJump()
    }



    /// Always open the candidate/preview sheet. Apple Music used to run a
    /// lyrics-only automatic scrape immediately here, which meant tapping the
    /// nominally manual action silently overwrote the cached lyrics and could
    /// choose a different provider result on every tap.
    private func openScrapeForCurrentSong() {
        guard let displayedSong = player.currentSong else { return }
        guard !isScrapeActionUnavailable else { return }

        scraperSettings.performSingleSongScrapeAction(
            from: .nowPlayingOptions,
            onProceed: { openScrapeForCurrentSongWithEnabledSource(displayedSong) },
            onRequireSource: { showNoScraperSourceAlert = true }
        )
    }

    private func openScrapeForCurrentSongWithEnabledSource(_ displayedSong: Song) {
        guard displayedSong.sourceID == AppleMusicLibraryIdentity.sourceID else {
            scrapeTargetSong = displayedSong
            return
        }

        // Resolve the transient MusicKit catalog identity before presenting
        // the sheet. Await alias preservation first so an older cached lyric
        // cannot race with the user's later Apply action.
        isResolvingScrapeTarget = true
        Task { @MainActor in
            defer { isResolvingScrapeTarget = false }
            let canonical = AppServices.shared.appleMusicLibrary.canonicalLibrarySong(for: displayedSong)
            if canonical.id != displayedSong.id {
                _ = await MetadataAssetStore.shared.preserveLyricsAlias(
                    fromSongID: displayedSong.id,
                    toSongID: canonical.id
                )
                guard player.currentSong?.id == displayedSong.id
                        || player.currentSong?.id == canonical.id else { return }
                player.adoptCanonicalAppleMusicSong(canonical, replacing: displayedSong.id)
            } else {
                guard player.currentSong?.id == canonical.id else { return }
            }
            scrapeTargetSong = canonical
        }
    }

    /// The empty lyrics state is an explicit one-tap automatic action. Keep it
    /// separate from the scrape icons, whose contract is to present the
    /// automatic/manual candidate sheet.
    private func startAutomaticLyricsScrape() {
        guard let displayedSong = player.currentSong,
              !isScrapeActionUnavailable else { return }

        scraperSettings.performSingleSongScrapeAction(
            from: .nowPlayingAutomaticLyrics,
            onProceed: { startAutomaticLyricsScrapeWithEnabledSource(displayedSong) },
            onRequireSource: { showNoScraperSourceAlert = true }
        )
    }

    private var canTranscribeCurrentSongAudio: Bool {
        guard let song = player.currentSong else { return false }
        return intelligence.isAudioTranscriptionConfigured
            && AIAudioTranscriptionPolicy.supportsInput(format: song.fileFormat)
            && song.sourceID != AppleMusicLibraryIdentity.sourceID
            && song.cueSheetPath == nil
            && (song.duration <= 0
                || song.duration <= AIAudioTranscriptionPolicy.maximumDuration)
    }

    private func openAudioTranscriptionEditor() {
        guard canTranscribeCurrentSongAudio, let song = player.currentSong else { return }
        lyricsEditorAutoStartsAudioTranscription = true
        lyricsEditorTargetSong = song
    }

    private func startAutomaticLyricsScrapeWithEnabledSource(_ displayedSong: Song) {
        // Invalidate an in-flight Tier 3 lookup for this same song before the
        // scraper starts. Otherwise that older request can finish after the
        // freshly scraped cache write and replace the new lyrics.
        lyricsLoadRevision &+= 1

        guard displayedSong.sourceID == AppleMusicLibraryIdentity.sourceID else {
            handleAutomaticScrapeStart(
                scraperService.startSingleScrape(song: displayedSong, in: library)
            )
            return
        }

        isResolvingScrapeTarget = true
        Task { @MainActor in
            defer { isResolvingScrapeTarget = false }
            let song = AppServices.shared.appleMusicLibrary.canonicalLibrarySong(for: displayedSong)
            if song.id != displayedSong.id {
                _ = await MetadataAssetStore.shared.preserveLyricsAlias(
                    fromSongID: displayedSong.id,
                    toSongID: song.id
                )
                if player.currentSong?.id == displayedSong.id
                    || player.currentSong?.id == song.id {
                    player.adoptCanonicalAppleMusicSong(song, replacing: displayedSong.id)
                }
            }
            handleAutomaticScrapeStart(
                scraperService.startOnlineLyricsOnlyScrape(song: song, in: library)
            )
        }
    }

    private func handleAutomaticScrapeStart(
        _ result: MusicScraperService.SingleScrapeStartResult
    ) {
        switch result {
        case .started, .joined:
            break
        case .busy:
            scrapeAlertMessage = String(localized: "intent_scrape_busy")
        case .noScraperSource:
            showNoScraperSourceAlert = true
        }
    }

    private func consumeAutomaticScrapeCompletion() {
        guard let songID = player.currentSong?.id,
              let completion = scraperService.consumeSingleScrapeCompletion(
                songID: songID,
                purposes: [.metadataApply, .lyricsApply]
              ) else { return }

        guard let result = completion.result else {
            scrapeAlertMessage = String(localized: "scrape_song_failed")
            return
        }

        let updatedSong = result.song
        CachedArtworkView.invalidateCache(for: updatedSong.id)
        if let oldRef = result.originalSong.coverArtFileName {
            CachedArtworkView.invalidateCache(for: oldRef)
        }
        player.syncSongMetadata(updatedSong)
        player.forceRefreshNowPlayingArtwork()

        if player.currentSong?.id == updatedSong.id {
            if let scrapedLyrics = result.lyrics, !scrapedLyrics.isEmpty {
                lyricsLoadRevision &+= 1
                setLyrics(scrapedLyrics)
            } else {
                Task { await loadLyrics() }
            }
        }
        scrapeAlertMessage = automaticScrapeSummary(
            original: result.originalSong,
            updated: updatedSong,
            coverFound: result.coverData != nil,
            lyricsFound: result.lyrics?.isEmpty == false,
            lyricsOnly: completion.activity.key.purpose == .lyricsApply
        )
    }

    /// The empty-lyrics button applies results immediately, so its completion
    /// alert must describe every tier instead of treating lyrics as the sole
    /// success signal. The regular scrape sheet already provides a detailed
    /// before/after preview; this is the compact equivalent for one-tap use.
    private func automaticScrapeSummary(
        original: Song,
        updated: Song,
        coverFound: Bool,
        lyricsFound: Bool,
        lyricsOnly: Bool
    ) -> String {
        let lyricsStatus = lyricsFound
            ? String(localized: "lyrics_found")
            : String(localized: "no_results")
        let accuracyNotice = String(localized: "scrape_accuracy_notice")
        if lyricsOnly {
            return [
                "\(String(localized: "lyrics_word")): \(lyricsStatus)",
                accuracyNotice,
            ].joined(separator: "\n\n")
        }

        var metadataChanges: [String] = []
        if original.title != updated.title {
            metadataChanges.append(String(localized: "title_changed"))
        }
        if original.artistName != updated.artistName {
            metadataChanges.append(String(localized: "artist_changed"))
        }
        if original.albumTitle != updated.albumTitle {
            metadataChanges.append(String(localized: "album_changed"))
        }
        let otherMetadataChanged = original.year != updated.year
            || original.genre != updated.genre
            || original.trackNumber != updated.trackNumber
            || original.discNumber != updated.discNumber
        if metadataChanges.isEmpty, otherMetadataChanged {
            metadataChanges.append(String(localized: "scrape_metadata_updated"))
        }

        let metadataStatus = metadataChanges.isEmpty
            ? String(localized: "unchanged")
            : metadataChanges.joined(separator: " · ")
        let coverStatus = coverFound
            ? String(localized: "cover_found")
            : String(localized: "no_results")

        return [
            "\(String(localized: "metadata")): \(metadataStatus)",
            "\(String(localized: "cover")): \(coverStatus)",
            "\(String(localized: "lyrics_word")): \(lyricsStatus)",
            "",
            accuracyNotice,
        ].joined(separator: "\n")
    }

    private func fmt(_ t: TimeInterval) -> String {
        t.formattedDuration
    }
}

struct MusicVideoFullScreenView: View {
    let player: AVPlayer
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
            .padding(.trailing, 24)
            .accessibilityLabel(Text("close"))
        }
        // 只有黑底与画面越过安全区；关闭按钮仍按安全区排布。
        .background {
            ZStack {
                Color.black
                MusicVideoSurface(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
        }
        #if os(iOS)
        .statusBarHidden(true)
        .onAppear {
            MusicVideoOrientationController.enterLandscape()
        }
        #endif
    }
}

struct MusicVideoSurface: View {
    let player: AVPlayer

    var body: some View {
        PlatformMusicVideoSurface(player: player)
            .id(ObjectIdentifier(player))
    }
}

#if os(iOS)
/// Uses the public scene-geometry API to make MV fullscreen behave like a video
/// player on iPhone. The previous orientation is restored when the cover closes,
/// so the rest of the app does not get stranded in landscape.
@MainActor
private enum MusicVideoOrientationController {
    private static var restoreMask: UIInterfaceOrientationMask?

    static func enterLandscape() {
        // 宽内屏是 regular 宽度，不接受界面朝向请求，只在 compact 宽度下切换。
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = foregroundWindowScene,
              scene.traitCollection.horizontalSizeClass == .compact else { return }

        if restoreMask == nil {
            restoreMask = mask(for: scene.interfaceOrientation)
        }
        request([.landscapeLeft, .landscapeRight], in: scene)
    }

    static func enterPortrait() {
        guard let scene = foregroundWindowScene else { return }
        request(.portrait, in: scene)
    }

    static func restorePreviousOrientation() {
        guard let restoreMask,
              UIDevice.current.userInterfaceIdiom == .phone,
              let scene = foregroundWindowScene,
              scene.traitCollection.horizontalSizeClass == .compact else { return }
        self.restoreMask = nil
        request(restoreMask, in: scene)
    }

    private static var foregroundWindowScene: UIWindowScene? {
        let applicationScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    && $0.session.role == .windowApplication
            }
        // CarPlay and external-display scenes can be foreground-active at the
        // same time as the phone. Only the main application scene may receive
        // phone orientation requests; prefer its key window when available.
        return applicationScenes.first { $0.keyWindow != nil }
            ?? applicationScenes.first
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    private static func request(_ orientations: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        // 系统拒绝请求时在后台队列回调:闭包不能沿用外面的主线程隔离,否则运行时的隔离检查当场崩溃。
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { @Sendable error in
            plog("⚠️ MV orientation request failed: \(error.localizedDescription)")
        }
    }
}

private struct PlatformMusicVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> MusicVideoLayerView {
        let view = MusicVideoLayerView()
        view.setPlayer(player)
        return view
    }

    func updateUIView(_ uiView: MusicVideoLayerView, context: Context) {
        uiView.setPlayer(player)
    }
}

private final class MusicVideoLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var currentPlayer: AVPlayer?

    var playerLayer: AVPlayerLayer? {
        layer as? AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer?.videoGravity = .resizeAspect
        backgroundColor = .black
        observeApplicationState()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setPlayer(_ player: AVPlayer) {
        currentPlayer = player
        playerLayer?.player = UIApplication.shared.applicationState == .background ? nil : player
    }

    private func observeApplicationState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground() {
        playerLayer?.player = nil
    }

    @objc private func applicationWillEnterForeground() {
        playerLayer?.player = currentPlayer
    }
}
#elseif os(macOS)
private struct PlatformMusicVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> MusicVideoLayerView {
        let view = MusicVideoLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: MusicVideoLayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class MusicVideoLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#endif

// MARK: - Custom Progress Slider (thin, no thumb)

struct ProgressSlider: View {
    let value: TimeInterval
    let total: TimeInterval
    let interactionID: String?
    let fillTint: Color?
    let onPreview: (TimeInterval?) -> Void
    let onSeek: (TimeInterval) -> Void

    init(
        value: TimeInterval,
        total: TimeInterval,
        interactionID: String? = nil,
        fillTint: Color? = nil,
        onPreview: @escaping (TimeInterval?) -> Void = { _ in },
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.value = value
        self.total = total
        self.interactionID = interactionID
        self.fillTint = fillTint
        self.onPreview = onPreview
        self.onSeek = onSeek
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ThemeService.self) private var theme

    @State private var scrubSession: ProgressScrubSession?
    /// 上一次落到填充条上的比例。只用来判断这次变化是不是一次普通的时钟推进。
    @State private var previousProgress: CGFloat = 0

    private var safeTotal: TimeInterval { total.sanitizedDuration }
    private var activePreview: TimeInterval? {
        guard let scrubSession,
              scrubSession.interactionID == interactionID else { return nil }
        return scrubSession.preview
    }
    private var isDragging: Bool { activePreview != nil }
    private var displayValue: TimeInterval { (activePreview ?? value).sanitizedDuration }
    private var progress: CGFloat {
        guard safeTotal > 0 else { return 0 }
        let fraction = displayValue / safeTotal
        guard fraction.isFinite else { return 0 }
        return CGFloat(max(0, min(1, fraction)))
    }

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var fillColor: Color {
        if let fillTint { return fillTint }
        guard theme.colorID != "default" else { return appearance.primary }
        return appearance.isLight ? theme.darkAccent : theme.accentColor
    }

    /// 播放时钟 0.5 秒推进一次, 填充条不接一条同长的线性动画就会一格一格地跳。
    /// 这是跟时钟间隔配套的特例曲线, 不属于 PMMotion 的任何一档。
    ///
    /// 只认"正常推进"这一种变化: 拖动中、seek、换歌、回跳都不给动画 ——
    /// 否则换歌时填充条会从上一首的位置一路倒扫回起点。
    private var fillAnimation: Animation? {
        guard !reduceMotion, !isDragging else { return nil }
        let advanced = Double(progress - previousProgress) * safeTotal
        guard advanced > 0, advanced <= Self.maximumAnimatedAdvance else { return nil }
        return .linear(duration: Self.clockTickInterval)
    }

    /// 与 AudioPlayerService 的 timeUpdateInterval 对齐。
    private static let clockTickInterval: TimeInterval = 0.5
    private static let maximumAnimatedAdvance: TimeInterval = 1

    private func commitAdjustment(incrementing: Bool) {
        guard let adjusted = NowPlayingInteractionPolicy.adjustedPlaybackTime(
            currentTime: displayValue,
            duration: safeTotal,
            incrementing: incrementing
        ) else { return }
        onSeek(adjusted)
    }

    #if os(iOS) || os(macOS)
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .leftArrow {
            commitAdjustment(incrementing: false)
            return .handled
        }
        if press.key == .rightArrow {
            commitAdjustment(incrementing: true)
            return .handled
        }
        return .ignored
    }
    #endif

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = isDragging ? 8 : 5

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(appearance.track)
                    .frame(height: trackHeight)

                // Filled track
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(0, min(width, width * progress)))
                    // 高度留在动画修饰符外面: 轨道加粗归下面那条 isDragging 的
                    // 曲线管, 这里只负责宽度, 免得一开始拖动就把加粗一起掐掉。
                    .animation(fillAnimation, value: progress)
                    .frame(height: trackHeight)
            }
            .frame(height: CGFloat(NowPlayingInteractionPolicy.minimumScrubHitTargetSize))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: CGFloat(
                    NowPlayingInteractionPolicy.minimumScrubDistance
                ))
                    .onChanged { gesture in
                        var session = scrubSession
                            ?? ProgressScrubSession(interactionID: interactionID)
                        session.update(
                            horizontalTranslation: Double(gesture.translation.width),
                            verticalTranslation: Double(gesture.translation.height),
                            location: Double(gesture.location.x),
                            trackWidth: Double(width),
                            duration: safeTotal
                        )
                        scrubSession = session
                    }
                    .onEnded { gesture in
                        let seekTime = scrubSession?.committedValue(
                            currentInteractionID: interactionID,
                            horizontalTranslation: Double(gesture.translation.width),
                            verticalTranslation: Double(gesture.translation.height),
                            location: Double(gesture.location.x),
                            trackWidth: Double(width),
                            duration: safeTotal
                        )
                        scrubSession = nil
                        if let seekTime {
                            onSeek(seekTime)
                        }
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: isDragging)
        }
        .frame(height: CGFloat(NowPlayingInteractionPolicy.minimumScrubHitTargetSize))
        .onChange(of: activePreview) { _, preview in onPreview(preview) }
        .onChange(of: interactionID) { _, _ in
            onPreview(nil)
        }
        // 拖动时进度是逐帧跟手的, 不记这一笔, 免得每帧多走一次状态写入。
        .onChange(of: progress) { _, updated in
            guard !isDragging else { return }
            previousProgress = updated
        }
        .onDisappear {
            scrubSession = nil
            onPreview(nil)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("playback"))
        .accessibilityValue(Text(verbatim:
            "\(displayValue.formattedDuration) / \(safeTotal.formattedDuration)"
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                commitAdjustment(incrementing: true)
            case .decrement:
                commitAdjustment(incrementing: false)
            @unknown default:
                break
            }
        }
        #if os(iOS) || os(macOS)
        .focusable()
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleKeyPress(press)
        }
        #endif
    }
}

// MARK: - Volume Slider (thin, matching ProgressSlider style)

#if os(iOS)
/// iOS exposes output volume as read-only on `AVAudioSession`; `MPVolumeView`
/// is the supported interactive control. Its slider observes hardware-button,
/// Control Center, Bluetooth and AirPlay volume changes, so the value rendered
/// here always describes the route that is actually producing sound. This also
/// works for MusicKit playback, which bypasses Primuse's `AVAudioEngine`.
struct SystemVolumeSlider: UIViewRepresentable {
    static let compactHeight: CGFloat = 24
    static let verticalOffset: CGFloat = 1.5

    final class Coordinator {
        var styleKey: StyleKey?
    }

    struct StyleKey: Equatable {
        let isLight: Bool
        let usesIncreasedContrast: Bool
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        UIView.performWithoutAnimation {
            view.showsVolumeSlider = true
            // The row owns the compact height, while MPVolumeView remains free
            // to lay out its private slider hierarchy. Forcing the internal
            // UISlider's frame can make the track disappear on newer iOS.
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            styleSlider(in: view)
            view.layoutIfNeeded()
        }
        context.coordinator.styleKey = currentStyleKey
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        let styleKey = currentStyleKey
        guard context.coordinator.styleKey != styleKey || findSlider(in: uiView) == nil else {
            return
        }
        UIView.performWithoutAnimation {
            styleSlider(in: uiView)
            uiView.setNeedsLayout()
            uiView.layoutIfNeeded()
        }
        context.coordinator.styleKey = styleKey
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MPVolumeView,
        context: Context
    ) -> CGSize? {
        // SwiftUI first asks an HStack child for an unspecified ideal width.
        // Returning no intrinsic width here collapsed the actual UIKit view to
        // zero even though the outer `.frame(maxWidth: .infinity)` still filled
        // the row, leaving only the speaker icons visible.
        let intrinsicWidth = uiView.intrinsicContentSize.width
        let width = proposal.width ?? max(intrinsicWidth, 1)
        return CGSize(width: width, height: Self.compactHeight)
    }

    private func styleSlider(in volumeView: MPVolumeView) {
        volumeView.backgroundColor = .clear
        volumeView.subviews
            .compactMap { $0 as? UIButton }
            .forEach { $0.isHidden = true }

        guard let slider = findSlider(in: volumeView) else {
            return
        }
        let foreground = playerUIColor
        slider.minimumTrackTintColor = foreground
        slider.maximumTrackTintColor = foreground.withAlphaComponent(
            colorSchemeContrast == .increased ? 0.30 : 0.20
        )
        slider.thumbTintColor = foreground
        slider.setThumbImage(thumbImage(diameter: 12, color: foreground), for: .normal)
        slider.setThumbImage(thumbImage(diameter: 14, color: foreground), for: .highlighted)
        slider.accessibilityLabel = String(localized: "volume")
    }

    private var playerUIColor: UIColor {
        colorScheme == .light
            ? UIColor.black.withAlphaComponent(colorSchemeContrast == .increased ? 0.96 : 0.88)
            : UIColor.white
    }

    private var currentStyleKey: StyleKey {
        StyleKey(
            isLight: colorScheme == .light,
            usesIncreasedContrast: colorSchemeContrast == .increased
        )
    }

    private func thumbImage(diameter: CGFloat, color: UIColor) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider {
            return slider
        }
        for subview in view.subviews {
            if let slider = findSlider(in: subview) {
                return slider
            }
        }
        return nil
    }
}
#endif

struct VolumeSlider: View {
    @Binding var value: Double

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var isDragging = false
    @State private var localValue: Double?

    private var displayValue: Double { localValue ?? value }
    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = CGFloat(max(0, min(1, displayValue)))
            let trackHeight: CGFloat = isDragging ? 8 : 5

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(appearance.track)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(appearance.primary)
                    .frame(width: max(0, min(width, width * progress)), height: trackHeight)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        localValue = Double(max(0, min(1, gesture.location.x / width)))
                        value = localValue!
                    }
                    .onEnded { _ in
                        localValue = nil
                        withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: isDragging)
        }
        .frame(height: 20)
    }
}

// MARK: - Song Info Sheet

enum SongInfoPresentationConfiguration {
    static let detents: Set<PresentationDetent> = [.medium, .large]
}

extension View {
    @ViewBuilder
    func songInfoPresentationStyle() -> some View {
        #if os(macOS)
        self
        #else
        self
            .presentationDetents(SongInfoPresentationConfiguration.detents)
            .presentationDragIndicator(.visible)
            // The sheet grows to its largest detent before its List/ScrollView
            // consumes the upward gesture, avoiding nested-scroll dead zones.
            .presentationContentInteraction(.automatic)
        #endif
    }
}

struct SongInfoSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var showSimilarSongs = false
    private let history = PlayHistoryStore.shared

    private var playbackStats: PlayHistoryStore.SongPlaybackStats {
        history.playbackStats(forSongID: song.id)
    }

    private var sourceName: String? {
        sourcesStore.source(id: song.sourceID)?.name
    }

    private var displayPath: String? {
        SongPathPresentationPolicy.displayPath(
            filePath: song.filePath,
            sourceID: song.sourceID,
            sourceType: sourcesStore.source(id: song.sourceID)?.type
        )
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        legacyBody
        #endif
    }

    #if !os(macOS)
    private var legacyBody: some View {
        NavigationStack {
            SkinList {
                infoRow(String(localized: "title_label"), song.title)
                if let artist = library.artistDisplayName(for: song) {
                    infoRow(String(localized: "artist_label"), artist)
                }
                if let album = song.albumTitle { infoRow(String(localized: "album_label"), album) }
                if let genre = song.genre { infoRow(String(localized: "genre_label"), genre) }
                if let year = song.year { infoRow(String(localized: "year_label"), "\(year)") }
                if let disc = song.discNumber { infoRow(String(localized: "disc_label"), "\(disc)") }
                if let track = song.trackNumber { infoRow(String(localized: "track_label"), "\(track)") }

                Section(String(localized: "playback_info")) {
                    infoRow(String(localized: "stats_play_count"), playbackStats.playCount.formatted())
                    infoRow(
                        String(localized: "last_played_label"),
                        playbackStats.lastPlayedAt?.formatted(date: .abbreviated, time: .shortened)
                            ?? String(localized: "no_recorded_playback")
                    )
                    Text(playbackHistoryNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section(String(localized: "library_info")) {
                    if let serverPlayCount = song.serverPlayCount {
                        infoRow(
                            String(localized: "server_play_count_label"),
                            serverPlayCount.formatted()
                        )
                    }
                    infoRow(String(localized: "date_added_label"), song.dateAdded.formatted(date: .long, time: .omitted))
                    if let lastModified = song.lastModified {
                        infoRow(String(localized: "last_modified_label"), lastModified.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let sourceName {
                        infoRow(String(localized: "source_label"), sourceName)
                    }
                    if let displayPath {
                        infoRow(
                            String(localized: "file_location_label"),
                            displayPath,
                            monospaced: true
                        )
                    }
                }

                Section(String(localized: "technical_info")) {
                    infoRow(String(localized: "format_label"), song.fileFormat.displayName)
                    if let sampleRate = song.formattedSampleRate {
                        infoRow(String(localized: "sample_rate_label"), sampleRate)
                    }
                    if let bitDepth = song.formattedBitDepth {
                        infoRow(String(localized: "bit_depth_label"), bitDepth)
                    }
                    if let bitRate = song.formattedBitRate {
                        infoRow(String(localized: "songs_column_bitrate"), bitRate)
                    }
                    if let fileSize = formattedFileSize {
                        infoRow(String(localized: "file_size_label"), fileSize)
                    }
                    infoRow(String(localized: "duration_label"), formatDuration(song.duration))
                }

            }
            .navigationTitle(String(localized: "song_info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSimilarSongs = true
                    } label: {
                        Label(String(localized: "similar_songs"), systemImage: "sparkles")
                    }
                    .accessibilityHint(Text("similar_songs_accessibility_hint"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showSimilarSongs) {
                SimilarSongsSheet(seed: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
    #endif

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 120,
                    cornerRadius: 8,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .shadow(color: .black.opacity(0.20), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text("song_info")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(PMColor.textFaint)
                    Text(song.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(2)
                    Text(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                        .font(.system(size: 13))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                    Text(song.albumTitle ?? "—")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                    Button {
                        showSimilarSongs = true
                    } label: {
                        Label(String(localized: "similar_songs"), systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PMColor.text)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(Text("similar_songs"))
                    .accessibilityHint(Text("similar_songs_accessibility_hint"))
                    .padding(.top, 5)
                }

                Spacer()

                PMRoundBtn(icon: "xmark", size: 26, iconSize: 11, style: .glass,
                           help: "done") {
                    dismiss()
                }
            }
            .padding(22)
            .background(PMColor.card.opacity(0.54))

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [
                        GridItem(.fixed(120), spacing: 18, alignment: .leading),
                        GridItem(.flexible(), spacing: 18, alignment: .leading),
                    ], alignment: .leading, spacing: 8) {
                        ForEach(macInfoRows, id: \.label) { row in
                            Text(row.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(PMColor.textMuted)
                                .accessibilityHidden(true)
                            Text(row.value)
                                .font(row.monospace
                                      ? .system(size: 12.5, design: .monospaced)
                                      : .system(size: 12.5))
                                .foregroundStyle(PMColor.text)
                                .lineLimit(row.monospace ? 3 : 1)
                                .textSelection(.enabled)
                                .accessibilityLabel(Text(row.label))
                                .accessibilityValue(Text(row.value))
                        }
                    }
                    Text(playbackHistoryNote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Spacer()

                Button(String(localized: "done")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.brand, in: .rect(cornerRadius: 6))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 620)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PMColor.bg.opacity(0.84))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .similarSongsPanel(isPresented: $showSimilarSongs, seed: song)
    }

    private var macInfoRows: [(label: String, value: String, monospace: Bool)] {
        var rows: [(String, String, Bool)] = [
            (String(localized: "title_label"), song.title, false),
        ]
        if let artist = library.artistDisplayName(for: song) {
            rows.append((String(localized: "artist_label"), artist, false))
        }
        if let album = song.albumTitle { rows.append((String(localized: "album_label"), album, false)) }
        if let genre = song.genre { rows.append((String(localized: "genre_label"), genre, false)) }
        if let year = song.year { rows.append((String(localized: "year_label"), "\(year)", false)) }
        if let disc = song.discNumber { rows.append((String(localized: "disc_label"), "\(disc)", false)) }
        if let track = song.trackNumber { rows.append((String(localized: "track_label"), "\(track)", false)) }
        rows.append((String(localized: "stats_play_count"), playbackStats.playCount.formatted(), false))
        rows.append((String(localized: "last_played_label"), playbackStats.lastPlayedAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "no_recorded_playback"), false))
        if let serverPlayCount = song.serverPlayCount {
            rows.append((String(localized: "server_play_count_label"), serverPlayCount.formatted(), false))
        }
        rows.append((String(localized: "date_added_label"), song.dateAdded.formatted(date: .long, time: .omitted), false))
        if let lastModified = song.lastModified {
            rows.append((String(localized: "last_modified_label"), lastModified.formatted(date: .abbreviated, time: .shortened), false))
        }
        rows.append((String(localized: "format_label"), song.fileFormat.displayName, false))
        if let sampleRate = song.formattedSampleRate {
            rows.append((String(localized: "sample_rate_label"), sampleRate, false))
        }
        if let bitDepth = song.formattedBitDepth {
            rows.append((String(localized: "bit_depth_label"), bitDepth, false))
        }
        if let bitRate = song.formattedBitRate {
            rows.append((String(localized: "songs_column_bitrate"), bitRate, false))
        }
        if let fileSize = formattedFileSize {
            rows.append((String(localized: "file_size_label"), fileSize, false))
        }
        rows.append((String(localized: "duration_label"), formatDuration(song.duration), false))
        if let sourceName {
            rows.append((String(localized: "source_label"), sourceName, false))
        }
        if let displayPath {
            rows.append((String(localized: "file_location_label"), displayPath, true))
        }
        return rows.map { ($0.0, $0.1, $0.2) }
    }
    #endif

    private var playbackHistoryNote: String {
        String(format: String(localized: "playback_history_note"),
            Int(PlayHistoryStore.recordedThresholdSec),
            PlayHistoryStore.maxRetainedEntries)
    }

    private var formattedFileSize: String? {
        guard song.fileSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file)
    }

    private func infoRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .callout.monospaced() : .body)
                .fontWeight(.medium)
                .lineLimit(monospaced ? 3 : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        t.formattedDuration
    }
}

// MARK: - Add to Playlist Sheet

struct AddToPlaylistSheet: View {
    let song: Song
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    private var editablePlaylists: [Playlist] {
        library.playlists.filter { isEditablePlaylist($0.id) }
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        legacyBody
        #endif
    }

    private var legacyBody: some View {
        NavigationStack {
            SkinList {
                Section {
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Label(String(localized: "new_playlist"), systemImage: "plus.circle.fill")
                    }
                }

                Section(String(localized: "playlists_title")) {
                    if editablePlaylists.isEmpty {
                        ContentUnavailableView {
                            Label(String(localized: "no_playlists"), systemImage: "music.note.list")
                        }
                    } else {
                        ForEach(editablePlaylists) { playlist in
                            playlistRow(playlist: playlist)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "add_to_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .alert(String(localized: "new_playlist"), isPresented: $showNewPlaylist) {
                TextField(String(localized: "playlist_name"), text: $newPlaylistName)
                Button(String(localized: "cancel"), role: .cancel) { newPlaylistName = "" }
                Button(String(localized: "create")) {
                    guard !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let pl = library.createPlaylist(name: newPlaylistName)
                    library.add(songID: song.id, toPlaylist: pl.id)
                    newPlaylistName = ""
                }
            }
        }
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("add_to_playlist")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: "\(song.title) · \(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                PMRoundBtn(icon: "xmark", size: 24, iconSize: 10.5, style: .plain,
                           help: "cancel") { dismiss() }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            Button {
                showNewPlaylist = true
            } label: {
                Label(String(localized: "new_playlist"), systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    if editablePlaylists.isEmpty {
                        ContentUnavailableView {
                            Label(String(localized: "no_playlists"), systemImage: "music.note.list")
                        }
                        .padding(.vertical, 48)
                    } else {
                        ForEach(editablePlaylists) { playlist in
                            macPlaylistRow(playlist)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "cancel")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                Button(String(localized: "done")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .background(PMColor.brand, in: .rect(cornerRadius: 5))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 380, height: 480)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PMColor.bg.opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .alert(String(localized: "new_playlist"), isPresented: $showNewPlaylist) {
            TextField(String(localized: "playlist_name"), text: $newPlaylistName)
            Button(String(localized: "cancel"), role: .cancel) { newPlaylistName = "" }
            Button(String(localized: "create")) {
                guard !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let pl = library.createPlaylist(name: newPlaylistName)
                library.add(songID: song.id, toPlaylist: pl.id)
                newPlaylistName = ""
            }
        }
    }

    private func macPlaylistRow(_ playlist: Playlist) -> some View {
        let isAdded = library.contains(songID: song.id, inPlaylist: playlist.id)
        let count = library.songs(forPlaylist: playlist.id).count

        return Button {
            guard isEditablePlaylist(playlist.id) else { return }
            if isAdded {
                library.remove(songID: song.id, fromPlaylist: playlist.id)
            } else {
                library.add(songID: song.id, toPlaylist: playlist.id)
            }
        } label: {
            HStack(spacing: 10) {
                PlaylistArtworkView(playlist: playlist, size: 32, cornerRadius: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text("\(count) \(String(localized: "songs_count"))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                }

                Spacer()

                if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .pmRowBackground(selected: isAdded, cornerRadius: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    @ViewBuilder
    private func playlistRow(playlist: Playlist) -> some View {
        let isAdded = library.contains(songID: song.id, inPlaylist: playlist.id)
        Button {
            guard isEditablePlaylist(playlist.id) else { return }
            if isAdded {
                library.remove(songID: song.id, fromPlaylist: playlist.id)
            } else {
                library.add(songID: song.id, toPlaylist: playlist.id)
            }
        } label: {
            HStack {
                PlaylistArtworkView(playlist: playlist, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.body)
                    let count = library.songs(forPlaylist: playlist.id).count
                    Text("\(count) \(String(localized: "songs_count"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isAdded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isAdded ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isEditablePlaylist(_ playlistID: String) -> Bool {
        library.playlist(id: playlistID)?.allowsManualSongMembership == true
            && playlistID != MusicLibrary.likedSongsPlaylistID
    }
}

#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        applyAppearance(to: v)
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        applyAppearance(to: uiView)
    }

    private func applyAppearance(to view: AVRoutePickerView) {
        let foreground = colorScheme == .light
            ? UIColor.black.withAlphaComponent(colorSchemeContrast == .increased ? 0.96 : 0.88)
            : UIColor.white
        view.tintColor = foreground.withAlphaComponent(colorSchemeContrast == .increased ? 0.72 : 0.52)
        view.activeTintColor = foreground
    }
}
#else
/// macOS 上 AVRoutePickerView 是 NSView, tint / activeTint API 也不一样。
/// 但 NowPlayingView 的 iOS 全屏播放器 (含 AirPlay 按钮) 在 macOS 上不会出现
/// (Mac 用 MacNowPlayingView), 这里给一个能编译的占位空视图, 避免 import
/// 链断开。真用到再走 AVRoutePickerView (NSView) 适配。
struct AirPlayButton: View {
    var body: some View { Color.clear.frame(width: 44, height: 44) }
}
#endif

/// `.sheet(item:)` 要一个 Identifiable; 书详情只认书的 id。
private struct NowPlayingBookRoute: Identifiable {
    let id: String
}

// MARK: - Stable native More menu

/// Only state that can legitimately change the native menu's contents. Playback
/// progress and lyric scroll state are intentionally absent, so their frequent
/// updates cannot invalidate an already-presented menu.
///
/// Not private: the grouped actions panel (another presentation of the same menu,
/// chosen by the interface skin) lives in its own file and reads the same snapshot.
struct NowPlayingMoreMenuSnapshot: Equatable {
    let songID: String?
    /// 正在播有声内容: 菜单收起音乐专属的项。
    let isSpokenWord: Bool
    let canOpenBook: Bool
    let hasChapterList: Bool
    let hasSong: Bool
    let isScrapingCurrentSong: Bool
    let canReloadLyricsFromSource: Bool
    let isReloadingLyricsFromSource: Bool
    let isAppleMusicMode: Bool
    let canDeleteSourceFile: Bool
    let appleMusicCatalogURL: URL?
    let showsLyricsPreferences: Bool
    let showsFullScreenAction: Bool
    let albumID: String?
    let artistID: String?
    let canOpenAlbum: Bool
    let canOpenArtist: Bool
    let canShare: Bool
    let castingRendererName: String?
    let isSleepTimerActive: Bool
    let lyricsFontScale: Double
    let canChangePlaybackRate: Bool
    let playbackRate: Float
    let isLyricsTranslationEnabled: Bool
    /// 手机横屏右栏窄到摆不下两端的随机 / 循环时为真, 菜单里补上这两个入口,
    /// 别的布局仍然只在传输键那一行提供它们。
    let showsPlaybackModeActions: Bool
    let isShuffleEnabled: Bool
    let repeatMode: RepeatMode
    let isMedleyActive: Bool
    let canStartMedley: Bool
    let canStartKaraoke: Bool
    let medleySegmentSeconds: Int
    let colorScheme: ColorScheme
    let colorSchemeContrast: ColorSchemeContrast
}

/// Keeps the existing SwiftUI `Menu` interaction and visual design, while using
/// an equatable update boundary to stop unrelated parent updates from rebuilding
/// the menu hierarchy and resetting its internal scroll position.
private struct NowPlayingMoreMenu: View, @MainActor Equatable {
    let snapshot: NowPlayingMoreMenuSnapshot
    @Binding var lyricsFontScale: Double
    @Binding var playbackRate: Float
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    let immersiveChrome: Bool
    /// 只在 `immersiveChrome` 为真时起作用：圆钮底用固定深色还是跟随明暗外观。
    let chromeGlass: NowPlayingChromeGlass
    /// 「更多」怎么呈现由界面皮肤决定:系统菜单,或分组面板。两者的内容与动作是同一份。
    @Environment(\.skin) private var skin
    @State private var showsActionsPanel = false
    /// 面板里选中的、要等面板收起之后再执行的动作(它们大多会再弹出一个面板)。
    @State private var pendingPanelAction: (() -> Void)?

    let onEnterFullScreen: () -> Void
    let onAddToPlaylist: () -> Void
    let onScrape: () -> Void
    let onReloadLyricsFromSource: () -> Void
    let onShowSimilarSongs: () -> Void
    let onEditTags: () -> Void
    let onEditLyrics: () -> Void
    let onShowSongInfo: () -> Void
    let onOpenAlbum: () -> Void
    let onOpenArtist: () -> Void
    let onOpenBook: () -> Void
    let onShowChapterList: () -> Void
    let onOpenInAppleMusic: () -> Void
    let onShare: () -> Void
    let onShowCastPicker: () -> Void
    let onToggleLyricsTranslation: () -> Void
    let onShowSleepTimer: () -> Void
    let onToggleShuffle: () -> Void
    let onCycleRepeatMode: () -> Void
    let onStartMedley: () -> Void
    let onContinueMedleySongInFull: () -> Void
    let onStartKaraoke: () -> Void
    let onDelete: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.immersiveChrome == rhs.immersiveChrome
            && lhs.chromeGlass == rhs.chromeGlass
    }

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(
            colorScheme: snapshot.colorScheme,
            contrast: snapshot.colorSchemeContrast
        )
    }

    /// 循环模式当前状态对应的图标。菜单项文案沿用 `repeat` 这一个 key,
    /// 三种状态靠图标区分。
    private static func repeatSymbol(for mode: RepeatMode) -> String {
        switch mode {
        case .off: return "repeat"
        case .all: return "repeat.circle.fill"
        case .one: return "repeat.1.circle.fill"
        }
    }

    /// 横排里除「添加到歌单」之外能凑出几个键。不足三个时把「添加到歌单」也提上来，
    /// 免得一行只剩孤零零一个键；够三个时它留在下面的列表里，横排不挤成四个小字。
    private var quickActionCount: Int {
        [snapshot.showsFullScreenAction, snapshot.canShare, snapshot.canDeleteSourceFile]
            .filter { $0 }
            .count
    }

    private var promotesAddToPlaylist: Bool { quickActionCount < 3 }

    /// 留在列表里时用完整说法，提到横排里时用短的那条。
    @ViewBuilder
    private func addToPlaylistButton(inQuickRow: Bool) -> some View {
        if inQuickRow {
            PMMenuQuickActionButton(
                shortKey: "add_to_playlist_short",
                fullKey: "add_to_playlist",
                systemImage: "text.badge.plus",
                action: onAddToPlaylist
            )
            .disabled(!snapshot.hasSong)
        } else {
            Button(action: onAddToPlaylist) {
                Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
            }
            .disabled(!snapshot.hasSong)
        }
    }

    var body: some View {
        #if os(iOS)
        switch skin.skin.player {
        case .sheetActions:
            actionsPanelButton
        case .classic:
            nativeMenu
        }
        #else
        nativeMenu
        #endif
    }

    #if os(iOS)
    private var actionsPanelButton: some View {
        Button {
            showsActionsPanel = true
        } label: {
            moreLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("a11y_more_actions"))
        .sheet(isPresented: $showsActionsPanel, onDismiss: { runPendingPanelAction() }) {
            NowPlayingActionsPanel(
                snapshot: snapshot,
                lyricsFontScale: $lyricsFontScale,
                playbackRate: $playbackRate,
                lyricsMotionEnabled: $lyricsMotionEnabled,
                actions: NowPlayingMoreActions(
                    enterFullScreen: onEnterFullScreen,
                    addToPlaylist: onAddToPlaylist,
                    scrape: onScrape,
                    reloadLyricsFromSource: onReloadLyricsFromSource,
                    showSimilarSongs: onShowSimilarSongs,
                    editTags: onEditTags,
                    editLyrics: onEditLyrics,
                    showSongInfo: onShowSongInfo,
                    openAlbum: onOpenAlbum,
                    openArtist: onOpenArtist,
                    openInAppleMusic: onOpenInAppleMusic,
                    share: onShare,
                    showCastPicker: onShowCastPicker,
                    toggleLyricsTranslation: onToggleLyricsTranslation,
                    showSleepTimer: onShowSleepTimer,
                    delete: onDelete,
                    toggleShuffle: onToggleShuffle,
                    cycleRepeatMode: onCycleRepeatMode
                ),
                performAfterDismiss: { action in
                    pendingPanelAction = action
                    showsActionsPanel = false
                }
            )
        }
    }

    private func runPendingPanelAction() {
        let action = pendingPanelAction
        pendingPanelAction = nil
        action?()
    }
    #endif

    private var nativeMenu: some View {
        Menu {
            // 最常用的几个操作排成一行，不用往下翻就够得着。文字取短的那一版，
            // 长了会被截断；键数与平台差异见 `PMMenuQuickActions`。
            PMMenuQuickActions {
                if snapshot.showsFullScreenAction {
                    PMMenuQuickActionButton(
                        shortKey: "full_screen_short",
                        fullKey: "full_screen_player",
                        systemImage: "viewfinder.rectangular",
                        action: onEnterFullScreen
                    )
                    .disabled(!snapshot.hasSong)
                }

                if snapshot.canShare {
                    // 歌词海报也从这里进：分享页里有一项「分享歌词」。
                    Button(action: onShare) {
                        Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                    }
                }

                if promotesAddToPlaylist {
                    addToPlaylistButton(inQuickRow: true)
                }

                if snapshot.canDeleteSourceFile {
                    Button(role: .destructive, action: onDelete) {
                        Label(String(localized: "delete"), systemImage: "trash")
                    }
                    .disabled(!snapshot.hasSong)
                }
            }

            if snapshot.canStartKaraoke {
                Section {
                    Button(action: onStartKaraoke) {
                        Label(String(localized: "karaoke_title"), systemImage: "music.mic.circle")
                    }
                }
            }

            if snapshot.isMedleyActive || snapshot.canStartMedley {
                Section {
                    if snapshot.isMedleyActive {
                        Button(action: onContinueMedleySongInFull) {
                            Label(String(localized: "medley_continue_full"), systemImage: "music.note")
                        }
                    } else {
                        // 一步开始，不再套两层子菜单；每首时长在设置 › 播放里改。
                        // 标题只留动作，范围和时长放进系统菜单的副标题行。
                        Button(action: onStartMedley) {
                            Label(String(localized: "medley_play_selection"),
                                  systemImage: "rectangle.stack.badge.play")
                            Text(String(
                                format: String(localized: "medley_queue_detail_format"),
                                snapshot.medleySegmentSeconds
                            ))
                        }
                    }
                }
            }

            if snapshot.showsPlaybackModeActions {
                Section {
                    Button(action: onToggleShuffle) {
                        Label(
                            String(localized: "shuffle"),
                            systemImage: snapshot.isShuffleEnabled ? "shuffle.circle.fill" : "shuffle"
                        )
                    }

                    Button(action: onCycleRepeatMode) {
                        Label(
                            String(localized: "repeat"),
                            systemImage: Self.repeatSymbol(for: snapshot.repeatMode)
                        )
                    }
                }
            }

            Section {
                if !promotesAddToPlaylist {
                    addToPlaylistButton(inQuickRow: false)
                }

                if !snapshot.isSpokenWord {
                    Button(action: onScrape) {
                        Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                    }
                    .disabled(!snapshot.hasSong || snapshot.isScrapingCurrentSong)
                }

                if snapshot.canReloadLyricsFromSource {
                    Button(action: onReloadLyricsFromSource) {
                        Label(
                            String(localized: "lyrics_reload_from_source"),
                            systemImage: "arrow.clockwise.circle"
                        )
                    }
                    .disabled(snapshot.isReloadingLyricsFromSource)
                }

                if !snapshot.isSpokenWord {
                    Button(action: onShowSimilarSongs) {
                        Label(String(localized: "similar_songs"), systemImage: "sparkles")
                    }
                    .disabled(!snapshot.hasSong)
                }

                if !snapshot.isAppleMusicMode {
                    Button(action: onEditTags) {
                        Label(String(localized: "tag_editor_menu"), systemImage: "tag")
                    }
                    .disabled(!snapshot.hasSong)

                    Button(action: onEditLyrics) {
                        Label(String(localized: "lyrics_editor_menu"), systemImage: "quote.bubble")
                    }
                    .disabled(!snapshot.hasSong)
                }
            }

            Section {
                Button(action: onShowSongInfo) {
                    Label(String(localized: "song_info"), systemImage: "info.circle")
                }
                .disabled(!snapshot.hasSong)

                if snapshot.isSpokenWord {
                    if snapshot.hasChapterList {
                        Button(action: onShowChapterList) {
                            Label(
                                String(localized: "spoken_word_chapters_and_bookmarks"),
                                systemImage: "list.bullet.indent"
                            )
                        }
                    }
                    if snapshot.canOpenBook {
                        Button(action: onOpenBook) {
                            Label(String(localized: "spoken_word_go_to_book"), systemImage: "books.vertical")
                        }
                    }
                } else if snapshot.canOpenAlbum {
                    Button(action: onOpenAlbum) {
                        Label(String(localized: "go_to_album"), systemImage: "square.stack")
                    }
                }

                if snapshot.canOpenArtist, !snapshot.isSpokenWord {
                    Button(action: onOpenArtist) {
                        Label(String(localized: "go_to_artist"), systemImage: "music.mic")
                    }
                }

                if snapshot.appleMusicCatalogURL != nil {
                    Button(action: onOpenInAppleMusic) {
                        Label(
                            String(localized: "apple_music_open_in_app"),
                            systemImage: "arrow.up.right.square"
                        )
                    }
                }

            }

            Section {
                Button(action: onShowCastPicker) {
                    if let rendererName = snapshot.castingRendererName {
                        Label(
                            String(
                                format: String(localized: "cast_casting_to_format"),
                                rendererName
                            ),
                            systemImage: "airplayaudio"
                        )
                    } else {
                        Label(String(localized: "cast_to_device"), systemImage: "airplayaudio")
                    }
                }
                .disabled(!snapshot.hasSong || snapshot.isAppleMusicMode)
            }

            if snapshot.showsLyricsPreferences {
                Section {
                    Picker(selection: $lyricsFontScale) {
                        Text("lyrics_font_small").tag(0.85)
                        Text("lyrics_font_medium").tag(1.0)
                        Text("lyrics_font_large").tag(1.2)
                        Text("lyrics_font_xlarge").tag(1.5)
                    } label: {
                        Label(String(localized: "lyrics_font_size"), systemImage: "textformat.size")
                    }
                    .pickerStyle(.menu)

                    Button(action: onToggleLyricsTranslation) {
                        Label(
                            snapshot.isLyricsTranslationEnabled
                                ? String(localized: "lyrics_translation_off")
                                : String(localized: "lyrics_translation_on"),
                            systemImage: snapshot.isLyricsTranslationEnabled
                                ? "character.bubble.fill"
                                : "character.bubble"
                        )
                    }
                }
            }

            Section {
                if !snapshot.isSpokenWord {
                    Toggle(isOn: $lyricsMotionEnabled) {
                        Label(
                            String(localized: "immersive_lyrics_motion_title"),
                            systemImage: "text.line.first.and.arrowtriangle.forward"
                        )
                    }
                }

                Button(action: onShowSleepTimer) {
                    Label(
                        snapshot.isSleepTimerActive
                            ? String(localized: "sleep_timer_active")
                            : String(localized: "sleep_timer"),
                        systemImage: snapshot.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz"
                    )
                }

                if !snapshot.isAppleMusicMode {
                    Picker(selection: $playbackRate) {
                        Text("0.5×").tag(Float(0.5))
                        Text("0.75×").tag(Float(0.75))
                        Text(String(localized: "playback_rate_normal")).tag(Float(1.0))
                        Text("1.25×").tag(Float(1.25))
                        Text("1.5×").tag(Float(1.5))
                        Text("1.75×").tag(Float(1.75))
                        Text("2.0×").tag(Float(2.0))
                    } label: {
                        Label(
                            snapshot.playbackRate == 1.0
                                ? String(localized: "playback_rate")
                                : String(
                                    format: "%@ %.2fx",
                                    String(localized: "playback_rate"),
                                    snapshot.playbackRate
                                ),
                            systemImage: "speedometer"
                        )
                    }
                    .pickerStyle(.menu)
                    .disabled(!snapshot.canChangePlaybackRate)
                }
            }
        } label: {
            moreLabel
        }
    }

    /// 系统菜单与分组面板共用的「更多」圆钮。
    @ViewBuilder
    private var moreLabel: some View {
        if immersiveChrome {
            chromeMenuLabel
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(appearance.secondary)
                .frame(width: 38, height: 38)
                .background(appearance.primary.opacity(0.065), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(appearance.primary.opacity(0.14), lineWidth: 0.75)
                }
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var chromeMenuLabel: some View {
        switch chromeGlass {
        case .immersive:
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(appearance.primary.opacity(0.88))
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                    Circle().fill(.black.opacity(0.16))
                }
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.8)
                }
        case .adaptive:
            NowPlayingGlassActionLabel(
                symbol: "ellipsis",
                appearance: appearance,
                tint: appearance.primary,
                diameter: 44
            )
        case .barColumn(let itemSize):
            NowPlayingBarColumnIcon(symbol: "ellipsis", appearance: appearance, size: itemSize)
        }
    }
}

// MARK: - LyricsScrollView (隔离的歌词渲染子 view)

/// Reserves the largest footprint a lyric row can occupy while its render-layer
/// emphasis animates. `scaleEffect` deliberately does not affect SwiftUI layout;
/// without this stable envelope a wrapped active row can draw outside its
/// measured frame even though its layout never moved.
private struct LyricsScaleEnvelopeLayout: Layout {
    let maximumScale: CGFloat
    let horizontalAnchor: UnitPoint

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let childProposal = ProposedViewSize(width: proposal.width, height: nil)
        let childSize = subview.sizeThatFits(childProposal)
        return CGSize(
            width: proposal.width ?? childSize.width,
            height: childSize.height * max(1, maximumScale)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        let childSize = subview.sizeThatFits(childProposal)
        subview.place(
            at: CGPoint(
                x: bounds.minX + bounds.width * horizontalAnchor.x,
                y: bounds.midY
            ),
            anchor: UnitPoint(x: horizontalAnchor.x, y: 0.5),
            proposal: ProposedViewSize(width: childSize.width, height: childSize.height)
        )
    }
}

/// 把歌词渲染抽出来作为独立 View,避免行切换 (`currentLineIndex` 变化) 让
/// 整个 NowPlayingView 的 body 重算,从而触发 SwiftUI Menu 内嵌的 Picker(.menu)
/// submenu 在父重算时被强制关闭(选字号弹框还没来得及选就消失)。
///
/// 通过把 currentLineIndex 等内部状态封装在子 view 里,行切换只让本 view 重算,
/// 父 view 的 Menu / sheet 不受影响。
enum LyricsTranslationActivity: Equatable {
    case idle
    /// Preparation reached a terminal state without any machine-translation work.
    case notNeeded
    case intelligentLoading
    case intelligentCached
    case intelligentSuccess(provider: String, fallbackDepth: Int)
    case systemFallback
    case systemPreparationRequired
    case systemUnavailable
}

/// 歌词还没有结论时的占位。照着歌词自身的排版节奏画几行骨架 —— 结果没回来
/// 之前空歌词只是"还不知道", 直接落到"暂无歌词 + 去刮削"等于每首需要联网
/// 取词的歌都先谎报一次没有歌词。骨架本身延迟淡入, 本地缓存命中的那几十
/// 毫秒里不会闪一下。
private struct LyricsLoadingSkeleton: View {
    let alignment: PlayerLyricsAlignment
    let tint: Color
    let layoutDirection: LayoutDirection

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isVisible = false
    @State private var isPulsing = false

    /// 行宽照着真实歌词的长短参差, 骨架才像歌词而不像列表。
    private static let rowWidthRatios: [Double] = [0.78, 0.58, 0.86, 0.46]
    private static let rowHeight: CGFloat = 17
    private static let rowSpacing: CGFloat = 26
    private static let topInset: CGFloat = 72
    private static let horizontalPadding: CGFloat = 24
    private static let appearDelay: Duration = .milliseconds(240)

    var body: some View {
        GeometryReader { geo in
            let available = max(geo.size.width - Self.horizontalPadding * 2, 1)
            VStack(alignment: alignment.horizontalAlignment, spacing: Self.rowSpacing) {
                ForEach(Array(Self.rowWidthRatios.enumerated()), id: \.offset) { index, ratio in
                    Capsule(style: .continuous)
                        .fill(tint.opacity(isPulsing ? 0.26 : 0.12))
                        .frame(width: available * ratio, height: Self.rowHeight)
                        .animation(pulseAnimation(index: index), value: isPulsing)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, Self.topInset)
        }
        .environment(\.layoutDirection, layoutDirection)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("lyrics_loading"))
        .task {
            try? await Task.sleep(for: Self.appearDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.28)) { isVisible = true }
            isPulsing = true
        }
    }

    private func pulseAnimation(index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 1.15)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * 0.14)
    }
}

/// 暂停后的歌词定位刷新只依赖这一层的 currentTime/isPlaying 读取。
private struct LyricsPausedTimeObserver: View {
    let player: AudioPlayerService
    let isEnabled: Bool
    let onPausedTick: () -> Void

    var body: some View {
        let isPaused = !player.isPlaying
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: player.currentTime) { _, _ in
                if isEnabled, isPaused {
                    onPausedTick()
                }
            }
    }
}

/// 手机横屏普通模式右栏的「当前歌词行」。
///
/// 当前行得跟着播放位置走, 但 `NowPlayingView.body` 是七千行规模的大 body,
/// 不能让它跟着时间每几百毫秒重算一遍。所以照 `LyricsScrollView` 的办法把
/// 时间读取整个关在这棵小子树里: 外面只传进不随播放进度变化的入参, 行索引
/// 是本 view 自己的 `@State`。
///
/// 行判定复用 `LyricPlaybackPositionPolicy.activeLineIndex`, 与歌词页、Mac
/// 单行歌词、外接屏用的是同一套二分, 不另写一份。
private struct CompactLandscapeLyricLine: View {
    let lyrics: [LyricLine]
    let player: AudioPlayerService
    let songID: String?
    let lyricsRevision: UInt
    let isSceneActive: Bool
    let tint: Color
    let lineHeight: CGFloat
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentLineIndex = -1

    /// 单行展示不需要逐字精度, 200ms 足够让换行看着是跟上的, 又比歌词页的
    /// 100ms 少一半唤醒。
    private static let pollInterval: Duration = .milliseconds(200)
    private static let lookahead: TimeInterval = 0.25

    private struct FollowIdentity: Hashable {
        let songID: String?
        let lyricsRevision: UInt
        let isPlaying: Bool
        let isSceneActive: Bool
    }

    private var hasSynchronizedLyrics: Bool {
        lyrics.contains { $0.isSynchronized }
    }

    private var followIdentity: FollowIdentity {
        FollowIdentity(
            songID: songID,
            lyricsRevision: lyricsRevision,
            isPlaying: player.isPlaying,
            isSceneActive: isSceneActive
        )
    }

    private var activityPolicy: NowPlayingVisualActivityPolicy {
        NowPlayingVisualActivityPolicy(
            isSceneActive: isSceneActive,
            isPlaying: player.isPlaying,
            usesRealtimeSpectrum: false,
            reduceMotion: reduceMotion
        )
    }

    private var currentText: String {
        guard lyrics.indices.contains(currentLineIndex) else { return "" }
        return lyrics[currentLineIndex].text
    }

    var body: some View {
        Text(verbatim: currentText)
            .font(.callout)
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .pmAnimation(.control, value: currentLineIndex)
            // 没有歌词时也占同样高度, 布局不会在有无歌词之间上下跳。
            .frame(height: lineHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .task(id: followIdentity) {
                guard hasSynchronizedLyrics else {
                    if currentLineIndex != -1 { currentLineIndex = -1 }
                    return
                }
                updateCurrentLine()
                guard activityPolicy.shouldPollLyrics else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: Self.pollInterval)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    updateCurrentLine()
                }
            }
            .background {
                // 暂停时没有轮询, 拖动进度条后的新位置靠这个零尺寸观察者补上。
                LyricsPausedTimeObserver(
                    player: player,
                    isEnabled: hasSynchronizedLyrics && isSceneActive
                ) {
                    updateCurrentLine()
                }
            }
            .onChange(of: songID) { _, _ in
                currentLineIndex = -1
            }
    }

    private func updateCurrentLine() {
        guard hasSynchronizedLyrics else {
            if currentLineIndex != -1 { currentLineIndex = -1 }
            return
        }
        let index = LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: player.interpolatedTime(),
            lookahead: Self.lookahead
        ) ?? -1
        if index != currentLineIndex {
            currentLineIndex = index
        }
    }
}

struct LyricsScrollView: View {
    let lyrics: [LyricLine]
    let lyricsWritingDirection: LyricWritingDirection
    let lyricsRevision: UInt
    /// 歌词结果还没回来。空歌词此时是"还不知道", 不是"没有"。
    let isResolvingLyrics: Bool
    let player: AudioPlayerService
    let songID: String?
    let isSceneActive: Bool
    let isScrapingCurrentSong: Bool
    let canTranscribeAudio: Bool
    let isScrapeActionUnavailable: Bool
    let onAutomaticScrape: () -> Void
    let onTranscribeAudio: () -> Void
    let onBackgroundTap: () -> Void
    /// 长按某一句 → 打开歌词海报, 并把这句作为选句起点。
    let onShareLyricLine: (String) -> Void
    /// 各行译文与翻译进度由播放页算好后传进来。这棵树进沉浸歌词、进全屏都会
    /// 被重建，翻译任务不能跟着它一起消失。
    let translatedTextByLineID: [String: String]
    let translationActivity: LyricsTranslationActivity

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    @AppStorage(PlayerAppearancePreferences.lyricsAlignmentKey)
    private var lyricsAlignmentRawValue = PlayerLyricsAlignment.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.lyricsColorModeKey)
    private var lyricsColorModeRawValue = PlayerLyricsColorMode.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.customLyricsColorHexKey)
    private var customLyricsColorHex = PlayerAppearancePreferences.defaultCustomLyricsColorHex
    @AppStorage(PlayerAppearancePreferences.gradientLyricsStartColorHexKey)
    private var gradientLyricsStartColorHex = PlayerAppearancePreferences.defaultGradientLyricsStartColorHex
    @AppStorage(PlayerAppearancePreferences.gradientLyricsEndColorHexKey)
    private var gradientLyricsEndColorHex = PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
    @AppStorage(PlayerAppearancePreferences.blursInactiveLyricsKey)
    private var blursInactiveLyrics = PlayerAppearancePreferences.blursInactiveLyricsByDefault
    @AppStorage(PlayerAppearancePreferences.tapLyricsToSeekKey)
    private var tapLyricsToSeek = PlayerAppearancePreferences.tapLyricsToSeekByDefault
    @State private var lyricsPinchScale: CGFloat = 1.0
    @State private var isPinchingLyrics = false
    @State private var currentLineIndex = -1
    @State private var activeInterludeAfterLineIndex: Int? = nil
    @State private var visualPlaybackTime: TimeInterval = 0
    @State private var isRestoringVisualPosition = false
    @State private var isManuallyBrowsingLyrics = false
    /// Row taps and the surface tap are simultaneous gestures. Remember the
    /// row event briefly so tapping lyrics seeks only, while tapping unused
    /// space can switch the normal Now Playing surface back to artwork.
    @State private var lastLyricRowTapAt: Date = .distantPast

    // 用户手动拖动歌词时, 暂时冻结自动滚动 ── 否则刚拖到想看的位置, 下一帧
    // auto follow 又把视图拽回当前行, 等于不能浏览。lastUserScrollTime 静止
    // 超过 manualScrollGracePeriod 后恢复 auto follow。
    @State private var lastUserScrollTime: Date = .distantPast
    /// 歌词在手动浏览保护期结束时必须主动归位。旧实现只在歌词索引
    /// 下一次变化时尝试 scrollTo，遇到长句/间奏就会长期停在错误位置。
    @State private var lineAutoFollowResumeTask: Task<Void, Never>? = nil
    private static let manualScrollGracePeriod: TimeInterval = 3.0

    private static let lyricsMinScale: Double = 0.7
    private static let lyricsMaxScale: Double = 1.8
    /// Keep every row on one stable layout size. Current-line emphasis is a
    /// render-layer scale, so a takeover does not reflow the surrounding rows.
    private static let lyricsLayoutBaseSize: CGFloat = 26
    private static let lyricsHorizontalPadding: CGFloat = 24

    private var visualActivityPolicy: NowPlayingVisualActivityPolicy {
        NowPlayingVisualActivityPolicy(
            isSceneActive: isSceneActive,
            isPlaying: player.isPlaying,
            usesRealtimeSpectrum: false,
            reduceMotion: reduceMotion
        )
    }

    private var effectiveLyricsScale: Double {
        let combined = lyricsFontScale * Double(lyricsPinchScale)
        return min(max(combined, Self.lyricsMinScale), Self.lyricsMaxScale)
    }

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var hasWordLevelLyrics: Bool {
        lyrics.contains(where: \.containsWordLevelContent)
    }

    private var hasSynchronizedLyrics: Bool {
        lyrics.contains { $0.isSynchronized }
    }

    private var lyricsAlignment: PlayerLyricsAlignment {
        PlayerLyricsAlignment(rawValue: lyricsAlignmentRawValue) ?? .defaultValue
    }

    private var lyricsColorMode: PlayerLyricsColorMode {
        PlayerLyricsColorMode(rawValue: lyricsColorModeRawValue) ?? .defaultValue
    }

    private var lyricLayoutDirection: LayoutDirection {
        switch lyricsWritingDirection {
        case .natural:
            return inheritedLayoutDirection
        case .leftToRight:
            return .leftToRight
        case .rightToLeft:
            return .rightToLeft
        }
    }

    private var lyricsScaleAnchor: UnitPoint {
        lyricsAlignment.scaleAnchor(in: lyricLayoutDirection)
    }

    private func currentLyricStyle(opacity: Double = 1) -> AnyShapeStyle {
        let resolvedOpacity = min(max(opacity, 0), 1)
        switch lyricsColorMode {
        case .defaultColor:
            return AnyShapeStyle(appearance.primary.opacity(resolvedOpacity))
        case .custom:
            return AnyShapeStyle(
                lyricsColor(
                    from: customLyricsColorHex,
                    fallback: PlayerAppearancePreferences.defaultCustomLyricsColorHex
                )
                .opacity(resolvedOpacity)
            )
        case .gradient:
            let startPoint: UnitPoint = lyricLayoutDirection == .rightToLeft ? .trailing : .leading
            let endPoint: UnitPoint = lyricLayoutDirection == .rightToLeft ? .leading : .trailing
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        lyricsColor(
                            from: gradientLyricsStartColorHex,
                            fallback: PlayerAppearancePreferences.defaultGradientLyricsStartColorHex
                        )
                        .opacity(resolvedOpacity),
                        lyricsColor(
                            from: gradientLyricsEndColorHex,
                            fallback: PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
                        )
                        .opacity(resolvedOpacity),
                    ],
                    startPoint: startPoint,
                    endPoint: endPoint
                )
            )
        }
    }

    private func lyricsColor(from storedHex: String, fallback: String) -> Color {
        Color(
            hex: PlayerAppearancePreferences.normalizedLyricsColorHex(
                storedHex,
                fallback: fallback
            )
        )
    }

    var body: some View {
        Group {
            if lyrics.isEmpty {
                if isResolvingLyrics {
                    LyricsLoadingSkeleton(
                        alignment: lyricsAlignment,
                        tint: appearance.faint,
                        layoutDirection: lyricLayoutDirection
                    )
                } else {
                    emptyLyricsView
                }
            } else if hasWordLevelLyrics {
                smoothWordLyricsView
            } else {
                lineLevelLyricsView
            }
        }
        .overlay(alignment: .topTrailing) {
            translationStatusBadge
                .padding(.top, 8)
                .padding(.trailing, 12)
        }
        .task(id: playbackFollowTaskIdentity) {
            guard hasSynchronizedLyrics else {
                currentLineIndex = -1
                activeInterludeAfterLineIndex = nil
                return
            }
            guard visualActivityPolicy.shouldPollLyrics else {
                updateCurrentLine(disableAnimations: true)
                return
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      visualActivityPolicy.shouldPollLyrics else { break }
                updateCurrentLine()
            }
        }
        .background {
            // 只有这个零尺寸子视图跟随播放时间，整棵歌词树不再随 currentTime 失效。
            LyricsPausedTimeObserver(
                player: player,
                isEnabled: hasSynchronizedLyrics && isSceneActive
            ) {
                updateCurrentLine(disableAnimations: true)
            }
        }
        .onChange(of: isSceneActive) { _, isActive in
            if !isActive {
                lineAutoFollowResumeTask?.cancel()
                updateCurrentLine(disableAnimations: true)
            }
        }
        .onChange(of: songID) { _, _ in
            // 换歌后先等待新歌首句时间戳，再恢复高亮与自动滚动。
            currentLineIndex = -1
            activeInterludeAfterLineIndex = nil
            lastLyricRowTapAt = .distantPast
            lastUserScrollTime = .distantPast
            lyricsPinchScale = 1
            isPinchingLyrics = false
            lineAutoFollowResumeTask?.cancel()
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { _ in
                    let eventTime = Date()
                    Task { @MainActor in
                        await Task.yield()
                        guard LyricsBackgroundTapPolicy.shouldHandle(
                            hasLyrics: !lyrics.isEmpty,
                            isPinching: isPinchingLyrics,
                            rowTapTimeDistance: lastLyricRowTapAt.timeIntervalSince(eventTime)
                        ) else { return }
                        onBackgroundTap()
                    }
                }
        )
    }

    @ViewBuilder
    private var translationStatusBadge: some View {
        switch translationActivity {
        case .idle, .notNeeded:
            EmptyView()
        case .intelligentLoading:
            Label("lyrics_translation_ai_loading", systemImage: "sparkles")
                .lyricsTranslationStatusBadgeStyle()
        case .intelligentCached:
            Label("lyrics_translation_ai_cached", systemImage: "checkmark.circle.fill")
                .lyricsTranslationStatusBadgeStyle()
        case .intelligentSuccess(let provider, let fallbackDepth):
            Label(
                String(
                    format: String(localized: fallbackDepth > 0
                                   ? "lyrics_translation_ai_fallback_success_format"
                                   : "lyrics_translation_ai_success_format"),
                    provider.isEmpty ? String(localized: "ai_provider_default_name") : provider
                ),
                systemImage: fallbackDepth > 0
                    ? "arrow.trianglehead.branch" : "checkmark.circle.fill"
            )
            .lyricsTranslationStatusBadgeStyle()
        case .systemFallback:
            Label("lyrics_translation_ai_system_fallback", systemImage: "arrow.uturn.backward.circle")
                .lyricsTranslationStatusBadgeStyle()
        case .systemPreparationRequired:
            Button {
                lastLyricRowTapAt = Date()
                LyricsTranslationSettingsStore.shared.requestSystemTranslationPreparation()
            } label: {
                Label(String(localized: "Translate Lyrics"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .lyricsTranslationStatusBadgeStyle()
        case .systemUnavailable:
            Label("lyrics_translation_unavailable", systemImage: "exclamationmark.triangle")
                .lyricsTranslationStatusBadgeStyle()
        }
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            Text("no_lyrics")
                .font(.title3)
                .foregroundStyle(appearance.faint)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { emptyLyricsActions }
                VStack(spacing: 10) { emptyLyricsActions }
            }
            if canTranscribeAudio {
                Text("ai_audio_transcription_now_playing_detail")
                    .font(.caption2)
                    .foregroundStyle(appearance.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var emptyLyricsActions: some View {
        Button { onAutomaticScrape() } label: {
            HStack(spacing: 7) {
                if isScrapingCurrentSong {
                    ProgressView()
                        .controlSize(.small)
                        .tint(appearance.primary)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "wand.and.stars")
                        .transition(.scale.combined(with: .opacity))
                }
                Text("scrape_song")
            }
            .font(.subheadline)
            .animation(.smooth(duration: 0.2, extraBounce: 0), value: isScrapingCurrentSong)
        }
        .buttonStyle(.bordered)
        .tint(appearance.primary)
        .disabled(isScrapeActionUnavailable)

        if canTranscribeAudio {
            Button { onTranscribeAudio() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.badge.mic")
                    Text("ai_audio_transcription_action")
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(appearance.primary)
            .disabled(isScrapeActionUnavailable)
        }
    }

    private var lineLevelLyricsView: some View {
        GeometryReader { geo in
            let layoutWidth = lyricLayoutWidth(in: geo.size.width)
            let textWidth = lyricTextWidth(in: geo.size.width)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Give the first and last rows enough physical room to
                        // reach the same visual anchor as every middle row.
                        Spacer().frame(height: geo.size.height * Self.lyricsVisualAnchor)

                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                            let activity = lineLevelRowVisualActivity(index: index)
                            LyricsScaleEnvelopeLayout(
                                maximumScale: Self.lyricsActiveVisualScale,
                                horizontalAnchor: lyricsScaleAnchor
                            ) {
                                lyricsRow(
                                    line: line,
                                    index: index,
                                    dimmedByAmbient: true,
                                    availableWidth: textWidth,
                                    visualScale: CGFloat(activity.scale)
                                )
                            }
                                .id(LyricsScrollTarget.line(id: line.id))
                                .opacity(activity.opacity)
                                .blur(radius: inactiveLyricBlurRadius(for: index))
                                // Match the word-level path: highlight, scale,
                                // and scroll all travel on one curve instead of
                                // snapping the row style before scrolling it.
                                .animation(
                                    .smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0),
                                    value: currentLineIndex
                                )
                                .padding(.vertical, 5)

                            if LyricPlaybackPositionPolicy.hasLongInterlude(
                                afterLine: index,
                                in: lyrics
                            ) {
                                interludeMarker(afterLine: index)
                                    .id(LyricsScrollTarget.interlude(afterLineID: line.id))
                            }
                        }

                        Spacer().frame(height: geo.size.height * (1 - Self.lyricsVisualAnchor))
                    }
                    .frame(width: layoutWidth, alignment: .topLeading)
                    .padding(.horizontal, Self.lyricsHorizontalPadding)
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            isPinchingLyrics = true
                            lyricsPinchScale = value.magnification
                        }
                        .onEnded { value in
                            let next = lyricsFontScale * Double(value.magnification)
                            lyricsFontScale = min(max(next, Self.lyricsMinScale), Self.lyricsMaxScale)
                            lyricsPinchScale = 1.0
                            isPinchingLyrics = false
                        }
                )
                // 监听任意拖动手势 → 刷新 lastUserScrollTime, 让 onChange 里的 auto
                // scrollTo 暂时退让, 用户能往上往下浏览其他歌词。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in
                            beginLineManualBrowsing()
                        }
                        .onEnded { _ in
                            endLineManualBrowsing(proxy: proxy)
                        }
                )

                // DragGesture.onEnded describes the finger, not the actual
                // ScrollView. Momentum can continue afterwards, and an
                // interrupted gesture may never deliver onEnded. Observe the
                // native scroll phase so auto-follow always resumes from the
                // latest lyric after scrolling really becomes idle.
                .onScrollPhaseChange { oldPhase, newPhase in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        beginLineManualBrowsing()
                    case .idle:
                        if oldPhase == .tracking
                            || oldPhase == .interacting
                            || oldPhase == .decelerating {
                            endLineManualBrowsing(proxy: proxy)
                        }
                    case .animating:
                        // Programmatic scrollTo animation is auto-follow, not
                        // a reason to enter manual browsing mode.
                        break
                    }
                }
                .onChange(of: playbackScrollTarget) { _, target in
                    guard isSceneActive,
                          !isRestoringVisualPosition,
                          !isPinchingLyrics,
                          let target else { return }
                    // 用户手动滚动后 manualScrollGracePeriod 内不要把视图拽回当前行,
                    // 否则刚拖到想看的位置又被自动 scrollTo 弹回, 等同不能浏览。
                    guard Date().timeIntervalSince(lastUserScrollTime) >= Self.manualScrollGracePeriod
                    else { return }
                    scroll(to: target, proxy: proxy, animated: true)
                }
                .onChange(of: lyricsFontScale) { _, _ in
                    scheduleLineAutoFollowResume(proxy: proxy, delay: 0)
                }
                .task(id: lineLevelScrollIdentity) {
                    guard isSceneActive else { return }
                    isRestoringVisualPosition = true
                    defer { isRestoringVisualPosition = false }
                    let target = updateCurrentLine(disableAnimations: true)
                    // Publish the active row first, then allow SwiftUI to lay
                    // out that state before issuing the initial scroll request.
                    await Task.yield()
                    guard !Task.isCancelled, let target else { return }
                    scroll(to: target, proxy: proxy, animated: false)
                }
                .onDisappear {
                    lineAutoFollowResumeTask?.cancel()
                    isManuallyBrowsingLyrics = false
                }
            }
        }
        .clipped()
        .mask(lyricsViewportFadeMask)
    }

    private var smoothWordLyricsView: some View {
        GeometryReader { geo in
            let layoutWidth = lyricLayoutWidth(in: geo.size.width)
            let textWidth = lyricTextWidth(in: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Spacer().frame(height: geo.size.height * Self.lyricsVisualAnchor)

                        wordLevelBadge

                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                            let activity = rowVisualActivity(index: index)
                            LyricsScaleEnvelopeLayout(
                                maximumScale: Self.lyricsActiveVisualScale,
                                horizontalAnchor: lyricsScaleAnchor
                            ) {
                                lyricsRow(
                                    line: line,
                                    index: index,
                                    dimmedByAmbient: true,
                                    availableWidth: textWidth,
                                    visualScale: CGFloat(activity.scale)
                                )
                            }
                            .id(LyricsScrollTarget.line(id: line.id))
                            .opacity(activity.opacity)
                            .blur(radius: inactiveLyricBlurRadius(for: index))
                            .animation(
                                .smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0),
                                value: currentLineIndex
                            )
                            .padding(.vertical, 5)

                            if LyricPlaybackPositionPolicy.hasLongInterlude(
                                afterLine: index,
                                in: lyrics
                            ) {
                                interludeMarker(afterLine: index)
                                    .id(LyricsScrollTarget.interlude(afterLineID: line.id))
                            }
                        }

                        Spacer().frame(height: geo.size.height * (1 - Self.lyricsVisualAnchor))
                    }
                    .frame(width: layoutWidth, alignment: .topLeading)
                    .padding(.horizontal, Self.lyricsHorizontalPadding)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in beginLineManualBrowsing() }
                        .onEnded { _ in endLineManualBrowsing(proxy: proxy) }
                )
                .onScrollPhaseChange { oldPhase, newPhase in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        beginLineManualBrowsing()
                    case .idle:
                        if oldPhase == .tracking
                            || oldPhase == .interacting
                            || oldPhase == .decelerating {
                            endLineManualBrowsing(proxy: proxy)
                        }
                    case .animating:
                        break
                    }
                }
                .onChange(of: playbackScrollTarget) { _, target in
                    guard isSceneActive,
                          !isRestoringVisualPosition,
                          !isPinchingLyrics,
                          let target,
                          Date().timeIntervalSince(lastUserScrollTime) >= Self.manualScrollGracePeriod
                    else { return }
                    scroll(to: target, proxy: proxy, animated: true)
                }
                .onChange(of: lyricsFontScale) { _, _ in
                    scheduleLineAutoFollowResume(proxy: proxy, delay: 0)
                }
                .task(id: lyricsPresentationIdentity) {
                    guard isSceneActive else { return }
                    isRestoringVisualPosition = true
                    defer { isRestoringVisualPosition = false }
                    let target = updateCurrentLine(disableAnimations: true)
                    await Task.yield()
                    guard !Task.isCancelled, let target else { return }
                    scroll(to: target, proxy: proxy, animated: false)
                }
                .onDisappear {
                    lineAutoFollowResumeTask?.cancel()
                    isManuallyBrowsingLyrics = false
                }
            }
        }
        .clipped()
        .mask(lyricsViewportFadeMask)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    isPinchingLyrics = true
                    lyricsPinchScale = value.magnification
                }
                .onEnded { value in
                    let next = lyricsFontScale * Double(value.magnification)
                    lyricsFontScale = min(max(next, Self.lyricsMinScale), Self.lyricsMaxScale)
                    lyricsPinchScale = 1.0
                    isPinchingLyrics = false
                }
        )
    }

    private var lineLevelScrollIdentity: String {
        lyricsPresentationIdentity
    }

    private var lyricsPresentationIdentity: String {
        "\(songID ?? "")|\(lyricsRevision)|\(isSceneActive)"
    }

    private enum LyricsScrollTarget: Hashable {
        case line(id: String)
        case interlude(afterLineID: String)
    }

    private var playbackScrollTarget: LyricsScrollTarget? {
        if let index = activeInterludeAfterLineIndex,
           lyrics.indices.contains(index) {
            return .interlude(afterLineID: lyrics[index].id)
        }
        guard lyrics.indices.contains(currentLineIndex) else { return nil }
        return .line(id: lyrics[currentLineIndex].id)
    }

    private struct PlaybackFollowTaskIdentity: Hashable {
        let songID: String?
        let lyricsRevision: UInt
        let isPlaying: Bool
        let isSceneActive: Bool
        let reduceMotion: Bool
    }

    private var playbackFollowTaskIdentity: PlaybackFollowTaskIdentity {
        PlaybackFollowTaskIdentity(
            songID: songID,
            lyricsRevision: lyricsRevision,
            isPlaying: player.isPlaying,
            isSceneActive: isSceneActive,
            reduceMotion: reduceMotion
        )
    }

    private func beginLineManualBrowsing() {
        lineAutoFollowResumeTask?.cancel()
        lastUserScrollTime = Date()
        guard !isManuallyBrowsingLyrics else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isManuallyBrowsingLyrics = true
        }
    }

    private func endLineManualBrowsing(proxy: ScrollViewProxy) {
        lastUserScrollTime = Date()
        scheduleLineAutoFollowResume(proxy: proxy)
    }

    private func scheduleLineAutoFollowResume(
        proxy: ScrollViewProxy,
        delay: TimeInterval = Self.manualScrollGracePeriod
    ) {
        lineAutoFollowResumeTask?.cancel()
        guard isSceneActive else { return }
        lineAutoFollowResumeTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled,
                  isSceneActive,
                  !isPinchingLyrics,
                  Date().timeIntervalSince(lastUserScrollTime) >= delay else { return }
            withAnimation(.smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0)) {
                isManuallyBrowsingLyrics = false
            }
            guard let target = playbackScrollTarget else { return }
            scroll(to: target, proxy: proxy, animated: true)
        }
    }

    private var lyricsViewportFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func scroll(
        to target: LyricsScrollTarget,
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let update = {
            proxy.scrollTo(
                target,
                anchor: UnitPoint(x: 0.5, y: Self.lyricsVisualAnchor)
            )
        }
        if animated {
            withAnimation(.smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0), update)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        }
    }

    private func interludeMarker(afterLine index: Int) -> some View {
        let isActive = activeInterludeAfterLineIndex == index
        return Image(systemName: "ellipsis")
            .font(.title3.weight(.semibold))
            .foregroundStyle(appearance.secondary)
            .symbolEffect(
                .variableColor.iterative,
                isActive: isActive && !reduceMotion
            )
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .opacity(isActive ? 0.9 : appearance.futureLyricOpacity * 0.65)
            .animation(.smooth(duration: 0.3, extraBounce: 0), value: isActive)
            .accessibilityHidden(true)
    }

    private var wordLevelBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.caption2)
            Text("lyrics_word_level_badge")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(appearance.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(appearance.primary.opacity(0.10)))
        .padding(.bottom, 4)
    }

    /// 一句歌词下面要显示的附属文本, 顺序与歌词文件里写的一致。
    ///
    /// 同一个时间戳上的多行(外语歌常见「原文 + 注音 + 译文」)在解析时已经并进
    /// 原文, 三行讲的是同一句, 全部列出来才不会把注音或者译文藏掉; 翻译任务给出
    /// 的那一条排在最后, 文件里已有同样文字时不重复。规则在 kit 里, 便于测试。
    static func companionTexts(
        for line: LyricLine,
        translatedTextByLineID: [String: String]
    ) -> [String] {
        LyricCompanionTextPolicy.texts(
            for: line,
            translatedText: translatedTextByLineID[line.id]
        )
    }

    /// dimmedByAmbient: 统一动效模式调用时传 true ── 表明行整体明暗由外层
    /// opacity 接管, row 内部不要再按 isActive 离散切换颜色,否则跟外层
    /// .opacity multiply 会双重叠加 + 跳变。
    @ViewBuilder
    private func lyricsRow(
        line: LyricLine,
        index: Int,
        dimmedByAmbient: Bool = false,
        timelineTime: TimeInterval? = nil,
        availableWidth: CGFloat,
        visualScale: CGFloat = 1
    ) -> some View {
        let isActive = index == currentLineIndex
        let playbackTime = timelineTime ?? player.currentTime
        let fontSize = Self.lyricsLayoutBaseSize * CGFloat(effectiveLyricsScale)
        // weight 在统一动效模式下固定 .semibold。active 行已有 scale + opacity
        // 强调, weight 瞬时跳变只会让切句增加视觉颗粒感。
        let weight: Font.Weight = dimmedByAmbient ? .semibold : (isActive ? .bold : .semibold)
        let alignment = lyricsAlignment.horizontalAlignment
        let frameAlignment = lyricsAlignment.frameAlignment
        let companions = Self.companionTexts(for: line, translatedTextByLineID: translatedTextByLineID)

        // 组内(原文与其译文)贴紧，组间(不同时间轴的两句)拉开 —— 两者此前都是
        // 4pt，一句歌词和它的译文看起来跟相邻的另一句一样远，读的时候要自己
        // 分辨哪一行属于哪一句。
        VStack(alignment: alignment, spacing: 3) {
            singleLineContent(
                line: line,
                isActive: isActive,
                index: index,
                fontSize: fontSize,
                weight: weight,
                textAlignment: lyricsAlignment.textAlignment,
                dimmedByAmbient: dimmedByAmbient,
                timelineTime: timelineTime,
                deactivationTime: wordLevelDeactivationTime(for: index)
            )
                .contentShape(Rectangle())
                .if(canSeekToLyricLine(line)) { view in
                    view
                        .onTapGesture { seekToLyricLine(line) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("player_tap_lyrics_to_seek_description"))
                }
                // 长按这一句做歌词海报。点按仍然是跳转播放位置 —— 两者
                // 不冲突, 长按只在手指停留足够久时才触发。
                .onLongPressGesture(minimumDuration: 0.45) {
                    onShareLyricLine(line.id)
                }
                .accessibilityAction(named: Text("lyric_poster_menu")) {
                    onShareLyricLine(line.id)
                }
                .frame(width: availableWidth, alignment: frameAlignment)

            // 歌词翻译 — 在原文下面以略小的字号显示。字号取原文的 0.65 +
            // medium weight, 视觉上是 secondary。注音和译文共用一个时间戳时
            // 两条都属于这一句, 按文件里的先后顺序依次排在原文下面。
            ForEach(companions.indices, id: \.self) { slot in
                Text(companions[slot])
                    .font(.system(size: fontSize * 0.65, weight: .medium))
                    .foregroundStyle(
                        dimmedByAmbient
                            ? appearance.secondary
                            : isActive ? appearance.secondary
                            : index < currentLineIndex
                                ? appearance.primary.opacity(appearance.pastLyricOpacity * 0.72)
                                : appearance.primary.opacity(appearance.futureLyricOpacity * 0.72)
                    )
                    .multilineTextAlignment(lyricsAlignment.textAlignment)
                    // 长翻译在窄屏 / 大字号下要 wrap 多行。不加 fixedSize 时 SwiftUI
                    // 会优先单行 + 截断显示省略号。
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .if(canSeekToLyricLine(line)) { view in
                        view
                            .onTapGesture { seekToLyricLine(line) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint(Text("player_tap_lyrics_to_seek_description"))
                    }
                    .frame(width: availableWidth, alignment: frameAlignment)
            }

            if let bgs = line.background {
                ForEach(bgs) { bg in
                    let isBackgroundActive = LyricVoiceTimelinePolicy.isActive(
                        bg,
                        at: playbackTime,
                        lookahead: Self.wordLevelLineLookahead
                    )
                    singleLineContent(
                        line: bg,
                        isActive: isBackgroundActive,
                        index: index,
                        fontSize: fontSize * 0.7,
                        weight: .medium,
                        textAlignment: lyricsAlignment.textAlignment,
                        dimmedByAmbient: dimmedByAmbient,
                        timelineTime: timelineTime,
                        deactivationTime: bg.endTime
                    )
                        .opacity(0.7)
                        .contentShape(Rectangle())
                        .if(canSeekToLyricLine(bg)) { view in
                            view
                                .onTapGesture { seekToLyricLine(bg) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint(Text("player_tap_lyrics_to_seek_description"))
                        }
                        .frame(width: availableWidth, alignment: frameAlignment)

                    let backgroundCompanions = Self.companionTexts(for: bg, translatedTextByLineID: translatedTextByLineID)
                    ForEach(backgroundCompanions.indices, id: \.self) { slot in
                        Text(backgroundCompanions[slot])
                            .font(.system(size: fontSize * 0.7 * 0.65, weight: .medium))
                            .foregroundStyle(appearance.secondary)
                            .multilineTextAlignment(lyricsAlignment.textAlignment)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                            .if(canSeekToLyricLine(bg)) { view in
                                view
                                    .onTapGesture { seekToLyricLine(bg) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint(Text("player_tap_lyrics_to_seek_description"))
                            }
                            .frame(width: availableWidth, alignment: frameAlignment)
                            .opacity(0.7)
                    }
                }
            }
        }
        .frame(width: availableWidth, alignment: frameAlignment)
        // Active emphasis stays a render-layer transform so playback changes
        // never reflow surrounding rows. The stable text width reserves the
        // maximum scale, and the anchor follows the selected alignment.
        .scaleEffect(visualScale, anchor: lyricsScaleAnchor)
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    private func seekToLyricLine(_ line: LyricLine) {
        lastLyricRowTapAt = Date()
        guard canSeekToLyricLine(line) else { return }
        player.seek(to: line.timestamp)
    }

    private func canSeekToLyricLine(_ line: LyricLine) -> Bool {
        NowPlayingInteractionPolicy.shouldSeekFromLyricTap(
            settingEnabled: tapLyricsToSeek,
            lineIsSynchronized: line.isSynchronized
        )
    }

    @ViewBuilder
    private func singleLineContent(
        line: LyricLine,
        isActive: Bool,
        index: Int,
        fontSize: CGFloat,
        weight: Font.Weight,
        textAlignment: TextAlignment,
        dimmedByAmbient: Bool = false,
        timelineTime: TimeInterval? = nil,
        deactivationTime: TimeInterval? = nil
    ) -> some View {
        if line.isWordLevel {
            let animatesWords = shouldRenderWordTimeline(
                line: line,
                index: index,
                isActive: isActive,
                dimmedByAmbient: dimmedByAmbient
            )
            let usesLiveTimeline = animatesWords
                && visualActivityPolicy.shouldRunWordTimeline
            let fixedPlaybackTime = usesLiveTimeline
                ? timelineTime
                : (timelineTime ?? visualPlaybackTime)
            // dimmedByAmbient 模式: KaraokeLineView 内部用固定 active=1.0 / inactive=0.4
            // 对比, 外层 ambient opacity 接管 row 整体明暗。这样无论 row 处于 future /
            // active / past, syllable 扫光的对比度都一致, 只是整体亮度被 ambient
            // 平滑过渡。
            let inactiveOpacity: Double = dimmedByAmbient ? appearance.inactiveSyllableOpacity
                : (isActive
                    ? appearance.inactiveSyllableOpacity
                    : (index < currentLineIndex
                        ? appearance.pastLyricOpacity
                        : appearance.futureLyricOpacity))
            let activeOpacity: Double = dimmedByAmbient ? 1.0
                : (isActive ? 1.0 : inactiveOpacity)
            KaraokeLineView(
                line: line,
                fontSize: fontSize,
                weight: weight,
                activeStyle: isActive
                    ? currentLyricStyle(opacity: activeOpacity)
                    : AnyShapeStyle(appearance.primary.opacity(activeOpacity)),
                inactiveColor: appearance.primary.opacity(inactiveOpacity),
                textAlignment: textAlignment,
                writingDirection: lyricsWritingDirection,
                timeAt: { date in player.interpolatedTime(at: date) },
                fixedTime: fixedPlaybackTime,
                isAnimationEnabled: animatesWords,
                animatesSyllableBounce: visualActivityPolicy.shouldRunWordTimeline,
                deactivationTime: dimmedByAmbient ? deactivationTime : nil
            )
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(lyricLineStyle(
                    isActive: isActive,
                    index: index,
                    dimmedByAmbient: dimmedByAmbient
                ))
                .multilineTextAlignment(textAlignment)
                // 长歌词在窄屏 / 放大字号下需要 wrap 多行。不加 fixedSize 时 SwiftUI
                // 在某些 layout 约束下会单行 + 省略号; 而靠近当前行时切到 KaraokeLineView
                // (它有 fixedSize) 会展开多行 → 视觉上"省略号展开收起"的跳动。
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lyricLineStyle(
        isActive: Bool,
        index: Int,
        dimmedByAmbient: Bool
    ) -> AnyShapeStyle {
        if isActive {
            return currentLyricStyle()
        }
        if dimmedByAmbient {
            return AnyShapeStyle(appearance.primary)
        }
        return AnyShapeStyle(
            index < currentLineIndex
                ? appearance.primary.opacity(appearance.pastLyricOpacity)
                : appearance.primary.opacity(appearance.futureLyricOpacity)
        )
    }

    /// 字级模式 row 的视觉状态。
    private struct RowActivity {
        var opacity: Double
        var scale: Double
    }

    /// 字级模式专用。scale 只在 active 切换时离散变化 (1.0 ↔ lyricsActiveVisualScale),
    /// 且由 lyricsRow 用 scaleEffect (渲染层) 应用 ── 不改字号/布局, 不会引发
    /// 行宽行高重排, 因此既不会每秒重排 60 次, 也不会和自动滚动反馈打满主线程。
    /// 实际明暗 + 大小过渡都由外层 .animation(value: currentLineIndex) 平滑插值。
    private func rowVisualActivity(index: Int) -> RowActivity {
        guard index >= 0, index < lyrics.count else {
            return RowActivity(opacity: appearance.futureLyricOpacity, scale: 1.0)
        }
        let hasActiveBackground = lyrics[index].background?.contains {
            LyricVoiceTimelinePolicy.isActive($0, at: player.currentTime)
        } ?? false
        return RowActivity(
            opacity: index == currentLineIndex || hasActiveBackground
                ? 1.0
                : (index < currentLineIndex
                    ? appearance.pastLyricOpacity
                    : appearance.futureLyricOpacity),
            scale: index == currentLineIndex ? Self.lyricsActiveVisualScale : 1.0
        )
    }

    /// 行级歌词保留原有的过去/未来明暗层次，只把离散字号切换改成与
    /// 逐字歌词一致的渲染层缩放。这样不改变布局，也能让切句三种动效同步。
    private func lineLevelRowVisualActivity(index: Int) -> RowActivity {
        guard hasSynchronizedLyrics else {
            return RowActivity(opacity: 1.0, scale: 1.0)
        }
        guard index >= 0, index < lyrics.count else {
            return RowActivity(opacity: appearance.futureLyricOpacity, scale: 1.0)
        }
        let isActive = index == currentLineIndex
            || (lyrics[index].background?.contains {
                LyricVoiceTimelinePolicy.isActive($0, at: player.currentTime)
            } ?? false)
        let opacity = isActive
            ? 1.0
            : (index < currentLineIndex
                ? appearance.pastLyricOpacity
                : appearance.futureLyricOpacity)
        return RowActivity(
            opacity: opacity,
            scale: isActive ? Self.lyricsActiveVisualScale : 1.0
        )
    }

    private func lyricLayoutWidth(in viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - Self.lyricsHorizontalPadding * 2)
    }

    private func lyricTextWidth(in viewportWidth: CGFloat) -> CGFloat {
        CGFloat(LyricRowLayoutPolicy.unscaledContentWidth(
            viewportWidth: Double(viewportWidth),
            horizontalPadding: Double(Self.lyricsHorizontalPadding),
            maximumVisualScale: Double(Self.lyricsActiveVisualScale)
        ))
    }

    private func inactiveLyricBlurRadius(for index: Int) -> CGFloat {
        CGFloat(LyricDepthEffectPolicy.blurRadius(
            forRow: index,
            activeRow: currentLineIndex,
            isEnabled: blursInactiveLyrics
                && !reduceTransparency
                && !isManuallyBrowsingLyrics
                && !isPinchingLyrics,
            isSynchronized: hasSynchronizedLyrics
        ))
    }

    private func shouldRenderWordTimeline(line: LyricLine, index: Int, isActive: Bool, dimmedByAmbient: Bool = false) -> Bool {
        guard line.isWordLevel else { return false }
        // dimmedByAmbient 模式 (字级歌词): 只让 active 行走 KaraokeLineView 扫光,
        // 相邻 ±1 行也走普通 Text。
        //
        // 原因: KaraokeLineView 内部 inactive syllable 用较低透明度的语义前景色实现
        // 双层 Text 的"扫光底色对比"; 而 row 外层 ambient opacity 在非 active 行
        // 也是 0.4。两者 multiply → 0.16, 比远行 (普通 Text × 0.4 = 0.4) 显著
        // 暗一档 ── 用户看到的"下一行比下下行还暗"就是这个双重 multiply 造成。
        //
        // 代价: 下一行失去"提前 100ms 预热扫光"的细节, 行真正切到 active 时才
        // 启动扫光。lookahead 100ms 在视觉上几乎不可察觉, 取舍合理。
        if dimmedByAmbient { return isActive }
        return isActive || abs(index - currentLineIndex) == 1
    }

    private func wordLevelDeactivationTime(for index: Int) -> TimeInterval? {
        guard hasWordLevelLyrics else { return nil }
        return LyricPlaybackPositionPolicy.wordLevelDeactivationTime(
            in: lyrics,
            afterLine: index,
            lookahead: Self.wordLevelLineLookahead
        )
    }

    /// 行级歌词 LRC 文件的 timestamp 通常是「演唱开始那一刻」,但 LRC 制作过程
    /// 中作者按 spacebar 记录会有人为反应延迟(常见 200-400ms),用户感受是
    /// 「头两个字唱完才高亮这一行」。给行级判断加 250ms lookahead 提前切换。
    /// 字级歌词 syllable 粒度精度本来就高,但行切换时也需要一点预热时间;
    /// 否则下一行会在第一个字开唱时才从普通行切成逐字 Timeline,跨行会显得顿。
    private static let lineLevelLookahead: TimeInterval = 0.25
    private static let wordLevelLineLookahead: TimeInterval = 0.10
    /// Line-level and word-level takeovers share one curve so scrolling,
    /// highlight, and scale read as a single continuous gesture.
    private static let lyricsTransitionDuration: TimeInterval = 0.54
    /// Keep the active line in the upper-middle of the compact phone viewport.
    /// 42% left too little room for upcoming lyrics once the header and bottom
    /// controls were present, which made a missed follow update more obvious.
    private static let lyricsVisualAnchor: CGFloat = 0.36
    /// Active rows render larger without changing their measured layout.
    /// LyricRowLayoutPolicy reserves this scale horizontally to prevent overflow.
    private static let lyricsActiveVisualScale: CGFloat = 1.08
    @discardableResult
    private func updateCurrentLine(
        disableAnimations: Bool = false
    ) -> LyricsScrollTarget? {
        guard hasSynchronizedLyrics else {
            if currentLineIndex != -1 { currentLineIndex = -1 }
            if activeInterludeAfterLineIndex != nil {
                activeInterludeAfterLineIndex = nil
            }
            return nil
        }
        let time = player.interpolatedTime()
        if !visualActivityPolicy.shouldRunWordTimeline {
            visualPlaybackTime = time
        }
        let lookahead = hasWordLevelLyrics
            ? Self.wordLevelLineLookahead
            : Self.lineLevelLookahead
        guard let position = LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: time,
            lookahead: lookahead
        ) else {
            let clearActiveLine = {
                if currentLineIndex != -1 { currentLineIndex = -1 }
                if activeInterludeAfterLineIndex != nil {
                    activeInterludeAfterLineIndex = nil
                }
            }
            if disableAnimations {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, clearActiveLine)
            } else {
                clearActiveLine()
            }
            return nil
        }

        let activeIndex: Int
        let interludeAfterLineIndex: Int?
        let scrollTarget: LyricsScrollTarget
        switch position {
        case .line(let index):
            guard lyrics.indices.contains(index) else { return nil }
            activeIndex = index
            interludeAfterLineIndex = nil
            scrollTarget = .line(id: lyrics[index].id)
        case .interlude(let index):
            guard lyrics.indices.contains(index) else { return nil }
            activeIndex = index
            interludeAfterLineIndex = index
            scrollTarget = .interlude(afterLineID: lyrics[index].id)
        }

        let update = {
            if currentLineIndex != activeIndex {
                currentLineIndex = activeIndex
            }
            if activeInterludeAfterLineIndex != interludeAfterLineIndex {
                activeInterludeAfterLineIndex = interludeAfterLineIndex
            }
        }
        if disableAnimations {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                update()
            }
        } else {
            update()
        }
        return scrollTarget
    }
}

private extension View {
    func lyricsTranslationStatusBadgeStyle() -> some View {
        font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    func lyricsTranslationTaskIfAvailable(
        songID: String?,
        lyricsRevision: UInt,
        lyrics: [LyricLine],
        settings: LyricsTranslationSettingsStore,
        translatedTextByLineID: Binding<[String: String]>,
        activity: Binding<LyricsTranslationActivity>
    ) -> some View {
        if #available(iOS 18.0, *) {
            modifier(
                LyricsTranslationTaskModifier(
                    songID: songID,
                    lyricsRevision: lyricsRevision,
                    lyrics: lyrics,
                    settings: settings,
                    translatedTextByLineID: translatedTextByLineID,
                    activity: activity
                )
            )
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
private struct LyricsTranslationTaskModifier: ViewModifier {
    @Environment(MusicIntelligenceService.self) private var intelligence
    let songID: String?
    let lyricsRevision: UInt
    let lyrics: [LyricLine]
    let settings: LyricsTranslationSettingsStore
    @Binding var translatedTextByLineID: [String: String]
    @Binding var activity: LyricsTranslationActivity

    @State private var translationConfig: TranslationSession.Configuration?
    @State private var preparedGroups: [LyricTranslationGroup] = []
    @State private var activeGroupIndex = 0
    @State private var preparedIdentity: TranslationTaskIdentity?
    @State private var completionActivity: LyricsTranslationActivity?

    private struct TranslationTaskIdentity: Hashable {
        let songID: String?
        let lyricsRevision: UInt
        let isEnabled: Bool
        let targetLanguageCode: String
        let mode: LyricsTranslationMode
        let systemPreparationRequestRevision: UInt
        /// 只认真正影响翻译决策的那个结论，而不是地区服务的原始修订号。
        ///
        /// 地区服务每刷新一次会把修订号加两次（先置未知、再发布结果），而翻译
        /// 准备唯一用到它的地方是这个布尔值 —— 拿原始修订号当重启键，等于每次
        /// 商店信息抖动都白白重启两轮翻译准备，每轮都要再问一遍系统语言可用性。
        let exposesRemoteConfiguration: Bool
    }

    private var translationTaskIdentity: TranslationTaskIdentity {
        TranslationTaskIdentity(
            songID: songID,
            lyricsRevision: lyricsRevision,
            isEnabled: settings.isEnabled,
            targetLanguageCode: LyricsTranslationSettingsStore.normalizedLanguageCode(
                settings.targetLanguageCode
            ),
            mode: settings.mode,
            systemPreparationRequestRevision: settings.systemPreparationRequestRevision,
            exposesRemoteConfiguration: intelligence.shouldExposeRemoteConfiguration
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: translationTaskIdentity) {
                let identity = translationTaskIdentity
                await prepareTranslation(for: identity)
            }
            .translationTask(translationConfig) { session in
                await runTranslation(session: session)
            }
    }

    /// 按检测到的源语言拆分歌词。Translation 的一个 batch 只能对应一个
    /// source/target 语言对，混合语言放进同一自动检测 batch 会导致整批失败。
    private func prepareTranslation(for identity: TranslationTaskIdentity) async {
        guard !Task.isCancelled, translationTaskIdentity == identity else { return }

        translationConfig = nil
        preparedGroups = []
        activeGroupIndex = 0
        preparedIdentity = nil
        completionActivity = nil
        translatedTextByLineID = [:]
        activity = .idle

        // 歌词文件自带的译文是歌词内容的一部分，不是机器翻译的产物 ——
        // 双语 LRC 把它和原文写在一起，用户不开「歌词翻译」也应该看得见。
        // 那个开关管的是「要不要再去翻译一遍」，不该连内容一起藏掉。
        let translationLines = LyricVoiceTimelinePolicy.flattenedLines(lyrics)
        // 罗马音 / 拼音这类读音行按整篇判一次，逐行选译文时把它们排除掉。
        let readingIDs = LyricRomanizedReadingPolicy.readingIDs(in: translationLines)
        let manualTranslations = translationLines.reduce(into: [String: String]()) { result, line in
            guard let manualTranslation = LyricManualTranslationPolicy.preferredTranslation(
                for: line,
                targetLanguageCode: identity.targetLanguageCode,
                readingIDs: readingIDs
            ) else { return }
            let text = manualTranslation.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            result[line.id] = text
        }
        translatedTextByLineID = manualTranslations

        guard identity.isEnabled, !lyrics.isEmpty else {
            activity = .notNeeded
            return
        }
        if LyricManualTranslationPolicy.hasCompleteCoverage(
            in: translationLines,
            targetLanguageCode: identity.targetLanguageCode,
            readingIDs: readingIDs
        ) {
            activity = .notNeeded
            return
        }

        let explicitlyRequested = settings.consumeSystemTranslationPreparationRequest(
            revision: identity.systemPreparationRequestRevision
        )

        let lyricTexts = translationLines.map(\.text)
        let metadataLines = lyrics.lazy.compactMap(\.metadataLines).first ?? []
        let declaredSourceLanguageCode = LyricsTranslationSettingsStore
            .declaredLyricsLanguageCode(from: metadataLines)
        let fallbackSourceLanguageCode = LyricsTranslationSettingsStore.detectedLyricsLanguageCode(
            for: lyricTexts,
            metadataLines: metadataLines
        )
        let candidates = translationLines.compactMap { line -> LyricTranslationCandidate? in
            guard manualTranslations[line.id] == nil else { return nil }
            let lineDeclaredLanguageCode = line.languageCode ?? declaredSourceLanguageCode
            return LyricTranslationCandidate(
                id: line.id,
                text: line.text,
                sourceLanguageCode: LyricsTranslationSettingsStore.detectedLanguageCode(
                    for: line.text,
                    fallbackLanguageCode: fallbackSourceLanguageCode,
                    declaredLanguageCode: lineDeclaredLanguageCode
                )
            )
        }
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: candidates,
            targetLanguageCode: identity.targetLanguageCode,
            fallbackSourceLanguageCode: fallbackSourceLanguageCode
        )
        guard !groups.isEmpty else {
            activity = .notNeeded
            return
        }

        let cache = LyricsTranslationCache.shared
        let usesIntelligentProvider = identity.mode == .intelligentWithSystemFallback
            && intelligence.shouldExposeRemoteConfiguration
        let preferredCacheProvider: LyricsTranslationCache.ProviderNamespace =
            usesIntelligentProvider ? .intelligent : .system
        var hits = manualTranslations
        var uncachedGroups: [LyricTranslationGroup] = []

        for group in groups {
            let pending = group.candidates.filter { candidate in
                if let translated = cache.translation(
                    for: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode,
                    provider: preferredCacheProvider
                ) {
                    hits[candidate.id] = translated
                    return false
                }
                return true
            }
            if !pending.isEmpty {
                uncachedGroups.append(
                    LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: pending
                    )
                )
            }
        }

        translatedTextByLineID = hits
        guard !uncachedGroups.isEmpty else {
            if preferredCacheProvider == .intelligent, !hits.isEmpty {
                activity = .intelligentCached
            }
            return
        }

        if usesIntelligentProvider {
            activity = .intelligentLoading
            let pendingCandidates = uncachedGroups.flatMap(\.candidates)
            var streamedTranslations: [String: String] = [:]
            if let execution = await intelligence.translateLyrics(
                pendingCandidates,
                targetLanguageCode: identity.targetLanguageCode,
                onStreamEvent: { event in
                    guard !Task.isCancelled,
                          translationTaskIdentity == identity else { return }
                    switch event {
                    case .reset:
                        for id in streamedTranslations.keys {
                            translatedTextByLineID[id] = hits[id]
                        }
                        streamedTranslations = [:]
                    case .translation(let id, let text):
                        streamedTranslations[id] = text
                        translatedTextByLineID[id] = text
                    case .completed:
                        break
                    }
                }
            ), !Task.isCancelled, translationTaskIdentity == identity {
                var cachePairs: [(source: String, sourceLang: String?, translated: String)] = []
                for group in uncachedGroups {
                    for candidate in group.candidates {
                        guard let translated = execution.translations[candidate.id] else { continue }
                        cachePairs.append((candidate.text, group.sourceLanguageCode, translated))
                    }
                }
                LyricsTranslationCache.shared.bulkSet(
                    cachePairs,
                    targetLang: identity.targetLanguageCode,
                    provider: .intelligent
                )
                translatedTextByLineID.merge(execution.translations) { _, new in new }
                let translatedIDs = Set(execution.translations.keys)
                uncachedGroups = uncachedGroups.compactMap { group in
                    let remaining = group.candidates.filter {
                        !translatedIDs.contains($0.id)
                    }
                    guard !remaining.isEmpty else { return nil }
                    return LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: remaining
                    )
                }
                if uncachedGroups.isEmpty {
                    activity = .intelligentSuccess(
                        provider: execution.providerName,
                        fallbackDepth: execution.fallbackDepth
                    )
                    return
                }
            }
            guard !Task.isCancelled, translationTaskIdentity == identity else { return }
            activity = .systemFallback

            var systemPendingGroups: [LyricTranslationGroup] = []
            for group in uncachedGroups {
                let pending = group.candidates.filter { candidate in
                    if let translated = cache.translation(
                        for: candidate.text,
                        sourceLang: group.sourceLanguageCode,
                        targetLang: identity.targetLanguageCode,
                        provider: .system
                    ) {
                        hits[candidate.id] = translated
                        return false
                    }
                    return true
                }
                if !pending.isEmpty {
                    systemPendingGroups.append(LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: pending
                    ))
                }
            }
            translatedTextByLineID.merge(hits) { _, new in new }
            uncachedGroups = systemPendingGroups
            guard !uncachedGroups.isEmpty else { return }
        }

        var systemGroups: [LyricTranslationGroup] = []
        var deferredSystemLineCount = 0
        for group in uncachedGroups {
            if !LyricTranslationGroupingPolicy.permitsAppleSystemTranslation(
                sourceLanguageCode: group.sourceLanguageCode,
                targetLanguageCode: identity.targetLanguageCode
            ) {
                // Do not let a historical system-failure cooldown turn an
                // explicitly unsupported Persian pair into a recoverable
                // preparation badge. Positive cache hits were already applied.
                systemGroups.append(group)
                continue
            }
            if !explicitlyRequested, cache.isPairMarkedFailed(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            ) {
                deferredSystemLineCount += group.candidates.count
                continue
            }

            let pending = explicitlyRequested ? group.candidates : group.candidates.filter { candidate in
                if cache.isMarkedFailed(
                    source: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode
                ) {
                    deferredSystemLineCount += 1
                    return false
                }
                return true
            }
            guard !pending.isEmpty else { continue }
            systemGroups.append(
                LyricTranslationGroup(
                    id: group.id,
                    sourceLanguageCode: group.sourceLanguageCode,
                    candidates: pending
                )
            )
        }
        if deferredSystemLineCount > 0 {
            plog("Lyrics translation cooldown skipped \(deferredSystemLineCount) lines")
        }
        guard !systemGroups.isEmpty else {
            if deferredSystemLineCount > 0 { activity = .systemPreparationRequired }
            return
        }

        let target = Locale.Language(identifier: identity.targetLanguageCode)
        var installedGroups: [LyricTranslationGroup] = []
        var preparationRequiredGroups: [LyricTranslationGroup] = []
        var unsupportedSystemLineCount = 0
        var shouldOfferPreparation = deferredSystemLineCount > 0
        var encounteredUnknownAvailabilityStatus = false
        var encounteredAvailabilityError = false
        for group in systemGroups {
            guard !Task.isCancelled else { return }
            guard LyricTranslationGroupingPolicy.permitsAppleSystemTranslation(
                sourceLanguageCode: group.sourceLanguageCode,
                targetLanguageCode: identity.targetLanguageCode
            ) else {
                unsupportedSystemLineCount += group.candidates.count
                plog(
                    "Lyrics translation pair unsupported by system provider: "
                        + "\(group.sourceLanguageCode ?? "auto") -> "
                        + identity.targetLanguageCode
                )
                continue
            }
            if group.sourceLanguageCode == nil, !explicitlyRequested {
                preparationRequiredGroups.append(group)
                continue
            }
            do {
                guard let text = group.candidates.first?.text else { continue }
                let status = try await Self.translationAvailabilityStatus(
                    sourceLanguageCode: group.sourceLanguageCode,
                    sampleText: text,
                    targetLanguageCode: target.minimalIdentifier
                )

                switch status {
                case .installed:
                    if group.sourceLanguageCode == nil {
                        preparationRequiredGroups.append(group)
                    } else {
                        installedGroups.append(group)
                    }
                case .supported:
                    preparationRequiredGroups.append(group)
                    plog(
                        "Lyrics translation language pair requires explicit download: "
                            + "\(group.sourceLanguageCode ?? "auto") -> "
                            + identity.targetLanguageCode
                    )
                case .unsupported:
                    unsupportedSystemLineCount += group.candidates.count
                    plog(
                        "Lyrics translation pair unsupported: "
                            + "\(group.sourceLanguageCode ?? "auto") -> "
                            + identity.targetLanguageCode
                    )
                @unknown default:
                    encounteredUnknownAvailabilityStatus = true
                    shouldOfferPreparation = true
                    plog("Lyrics translation availability returned an unknown status")
                }
            } catch {
                guard !Task.isCancelled, translationTaskIdentity == identity else { return }
                encounteredAvailabilityError = true
                cache.markPairFailed(
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode
                )
                shouldOfferPreparation = true
                plog("Lyrics translation language detection failed: \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled, translationTaskIdentity == identity else { return }
        translatedTextByLineID.merge(hits) { _, new in new }
        var availableGroups = LyricTranslationGroupingPolicy.automaticSessionGroups(
            installed: installedGroups
        )
        if explicitlyRequested,
           let explicitGroup = LyricTranslationGroupingPolicy.explicitlyRequestedSessionGroup(
               preparationRequired: preparationRequiredGroups
           ) {
            availableGroups.append(explicitGroup)
            preparationRequiredGroups.removeAll { $0.id == explicitGroup.id }
        }
        let remainingState = LyricTranslationTerminalPolicy.remainingStateAfterAvailableWork(
            preparationRequiredCandidateCount: preparationRequiredGroups.reduce(0) {
                $0 + $1.candidates.count
            },
            unsupportedCandidateCount: unsupportedSystemLineCount,
            encounteredUnknownStatus: encounteredUnknownAvailabilityStatus,
            encounteredError: encounteredAvailabilityError || shouldOfferPreparation
        )
        switch remainingState {
        case .notNeeded:
            completionActivity = .notNeeded
        case .preparationRequired:
            completionActivity = .systemPreparationRequired
        case .unavailable:
            completionActivity = .systemUnavailable
        case .ready:
            completionActivity = nil
        }
        let terminalState = LyricTranslationTerminalPolicy.resolve(
            pendingCandidateCount: systemGroups.reduce(0) { partial, group in
                partial + group.candidates.count
            },
            availableGroupCount: availableGroups.count,
            preparationRequiredGroupCount: preparationRequiredGroups.count,
            unsupportedCandidateCount: unsupportedSystemLineCount,
            encounteredUnknownStatus: encounteredUnknownAvailabilityStatus,
            encounteredError: encounteredAvailabilityError || shouldOfferPreparation
        )
        switch terminalState {
        case .notNeeded:
            activity = .notNeeded
            return
        case .unavailable:
            activity = .systemUnavailable
            return
        case .preparationRequired:
            activity = .systemPreparationRequired
            return
        case .ready:
            if !preparationRequiredGroups.isEmpty || shouldOfferPreparation {
                activity = .systemPreparationRequired
            }
        }

        preparedGroups = availableGroups
        activeGroupIndex = 0
        preparedIdentity = identity
        activateGroup(at: 0, identity: identity)
    }

    /// Translation's availability reference is not Sendable in the current
    /// SDK. Keep it entirely inside this nonisolated operation and return only
    /// its Sendable status to the view's main-actor state machine.
    private nonisolated static func translationAvailabilityStatus(
        sourceLanguageCode: String?,
        sampleText: String,
        targetLanguageCode: String
    ) async throws -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        let target = Locale.Language(identifier: targetLanguageCode)
        if let sourceLanguageCode {
            return await availability.status(
                from: Locale.Language(identifier: sourceLanguageCode),
                to: target
            )
        }
        return try await availability.status(for: sampleText, to: target)
    }

    /// 为下一组建立 session。同一语言配置再次启用时必须 invalidate 配置版本，
    /// 才能让 SwiftUI 重新运行 translationTask。
    private func activateGroup(at index: Int, identity: TranslationTaskIdentity) {
        guard preparedIdentity == identity, preparedGroups.indices.contains(index) else {
            translationConfig = nil
            return
        }

        activeGroupIndex = index
        let group = preparedGroups[index]
        let source = group.sourceLanguageCode.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: identity.targetLanguageCode)
        var next = TranslationSession.Configuration(source: source, target: target)

        if var current = translationConfig,
           current.source == next.source,
           current.target == next.target {
            current.invalidate()
            next = current
        }
        translationConfig = next
    }

    /// 一次只翻译同一源语言的行。失败进入短时间冷却，避免用户取消下载或系统
    /// 临时错误后，同一首歌立即再次抢占系统展示链。
    private func runTranslation(session: TranslationSession) async {
        guard let identity = preparedIdentity,
              identity == translationTaskIdentity,
              preparedGroups.indices.contains(activeGroupIndex) else {
            return
        }

        let groupIndex = activeGroupIndex
        let group = preparedGroups[groupIndex]
        let requests = group.candidates.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        guard !requests.isEmpty else { return }

        var newCachePairs: [(source: String, sourceLang: String?, translated: String)] = []
        var newStateUpdates: [String: String] = [:]
        var translationFailed = false
        do {
            for try await response in session.translate(batch: requests) {
                guard !Task.isCancelled else { return }
                let id = response.clientIdentifier ?? ""
                let translated = response.targetText
                if !id.isEmpty { newStateUpdates[id] = translated }
                let detectedSourceLanguageCode = LyricsTranslationSettingsStore
                    .normalizedLanguageCode(response.sourceLanguage.minimalIdentifier)
                newCachePairs.append(
                    (
                        source: response.sourceText,
                        sourceLang: group.sourceLanguageCode,
                        translated: translated
                    )
                )
                if !id.isEmpty {
                    translatedTextByLineID[id] = translated
                    LyricsTranslationCache.shared.setTranslation(
                        translated,
                        for: response.sourceText,
                        sourceLang: group.sourceLanguageCode,
                        targetLang: identity.targetLanguageCode,
                        provider: .system
                    )
                }
                if group.sourceLanguageCode != detectedSourceLanguageCode {
                    newCachePairs.append(
                        (
                            source: response.sourceText,
                            sourceLang: detectedSourceLanguageCode,
                            translated: translated
                        )
                    )
                    LyricsTranslationCache.shared.setTranslation(
                        translated,
                        for: response.sourceText,
                        sourceLang: detectedSourceLanguageCode,
                        targetLang: identity.targetLanguageCode,
                        provider: .system
                    )
                }
            }
        } catch {
            guard !Task.isCancelled,
                  preparedIdentity == identity,
                  translationTaskIdentity == identity,
                  activeGroupIndex == groupIndex else { return }
            translationFailed = true
            LyricsTranslationCache.shared.markFailed(
                sources: group.candidates.compactMap { candidate in
                    newStateUpdates[candidate.id] == nil ? candidate.text : nil
                },
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
            LyricsTranslationCache.shared.markPairFailed(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
            plog("Lyrics translation failed: \(error.localizedDescription)")
        }

        guard !Task.isCancelled,
              preparedIdentity == identity,
              translationTaskIdentity == identity,
              activeGroupIndex == groupIndex else { return }

        if !newCachePairs.isEmpty {
            LyricsTranslationCache.shared.bulkSet(
                newCachePairs,
                targetLang: identity.targetLanguageCode,
                provider: .system
            )
        }
        if !translationFailed {
            LyricsTranslationCache.shared.clearPairFailure(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
        }

        if !newStateUpdates.isEmpty {
            translatedTextByLineID.merge(newStateUpdates) { _, new in new }
        }

        guard !translationFailed else {
            activity = .systemPreparationRequired
            translationConfig = nil
            preparedGroups = []
            preparedIdentity = nil
            return
        }

        let nextIndex = groupIndex + 1
        if preparedGroups.indices.contains(nextIndex) {
            activateGroup(at: nextIndex, identity: identity)
        } else {
            translationConfig = nil
            activity = completionActivity ?? .notNeeded
            completionActivity = nil
            preparedGroups = []
            preparedIdentity = nil
        }
    }
}

// MARK: - PlaybackProgressBar (隔离 player.currentTime 高频读)

/// 进度条 + 双端时间标签。父 NowPlayingView body 不直接读 `player.currentTime`,
/// 把高频属性的 Observation 追踪限制在本 view 内。这样 currentTime 每 0.5s 变化
/// 只重算本 view,不会让父 body 重算 → 父 view 里的 SwiftUI Menu submenu (字号
/// 选择)在用户操作期间不会被强制关闭。
fileprivate struct PlaybackProgressBar: View {
    var fillTint: Color? = nil
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var previewTime: TimeInterval?

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    /// 时间标签 0.5 秒跳一次, 正好是数字翻页动画还撑得住的频率上限, 所以按整秒
    /// 驱动而不是按浮点进度。拖动时数字是跟手的, 翻页追不上, 这段期间给 nil。
    private var animatedSecond: Int? {
        guard previewTime == nil else { return nil }
        return player.currentTime.sanitizedDuration.rounded(.down).finiteInt()
    }

    var body: some View {
        let displayedTime = previewTime ?? player.currentTime
        Group {
            if player.isLiveRadio {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("live_badge").fontWeight(.bold)
                    Spacer()
                    Text(player.currentTime.formattedDuration).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(appearance.secondary)
            } else {
                VStack(spacing: 4) {
                    ProgressSlider(
                        value: player.currentTime,
                        total: player.duration,
                        interactionID: player.currentSong?.id,
                        fillTint: fillTint,
                        onPreview: { previewTime = $0 },
                        onSeek: { player.seek(to: $0) }
                    )
                    HStack {
                        Text(displayedTime.formattedDuration)
                            .contentTransition(.numericText()); Spacer()
                        Text("-\(max(0, player.duration - displayedTime).formattedDuration)")
                            .contentTransition(.numericText())
                    }
                    .font(.caption2).foregroundStyle(appearance.tertiary).monospacedDigit()
                    .pmAnimation(.control, value: animatedSecond)
                }
            }
        }
    }
}

// MARK: - Cast Device Picker

/// 投屏目标设备选择。读 DLNARendererService.discoveredRenderers, 显示 LAN 内
/// 所有 MediaRenderer; 顶部"本机播放"项 = 取消投屏 (stopCasting); 选中其它项
/// = startCasting。当前已投屏的设备旁打 checkmark。
struct CastDevicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayerService.self) private var player
    @Environment(DLNARendererService.self) private var renderer

    var body: some View {
        #if os(macOS)
        macBody
            .task {
                renderer.refreshRemoteRenderers()
            }
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        let remoteRenderers = renderer.discoveredRenderers.values.sorted { $0.friendlyName < $1.friendlyName }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tv.and.hifispeaker.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 30, height: 30)
                    .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("cast_to_device")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text("cast_lan_devices")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                Button {
                    renderer.refreshRemoteRenderers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 24, height: 24)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
                .help(Text("refresh"))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    macLocalRendererRow

                    if remoteRenderers.isEmpty {
                        macScanningState
                    } else {
                        ForEach(remoteRenderers) { dev in
                            macRendererRow(dev)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            #if os(macOS)
            .pmForceHideScrollers()
            #endif
            .frame(minHeight: 260, maxHeight: 340)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(spacing: 10) {
                Text("settings_dlna_enable")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                Spacer()
                if player.isCastingMode {
                    Button {
                        Task {
                            await player.stopCasting()
                            dismiss()
                        }
                    } label: {
                        Text("cast_local_subtitle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PMColor.text)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(PMColor.glassBtn, in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 380)
        // 当作为 popover/sheet 弹出时, SwiftUI 系统已经包了 chrome (圆角材质 +
        // 边框 + 阴影 + 箭头), 这里不再画自己的 rounded rect + material + shadow,
        // 否则跟系统 chrome 叠成双层框 (用户截图里那一圈外框就是这么来的)。
    }

    private var macLocalRendererRow: some View {
        Button {
            Task {
                await player.stopCasting()
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                macRendererIcon("macbook.and.iphone")
                VStack(alignment: .leading, spacing: 2) {
                    Text("cast_local_device")
                        .font(.system(size: 12.5, weight: !player.isCastingMode ? .semibold : .medium))
                        .foregroundStyle(PMColor.text)
                    Text("cast_local_subtitle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                }
                Spacer()
                if !player.isCastingMode {
                    Text("casting_connected")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .pmRowBackground(selected: !player.isCastingMode, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func macRendererRow(_ dev: RemoteRenderer) -> some View {
        let selected = player.castingRenderer?.udn == dev.udn
        return Button {
            Task {
                await player.startCasting(to: dev)
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                macRendererIcon(rendererSymbol(for: dev))
                VStack(alignment: .leading, spacing: 2) {
                    Text(dev.friendlyName)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(rendererSubtitle(for: dev))
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Text("casting_connected")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .pmRowBackground(selected: selected, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var macScanningState: some View {
        VStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("cast_scanning")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PMColor.textMuted)
            Text("cast_dlna_required_hint")
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private func macRendererIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PMColor.brand)
            .frame(width: 32, height: 32)
            .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 6))
    }

    private func rendererSymbol(for dev: RemoteRenderer) -> String {
        let text = [dev.friendlyName, dev.modelName, dev.manufacturer]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if text.contains("tv") || text.contains("bravia") { return "tv" }
        if text.contains("speaker") || text.contains("sonos") || text.contains("音箱") { return "hifispeaker.fill" }
        if text.contains("nas") || text.contains("synology") || text.contains("群晖") { return "externaldrive.fill" }
        return "desktopcomputer"
    }

    private func rendererSubtitle(for dev: RemoteRenderer) -> String {
        if let model = dev.modelName, let maker = dev.manufacturer {
            return "\(maker) · \(model)"
        }
        if let model = dev.modelName { return model }
        return dev.host
    }
    #endif

    private var iosBody: some View {
        NavigationStack {
            SkinList {
                Section {
                    Button {
                        Task { await player.stopCasting(); dismiss() }
                    } label: {
                        HStack {
                            Image(systemName: "iphone")
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("cast_local_device")
                                    .font(.body)
                                Text("cast_local_subtitle")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !player.isCastingMode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                let remoteRenderers = renderer.discoveredRenderers.values.sorted { $0.friendlyName < $1.friendlyName }
                if remoteRenderers.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("cast_scanning")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("cast_dlna_required_hint")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                } else {
                    Section {
                        ForEach(remoteRenderers) { dev in
                            Button {
                                Task { await player.startCasting(to: dev); dismiss() }
                            } label: {
                                HStack {
                                    Image(systemName: "tv.and.hifispeaker.fill")
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dev.friendlyName)
                                            .font(.body)
                                            .lineLimit(1)
                                        if let model = dev.modelName {
                                            Text(dev.manufacturer.map { "\($0) · \(model)" } ?? model)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        } else {
                                            Text(dev.host)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if player.castingRenderer?.udn == dev.udn {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("cast_lan_devices")
                    }
                }
            }
            .navigationTitle("cast_picker_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { renderer.refreshRemoteRenderers() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text("refresh"))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "done")) { dismiss() }
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { renderer.refreshRemoteRenderers() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text("refresh"))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
                #endif
            }
            .task {
                // 进 sheet 立刻主动扫一遍, 不等下一次周期触发
                renderer.refreshRemoteRenderers()
            }
        }
    }
}

/// Over the artwork while a music video in a container AVPlayer cannot open
/// is fetched and rewritten into MP4 (first play only). Reads the status
/// itself so its progress updates never re-render the player.
struct MusicVideoPreparationBadge: View {
    let songID: String?

    var body: some View {
        if let text = MusicVideoPreparationStatus.shared.label(for: songID) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(text)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(10)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}

/// `sheet(item:)` needs an identifiable value; a station id is one.
private struct RadioDetailSheetID: Identifiable {
    let id: String
}

private extension View {
    /// A long-press menu that exists only while `isEnabled`, so music keeps
    /// its plain buttons.
    @ViewBuilder
    func bookJumpMenu<Items: View>(isEnabled: Bool, @ViewBuilder items: () -> Items) -> some View {
        if isEnabled {
            contextMenu { items() }
        } else {
            self
        }
    }
}

/// 竖屏播放页的左右让位(见 `NowPlayingView.portraitInsets`)。普通设备只有两侧安全区,
/// 系统竖栏的设备(iPhone Duo)整屏居中,只让开遮挡区。
struct NowPlayingPortraitInsets: Equatable {
    /// 整列两侧。
    var containerLeading: CGFloat
    var containerTrailing: CGFloat
    /// 方形封面边长。
    var artworkSize: CGFloat
    /// MV 画面的宽度上限(整屏居中时不碰遮挡区)。
    var mediaWidthLimit: CGFloat
    /// 封面下面几行两边各多让的(灵动岛长到这段高度时)。
    var rows: CGFloat
    /// 歌词模式里歌词与顶栏在遮挡那一侧让的。
    var lyricsLeading: CGFloat
    var lyricsTrailing: CGFloat
    /// 沉浸歌词:歌词区从遮挡区下沿以下才开始(整屏居中,不为整条竖栏让位),顶上那排圆钮在遮挡那侧让开。
    var immersiveContentTop: CGFloat = 0
    var immersiveTopRowLeading: CGFloat = 0
    var immersiveTopRowTrailing: CGFloat = 0
}

/// 播放页按尺寸选的构图:竖版 / 手机横屏骨架 / iPad 双栏,以及 Duo 内屏的分栏与桌面半折。
/// 歌词、MV 这些由用户切换的模式不在里面 —— 它们有自己的过渡。
private struct NowPlayingCanvasKey: Equatable {
    var layoutMode: NowPlayingPlayerLayoutMode
    var arrangement: NowPlayingArrangement?
}

/// 播放页几副构图里共有的主元素。换构图时同一个元素从旧位置滑到新位置。
private enum NowPlayingLayoutElement: Hashable {
    /// 歌名那一块(歌名、艺人)。只对齐左上角,不插值尺寸 —— 两边字号不同,插值宽度会让字一路折行。
    case songHeading
    case progress
    case transport
}

private extension View {
    func matchedLayoutElement(_ element: NowPlayingLayoutElement, in namespace: Namespace.ID) -> some View {
        modifier(NowPlayingMatchedLayoutElement(element: element, namespace: namespace))
    }
}

private struct NowPlayingMatchedLayoutElement: ViewModifier {
    let element: NowPlayingLayoutElement
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if element == .songHeading {
            content.matchedGeometryEffect(id: element, in: namespace, properties: .position, anchor: .topLeading)
        } else {
            content.matchedGeometryEffect(id: element, in: namespace)
        }
    }
}

/// 常规宽度 iPhone 画布(Duo 内屏)上播放页的两种排法,见 `NowPlayingView.playerArrangement`。
enum NowPlayingArrangement: Equatable {
    /// 摊平:`canSplit` 为真(横握)时左右分栏,否则只有播放器一栏。
    case split(canSplit: Bool)
    /// 桌面半折:折痕的上下沿(播放页自己的坐标)。
    case tabletop(foldMinY: CGFloat, foldMaxY: CGFloat)
}
