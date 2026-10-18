import AVKit
import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
import MediaPlayer
#elseif os(macOS)
import AppKit
#endif

struct NowPlayingAppearance {
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

    /// 浅色外观「氛围强度」拉满时想要的浓度;实际还要过 `NowPlayingLightAmbientPolicy` 的深色字下限。
    var vividLightAmbientLevels: NowPlayingLightAmbientLevels {
        usesIncreasedContrast
            ? NowPlayingLightAmbientLevels(
                primaryOpacity: 0.66,
                secondaryOpacity: 0.48,
                overlayTopOpacity: 0.20,
                overlayBottomOpacity: 0.08
            )
            : NowPlayingLightAmbientLevels(
                primaryOpacity: 0.84,
                secondaryOpacity: 0.62,
                overlayTopOpacity: 0.06,
                overlayBottomOpacity: 0
            )
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

/// 「更多」摆进有声书、播客那几格时的写法,和旁边的文字稿、目录键一样。
private struct NowPlayingMoreMenuPlainLabel: Equatable {
    let font: Font
    let tint: Color
    let height: CGFloat
    /// 挪进有声书、播客最下面那一排时画成那一排的一块(图标加「更多」两个字)。
    var tile: NowPlayingMoreMenuTileStyle? = nil
}

/// 「更多」作为最下面那一排的一块时的样子,跟同一排别的块一样(`SpokenWordTileFace`)。
private struct NowPlayingMoreMenuTileStyle: Equatable {
    let layout: SpokenWordActionTiles.Layout
    let tileHeight: CGFloat
    let labelStyle: SpokenWordTileLabelStyle
    let secondary: Color
    let tileFill: Color
}

/// 播放页浮动圆钮的玻璃底样式。
private enum NowPlayingChromeGlass: Equatable {
    /// 固定深色玻璃，用于背景固定为深色的效果画面。
    case immersive
    /// 跟随明暗外观。普通模式的背景是取色渐变，浅色外观下底也得是浅的 ——
    /// 深色圆底会把同样是深色的图标吃掉。
    case adaptive
    /// iPhone Duo 竖栏那一列里：只有图标，玻璃底由整组的胶囊给。
    case barColumn(itemSize: CGFloat)
}

/// 原生全屏底部播放条的玻璃底:浮在内容上时垫一块,不浮时原样。
private struct NowPlayingDockPlate: ViewModifier {
    let isFloating: Bool
    let strokeTint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFloating {
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(strokeTint, lineWidth: 0.5)
                }
        } else {
            content
        }
    }
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

/// 播放页背景:封面取色的色场(或流动色彩)、声音律动、明暗两种遮罩,以及铺在最上面的背景图
/// (封面模糊 / 专辑封底 / 自选图片)。播放页和设置里「播放页样式与按钮」那张预览共用,
/// 预览里看到的就是播放页的背景。
struct NowPlayingAmbientBackdrop: View {
    private enum AmbientBackdropTuning {
        static let transitionDuration = 0.5
    }

    let song: Song?
    let isPlaying: Bool
    /// 播放页是正在看的那一面:色场与律动的动画时钟、背景图轮播只在这时走。
    let isSurfaceVisible: Bool
    let isSceneActive: Bool
    /// 入场动画结束前不开始读盘解码背景图。
    let allowsImageLoading: Bool
    /// 拖动整页、收进迷你条途中先停下动画。在这一层里读，开始拖、开始收起时只重算背景。
    var motion: NowPlayingSurfaceMotion? = nil

    @Environment(ThemeService.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(AppThemePreferences.ambientStrengthKey)
    private var ambientStrength = AppThemePreferences.defaultAmbientStrength

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        let isSurfaceVisible = isSurfaceVisible && !(motion?.isHeld ?? false)
        let hasArtworkTheme = theme.hasArtworkAmbient
        let strength = AppThemePreferences.normalizedAmbientStrength(ambientStrength)
        let backdropSource = PlayerBackdropSettingsStore.shared.effectiveSource
        let usesLiquid = backdropSource == .liquid
        var accentOpacity = (hasArtworkTheme
            ? appearance.artworkAccentOpacity
            : appearance.fallbackAccentOpacity) * strength
        var lowerAccentOpacity = (hasArtworkTheme
            ? appearance.artworkLowerAccentOpacity
            : appearance.fallbackLowerAccentOpacity) * strength
        var lightOverlay = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: hasArtworkTheme,
            usesIncreasedContrast: colorSchemeContrast == .increased,
            strength: strength
        )
        // 浅色外观把氛围强度调过默认值:背景往封面颜色上靠,封面色太深时停在深色字还看得清的地方(#69)。
        if appearance.isLight, hasArtworkTheme, !usesLiquid,
           strength > AppThemePreferences.defaultAmbientStrength {
            let defaultStrength = AppThemePreferences.defaultAmbientStrength
            let defaultOverlay = AmbientLightOverlayPolicy.resolve(
                hasArtworkTheme: true,
                usesIncreasedContrast: colorSchemeContrast == .increased,
                strength: defaultStrength
            )
            let levels = NowPlayingLightAmbientPolicy.levels(
                atDefault: NowPlayingLightAmbientLevels(
                    primaryOpacity: appearance.artworkAccentOpacity * defaultStrength,
                    secondaryOpacity: appearance.artworkLowerAccentOpacity * defaultStrength,
                    overlayTopOpacity: defaultOverlay.topOpacity,
                    overlayBottomOpacity: defaultOverlay.bottomOpacity
                ),
                vivid: appearance.vividLightAmbientLevels,
                strength: strength,
                defaultStrength: defaultStrength,
                primaryLuma: theme.artworkAccentLuma,
                secondaryLuma: theme.artworkSecondaryLuma,
                usesIncreasedContrast: colorSchemeContrast == .increased
            )
            accentOpacity = levels.primaryOpacity
            lowerAccentOpacity = levels.secondaryOpacity
            lightOverlay = AmbientLightOverlay(
                topOpacity: levels.overlayTopOpacity,
                bottomOpacity: levels.overlayBottomOpacity
            )
        }
        let darkOverlay = NowPlayingAmbientLegibilityPolicy.darkOverlay(
            paletteLuminance: theme.artworkLuminance,
            primaryOpacity: accentOpacity,
            secondaryOpacity: lowerAccentOpacity,
            usesIncreasedContrast: colorSchemeContrast == .increased
        )

        return ZStack {
            if usesLiquid {
                // 设置里选了「流动色彩」:换成几团跟着封面颜色缓缓流动的光(#189)。上面两层遮罩照旧。
                LiquidArtworkBackdrop(
                    palette: theme.liquidPalette,
                    isLight: appearance.isLight,
                    strength: strength,
                    isVisible: isSurfaceVisible,
                    isSceneActive: isSceneActive,
                    isPlaying: isPlaying
                )
            } else {
                AdaptiveNowPlayingBackdrop(
                    baseColor: appearance.backgroundBase,
                    primaryAccent: theme.accentColor,
                    secondaryAccent: theme.secondaryAccent,
                    darkAccent: theme.darkAccent,
                    primaryOpacity: accentOpacity,
                    secondaryOpacity: lowerAccentOpacity,
                    hasArtworkPalette: hasArtworkTheme,
                    // 背景图铺满时色场被盖住，停掉它的动画时钟。
                    isVisible: isSurfaceVisible && !PlayerBackdropResolver.shared.isShowingImage,
                    isSceneActive: isSceneActive,
                    isPlaying: isPlaying,
                    paletteVibrancy: theme.artworkVibrancy,
                    paletteLuminance: theme.artworkLuminance
                )
            }

            if backdropSource == .visualizer {
                // 设置里选了「声音律动」:色场上再画一层跟着声音动的频谱、波形或星尘(#312)。
                // 压在下面两层遮罩底下,字的对比度照旧由遮罩保证。
                PlayerVisualizerBackdrop(
                    style: PlayerBackdropSettingsStore.shared.settings.visualizerStyle,
                    primary: theme.accentColor,
                    secondary: theme.secondaryAccent,
                    deep: theme.darkAccent,
                    isLight: appearance.isLight,
                    strength: strength,
                    isVisible: isSurfaceVisible,
                    isSceneActive: isSceneActive
                )
            }

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

            // 设置里选了封面模糊 / 专辑封底 / 自选图片时铺在色场上面。
            PlayerBackdropImageHost(
                song: song,
                isLight: appearance.isLight,
                strength: strength,
                usesIncreasedContrast: colorSchemeContrast == .increased,
                isSurfaceVisible: isSurfaceVisible && isSceneActive,
                allowsLoading: allowsImageLoading
            )
        }
        .animation(
            .easeInOut(duration: AmbientBackdropTuning.transitionDuration),
            value: theme.colorID
        )
        .allowsHitTesting(false)
    }
}

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

/// 大封面与歌词小封面之间交接时所在的位置。
private enum LyricsArtworkPlacement: Hashable {
    case cover
    case compactLyrics
    case immersiveLyrics
}

private struct LyricsArtworkShadow {
    var opacity: Double = 0
    var radius: CGFloat = 0
    var y: CGFloat = 0
}

private struct LyricsArtworkAnchor {
    let bounds: Anchor<CGRect>
    let cornerRadius: CGFloat
    let shadow: LyricsArtworkShadow
    let showsVideoPreparation: Bool
    /// 下沿渐隐进背景的那一截占高度的比例；0 是不渐隐（卡片封面、歌词小封面）。
    var bottomFade: CGFloat = 0
    /// 铺满封面从屏幕顶端画起，把手和状态栏压在封面上，这一层要替它们垫一道淡淡的底色。
    var coversTopChrome = false
}

private struct LyricsArtworkAnchorKey: PreferenceKey {
    static let defaultValue: [LyricsArtworkPlacement: LyricsArtworkAnchor] = [:]

    static func reduce(
        value: inout [LyricsArtworkPlacement: LyricsArtworkAnchor],
        nextValue: () -> [LyricsArtworkPlacement: LyricsArtworkAnchor]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 常驻封面在大封面位与歌词小封面位之间移动。
///
/// 位置、边长、圆角、阴影是同一份动画数据，每一帧一起插值；圆角裁在缩放之前，
/// 外框和图片是同一层，不会出现外框先缩、图片后追上的情况。布局尺寸固定为绘制尺寸，
/// 移动途中只变换不重新排版。
///
/// 槽位不是正方形时（铺满封面在矮屏上被压扁）按长边铺满、居中裁掉多出来的那截，
/// 下沿渐隐也在同一层里随位置一起插值，飞向歌词小封面途中渐隐慢慢收掉。
private struct LyricsArtworkFlight: ViewModifier, Animatable {
    var rect: CGRect
    var cornerRadius: CGFloat
    var shadow: LyricsArtworkShadow
    var bottomFade: CGFloat
    let renderSize: CGFloat

    nonisolated var animatableData: AnimatablePair<
        AnimatablePair<CGRect.AnimatableData, AnimatablePair<CGFloat, CGFloat>>,
        AnimatablePair<Double, AnimatablePair<CGFloat, CGFloat>>
    > {
        get {
            AnimatablePair(
                AnimatablePair(rect.animatableData, AnimatablePair(cornerRadius, bottomFade)),
                AnimatablePair(shadow.opacity, AnimatablePair(shadow.radius, shadow.y))
            )
        }
        set {
            rect.animatableData = newValue.first.first
            cornerRadius = newValue.first.second.first
            bottomFade = newValue.first.second.second
            shadow.opacity = newValue.second.first
            shadow.radius = newValue.second.second.first
            shadow.y = newValue.second.second.second
        }
    }

    func body(content: Content) -> some View {
        let scale = max(rect.width, rect.height, 1) / renderSize
        let visible = CGSize(width: max(rect.width, 0) / scale, height: max(rect.height, 0) / scale)
        let fade = min(max(bottomFade, 0), 1)
        // 不渐隐时整张都是实色：只改色值不改结构，飞行途中渐隐收到 0 时这一层不会被重建。
        let fades = fade > 0.001
        content
            .frame(width: renderSize, height: renderSize)
            .clipShape(LyricsArtworkClipShape(size: visible, cornerRadius: max(0, cornerRadius) / scale))
            .mask {
                // 渐隐那一截按 smoothstep 取五个点，起止两头都是平的，看不出从哪一行开始变淡。
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 1 - fade),
                        .init(color: .black.opacity(fades ? 0.844 : 1), location: 1 - fade * 0.75),
                        .init(color: .black.opacity(fades ? 0.5 : 1), location: 1 - fade * 0.5),
                        .init(color: .black.opacity(fades ? 0.156 : 1), location: 1 - fade * 0.25),
                        .init(color: fades ? .clear : .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: visible.width, height: visible.height)
            }
            .scaleEffect(scale)
            .shadow(color: .black.opacity(max(0, shadow.opacity)), radius: max(0, shadow.radius), y: shadow.y)
            .position(x: rect.midX, y: rect.midY)
    }
}

/// 绘制尺寸那张方图里居中留下 `size` 那么大的圆角矩形。
private struct LyricsArtworkClipShape: Shape {
    var size: CGSize
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = min(size.width, rect.width)
        let height = min(size.height, rect.height)
        let visible = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
        let radius = min(cornerRadius, width / 2, height / 2)
        return Path(roundedRect: visible, cornerRadius: max(radius, 0), style: .continuous)
    }
}

/// 顶栏文字和按钮淡入淡出，书封面保留独立的透明度交接。
/// 音乐封面由布局外的常驻视图绘制，不参与顶栏的淡化。
private struct LyricsHeaderTransition: Transition {
    var receivesArtworkFromCover: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let artworkVisible = phase.isIdentity || (phase == .willAppear && receivesArtworkFromCover)
        content
            .environment(\.lyricsHeaderContentOpacity, phase.isIdentity ? 1 : 0)
            .environment(\.lyricsHeaderArtworkOpacity, artworkVisible ? 1 : 0)
    }
}

private struct LyricsHeaderContentOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

private struct LyricsHeaderArtworkOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

private extension EnvironmentValues {
    var lyricsHeaderContentOpacity: Double {
        get { self[LyricsHeaderContentOpacityKey.self] }
        set { self[LyricsHeaderContentOpacityKey.self] = newValue }
    }

    var lyricsHeaderArtworkOpacity: Double {
        get { self[LyricsHeaderArtworkOpacityKey.self] }
        set { self[LyricsHeaderArtworkOpacityKey.self] = newValue }
    }
}

/// 顶栏里的一块按 `LyricsHeaderTransition` 给的透明度显示。
private struct LyricsHeaderRevealModifier: ViewModifier {
    let isArtwork: Bool
    @Environment(\.lyricsHeaderContentOpacity) private var contentOpacity
    @Environment(\.lyricsHeaderArtworkOpacity) private var artworkOpacity

    func body(content: Content) -> some View {
        content.opacity(isArtwork ? artworkOpacity : contentOpacity)
    }
}

private extension View {
    func lyricsHeaderReveal(isArtwork: Bool = false) -> some View {
        modifier(LyricsHeaderRevealModifier(isArtwork: isArtwork))
    }
}

/// 把一段视图的构造推迟到这一层自己的 `body` 里，由 SwiftUI 单独求值。
///
/// Debug（-Onone）构建不复用栈槽：一个构造视图的闭包里，每个分支、每个中间值都各占一块栈，
/// 没走到的分支也照样预留。播放页 `body` 的 GeometryReader 闭包原先在两层 ZStack 闭包里
/// 现场构造全部布局，这几帧都要为「所有布局拼成的条件类型」留好几份，再叠上
/// 竖屏布局 → 歌名栏 → 「更多」菜单这一串，iPhone 主线程 1MB 的栈会被吃满，
/// 打开播放页就撞上栈保护页崩溃。包进这一层后，外层闭包只持有一个闭包大小的值，
/// 布局本身等到这一层更新时才构造，那时外层那几帧已经返回。
///
/// 这一层不带泛型参数、内容擦成 AnyView：带着布局类型时，播放页 `body` 的静态类型
/// 是「所有布局拼成的条件类型」，第一次展开播放页 SwiftUI 就要把横屏骨架、平板分栏、
/// 电台、MV 等每一套布局的类型元数据都实例化一遍（采样里首次展开那一卡的大头），
/// 而竖屏 iPhone 只会用到其中一套。擦掉之后只有真正走到的那一支才实例化。
private struct NowPlayingDeferredContent: View {
    private let content: () -> AnyView

    init<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        self.content = { AnyView(content()) }
    }

    var body: AnyView {
        content()
    }
}

/// 有声内容的这一条带不带有时间的文字(字幕、转写稿),记在播放页外面,也存进本机偏好。
/// 播放页每次展开都是新挂载的,文字稿又要等入场动画结束才读;不记的话传输键两头的文字稿 / 目录键
/// 每次都是页面停稳以后才弹出来(#283)。这一条没记过时按同一本书上次的结论猜(一本书的文件一般
/// 要么都有、要么都没有);播客单集不跨集猜。只是显示上的预判,读出结论后以结论为准。
@MainActor
private enum SpokenWordTextPresenceMemo {
    nonisolated private static let storageKey = "primuse.player.spokenWordTextPresence.v1"
    private static let songLimit = 160
    private static let bookLimit = 80
    private static var bySong: [String: Bool] = stored("songs")
    private static var byBook: [String: Bool] = stored("books")

    static func record(_ hasText: Bool, for song: Song) {
        var changed = store(hasText, key: song.id, in: &bySong, limit: songLimit)
        if let key = bookKey(for: song) {
            changed = store(hasText, key: key, in: &byBook, limit: bookLimit) || changed
        }
        guard changed else { return }
        UserDefaults.standard.set(["songs": bySong, "books": byBook], forKey: storageKey)
    }

    static func predictedHasText(for song: Song) -> Bool {
        if let known = bySong[song.id] { return known }
        guard let key = bookKey(for: song) else { return false }
        return byBook[key] ?? false
    }

    private static func store(_ value: Bool, key: String, in map: inout [String: Bool], limit: Int) -> Bool {
        guard map[key] != value else { return false }
        if map[key] == nil, map.count >= limit {
            // 满了随手丢掉一半;只是预判,丢了的那些下次读出结论再记。
            for stale in Array(map.keys.prefix(limit / 2)) { map[stale] = nil }
        }
        map[key] = value
        return true
    }

    nonisolated private static func stored(_ field: String) -> [String: Bool] {
        let saved = UserDefaults.standard.dictionary(forKey: storageKey)
        return saved?[field] as? [String: Bool] ?? [:]
    }

    private static func bookKey(for song: Song) -> String? {
        guard !PodcastPlaybackSong.isEpisode(song) else { return nil }
        let album = song.albumID ?? song.albumTitle ?? ""
        guard !album.isEmpty else { return nil }
        return "\(song.sourceID)|\(album)"
    }
}

struct NowPlayingView: View {
    var onOpenAlbum: ((Album) -> Void)? = nil
    var onOpenArtist: ((Artist) -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    var onTopMinimizeDragChanged: ((CGFloat) -> Void)? = nil
    var onTopMinimizeDragEnded: ((Bool) -> Void)? = nil
    var onLeadingMinimizeDragChanged: ((CGFloat) -> Void)? = nil
    var onLeadingMinimizeDragEnded: ((Bool) -> Void)? = nil
    /// The overlay mounts off-screen first. Expensive, nonessential work stays
    /// suspended until its entrance animation has actually completed.
    /// 封面取色不在此列：ThemeService 早已算好，推迟它只会让播放页先以灰底滑上来、停稳后再变色。
    var isPresentationSettled = true
    var isPresentationActive = true
    /// 外壳（PlayerOverlay）开始收起时在这里记一笔；没有外壳时用自己那份。
    var surfaceMotionFromHost: NowPlayingSurfaceMotion? = nil
    @State private var showChapterList = false
    /// 正在给哪一集 / 哪一章打开「生成文字稿」(#314)。
    @State private var transcriptGenerationSong: Song?
    /// 目录面板(sheet 或右栏)该翻到哪一页;播客的「接下来」块与队列键用它。
    @State private var contentsRequestedTab: SpokenWordContentsView.Tab?
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
    @AppStorage(PlayerAppearancePreferences.showsArtworkLyricsKey)
    private var showsArtworkLyrics = PlayerAppearancePreferences.showsArtworkLyricsByDefault
    /// 封面下的歌词几行;字号只在 `NowPlayingArtworkLyricPreview` 里读。
    @AppStorage(PlayerAppearancePreferences.artworkLyricsLinesKey)
    private var artworkLyricsLinesRawValue = NowPlayingArtworkLyricsLines.one.rawValue
    @AppStorage(PlayerAppearancePreferences.artworkStyleKey)
    private var artworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.podcastArtworkStyleKey)
    private var podcastArtworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.radioArtworkStyleKey)
    private var radioArtworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.audioInfoModeKey)
    private var audioInfoModeRawValue = PlayerAppearancePreferences.audioInfoModeByDefault.rawValue
    @AppStorage(PlayerAppearancePreferences.playButtonStyleKey)
    private var playButtonStyleRawValue = NowPlayingPlayButtonStyle.filledCircle.rawValue
    @AppStorage(PlayerAppearancePreferences.skipButtonStyleKey)
    private var skipButtonStyleRawValue = NowPlayingSkipButtonStyle.standard.rawValue

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
    /// 播客单集不在曲库里,「转到这本书」对它是空页, 换成这一集的详情。
    @State private var presentedPodcastSheet: PodcastPlayerSheetTarget?
    #endif
    @State private var showLyrics = false
    /// 有声内容的文稿全屏读(`SpokenWordTranscriptReader`)。
    @State private var showsTranscriptReader = false
    /// 按住文字稿键打开了全屏文稿:松手时按钮自己的点按也会到,那一下不再切换文字稿。
    /// 文稿关掉时清掉,点按没到(触摸被弹出的全屏打断)也不会吃掉下一次正常的点按。
    @State private var transcriptKeyHeld = false
    /// 下拉收起手势的起点、方向与最近一次动静的时刻，见 `returnToArtworkFromLyricsHeader()`。
    /// 普通引用：拖动时每一帧都写，不能引起重绘。
    @State private var minimizeDragActivity = NowPlayingMinimizeDragActivity()
    @State private var ownSurfaceMotion = NowPlayingSurfaceMotion()
    @State private var isLyricsImmersive = false
    /// 竖屏歌词里拖动歌词后收起了底部控件（歌词铺满，顶上的小封面与歌名还在）。
    /// 与全屏歌词互斥：那一套会重建歌词视图，拖到一半切过去会打断滚动。
    @State private var isLyricsChromeCollapsed = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// 上一轮已经落定的封面位置。换位置的那一次更新里它还是旧值，
    /// 进场的那一张封面据此判断是不是从另一张手里接过来的。
    @State private var settledLyricsArtworkPlacement: LyricsArtworkPlacement = .cover
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
    /// 手机横屏自己的「锁」。竖屏沉浸歌词那套 `immersiveControlsState` 带自动
    /// 隐藏计时，语义不同，不能共用。离开这个布局时会自动解锁，免得用户在别的
    /// 布局里找不到解锁入口。
    @State private var isCompactLandscapeLocked = false
    /// 手机横屏右栏窄到放不下两端的随机 / 循环时置真，让「更多」菜单补上入口。
    /// 由布局函数在 `onChange` 里写入，`body` 里不做这类赋值。
    @State private var compactLandscapeHidesModeToggles = false
    /// 音乐播放页上几个位置放哪些按钮、底部状态行显示哪几项(设置 › 播放器 › 播放页按钮)。
    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var controlLayoutStorage = ""
    /// 播放页控件跟主题色还是单色(设置 › 播放器 › 控件颜色)。
    @AppStorage(PlayerAppearancePreferences.controlTintKey)
    private var controlTintRawValue = NowPlayingControlTint.theme.rawValue
    /// 有声书与播客播放页各自的那排功能块、喜欢 / 文字稿键与章节键。
    @AppStorage(SpokenWordControlLayout.storageKey(for: .audiobook)) private var audiobookControlStorage = ""
    @AppStorage(SpokenWordControlLayout.storageKey(for: .podcast)) private var podcastControlStorage = ""
    @AppStorage(NowPlayingLyricsPageControls.storageKey) private var lyricsPageControlStorage = ""
    @AppStorage(NowPlayingImmersiveLyricsControls.storageKey) private var immersiveLyricsControlStorage = ""
    @AppStorage(NowPlayingEffectPlayerControls.storageKey) private var effectPlayerControlStorage = ""
    @AppStorage(NowPlayingRadioControlLayout.storageKey) private var radioControlStorage = ""
    @AppStorage(NowPlayingTextScrollPreference.collapsesKey(for: .audiobook))
    private var audiobookTextCollapses = NowPlayingTextScrollPreference.collapsesByDefault
    @AppStorage(NowPlayingTextScrollPreference.collapsesKey(for: .podcast))
    private var podcastTextCollapses = NowPlayingTextScrollPreference.collapsesByDefault
    /// 页面上那颗按钮此刻用不了时点出来的说明。
    @State private var controlNotice: NowPlayingControlNotice?
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    /// 歌词面板、全屏舞台、海报和机翻用的那份：关掉「显示歌词自带的译文」时去掉文件带的
    /// 译文。`lyrics` 仍是原文档，缓存比对照旧拿它。
    @State private var presentedLyrics: [LyricLine] = []
    /// 原文档里有没有能隐藏的自带译文;没有时「更多 › 歌词翻译」里不给那个开关。
    @State private var lyricsHaveBundledTranslations = false
    /// `lyrics` 是哪一首的读取结果。播放页刚挂载、还没读过时是 nil。
    @State private var lyricsSongID: String?
    /// 当前歌词各行的译文（文件自带的优先，其次是翻译任务给出的）。翻译任务挂在
    /// 播放页常驻的零尺寸视图上，这份结果同时供歌词面板、全屏舞台和歌词海报读取。
    @State private var lyricTranslationsByLineID: [String: String] = [:]
    @State private var lyricsTranslationActivity: LyricsTranslationActivity = .idle
    /// 自动生成的罗马音与双语 LRC 里的读音行；罗马音任务和翻译任务挂在同一处。
    @State private var lyricRomanizationOverlay: LyricRomanizationOverlay = .empty
    /// 歌词面板与全屏舞台显示的那份：按罗马音设置换过正文或附属罗马音。翻译任务、点歌词跳转、
    /// 歌词海报、编辑器仍用 `presentedLyrics`。跟着 `presentedLyrics` 一起更新（见
    /// `refreshRomanizedLyrics`），传下去的数组只在内容真的变了时才换。
    @State private var romanizedPresentedLyrics: [LyricLine] = []
    @State private var romanizedLyricsWritingDirection: LyricWritingDirection = .natural
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
    /// 「更多」› 播放时间段 打开的编辑面板；打开时冻结目标，自然切歌后仍改这一首。
    @State private var playbackRangeEditorSong: Song?
    @State private var showSleepTimer = false
    /// 音乐的上一首 / 下一首按住不放时快退 / 快进的预览位置。
    @State private var transportHoldScrub = TransportHoldScrub()
    /// 「更多」› 均衡器 › 调整均衡器… 打开的完整均衡器页。
    @State private var showEqualizer = false
    /// 高保真直通时点了均衡器,说明为什么不生效。
    @State private var showEqualizerBypassNotice = false
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
        presentedAlbum != nil || presentedBook != nil || presentedPodcastSheet != nil
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
            || playbackRangeEditorSong != nil
            || showTagEditor
            || lyricsEditorTargetSong != nil
            || lyricPosterComposer != nil
            || showSimilarSongs
            || showCastPicker
            || showMusicVideoFullScreen
            || isAlbumPresentationActive
            || showSleepTimer
            || showEqualizer
            || showEqualizerBypassNotice
            || controlNotice != nil
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
    }

    /// 拖动整页、收进迷你条途中要停的动画只在各自那一层读它（背景、歌词顶上的大封面）：
    /// 原先拖动状态放在这一页的 `@State` 里、参与上面的判断，手指一动、一松手整页版面
    /// 都要重建一遍，正好落在下拉的第一帧上（#322）。
    private var surfaceMotion: NowPlayingSurfaceMotion {
        surfaceMotionFromHost ?? ownSurfaceMotion
    }

    private var initialLyricsLoadIdentity: String {
        "\(player.currentSong?.id ?? "")|settled:\(isPresentationSettled)"
    }

    /// Keep startup buffering and playback-state changes from starting a second
    /// artwork spring while the full-player entrance spring is still running.
    private var artworkAppearsPlaying: Bool {
        !isPresentationSettled || player.isPlaying || player.isLoading
    }

    /// `body` 的修饰链已经很长, 再往里塞多语句闭包 iOS 就类型检查超时;
    /// 下面两个回调写成方法, 链上只剩一个引用。
    private func configureHandoffActivity(_ activity: NSUserActivity) {
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

    /// 歌词来源页换了文件、后台核对换掉了缓存: 正在放的这首直接换上, 不等下次打开播放页。
    private func lyricsDidChange(_ note: Notification) {
        guard let songID = note.object as? String,
              songID == player.currentSong?.id,
              !player.isLiveRadio else { return }
        Task { await showChangedLyrics(songID: songID) }
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
    /// 译文字号;「更多」里改了在绑定里同步 iCloud(播放页那条修饰链不能再加 onChange)。
    @AppStorage(CloudKVSKey.lyricsTranslationFontScale) private var lyricsTranslationFontScale: Double = 0
    @AppStorage(LyricPosterPreferences.styleKey) private var lyricPosterStyleRawValue = ""
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
    @AppStorage(PlayerAppearancePreferences.entersFullscreenInLandscapeKey)
    private var entersFullscreenInLandscape = PlayerAppearancePreferences.entersFullscreenInLandscapeByDefault
    /// 这次全屏是转横屏带进去的：转回竖屏时只退出这一种，自己点进去的全屏不动。
    @State private var enteredFullscreenForLandscape = false
    @AppStorage(PlayerAppearancePreferences.immersiveShowsArtworkKey)
    private var immersiveShowsArtwork = PlayerAppearancePreferences.immersiveShowsArtworkByDefault
    /// 转横屏进全屏前歌词页开没开着；原生全屏歌词退出后照原样恢复。
    @State private var lyricsVisibleBeforeLandscapeFullscreen = false

    private var fullscreenPlayerEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: fullscreenPlayerEffectRawValue) ?? .defaultValue
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
    /// "喜欢"是 heart 按钮 toggle 这个固定 system 歌单。播客单集记在播客自己的喜欢里。
    private var isCurrentLiked: Bool {
        guard let song = player.currentSong else { return false }
        if PodcastPlaybackSong.isEpisode(song) { return PodcastStore.shared.isLiked(episodeID: song.id) }
        return library.isLiked(songID: song.id)
    }

    /// 当前歌是否被标了「不喜欢」(#193) ── 只在「更多」菜单里出现, 不占播放器上的按钮位。
    private var isCurrentDisliked: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.isDisliked(songID: songID)
    }

    /// 心形键给不给。有声书的每个文件也是曲库里的一首,和锁屏上的「喜欢」一样能加进「我喜欢」;
    /// 播客单集不在曲库里,喜欢的记在播客自己那份(「我喜欢」页底下和播客页列出来)。
    private var offersLikeAction: Bool { true }

    /// 已喜欢时心形的颜色:有声书那两套设计用它自己的强调色,其余是红色。
    private var likedHeartTint: Color {
        usesAudiobookPlayerDesign ? themedControlAccent : .red
    }

    /// 正在播的歌在曲库里对应的艺人(见 `MusicLibrary.linkedArtists(for:)`)。
    private var currentArtists: [Artist] {
        guard let song = player.currentSong else { return [] }
        return library.linkedArtists(for: song)
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
        // 曲库里一首都没有的 Apple Music 专辑按目录现拼一张(见 AppleMusicCatalogAlbumIdentity)。
        return library.linkedAlbum(for: song)
            ?? AppServices.shared.appleMusicLibrary.catalogAlbum(forCatalogOnlySong: song)
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
        // 不回弹：封面缩到小封面位、放回大封面位都是一次到位（#167）。
        let animation: Animation = reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(response: 0.46, dampingFraction: 1, blendDuration: 0.08)
        #if DEBUG
        if let speed = Self.debugLyricsAnimationSpeed { return animation.speed(speed) }
        #endif
        return animation
    }

    #if DEBUG
    /// `PRIMUSE_DEBUG_LYRICS_ANIMATION_SPEED=0.125`：封面 ⇄ 歌词转场放慢，逐帧截图看封面怎么走。
    private static let debugLyricsAnimationSpeed: Double? = ProcessInfo.processInfo
        .environment["PRIMUSE_DEBUG_LYRICS_ANIMATION_SPEED"]
        .flatMap(Double.init)
        .flatMap { $0 > 0 ? $0 : nil }
    #endif

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

    /// 布局内容的进出场；常驻音乐封面独立于这层透明度变化。
    private var playerArtworkTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity
    }

    private var lyricsArtworkPlacement: LyricsArtworkPlacement {
        guard showLyrics else { return .cover }
        return isLyricsImmersive ? .immersiveLyrics : .compactLyrics
    }

    /// 有歌词小封面的构图里, 顶栏的进出场。
    private var lyricsHeaderHandoffTransition: LyricsHeaderTransition {
        LyricsHeaderTransition(receivesArtworkFromCover: settledLyricsArtworkPlacement == .cover)
    }

    /// 仍使用匹配几何的书封面，由接手视图保持不透明。
    private var lyricsHandoffArtworkTransition: AnyTransition {
        guard settledLyricsArtworkPlacement == .compactLyrics else { return playerArtworkTransition }
        return .asymmetric(insertion: .identity, removal: playerArtworkTransition)
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
        .playerPresentationColorScheme()

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
        if PodcastPlaybackSong.isEpisode(player.currentSong) {
            #if os(iOS)
            if let episodeID = currentPodcastEpisodeID {
                presentedPodcastSheet = .episode(episodeID)
            }
            #endif
            return
        }
        guard let bookID = player.currentBookID else { return }
        #if os(iOS)
        presentedBook = NowPlayingBookRoute(id: bookID)
        #elseif os(macOS)
        NotificationCenter.default.post(name: .primuseDetailOpenSpokenWordBook, object: bookID)
        #endif
    }

    private var currentPodcastEpisodeID: String? {
        SpokenWordPlayerText.openablePodcastEpisodeID(player)
    }

    /// 播客标题块里的节目名:在播放页上弹出节目页(不收起播放页)。
    private var openCurrentPodcastShow: (() -> Void)? {
        #if os(iOS)
        guard SpokenWordPlayerText.isPodcastEpisode(player) else { return nil }
        return {
            if let showID = SpokenWordPlayerText.podcastShowID(player) {
                presentedPodcastSheet = .show(showID)
            }
        }
        #else
        return nil
        #endif
    }

    /// 打开目录面板(播客是节目说明),`tab` 给了就翻到那一页。分栏时打开右栏。
    private func openContentsPanel(tab: SpokenWordContentsView.Tab? = nil) {
        contentsRequestedTab = tab
        if isPlayerSplit {
            selectSidePane(showsQueue: true)
        } else {
            showChapterList = true
        }
    }

    /// iPad 横屏目录常驻右栏:目录键把右栏翻回目录那一页(播客没有章节时是节目说明)。
    private func flipResidentContents() {
        contentsRequestedTab = SpokenWordPlayerText.isPodcastEpisode(player) && !player.hasChapters
            ? .notes
            : .contents
    }

    private var currentPodcastShareURL: URL? {
        SpokenWordPlayerText.podcastShareURL(player)
    }

    private func toggleLikedCurrent() {
        guard let song = player.currentSong else { return }
        PMHaptics.likeToggled(isLiked: !isCurrentLiked)
        if PodcastPlaybackSong.isEpisode(song) {
            player.toggleLikeForCurrentPodcastEpisode()
            return
        }
        library.toggleLiked(songID: song.id)
    }

    private func presentImmersiveLyrics() {
        if fullscreenPlayerEffect == .native {
            withAnimation(.easeInOut(duration: 0.3)) {
                showLyrics = true
                isLyricsChromeCollapsed = false
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
                isLyricsChromeCollapsed = false
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

    /// 手机转横屏时进入全屏、转回竖屏时退出(#191)。只认竖 → 横这一次旋转本身：横屏里退出
    /// 全屏后普通播放页会重新装上，若在它出现时判断，就会又被拉回全屏。
    private func handleLandscapeFullscreenRotation(
        from oldMode: NowPlayingPlayerLayoutMode,
        to newMode: NowPlayingPlayerLayoutMode
    ) {
        guard isPhoneCanvas else { return }
        if oldMode == .portrait, newMode == .compactLandscape {
            guard entersFullscreenInLandscape,
                  !isFullscreenPlayerPresented, !isLyricsImmersive,
                  player.currentSong != nil,
                  !player.isMusicVideoPlaybackActive, !player.isLiveRadio, !usesSpokenWordTransport,
                  isPresentationSettled, isPresentationActive, !surfaceMotion.isDismissing,
                  !hasBlockingNowPlayingPresentation
            else { return }
            lyricsVisibleBeforeLandscapeFullscreen = showLyrics
            presentImmersiveLyrics()
            enteredFullscreenForLandscape = true
        } else if newMode == .portrait, enteredFullscreenForLandscape {
            enteredFullscreenForLandscape = false
            if isFullscreenPlayerPresented {
                dismissFullscreenPlayer()
            } else if isLyricsImmersive {
                dismissImmersiveLyrics()
                if !lyricsVisibleBeforeLandscapeFullscreen { setStandardLyricsVisible(false) }
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
    private func presentLyricPoster(anchorLineID: String?) {
        guard let song = player.currentSong else { return }
        let composer = LyricPosterComposer.make(
            song: song,
            lyrics: presentedLyrics,
            translations: lyricTranslationsByLineID,
            playbackPosition: player.currentTime,
            anchorLineID: anchorLineID,
            writingDirection: lyricsWritingDirection,
            styleID: lyricPosterStyleRawValue.isEmpty
                ? nil
                : LyricPosterStyleID(lyricPosterStyleRawValue),
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
            isLyricsChromeCollapsed = false
            immersiveControlsState = immersiveControlsState.applying(.dismiss)
        }
    }

    private func toggleStandardLyrics() {
        setStandardLyricsVisible(!showLyrics)
    }

    /// 歌词顶上那一行(小封面与歌名)是回封面的按钮，又正好在下拉收起的起手区里。整页跟着
    /// 手指走，松手时触点还在按钮上，按钮照样触发：收起或弹回的同时封面又放大回来。
    /// 拖过就不算点。按钮和拖动谁先收到松手不确定，所以拖动的每一下和松手都记时间；
    /// 拖着停住再松手时按钮可能先到，那时拖动还没结束，也挡。
    private func returnToArtworkFromLyricsHeader() {
        let sinceDrag = Date().timeIntervalSince(minimizeDragActivity.lastEventAt)
        let isDragging = minimizeDragActivity.startLocation != nil && sinceDrag < 3
        guard sinceDrag > 0.35, !isDragging else { return }
        setStandardLyricsVisible(false)
    }

    /// 竖屏歌词里往上翻歌词就收起底部控件、让歌词铺满（参照 Apple Music）。顶上的小封面
    /// 与歌名留着，点它直接回封面；点歌词空白先叫回控件，控件在时再点才回封面。
    /// VoiceOver 下不收：控件没了就摸不到。
    private func collapseLyricsChrome() {
        guard showLyrics,
              !isLyricsImmersive,
              !isLyricsChromeCollapsed,
              textCollapsesOnScroll,
              !voiceOverEnabled,
              !lyrics.isEmpty else { return }
        withAnimation(lyricsChromeAnimation) {
            isLyricsChromeCollapsed = true
        }
    }

    private func restoreLyricsChrome() {
        guard isLyricsChromeCollapsed else { return }
        withAnimation(lyricsChromeAnimation) {
            isLyricsChromeCollapsed = false
        }
    }

    private var lyricsChromeAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.16) : .smooth(duration: 0.35, extraBounce: 0)
    }

    /// 点大封面切到歌词。有声内容同样切到文字稿那一页,有没有文字稿都一样:没有时那一页写明没有、
    /// 能生成就给生成,生成中显示进度(`SpokenTranscriptEmptyState`)。
    private func openTextFromArtwork() {
        if usesSpokenWordTransport, isPlayerSplit {
            showSpokenWordTextPane()
            return
        }
        setStandardLyricsVisible(true)
    }

    /// 分栏时有声内容的右栏固定是目录 / 书签 / 文字:打开右栏并翻到文字那一页;
    /// 别把 showLyrics 置真,那会让大封面不再充当匹配几何的源。
    private func showSpokenWordTextPane() {
        contentsRequestedTab = .text
        selectSidePane(showsQueue: true)
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
        // 与旁边的隔空播放键同一种写法:只有图标,不垫圆底也不描边。选中态由图标本身
        // (实心符号、红心)表达。
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
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

    /// iOS 上播放页整层铺满、忽略安全区，版面按窗口的安全区排，不读 `geo.safeAreaInsets`：
    /// 它按这一层在窗口里的位置换算，停稳时是 0；展开、收起、下拉时整页在变形、平移，它跟着
    /// 出一串过渡值（回弹时左右还漏出零点几），读了它版面闭包就每一帧都重跑，整套版面连同
    /// 「更多」菜单重建一遍（#322）。
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
            top: windowInsets.top,
            leading: logicalLeading,
            bottom: windowInsets.bottom,
            trailing: logicalTrailing
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

    /// 竖屏封面的边长:两边各留 22,高度不超过整屏的 42%(#192:封面大一些,和下面几行一起往上提)。
    /// 矮屏上放不下时由版面再压缩。
    static func portraitArtworkSize(in size: CGSize) -> CGFloat {
        max(0, min(size.width - 44, size.height * 0.42))
    }

    /// 竖屏音量行的高度(`SystemVolumeSlider.compactHeight`),关掉音量条时按它把空出来的高度分出去。
    static let portraitVolumeRowHeight: CGFloat = 24

    /// 封面下歌词的字号:`.callout`(跟着系统字体大小)乘上设置里的倍数。
    static func artworkLyricFontSize(base: CGFloat, scale: Double) -> CGFloat {
        base * CGFloat(PlayerAppearancePreferences.artworkLyricsFontScale(scale))
    }

    /// 封面下歌词每一行的高度,字号的 1.5 倍(默认 16 号字、24 高)。
    static func artworkLyricLineHeight(fontSize: CGFloat) -> CGFloat {
        max(1, (fontSize * 1.5).rounded())
    }

    /// 封面下的歌词选了「自动」时最多排几行。
    static let artworkLyricMaximumRows = 8

    /// 封面下的歌词与上面歌名那几行之间至少空多少。
    static let artworkLyricHeadingGap: CGFloat = 14

    /// 「自动」时这块高度能排下几行,至少一行。
    static func artworkLyricRowCount(fitting height: CGFloat, lineHeight: CGFloat) -> Int {
        guard lineHeight > 0 else { return 1 }
        return min(max(1, (height / lineHeight).rounded(.down).finiteInt(or: 1)), artworkLyricMaximumRows)
    }

    /// 竖屏播放键、音量与底排之间多拉开的距离:屏幕越高拉得越开,矮屏(700 以下)照旧。
    /// 封面与歌词两种模式用同一个值,切换时这几行不挪位置。
    static func portraitControlGap(forHeight height: CGFloat) -> CGFloat {
        min(max(0, height - 700) * 0.12, 30)
    }

    /// 高画布上歌名(或下面那两句歌词)与进度条之间至少留的空白;进度条自己另有 8 的上边距。
    static let portraitTallCanvasHeadingGap: CGFloat = 40

    /// 竖版用「封面吃掉剩余高度」的排法:iPad 与 Duo 内屏这类不是窄手机的画布,并且高到控件间距已拉满。
    /// 这时 42% 屏高的封面会在歌名与进度条之间空出几百点(#303)。iPhone 竖屏(含 Pro Max)不走这条。
    private func portraitArtworkFillsTallCanvas(height: CGFloat) -> Bool {
        (sizeClass == .regular || !isPhoneCanvas) && height >= 950
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
                artworkSize: Self.portraitArtworkSize(in: geo.size),
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
        let preferred = Self.portraitArtworkSize(in: geo.size)
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
        // 只看贴着屏幕上沿的遮挡区:在下半屏的(外屏横握摄像头在右下角的方向)不该把内容往下推。
        let lowest = OcclusionAvoidancePolicy.topEdge(of: occlusions, height: height)
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
                // 有声内容的右栏自带「目录 / 书签 / 文字」切换。
                if !usesSpokenWordTransport {
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
                }

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
                if usesSpokenWordTransport {
                    spokenWordContentsPane
                        .pmAppearFade(.contentAppear)
                } else if !showLyrics {
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
            isLyricsChromeCollapsed = false
        }
    }

    private func closeSidePane() {
        withAnimation(standardLyricsAnimation) {
            sidePaneHidden = true
            // 收起后整屏排开的是封面那一副;下次从歌词键或接下来播放键打开时再选右栏看哪一页。
            showLyrics = false
            isLyricsImmersive = false
            isLyricsChromeCollapsed = false
        }
    }

    /// 队列键:分栏时打开右栏的「接下来播放」(已经在看就收起右栏),其它时候弹出半屏队列。
    private func openQueue() {
        // 播客的「队列」就是后面排着的单集:直接翻到「接下来」。
        let podcastUpNext: SpokenWordContentsView.Tab? = usesSpokenWordTransport
            && SpokenWordPlayerText.isPodcastEpisode(player) ? .upNext : nil
        guard isPlayerSplit else {
            // 有声内容的「队列」就是这本书的目录。
            if usesSpokenWordTransport {
                contentsRequestedTab = podcastUpNext
                showChapterList = true
            } else {
                showQueue = true
            }
            return
        }
        if !sidePaneHidden, !showLyrics, podcastUpNext == nil {
            closeSidePane()
        } else {
            contentsRequestedTab = podcastUpNext
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
    /// 在尾侧摆一块(框里读到的是外屏自己的遮挡区,位置对不上);`PRIMUSE_EVIDENCE_OCCLUSION=bottom`
    /// 时摆在尾侧底部(外屏横握摄像头在右下角的那个方向)。
    private func playerOcclusions(in geo: GeometryProxy) -> [OcclusionAvoidancePolicy.Region] {
        guard centersOnFullScreen else { return [] }
        #if DEBUG && os(iOS)
        if debugSuppressesVerticalBar {
            let width = Double(geo.size.width)
            if ProcessInfo.processInfo.environment["PRIMUSE_EVIDENCE_OCCLUSION"] == "bottom" {
                let height = Double(geo.size.height)
                return [
                    .init(x: width - 84, y: height - 82, width: 84, height: 82),
                    .init(x: width - 60.5, y: height - 61, width: 37, height: 37),
                ]
            }
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
    /// 和系统竖栏同一套玻璃胶囊分组,对准前置摄像头的中线。按系统报告的遮挡区(竖排状态栏 + 摄像头)实际
    /// 在哪排:遮挡区在竖栏顶上时从它下面往下排,在底下(外屏横握摄像头在右下角的那个方向)时到它上面为止、
    /// 贴着它往上排,任何一颗都不落进遮挡区或屏幕外。播放器这边只留封面、歌名、进度与传输键。
    /// 高度不够时每颗按钮一起缩一点(44 → 34);还放不下就把锁、全屏效果、喜欢依次收进「更多」。
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
        let segment = OcclusionAvoidancePolicy.columnSegment(
            regions: barRegions,
            bandMinX: band.lowerBound,
            bandMaxX: band.upperBound,
            height: Double(geo.size.height),
            topInset: Double(topSafeArea),
            bottomInset: Double(bottomSafeArea),
            margin: 12
        )
        let music = !usesSpokenWordTransport
        // 有声内容没有文字稿(或在「播放页按钮」里关了文字稿键)时不给文字键,这一组只剩目录。
        let showsTextToggle = spokenWordHasText && spokenWordControlLayout.showsTranscriptToggle
        // 中间一组:音乐按「播放页按钮」底栏的配置(去掉 AirPlay,默认歌词与队列);有声内容是文字稿与目录。
        let columnGroups = musicControlLayout.toolColumnGroups()
        let middleCount = music ? columnGroups.middle.count : (showsTextToggle ? 2 : 1)
        // 下面一组里歌名旁那一格:音乐按配置(默认心形),有声内容跟「喜欢」开关。
        let headerAction: NowPlayingControlAction? = music
            ? columnGroups.header
            : (offersLikeAction && spokenWordControlLayout.showsLike ? .like : nil)
        // 放不下时依次收进「更多」的:锁、全屏效果、歌名旁那一格。
        let droppable = (offersLock ? 1 : 0) + (music ? 1 : 0) + (headerAction != nil ? 1 : 0)
        let spacing = 12.0
        let capsulePadding = 4.0
        let fit = OcclusionAvoidancePolicy.columnFit(
            length: segment.length,
            groups: [1]
                + (middleCount > 0 ? [middleCount] : [])
                + [(music ? 1 : 0) + (headerAction != nil ? 1 : 0) + 2 + (offersLock ? 1 : 0)],
            droppable: droppable,
            spacing: spacing,
            capsulePadding: capsulePadding
        )
        let itemSize = CGFloat(fit.itemSize)
        var overflow = NowPlayingBarColumnOverflow()
        var remaining = fit.overflowCount
        var headerOverflows = false
        if offersLock, remaining > 0 { overflow.lock = true; remaining -= 1 }
        if music, remaining > 0 { overflow.effect = true; remaining -= 1 }
        if headerAction != nil, remaining > 0 { headerOverflows = true; remaining -= 1 }
        // 有声内容的心形收进「更多」走原来那一项;音乐的由「播放页按钮」的兜底补上。
        overflow.like = headerOverflows && !music
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

                if music {
                    if !columnGroups.middle.isEmpty {
                        barColumnGroup {
                            ForEach(columnGroups.middle, id: \.self) { action in
                                controlButton(action, style: .column(itemSize))
                            }
                        }
                    }
                } else {
                    barColumnGroup {
                        if showsTextToggle {
                            barColumnLyricsButton(symbol: "text.bubble", itemSize: itemSize)
                        }
                        barColumnQueueButton(itemSize: itemSize)
                    }
                }

                barColumnGroup {
                    if let headerAction, !headerOverflows {
                        controlButton(headerAction, style: .column(itemSize))
                    }

                    AirPlayButton()
                        .frame(width: itemSize * 0.62, height: itemSize * 0.62)
                        .frame(width: itemSize, height: itemSize)

                    if music, !overflow.effect {
                        immersiveEffectButton(glass: .barColumn(itemSize: itemSize))
                    }

                    if offersLock, !overflow.lock {
                        Button {
                            immersiveControlsAutoHideTask?.cancel()
                            isCompactLandscapeLocked = true
                        } label: {
                            NowPlayingBarColumnIcon(symbol: "lock", appearance: appearance, size: itemSize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("immersive_lock_controls"))
                    }

                    makeMoreMenu(
                        immersiveChrome: true,
                        chromeGlass: .barColumn(itemSize: itemSize),
                        columnOverflow: overflow,
                        controlSurface: .toolColumn(
                            showsTransportEdges: !compactLandscapeHidesModeToggles,
                            headerOverflows: headerOverflows
                        )
                    )
                }
            }
        }
        .frame(height: CGFloat(segment.length), alignment: segment.alignsToBottom ? .bottom : .top)
        .frame(width: itemSize + CGFloat(capsulePadding) * 2 + 8)
        .position(x: CGFloat(centerX), y: CGFloat(segment.minY + segment.length / 2))
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
        // 下半屏的控件一直在,歌词(文字稿)在上半屏。
        let spokenControls = usesSpokenWordTransport
            ? spokenWordControlLayout.resolved(in: SpokenWordControlContext(
                hasTranscript: hasSpokenWordTranscript,
                hasInnerChapterPair: true
            ))
            : nil
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
                        artworkOrMusicVideo(
                            size: artworkSide,
                            cornerRadius: 16,
                            playbackScale: artworkAppearsPlaying ? 1.0 : 0.92,
                            shadow: .init(opacity: 0.3, radius: 24, y: 10)
                        )
                            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: artworkAppearsPlaying)
                            .onTapGesture { openTextFromArtwork() }
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
                PlaybackProgressBar(fillTint: themedControlAccent) { progressAudioTags(showsSource: false) }
                    .matchedLayoutElement(.progress, in: layoutNamespace)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)
                portraitTransportRow(spokenControls: spokenControls)
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
                portraitBottomBar(spokenControls: spokenControls)
                .padding(.top, showsQueueStrip ? 6 : 0)
                .pmLayoutSwitchFade()
                nowPlayingStatusBand(
                    height: max(bottomSafeArea, Self.statusBandMinimumHeight),
                    horizontalPadding: 36
                )
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
                let activity = minimizeDragActivity
                activity.lastEventAt = Date()
                let isRTL = layoutDirection == .rightToLeft
                if activity.startLocation != value.startLocation {
                    activity.startLocation = value.startLocation
                    activity.axis = nil
                    if !surfaceMotion.isDragging { surfaceMotion.isDragging = true }
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
                let axis = activity.axis
                    ?? NowPlayingDismissGesturePolicy.recognizedAxis(
                        startY: Double(value.startLocation.y),
                        startDistanceFromLeadingEdge: startDistance,
                        translationTowardCenter: towardCenter,
                        translationY: Double(value.translation.height),
                        verticalStartMaximumY: Double(verticalStartMaximumY)
                    )
                guard let axis else { return }
                activity.axis = axis

                switch axis {
                case .horizontal:
                    onLeadingMinimizeDragChanged?(CGFloat(max(0, towardCenter)))
                case .vertical:
                    onTopMinimizeDragChanged?(max(0, value.translation.height))
                }
            }
            .onEnded { value in
                let activity = minimizeDragActivity
                let axis = activity.axis
                activity.axis = nil
                activity.startLocation = nil
                activity.lastEventAt = Date()
                if surfaceMotion.isDragging { surfaceMotion.isDragging = false }
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
            // 顶部圆钮排保持同一个视图身份；歌词模式下封面与控件在左、歌词在右。
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

                // 转横屏自动进全屏(#191，默认关)。挂在常驻的零尺寸视图上：进了全屏普通播放页会被
                // 卸载，转回竖屏这件事也得有人接着看。
                Color.clear
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onChange(of: playerLayoutMode) { oldMode, newMode in
                        handleLandscapeFullscreenRotation(from: oldMode, to: newMode)
                    }
                    .onChange(of: isFullscreenPlayerPresented) { _, isPresented in
                        if !isPresented, !isLyricsImmersive { enteredFullscreenForLandscape = false }
                    }
                    .onChange(of: isLyricsImmersive) { _, isImmersive in
                        if !isImmersive, !isFullscreenPlayerPresented { enteredFullscreenForLandscape = false }
                    }
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
                            songContext: .init(title: player.currentSong?.title, artist: player.currentSong?.artistName),
                            lyricsRevision: lyricsRevision,
                            lyrics: presentedLyrics,
                            settings: LyricsTranslationSettingsStore.shared,
                            player: player,
                            translatedTextByLineID: $lyricTranslationsByLineID,
                            activity: $lyricsTranslationActivity
                        )
                }

                // 罗马音同理;另外选了「只显示罗马音」时封面模式那一行歌词也要换成罗马音,
                // 所以封面模式也挂着(本机生成很快,结果有缓存)。
                if showLyrics || isFullscreenPlayerPresented
                    || LyricsRomanizationSettingsStore.shared.displayMode == .romanizationOnly {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .lyricsRomanizationTask(
                            songID: player.currentSong?.id,
                            songContext: .init(title: player.currentSong?.title, artist: player.currentSong?.artistName),
                            lyricsRevision: lyricsRevision,
                            lyrics: presentedLyrics,
                            overlay: $lyricRomanizationOverlay
                        )
                }

                if !isFullscreenPlayerPresented {
                    ZStack {
                        // Opaque base — prevents content bleeding through
                        // 两层底色在换构图那一次立刻铺满新尺寸，不随换构图的动画慢慢长大(换歌时的取色过渡照旧)。
                        if usesAudiobookPlayerDesign && !audiobookUsesPlayerBackdrop {
                            // 有声书是两套设计里的纯色底(墨黑 / 暖白),不随封面取色,也不铺背景图;
                            // 设置里打开「有声书也使用」时,深色的墨黑改铺播放页背景(#283)。
                            audiobookPlayerStyle.background.ignoresSafeArea()
                                .animation(nil, value: canvasKey)
                                .transition(.opacity)
                        } else {
                            appearance.backgroundBase.ignoresSafeArea()
                                .animation(nil, value: canvasKey)
                            // Dynamic background from cover colors — fully opaque
                            backgroundGradient.ignoresSafeArea()
                                .animation(nil, value: canvasKey)
                        }

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
                    .overlayPreferenceValue(LyricsArtworkAnchorKey.self) { anchors in
                        lyricsArtworkOverlay(anchors: anchors)
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
                        lyrics: romanizedPresentedLyrics,
                        lyricCompanions: {
                            LyricsScrollView.companionTexts(
                                for: $0,
                                translatedTextByLineID: lyricTranslationsByLineID
                            )
                        },
                        lyricsWritingDirection: romanizedLyricsWritingDirection,
                        isResolvingLyrics: isResolvingLyrics,
                        isSceneActive: isVisualSceneActive,
                        onDismiss: dismissFullscreenPlayer,
                        onMinimize: minimizeFullscreenPlayer,
                        onShowQueue: { showQueue = true },
                        occlusions: occlusions,
                        onShowAlbum: {
                            guard let album = currentAlbum else { return }
                            presentAlbum(album, prefersMatchedArtworkSource: false)
                        },
                        chromeControls: NowPlayingControlLayoutCache.effectPlayerControls(for: effectPlayerControlStorage),
                        chromeControl: { action, placement, ink in
                            AnyView(controlButton(
                                action,
                                style: placement == .top ? .effectGlass(ink: ink) : .effectPill(ink: ink)
                            ))
                        }
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
        // 进度条从这里读按住快退 / 快进的预览位置；只有进度条观察它，按住期间整页不跟着重画。
        .environment(transportHoldScrub)
        .onAppear { FullscreenPlayerEffectSync.shared.install() }
        #if DEBUG && os(iOS)
        .task {
            // 取证页让播放页一出现就处在歌词 / 全屏歌词模式。真机上无人值守截图用
            // `PRIMUSE_DEBUG_PLAYER_MODE`(同样的取值,另有 `queueSheet`:弹出半屏的接下来播放;
            // `fullscreen`:进全屏播放; `lyricsToggle`:每 4 秒走一次真实的封面 ⇄ 歌词切换,录屏看转场)。
            switch debugPlayerMode ?? ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PLAYER_MODE"] {
            case "lyrics":
                showLyrics = true
            case "artworkTap", "artworkTapGenerate", "artworkTapSimulate":
                // 和手指点大封面走同一条路:有声内容没有文字稿时进文字稿那一页。`artworkTapGenerate`
                // 接着用本机识别给这一集生成文字稿,`artworkTapSimulate` 只把生成的几个阶段走一遍,
                // 看那一页上的进度与结果。
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                openTextFromArtwork()
                let mode = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PLAYER_MODE"]
                if let song = player.currentSong {
                    if mode == "artworkTapGenerate" {
                        SpokenTranscriptGenerator.shared.start(song: song, engine: .onDevice, localeIdentifier: "en-US")
                    } else if mode == "artworkTapSimulate" {
                        SpokenTranscriptGenerator.shared.debugSimulateProgress(song: song)
                    }
                }
            case "lyricsToggle":
                let environment = ProcessInfo.processInfo.environment
                let configuredInterval = Double(environment["PRIMUSE_DEBUG_LYRICS_TOGGLE_INTERVAL"] ?? "") ?? 4
                let interval = configuredInterval.isFinite ? max(0.05, configuredInterval) : 4
                let limit = Int(environment["PRIMUSE_DEBUG_LYRICS_TOGGLE_COUNT"] ?? "") ?? Int.max
                var count = 0
                while !Task.isCancelled, count < limit {
                    // 首次留出封面加载时间，短间隔用来验证尚未结束的动画反向切换。
                    try? await Task.sleep(for: .seconds(count == 0 ? max(4, interval) : interval))
                    guard !Task.isCancelled else { return }
                    toggleStandardLyrics()
                    count += 1
                }
            case "immersive":
                showLyrics = true
                isLyricsImmersive = true
                immersiveControlsState = .presented
            case "lyricsCollapsed":
                // 拖动歌词后收起底部控件的样子。
                showLyrics = true
                isLyricsChromeCollapsed = true
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
            case "contents":
                // 有声内容的目录与书签面板。
                try? await Task.sleep(for: .seconds(1))
                showChapterList = true
            case "podcastUpNext":
                // 播客的说明面板,直接翻到「接下来」。
                try? await Task.sleep(for: .seconds(1))
                openContentsPanel(tab: .upNext)
            case "podcastNotes":
                try? await Task.sleep(for: .seconds(1))
                openContentsPanel(tab: .notes)
            case "fullscreen":
                // 全屏播放(当前选的全屏效果;原生效果时是全屏歌词)。
                try? await Task.sleep(for: .seconds(1))
                presentImmersiveLyrics()
            case "transcriptReader":
                // 有声内容的全屏文稿(等文稿读进来);里面的菜单、设置、目录、搜索见 `PRIMUSE_DEBUG_TRANSCRIPT_READER`。
                try? await Task.sleep(for: .seconds(2))
                if !lyrics.isEmpty { showsTranscriptReader = true }
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
                minimizeDragActivity.axis = nil
                minimizeDragActivity.startLocation = nil
                if surfaceMotion.isDragging { surfaceMotion.isDragging = false }
            }
        }
        .onChange(of: showsImmersiveEffectPicker) { _, isPresented in
            if isPresented {
                immersiveControlsAutoHideTask?.cancel()
            } else if isLyricsImmersive, immersiveControlsState.isVisible {
                scheduleImmersiveControlsAutoHide()
            }
        }
        .onChange(of: fullscreenPlayerEffectRawValue) { _, rawValue in
            guard let effect = FullscreenPlayerEffect(rawValue: rawValue) else { return }
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
                presentBundledTranslationVisibility()
            } else {
                await loadLyrics()
            }
            consumeAutomaticScrapeCompletion()
        }
        // 换上新歌词,或问源结束(没问到也算结论):记下这一条有没有文字。
        .onChange(of: lyricsRevision) { _, _ in rememberSpokenWordTextPresence() }
        .onChange(of: LyricsTranslationSettingsStore.shared.showsBundledTranslations) { _, _ in
            presentBundledTranslationVisibility()
            lyricsRevision &+= 1
        }
        .onChange(of: lyricRomanizationOverlay) { _, _ in refreshRomanizedLyrics() }
        .onChange(of: LyricsRomanizationSettingsStore.shared.displayMode) { _, _ in refreshRomanizedLyrics() }
        .onChange(of: isResolvingLyrics) { _, _ in rememberSpokenWordTextPresence() }
        .onChange(of: scraperService.singleScrapeCompletionRevision) { _, _ in
            consumeAutomaticScrapeCompletion()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .primuseLyricsDidChange),
            perform: lyricsDidChange
        )
        // 这里弹出的页面都套 `playerPresentationColorScheme`:「播放页始终用深色」时弹出页整页一起深色。
        .sheet(isPresented: $showQueue) {
            QueueView(player: player)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .playerPresentationColorScheme()
        }
        .modifier(NowPlayingSpokenWordTextPresentations(
            showChapterList: $showChapterList,
            contentsRequestedTab: $contentsRequestedTab,
            showsTranscriptReader: $showsTranscriptReader,
            player: player,
            transcriptReaderLines: { transcriptReaderLines },
            transcriptTranslations: { lyricTranslationsByLineID },
            onTranscriptOffsetChange: refreshTranscriptOffset,
            transcriptGenerationSong: $transcriptGenerationSong,
            intelligence: intelligence
        ))
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
            .playerPresentationColorScheme()
        }
        .sheet(item: $presentedPodcastSheet) { target in
            NowPlayingPodcastSheet(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .playerPresentationColorScheme()
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
            .playerPresentationColorScheme()
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.currentSong {
                AddToPlaylistSheet(song: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .playerPresentationColorScheme()
            }
        }
        .sheet(item: $shareSong, onDismiss: { presentLyricPosterRequestedFromShare() }) { song in
            SongShareSheet(
                song: song,
                onShareLyricPoster: canShareLyricPoster(for: song)
                    ? { presentsLyricPosterAfterShare = true }
                    : nil
            )
            .playerPresentationColorScheme()
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = player.currentSong {
                SongInfoSheet(song: song)
                    .songInfoPresentationStyle()
                    .playerPresentationColorScheme()
            }
        }
        .sheet(item: $playbackRangeEditorSong) { song in
            SongPlaybackRangeEditor(song: song)
                .playerPresentationColorScheme()
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
                .playerPresentationColorScheme()
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
            .playerPresentationColorScheme()
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
                .playerPresentationColorScheme()
                #if os(macOS)
                .presentationDetents([.large])
                #endif
        }
        .similarSongsPanel(isPresented: $showSimilarSongs, seed: player.currentSong)
        .sheet(isPresented: $showCastPicker) {
            CastDevicePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .playerPresentationColorScheme()
        }
        #if os(iOS)
        .sheet(isPresented: $showEqualizer) {
            NavigationStack {
                EqualizerView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("done") { showEqualizer = false }
                        }
                    }
            }
            .environment(player.equalizerService)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .playerPresentationColorScheme()
        }
        .fullScreenCover(
            isPresented: $showMusicVideoFullScreen,
            onDismiss: finishMusicVideoFullScreenDismissal
        ) {
            if let videoPlayer = fullScreenMusicVideoPlayer ?? player.musicVideoPlayer {
                MusicVideoFullScreenView(player: videoPlayer) {
                    dismissMusicVideoFullScreen()
                }
                .playerPresentationColorScheme()
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
                .playerPresentationColorScheme()
        }
        .equalizerHighFidelityNotice(
            isPresented: $showEqualizerBypassNotice,
            playbackSettings: playbackSettings
        )
        // 发起处散在电台底栏、有声的「定时」块和各个版式的更多菜单里，挂在整页上会贴着页边弹，
        // 用居中的 alert。
        .alert(String(localized: "sleep_timer"), isPresented: $showSleepTimer) {
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
        .alert(
            controlNotice?.title ?? "",
            isPresented: Binding(
                get: { controlNotice != nil },
                set: { if !$0 { controlNotice = nil } }
            ),
            presenting: controlNotice
        ) { notice in
            if notice.offersEffectsOutput {
                Button(String(localized: "eq_use_effects_output")) {
                    playbackSettings.outputMode = .effects
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } else {
                Button(String(localized: "done"), role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
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
            if !isVisible { isLyricsChromeCollapsed = false }
        }
        .onChange(of: lyrics.isEmpty && !isResolvingLyrics) { _, hasNoLyrics in
            // 换到一首没有歌词的歌：空页面点空白不回应，控件得先回来。
            if hasNoLyrics { restoreLyricsChrome() }
        }
        .onChange(of: lyricsArtworkPlacement) { _, placement in
            settledLyricsArtworkPlacement = placement
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
            // 进场动画结束后再挂 Handoff：激活时要拼一份队列窗口与显示名，
            // 不必挤进首次展开那几帧。
            isActive: isPresentationSettled && player.currentSong != nil && !player.isLiveRadio,
            configureHandoffActivity
        )
    }

    @ViewBuilder
    private func liveRadioLayout(
        geo: GeometryProxy,
        safeInsets: EdgeInsets,
        occlusions: [OcclusionAvoidancePolicy.Region] = []
    ) -> some View {
        let preferredArtworkSize = min(geo.size.width * (geo.size.width > geo.size.height ? 0.30 : 0.80), 430)
        // 整屏居中(iPhone Duo)时台标在遮挡区那段高度里两边都不碰它;其它设备不设限。
        // 台标上面还垫着最多一半的空余高度,遮挡带按它可能落到的最低处算。
        let artworkSlack = max(0, geo.size.height - preferredArtworkSize) / 2
        // 播放键到底排的间距和音乐页同一把尺,高屏拉开一些,但不再把空余高度都堆在这里(#313)。
        let controlGap = Self.portraitControlGap(forHeight: geo.size.height)
        let showsVolumeRow = showsPlayerVolumeBar && radioControlLayout.showsVolumeBar
        let artworkSize = min(preferredArtworkSize, CGFloat(OcclusionAvoidancePolicy.centeredWidthLimit(
            regions: occlusions,
            bandMinY: Double(topSafeArea) + 11,
            bandMaxY: Double(topSafeArea + 11 + artworkSlack + preferredArtworkSize),
            width: Double(geo.size.width),
            gap: 16
        )))
        let fullBleedLogo = liveRadioUsesFullBleedLogo(in: geo.size)

        VStack(spacing: 0) {
            if fullBleedLogo {
                // 台标从屏幕顶端铺满整宽,最多画成正方形;下面几行照旧,空出来的高度留在台标与台名之间。
                liveRadioFullBleedLogo
                    .frame(maxHeight: geo.size.width)
                    .layoutPriority(1)
            } else {
                Capsule()
                    .fill(appearance.tertiary)
                    .frame(width: 48, height: 5)
                    .padding(.top, topSafeArea + 6)
            }

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

            if !fullBleedLogo {
                // 台名、播放键和底排像音乐页一样收在下面；空出来的高度一份垫在台标上面、
                // 一份留在台标与台名之间，不再在播放键和底排之间空出一大块(#313)。
                Spacer(minLength: 12)

                // 台标只吃文字和控件之外剩下的高度。只按宽度取值时，iPhone Duo 外屏、
                // 内屏分屏半幅这类宽而矮的窗口会把底部控件顶出屏幕。
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: artworkSize, maxHeight: artworkSize)
                    .overlay {
                        GeometryReader { artworkGeometry in
                            let fittedSize = min(artworkGeometry.size.width, artworkGeometry.size.height)
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
                    }
                    .layoutPriority(1)
            }

            Spacer(minLength: 22)

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
            // 台标先分高度，文字按自己的完整高度留位，不被挤成一行。
            .fixedSize(horizontal: false, vertical: true)

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
            .padding(.top, 20)

            if showsVolumeRow {
                playerVolumeRow
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 36)
                    .padding(.top, 14 + controlGap)
            }

            // 最下面那一排按「播放页按钮 › 电台」的顺序与显隐摆。每项占等宽的一格、
            // 在格里居中，几项都均匀铺开；码率那行字和睡眠倒计时比一格宽时按自己的宽度来。
            HStack(spacing: 0) {
                ForEach(radioBottomRowItems) { item in
                    radioControlItem(item)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.top, showsVolumeRow ? 14 : 14 + controlGap)
            .padding(.bottom, max(bottomSafeArea, 16))
        }
        // 侧边安全区按侧取值，内容不会压到侧置系统控件或摄像头区域下面。
        // 整屏居中(iPhone Duo)时两侧都是 0,只由台标让开遮挡区。
        .padding(.leading, centersOnFullScreen ? 0 : safeInsets.leading)
        .padding(.trailing, centersOnFullScreen ? 0 : safeInsets.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 铺满的台标：从屏幕顶端画到这一块的下沿，整宽、直角，下沿和音乐铺满封面一样渐隐进背景；
    /// 顶上垫一道背景色的淡底让状态栏看得清，下拉把手画在台标上面。
    private var liveRadioFullBleedLogo: some View {
        GeometryReader { region in
            let width = region.size.width
            let height = region.size.height
            ZStack(alignment: .top) {
                if let station = player.currentRadioStation, height >= 48 {
                    RadioStationArtworkContent(station: station, decodeSize: max(width, height))
                        .frame(width: width, height: height)
                        .clipped()
                        .mask { FullBleedArtworkFadeMask() }
                }

                LinearGradient(
                    colors: [appearance.backgroundBase.opacity(0.42), appearance.backgroundBase.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(height, topSafeArea + 44))

                Capsule()
                    .fill(appearance.primary.opacity(0.5))
                    .frame(width: 48, height: 5)
                    .padding(.top, topSafeArea + 6)
            }
            .frame(width: width, height: height, alignment: .top)
        }
        .accessibilityHidden(true)
    }

    /// 底排真画得出来的那几项：分享要有电台地址、听过的歌要有电台，缺了就不占一格。
    private var radioBottomRowItems: [NowPlayingRadioControlItem] {
        let station = player.currentRadioStation
        return radioControlLayout.visibleItems.filter { item in
            switch item {
            case .share: station?.url != nil
            case .history: station != nil
            case .airPlay, .info, .sleepTimer: true
            }
        }
    }

    @ViewBuilder
    private func radioControlItem(_ item: NowPlayingRadioControlItem) -> some View {
        switch item {
        case .airPlay:
            AirPlayButton()
                .frame(width: 36, height: 36)
        case .info:
            Text(radioTechnicalSummary)
                .font(.caption2)
                .foregroundStyle(appearance.faint)
        case .share:
            if let url = player.currentRadioStation?.url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(Text("share"))
            }
        case .history:
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
        case .sleepTimer:
            radioSleepTimerButton
        }
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
            if player.currentListeningSpace?.playbackFamily == .spokenWord {
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
                    lyricsPaneTopClearance: lyricsPaneTop,
                    usesToolColumn: usesToolColumn
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!isCompactLandscapeLocked)

            if !usesToolColumn {
                compactLandscapeChromeLayer
                    .pmLayoutSwitchFade()
                    .padding(.leading, chromeLeading)
                    .padding(.trailing, chromeTrailing)
            }
        }
        .padding(.leading, CGFloat(metrics.leadingInset))
        .padding(.trailing, CGFloat(metrics.trailingInset))
        .padding(.top, CGFloat(metrics.topInset))
        .padding(.bottom, CGFloat(metrics.bottomInset))
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

    /// 歌词栏在遮挡区下面才开始:只在它横向碰到从栏顶以上伸下来的遮挡区时把栏顶往下挪到遮挡区下沿
    /// (贴着屏幕下沿的遮挡区不算,那样栏顶会被推出屏幕)。
    private func compactLandscapeLyricsPaneTopClearance(
        occlusions: [OcclusionAvoidancePolicy.Region],
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics,
        lyricsMetrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics
    ) -> CGFloat {
        CGFloat(NowPlayingCompactLandscapeLayoutPolicy.lyricsPaneTopClearance(
            metrics: metrics,
            lyricsMetrics: lyricsMetrics,
            occlusions: occlusions,
            isRightToLeft: layoutDirection == .rightToLeft
        ))
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

    /// 锁上、或者效果抽屉开着的时候，播放页整体不再接最小化拖拽。
    private var suppressesPlayerMinimizeGesture: Bool {
        isCompactLandscapeLocked || showsImmersiveEffectPicker
    }

    private func compactLandscapeColumns(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics,
        lyricsMetrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics,
        lyricsPaneTopClearance: CGFloat = 0,
        usesToolColumn: Bool = false
    ) -> some View {
        let leftColumnWidth = CGFloat(
            showLyrics ? lyricsMetrics.detailColumnWidth : metrics.artworkColumnWidth
        )
        let rightColumnWidth = CGFloat(
            showLyrics ? lyricsMetrics.lyricsPaneWidth : metrics.detailColumnWidth
        )
        return HStack(alignment: .center, spacing: CGFloat(metrics.columnSpacing)) {
            // 每栏在自己的定宽槽位里换场，过渡期间旧、新内容同时存在也不会挤压另一栏。
            ZStack {
                if showLyrics {
                    compactLandscapeDetailColumn(
                        metrics: metrics,
                        lyricsMetrics: lyricsMetrics,
                        usesToolColumn: usesToolColumn
                    )
                        .transition(.opacity)
                } else {
                    compactLandscapeArtwork(metrics: metrics)
                        .transition(lyricsHandoffArtworkTransition)
                }
            }
            .frame(width: leftColumnWidth)
            .frame(maxHeight: .infinity)

            ZStack {
                if showLyrics {
                    compactLandscapeLyricsPane(metrics: lyricsMetrics)
                        .padding(.top, lyricsPaneTopClearance)
                        .pmLayoutSwitchFade()
                        .transition(lyricsPanelTransition)
                } else {
                    compactLandscapeDetailColumn(
                        metrics: metrics,
                        lyricsMetrics: lyricsMetrics,
                        usesToolColumn: usesToolColumn
                    )
                        .transition(.opacity)
                }
            }
            .frame(width: rightColumnWidth)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactLandscapeArtwork(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics
    ) -> some View {
        let artworkSize = CGFloat(metrics.artworkSize)
        return artworkOrMusicVideo(
            size: artworkSize,
            cornerRadius: 18,
            playbackScale: artworkAppearsPlaying ? 1 : 0.96,
            shadow: .init(opacity: 0.28, radius: 20, y: 10)
        )
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.75),
                value: artworkAppearsPlaying
            )
            .onTapGesture { openTextFromArtwork() }
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
        lyricsMetrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics,
        usesToolColumn: Bool
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
                        .transition(lyricsHeaderHandoffTransition)
                } else {
                    compactLandscapeCoverHeading(metrics: metrics)
                        .matchedLayoutElement(.songHeading, in: layoutNamespace)
                        .transition(.opacity)
                }
            }

            // 手机横屏底下没有状态行,来源仍挂在进度条下的标签里。
            PlaybackProgressBar(fillTint: themedControlAccent) { progressAudioTags(showsSource: true) }
                .matchedLayoutElement(.progress, in: layoutNamespace)
                .padding(.top, CGFloat(NowPlayingCompactLandscapeLayoutPolicy.progressTopSpacing))

            compactLandscapeTransportRow(
                showsEdgeToggles: showsEdgeToggles,
                // 竖栏那一列里排着文字稿与目录时(iPhone Duo)这一行按没有文字稿摆。
                spokenControls: usesSpokenWordTransport
                    ? spokenWordControlLayout.resolved(in: spokenWordCompactLandscapeControlContext(
                        showsSides: showsEdgeToggles,
                        usesToolColumn: usesToolColumn
                    ))
                    : nil
            )
                .matchedLayoutElement(.transport, in: layoutNamespace)
                .padding(.top, CGFloat(NowPlayingCompactLandscapeLayoutPolicy.transportTopSpacing))
                // 只有手动锁定才隐藏播放操作；保留占位，封面和歌词不会随之移动。
                .opacity(isCompactLandscapeLocked ? 0 : 1)
                .accessibilityHidden(isCompactLandscapeLocked)
                .pmAnimation(.control, value: isCompactLandscapeLocked)

            if showsVolumeBar {
                playerVolumeRow
                    .pmLayoutSwitchFade()
                    .padding(.top, CGFloat(NowPlayingCompactLandscapeLayoutPolicy.volumeTopSpacing))
                    .opacity(isCompactLandscapeLocked ? 0 : 1)
                    .accessibilityHidden(isCompactLandscapeLocked)
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
        if usesSpokenWordTransport {
            // 右栏按固定高度排版:书名一行,章名与「第几章」各一行。
            SpokenWordPlayerHeading(
                palette: spokenWordPalette,
                titleFont: .title,
                partFont: .body,
                titleLineLimit: 1,
                onOpenShow: openCurrentPodcastShow,
                onOpenBook: { presentCurrentBook() },
                onOpenContents: { openContentsPanel() }
            )
        } else {
            compactLandscapeMusicHeading(metrics: metrics)
        }
    }

    private func compactLandscapeMusicHeading(
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

    /// 歌词模式左栏的上半截：小封面 + 歌名 / 艺人，整块点一下回封面模式。
    /// 音乐缩略图只提供位置，常驻封面层负责缩放和位移。
    private func compactLandscapeLyricsHeader(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.LyricsMetrics
    ) -> some View {
        let thumbnail = CGFloat(metrics.thumbnailSize)
        return Button { returnToArtworkFromLyricsHeader() } label: {
            HStack(
                alignment: .center,
                spacing: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.lyricsHeaderSpacing)
            ) {
                lyricsThumbnailArtwork(size: thumbnail, cornerRadius: 12, shadow: .init(opacity: 0.22, radius: 10, y: 5))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
                .lyricsHeaderReveal(isArtwork: true)

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
                .lyricsHeaderReveal()
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

    /// 艺人 / 专辑沿用竖屏那套可点跳转的 Menu，横屏只是压成一行。音质与来源在进度条下的标签里。
    private var compactLandscapeArtistRow: some View {
        nowPlayingMetadataLinks(font: .title3, lineLimit: 1)
    }

    private func compactLandscapeLyricLine(
        metrics: NowPlayingCompactLandscapeLayoutPolicy.Metrics
    ) -> some View {
        NowPlayingLyricPreview(
            lyrics: lyricPreviewLines,
            player: player,
            songID: player.currentSong?.id,
            lyricsRevision: lyricsRevision,
            isSceneActive: isVisualSceneActive,
            tint: appearance.tertiary,
            statusTint: appearance.tertiary,
            lineHeight: CGFloat(metrics.lyricLineHeight),
            onTap: { setStandardLyricsVisible(true) }
        )
    }

    /// 封面模式那一行歌词用的那份:和歌词页一样按罗马音设置换过(「只显示罗马音」时正文是罗马音);
    /// 换好的那份还没出来时先用原来的。
    private var lyricPreviewLines: [LyricLine] {
        romanizedPresentedLyrics.isEmpty ? lyrics : romanizedPresentedLyrics
    }

    /// 竖屏封面模式进度条上面正在唱的那一句(或按设置的几行), 点一下进歌词页。
    /// `fillsHeight` 时行数按这一块分到的高度定(设置里选了「自动」)。
    private func artworkLyricPreview(fillsHeight: Bool) -> some View {
        NowPlayingArtworkLyricPreview(
            lyrics: lyricPreviewLines,
            player: player,
            songID: player.currentSong?.id,
            lyricsRevision: lyricsRevision,
            isSceneActive: isVisualSceneActive,
            appearance: appearance,
            lineCount: fillsHeight
                ? nil
                : PlayerAppearancePreferences.artworkLyricsLines(rawValue: artworkLyricsLinesRawValue).fixedCount ?? 1,
            onTap: { setStandardLyricsVisible(true) }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("a11y_open_lyrics"))
    }

    /// 两端放得下时:音乐是随机 / 循环;有声内容按「播放页按钮」两侧那两格摆,默认是上一章 / 下一章,
    /// 这一条有文字稿时换成文字稿与目录(右栏放不下四颗),上一章 / 下一章仍在快退、快进的长按菜单里,
    /// 和竖屏一样。
    @ViewBuilder
    private func compactLandscapeTransportRow(
        showsEdgeToggles: Bool,
        spokenControls: SpokenWordResolvedControls?
    ) -> some View {
        let sideKeyFont = Font.system(size: 17, weight: .semibold)
        let menuSurface = NowPlayingControlSurface.compactLandscape(showsTransportEdges: !compactLandscapeHidesModeToggles)
        HStack(spacing: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.transportSpacing)) {
            if showsEdgeToggles {
                if let spokenControls {
                    spokenWordSlotKey(
                        spokenControls.leadingSide,
                        slot: .leadingSide,
                        font: sideKeyFont,
                        tint: appearance.secondary,
                        selectedTint: themedControlAccent,
                        menuSurface: menuSurface
                    )
                    .pmFadeTransition(motion: .control)
                } else {
                    controlSlot(.leadingEdge, style: .edge)
                }
            }

            Spacer(minLength: 0)

            playerSkipButton(
                symbol: transportGlyphSymbol(forward: false),
                label: transportBackwardLabel
            ) {
                transportBackward()
            }
            .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: false) }
            .modifier(transportHoldScrubGesture(forward: false))

            playerPlayButton

            playerSkipButton(
                symbol: transportGlyphSymbol(forward: true),
                label: transportForwardLabel
            ) {
                transportForward()
            }
            .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: true) }
            .modifier(transportHoldScrubGesture(forward: true))

            Spacer(minLength: 0)

            if showsEdgeToggles {
                if let spokenControls {
                    spokenWordSlotKey(
                        spokenControls.trailingSide,
                        slot: .trailingSide,
                        font: sideKeyFont,
                        tint: appearance.secondary,
                        selectedTint: themedControlAccent,
                        menuSurface: menuSurface
                    )
                    .pmFadeTransition(motion: .control)
                } else {
                    controlSlot(.trailingEdge, style: .edge)
                }
            }
        }
        .frame(height: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.primaryTransportDiameter))
        .pmAnimation(.control, value: spokenControls?.leadingSide)
        .pmAnimation(.control, value: spokenControls?.trailingSide)
    }

    // MARK: - Transport: music vs spoken word

    /// 有声书、评书、相声用「后退 15 秒 / 前进 30 秒」代替切曲。一整本书就是
    /// 一个条目, 切到下一条目等于整本跳过; 真实需求是漏听一句往回倒。
    /// 电台那套控件在另一处单独实现, 不受影响。
    /// 「更多」里的「生成文字稿」:没有文字稿的有声内容给「生成」,生成过的给「重新生成」,
    /// 生成中写进度;自带文字稿(节目给的、源里的)不给(#314)。
    private var transcriptGenerationMenuItem: SpokenTranscriptGenerationMenuItem? {
        guard usesSpokenWordTransport,
              let song = player.currentSong,
              SpokenTranscriptGenerator.canGenerate(for: song) else { return nil }
        let generator = SpokenTranscriptGenerator.shared
        if let job = generator.activeJob, job.song.id == song.id {
            return SpokenTranscriptGenerationMenuItem(
                titleKey: "transcript_generation_menu_running",
                detail: SpokenTranscriptGenerationSheet.phaseText(job.phase)
            )
        }
        if generator.records[song.id] != nil, !lyrics.isEmpty {
            return SpokenTranscriptGenerationMenuItem(titleKey: "transcript_generation_regenerate", detail: nil)
        }
        guard lyrics.isEmpty, !isResolvingLyrics else { return nil }
        return SpokenTranscriptGenerationMenuItem(titleKey: "transcript_generation_action", detail: nil)
    }

    private var usesSpokenWordTransport: Bool {
        player.currentItemIsSpokenWord && !player.isLiveRadio
    }

    /// 给正在听的这一集生成文字稿时挂在播放页上的进度(竖屏、有声书版式和 iPad 在出错提示那一格,
    /// 手机横屏在顶上那排圆钮中间);不在生成时不占位置。点开是生成面板,做完点一下看文字稿。
    @ViewBuilder
    private var transcriptGenerationStatus: some View {
        if usesSpokenWordTransport {
            SpokenTranscriptGenerationStatusPill(
                songID: player.currentSong?.id,
                onOpenDetails: { transcriptGenerationSong = player.currentSong },
                onShowTranscript: { showGeneratedTranscript() }
            )
        }
    }

    /// 有声内容没有文字稿时文字稿那一页的内容;音乐为空。
    private var spokenTranscriptEmptyState: SpokenTranscriptEmptyState.Content? {
        guard usesSpokenWordTransport else { return nil }
        return SpokenTranscriptEmptyState.Content(
            song: player.currentSong,
            onOpenGeneration: { transcriptGenerationSong = player.currentSong },
            onShowNotes: SpokenWordPlayerText.isPodcastEpisode(player)
                ? { openContentsPanel(tab: .notes) }
                : nil
        )
    }

    /// 文字稿刚生成好:打开文字稿那一面(这时歌词可能还在读进来)。
    private func showGeneratedTranscript() {
        if isPlayerSplit {
            showSpokenWordTextPane()
        } else if !showLyrics {
            setStandardLyricsVisible(true)
        }
    }

    /// 有声内容总走效果链(`AudioPlayerService.outputMode(for:)`),语速随时可调;
    /// 音乐只有效果模式能变速。
    private var canChangeCurrentPlaybackRate: Bool {
        player.currentItemIsSpokenWord || playbackSettings.outputMode == .effects
    }

    private var playButtonStyle: NowPlayingPlayButtonStyle {
        PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue)
    }

    /// 上一首 / 下一首按「播放页样式与按钮」里选的画;有声内容那两颗是快退 / 快进,不跟着换。
    private var skipButtonStyle: NowPlayingSkipButtonStyle {
        usesSpokenWordTransport
            ? .standard
            : PlayerAppearancePreferences.skipButtonStyle(rawValue: skipButtonStyleRawValue)
    }

    private var transportBackwardSymbol: String {
        usesSpokenWordTransport ? player.spokenWordSkipBackwardSymbol : skipButtonStyle.symbol(forward: false)
    }

    private var transportForwardSymbol: String {
        usesSpokenWordTransport ? player.spokenWordSkipForwardSymbol : skipButtonStyle.symbol(forward: true)
    }

    /// 压在玻璃胶囊里的那两颗(手机横屏、浮起来的原生全屏底排):胶囊已经是框,不再套圆。
    private func transportGlyphSymbol(forward: Bool) -> String {
        if usesSpokenWordTransport {
            return forward ? player.spokenWordSkipForwardSymbol : player.spokenWordSkipBackwardSymbol
        }
        return skipButtonStyle.glyphSymbol(forward: forward)
    }

    /// 播放页传输键一行的播放 / 暂停键:加载中转圈,其余按样式画。`diameter` 是键的边长。
    private func transportPlayPauseFace(diameter: CGFloat) -> some View {
        ZStack {
            // Anchor sizing so the button doesn't reflow.
            Image(systemName: "play.circle.fill")
                .font(.system(size: diameter)).opacity(0)
            if player.showsLoadingIndicator {
                ProgressView()
                    .controlSize(.large)
                    .tint(appearance.primary)
                    .pmFadeTransition(motion: .control)
            } else {
                NowPlayingPlayPauseFace(
                    style: playButtonStyle,
                    showsPause: player.isPlaying || player.isLoading,
                    diameter: diameter,
                    tint: appearance.primary
                )
                // symbolEffect 管不到 ProgressView 这一跳, 用透明度接上。
                .pmFadeTransition(motion: .control)
            }
        }
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
        // 按住快退松手时，按钮自己的点按也会到这里，这一下不再切歌。
        guard !transportHoldScrub.consumesTap() else { return }
        if usesSpokenWordTransport {
            player.skipSpokenWordBackward()
        } else {
            Task { await player.previous() }
        }
    }

    private func transportForward() {
        guard !transportHoldScrub.consumesTap() else { return }
        if usesSpokenWordTransport {
            player.skipSpokenWordForward()
        } else {
            Task { await player.next() }
        }
    }

    /// 音乐的上一首 / 下一首按住不放是快退 / 快进(系统音乐的习惯);有声内容的这两颗键长按是跳章菜单,
    /// 电台没有进度可跳。
    private func transportHoldScrubGesture(forward: Bool) -> TransportHoldScrubGesture {
        TransportHoldScrubGesture(
            forward: forward,
            isEnabled: !usesSpokenWordTransport && !player.isLiveRadio && player.duration > 0,
            scrub: transportHoldScrub,
            player: player
        )
    }

    private func playerSkipButton(
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

    private var playerPlayButton: some View {
        let diameter = CGFloat(NowPlayingCompactLandscapeLayoutPolicy.primaryTransportDiameter)
        // 实心圆用前景色填充，图标反过来用背景底色，深浅两种外观下都是高对比。
        let glyphTint = appearance.backgroundBase
        let style = playButtonStyle
        return Button {
            guard !player.isLoading else { return }
            player.togglePlayPause()
        } label: {
            ZStack {
                if style == .filledCircle {
                    Circle()
                        .fill(appearance.primary)
                }

                if player.showsLoadingIndicator {
                    ProgressView()
                        .tint(style == .filledCircle ? glyphTint : appearance.primary)
                        .pmFadeTransition(motion: .control)
                } else if style == .filledCircle {
                    Image(systemName: player.isPlaying || player.isLoading ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(glyphTint)
                        .contentTransition(.symbolEffect(.replace))
                        // symbolEffect 管不到 ProgressView 这一跳, 用透明度接上。
                        .pmFadeTransition(motion: .control)
                } else {
                    // 其它样式和竖屏那一颗同一种画法,按这颗键的大小缩放。
                    NowPlayingPlayPauseFace(
                        style: style,
                        showsPause: player.isPlaying || player.isLoading,
                        diameter: diameter * 0.86,
                        tint: appearance.primary
                    )
                    .pmFadeTransition(motion: .control)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(player.showsLoadingIndicator)
        .accessibilityLabel(player.isPlaying || player.isLoading
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
    /// 音乐时左边一组是「播放页按钮」里底栏的那几颗(歌词在右栏、全屏有自己那颗键,不放),
    /// 右边心形那一格跟着歌名旁那一格走。
    private var compactLandscapeChromeRow: some View {
        let diameter = CGFloat(NowPlayingCompactLandscapeLayoutPolicy.chromeButtonDiameter)
        let chrome = musicControlLayout.compactLandscapeChrome()
        // 有声内容:传输键两侧已经摆着的键,这一排不再重复。
        let spokenControls = spokenWordControlLayout.resolved(in: spokenWordCompactLandscapeControlContext(
            showsSides: !compactLandscapeHidesModeToggles,
            usesToolColumn: false
        ))
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

            if usesSpokenWordTransport {
                // 书的这一颗就是目录,播客是「接下来」:传输键那一行两端摆着同一样时不再重复。
                let queueInTransport = spokenControls.placedActions.contains(
                    SpokenWordPlayerText.isPodcastEpisode(player) ? .upNext : .contents
                )
                if !queueInTransport {
                    NowPlayingGlassActionButton(
                        symbol: "list.bullet",
                        label: "a11y_queue",
                        appearance: appearance,
                        tint: appearance.primary,
                        diameter: diameter
                    ) {
                        openQueue()
                    }
                }

                compactLandscapeAirPlayButton

                // 文字稿那一页空着时进度就画在那一页上,这里不再重复。
                if !(showLyrics && lyrics.isEmpty) {
                    transcriptGenerationStatus
                }
            } else {
                ForEach(chrome.leading, id: \.self) { action in
                    controlButton(action, style: .glass)
                }
            }

            Spacer(minLength: 0)

            if usesSpokenWordTransport {
                // 横屏右栏放不下那排功能块;书签留在圆钮排里,语速与定时在更多菜单。
                if !spokenControls.placedActions.contains(.bookmark) {
                    NowPlayingGlassActionButton(
                        symbol: "bookmark",
                        label: "spoken_word_add_bookmark",
                        appearance: appearance,
                        tint: appearance.primary,
                        diameter: diameter
                    ) {
                        player.addSpokenWordBookmark()
                    }
                }
            } else {
                immersiveEffectButton(glass: .adaptive)
            }

            if usesSpokenWordTransport {
                if offersLikeAction, spokenControls.headerShowsLike {
                    NowPlayingGlassActionButton(
                        symbol: isCurrentLiked ? "heart.fill" : "heart",
                        label: isCurrentLiked ? "a11y_unlike" : "a11y_like",
                        appearance: appearance,
                        tint: isCurrentLiked ? likedHeartTint : appearance.primary,
                        diameter: diameter,
                        isSelected: isCurrentLiked
                    ) {
                        toggleLikedCurrent()
                    }
                    .disabled(player.currentSong == nil)
                }
            } else if let action = chrome.trailing {
                controlButton(action, style: .glass)
            }

            if !usesSpokenWordTransport || spokenControls.headerShowsMore {
                makeMoreMenu(
                    immersiveChrome: true,
                    chromeGlass: .adaptive,
                    controlSurface: .compactLandscape(showsTransportEdges: !compactLandscapeHidesModeToggles)
                )
            }

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
                // 同步竖屏全屏歌词的解锁状态；横屏控件不跟随它的自动隐藏计时。
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
                // lastPlaybackError 由服务层裸赋值, 调用点包不住动画事务,
                // 曲线只能附在过渡本身上(提示条里已经带了)。
                playbackErrorToast(error)
            }
            transcriptGenerationStatus

            GeometryReader { artworkGeometry in
                let ratio: CGFloat = player.isMusicVideoPlaybackActive ? 16.0 / 9.0 : 1
                let fittedWidth = min(artSize, max(1, artworkGeometry.size.height - 24) * ratio)
                artworkOrMusicVideo(
                    size: fittedWidth,
                    cornerRadius: 16,
                    playbackScale: artworkAppearsPlaying ? 1.0 : 0.92,
                    shadow: .init(opacity: 0.35, radius: 28, y: 12)
                )
                    .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: artworkAppearsPlaying)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            nowPlayingSongHeader(titleFont: .title2, metadataFont: .title3, controlSurface: .wideLandscape)
                .padding(.horizontal, 36)
                .padding(.top, 18)

            nowPlayingReviewSection
                .padding(.horizontal, 36)

            PlaybackProgressBar(fillTint: themedControlAccent) { progressAudioTags(showsSource: false) }
                .padding(.horizontal, 36).padding(.top, 10)

            // 有声内容两头再各一格,按「播放页按钮」摆。默认有文字稿时最左边文字稿(和竖屏同一件事,
            // 切到整幅的文字稿)、最右边目录 —— 目录常驻右栏,这一颗把右栏翻回目录那一页。
            let spokenControls = usesSpokenWordTransport
                ? spokenWordControlLayout.resolved(in: spokenWordWideLandscapeControlContext)
                : nil
            Group {
                if let spokenControls {
                    spokenWordTransportRow(spokenControls, playDiameter: 60, minimumGap: nil) { slot, action in
                        spokenWordSlotKey(
                            action,
                            slot: slot,
                            font: .body,
                            tint: appearance.secondary,
                            selectedTint: themedControlAccent,
                            menuSurface: .wideLandscape,
                            onContents: { flipResidentContents() },
                            onUpNext: { contentsRequestedTab = .upNext }
                        )
                    }
                } else {
                    HStack(spacing: 0) {
                        Spacer()
                        controlSlot(.leadingEdge, style: .edge)
                        Spacer()
                        transportSkipButton(forward: false)
                        Spacer()
                        transportPlayButton(diameter: 60)
                        Spacer()
                        transportSkipButton(forward: true)
                        Spacer()
                        controlSlot(.trailingEdge, style: .edge)
                        Spacer()
                    }
                }
            }
            .padding(.top, 14)

            if showsPlayerVolumeBar {
                playerVolumeRow
                    .padding(.horizontal, 36).padding(.top, 12)
            }

            // 底部 bar —— 按「播放页按钮」底栏的配置,但不放歌词键(歌词永远在右栏可见)。
            // 有声内容的目录常驻右栏,这里换成语速 / 定时 / 书签三块。
            if let spokenControls {
                // 和音乐页底栏一样只画图标(下面一行说明),不垫圆角方块。
                SpokenWordActionTiles(
                    palette: spokenWordPalette,
                    layout: .stacked,
                    showsContents: false,
                    tileHeight: 54,
                    tiles: spokenControls.tiles,
                    labelStyle: spokenWordControlLayout.tileLabelStyle,
                    onSleep: { showSleepTimer = true },
                    onContents: {},
                    // 右栏常驻:「接下来」只是把它翻到那一页。
                    onUpNext: { contentsRequestedTab = .upNext },
                    customTile: spokenWordCustomTile(
                        layout: .stacked,
                        tileHeight: 54,
                        palette: spokenWordPalette,
                        menuSurface: .wideLandscape
                    )
                )
                .padding(.horizontal, 36).padding(.top, 16)
            } else {
                wideLandscapeControlBar
                    .font(.body).padding(.horizontal, 80).padding(.top, 14)
            }

            // 底排停在原来那行音质小字还在时的高度。
            nowPlayingStatusBand(height: max(bottomSafeArea, 16) + 16, horizontalPadding: 36)
        }
    }

    @ViewBuilder
    private func wideRightPane() -> some View {
        VStack(spacing: 0) {
            // 跟左栏 grabber 顶端对齐
            Spacer().frame(height: topSafeArea + 21)
            if usesSpokenWordTransport {
                // 有声内容的右栏是这本书的目录、书签与文字稿。
                spokenWordContentsPane
                    .padding(.bottom, 24)
            } else {
                lyricsFullView
                    .padding(.bottom, 24)
            }
        }
    }

    private var spokenWordContentsPane: some View {
        SpokenWordContentsView(
            presentation: .embedded(spokenWordPalette),
            // 没有文字稿时这一页也在:写明没有、能生成就给生成,生成中在这里看进度。
            textTab: AnyView(lyricsFullView),
            requestedTab: $contentsRequestedTab
        )
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
                    Button { returnToArtworkFromLyricsHeader() } label: {
                        HStack(spacing: 10) {
                            lyricsThumbnailArtwork(size: 40, cornerRadius: 7)
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

                    let topActions = immersiveLyricsTopActions
                    if let extra = lyricsHeaderExtraAction(onSurface: .configuredImmersiveLyrics(visible: Set(topActions))) {
                        lyricsHeaderExtraButton(extra)
                            .buttonStyle(.plain)
                    }

                    // 心形那一格:音乐按「全屏歌词」那份配置(默认跟歌名旁那一格),有声内容跟「喜欢」开关走。
                    if !usesSpokenWordTransport {
                        ForEach(topActions) { action in
                            controlButton(action, style: .header)
                        }
                    } else if offersLikeAction, spokenWordControlLayout.showsLike {
                        Button { toggleLikedCurrent() } label: {
                            nowPlayingActionIcon(
                                symbol: isCurrentLiked ? "heart.fill" : "heart",
                                tint: isCurrentLiked ? likedHeartTint : appearance.secondary,
                                isSelected: isCurrentLiked
                            )
                        }
                        .frame(width: 44, height: 44)
                        .buttonStyle(.plain)
                        .disabled(player.currentSong == nil)
                        .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                    }

                    immersiveMoreMenu(offersArtworkToggle: false)
                }
                .padding(.leading, max(safeInsets.leading, 18))
                .padding(.trailing, max(safeInsets.trailing, 18))
                .padding(.top, max(safeInsets.top, 10))

                Spacer()

                playbackDock(floats: true)
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

                    artworkOrMusicVideo(
                        size: artSize,
                        cornerRadius: 18,
                        playbackScale: artworkAppearsPlaying ? 1 : 0.96,
                        shadow: .init(opacity: 0.34, radius: 22, y: 10)
                    )
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
        // 高画布(见 `portraitArtworkFillsTallCanvas`):封面上限放宽到屏宽减 44,实际边长由版面按
        // 「其余几行 + 歌名下那段空白」之外剩下的高度定;碰到宽度上限时多出来的高度在封面上下平分。
        let fillsTallCanvas = portraitArtworkFillsTallCanvas(height: geo.size.height)
            && !player.isMusicVideoPlaybackActive
        // MV 是 16:9，若沿用方形封面按高度推导出的宽度，会在竖屏里显得
        // 明显偏小。视频改为尽量吃满屏宽；方形封面仍保持原来的视觉尺度。
        let mediaWidth = player.isMusicVideoPlaybackActive
            ? min(max(0, geo.size.width - 20), 720, insets.mediaWidthLimit)
            : fillsTallCanvas
                ? max(artSize, min(max(0, geo.size.width - 44), insets.mediaWidthLimit))
                : artSize
        // 封面那一块只要封面加上下各 12 的高度,封面、歌名一起靠上;多出来的高度放在歌名与进度条之间。
        let artworkRegionHeight = (player.isMusicVideoPlaybackActive ? mediaWidth * 9 / 16 : mediaWidth) + 24
        let controlGap = Self.portraitControlGap(forHeight: geo.size.height)
        // 进度条上面那几行歌词(设置里打开)。它占的高度从封面那里让出来: 高屏的空白就够,
        // 不够时封面按剩下的高度缩小。不跟歌词页开关走, 进出歌词页时下面几行不挪位置。
        // 分栏时右栏正在放整页歌词(这一栏于是不跟歌词开关走), 这里不再重复。
        let artworkLyricsEnabled = showsArtworkLyrics
            && showLyrics == self.showLyrics
            && !usesSpokenWordTransport
            && !player.isMusicVideoPlaybackActive
            && !player.isLiveRadio
        // 行数选了「自动」:歌名与进度条之间剩下的高度都给歌词,能放几行放几行。
        let artworkLyricsFill = artworkLyricsEnabled
            && PlayerAppearancePreferences.artworkLyricsLines(rawValue: artworkLyricsLinesRawValue) == .fill
        // 关掉音量条空出来的高度。分到封面上方和几行控件之间, 不全堆在歌名与进度条之间(否则开着
        // 封面下的歌词时, 歌词和歌名中间空出一大片); 这些本来是音量行占着的, 矮屏也不会因此更挤。
        // 封面与歌词两种模式取同一个值。歌词选了「自动」时留给歌词, 多排几行。
        let volumeSlack: CGFloat = showsPlayerVolumeBar || artworkLyricsFill
            ? 0
            : Self.portraitVolumeRowHeight + 10 + controlGap
        // 有声内容(播客,以及全屏文字稿以外不走专版的书)那几格与功能块怎么摆。
        let spokenPortraitControls = usesSpokenWordTransport
            ? spokenWordControlLayout.resolved(in: spokenWordPortraitControlContext(usesToolColumn: usesToolColumn))
            : nil
        // 封面模式下大封面铺满(设置里的「封面样式」)。歌词模式不铺,小封面照旧。
        let fullBleedArtwork = !showLyrics
            && usesFullBleedArtwork(lyricsInline: lyricsInline, usesToolColumn: usesToolColumn)

        if usesAudiobookPlayerDesign, !isLyricsImmersive {
            // 包一层壳子,别在这个分支里现场构造整套版面(见 `NowPlayingDeferredContent`)。
            NowPlayingDeferredContent {
                audiobookPortraitLayout(
                    geo: geo,
                    insets: insets,
                    showsText: showLyrics,
                    usesToolColumn: usesToolColumn
                )
            }
        } else {
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
                    if (!showLyrics || !isLyricsImmersive), !fullBleedArtwork,
                       let error = player.lastPlaybackError {
                        playbackErrorToast(error)
                    }
                    // 文字稿那一页空着时进度就画在那一页上,这里不再重复。
                    if !showLyrics || (!isLyricsImmersive && !lyrics.isEmpty) {
                        transcriptGenerationStatus
                    }

                    if showLyrics {
                        // LYRICS MODE: compact header at top
                        if !isLyricsImmersive {
                            HStack(spacing: 10) {
                            // Explicit button rather than a hidden tap gesture:
                            // the artwork itself is now a discoverable way back.
                            Button { returnToArtworkFromLyricsHeader() } label: {
                                HStack(spacing: 10) {
                                    lyricsThumbnailArtwork(
                                        size: 44,
                                        cornerRadius: 6,
                                        receivesFullBleedArtwork: usesFullBleedArtwork(
                                            lyricsInline: lyricsInline,
                                            usesToolColumn: usesToolColumn
                                        )
                                    )
                                    .lyricsHeaderReveal(isArtwork: true)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(player.currentSong?.title ?? "")
                                            .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                                            .foregroundStyle(appearance.primary)
                                        Text(currentArtistDisplayName)
                                            .font(.caption).foregroundStyle(appearance.secondary).lineLimit(1)
                                    }
                                    .lyricsHeaderReveal()
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityLabel(Text("a11y_close_lyrics"))

                            Spacer()

                            musicVideoToggleButton(font: .title3, trailing: 4)
                                .lyricsHeaderReveal()

                            // 歌词页顶上多出来那一格(默认卡拉OK);页面上已经摆着同一颗键时不再多放。
                            let headerExtra = lyricsHeaderExtraAction(
                                onSurface: usesToolColumn
                                    ? .toolColumn(showsTransportEdges: true, headerOverflows: false)
                                    : .portrait
                            )
                            if let headerExtra {
                                lyricsHeaderExtraButton(headerExtra)
                                    .lyricsHeaderReveal()
                            }

                            // 竖栏里排着那一列按钮时(iPhone Duo),喜欢与更多在那一列里。
                            if !usesToolColumn {
                                // 播客文字稿也走这个标题栏:心形跟播客页的「喜欢」开关,不用音乐歌名旁那一格。
                                // 喜欢、更多摆进了下面传输键两侧时,那一行收起之前这里不重复。
                                let spokenControls = usesSpokenWordTransport
                                    ? spokenWordControlLayout.resolved(in: spokenWordPortraitControlContext())
                                    : nil
                                if let spokenControls {
                                    spokenWordLikeButton(shows: spokenControls.headerShowsLike)
                                        .lyricsHeaderReveal()
                                } else if let action = musicControlLayout.action(in: .header) {
                                    controlButton(action, style: .header)
                                        .lyricsHeaderReveal()
                                }

                                // More menu
                                if spokenControls?.headerShowsMore ?? true {
                                    makeMoreMenu(controlSurface: .portraitLyrics(headerExtra: headerExtra))
                                        .lyricsHeaderReveal()
                                }
                            }
                            }
                            .padding(.horizontal, 20).padding(.bottom, 6)
                            .padding(.leading, insets.lyricsLeading)
                            .padding(.trailing, insets.lyricsTrailing)
                            .transition(lyricsHeaderHandoffTransition)
                            // 大封面缩进来的途中压在正在淡入的歌词上面, 而不是被歌词盖住。
                            .zIndex(1)
                        }

                        // Full screen lyrics
                        if isLyricsImmersive {
                            // 包一层壳子再构造(见 `NowPlayingDeferredContent`)：这个 VStack 闭包在 Debug 构建里
                            // 约 440KB、外面的 portraitLayout 约 210KB，原生全屏的顶栏若在这里现场构造就整串叠在
                            // 它们上面，点全屏必撞主线程栈保护页。
                            NowPlayingDeferredContent {
                                immersiveLyricsExperience(
                                    isLandscape: false,
                                    topRowLeadingInset: insets.immersiveTopRowLeading,
                                    topRowTrailingInset: insets.immersiveTopRowTrailing,
                                    contentTopInset: insets.immersiveContentTop
                                ) {
                                    if immersiveShowsArtwork {
                                        immersiveArtworkFace(contentTopInset: insets.immersiveContentTop)
                                            .transition(.opacity)
                                    } else {
                                        lyricsFullView
                                            .transition(.opacity)
                                    }
                                }
                            }
                            .transition(.opacity)
                        } else {
                            collapsibleLyricsView
                                .padding(.leading, insets.lyricsLeading)
                                .padding(.trailing, insets.lyricsTrailing)
                                .pmLayoutSwitchFade()
                                .transition(lyricsPanelTransition)
                                // 转去横屏等别的版面时收起状态不带过去，回来是完整的播放页。
                                .onDisappear { isLyricsChromeCollapsed = false }
                        }
                    } else if fullBleedArtwork {
                        // 铺满封面(见 `fullBleedArtworkRegion`):这一块只占把手以下的高度,封面往上伸到屏幕顶端。
                        // 矮屏照样按剩下的高度压扁,封面居中裁掉上下。
                        fullBleedArtworkRegion(width: geo.size.width)
                            .frame(maxHeight: max(0, geo.size.width - Self.portraitGrabberBand(topSafeArea: topSafeArea)))
                            .layoutPriority(1)
                            .transition(lyricsHandoffArtworkTransition)
                            .zIndex(1)

                        // 顶上那一截被封面盖着,出错提示挪到封面下面。
                        if let error = player.lastPlaybackError {
                            playbackErrorToast(error)
                                .padding(.top, 8)
                        }
                    } else {
                        if fillsTallCanvas {
                            // 固定的这一截不让封面挤掉;封面到了宽度上限还有富余时,富余的一半落在这里。
                            Color.clear
                                .frame(height: 16 + volumeSlack * 0.4)
                            Spacer(minLength: 0)
                        } else {
                            // 把手与封面之间:高屏多空一点,矮屏先压这里。
                            Spacer(minLength: 0)
                                .frame(maxHeight: 16 + volumeSlack * 0.4)
                        }
                        GeometryReader { artworkGeometry in
                            // Text and controls retain their height; artwork uses the remaining space.
                            let ratio: CGFloat = player.isMusicVideoPlaybackActive ? 16.0 / 9.0 : 1
                            let fittedWidth = min(mediaWidth, max(1, artworkGeometry.size.height - 24) * ratio)
                            artworkOrMusicVideo(
                                size: fittedWidth,
                                cornerRadius: 12,
                                playbackScale: player.isMusicVideoPlaybackActive
                                    ? 1.0
                                    : (artworkAppearsPlaying ? 1.0 : 0.9)
                            )
                                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: artworkAppearsPlaying)
                                .onTapGesture {
                                    guard !player.isMusicVideoPlaybackActive else { return }
                                    openTextFromArtwork()
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        // 封面先拿高度(不超过它自己那一块),上下的空白只分剩下的;矮屏照旧按剩下的高度缩封面。
                        .frame(maxHeight: artworkRegionHeight)
                        .layoutPriority(1)
                        // 进出场的是这一层 GeometryReader, 转场要挂在它身上才生效 (挂在里面的封面上时
                        // 这一层按默认淡入, 回封面页时大封面仍是半透明的)。移动的封面始终压在淡入淡出的歌词上面。
                        .transition(lyricsHandoffArtworkTransition)
                        .zIndex(1)
                    }

                    // Song info (player mode only — in lyrics mode it's in the top bar)
                    if !showLyrics {
                        // 高画布上封面会把可压的空白都吃掉,这一截要定住。
                        Spacer(minLength: fillsTallCanvas ? 16 : 0)
                            .frame(maxHeight: 16)

                        nowPlayingSongHeader(titleFont: .title3, metadataFont: .body, inlineActions: !usesToolColumn)
                            .matchedLayoutElement(.songHeading, in: layoutNamespace)
                            .padding(.horizontal, 26)
                            .padding(.horizontal, insets.rows)
                            .padding(.top, 12)

                        nowPlayingReviewSection
                            .padding(.horizontal, 26)
                            .padding(.horizontal, insets.rows)
                            .pmLayoutSwitchFade()

                        // 高画布上这段空白是定长的,封面先拿走其余高度(见上面封面那一块)。
                        if fillsTallCanvas {
                            Color.clear
                                .frame(height: Self.portraitTallCanvasHeadingGap)
                        }

                        // 歌名紧跟封面,剩下的高度都在这里:进度条以下几行贴着底部,和歌词模式同一位置。
                        // 歌词选了「自动」时这段高度归歌词: 它先于封面上下的留白分到高度(优先级介于封面与留白之间),
                        // 下面仍是「一行」时那个定高的格子, 多出来的行从那一格往上排进这段空白。歌词不做成
                        // 「至少一行、可以一直长高」的一整块: VStack 先排伸缩范围小的留白, 轮到它时不够一行就
                        // 撑出屏幕, 底排被挤出去。
                        if artworkLyricsFill {
                            Color.clear
                                .overlay { artworkLyricPreview(fillsHeight: true) }
                                .padding(.horizontal, 26)
                                .padding(.horizontal, insets.rows)
                                .layoutPriority(0.5)
                                .pmLayoutSwitchFade()
                        } else {
                            Spacer(minLength: 0)
                        }

                        // 正在唱的那一句贴在进度条上面(设置里打开),和歌名之间是上面那段空白。
                        if artworkLyricsFill {
                            NowPlayingArtworkLyricSlot()
                                .padding(.top, Self.artworkLyricHeadingGap)
                                .padding(.bottom, 4)
                        } else if artworkLyricsEnabled {
                            artworkLyricPreview(fillsHeight: false)
                                .padding(.horizontal, 26)
                                .padding(.horizontal, insets.rows)
                                .padding(.top, Self.artworkLyricHeadingGap)
                                .padding(.bottom, 4)
                                .pmLayoutSwitchFade()
                        }
                    }

                    // Progress — 抽成独立子 view 隔离 player.currentTime 的高频
                    // 重算,避免触发父 body re-render(进而让 toolbar Menu 的 submenu
                    // 被强制关闭)。SwiftUI Observation 是 per-body 追踪——子 view
                    // 自己读 player.currentTime,父 view body 完全不读高频属性。
                    if !showLyrics || !(isLyricsImmersive || isLyricsChromeCollapsed) {
                        PlaybackProgressBar(fillTint: themedControlAccent) { progressAudioTags(showsSource: false) }
                            .matchedLayoutElement(.progress, in: layoutNamespace)
                            .padding(.horizontal, 26).padding(.top, 8)
                            .padding(.horizontal, insets.rows)

                        // Controls
                        portraitTransportRow(spokenControls: spokenPortraitControls)
                        .matchedLayoutElement(.transport, in: layoutNamespace)
                        .padding(.top, 12 + controlGap + volumeSlack * 0.3)
                        .padding(.horizontal, insets.rows)

                        if showsPlayerVolumeBar {
                            playerVolumeRow
                                .padding(.horizontal, 26).padding(.top, 10 + controlGap)
                                .padding(.horizontal, insets.rows)
                                .pmLayoutSwitchFade()
                        }

                        // Bottom bar —— 三个槽位都是 44×44, HStack 的两个 Spacer 才
                        // 会把 AirPlay 分到正中, 左右图标到 padding 边的距离也才相等。
                        // 竖栏里排着那一列按钮时(iPhone Duo)这一排的键都在那一列里,这里不再重复。
                        if !usesToolColumn {
                            portraitBottomBar(spokenControls: spokenPortraitControls)
                            .padding(.top, controlGap / 2 + volumeSlack * 0.3)
                            .padding(.horizontal, insets.rows)
                            .pmLayoutSwitchFade()
                        }

                        // 这套版面铺满整屏、不经安全区。底排停在原来那行音质小字还在时的高度,
                        // 下面那一截正是 Home 指示条那一带;没有指示条的机型也留出一行字的高度。
                        nowPlayingStatusBand(
                            height: max(bottomSafeArea - 8, Self.statusBandMinimumHeight),
                            horizontalPadding: 26 + insets.rows
                        )
                    } else if isLyricsChromeCollapsed {
                        // 控件收起后歌词铺到底，只让开 Home 指示条那一带。
                        Color.clear
                            .frame(height: max(bottomSafeArea - 8, Self.statusBandMinimumHeight))
                    }
                }
                // 侧边安全区按侧取值；上下仍沿用窗口安全区的既有处理。整屏居中(iPhone Duo)时两侧都是 0。
                .padding(.leading, insets.containerLeading)
                .padding(.trailing, insets.containerTrailing)
                // 铺满封面下面那一截垫在歌名和控件底下，盖住色场的下半(见 `FullBleedArtworkExtension`)。
                .backgroundPreferenceValue(LyricsArtworkAnchorKey.self) { anchors in
                    fullBleedArtworkExtension(anchor: fullBleedArtwork ? anchors[.cover] : nil)
                }
        }
    }

    /// 铺满封面且背景选的是封面取色时，封面下沿接着往下延伸；其它背景照旧露出来。
    @ViewBuilder
    private func fullBleedArtworkExtension(anchor: LyricsArtworkAnchor?) -> some View {
        if let anchor, anchor.bottomFade > 0,
           PlayerBackdropSettingsStore.shared.effectiveSource == .coverAmbient {
            GeometryReader { proxy in
                FullBleedArtworkExtension(
                    song: player.currentSong,
                    coverRevision: player.coverRevision,
                    artworkRect: proxy[anchor.bounds],
                    pageSize: proxy.size,
                    isLight: appearance.isLight,
                    strength: AppThemePreferences.normalizedAmbientStrength(ambientStrength),
                    usesIncreasedContrast: colorSchemeContrast == .increased,
                    allowsLoading: isPresentationSettled
                )
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    // MARK: - 有声书竖版(墨黑 / 暖白)

    /// 正在放的是播客:订阅的单集,或资料库里标成播客的文件。播客不套书的版式。
    private var currentItemIsPodcast: Bool {
        guard let song = player.currentSong else { return false }
        return PodcastPlaybackSong.isEpisode(song) || SpokenWordStore.shared.isPodcast(song)
    }

    /// 有声书(播客单集不算)用专门的两套设计,见 `AudiobookPlayerStyle`。iPhone 与 iPad 竖屏是
    /// 专门的版面;横屏、iPad 双栏沿用通用的有声版面,只把底换成同一种纯色。
    private var usesAudiobookPlayerDesign: Bool {
        #if os(iOS)
        usesSpokenWordTransport && !currentItemIsPodcast
        #else
        false
        #endif
    }

    private var audiobookPlayerStyle: AudiobookPlayerStyle {
        AudiobookPlayerStyle(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    /// 有声书的墨黑版面铺播放页背景(封面取色、流动色彩、模糊封面、自选图):播放页背景设置里
    /// 打开了「有声书也使用」。浅色的暖白照旧是纸面底,墨黑的字和控件本来就是白的,压得住。
    private var audiobookUsesPlayerBackdrop: Bool {
        usesAudiobookPlayerDesign && colorScheme == .dark
            && PlayerBackdropSettingsStore.shared.settings.appliesToAudiobooks
    }

    /// 设置里「控件颜色」选了单色,或主题色是「白色」。
    private var usesMonochromePlayerControls: Bool {
        PlayerAppearancePreferences.controlTint(rawValue: controlTintRawValue) == .monochrome
            || usesWhiteTheme
    }

    /// 顶栏、书名与封面那一块(有文字稿时可换成文字稿)、当前章节、进度、传输键、
    /// 语速定时书签目录、音量与规格。墨黑与暖白只是这几块的次序与写法不同。
    private func audiobookPortraitLayout(
        geo: GeometryProxy,
        insets: NowPlayingPortraitInsets,
        showsText: Bool,
        usesToolColumn: Bool
    ) -> some View {
        let style = audiobookPlayerStyle
        let margin: CGFloat = 28
        // iPad 竖屏与大窗口里版面不跟着拉宽,停在这个宽度居中。
        let columnLimit: CGFloat = 680
        let available = geo.size.width - insets.containerLeading - insets.containerTrailing - insets.rows * 2
        let contentWidth = max(0, min(available, columnLimit) - margin * 2)
        let isShort = geo.size.height < 760
        let chapterColumnWidth = min(max((contentWidth * 0.23).rounded(), 72), 120)
        // 进度条(连同「本章还剩约」)、传输键、功能块之间别挤在一起(#283):矮屏也留出一截,
        // 高屏按通用播放页那把尺再拉开一些。多出来的高度从封面与当前章节之间的空白里出。
        let controlGap = Self.portraitControlGap(forHeight: geo.size.height)
        let controls = spokenWordControlLayout.resolved(
            in: audiobookPortraitControlContext(usesToolColumn: usesToolColumn)
        )
        // 功能块全藏了、或都排进 Duo 竖栏时,下面那一排连同它的间距都不出现(#313)。
        let showsActionRow = !usesToolColumn && !controls.tiles.isEmpty
        let usesGrabber = audiobookTopBarUsesGrabber(usesToolColumn: usesToolColumn, controls: controls)
        // 最底下那行信息离上面多远:直接跟在传输键下面时留开一些;跟在暖白功能块下面时不再另加,
        // 那一排自己上下已留着空,再加就显得和来源隔得太开(#313)。
        let footerGap: CGFloat
        if !showsActionRow && !showsPlayerVolumeBar {
            footerGap = isShort ? 10 : 16
        } else if style.isNocturne {
            footerGap = isShort ? 4 : 8
        } else {
            footerGap = showsPlayerVolumeBar ? 4 : 0
        }

        return VStack(spacing: 0) {
            audiobookTopBar(style: style, usesToolColumn: usesToolColumn, controls: controls)
                .padding(.top, topSafeArea)
                .padding(.horizontal, 16)
                .pmLayoutSwitchFade()

            if let error = player.lastPlaybackError {
                playbackErrorToast(error)
                    .padding(.top, 4)
            }
            // 文字稿那一页空着时进度就画在那一页上,这里不再重复。
            if !showsText || !lyrics.isEmpty {
                transcriptGenerationStatus
            }

            VStack(spacing: 0) {
                if showsText {
                    audiobookTextHeader(style: style)
                        .padding(.top, 8)
                        .transition(lyricsHeaderHandoffTransition)
                        .zIndex(1)
                    // 上滑文字稿时收起下面的播放控件(播放页按钮里可关),点文字稿空白叫回来。
                    lyricsScrollView(
                        collapsesChromeOnScroll: textCollapsesOnScroll,
                        showsReaderButton: false
                    )
                        .padding(.horizontal, -margin)
                        .frame(maxHeight: .infinity)
                        .transition(lyricsPanelTransition)
                        .onDisappear { isLyricsChromeCollapsed = false }
                } else if style.isNocturne {
                    // 顶上只剩把手时书名和作者再往上靠一些(#320),多出来的高度落到封面下面。
                    Spacer(minLength: isShort ? 8 : 16)
                        .frame(maxHeight: usesGrabber ? (isShort ? 8 : 20) : .infinity)
                    AudiobookTitleBlock(style: style) { presentCurrentBook() }
                        .matchedLayoutElement(.songHeading, in: layoutNamespace)
                    AudiobookHeroRowLayout(
                        columnLeading: true,
                        columnWidth: chapterColumnWidth,
                        spacing: 24,
                        maxSide: 480
                    ) {
                        AudiobookChapterColumn(style: style)
                        audiobookCover(style: style)
                    }
                    // 封面顶边和左边「CHAPTER」对齐,离作者也就宽一些(#320)。
                    .padding(.top, isShort ? 24 : 32)
                    .layoutPriority(1)
                    .transition(lyricsHandoffArtworkTransition)
                    Spacer(minLength: isShort ? 16 : 28)
                } else {
                    Spacer(minLength: isShort ? 8 : 14)
                    HStack(spacing: 12) {
                        AudiobookPlayerEyebrow(key: "spoken_word_player_now_listening", style: style)
                        Rectangle()
                            .fill(style.hairline)
                            .frame(height: 0.5)
                    }
                    .pmLayoutSwitchFade()
                    AudiobookHeroRowLayout(
                        columnLeading: false,
                        columnWidth: chapterColumnWidth,
                        spacing: 28,
                        maxSide: 480
                    ) {
                        AudiobookChapterColumn(style: style)
                        audiobookCover(style: style)
                    }
                    .padding(.top, isShort ? 14 : 22)
                    .layoutPriority(1)
                    .transition(lyricsHandoffArtworkTransition)
                    AudiobookTitleBlock(style: style) { presentCurrentBook() }
                        .matchedLayoutElement(.songHeading, in: layoutNamespace)
                        .padding(.top, isShort ? 16 : 26)
                    Spacer(minLength: isShort ? 12 : 22)
                }

                if !showsText || !isLyricsChromeCollapsed {
                    AudiobookCurrentPartRow(
                        style: style,
                        showsPartButtons: controls.partRow == .chapters,
                        showsAccessory: controls.partRow.map { $0 != .chapters } ?? false,
                        onOpenContents: { openContentsPanel() }
                    ) {
                        // 章节那一行右边换成别的键时(「播放页按钮」,如「更多」)只放这一颗。
                        spokenWordSlotKey(
                            controls.partRow,
                            slot: .partRow,
                            font: .system(size: 18, weight: .regular),
                            tint: style.control(paper: style.primary),
                            selectedTint: style.accent
                        )
                    }
                        .padding(.top, showsText ? 8 : 0)
                        .pmLayoutSwitchFade()

                    AudiobookProgressBar(style: style)
                        .matchedLayoutElement(.progress, in: layoutNamespace)

                    audiobookTransportRow(
                        style: style,
                        isShort: isShort,
                        controls: controls
                    )
                        .matchedLayoutElement(.transport, in: layoutNamespace)
                        .padding(.top, (isShort ? 10 : 16) + controlGap * 0.5)

                    Group {
                        if style.isNocturne {
                            if showsPlayerVolumeBar {
                                playerVolumeRow
                                    .padding(.horizontal, 12)
                                    .padding(.top, isShort ? 10 : 16)
                            }
                            // 竖栏里排着那一列按钮时(iPhone Duo),这几样都在那一列里。
                            if showsActionRow {
                                audiobookActionRow(style: style, layout: .stacked, tiles: controls.tiles)
                                    .padding(.top, (isShort ? 6 : 12) + controlGap * 0.3)
                            }
                        } else {
                            // 细线只为隔开下面那一排,下面什么都不剩时不画。
                            if showsActionRow || showsPlayerVolumeBar {
                                Rectangle()
                                    .fill(style.hairline)
                                    .frame(height: 0.5)
                                    .padding(.top, (isShort ? 12 : 20) + controlGap * 0.3)
                            }
                            if showsActionRow {
                                audiobookActionRow(style: style, layout: .inline, tiles: controls.tiles)
                                    .padding(.top, 6)
                            }
                            if showsPlayerVolumeBar {
                                playerVolumeRow
                                    .padding(.horizontal, 12)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .pmLayoutSwitchFade()

                    if let song = player.currentSong {
                        let footer = nowPlayingFooterInfo(
                            for: song,
                            showsSource: spokenWordControlLayout.showsSource,
                            infoColor: style.faint,
                            sourceColor: style.faint,
                            noticeColor: style.secondary
                        )
                        // 来源关了、音频信息也关了时整行没字,不留一行空白。
                        if footer.hasContent {
                            footer
                                .tracking(0.6)
                                .padding(.top, footerGap)
                                .pmLayoutSwitchFade()
                        }
                    }
                }
            }
            .padding(.horizontal, margin)
            .frame(maxWidth: columnLimit)
            .padding(.horizontal, insets.rows)
            .frame(maxWidth: .infinity)
            .padding(.bottom, max(bottomSafeArea, 12))
        }
        .padding(.leading, insets.containerLeading)
        .padding(.trailing, insets.containerTrailing)
    }

    /// 收起键 · 投放 / 喜欢 / 更多。正中留空,书名就在下面,不再重复什么。
    /// 文字稿键默认在传输键那一行最左边;投放进了功能块、喜欢或更多进了格子(「播放页按钮」)时这里不再放。
    /// 右边一颗都不剩(或都在 Duo 竖栏里)时不再为一颗收起键占一整行:换成音乐播放页那根把手,
    /// 点它照样收起,下面的书封和书名往上让出这一截(#313)。
    @ViewBuilder
    private func audiobookTopBar(
        style: AudiobookPlayerStyle,
        usesToolColumn: Bool,
        controls: SpokenWordResolvedControls
    ) -> some View {
        if audiobookTopBarUsesGrabber(usesToolColumn: usesToolColumn, controls: controls) {
            audiobookGrabber(style: style)
        } else {
            audiobookTopBarRow(style: style, controls: controls)
        }
    }

    private func audiobookTopBarUsesGrabber(
        usesToolColumn: Bool,
        controls: SpokenWordResolvedControls
    ) -> Bool {
        let showsLike = offersLikeAction && controls.headerShowsLike
        return usesToolColumn
            || !(controls.headerShowsAirPlay || showsLike || controls.headerShowsMore)
    }

    private func audiobookGrabber(style: AudiobookPlayerStyle) -> some View {
        Button { onMinimize?() } label: {
            Capsule()
                .fill(style.tertiary)
                .frame(width: 48, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onMinimize == nil)
        .accessibilityLabel(Text("a11y_minimize_player"))
    }

    private func audiobookTopBarRow(
        style: AudiobookPlayerStyle,
        controls: SpokenWordResolvedControls
    ) -> some View {
        HStack(spacing: 0) {
            if let onMinimize {
                Button(action: onMinimize) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(style.control(paper: style.primary))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("a11y_minimize_player"))
            }
            Spacer(minLength: 0)
            // 竖栏里排着那一列按钮时(iPhone Duo),投放、喜欢与更多在那一列里,这时上面已换成把手。
            HStack(spacing: 0) {
                if controls.headerShowsAirPlay {
                    AirPlayButton()
                        .frame(width: 30, height: 30)
                        .frame(width: 40, height: 44)
                }
                spokenWordLikeButton(
                    shows: controls.headerShowsLike,
                    idleTint: style.control(paper: appearance.secondary)
                )
                if controls.headerShowsMore {
                    makeMoreMenu(
                        controlSurface: .portrait,
                        plainLabel: NowPlayingMoreMenuPlainLabel(
                            font: .system(size: 18, weight: .semibold),
                            tint: style.control(paper: appearance.secondary),
                            height: 44
                        )
                    )
                }
            }
            .fixedSize()
            .pmAnimation(.control, value: controls.headerShowsAirPlay)
            .pmAnimation(.control, value: controls.headerShowsMore)
        }
        .frame(height: 44)
    }

    /// 正方形的书封。方的原图正好铺满,竖的、横的整张放进来,空出的边用它自己的模糊放大垫上。
    /// 和文字稿顶上那张小封面是同一个匹配几何身份,切换时飞过去。点开是文字稿那一页。
    private func audiobookCover(style: AudiobookPlayerStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return CachedArtworkView(
            coverRef: player.currentSong?.coverArtFileName,
            songID: player.currentSong?.id ?? "",
            size: 420,
            cornerRadius: 0,
            sourceID: player.currentSong?.sourceID,
            filePath: player.currentSong?.filePath,
            fileFormat: player.currentSong?.fileFormat,
            placeholderIcon: "book.closed",
            loadsHighResolution: isPresentationSettled,
            fillsProposedSize: true,
            revisionToken: player.coverRevision
        )
        .bookCoverLayout(frameAspectRatio: 1)
        .artworkCrossfade()
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(style.hairline, lineWidth: 0.5)
        }
        .matchedGeometryEffect(
            id: lyricsArtworkTransitionID,
            in: lyricsArtworkNamespace,
            isSource: !isLyricsCompactArtworkVisible
        )
        .shadow(
            color: style.isNocturne
                ? .black.opacity(0.55)
                : Color(red: 0.30, green: 0.22, blue: 0.12).opacity(0.22),
            radius: style.isNocturne ? 22 : 16,
            y: style.isNocturne ? 12 : 10
        )
        .contentShape(shape)
        .onTapGesture { openTextFromArtwork() }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: SpokenWordPlayerText.bookTitle(player)))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("spoken_word_text_tab"))
    }

    /// 文字稿顶上那一行:小封面、书名、作者。点一下回到封面。
    private func audiobookTextHeader(style: AudiobookPlayerStyle) -> some View {
        HStack(spacing: 12) {
            Button { returnToArtworkFromLyricsHeader() } label: {
                HStack(spacing: 12) {
                    lyricsThumbnailArtwork(size: 44, cornerRadius: 4)
                        .lyricsHeaderReveal(isArtwork: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: SpokenWordPlayerText.bookTitle(player))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(style.primary)
                            .lineLimit(1)
                        if let author = SpokenWordPlayerText.author(player) {
                            Text(verbatim: author)
                                .font(.caption)
                                .foregroundStyle(style.secondary)
                                .lineLimit(1)
                        }
                    }
                    .lyricsHeaderReveal()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("a11y_close_lyrics"))
            transcriptReaderButton
        }
    }

    /// 快退 · 播放 · 快进。播放键是实心圆:墨黑橙红、暖白近黑,三角取底色。
    /// 两头各一格按「播放页按钮」摆(默认有文字稿时左边文字稿、右边目录),同样大小;
    /// 两格都空时不占位。
    private func audiobookTransportRow(
        style: AudiobookPlayerStyle,
        isShort: Bool,
        controls: SpokenWordResolvedControls
    ) -> some View {
        let diameter: CGFloat = isShort ? 64 : 72
        let showsPause = player.isPlaying || player.isLoading
        let sideKeyFont = Font.system(size: 22, weight: .light)
        // 播放键左右两半各自排开:两侧的键贴着两头,空着的那一边不留空位,播放键仍在正中(#320)。
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                if let action = controls.leadingSide {
                    spokenWordSlotKey(
                        action,
                        slot: .leadingSide,
                        font: sideKeyFont,
                        tint: style.control(paper: style.secondary),
                        selectedTint: style.accent,
                        height: 56
                    )
                    .pmFadeTransition(motion: .control)
                }
                Spacer(minLength: 0)
                audiobookSkipButton(forward: false, style: style)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Button {
                guard !player.isLoading else { return }
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(style.accent)
                    if player.showsLoadingIndicator {
                        ProgressView()
                            .tint(style.onAccent)
                            .pmFadeTransition(motion: .control)
                    } else {
                        Image(systemName: showsPause ? "pause.fill" : "play.fill")
                            .font(.system(size: diameter * 0.36, weight: .semibold))
                            .foregroundStyle(style.onAccent)
                            // 三角的视觉重心偏左,往右挪一点才像居中。
                            .offset(x: showsPause ? 0 : diameter * 0.03)
                            .contentTransition(.symbolEffect(.replace))
                            .pmFadeTransition(motion: .control)
                    }
                }
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.showsLoadingIndicator)
            .accessibilityLabel(showsPause
                ? String(localized: "a11y_pause")
                : String(localized: "a11y_play"))
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                audiobookSkipButton(forward: true, style: style)
                Spacer(minLength: 0)
                if let action = controls.trailingSide {
                    spokenWordSlotKey(
                        action,
                        slot: .trailingSide,
                        font: sideKeyFont,
                        tint: style.control(paper: style.secondary),
                        selectedTint: style.accent,
                        height: 56
                    )
                    .pmFadeTransition(motion: .control)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .pmAnimation(.control, value: controls.leadingSide)
        .pmAnimation(.control, value: controls.trailingSide)
    }

    /// 快退 15 / 快进 30 秒(秒数随设置);长按跳章、跳集。
    private func audiobookSkipButton(forward: Bool, style: AudiobookPlayerStyle) -> some View {
        Button {
            if forward { transportForward() } else { transportBackward() }
        } label: {
            Image(systemName: forward ? transportForwardSymbol : transportBackwardSymbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(style.control(paper: style.primary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? transportForwardLabel : transportBackwardLabel)
        .bookJumpMenu(isEnabled: true) { bookJumpItems(forward: forward) }
    }

    /// 语速 · 定时 · 书签 · 目录。墨黑图标在上、字在下;暖白排成一行。
    /// 摆进传输键两侧或章节那一行的键,这里不再重复(`tiles` 已经去掉)。
    private func audiobookActionRow(
        style: AudiobookPlayerStyle,
        layout: SpokenWordActionTiles.Layout,
        tiles: [SpokenWordControlTile]
    ) -> some View {
        let tileHeight: CGFloat = layout == .stacked ? 54 : 40
        return SpokenWordActionTiles(
            palette: style.palette,
            layout: layout,
            tileHeight: tileHeight,
            tiles: tiles,
            labelStyle: spokenWordControlLayout.tileLabelStyle,
            onSleep: { showSleepTimer = true },
            onContents: { openContentsPanel() },
            customTile: spokenWordCustomTile(layout: layout, tileHeight: tileHeight, palette: style.palette)
        )
    }

    /// 竖版的传输键一行(随机 · 上一首 · 播放 · 下一首 · 循环)。桌面半折的下半屏也用这一行。
    /// 有声内容(`spokenControls`)两端是上一章 / 下一章,外面再各一格按「播放页按钮」摆
    /// (默认有文字稿时最左边文字稿、最右边目录),见 `spokenWordTransportRow`。
    @ViewBuilder
    private func portraitTransportRow(spokenControls: SpokenWordResolvedControls?) -> some View {
        if let spokenControls {
            // 七颗键在 375 宽的手机上要挤一挤:间隙最小可以是 0(键本身的 44/56 宽已经留出了图标间距)。
            spokenWordTransportRow(
                spokenControls,
                playDiameter: 56,
                minimumGap: spokenControls.hasSideKeys && spokenControls.showsInnerChapters ? 0 : nil
            ) { slot, action in
                spokenWordSlotKey(
                    action,
                    slot: slot,
                    font: .body,
                    tint: appearance.secondary,
                    selectedTint: themedControlAccent
                )
            }
        } else {
            // 两头外侧也各留一道间隙,宽屏上两侧的键不贴着屏幕边。
            HStack(spacing: 0) {
                Spacer()
                controlSlot(.leadingEdge, style: .edge)
                Spacer()
                transportSkipButton(forward: false)
                Spacer()
                transportPlayButton(diameter: 56)
                Spacer()
                transportSkipButton(forward: true)
                Spacer()
                controlSlot(.trailingEdge, style: .edge)
                Spacer()
            }
        }
    }

    /// 有声内容的传输键一行:播放键左右两半各自把键平均排开 —— 空着的格不占位、不在一头留个空洞,
    /// 播放键始终在正中(#320)。两侧都空、也没有紧挨快退快进的上一章 / 下一章时,两头各留一个键位的空白,
    /// 三颗键不散到屏幕两边。
    private func spokenWordTransportRow<SideKey: View>(
        _ controls: SpokenWordResolvedControls,
        playDiameter: CGFloat,
        minimumGap: CGFloat?,
        @ViewBuilder sideKey: @escaping (SpokenWordControlSlot, SpokenWordSlotAction) -> SideKey
    ) -> some View {
        let keepsCompact = !controls.hasSideKeys && !controls.showsInnerChapters
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                if let action = controls.leadingSide {
                    Spacer(minLength: 0)
                    sideKey(.leadingSide, action)
                        .pmFadeTransition(motion: .control)
                }
                if controls.showsInnerChapters {
                    Spacer(minLength: minimumGap)
                    SpokenWordPartButton(forward: false, color: appearance.secondary)
                } else if keepsCompact {
                    Spacer(minLength: minimumGap)
                    transportKeySpace
                }
                Spacer(minLength: minimumGap)
                transportSkipButton(forward: false)
                Spacer(minLength: minimumGap)
            }
            .frame(maxWidth: .infinity)
            transportPlayButton(diameter: playDiameter)
            HStack(spacing: 0) {
                Spacer(minLength: minimumGap)
                transportSkipButton(forward: true)
                Spacer(minLength: minimumGap)
                if controls.showsInnerChapters {
                    SpokenWordPartButton(forward: true, color: appearance.secondary)
                    Spacer(minLength: minimumGap)
                } else if keepsCompact {
                    transportKeySpace
                    Spacer(minLength: minimumGap)
                }
                if let action = controls.trailingSide {
                    sideKey(.trailingSide, action)
                        .pmFadeTransition(motion: .control)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .pmAnimation(.control, value: controls.leadingSide)
        .pmAnimation(.control, value: controls.trailingSide)
        .pmAnimation(.control, value: controls.showsInnerChapters)
    }

    /// 一个键位大小的空白(只在三颗键时用来收拢,见 `spokenWordTransportRow`)。
    private var transportKeySpace: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }

    /// 快退 / 快进(有声内容)或上一首 / 下一首。长按有声内容跳章,音乐按住快进快退。
    private func transportSkipButton(forward: Bool) -> some View {
        Button { if forward { transportForward() } else { transportBackward() } } label: {
            Image(systemName: forward ? transportForwardSymbol : transportBackwardSymbol)
                .font(skipButtonStyle.font).foregroundStyle(appearance.primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel(forward ? transportForwardLabel : transportBackwardLabel)
        .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: forward) }
        .modifier(transportHoldScrubGesture(forward: forward))
    }

    private func transportPlayButton(diameter: CGFloat) -> some View {
        Button {
            guard !player.isLoading else { return }
            player.togglePlayPause()
        } label: {
            transportPlayPauseFace(diameter: diameter)
        }
        .disabled(player.showsLoadingIndicator)
        .accessibilityLabel(player.isPlaying || player.isLoading
            ? String(localized: "a11y_pause")
            : String(localized: "a11y_play"))
    }

    /// 竖版最下面那一排(默认歌词 · 投放 · 队列)。三个槽位都是 44×44(空着的格也占位),
    /// HStack 的两个 Spacer 才会把中间那颗分到正中, 左右图标到 padding 边的距离也才相等。
    @ViewBuilder
    private func portraitBottomBar(spokenControls: SpokenWordResolvedControls?) -> some View {
        if let spokenControls {
            // 有声内容把语速、睡眠定时、书签、目录摆在页面上:听书就是靠这几样,不该藏在菜单里。
            // 投放默认在标题右侧;摆进传输键两侧的键这里不再重复。
            // 和音乐页底栏、有声书墨黑版一样只画图标(下面一行说明),不垫圆角方块(#283)。
            SpokenWordActionTiles(
                palette: spokenWordPalette,
                layout: .stacked,
                tileHeight: 54,
                tiles: spokenControls.tiles,
                labelStyle: spokenWordControlLayout.tileLabelStyle,
                onSleep: { showSleepTimer = true },
                onContents: { openContentsPanel() },
                onUpNext: { openContentsPanel(tab: .upNext) },
                customTile: spokenWordCustomTile(layout: .stacked, tileHeight: 54, palette: spokenWordPalette)
            )
            .padding(.horizontal, 22)
            .padding(.top, 12)
        } else {
            musicBottomBar
        }
    }

    private var musicBottomBar: some View {
        HStack {
            controlSlot(.barLeading, style: .bar)
            Spacer()
            controlSlot(.barCenter, style: .bar)
            Spacer()
            controlSlot(.barTrailing, style: .bar)
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
                // 竖屏底部的播放键直接画在背景上,控件在时歌词在它上面淡出,不和按钮叠在一起。
                // 封面那一面自己按播放条让出了底部,不用淡。
                .mask {
                    immersiveDockClearanceMask(
                        isActive: !isLandscape && !immersiveShowsArtwork
                            && immersiveControlsState.showsPrimaryControls
                    )
                }
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
                    NowPlayingGlassActionButton(
                        symbol: "lock",
                        label: "immersive_lock_controls",
                        appearance: appearance,
                        tint: appearance.primary,
                        diameter: 44
                    ) {
                        lockImmersiveControls()
                    }

                    Spacer()

                    // 竖屏的封面 / 歌词两面(#311)。顶栏两格都配了按钮时这一排放不下第七颗,
                    // 只留「更多」里那一项。横屏沉浸本来就是封面卡片 + 歌词, 不给这一键。
                    if !isLandscape, immersiveLyricsTopActions.count < 2 {
                        NowPlayingGlassActionButton(
                            symbol: immersiveShowsArtwork ? "quote.bubble" : "photo",
                            label: immersiveShowsArtwork ? "immersive_show_lyrics" : "immersive_show_artwork",
                            appearance: appearance,
                            tint: appearance.primary,
                            diameter: 44
                        ) {
                            setImmersiveShowsArtwork(!immersiveShowsArtwork)
                        }
                    }

                    if !usesSpokenWordTransport {
                        immersiveEffectButton(glass: .adaptive)
                    }

                    // 原来心形的位置:音乐按「全屏歌词」那份配置(默认跟歌名旁那一格),有声内容跟「喜欢」开关走。
                    if !usesSpokenWordTransport {
                        ForEach(immersiveLyricsTopActions) { action in
                            controlButton(action, style: .glass)
                        }
                    } else if offersLikeAction, spokenWordControlLayout.showsLike {
                        NowPlayingGlassActionButton(
                            symbol: isCurrentLiked ? "heart.fill" : "heart",
                            label: isCurrentLiked ? "a11y_unlike" : "a11y_like",
                            appearance: appearance,
                            tint: isCurrentLiked ? likedHeartTint : appearance.primary,
                            diameter: 44,
                            isSelected: isCurrentLiked
                        ) {
                            toggleLikedCurrent()
                        }
                        .disabled(player.currentSong == nil)
                    }

                    immersiveMoreMenu(offersArtworkToggle: !isLandscape)

                    NowPlayingGlassActionButton(
                        symbol: "arrow.down.right.and.arrow.up.left",
                        label: "lyrics_exit_full_screen",
                        appearance: appearance,
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

                // 横屏这一块压在封面卡片和歌词上,仍垫玻璃底;竖屏下面是背景,直接摆。
                playbackDock(floats: isLandscape)
                    .frame(maxWidth: isLandscape ? 440 : 520)
                    .padding(.leading, leadingSafeInset + (isLandscape ? 28 : 20))
                    .padding(.trailing, trailingSafeInset + (isLandscape ? 28 : 20))
                    .padding(.bottom, Self.immersiveDockBottomInset(bottomSafeArea: bottomSafeArea, isLandscape: isLandscape))
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
                        .nowPlayingAdaptiveGlass(
                            Capsule(),
                            appearance: appearance,
                            tint: appearance.primary
                        )
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

    /// 进度条 + 传输键。`floats` 时垫一块玻璃底浮在内容上;否则和普通播放页一样直接画在背景上,
    /// 上一首、下一首只有图标。
    private func playbackDock(floats: Bool) -> some View {
        VStack(spacing: floats ? 8 : Self.plainDockRowSpacing) {
            PlaybackProgressBar(fillTint: themedControlAccent)
                .padding(.horizontal, floats ? 0 : 6)

            HStack(spacing: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.transportSpacing)) {
                // 播放键两侧按「全屏歌词」那份配置;只摆了一侧时另一侧留同样大的空位,播放键仍在正中。
                let dockActions = immersiveLyricsActions
                let showsDockEdges = dockActions[.dockLeading] != nil || dockActions[.dockTrailing] != nil
                if showsDockEdges {
                    dockEdgeControl(dockActions[.dockLeading])
                }

                Spacer(minLength: 0)

                dockSkipButton(forward: false, floats: floats)

                playerPlayButton

                dockSkipButton(forward: true, floats: floats)

                Spacer(minLength: 0)

                if showsDockEdges {
                    dockEdgeControl(dockActions[.dockTrailing])
                }
            }
            .frame(height: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.primaryTransportDiameter))
        }
        .modifier(NowPlayingDockPlate(isFloating: floats, strokeTint: appearance.primary.opacity(0.10)))
    }

    @ViewBuilder
    private func dockSkipButton(forward: Bool, floats: Bool) -> some View {
        let symbol = forward ? transportForwardSymbol : transportBackwardSymbol
        let label = forward ? transportForwardLabel : transportBackwardLabel
        Group {
            if floats {
                playerSkipButton(symbol: transportGlyphSymbol(forward: forward), label: label) {
                    if forward { transportForward() } else { transportBackward() }
                }
            } else {
                // 和普通播放页那一排同样的图标与字号。
                Button {
                    if forward { transportForward() } else { transportBackward() }
                } label: {
                    Image(systemName: symbol)
                        .font(skipButtonStyle.font)
                        .foregroundStyle(appearance.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(
                            width: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.secondaryTransportWidth),
                            height: 56
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(label))
            }
        }
        .bookJumpMenu(isEnabled: usesSpokenWordTransport) { bookJumpItems(forward: forward) }
        .modifier(transportHoldScrubGesture(forward: forward))
    }

    /// 竖屏原生全屏底部那一块(进度条 + 传输键)的上沿以下:控件在时歌词在这里之前淡完。
    private func immersiveDockClearanceMask(isActive: Bool) -> some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: isActive ? Self.plainDockLyricsFadeHeight : 0)
            Color.clear
                .frame(height: isActive
                    ? Self.immersiveDockBottomInset(bottomSafeArea: bottomSafeArea, isLandscape: false)
                        + Self.plainDockHeight + Self.plainDockLyricsGap
                    : 0)
        }
    }

    private static func immersiveDockBottomInset(bottomSafeArea: CGFloat, isLandscape: Bool) -> CGFloat {
        max(bottomSafeArea, 12) + (isLandscape ? 0 : 8)
    }

    private static let plainDockRowSpacing: CGFloat = 14
    /// 不垫底时那一块的高度:进度条连两端时间约 36,加行距与传输键那一行。
    private static let plainDockHeight: CGFloat = 36 + plainDockRowSpacing
        + CGFloat(NowPlayingCompactLandscapeLayoutPolicy.primaryTransportDiameter)
    private static let plainDockLyricsFadeHeight: CGFloat = 56
    /// 歌词淡完的地方离进度条上沿还留这么多,最后一行不贴着进度条。
    private static let plainDockLyricsGap: CGFloat = 16

    @ViewBuilder
    private func dockEdgeControl(_ action: NowPlayingControlAction?) -> some View {
        if let action {
            controlButton(action, style: .edge)
        } else {
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    private func lyricsArtworkSlot(
        size: CGFloat,
        cornerRadius: CGFloat,
        placement: LyricsArtworkPlacement,
        shadow: LyricsArtworkShadow = .init(),
        showsVideoPreparation: Bool = false
    ) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .anchorPreference(key: LyricsArtworkAnchorKey.self, value: .bounds) {
                [placement: LyricsArtworkAnchor(
                    bounds: $0,
                    cornerRadius: cornerRadius,
                    shadow: shadow,
                    showsVideoPreparation: showsVideoPreparation
                )]
            }
    }

    /// 铺满封面的大封面位：整宽、从屏幕顶端到这一块的下沿，直角、无阴影，下沿渐隐。
    private func lyricsArtworkFullBleedSlot(width: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .anchorPreference(key: LyricsArtworkAnchorKey.self, value: .bounds) {
                [.cover: LyricsArtworkAnchor(
                    bounds: $0,
                    cornerRadius: 0,
                    shadow: .init(),
                    showsVideoPreparation: true,
                    bottomFade: Self.fullBleedArtworkBottomFade,
                    coversTopChrome: true
                )]
            }
    }

    /// 铺满封面下沿渐隐的那一截（占封面高度），封面下面那截延伸按同一个值接上。
    private static let fullBleedArtworkBottomFade = FullBleedArtworkExtension.fadeFraction

    /// 竖版顶上把手那一行连同上下留白的高度(把手上方 6、自身 5、下方 10,见 `portraitLayout`)。
    private static func portraitGrabberBand(topSafeArea: CGFloat) -> CGFloat {
        topSafeArea + 21
    }

    /// 铺满封面在竖版里占的那一块：版面里只占把手以下的高度，封面槽位按底边对齐往上伸出把手那一行，
    /// 从屏幕顶端画起。点封面和卡片封面一样进歌词。
    private func fullBleedArtworkRegion(width: CGFloat) -> some View {
        let grabberBand = Self.portraitGrabberBand(topSafeArea: topSafeArea)
        return GeometryReader { region in
            lyricsArtworkFullBleedSlot(width: width, height: region.size.height + grabberBand)
                .onTapGesture { openTextFromArtwork() }
                .frame(width: region.size.width, height: region.size.height, alignment: .bottom)
        }
    }

    private func playbackErrorToast(_ error: String) -> some View {
        let offersSourceSkip = player.pendingSourceSkip != nil
        return VStack(spacing: 8) {
            Text(error)
                .font(.caption).fontWeight(.medium)
                .multilineTextAlignment(.center)
            // 整个来源放不了、正在倒数跳过时:可以留在这首,也可以不等了。
            if offersSourceSkip {
                HStack(spacing: 10) {
                    playbackErrorToastButton("cancel") { player.cancelPendingSourceSkip() }
                    playbackErrorToastButton("source_skip_now") { player.skipUnavailableSourceNow() }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(
            .red.opacity(0.8),
            in: offersSourceSkip
                ? AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                : AnyShape(Capsule())
        )
        .padding(.horizontal, offersSourceSkip ? 16 : 0)
        .pmSlideTransition(edge: .top, motion: .list)
    }

    private func playbackErrorToastButton(
        _ title: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.white.opacity(0.22), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 竖屏播放页的大封面铺满（设置里「封面样式」选了铺满，音乐与播客各选各的）。只在 iPhone 的整屏竖版上：
    /// iPad 竖屏太宽，铺满会把下面几行挤没；Duo 分栏、竖栏那一列的版面窄而高，照旧用卡片。
    /// MV 有自己的画面，有声书的书封是竖版，都不铺。电台另见 `liveRadioUsesFullBleedLogo`。
    private func usesFullBleedArtwork(lyricsInline: Bool?, usesToolColumn: Bool) -> Bool {
        let styleRawValue = usesSpokenWordTransport
            ? (currentItemIsPodcast ? podcastArtworkStyleRawValue : NowPlayingArtworkStyle.card.rawValue)
            : artworkStyleRawValue
        return isPhoneCanvas
            && PlayerAppearancePreferences.artworkStyle(rawValue: styleRawValue) == .fullBleed
            && lyricsInline == nil
            && !usesToolColumn
            && !player.isMusicVideoPlaybackActive
            && !player.isLiveRadio
    }

    /// 电台台标铺满（「播放页样式与按钮 › 电台」里选）：同样只在 iPhone 整屏竖版上，横屏与 Duo 整屏居中照旧是卡片。
    private func liveRadioUsesFullBleedLogo(in size: CGSize) -> Bool {
        isPhoneCanvas
            && !centersOnFullScreen
            && size.height > size.width
            && PlayerAppearancePreferences.artworkStyle(rawValue: radioArtworkStyleRawValue) == .fullBleed
    }

    /// `receivesFullBleedArtwork`:封面那一面是铺满的(播客也可以选),小封面和音乐一样用槽位,
    /// 让铺满的封面缩进来;否则有声内容沿用书封那套匹配几何。
    @ViewBuilder
    private func lyricsThumbnailArtwork(
        size: CGFloat,
        cornerRadius: CGFloat,
        shadow: LyricsArtworkShadow = .init(),
        receivesFullBleedArtwork: Bool = false
    ) -> some View {
        if (usesSpokenWordTransport && !receivesFullBleedArtwork) || player.isMusicVideoPlaybackActive {
            CachedArtworkView(
                coverRef: player.currentSong?.coverArtFileName,
                songID: player.currentSong?.id ?? "",
                size: size, cornerRadius: cornerRadius,
                sourceID: player.currentSong?.sourceID,
                filePath: player.currentSong?.filePath,
                fileFormat: player.currentSong?.fileFormat,
                placeholderIcon: PodcastPlaybackSong.isEpisode(player.currentSong)
                    ? "antenna.radiowaves.left.and.right"
                    : "music.note",
                fillsProposedSize: true,
                revisionToken: player.coverRevision
            )
            .artworkCrossfade()
            .matchedGeometryEffect(
                id: lyricsArtworkTransitionID,
                in: lyricsArtworkNamespace,
                isSource: isLyricsCompactArtworkVisible
            )
            .frame(width: size, height: size)
        } else {
            lyricsArtworkSlot(size: size, cornerRadius: cornerRadius, placement: lyricsArtworkPlacement, shadow: shadow)
        }
    }

    /// 播放页大封面固定按这个尺寸画一次再缩放（单层飞行封面）。迷你条状态下的预热按同一尺寸解码。
    static let artworkRenderSize: CGFloat = 512

    private func lyricsArtworkOverlay(
        anchors: [LyricsArtworkPlacement: LyricsArtworkAnchor]
    ) -> some View {
        // 歌词那一侧的槽位可能比换位置那次更新晚一拍才出现，按「实际落在哪个槽位」
        // 驱动动画，晚到的那一次也走同一条曲线，而不是瞬移或换成别的动画。
        let placement: LyricsArtworkPlacement = anchors[lyricsArtworkPlacement] != nil
            ? lyricsArtworkPlacement
            : .cover
        return GeometryReader { geometry in
            if let anchor = anchors[placement] {
                let rect = geometry[anchor.bounds]
                // 封面按固定尺寸画一次，外框、圆角、图片和占位音符都在同一层里一起缩放。
                let renderSize = Self.artworkRenderSize
                // 播客铺满时也画在这一层:占位换成播客的图标,不去找动态封面。
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: renderSize, cornerRadius: 0,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath,
                    fileFormat: player.currentSong?.fileFormat,
                    placeholderIcon: PodcastPlaybackSong.isEpisode(player.currentSong)
                        ? "antenna.radiowaves.left.and.right"
                        : "music.note",
                    presentationRole: usesSpokenWordTransport ? .staticFirstFrame : .animatedHero,
                    animationRequiresPlayback: true,
                    isPlaying: player.isPlaying,
                    isAnimationVisible: isNowPlayingSurfaceExposed && !surfaceMotion.isHeld,
                    loadsHighResolution: isPresentationSettled,
                    revisionToken: player.coverRevision
                )
                .artworkCrossfade()
                .modifier(LyricsArtworkFlight(
                    rect: rect,
                    cornerRadius: anchor.cornerRadius,
                    shadow: anchor.shadow,
                    bottomFade: anchor.bottomFade,
                    renderSize: renderSize
                ))
                .animation(standardLyricsAnimation, value: placement)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: artworkAppearsPlaying)

                // 铺满封面压住了状态栏与下拉把手：顶上垫一道背景色的淡底，把手画在封面上面。
                // 版面里那根把手还在原位，被封面盖着；切到歌词时这两样淡出，露出的正是它。
                if anchor.coversTopChrome {
                    let band = topSafeArea + 44
                    LinearGradient(
                        colors: [appearance.backgroundBase.opacity(0.42), appearance.backgroundBase.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: rect.width, height: band)
                    .position(x: rect.midX, y: rect.minY + band / 2)
                    .transition(.opacity)

                    Capsule()
                        .fill(appearance.primary.opacity(0.5))
                        .frame(width: 48, height: 5)
                        .position(x: rect.midX, y: rect.minY + topSafeArea + 8.5)
                        .transition(.opacity)
                }

                if anchor.showsVideoPreparation {
                    MusicVideoPreparationBadge(songID: player.currentSong?.id)
                        .frame(width: rect.width, height: rect.height, alignment: .bottom)
                        .position(x: rect.midX, y: rect.midY)
                }

                #if os(iOS)
                // 「前往专辑」放大转场只需要知道从哪里放大：放一个和封面同位置的透明框当源，
                // 移动的封面本身只是上面这一层，不再叠系统转场的修饰。
                if placement == .cover, let albumID = currentAlbum?.id {
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .modifier(NowPlayingAlbumTransitionSourceModifier(
                            albumID: albumID,
                            namespace: albumPresentationNamespace,
                            cornerRadius: anchor.cornerRadius
                        ))
                        .position(x: rect.midX, y: rect.midY)
                }
                #endif
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func artworkOrMusicVideo(
        size: CGFloat,
        cornerRadius: CGFloat,
        playbackScale: CGFloat = 1,
        shadow: LyricsArtworkShadow = .init(opacity: 0.3, radius: 20, y: 8)
    ) -> some View {
        let displayedSize = size * playbackScale
        let displayedCornerRadius = cornerRadius * playbackScale
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
            .scaleEffect(playbackScale)
        } else if usesSpokenWordTransport {
            // 书封放进方形书框:方图直接铺满,竖版或横版的原图整张放进去、空出来的边用它自己的模糊放大垫上,
            // 和书架、书页是同一个零件。占的仍是原来那块方形槽位,别的布局不用跟着改。
            // 暂停时的缩小直接算进尺寸(和音乐那一支一样),别在匹配几何外面再套 scaleEffect:
            // 那样飞向小封面的起点和终点都会被一起缩向中心, 交接时跳一下。
            // 播客的方形封面圆角跟音乐一致, 不按书缩小。
            let isPodcastEpisode = currentItemIsPodcast
            SpokenWordBookCover(
                song: player.currentSong,
                width: SpokenWordCoverLayout.width(forHeight: displayedSize),
                cornerRadius: isPodcastEpisode
                    ? displayedCornerRadius
                    : max(6, displayedCornerRadius * 0.6),
                decodeSize: size
            )
            .matchedGeometryEffect(
                id: lyricsArtworkTransitionID,
                in: lyricsArtworkNamespace,
                isSource: !isLyricsCompactArtworkVisible
            )
            .frame(width: size, height: size)
        } else {
            lyricsArtworkSlot(
                size: displayedSize,
                cornerRadius: displayedCornerRadius,
                placement: isLyricsImmersive ? .immersiveLyrics : .cover,
                shadow: shadow,
                showsVideoPreparation: true
            )
            .frame(width: size, height: size)
        }
    }

    /// 歌词页上直接进卡拉OK（参照 Apple Music 歌词页的「唱」）。条件与「更多」里那一项相同，
    /// 另外要有歌词 —— 没词的页面是「暂无歌词」，放这颗键没意义。
    private var offersLyricsKaraokeAction: Bool {
        !usesSpokenWordTransport && player.currentSong != nil && !player.isAppleMusicMode
            && !player.isLiveRadio && !lyrics.isEmpty
    }

    private var lyricsKaraokeButton: some View {
        Button { showKaraoke = true } label: {
            nowPlayingActionIcon(symbol: "music.mic", tint: appearance.secondary)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text("karaoke_title"))
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
                player.setQueue(remainingQueue, startAt: anchorIndex, keepsContinuation: true)
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

    private func immersiveMoreMenu(offersArtworkToggle: Bool) -> some View {
        makeMoreMenu(
            immersiveChrome: true,
            chromeGlass: .adaptive,
            controlSurface: .configuredImmersiveLyrics(visible: Set(immersiveLyricsActions.values)),
            offersImmersiveArtworkToggle: offersArtworkToggle
        )
    }

    private func setImmersiveShowsArtwork(_ showsArtwork: Bool) {
        withAnimation(standardLyricsAnimation) {
            immersiveShowsArtwork = showsArtwork
        }
        if immersiveControlsState.isVisible {
            scheduleImmersiveControlsAutoHide()
        }
    }

    /// 原生全屏的封面那一面(#311):大封面居中、下面是歌名与艺人，上下给顶栏和底部播放条
    /// 让出位置，控件收起后也不挪。封面画在 `.immersiveLyrics` 那个槽里，从播放页进来、
    /// 退回歌词页时都是同一张封面飞过去。点封面回到歌词，点空白照旧叫出 / 收起控件。
    private func immersiveArtworkFace(contentTopInset: CGFloat) -> some View {
        GeometryReader { proxy in
            let topReserve = max(0, max(topSafeArea, 10) + 8 + 44 + 20 - contentTopInset)
            let bottomReserve = Self.immersiveDockBottomInset(bottomSafeArea: bottomSafeArea, isLandscape: false)
                + Self.plainDockHeight + 20
            let headingHeight: CGFloat = 56
            let spacing: CGFloat = 22
            let side = max(0, min(
                proxy.size.width - 56,
                Self.immersiveArtworkMaximumSide,
                proxy.size.height - topReserve - bottomReserve - headingHeight - spacing
            ))
            VStack(spacing: 0) {
                Color.clear.frame(height: topReserve)
                Spacer(minLength: 0)
                VStack(spacing: spacing) {
                    if player.isMusicVideoPlaybackActive {
                        // MV 自己带着全屏键，不把整块换成「显示歌词」。
                        artworkOrMusicVideo(size: side, cornerRadius: 16)
                    } else {
                        artworkOrMusicVideo(
                            size: side,
                            cornerRadius: 16,
                            playbackScale: artworkAppearsPlaying ? 1 : 0.94,
                            shadow: .init(opacity: 0.34, radius: 24, y: 12)
                        )
                        .animation(.spring(response: 0.5, dampingFraction: 0.76), value: artworkAppearsPlaying)
                        .contentShape(Rectangle())
                        .onTapGesture { setImmersiveShowsArtwork(false) }
                        .accessibilityElement()
                        .accessibilityLabel(Text("immersive_show_lyrics"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { setImmersiveShowsArtwork(false) }
                    }

                    VStack(spacing: 4) {
                        Text(player.currentSong?.title ?? "")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(appearance.primary)
                        Text(currentArtistDisplayName)
                            .font(.subheadline)
                            .foregroundStyle(appearance.secondary)
                    }
                    .lineLimit(1)
                    .frame(height: headingHeight)
                    .padding(.horizontal, 28)
                }
                Spacer(minLength: 0)
                Color.clear.frame(height: bottomReserve)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { handleImmersiveContentTap() }
        }
    }

    private static let immersiveArtworkMaximumSide: CGFloat = 520

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
                primary: theme.accentColor,
                secondary: theme.secondaryDarkAccent
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
        presentImmersiveLyrics()
    }
    #endif

    /// - Parameter controlSurface: 这份菜单所在的版面是按「播放页按钮」摆的哪一种;nil 是不按配置摆的
    ///   版面(沉浸歌词、iPad 横屏歌词),菜单照旧。
    /// 「更多」菜单都从这里拿。菜单本身推迟到 `NowPlayingDeferredContent` 里构造：
    /// 拼快照要逐项读几十个属性，Debug 构建里这一帧约 190KB；它挂在各个布局最深处（竖屏
    /// 歌名栏、歌词顶栏、原生全屏顶栏），现场构造时这 190KB 叠在整条布局链上，原生全屏
    /// 那一条因此越过 iPhone 主线程 1MB 的栈。推迟后它在自己那一层单独求值，调用处只多一个闭包。
    private func makeMoreMenu(
        immersiveChrome: Bool = false,
        chromeGlass: NowPlayingChromeGlass = .immersive,
        columnOverflow: NowPlayingBarColumnOverflow = NowPlayingBarColumnOverflow(),
        controlSurface: NowPlayingControlSurface? = nil,
        plainLabel: NowPlayingMoreMenuPlainLabel? = nil,
        offersImmersiveArtworkToggle: Bool = false
    ) -> some View {
        NowPlayingDeferredContent {
            buildMoreMenu(
                immersiveChrome: immersiveChrome,
                chromeGlass: chromeGlass,
                columnOverflow: columnOverflow,
                controlSurface: controlSurface,
                plainLabel: plainLabel,
                offersImmersiveArtworkToggle: offersImmersiveArtworkToggle
            )
        }
    }

    private func buildMoreMenu(
        immersiveChrome: Bool,
        chromeGlass: NowPlayingChromeGlass,
        columnOverflow: NowPlayingBarColumnOverflow,
        controlSurface: NowPlayingControlSurface?,
        plainLabel: NowPlayingMoreMenuPlainLabel?,
        offersImmersiveArtworkToggle: Bool
    ) -> some View {
        // 有声内容只留听书用得上的项: 相似歌曲、串烧、卡拉OK、全屏效果、随机、
        // 在线刮削(查的是音乐库)与歌词动效都是音乐的玩法, 「转到专辑」换成
        // 「转到这本书」。
        // 播客单集不在曲库里: 加歌单、改标签与歌词都没有落处, 「转到这本书」换成单集详情,
        // 分享给单集的网页。
        let isSpokenWord = usesSpokenWordTransport
        let isPodcastEpisode = PodcastPlaybackSong.isEpisode(player.currentSong)
        let podcastShareURL = isPodcastEpisode ? currentPodcastShareURL : nil
        // 「播放页按钮」:页面上没摆出来、本来只能靠那颗键点到的补进菜单,已经摆在页面上的不再重复。
        // 有声内容和不按配置摆的版面照旧,只有手机横屏让出两端时补上随机与循环。
        let menuFallback: [NowPlayingControlAction]
        let menuSuppressed: Set<NowPlayingControlAction>
        if let controlSurface, !isSpokenWord {
            menuFallback = musicControlLayout.menuFallback(on: controlSurface)
            menuSuppressed = musicControlLayout.menuSuppressed(on: controlSurface)
        } else {
            menuFallback = compactLandscapeHidesModeToggles && !isSpokenWord ? [.shuffle, .repeatMode] : []
            menuSuppressed = []
        }
        // 有声书、播客页上藏起来的入口(喜欢、文字稿、书签、播客的「接下来」)补进菜单。功能块只在竖屏
        // 与 iPad 横屏左栏出现,别的版面只看喜欢。
        let spokenFallback: [SpokenWordMenuFallback]
        if isSpokenWord, let controlSurface {
            let layout = spokenWordControlLayout
            let context = spokenWordMenuContext(for: controlSurface)
            spokenFallback = layout.menuFallback(for: layout.resolved(in: context), context: context)
        } else {
            spokenFallback = []
        }
        // 「播放页按钮 › 『更多』菜单」里关掉的项(#198):音乐、有声书、播客各有一份。
        let menuHidden: Set<NowPlayingMenuItem> = isSpokenWord
            ? spokenWordControlLayout.hiddenMenuItems
            : musicControlLayout.hiddenMenuItems
        let shows: (NowPlayingMenuItem) -> Bool = { !menuHidden.contains($0) }
        let snapshot = NowPlayingMoreMenuSnapshot(
            songID: player.currentSong?.id,
            isSpokenWord: isSpokenWord,
            isPodcastEpisode: isPodcastEpisode,
            canOpenPodcastEpisode: isPodcastEpisode && currentPodcastEpisodeID != nil
                && shows(.podcastEpisodeDetails),
            canOpenPodcastShow: isPodcastEpisode && SpokenWordPlayerText.podcastShowID(player) != nil
                && shows(.podcastGoToShow),
            showsPodcastMarkPlayed: isPodcastEpisode && currentPodcastEpisodeID != nil && shows(.podcastMarkPlayed),
            showsPodcastDownload: isPodcastEpisode && currentPodcastEpisodeID != nil && shows(.podcastDownload),
            transcriptGeneration: transcriptGenerationMenuItem,
            podcastShareURL: podcastShareURL,
            canOpenBook: isSpokenWord && !isPodcastEpisode && player.currentBookID != nil && shows(.goToBook),
            hasChapterList: (player.hasChapters || isSpokenWord) && shows(.chaptersAndBookmarks),
            hasSong: player.currentSong != nil,
            isScrapingCurrentSong: isScrapeActionUnavailable,
            canReloadLyricsFromSource: canReloadLyricsFromSource && shows(.reloadLyrics),
            isReloadingLyricsFromSource: isReloadingLyricsFromSource,
            isAppleMusicMode: player.isAppleMusicMode,
            canDeleteSourceFile: shows(.delete) && (player.currentSong.map {
                SourceFileDeletionPolicy.shouldShowDeleteAction(
                    for: sourcesStore.source(id: $0.sourceID)?.type
                )
            } ?? false),
            appleMusicCatalogURL: shows(.openInAppleMusic) ? appleMusicCatalogURL : nil,
            // 有声内容没有文字时歌词页是空的, 字号与翻译无从调起。
            showsLyricsPreferences: showLyrics && (!isSpokenWord || !lyrics.isEmpty) && shows(.lyricsDisplay),
            showsFullScreenAction: !isSpokenWord && !isLyricsImmersive && !isFullscreenPlayerPresented
                && !menuSuppressed.contains(.fullScreen) && shows(.fullScreen),
            albumID: currentAlbum?.id,
            artistID: currentArtist?.id,
            canOpenAlbum: canOpenCurrentAlbum && shows(.goToAlbum),
            canOpenArtist: currentArtist != nil && onOpenArtist != nil && shows(.goToArtist),
            canShare: (isPodcastEpisode ? podcastShareURL != nil : player.currentSong != nil)
                && !menuSuppressed.contains(.share) && shows(.share),
            showsAddToPlaylist: !menuSuppressed.contains(.addToPlaylist) && shows(.addToPlaylist),
            showsCastAction: !menuSuppressed.contains(.cast) && shows(.cast),
            showsSleepTimer: !menuSuppressed.contains(.sleepTimer) && shows(.sleepTimer),
            showsPlaybackRate: !menuSuppressed.contains(.playbackSpeed) && shows(.playbackSpeed),
            castingRendererName: player.castingRenderer?.friendlyName,
            isSleepTimerActive: player.isSleepTimerActive,
            lyricsFontScale: lyricsFontScale,
            lyricsTranslationFontScale: lyricsTranslationFontScale,
            showsCompanionFontSize: LyricsTranslationSettingsStore.shared.isEnabled || lyricsHaveBundledTranslations,
            transcriptOffsetItemKey: lyrics.isEmpty ? nil : player.currentSong.flatMap {
                SpokenWordTranscriptOffsetStore.shared.itemKey(for: $0)
            },
            transcriptOffsetItemDelay: player.currentSong
                .flatMap { SpokenWordTranscriptOffsetStore.shared.itemKey(for: $0) }
                .flatMap { SpokenWordTranscriptOffsetStore.shared.itemDelay(forKey: $0) } ?? 0,
            canChangePlaybackRate: canChangeCurrentPlaybackRate,
            // Apple Music 由系统播放器出声,投放时由对方设备出声,都不经过本机均衡器。
            showsEqualizer: !player.isAppleMusicMode && player.castingRenderer == nil
                && !menuSuppressed.contains(.equalizer) && shows(.equalizer),
            isEqualizerBypassed: player.outputMode(for: player.currentSong) == .highFidelity,
            playbackRate: !canChangeCurrentPlaybackRate
                ? 1
                : (player.currentItemIsSpokenWord
                    ? player.currentSpokenWordRate
                    : playbackSettings.playbackRate),
            isLyricsTranslationEnabled: LyricsTranslationSettingsStore.shared.isEnabled,
            lyricsTranslationMode: LyricsTranslationSettingsStore.shared.mode,
            offersSmartLyricsTranslation: intelligence.shouldExposeRemoteConfiguration,
            offersBaiduLyricsTranslation: BaiduTranslateAccount.shared.isConfigured
                || LyricsTranslationSettingsStore.shared.mode == .baidu,
            lyricsHaveBundledTranslations: lyricsHaveBundledTranslations,
            showsBundledLyricsTranslations: LyricsTranslationSettingsStore.shared.showsBundledTranslations,
            fallbackActions: menuFallback,
            spokenFallbackActions: spokenFallback.filter { $0 != .transcript || !lyrics.isEmpty },
            isShowingLyrics: showLyrics,
            isShuffleEnabled: player.shuffleEnabled,
            repeatMode: player.repeatMode,
            isMedleyActive: player.isMedleyActive,
            canStartMedley: !isSpokenWord && !player.isAppleMusicMode && !player.isLiveRadio
                && player.canPlayMedleyFromQueue && shows(.medley),
            canStartKaraoke: !isSpokenWord && player.currentSong != nil && !player.isAppleMusicMode
                && !player.isLiveRadio && !menuSuppressed.contains(.karaoke) && shows(.karaoke),
            medleyPlayQueueTitle: playbackSettings.medleyPlayQueueTitle,
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast,
            columnOverflow: columnOverflow,
            isCurrentLiked: isCurrentLiked,
            canDislike: player.canDislikeCurrentSong && !menuSuppressed.contains(.dislike) && shows(.dislike),
            isCurrentDisliked: isCurrentDisliked,
            playbackRangeSong: isSpokenWord || player.isAppleMusicMode || player.isLiveRadio || !shows(.playbackRange)
                ? nil
                : player.currentSong?.withoutAppliedPlaybackRange,
            showsScrape: shows(.scrape),
            showsSimilarSongs: shows(.similarSongs),
            showsTagEditor: shows(.editTags),
            showsLyricsEditor: shows(.editLyrics),
            showsSongInfo: shows(.songInfo),
            showsLyricsMotion: shows(.lyricsMotion),
            fullscreenEffectIsNative: fullscreenPlayerEffect.isNative,
            immersiveShowsArtwork: offersImmersiveArtworkToggle && isLyricsImmersive
                ? immersiveShowsArtwork : nil
        )

        return NowPlayingMoreMenu(
            snapshot: snapshot,
            lyricsFontScale: $lyricsFontScale,
            lyricsTranslationFontScale: Binding(
                get: { lyricsTranslationFontScale },
                set: {
                    lyricsTranslationFontScale = $0
                    CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsTranslationFontScale)
                }
            ),
            playbackRate: currentPlaybackRateBinding,
            immersiveChrome: immersiveChrome,
            chromeGlass: chromeGlass,
            plainLabel: plainLabel,
            equalizer: player.equalizerService,
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
            onOpenPodcastShow: { openCurrentPodcastShow?() },
            onMarkPodcastPlayed: { player.markCurrentPodcastEpisodePlayed() },
            onGenerateTranscript: { transcriptGenerationSong = player.currentSong },
            onShowChapterList: { openContentsPanel() },
            onOpenInAppleMusic: {
                guard let url = appleMusicCatalogURL else { return }
                openURL(url)
            },
            onShare: { shareSong = player.currentSong },
            onShowCastPicker: { showCastPicker = true },
            onToggleLike: { toggleLikedCurrent() },
            onToggleLyrics: { toggleLyricsForLayout() },
            onOpenQueue: { openQueue() },
            onAddBookmark: { _ = player.addSpokenWordBookmark() },
            onOpenUpNext: { openContentsPanel(tab: .upNext) },
            onToggleDislike: { player.toggleDislikeForCurrentSong() },
            onEditPlaybackRange: {
                playbackRangeEditorSong = player.currentSong?.withoutAppliedPlaybackRange
            },
            onShowEffectPicker: {
                immersiveControlsAutoHideTask?.cancel()
                showsImmersiveEffectPicker = true
            },
            onLockControls: {
                immersiveControlsAutoHideTask?.cancel()
                isCompactLandscapeLocked = true
            },
            onSelectLyricsTranslation: { mode in
                let settings = LyricsTranslationSettingsStore.shared
                guard let mode else {
                    settings.isEnabled = false
                    return
                }
                settings.mode = mode
                settings.isEnabled = true
            },
            onSetBundledLyricsTranslationsShown: { shows in
                LyricsTranslationSettingsStore.shared.showsBundledTranslations = shows
            },
            onToggleImmersiveArtwork: { setImmersiveShowsArtwork(!immersiveShowsArtwork) },
            onShowSleepTimer: { showSleepTimer = true },
            onAdjustEqualizer: { openEqualizer() },
            onShowEqualizerBypassNotice: { showEqualizerBypassNotice = true },
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

    /// 「更多」里和页面上那颗速度键共用:有声内容与音乐各记一档速度, 改的是正在播的这一类;
    /// 有声按书记,每本书可以有自己的速度。
    private var currentPlaybackRateBinding: Binding<Float> {
        Binding(
            get: {
                guard canChangeCurrentPlaybackRate else { return 1 }
                return player.currentItemIsSpokenWord
                    ? player.currentSpokenWordRate
                    : playbackSettings.playbackRate
            },
            set: {
                guard canChangeCurrentPlaybackRate else { return }
                if player.currentItemIsSpokenWord {
                    player.setSpokenWordRateForCurrentBook($0)
                } else {
                    playbackSettings.playbackRate = $0
                }
            }
        )
    }

    private func openEqualizer() {
        #if os(macOS)
        SettingsWindowController.shared.show(tab: .equalizer)
        #else
        showEqualizer = true
        #endif
    }

    // MARK: - Ambient background from cover dominant color

    private var backgroundGradient: some View {
        NowPlayingAmbientBackdrop(
            song: player.isLiveRadio ? nil : player.currentSong,
            isPlaying: player.isPlaying,
            isSurfaceVisible: isNowPlayingSurfaceExposed,
            isSceneActive: isVisualSceneActive,
            allowsImageLoading: isPresentationSettled,
            motion: surfaceMotion
        )
    }

    // MARK: - Full Lyrics

    private var lyricsFullView: some View {
        lyricsScrollView(collapsesChromeOnScroll: false)
    }

    /// 竖屏播放页里替换封面的那份歌词：往上翻歌词时收起底部控件。
    private var collapsibleLyricsView: some View {
        lyricsScrollView(collapsesChromeOnScroll: textCollapsesOnScroll)
    }

    private func lyricsScrollView(
        collapsesChromeOnScroll: Bool,
        showsReaderButton: Bool = true
    ) -> some View {
        LyricsScrollView(
            lyrics: romanizedPresentedLyrics,
            lyricsWritingDirection: romanizedLyricsWritingDirection,
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
                } else if collapsesChromeOnScroll, isLyricsChromeCollapsed {
                    // 收起的控件先叫回来，控件在时再点才回封面。
                    restoreLyricsChrome()
                } else {
                    setStandardLyricsVisible(false)
                }
            },
            onShareLyricLine: { lineID in
                presentLyricPoster(anchorLineID: lineID)
            },
            translatedTextByLineID: lyricTranslationsByLineID,
            translationActivity: lyricsTranslationActivity,
            onUserScroll: collapsesChromeOnScroll ? { collapseLyricsChrome() } : nil,
            spokenWordEmptyState: spokenTranscriptEmptyState
        )
        .overlay(alignment: .topTrailing) {
            if showsReaderButton {
                transcriptReaderButton
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
        }
    }

    /// 有声书、播客的文稿:右上角一颗键,全屏读、调字体与间距。
    @ViewBuilder
    private var transcriptReaderButton: some View {
        if usesSpokenWordTransport, !lyrics.isEmpty {
            Button {
                showsTranscriptReader = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appearance.secondary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("transcript_read_fullscreen"))
        }
    }

    @ViewBuilder
    private func nowPlayingSongHeader(
        titleFont: Font,
        metadataFont: Font,
        inlineActions: Bool = true,
        controlSurface: NowPlayingControlSurface = .portrait
    ) -> some View {
        if usesSpokenWordTransport {
            spokenWordHeading(
                titleFont: titleFont,
                partFont: metadataFont,
                inlineActions: inlineActions,
                controlSurface: controlSurface
            )
        } else {
            musicSongHeader(
                titleFont: titleFont,
                metadataFont: metadataFont,
                inlineActions: inlineActions,
                controlSurface: controlSurface
            )
        }
    }

    /// 有声内容的标题块:书名作主标题,下面是正在听的章与演播者,「第 12 / 120 章 ›」打开目录。
    /// 右侧是投放、喜欢与更多(竖栏那一列里已经有的不重复)。文字稿键在传输键那一行最左边。
    private func spokenWordHeading(
        titleFont: Font,
        partFont: Font,
        inlineActions: Bool,
        controlSurface: NowPlayingControlSurface
    ) -> some View {
        SpokenWordPlayerHeading(
            palette: spokenWordPalette,
            titleFont: titleFont,
            partFont: partFont,
            onOpenShow: openCurrentPodcastShow,
            onOpenBook: { presentCurrentBook() },
            onOpenContents: { openContentsPanel() }
        ) {
            let controls = spokenWordControlLayout.resolved(
                in: controlSurface == .wideLandscape
                    ? spokenWordWideLandscapeControlContext
                    : spokenWordPortraitControlContext()
            )
            HStack(spacing: 4) {
                if inlineActions {
                    if controls.headerShowsAirPlay {
                        AirPlayButton()
                            .frame(width: 30, height: 30)
                            .frame(width: 40, height: 44)
                    }
                    spokenWordLikeButton(shows: controls.headerShowsLike)
                    if controls.headerShowsMore {
                        makeMoreMenu(controlSurface: controlSurface)
                    }
                }
            }
            .fixedSize()
        }
    }

    /// 把正在听的这一个文件加进「我喜欢」,和锁屏上的「喜欢」是同一件事;播客单集记在播客自己那份。
    /// `shows` 是这个版面上右上角(或标题旁)那一组里要不要这一颗(喜欢摆进了格子时不要)。
    @ViewBuilder
    private func spokenWordLikeButton(shows: Bool, idleTint: Color? = nil) -> some View {
        if offersLikeAction, shows {
            Button { toggleLikedCurrent() } label: {
                nowPlayingActionIcon(
                    symbol: isCurrentLiked ? "heart.fill" : "heart",
                    tint: isCurrentLiked ? likedHeartTint : (idleTint ?? appearance.secondary),
                    isSelected: isCurrentLiked
                )
            }
            .frame(width: 40, height: 44)
            .buttonStyle(.plain)
            .disabled(player.currentSong == nil)
            .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
        }
    }

    /// 有声内容只在这一条目真有带时间的文字(字幕、转写稿按歌词读进来)时才有文字稿可看。
    private var hasSpokenWordTranscript: Bool {
        usesSpokenWordTransport && spokenWordHasText
    }

    /// 有声书竖版(墨黑 / 暖白):有章节那一行;看文字稿上滑收起时格子与功能块都不在。
    /// iPhone Duo 竖栏那一列里排着文字稿、目录与投放、更多,两侧与功能块让给那一列。
    private func audiobookPortraitControlContext(usesToolColumn: Bool) -> SpokenWordControlContext {
        SpokenWordControlContext(
            hasTranscript: hasSpokenWordTranscript,
            hasPartRow: true,
            showsSides: !usesToolColumn,
            hasTiles: !usesToolColumn,
            controlsCollapsed: showLyrics && isLyricsChromeCollapsed
        )
    }

    /// 通用的有声竖版(播客、桌面半折,以及看全屏文字稿以外的有声书非专版):紧挨快退快进
    /// 还有一对上一章 / 下一章,两侧那两格在它们外面。
    private func spokenWordPortraitControlContext(usesToolColumn: Bool = false) -> SpokenWordControlContext {
        SpokenWordControlContext(
            hasTranscript: hasSpokenWordTranscript,
            showsSides: !usesToolColumn,
            hasInnerChapterPair: true,
            hasTiles: !usesToolColumn,
            controlsCollapsed: showLyrics && (isLyricsImmersive || isLyricsChromeCollapsed)
        )
    }

    /// iPad 横屏左栏:目录常驻右栏。
    private var spokenWordWideLandscapeControlContext: SpokenWordControlContext {
        SpokenWordControlContext(
            hasTranscript: hasSpokenWordTranscript,
            hasInnerChapterPair: true,
            contentsResident: true
        )
    }

    /// 手机横屏右栏:放得下时只有两侧那两格,没有功能块。竖栏那一列里排着文字稿时(iPhone Duo)
    /// 这一行按没有文字稿摆。
    private func spokenWordCompactLandscapeControlContext(
        showsSides: Bool,
        usesToolColumn: Bool
    ) -> SpokenWordControlContext {
        SpokenWordControlContext(
            hasTranscript: hasSpokenWordTranscript && !usesToolColumn,
            showsSides: showsSides,
            hasTiles: false
        )
    }

    /// 「更多」菜单按哪种版面补页面上缺的入口。
    private func spokenWordMenuContext(for surface: NowPlayingControlSurface) -> SpokenWordControlContext {
        switch surface {
        case .portrait:
            return usesAudiobookPlayerDesign && !isLyricsImmersive
                ? audiobookPortraitControlContext(usesToolColumn: false)
                : spokenWordPortraitControlContext()
        case .wideLandscape:
            return spokenWordWideLandscapeControlContext
        default:
            // 手机横屏、竖栏那一列、全屏文字稿:没有功能块,只看喜欢。
            return SpokenWordControlContext(hasTranscript: hasSpokenWordTranscript, showsSides: false, hasTiles: false)
        }
    }

    /// 两侧那两格与章节那一行里的一颗键。`action` 为空时留一个同样大的空位。目录键在 iPad 横屏
    /// 翻右栏(`onContents`),「接下来」同理。
    @ViewBuilder
    private func spokenWordSlotKey(
        _ action: SpokenWordSlotAction?,
        slot: SpokenWordControlSlot,
        font: Font,
        tint: Color,
        selectedTint: Color,
        height: CGFloat = 44,
        menuSurface: NowPlayingControlSurface = .portrait,
        onContents: (() -> Void)? = nil,
        onUpNext: (() -> Void)? = nil
    ) -> some View {
        switch action {
        case nil:
            Color.clear
                .frame(width: 44, height: height)
                .accessibilityHidden(true)
        case .transcript:
            transportTextKey(font: font, tint: tint, selectedTint: selectedTint, height: height)
        case .contents:
            transportContentsKey(font: font, tint: tint, height: height, action: onContents)
        case .chapters:
            SpokenWordPartButton(forward: slot == .trailingSide, color: tint, font: font)
                .frame(width: 44, height: height)
        case .bookmark:
            Button {
                if player.addSpokenWordBookmark() { bookmarkFeedbackToken += 1 }
            } label: {
                spokenWordSlotIcon("bookmark", font: font, tint: tint, height: height)
                    .symbolEffect(.bounce, value: bookmarkFeedbackToken)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: bookmarkFeedbackToken)
            .accessibilityLabel(Text("spoken_word_add_bookmark"))
        case .speed:
            Menu {
                Picker(selection: spokenWordRateBinding) {
                    ForEach(SpokenWordPlaybackRatePolicy.presets, id: \.self) { rate in
                        Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate)).tag(rate)
                    }
                } label: {
                    Text(SpokenWordPlayerText.rateTitleKey(player))
                }
            } label: {
                Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: player.currentSpokenWordRate))
                    .font(font.monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 44, height: height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(Text(SpokenWordPlayerText.rateTitleKey(player)))
            .accessibilityValue(Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: player.currentSpokenWordRate)))
        case .sleepTimer:
            Button { showSleepTimer = true } label: {
                spokenWordSlotIcon(
                    player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz",
                    font: font,
                    tint: player.isSleepTimerActive ? selectedTint : tint,
                    height: height
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(player.isSleepTimerActive ? "sleep_timer_active" : "sleep_timer"))
        case .upNext:
            Button {
                if let onUpNext { onUpNext() } else { openContentsPanel(tab: .upNext) }
            } label: {
                spokenWordSlotIcon("list.bullet", font: font, tint: tint, height: height)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("up_next"))
        case .like:
            Button { toggleLikedCurrent() } label: {
                spokenWordSlotIcon(
                    isCurrentLiked ? "heart.fill" : "heart",
                    font: font,
                    tint: isCurrentLiked ? likedHeartTint : tint,
                    height: height
                )
            }
            .buttonStyle(.plain)
            .disabled(player.currentSong == nil)
            .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
            .accessibilityAddTraits(isCurrentLiked ? .isSelected : [])
        case .more:
            makeMoreMenu(
                controlSurface: menuSurface,
                plainLabel: NowPlayingMoreMenuPlainLabel(font: font, tint: tint, height: height)
            )
        }
    }

    /// 挪进最下面那一排的文字稿、喜欢、「更多」(`SpokenWordActionTiles.customTile`),和同一排别的块一样大。
    /// 这一条没有文字稿时那一块不出现,其余的照样平均排开。
    private func spokenWordCustomTile(
        layout: SpokenWordActionTiles.Layout,
        tileHeight: CGFloat,
        palette: SpokenWordPlayerPalette,
        menuSurface: NowPlayingControlSurface = .portrait
    ) -> (SpokenWordControlTile) -> AnyView? {
        let labelStyle = spokenWordControlLayout.tileLabelStyle
        let iconFont = SpokenWordActionTiles.iconFont(for: layout)
        return { tile in
            switch tile {
            case .transcript:
                guard hasSpokenWordTranscript else { return nil }
                return AnyView(transcriptToggleButton {
                    SpokenWordTileFace(layout: layout, tileHeight: tileHeight, labelStyle: labelStyle, palette: palette) {
                        Image(systemName: showLyrics ? "text.bubble.fill" : "text.bubble")
                            .font(iconFont)
                            .foregroundStyle(showLyrics ? palette.accent : palette.primary)
                            .contentTransition(.symbolEffect(.replace))
                    } caption: {
                        Text("spoken_word_text_tab")
                    }
                })
            case .like:
                guard offersLikeAction else { return nil }
                return AnyView(
                    Button { toggleLikedCurrent() } label: {
                        SpokenWordTileFace(layout: layout, tileHeight: tileHeight, labelStyle: labelStyle, palette: palette) {
                            Image(systemName: isCurrentLiked ? "heart.fill" : "heart")
                                .font(iconFont)
                                .foregroundStyle(isCurrentLiked ? likedHeartTint : palette.primary)
                                .contentTransition(.symbolEffect(.replace))
                        } caption: {
                            Text("player_controls_action_like")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(player.currentSong == nil)
                    .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                    .accessibilityAddTraits(isCurrentLiked ? .isSelected : [])
                )
            case .more:
                return AnyView(makeMoreMenu(
                    controlSurface: menuSurface,
                    plainLabel: NowPlayingMoreMenuPlainLabel(
                        font: iconFont,
                        tint: palette.primary,
                        height: tileHeight,
                        tile: NowPlayingMoreMenuTileStyle(
                            layout: layout,
                            tileHeight: tileHeight,
                            labelStyle: labelStyle,
                            secondary: palette.secondary,
                            tileFill: palette.tileFill
                        )
                    )
                ))
            case .speed, .sleepTimer, .bookmark, .contents, .upNext, .airPlay:
                return nil
            }
        }
    }

    private func spokenWordSlotIcon(_ symbol: String, font: Font, tint: Color, height: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(font)
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 44, height: height)
            .contentShape(Rectangle())
    }

    /// 这一条有没有带时间的文字。还没读出结论时(播放页刚展开,文字稿等入场动画结束才读;或正在问源)
    /// 先按上次的结论,文字稿 / 目录键随页面一起出现,不在页面停稳后才弹出来(#283)。
    private var spokenWordHasText: Bool {
        if !lyrics.isEmpty { return true }
        guard let song = player.currentSong,
              lyricsSongID != song.id || isResolvingLyrics else { return false }
        return SpokenWordTextPresenceMemo.predictedHasText(for: song)
    }

    /// 有声内容这一条读出结论(有字或确定没有)时记下来,下次展开播放页直接用。
    /// 问源途中先写进来的空结果不算:那时 `isResolvingLyrics` 还是真。
    private func rememberSpokenWordTextPresence() {
        guard usesSpokenWordTransport, !isResolvingLyrics,
              let song = player.currentSong, lyricsSongID == song.id else { return }
        SpokenWordTextPresenceMemo.record(!lyrics.isEmpty, for: song)
    }

    /// 传输键一行最左边的文字稿键:分栏时打开右栏,其它时候在封面与文字稿之间切换;按住直接全屏读文稿
    /// (#155)。按住后松手,按钮的点按也会触发,那一下吃掉。
    private func transportTextKey(
        font: Font,
        tint: Color,
        selectedTint: Color,
        height: CGFloat = 44
    ) -> some View {
        transcriptToggleButton {
            Image(systemName: showLyrics ? "text.bubble.fill" : "text.bubble")
                .font(font)
                .foregroundStyle(showLyrics ? selectedTint : tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: height)
                .contentShape(Rectangle())
        }
    }

    /// 文字稿键的点按与按住(两侧那一格、最下面那一排共用):点一下在封面与文字稿之间切换,按住全屏读文稿。
    private func transcriptToggleButton<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Button {
            if transcriptKeyHeld {
                transcriptKeyHeld = false
                return
            }
            toggleLyricsForLayout()
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45, maximumDistance: 24)
                .onEnded { _ in openTranscriptReaderFromHold() }
        )
        .accessibilityLabel(Text("spoken_word_text_tab"))
        .accessibilityHint(Text("spoken_word_text_tab_hold_hint"))
        .accessibilityAction(named: Text("transcript_read_fullscreen")) { openTranscriptReaderFromHold() }
        .accessibilityAddTraits(showLyrics ? .isSelected : [])
        .onChange(of: showsTranscriptReader) { _, shown in
            if !shown { transcriptKeyHeld = false }
        }
    }

    /// 按住文字稿键(或旁白的自定操作)打开全屏文稿;没有文字时什么也不做。
    private func openTranscriptReaderFromHold() {
        guard !lyrics.isEmpty else { return }
        // 和按住快退 / 快进弹出跳章菜单时一样,手上有一下(#283)。
        PMHaptics.longPressActivated()
        transcriptKeyHeld = true
        showsTranscriptReader = true
    }

    /// 传输键一行最右边的目录键(播客是节目说明),和左边的文字稿键一样大。`action` 不给时打开目录面板。
    private func transportContentsKey(
        font: Font,
        tint: Color,
        height: CGFloat = 44,
        action: (() -> Void)? = nil
    ) -> some View {
        let isPodcast = SpokenWordPlayerText.isPodcastEpisode(player)
        return Button {
            if let action {
                action()
            } else {
                openContentsPanel()
            }
        } label: {
            Image(systemName: isPodcast ? "text.alignleft" : "list.bullet")
                .font(font)
                .foregroundStyle(tint)
                .frame(width: 44, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isPodcast ? "podcast_show_notes" : "spoken_word_contents_title"))
    }

    private var spokenWordPalette: SpokenWordPlayerPalette {
        SpokenWordPlayerPalette(
            primary: appearance.primary,
            secondary: appearance.secondary,
            tertiary: appearance.tertiary,
            accent: themedControlAccent,
            tileFill: appearance.primary.opacity(appearance.isLight ? 0.07 : 0.10)
        )
    }

    private func musicSongHeader(
        titleFont: Font,
        metadataFont: Font,
        inlineActions: Bool = true,
        controlSurface: NowPlayingControlSurface = .portrait
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // 歌名与下面的艺人都只占一行,放不下时慢慢滚动(#192)。
                MarqueeText(text: player.currentSong?.title ?? "", font: titleFont.weight(.bold))
                    .foregroundStyle(appearance.primary)
                    .contentTransition(.opacity)
                    .pmAnimation(.trackChange, value: player.currentSong?.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                HStack(spacing: 4) {
                    musicVideoToggleButton(font: .title3, trailing: 0)
                    // 竖栏那一列里已经有的就不在这里重复。歌名旁那一格默认是心形。
                    if inlineActions, let action = musicControlLayout.action(in: .header) {
                        controlButton(action, style: .header)
                    }
                    if inlineActions {
                        makeMoreMenu(controlSurface: controlSurface)
                    }
                }
                .fixedSize()
            }
            nowPlayingMetadataLinks(font: metadataFont, scrolls: true)
            nowPlayingChapterLink
            nowPlayingMedleyBadge
        }
    }

    private var audioInfoMode: NowPlayingAudioInfoMode {
        PlayerAppearancePreferences.audioInfoMode(rawValue: audioInfoModeRawValue)
    }

    /// 底排下面那一截至少这么高,放得下一行状态。
    private static var statusBandMinimumHeight: CGFloat { 20 }

    /// 底排下面那一截:让开 Home 指示条,有事时在顶上写一行状态(输出设备、睡眠定时)。
    /// 往上提一点,贴着底排按钮的留白,不压到指示条。
    private func nowPlayingStatusBand(height: CGFloat, horizontalPadding: CGFloat) -> some View {
        Color.clear
            .frame(height: height)
            .overlay(alignment: .top) {
                NowPlayingStatusLine(
                    showsSleepTimer: !usesSpokenWordTransport && musicControlLayout.showsStatusItem(.sleepTimer),
                    showsOutput: musicControlLayout.showsStatusItem(.output),
                    source: usesSpokenWordTransport || !musicControlLayout.showsStatusItem(.source)
                        ? nil
                        : player.currentSong.flatMap(nowPlayingSourceLabel(for:)),
                    tint: appearance.tertiary
                )
                .padding(.horizontal, horizontalPadding)
                .offset(y: -4)
            }
    }

    #if DEBUG
    /// 取证用:模拟器里通常只有一个音乐源,`PRIMUSE_DEBUG_SOURCE_LABEL=1` 时照样标出来源。
    private static let debugAlwaysShowsSource =
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SOURCE_LABEL"] == "1"
    #endif

    /// 不止一个音乐源时标出这首歌来自哪个源。
    private func nowPlayingSourceLabel(for song: Song) -> NowPlayingSourceLabel? {
        var hasSeveralSources = sourcesStore.sources.count > 1
        #if DEBUG
        hasSeveralSources = hasSeveralSources || Self.debugAlwaysShowsSource
        #endif
        guard hasSeveralSources, let source = sourcesStore.source(id: song.sourceID) else {
            return nil
        }
        return NowPlayingSourceLabel(iconName: source.type.iconName, name: source.name)
    }

    /// 进度条下、两个时间中间的标签:音乐按设置的档位标音质(带规格简写);底下有状态行的版面
    /// 来源写在状态行里,没有的(手机横屏)才在这里加一枚来源。有声内容那里写本章还剩多久,
    /// 只在等 iCloud 下载时出现。轻点看完整规格、实际输出与来源。
    @ViewBuilder
    private func progressAudioTags(showsSource: Bool) -> some View {
        if let song = player.currentSong {
            let isSpokenWord = usesSpokenWordTransport
            NowPlayingAudioTagRow(
                song: song,
                showsAudio: !isSpokenWord && audioInfoMode.showsSummary(for: song.audioQuality),
                isDownloadingFromICloud: player.iCloudDownloadingSongID == song.id,
                source: isSpokenWord ? nil : nowPlayingSourceLabel(for: song),
                // 「播放页按钮」里关掉了状态行的来源时,手机横屏这枚来源标签也不挂。
                showsSourceTag: showsSource && musicControlLayout.showsStatusItem(.source),
                outputSampleRate: player.audioEngine.observedOutputSampleRate,
                allowsOutputDetail: !player.isAppleMusicMode,
                transcodePlan: player.activeTranscodePlan,
                tint: appearance.tertiary
            )
        }
    }

    /// 有声书版面最下面那行:格式、采样率与来源。起播前在 iCloud 下载时,
    /// 音频信息那段换成下载提示。
    private func nowPlayingFooterInfo(
        for song: Song,
        showsSource: Bool = true,
        infoColor: Color,
        sourceColor: Color,
        noticeColor: Color
    ) -> NowPlayingFooterInfoRow {
        NowPlayingFooterInfoRow(
            song: song,
            showsAudioDetail: audioInfoMode != .off,
            isDownloadingFromICloud: player.iCloudDownloadingSongID == song.id,
            // 「播放页按钮 › 有声书」里可以关掉来源。
            source: showsSource ? nowPlayingSourceLabel(for: song) : nil,
            outputSampleRate: player.audioEngine.observedOutputSampleRate,
            transcodePlan: player.activeTranscodePlan,
            infoColor: infoColor,
            sourceColor: sourceColor,
            noticeColor: noticeColor
        )
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
                    Text(playbackSettings.medleyBadgeTitle)
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
        // 播客单集不在曲库里, 评分会记成一条对不上任何歌的评价。
        if let song = player.currentSong, !PodcastPlaybackSong.isEpisode(song) {
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
    /// - Parameter scrolls: 只占一行、放不下时慢慢滚动(竖屏歌名下面那一行);否则最多 `lineLimit` 行。
    private func nowPlayingMetadataLinks(font: Font, lineLimit: Int = 2, scrolls: Bool = false) -> some View {
        let artistName = currentArtistDisplayName
        let albumTitle = player.currentSong?.albumTitle ?? ""
        let metadata = [artistName, albumTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        let label = Group {
            if scrolls {
                MarqueeText(text: metadata, font: font)
            } else {
                Text(verbatim: metadata)
                    .font(font)
                    .multilineTextAlignment(.leading)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
            .foregroundStyle(appearance.secondary)
            .contentTransition(.opacity)
            .pmAnimation(.trackChange, value: player.currentSong?.id)
            .frame(maxWidth: .infinity, alignment: .leading)

        // 有声内容这一行点开是它所在的书: 艺人页与专辑页只收音乐, 对它是空的。
        // 播客单集点开是这一集的详情(节目还订着时)。
        let isPodcastEpisode = PodcastPlaybackSong.isEpisode(player.currentSong)
        let opensBook = usesSpokenWordTransport && (isPodcastEpisode
            ? currentPodcastEpisodeID != nil
            : player.currentBookID != nil)
        if opensBook {
            Button { presentCurrentBook() } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityHint(isPodcastEpisode
                ? Text("podcast_player_episode_details")
                : Text("spoken_word_go_to_book"))
        } else if usesSpokenWordTransport && isPodcastEpisode {
            label
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

    // MARK: - 可换按钮(播放页按钮)

    /// 音乐播放页的按钮摆法。有声内容(书、播客)读默认那份,它们有自己的 `spokenWordControlLayout`。
    /// 看歌词时(歌词顶替封面,或横屏、分栏里歌词那一栏开着)用「歌词界面」那组,没单独摆就是同一组。
    private var musicControlLayout: NowPlayingControlLayout {
        guard !usesSpokenWordTransport else { return .default }
        return NowPlayingControlLayoutCache.layout(
            for: controlLayoutStorage,
            lyricsPageStorage: showLyrics ? lyricsPageControlStorage : nil
        )
    }

    private var lyricsPageControls: NowPlayingLyricsPageControls {
        NowPlayingControlLayoutCache.lyricsPageControls(for: lyricsPageControlStorage)
    }

    /// 全屏歌词(及 iPad 横屏看歌词)按「全屏歌词」那份配置摆的几格。「跟歌名旁」跟的是看歌词时歌名旁那一格。
    private var immersiveLyricsActions: [NowPlayingImmersiveLyricsSlot: NowPlayingControlAction] {
        guard !usesSpokenWordTransport else { return [:] }
        return NowPlayingControlLayoutCache.immersiveLyricsControls(for: immersiveLyricsControlStorage)
            .actions(header: musicControlLayout.action(in: .header))
    }

    /// 全屏歌词顶上一排「更多」左边那几颗。
    private var immersiveLyricsTopActions: [NowPlayingControlAction] {
        let actions = immersiveLyricsActions
        return [NowPlayingImmersiveLyricsSlot.topPrimary, .topSecondary].compactMap { actions[$0] }
    }

    /// 歌词页顶上多出来那一格此刻放什么:按「歌词界面」的配置;页面上已经摆着同一颗键、
    /// 或者这首歌用不了(卡拉OK要有歌词、不是 Apple Music)时不放。
    private func lyricsHeaderExtraAction(onSurface surface: NowPlayingControlSurface) -> NowPlayingControlAction? {
        guard !usesSpokenWordTransport, let extra = lyricsPageControls.headerExtra else { return nil }
        if extra == .karaoke, !offersLyricsKaraokeAction { return nil }
        guard !musicControlLayout.visibleActions(on: surface).contains(extra) else { return nil }
        return extra
    }

    @ViewBuilder
    private func lyricsHeaderExtraButton(_ action: NowPlayingControlAction) -> some View {
        if action == .karaoke {
            lyricsKaraokeButton
        } else {
            controlButton(action, style: .header)
        }
    }

    /// 上滑歌词(有声内容是文字稿)时收起播放控件:音乐看「歌词界面」的开关,书和播客各看自己的。
    private var textCollapsesOnScroll: Bool {
        guard usesSpokenWordTransport else { return lyricsPageControls.collapsesControlsOnScroll }
        return currentItemIsPodcast ? podcastTextCollapses : audiobookTextCollapses
    }

    private var radioControlLayout: NowPlayingRadioControlLayout {
        NowPlayingControlLayoutCache.radioLayout(for: radioControlStorage)
    }

    /// 有声书或播客播放页的那排功能块与几个开关。
    private var spokenWordControlLayout: SpokenWordControlLayout {
        let kind: SpokenWordPlayerKind = currentItemIsPodcast ? .podcast : .audiobook
        return NowPlayingControlLayoutCache.spokenWordLayout(
            for: kind == .podcast ? podcastControlStorage : audiobookControlStorage,
            kind: kind
        )
    }

    /// 竖栏那一列里的歌词(有声内容是文字稿)键:分栏时选中的是右栏的歌词页。
    private func barColumnLyricsButton(symbol: String, itemSize: CGFloat) -> some View {
        let isSelected = isPlayerSplit ? (!sidePaneHidden && showLyrics) : showLyrics
        return Button {
            toggleLyricsForLayout()
        } label: {
            NowPlayingBarColumnIcon(
                symbol: symbol,
                appearance: appearance,
                size: itemSize,
                tint: themedControlAccent,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isSelected ? "a11y_close_lyrics" : "a11y_open_lyrics"))
    }

    /// 竖栏那一列里的队列键:分栏时选中的是右栏的「接下来播放」。
    private func barColumnQueueButton(itemSize: CGFloat) -> some View {
        Button {
            openQueue()
        } label: {
            NowPlayingBarColumnIcon(
                symbol: "list.bullet",
                appearance: appearance,
                size: itemSize,
                tint: themedControlAccent,
                isSelected: isPlayerSplit && !sidePaneHidden && !showLyrics
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("a11y_queue"))
    }

    /// 一个位置上的按钮;空着的格照样占 44×44,别的按钮不挪位置。
    @ViewBuilder
    private func controlSlot(_ slot: NowPlayingControlSlot, style: NowPlayingControlStyle) -> some View {
        if let action = musicControlLayout.action(in: slot) {
            controlButton(action, style: style)
        } else {
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func controlButton(_ action: NowPlayingControlAction, style: NowPlayingControlStyle) -> some View {
        if action == .airPlay {
            airPlayControl(style: style)
        } else if case .column(let itemSize) = style, action == .lyrics {
            barColumnLyricsButton(symbol: "quote.bubble", itemSize: itemSize)
        } else if case .column(let itemSize) = style, action == .queue {
            barColumnQueueButton(itemSize: itemSize)
        } else if style == .edge, action == .shuffle {
            ctrlBtn("shuffle", active: player.shuffleEnabled) { player.shuffleEnabled.toggle() }
        } else if style == .edge, action == .repeatMode {
            ctrlBtn(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                cycleRepeatMode()
            }
        } else if action == .playbackSpeed, unavailableNotice(for: .playbackSpeed) == nil {
            playbackSpeedControl(style: style)
        } else {
            standardControl(action, style: style)
        }
    }

    @ViewBuilder
    private func airPlayControl(style: NowPlayingControlStyle) -> some View {
        switch style {
        case .glass:
            compactLandscapeAirPlayButton
        case .column(let itemSize):
            AirPlayButton()
                .frame(width: itemSize * 0.62, height: itemSize * 0.62)
                .frame(width: itemSize, height: itemSize)
        case .header:
            AirPlayButton()
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
        case .bar, .wideBar, .edge:
            AirPlayButton()
                .frame(width: 36, height: 36)
                .frame(width: 44, height: 44)
        case .effectGlass:
            AirPlayButton()
                .frame(width: 26, height: 26)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                }
        case .effectPill:
            AirPlayButton()
                .frame(width: 26, height: 26)
                .frame(width: 38, height: 38)
        }
    }

    /// 用不了时照样画、照样能点,只是淡一些;点了说明为什么(能一键解决的给按钮)。
    @ViewBuilder
    private func standardControl(_ action: NowPlayingControlAction, style: NowPlayingControlStyle) -> some View {
        let face = controlFace(action)
        let notice = unavailableNotice(for: action)
        let button = Button {
            if let notice {
                controlNotice = notice
            } else {
                performControl(action, style: style)
            }
        } label: {
            controlLabel(face, style: style)
                .opacity(notice == nil ? 1 : 0.4)
        }
        switch style {
        case .bar, .wideBar, .edge:
            button
                .frame(width: 44, height: 44)
                .disabled(face.requiresSong && player.currentSong == nil)
                .accessibilityLabel(Text(face.label))
                .accessibilityValue(controlAccessibilityValue(face, notice: notice))
        case .header:
            button
                .frame(width: 44, height: 44)
                .buttonStyle(.plain)
                .disabled(face.requiresSong && player.currentSong == nil)
                .accessibilityLabel(Text(face.label))
                .accessibilityValue(controlAccessibilityValue(face, notice: notice))
        case .glass, .column, .effectGlass, .effectPill:
            button
                .buttonStyle(.plain)
                .disabled(face.requiresSong && player.currentSong == nil)
                .accessibilityLabel(Text(face.label))
                .accessibilityValue(controlAccessibilityValue(face, notice: notice))
        }
    }

    /// 速度键直接弹出档位,和「更多」里那一项是同一个开关。
    private func playbackSpeedControl(style: NowPlayingControlStyle) -> some View {
        let face = controlFace(.playbackSpeed)
        return Menu {
            Picker(selection: currentPlaybackRateBinding) {
                Text("0.5×").tag(Float(0.5))
                Text("0.75×").tag(Float(0.75))
                Text(String(localized: "playback_rate_normal")).tag(Float(1.0))
                Text("1.25×").tag(Float(1.25))
                Text("1.5×").tag(Float(1.5))
                Text("1.75×").tag(Float(1.75))
                Text("2.0×").tag(Float(2.0))
            } label: {
                Text(face.label)
            }
        } label: {
            controlLabel(face, style: style)
        }
        .frame(width: style.fixedFrame, height: style.fixedFrame)
        .disabled(player.currentSong == nil)
        .accessibilityLabel(Text(face.label))
        .accessibilityValue(Text(verbatim: String(format: "%.2f×", Double(currentPlaybackRateBinding.wrappedValue))))
    }

    @ViewBuilder
    private func controlLabel(_ face: NowPlayingControlFace, style: NowPlayingControlStyle) -> some View {
        let activeTint = face.activeTint ?? themedControlAccent
        switch style {
        case .bar, .wideBar:
            Image(systemName: face.symbol)
                .foregroundStyle(face.isActive
                    ? activeTint
                    : (style == .wideBar ? appearance.secondary : appearance.tertiary))
                .contentTransition(.symbolEffect(.replace))
        case .edge:
            Image(systemName: face.symbol).font(.body)
                .foregroundStyle(face.isActive ? activeTint : appearance.tertiary)
                .contentTransition(.symbolEffect(.replace))
                .playbackToggleHighlight(isActive: face.isActive, tint: activeTint, diameter: 32)
        case .header:
            nowPlayingActionIcon(
                symbol: face.symbol,
                tint: face.isActive ? activeTint : appearance.secondary,
                isSelected: face.isActive
            )
        case .glass:
            NowPlayingGlassActionLabel(
                symbol: face.symbol,
                appearance: appearance,
                tint: face.isActive ? (face.activeTint ?? appearance.primary) : appearance.primary,
                diameter: CGFloat(NowPlayingCompactLandscapeLayoutPolicy.chromeButtonDiameter),
                isSelected: face.isActive
            )
        case .column(let itemSize):
            NowPlayingBarColumnIcon(
                symbol: face.symbol,
                appearance: appearance,
                size: itemSize,
                tint: activeTint,
                isSelected: face.isActive
            )
        case .effectGlass(let ink):
            ImmersiveGlassActionLabel(
                symbol: face.symbol,
                tint: face.isActive ? (face.activeTint ?? ink) : ink,
                diameter: 44,
                isSelected: face.isActive
            )
        case .effectPill(let ink):
            Image(systemName: face.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(face.isActive ? (face.activeTint ?? ink) : ink.opacity(0.88))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
    }

    private func controlAccessibilityValue(_ face: NowPlayingControlFace, notice: NowPlayingControlNotice?) -> Text {
        if let notice { return Text(notice.message) }
        guard face.isToggle else { return Text(verbatim: "") }
        return Text(face.isActive ? "a11y_value_on" : "a11y_value_off")
    }

    private func controlFace(_ action: NowPlayingControlAction) -> NowPlayingControlFace {
        switch action {
        case .like:
            return NowPlayingControlFace(
                symbol: isCurrentLiked ? "heart.fill" : "heart",
                label: isCurrentLiked ? String(localized: "a11y_unlike") : String(localized: "a11y_like"),
                isActive: isCurrentLiked,
                activeTint: likedHeartTint,
                requiresSong: true
            )
        case .dislike:
            return NowPlayingControlFace(
                symbol: isCurrentDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                label: isCurrentDisliked ? String(localized: "song_undislike") : String(localized: "song_dislike"),
                isActive: isCurrentDisliked,
                requiresSong: true
            )
        case .lyrics:
            // 看歌词时换成「回到封面」。图标已经说明了去向,亮度跟旁边的按钮一样,
            // 不再当成选中提亮——否则切到歌词页这一个键比 AirPlay、队列亮一截。
            return NowPlayingControlFace(
                symbol: showLyrics ? "photo" : "quote.bubble",
                label: showLyrics ? String(localized: "a11y_close_lyrics") : String(localized: "a11y_open_lyrics")
            )
        case .airPlay:
            return NowPlayingControlFace(symbol: "airplayaudio", label: String(localized: "player_controls_action_airplay"))
        case .queue:
            return NowPlayingControlFace(symbol: "list.bullet", label: String(localized: "a11y_queue"))
        case .shuffle:
            return NowPlayingControlFace(
                symbol: "shuffle",
                label: String(localized: "a11y_shuffle"),
                isActive: player.shuffleEnabled,
                isToggle: true
            )
        case .repeatMode:
            return NowPlayingControlFace(
                symbol: player.repeatMode == .one ? "repeat.1" : "repeat",
                label: String(localized: "a11y_repeat"),
                isActive: player.repeatMode != .off,
                isToggle: true
            )
        case .sleepTimer:
            return NowPlayingControlFace(
                symbol: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz",
                label: player.isSleepTimerActive
                    ? String(localized: "sleep_timer_active")
                    : String(localized: "sleep_timer"),
                isActive: player.isSleepTimerActive
            )
        case .equalizer:
            return NowPlayingControlFace(
                symbol: "slider.vertical.3",
                label: String(localized: "equalizer"),
                isActive: player.equalizerService.isEnabled && unavailableNotice(for: .equalizer) == nil,
                isToggle: true
            )
        case .playbackSpeed:
            let rate = currentPlaybackRateBinding.wrappedValue
            return NowPlayingControlFace(
                symbol: "speedometer",
                label: String(localized: "playback_rate"),
                isActive: abs(rate - 1) > 0.001,
                requiresSong: true
            )
        case .karaoke:
            return NowPlayingControlFace(symbol: "music.mic", label: String(localized: "karaoke_title"), requiresSong: true)
        case .fullScreen:
            return NowPlayingControlFace(
                symbol: "viewfinder.rectangular",
                label: String(localized: "full_screen_player"),
                requiresSong: true
            )
        case .addToPlaylist:
            return NowPlayingControlFace(
                symbol: "text.badge.plus",
                label: String(localized: "add_to_playlist"),
                requiresSong: true
            )
        case .share:
            return NowPlayingControlFace(
                symbol: "square.and.arrow.up",
                label: String(localized: "share"),
                requiresSong: true
            )
        case .cast:
            return NowPlayingControlFace(
                symbol: "hifispeaker",
                label: player.castingRenderer.map {
                    String(format: String(localized: "cast_casting_to_format"), $0.friendlyName)
                } ?? String(localized: "cast_to_device"),
                isActive: player.castingRenderer != nil,
                requiresSong: true
            )
        }
    }

    /// 因模式暂时用不了的说明。没有歌这种「根本没有」的情况走置灰,不在这里。
    private func unavailableNotice(for action: NowPlayingControlAction) -> NowPlayingControlNotice? {
        guard player.currentSong != nil else { return nil }
        switch action {
        case .dislike:
            guard !player.canDislikeCurrentSong else { return nil }
            return NowPlayingControlNotice(
                title: String(localized: "song_dislike"),
                message: String(localized: "player_controls_unavailable_dislike")
            )
        case .equalizer:
            if player.isAppleMusicMode {
                return NowPlayingControlNotice(
                    title: String(localized: "equalizer"),
                    message: String(localized: "player_controls_unavailable_eq_apple_music")
                )
            }
            if player.castingRenderer != nil {
                return NowPlayingControlNotice(
                    title: String(localized: "equalizer"),
                    message: String(localized: "player_controls_unavailable_eq_casting")
                )
            }
            guard player.outputMode(for: player.currentSong) == .highFidelity else { return nil }
            return NowPlayingControlNotice(
                title: String(localized: "eq_high_fidelity_alert_title"),
                message: String(localized: "eq_high_fidelity_alert_message"),
                offersEffectsOutput: true
            )
        case .playbackSpeed:
            if player.isAppleMusicMode {
                return NowPlayingControlNotice(
                    title: String(localized: "playback_rate"),
                    message: String(localized: "player_controls_unavailable_speed_apple_music")
                )
            }
            guard !canChangeCurrentPlaybackRate else { return nil }
            return NowPlayingControlNotice(
                title: String(localized: "playback_rate"),
                message: String(localized: "player_controls_unavailable_speed_high_fidelity"),
                offersEffectsOutput: true
            )
        case .karaoke:
            guard player.isAppleMusicMode else { return nil }
            return NowPlayingControlNotice(
                title: String(localized: "karaoke_title"),
                message: String(localized: "karaoke_unavailable_apple_music")
            )
        case .cast:
            guard player.isAppleMusicMode else { return nil }
            return NowPlayingControlNotice(
                title: String(localized: "cast_to_device"),
                message: String(localized: "player_controls_unavailable_cast_apple_music")
            )
        default:
            return nil
        }
    }

    private func performControl(_ action: NowPlayingControlAction, style: NowPlayingControlStyle) {
        switch action {
        case .like: toggleLikedCurrent()
        case .dislike: player.toggleDislikeForCurrentSong()
        case .lyrics: toggleLyricsForLayout()
        // iPad 横屏左栏原来就是直接弹出队列;全屏效果页盖在整页上,也直接弹出。
        case .queue: if style.opensQueueSheet { showQueue = true } else { openQueue() }
        case .shuffle: player.shuffleEnabled.toggle()
        case .repeatMode: cycleRepeatMode()
        case .sleepTimer: showSleepTimer = true
        case .equalizer: openEqualizer()
        case .karaoke: showKaraoke = true
        case .fullScreen: presentImmersiveLyrics()
        case .addToPlaylist: showAddToPlaylist = true
        case .share: shareSong = player.currentSong
        case .cast: showCastPicker = true
        case .airPlay, .playbackSpeed: break
        }
    }

    /// iPad 横屏左栏最下面那排:歌词常驻右栏,不放歌词键。两颗时和原来一样,一颗在中间、一颗靠右。
    @ViewBuilder
    private var wideLandscapeControlBar: some View {
        let actions = musicControlLayout.wideLandscapeBar()
        HStack {
            switch actions.count {
            case 0:
                Color.clear.frame(height: 44)
            case 1:
                Spacer()
                controlButton(actions[0], style: .wideBar)
                Spacer()
            case 2:
                Spacer()
                controlButton(actions[0], style: .wideBar)
                Spacer()
                controlButton(actions[1], style: .wideBar)
            default:
                controlButton(actions[0], style: .wideBar)
                Spacer()
                controlButton(actions[1], style: .wideBar)
                Spacer()
                controlButton(actions[2], style: .wideBar)
            }
        }
    }

    // MARK: - Helpers

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

    private var usesWhiteTheme: Bool {
        #if os(iOS)
        ThemeColorSettings.shared.isWhiteTheme
        #else
        false
        #endif
    }

    private var themedControlAccent: Color {
        // 有声书两套设计用自己的强调色(墨黑是白、暖白是近黑),横屏、iPad 双栏也用它,不随封面取色。
        if usesAudiobookPlayerDesign { return audiobookPlayerStyle.accent }
        // 设置里选了单色:深色外观下白、浅色外观下黑,和文字同色。主题色选了「白色」也一样,不跟封面取色。
        if usesMonochromePlayerControls {
            return appearance.primary
        }
        guard theme.colorID != "default" else { return appearance.primary }
        return appearance.isLight ? theme.darkAccent : theme.accentColor
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

        // Apple Music 先查 MetadataAssetStore songID cache (在线刮削或上次读到
        // 的歌词); miss 再读用户导入 Music.app 的本机文件里内嵌的歌词, 读到后
        // 写回 cache。流媒体曲目 Apple 不公开歌词正文。
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
            if let lyrics = await AppServices.shared.appleMusicLibrary.fetchLyrics(for: song),
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
                plog(String(format: "📜 Apple Music embedded lyrics '%@' in %.0fms (%d lines)",
                            song.title, Date().timeIntervalSince(loadStart) * 1000, lyrics.count))
                setLyricsIfCurrent(lyrics, for: song, loadRevision: loadRevision)
                return
            }
            plog("📜 Apple Music lyrics: none readable for '\(song.title)'")
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
            } else if (song.lyricsFileName ?? "").contains("/")
                        || LyricsLoader.readsPinnedDocument(song) {
                // NAS sidecars retain their existing source-of-truth refresh,
                // and so does a lyric file picked on the lyric sources page.
                runLyricsTier3Fetch(
                    song: song,
                    currentCache: cached,
                    loadRevision: loadRevision
                )
            } else {
                runSourceDocumentRecheck(song: song, currentCache: cached, loadRevision: loadRevision)
            }
            return
        }

        // 播客单集不在任何音乐源里:文字只来自 feed 里的 `<podcast:transcript>`。
        if PodcastPlaybackSong.isEpisode(song) {
            let transcript = await PodcastTranscriptLoader.lines(for: song)
            setLyricsIfCurrent(transcript, for: song, loadRevision: loadRevision)
            return
        }

        let lyricsRefIsRemote = (song.lyricsFileName ?? "").contains("/")
        // A picked lyric file is read from the source; the shortcuts below
        // only know the scanner's choice.
        let readsPinnedDocument = LyricsLoader.readsPinnedDocument(song)

        // Tier 1b: legacy named ref (only for non-NAS path)
        if !lyricsRefIsRemote,
           !readsPinnedDocument,
           let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
            guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
            await MetadataAssetStore.shared.cacheLyrics(cached, forSongID: song.id)
            plog(String(format: "📜 loadLyrics '%@' Tier1b hit (named ref) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, cached.count))
            guard setLyricsIfCurrent(cached, for: song, loadRevision: loadRevision) else { return }
            if !LyricsAuthoritativeSourcePolicy.supportsServerDocument(
                sourcesStore.source(id: song.sourceID)?.type
            ) {
                runSourceDocumentRecheck(song: song, currentCache: cached, loadRevision: loadRevision)
            }
            return
        }

        // Tier 2: Check local audio cache for a lyrics sidecar (filesystem only, zero network)
        if !readsPinnedDocument,
           LyricsLoader.usesAudioCacheSidecar(for: song),
           let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
            await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
            plog(String(format: "📜 loadLyrics '%@' Tier2 hit (audio cache sidecar) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, parsed.count))
            setLyricsIfCurrent(parsed, for: song, loadRevision: loadRevision); return
        }

        // 刚确认过源里没有同名歌词 / 文字稿：不再每次展开播放页都去源里问一遍。
        if !readsPinnedDocument,
           await LyricsSidecarMissLedger.shared.isRecentMiss(Self.lyricsSidecarMissKey(for: song)) {
            plog(String(format: "📜 loadLyrics '%@' sidecar known missing, skip Tier3", song.title))
            setLyricsIfCurrent([], for: song, loadRevision: loadRevision)
            return
        }

        // Tier 3: 首次必走 (无 cache, 无本地 sidecar)
        guard setLyricsIfCurrent([], for: song, loadRevision: loadRevision) else { return }
        // 上一行已经把"没有歌词"写进 UI, 但 Tier 3 还在路上。重新接上加载态,
        // 否则联网取词的这几百毫秒里播放页会先谎报一次"暂无歌词, 去刮削"。
        beginLyricsResolution(loadRevision)
        plog(String(format: "📜 loadLyrics '%@' miss Tier1+2, falling to Tier3 (NAS fetch)", song.title))
        runLyricsTier3Fetch(song: song, currentCache: nil, loadRevision: loadRevision)
    }

    /// 别处换掉了这首歌的歌词缓存: 和屏幕上的不一样才换。不走 `loadLyrics`, 免得又连一次源。
    private func showChangedLyrics(songID: String) async {
        guard let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID),
              !cached.isEmpty,
              player.currentSong?.id == songID,
              LyricsDocumentFingerprint(lines: cached) != LyricsDocumentFingerprint(lines: lyrics) else { return }
        lyricsLoadRevision &+= 1
        setLyrics(cached)
    }

    /// 核对源里的歌词文件(见 `LyricsLoader.recheckSourceDocument`), 换了就显示新的。
    private func runSourceDocumentRecheck(
        song: Song,
        currentCache: [LyricLine],
        loadRevision: UInt
    ) {
        let capturedSourceManager = sourceManager
        Task {
            guard let lines = await LyricsLoader.recheckSourceDocument(
                for: song,
                sourceManager: capturedSourceManager,
                cachedDocument: currentCache
            ), isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
            setLyrics(lines)
        }
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
        let missKey = Self.lyricsSidecarMissKey(for: song)
        let opaqueAddresses = sourcesStore.source(id: song.sourceID)?.type
            .usesOpaqueDirectoryIdentifiers ?? false

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
                // ID 寻址网盘的歌上记的是歌词文件 id, 下面的路径推断只推得出 `<歌>.lrc`:
                // 旁边只有 .ttml 等别的格式就读空。这类源照歌词来源页的规则列目录找「使用中」
                // 那份, 按实际大小读, 播放和来源页读的是同一份文件(#208)。
                let listedFile: LyricsLoader.AuthoritativeLyricsFile?
                if opaqueAddresses, connector is any LyricsSidecarTargetResolving {
                    guard let file = try await LyricsLoader.authoritativeLyricsFile(
                        for: song,
                        connector: connector
                    ) else {
                        // 列过目录, 确实一份歌词文件都没有。
                        guard !isRefresh else { return }
                        await LyricsSidecarMissLedger.shared.recordMiss(missKey)
                        guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                        plog(String(format: "📜 loadLyrics '%@' Tier3 no lyric file listed (connect=%.0fms)", songTitle, connectMs))
                        await applyAutomaticOnlineLyrics(
                            song: song, currentCache: currentCache, loadRevision: loadRevision
                        )
                        return
                    }
                    listedFile = file
                } else {
                    listedFile = nil
                }
                let lyricsPath: String
                if let listedFile {
                    lyricsPath = listedFile.path
                } else if let pinned = try await LyricsLoader.pinnedDocumentFile(
                    for: song,
                    connector: connector
                ) {
                    lyricsPath = pinned.path
                } else if let ref = song.lyricsFileName, ref.contains("/") {
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
                let documentName = listedFile?.fileName ?? (lyricsPath as NSString).lastPathComponent

                let fetchStart = Date()
                let lyricsData = try await connector.fetchRange(
                    path: lyricsPath,
                    offset: 0,
                    length: listedFile?.size ?? 256 * 1024,
                    priority: .background
                )
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                let fetchMs = Date().timeIntervalSince(fetchStart) * 1000
                guard let lyricsContent = LyricsParser.decodeText(
                    lyricsData, label: documentName
                ) else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 sidecar undecodable (connect=%.0fms fetch=%.0fms)", songTitle, connectMs, fetchMs))
                    if !isRefresh {
                        await LyricsSidecarMissLedger.shared.recordMiss(missKey)
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
                        await LyricsSidecarMissLedger.shared.recordMiss(missKey)
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
                    ofSidecarNamed: documentName
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
                if !isRefresh {
                    // 先显示, 再在后台看歌旁边有没有时间轴更细的另一份歌词文件。
                    let displayed = parsed
                    Task {
                        guard let upgraded = await LyricsLoader.upgradeToTimingPreferredDocument(
                            for: song,
                            connector: connector,
                            displayed: displayed,
                            displayedFileName: listedFile?.fileName,
                            documents: listedFile?.documents,
                            baseName: listedFile?.songBaseName
                        ), isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                        setLyrics(upgraded)
                    }
                }
            } catch {
                // 播放页这时可能已经收起，但「源里没有这个文件」这件事照样成立，先记下。
                if resolvedPlainSource, !isRefresh, Self.isMissingLyricsSidecarError(error) {
                    await LyricsSidecarMissLedger.shared.recordMiss(missKey)
                }
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

    /// `LyricsSidecarMissLedger` 的键：哪一首、扫描记下的歌词文件名。重扫找到歌词后文件名变了，
    /// 旧的「没有」自然作废。
    private static func lyricsSidecarMissKey(for song: Song) -> String {
        "\(song.id)\u{1F}\(song.lyricsFileName ?? "")"
    }

    /// 只有能确定「文件不存在」的错误才算没有歌词；连不上、超时、权限这类下次还要再试。
    /// 群晖 FileStation 缺文件多半回 408 错误包（已归为 `fileNotFound`），也有直接回 HTTP 404 的。
    private static func isMissingLyricsSidecarError(_ error: Error) -> Bool {
        if SourceManager.isMissingFileError(error) { return true }
        if case SynologyError.httpError(let status) = error, status == 404 || status == 410 { return true }
        return false
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
        // 源里读不到歌词文件: 先用读标签时留着的内嵌歌词, 没有再去在线找。
        if let embedded = await LyricsLoader.embeddedFallbackLyrics(for: song) {
            guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
            setLyrics(embedded)
            return
        }
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
        presentBundledTranslationVisibility()
        lyricsSongID = player.currentSong?.id
        lyricsRevision &+= 1
        let wordLevelCount = value.filter { $0.isWordLevel }.count
        plog("📜 setLyrics: lines=\(value.count) wordLevelLines=\(wordLevelCount) direction=\(String(describing: lyricsWritingDirection)) firstSyllables=\(value.first?.syllables?.count ?? -1)")
        // currentLineIndex / hasWordLevelLyrics 已迁移到 LyricsScrollView 子 view,
        // 子 view 自己 onChange(of: songID) 重置 + computed property 算 hasWord。
        consumePendingLyricsJump(from: value)
    }

    /// 全屏文字稿读的那份:和歌词页同一份,带着这一集 / 这本书的时间偏移(#320),关了「显示歌词
    /// 自带的译文」时也去掉文件带的译文,双语那一档才和歌词页说的一样。
    private var transcriptReaderLines: [LyricLine] {
        presentedLyrics
    }

    /// 文字稿偏移变了:按新的偏移重排一遍,歌词页按新时间轴重新对位。
    private func refreshTranscriptOffset() {
        presentBundledTranslationVisibility()
        lyricsRevision &+= 1
    }

    private func presentBundledTranslationVisibility() {
        let presentation = LyricBundledTranslationPolicy.presentation(
            of: lyrics,
            showsBundledTranslations: LyricsTranslationSettingsStore.shared.showsBundledTranslations
        )
        // 文字稿按这一集 / 这本书的偏移平移时间轴(#320);音乐原样。
        presentedLyrics = SpokenWordTranscriptOffsetStore.shared.presenting(
            presentation.lines,
            for: player.currentSong
        )
        lyricsHaveBundledTranslations = presentation.hasBundledTranslations
        refreshRomanizedLyrics()
    }

    /// 按罗马音设置得出显示用的那份歌词。只改显示：原文、行 id、时间戳都不变。「只显示罗马音」
    /// 时正文可能换了文字方向（阿拉伯文换成拉丁字母），按换过的那份重新判断。
    private func refreshRomanizedLyrics() {
        let mode = LyricsRomanizationSettingsStore.shared.displayMode
        let display = LyricRomanizationDisplayPolicy.displayLines(
            presentedLyrics,
            overlay: lyricRomanizationOverlay,
            mode: mode
        )
        if display != romanizedPresentedLyrics { romanizedPresentedLyrics = display }
        let direction = mode == .romanizationOnly && display != presentedLyrics
            ? LyricWritingDirectionPolicy.resolve(in: display)
            : lyricsWritingDirection
        if direction != romanizedLyricsWritingDirection { romanizedLyricsWritingDirection = direction }
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
        return intelligence.canTranscribeAudio(of: song)
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

/// 播放图层直接当视图的背板层:尺寸由 AppKit 跟着视图走,并裁在视图边界内。
/// 以前是挂在背板层下的子层、只在 layout() 里对齐,SwiftUI 改视图尺寸时不一定触发
/// layout(),子层停在旧的大尺寸上,画面就溢出播放页左栏、盖住歌词;SwiftUI 的
/// clipShape 也裁不到 AppKit 视图里的子层。
private final class MusicVideoLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.masksToBounds = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func makeBackingLayer() -> CALayer {
        playerLayer
    }
}
#endif

// MARK: - Custom Progress Slider (thin, no thumb)

struct ProgressSlider: View {
    /// 轨道粗细、底色与拖动点。默认是播放页一直用的胶囊条;有声书竖版是细线加一个圆点。
    struct TrackStyle: Equatable {
        var restingHeight: CGFloat = 5
        var draggingHeight: CGFloat = 8
        /// nil 时按明暗外观取。
        var trackColor: Color? = nil
        /// 给了就在播放头上画一个这么大的圆点,拖动时放大一圈。
        var knobDiameter: CGFloat? = nil
        /// 播放过的那段画成波浪(#69),播放头上一道竖着的短条。
        var isWave = false
        /// 播放过的那段和播放头外面一圈同色的光晕(#319)。
        var glows = false

        static let standard = TrackStyle()

        /// 设置 › 播放器 › 进度条 选的画法。
        static func forProgressStyle(_ style: NowPlayingProgressStyle, glows: Bool = false) -> TrackStyle {
            var track: TrackStyle
            switch style {
            case .standard: track = .standard
            case .wave: track = TrackStyle(restingHeight: 4, draggingHeight: 7, isWave: true)
            case .dot: track = TrackStyle(restingHeight: 3, draggingHeight: 5, knobDiameter: 12)
            }
            track.glows = glows
            return track
        }
    }

    let value: TimeInterval
    let total: TimeInterval
    let interactionID: String?
    let fillTint: Color?
    let trackStyle: TrackStyle
    /// 波浪只在播放时流动,暂停时抚平成直线。
    let isPlaying: Bool
    let onPreview: (TimeInterval?) -> Void
    let onSeek: (TimeInterval) -> Void

    init(
        value: TimeInterval,
        total: TimeInterval,
        interactionID: String? = nil,
        fillTint: Color? = nil,
        trackStyle: TrackStyle = .standard,
        isPlaying: Bool = false,
        onPreview: @escaping (TimeInterval?) -> Void = { _ in },
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.value = value
        self.total = total
        self.interactionID = interactionID
        self.fillTint = fillTint
        self.trackStyle = trackStyle
        self.isPlaying = isPlaying
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

    private var progressGlow: ProgressGlow {
        ProgressGlow(
            color: fillColor,
            isEnabled: trackStyle.glows,
            isLit: isPlaying,
            isLight: appearance.isLight
        )
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

    /// 波浪样式:播放过的那段是波浪,没播的那段是直线,播放头上一道竖着的短条。
    /// 拖动时抚平成直线,对准位置时不晃。
    private func waveTrack(width: CGFloat, filledWidth: CGFloat, trackHeight: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(trackStyle.trackColor ?? appearance.track)
                .frame(width: max(0, width - filledWidth), height: trackHeight)
                .offset(x: filledWidth)
                .animation(fillAnimation, value: progress)

            ProgressWaveFill(
                lineWidth: trackHeight,
                color: fillColor,
                isFlowing: isPlaying && !isDragging
            )
            .frame(width: filledWidth)
            .animation(fillAnimation, value: progress)
            .modifier(progressGlow)

            Capsule()
                .fill(fillColor)
                .frame(width: trackHeight, height: isDragging ? 20 : 14)
                .offset(x: filledWidth - trackHeight / 2)
                .animation(fillAnimation, value: progress)
                .modifier(progressGlow)
        }
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
            let trackHeight: CGFloat = isDragging ? trackStyle.draggingHeight : trackStyle.restingHeight
            let filledWidth = max(0, min(width, width * progress))

            ZStack(alignment: .leading) {
                if trackStyle.isWave {
                    waveTrack(width: width, filledWidth: filledWidth, trackHeight: trackHeight)
                } else {
                    // Background track
                    Capsule()
                        .fill(trackStyle.trackColor ?? appearance.track)
                        .frame(height: trackHeight)

                    // Filled track
                    Capsule()
                        .fill(fillColor)
                        .frame(width: filledWidth)
                        // 高度留在动画修饰符外面: 轨道加粗归下面那条 isDragging 的
                        // 曲线管, 这里只负责宽度, 免得一开始拖动就把加粗一起掐掉。
                        .animation(fillAnimation, value: progress)
                        .frame(height: trackHeight)
                        .modifier(progressGlow)
                }

                if let knob = trackStyle.knobDiameter {
                    let diameter = isDragging ? knob + 4 : knob
                    Circle()
                        .fill(fillColor)
                        .frame(width: diameter, height: diameter)
                        .offset(x: filledWidth - diameter / 2)
                        .animation(fillAnimation, value: progress)
                        .modifier(progressGlow)
                }
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

/// 进度条发光(#319):播放过的那段和播放头外面一圈同色的光晕。播放时亮,暂停时收淡;
/// 浅色外观下整体压淡,免得在浅底上看着像一道脏阴影。关着时不挂阴影,不白多一层离屏渲染。
private struct ProgressGlow: ViewModifier {
    let color: Color
    let isEnabled: Bool
    let isLit: Bool
    let isLight: Bool

    private var opacity: Double {
        let lit = isLight ? 0.4 : 0.85
        return isLit ? lit : lit * 0.45
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .shadow(color: color.opacity(opacity), radius: 6)
                .animation(.easeInOut(duration: 0.35), value: isLit)
        } else {
            content
        }
    }
}

/// 波浪进度条播放过的那一段:一条向播放头缓缓流动的正弦线。暂停、拖动时抚平成直线;
/// 「减弱动态效果」、低电量时停住不流动,形状照旧。只在播放页看得见时走钟。
private struct ProgressWaveFill: View {
    let lineWidth: CGFloat
    let color: Color
    let isFlowing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    private var animatesPhase: Bool {
        isFlowing && isVisible && !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animatesPhase)) { context in
            ProgressWaveShape(
                phase: animatesPhase ? ProgressWaveShape.phase(at: context.date) : 0,
                amplitude: isFlowing ? ProgressWaveShape.amplitude : 0
            )
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .animation(.easeInOut(duration: 0.35), value: isFlowing)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

private struct ProgressWaveShape: Shape {
    static let amplitude: CGFloat = 3
    static let wavelength: CGFloat = 26
    /// 波峰走过一个波长要的秒数。
    static let period: TimeInterval = 1.6

    var phase: CGFloat
    var amplitude: CGFloat

    var animatableData: CGFloat {
        get { amplitude }
        set { amplitude = newValue }
    }

    static func phase(at date: Date) -> CGFloat {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return CGFloat(cycle) * 2 * .pi
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        guard rect.width > 0 else { return path }
        let step: CGFloat = 2
        // 靠近播放头的半个波长里振幅收到 0,和后面的直线接上。
        let taper = Self.wavelength / 2
        var x: CGFloat = 0
        path.move(to: CGPoint(x: 0, y: midY + waveOffset(at: 0, width: rect.width, taper: taper)))
        while x < rect.width {
            x = min(x + step, rect.width)
            path.addLine(to: CGPoint(x: x, y: midY + waveOffset(at: x, width: rect.width, taper: taper)))
        }
        return path
    }

    private func waveOffset(at x: CGFloat, width: CGFloat, taper: CGFloat) -> CGFloat {
        let envelope = min(1, max(0, (width - x) / taper))
        return amplitude * envelope * sin(2 * .pi * x / Self.wavelength - phase)
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
            List {
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
                    infoRow(String(localized: "format_label"), song.detailedFormatName)
                    if let sampleRate = song.formattedSampleRate {
                        infoRow(String(localized: "sample_rate_label"), sampleRate)
                    }
                    if let bitDepth = song.formattedBitDepthDetail {
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
                // 从播放页打开的歌曲信息里再弹出的,同样跟「播放页始终用深色」。
                SimilarSongsSheet(seed: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .playerPresentationColorScheme()
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
        rows.append((String(localized: "format_label"), song.detailedFormatName, false))
        if let sampleRate = song.formattedSampleRate {
            rows.append((String(localized: "sample_rate_label"), sampleRate, false))
        }
        if let bitDepth = song.formattedBitDepthDetail {
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
    // 可选: 这张表也会从独立宿主(外接屏、菜单栏)里弹出, 那边未必注入了这两个。
    @Environment(SourcesStore.self) private var sourcesStore: SourcesStore?
    @Environment(SourceManager.self) private var sourceManager: SourceManager?
    @Environment(\.dismiss) private var dismiss
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var appendingPlaylistID: String?
    @State private var appendErrorMessage: String?

    private var editablePlaylists: [Playlist] {
        library.playlists.filter { isEditablePlaylist($0.id) }
    }

    /// 这首歌所在服务器上的歌单(#162)。只能往里加, 移出要在服务器上操作。
    private var serverPlaylists: [Playlist] {
        guard let sourcesStore, sourceManager != nil else { return [] }
        return ServerPlaylistAppendService.targets(for: [song], library: library, sourcesStore: sourcesStore)
    }

    private var serverSectionTitle: String {
        sourcesStore.flatMap { ServerPlaylistAppendService.source(for: [song], sourcesStore: $0)?.name }
            ?? String(localized: "playlist_kind_server_mirror")
    }

    private var appendErrorBinding: Binding<Bool> {
        Binding(
            get: { appendErrorMessage != nil },
            set: { if !$0 { appendErrorMessage = nil } }
        )
    }

    private func appendToServerPlaylist(_ playlist: Playlist) {
        guard appendingPlaylistID == nil,
              let sourcesStore, let sourceManager,
              !library.contains(songID: song.id, inPlaylist: playlist.id) else { return }
        appendingPlaylistID = playlist.id
        Task { @MainActor in
            defer { appendingPlaylistID = nil }
            do {
                try await ServerPlaylistAppendService.append(
                    [song],
                    toMirrorPlaylist: playlist.id,
                    library: library,
                    sourcesStore: sourcesStore,
                    sourceManager: sourceManager
                )
            } catch is CancellationError {
            } catch {
                appendErrorMessage = error.localizedDescription
            }
        }
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
            List {
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

                if !serverPlaylists.isEmpty {
                    Section {
                        ForEach(serverPlaylists) { playlist in
                            serverPlaylistRow(playlist: playlist)
                        }
                    } header: {
                        Text(verbatim: serverSectionTitle)
                    } footer: {
                        Text("server_playlist_append_footer")
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
            .alert(String(localized: "server_playlist_append_failed_title"), isPresented: appendErrorBinding) {
                Button(String(localized: "ok"), role: .cancel) {}
            } message: {
                Text(verbatim: appendErrorMessage ?? "")
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
                    if editablePlaylists.isEmpty && serverPlaylists.isEmpty {
                        ContentUnavailableView {
                            Label(String(localized: "no_playlists"), systemImage: "music.note.list")
                        }
                        .padding(.vertical, 48)
                    } else {
                        ForEach(editablePlaylists) { playlist in
                            macPlaylistRow(playlist)
                        }
                        if !serverPlaylists.isEmpty {
                            Text(verbatim: serverSectionTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PMColor.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, editablePlaylists.isEmpty ? 0 : 10)
                                .padding(.bottom, 2)
                            ForEach(serverPlaylists) { playlist in
                                macPlaylistRow(playlist)
                            }
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
        .alert(String(localized: "server_playlist_append_failed_title"), isPresented: appendErrorBinding) {
            Button(String(localized: "ok"), role: .cancel) {}
        } message: {
            Text(verbatim: appendErrorMessage ?? "")
        }
    }

    private func macPlaylistRow(_ playlist: Playlist) -> some View {
        let isAdded = library.contains(songID: song.id, inPlaylist: playlist.id)
        let count = library.songCount(forPlaylist: playlist.id)

        return Button {
            guard isEditablePlaylist(playlist.id) else {
                appendToServerPlaylist(playlist)
                return
            }
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

                if appendingPlaylistID == playlist.id {
                    ProgressView().controlSize(.small)
                } else if isAdded {
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
                    let count = library.songCount(forPlaylist: playlist.id)
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

    @ViewBuilder
    private func serverPlaylistRow(playlist: Playlist) -> some View {
        let isAdded = library.contains(songID: song.id, inPlaylist: playlist.id)
        Button {
            appendToServerPlaylist(playlist)
        } label: {
            HStack {
                PlaylistArtworkView(playlist: playlist, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.body)
                    Text("\(library.songCount(forPlaylist: playlist.id)) \(String(localized: "songs_count"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if appendingPlaylistID == playlist.id {
                    ProgressView()
                } else {
                    Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isAdded ? Color.accentColor : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded || appendingPlaylistID != nil)
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

// MARK: - Stable native More menu

/// Only state that can legitimately change the native menu's contents. Playback
/// progress and lyric scroll state are intentionally absent, so their frequent
/// updates cannot invalidate an already-presented menu.
/// `.sheet(item:)` 要一个 Identifiable; 书详情只认书的 id。
private struct NowPlayingBookRoute: Identifiable {
    let id: String
}

private struct NowPlayingMoreMenuSnapshot: Equatable {
    let songID: String?
    /// 正在播有声内容: 菜单收起音乐专属的项。
    let isSpokenWord: Bool
    /// 播客单集: 不在曲库里, 收起加歌单、改标签与歌词; 「歌曲信息」换成单集详情。
    let isPodcastEpisode: Bool
    let canOpenPodcastEpisode: Bool
    let canOpenPodcastShow: Bool
    /// 播客单集的「标为已播放」与「下载」,「播放页按钮 › 『更多』菜单」里能关。
    let showsPodcastMarkPlayed: Bool
    let showsPodcastDownload: Bool
    /// 有声内容的「生成文字稿」;没有这一项时为 nil(#314)。
    let transcriptGeneration: SpokenTranscriptGenerationMenuItem?
    let podcastShareURL: URL?
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
    /// 下面四项摆在页面上(「播放页按钮」)、此刻也看得见时为假,菜单里不再重复。
    let showsAddToPlaylist: Bool
    let showsCastAction: Bool
    let showsSleepTimer: Bool
    let showsPlaybackRate: Bool
    let castingRendererName: String?
    let isSleepTimerActive: Bool
    let lyricsFontScale: Double
    /// 译文行自己的字号;0 = 跟原文(#320)。
    let lyricsTranslationFontScale: Double
    /// 有译文可看(开着翻译,或歌词自带译文)时才给「译文字号」。
    let showsCompanionFontSize: Bool
    /// 有声内容有文字稿时,「文字稿时间」调的是这一集 / 这本书那一层;nil 时不给(#320)。
    let transcriptOffsetItemKey: String?
    let transcriptOffsetItemDelay: TimeInterval
    let canChangePlaybackRate: Bool
    let showsEqualizer: Bool
    /// 高保真直通的图里没有均衡器。
    let isEqualizerBypassed: Bool
    let playbackRate: Float
    let isLyricsTranslationEnabled: Bool
    let lyricsTranslationMode: LyricsTranslationMode
    /// 这个地区有智能服务时菜单里才给「智能翻译」。
    let offersSmartLyricsTranslation: Bool
    /// 填好了百度翻译(或正选着它)时菜单里才给「百度翻译」,没用它的人菜单里不多一项(#320)。
    let offersBaiduLyricsTranslation: Bool
    /// 这首歌词自带译文时才给「显示歌词自带的译文」。
    let lyricsHaveBundledTranslations: Bool
    let showsBundledLyricsTranslations: Bool
    /// 页面上点不到、要在菜单里补上的(「播放页按钮」里没摆出来的心形、歌词、队列、随机、循环,
    /// 以及手机横屏右栏窄到让出来的两端)。
    let fallbackActions: [NowPlayingControlAction]
    /// 有声书、播客页上藏起来的入口。
    let spokenFallbackActions: [SpokenWordMenuFallback]
    let isShowingLyrics: Bool
    let isShuffleEnabled: Bool
    let repeatMode: RepeatMode
    let isMedleyActive: Bool
    let canStartMedley: Bool
    let canStartKaraoke: Bool
    let medleyPlayQueueTitle: String
    let colorScheme: ColorScheme
    let colorSchemeContrast: ColorSchemeContrast
    /// iPhone Duo 竖栏那一列放不下时收进这里的按钮。
    let columnOverflow: NowPlayingBarColumnOverflow
    let isCurrentLiked: Bool
    /// 曲库里的音乐才能标「不喜欢」(#193)。
    let canDislike: Bool
    let isCurrentDisliked: Bool
    /// 能设播放时间段的当前歌曲(整首);有声内容、Apple Music、电台为 nil。
    let playbackRangeSong: Song?
    /// 下面几项在「播放页按钮 › 『更多』菜单」里可以关掉(#198)。
    let showsScrape: Bool
    let showsSimilarSongs: Bool
    let showsTagEditor: Bool
    let showsLyricsEditor: Bool
    let showsSongInfo: Bool
    let showsLyricsMotion: Bool
    /// 原生全屏不用「歌词动效」，菜单里那一项要写明。
    let fullscreenEffectIsNative: Bool
    /// 竖屏原生全屏里现在是封面那一面还是歌词那一面;不在那里时为 nil,菜单不给切换。
    let immersiveShowsArtwork: Bool?
}

/// 有声内容的目录、全屏文字稿两个弹出页和文字稿偏移的通知。单独成一个修饰:播放页那条修饰链
/// 已经长到编译器推断不过来,别再往上加(#320)。
private struct NowPlayingSpokenWordTextPresentations: ViewModifier {
    @Binding var showChapterList: Bool
    @Binding var contentsRequestedTab: SpokenWordContentsView.Tab?
    @Binding var showsTranscriptReader: Bool
    let player: AudioPlayerService
    /// 全屏文字稿读的那份,打开时才算。
    let transcriptReaderLines: () -> [LyricLine]
    /// 各行译文,全屏文字稿的「双语」「只看译文」用(#320)。
    let transcriptTranslations: () -> [String: String]
    let onTranscriptOffsetChange: () -> Void
    /// 「生成文字稿」打开给哪一集(#314)。
    @Binding var transcriptGenerationSong: Song?
    let intelligence: MusicIntelligenceService

    func body(content: Content) -> some View {
        content
            .sheet(item: $transcriptGenerationSong) { song in
                SpokenTranscriptGenerationSheet(song: song, dismissesOnStart: true)
                    .environment(intelligence)
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    #endif
                    .playerPresentationColorScheme()
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseTranscriptOffsetDidChange)) { _ in
                onTranscriptOffsetChange()
            }
            .sheet(isPresented: $showChapterList) {
                SpokenWordContentsView(requestedTab: $contentsRequestedTab)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .playerPresentationColorScheme()
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showsTranscriptReader) {
                // 全屏文稿自己定深浅,不套 `playerPresentationColorScheme`。左右扫、顶栏下拉时整页跟着手指走开,
                // 露出底下的播放页。
                transcriptReader
                    .modifier(SpokenWordTranscriptInteractiveDismiss(isPresented: $showsTranscriptReader))
            }
            #else
            .sheet(isPresented: $showsTranscriptReader) {
                transcriptReader
            }
            #endif
    }

    private var transcriptReader: SpokenWordTranscriptReader {
        SpokenWordTranscriptReader(
            lines: transcriptReaderLines(),
            title: player.currentSong?.title ?? "",
            player: player,
            translatedTextByLineID: transcriptTranslations()
        )
    }
}

/// 「播放页按钮」里一颗按钮放在哪种地方:各处原来的画法不同,照各自原样画。
private enum NowPlayingControlStyle: Equatable {
    /// 竖屏最下面那排:只有图标,三级灰。
    case bar
    /// iPad 横屏左栏最下面那排:只有图标,二级灰。
    case wideBar
    /// 传输键两端:和随机、循环同一种写法,开着时垫强调色的圆。
    case edge
    /// 歌名旁:和心形同一种写法。
    case header
    /// 手机横屏顶上那排玻璃圆钮。
    case glass
    /// iPhone Duo 竖栏那一列,按钮边长随那一列缩放。
    case column(CGFloat)
    /// 全屏效果页右上角:和效果页自己的玻璃圆钮同一种画法,颜色跟那一页的墨色。
    case effectGlass(ink: Color)
    /// 全屏效果页底部播放胶囊里播放键两侧:和上一首、下一首同一种画法。
    case effectPill(ink: Color)

    /// 点队列键直接弹出半屏的「接下来播放」,不走分栏右栏。
    var opensQueueSheet: Bool {
        switch self {
        case .wideBar, .effectGlass, .effectPill: true
        default: false
        }
    }

    /// 按钮自己的点按区;玻璃圆钮与竖栏那一列由图标自己定大小。
    var fixedFrame: CGFloat? {
        switch self {
        case .bar, .wideBar, .edge, .header: 44
        case .effectPill: 38
        case .glass, .column, .effectGlass: nil
        }
    }
}

/// 一颗可换按钮此刻的样子。
private struct NowPlayingControlFace {
    var symbol: String
    var label: String
    var isActive = false
    /// 开着时的颜色;nil 用强调色。
    var activeTint: Color?
    /// 读屏要读「开 / 关」的开关类按钮。
    var isToggle = false
    /// 没有正在放的歌时置灰。
    var requiresSong = false
}

/// 页面上那颗按钮因模式暂时用不了时点出来的说明;能一键解决的(切到音效输出)给按钮。
private struct NowPlayingControlNotice: Equatable {
    var title: String
    var message: String
    var offersEffectsOutput = false
}

/// 同一份存储串只解一次:播放页每次重画都要读好几遍配置。
@MainActor
private enum NowPlayingControlLayoutCache {
    private static var storage = ""
    private static var layout = NowPlayingControlLayout.default

    static func layout(for storage: String) -> NowPlayingControlLayout {
        if storage != Self.storage {
            Self.storage = storage
            layout = NowPlayingControlLayout.decode(storage)
        }
        return layout
    }

    private static var lyricsLayoutKey: (cover: String, lyrics: String)?
    private static var lyricsLayout = NowPlayingControlLayout.default

    /// `lyricsPageStorage` 不为 nil 时是看歌词那一页:单独摆了按钮就换上那一组。
    static func layout(for storage: String, lyricsPageStorage: String?) -> NowPlayingControlLayout {
        let cover = layout(for: storage)
        guard let lyricsPageStorage else { return cover }
        if lyricsLayoutKey?.cover != storage || lyricsLayoutKey?.lyrics != lyricsPageStorage {
            lyricsLayoutKey = (storage, lyricsPageStorage)
            lyricsLayout = lyricsPageControls(for: lyricsPageStorage).resolvedLayout(cover: cover)
        }
        return lyricsLayout
    }

    private static var lyricsPage: (storage: String, controls: NowPlayingLyricsPageControls)?

    static func lyricsPageControls(for storage: String) -> NowPlayingLyricsPageControls {
        if let lyricsPage, lyricsPage.storage == storage { return lyricsPage.controls }
        let controls = NowPlayingLyricsPageControls.decode(storage)
        lyricsPage = (storage, controls)
        return controls
    }

    private static var immersiveLyrics: (storage: String, controls: NowPlayingImmersiveLyricsControls)?

    static func immersiveLyricsControls(for storage: String) -> NowPlayingImmersiveLyricsControls {
        if let immersiveLyrics, immersiveLyrics.storage == storage { return immersiveLyrics.controls }
        let controls = NowPlayingImmersiveLyricsControls.decode(storage)
        immersiveLyrics = (storage, controls)
        return controls
    }

    private static var effectPlayer: (storage: String, controls: NowPlayingEffectPlayerControls)?

    static func effectPlayerControls(for storage: String) -> NowPlayingEffectPlayerControls {
        if let effectPlayer, effectPlayer.storage == storage { return effectPlayer.controls }
        let controls = NowPlayingEffectPlayerControls.decode(storage)
        effectPlayer = (storage, controls)
        return controls
    }

    private static var radio: (storage: String, layout: NowPlayingRadioControlLayout)?

    static func radioLayout(for storage: String) -> NowPlayingRadioControlLayout {
        if let radio, radio.storage == storage { return radio.layout }
        let layout = NowPlayingRadioControlLayout.decode(storage)
        radio = (storage, layout)
        return layout
    }

    private static var spokenWord: [SpokenWordPlayerKind: (storage: String, layout: SpokenWordControlLayout)] = [:]

    static func spokenWordLayout(for storage: String, kind: SpokenWordPlayerKind) -> SpokenWordControlLayout {
        if let cached = spokenWord[kind], cached.storage == storage { return cached.layout }
        let layout = SpokenWordControlLayout.decode(storage, kind: kind)
        spokenWord[kind] = (storage, layout)
        return layout
    }
}

/// iPhone Duo 竖栏那一列按钮放不下时收进「更多」的几颗(按收走的先后:锁、全屏效果、喜欢)。
struct NowPlayingBarColumnOverflow: Equatable {
    var lock = false
    var effect = false
    var like = false

    var isEmpty: Bool { !lock && !effect && !like }
}

/// Keeps the existing SwiftUI `Menu` interaction and visual design, while using
/// an equatable update boundary to stop unrelated parent updates from rebuilding
/// the menu hierarchy and resetting its internal scroll position.
private struct NowPlayingMoreMenu: View, @MainActor Equatable {
    let snapshot: NowPlayingMoreMenuSnapshot
    @Binding var lyricsFontScale: Double
    @Binding var lyricsTranslationFontScale: Double
    @Binding var playbackRate: Float
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    let immersiveChrome: Bool
    /// 只在 `immersiveChrome` 为真时起作用：圆钮底用固定深色还是跟随明暗外观。
    let chromeGlass: NowPlayingChromeGlass
    /// 摆进有声书、播客那几格时跟旁边的键同样的字号、颜色与高度。
    var plainLabel: NowPlayingMoreMenuPlainLabel?
    /// 同一个实例一直不变,不进相等比较;子菜单自己读它的状态。
    let equalizer: EqualizerService

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
    let onOpenPodcastShow: () -> Void
    let onMarkPodcastPlayed: () -> Void
    let onGenerateTranscript: () -> Void
    let onShowChapterList: () -> Void
    let onOpenInAppleMusic: () -> Void
    let onShare: () -> Void
    let onShowCastPicker: () -> Void
    let onToggleLike: () -> Void
    let onToggleLyrics: () -> Void
    let onOpenQueue: () -> Void
    let onAddBookmark: () -> Void
    let onOpenUpNext: () -> Void
    let onToggleDislike: () -> Void
    let onEditPlaybackRange: () -> Void
    let onShowEffectPicker: () -> Void
    let onLockControls: () -> Void
    /// nil 表示关闭歌词翻译;选了方式就按这个方式打开。
    let onSelectLyricsTranslation: (LyricsTranslationMode?) -> Void
    let onSetBundledLyricsTranslationsShown: (Bool) -> Void
    let onToggleImmersiveArtwork: () -> Void
    let onShowSleepTimer: () -> Void
    let onAdjustEqualizer: () -> Void
    let onShowEqualizerBypassNotice: () -> Void
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
            && lhs.plainLabel == rhs.plainLabel
    }

    /// 文字稿时间:这一集 / 这本书往前、往后挪。iPhone 上点了菜单不收起,能连着点几下(#320)。
    private func transcriptOffsetMenu(key: String, delay: TimeInterval) -> some View {
        let store = SpokenWordTranscriptOffsetStore.shared
        let step = SpokenWordTranscriptOffsetPolicy.step
        return Menu {
            Section {
                Button {
                    store.setItemDelay(delay - step, forKey: key)
                } label: {
                    Label("transcript_offset_earlier_step", systemImage: "backward")
                }
                Button {
                    store.setItemDelay(delay + step, forKey: key)
                } label: {
                    Label("transcript_offset_later_step", systemImage: "forward")
                }
            }
            Section {
                Button {
                    store.setItemDelay(delay - 5, forKey: key)
                } label: {
                    Label("transcript_offset_earlier_coarse", systemImage: "backward.end")
                }
                Button {
                    store.setItemDelay(delay + 5, forKey: key)
                } label: {
                    Label("transcript_offset_later_coarse", systemImage: "forward.end")
                }
            }
            if delay != 0 {
                Button("transcript_offset_reset") {
                    store.setItemDelay(0, forKey: key)
                }
            }
        } label: {
            Label {
                Text("transcript_offset_title")
                Text(verbatim: SpokenWordTranscriptOffsetRow.valueText(delay))
            } icon: {
                Image(systemName: "arrow.left.arrow.right")
            }
        }
        #if os(iOS)
        .menuActionDismissBehavior(.disabled)
        #endif
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
        [
            snapshot.showsFullScreenAction,
            snapshot.immersiveShowsArtwork != nil,
            snapshot.canShare,
            snapshot.canDeleteSourceFile,
        ]
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

    @ViewBuilder
    private func fallbackItem(_ action: NowPlayingControlAction) -> some View {
        switch action {
        case .like:
            Button(action: onToggleLike) {
                if snapshot.isCurrentLiked {
                    Label(String(localized: "a11y_unlike"), systemImage: "heart.fill")
                } else {
                    Label(String(localized: "a11y_like"), systemImage: "heart")
                }
            }
            .disabled(!snapshot.hasSong)
        case .lyrics:
            Button(action: onToggleLyrics) {
                if snapshot.isShowingLyrics {
                    Label(String(localized: "a11y_close_lyrics"), systemImage: "photo")
                } else {
                    Label(String(localized: "a11y_open_lyrics"), systemImage: "quote.bubble")
                }
            }
        case .queue:
            Button(action: onOpenQueue) {
                Label(String(localized: "a11y_queue"), systemImage: "list.bullet")
            }
        case .shuffle:
            Button(action: onToggleShuffle) {
                Label(
                    String(localized: "shuffle"),
                    systemImage: snapshot.isShuffleEnabled ? "shuffle.circle.fill" : "shuffle"
                )
            }
        case .repeatMode:
            Button(action: onCycleRepeatMode) {
                Label(
                    String(localized: "repeat"),
                    systemImage: Self.repeatSymbol(for: snapshot.repeatMode)
                )
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func spokenFallbackItem(_ item: SpokenWordMenuFallback) -> some View {
        switch item {
        case .like:
            fallbackItem(.like)
        case .transcript:
            Button(action: onToggleLyrics) {
                if snapshot.isShowingLyrics {
                    Label(String(localized: "a11y_close_lyrics"), systemImage: "text.bubble.fill")
                } else {
                    Label(String(localized: "spoken_word_text_tab"), systemImage: "text.bubble")
                }
            }
        case .bookmark:
            Button(action: onAddBookmark) {
                Label(String(localized: "spoken_word_add_bookmark"), systemImage: "bookmark")
            }
            .disabled(!snapshot.hasSong)
        case .upNext:
            Button(action: onOpenUpNext) {
                Label(String(localized: "up_next"), systemImage: "list.bullet")
            }
        }
    }

    var body: some View {
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

                // 竖屏原生全屏里「全屏」那一格换成封面 / 歌词两面的切换(#311)。
                if let showsArtwork = snapshot.immersiveShowsArtwork {
                    PMMenuQuickActionButton(
                        shortKey: showsArtwork ? "immersive_show_lyrics_short" : "immersive_show_artwork_short",
                        fullKey: showsArtwork ? "immersive_show_lyrics" : "immersive_show_artwork",
                        systemImage: showsArtwork ? "quote.bubble" : "photo",
                        action: onToggleImmersiveArtwork
                    )
                    .disabled(!snapshot.hasSong)
                }

                if snapshot.canShare {
                    if let url = snapshot.podcastShareURL {
                        ShareLink(item: url) {
                            Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                        }
                    } else {
                        // 歌词海报也从这里进：分享页里有一项「分享歌词」。
                        Button(action: onShare) {
                            Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if snapshot.showsAddToPlaylist, promotesAddToPlaylist, !snapshot.isPodcastEpisode {
                    addToPlaylistButton(inQuickRow: true)
                }

                if snapshot.canDeleteSourceFile {
                    Button(role: .destructive, action: onDelete) {
                        Label(String(localized: "delete"), systemImage: "trash")
                    }
                    .disabled(!snapshot.hasSong)
                }
            }

            if snapshot.isPodcastEpisode, snapshot.showsPodcastMarkPlayed || snapshot.showsPodcastDownload {
                // 听播客最常做的两件事:这一集算听完(有下一集就接着放),和存下来离线听。
                Section {
                    if snapshot.showsPodcastMarkPlayed {
                        Button(action: onMarkPodcastPlayed) {
                            Label(String(localized: "podcast_mark_played"), systemImage: "checkmark.circle")
                        }
                    }
                    if snapshot.showsPodcastDownload {
                        PodcastPlayerDownloadMenuItem()
                    }
                }
            }

            if let generation = snapshot.transcriptGeneration {
                Section {
                    Button(action: onGenerateTranscript) {
                        Label {
                            Text(generation.titleKey)
                            if let detail = generation.detail {
                                Text(verbatim: detail)
                            }
                        } icon: {
                            Image(systemName: "waveform.and.mic")
                        }
                    }
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
                        // 时长直接缀在标题后，一行放下，不占副标题行。
                        Button(action: onStartMedley) {
                            Label(snapshot.medleyPlayQueueTitle, systemImage: "rectangle.stack.badge.play")
                        }
                    }
                }
            }

            if !snapshot.columnOverflow.isEmpty {
                // iPhone Duo 竖栏那一列放不下时收进来的按钮。
                Section {
                    if snapshot.columnOverflow.like {
                        Button(action: onToggleLike) {
                            if snapshot.isCurrentLiked {
                                Label(String(localized: "a11y_unlike"), systemImage: "heart.fill")
                            } else {
                                Label(String(localized: "a11y_like"), systemImage: "heart")
                            }
                        }
                        .disabled(!snapshot.hasSong)
                    }
                    if snapshot.columnOverflow.effect {
                        Button(action: onShowEffectPicker) {
                            Label(String(localized: "fullscreen_effect_settings_title"), systemImage: "viewfinder.rectangular")
                        }
                    }
                    if snapshot.columnOverflow.lock {
                        Button(action: onLockControls) {
                            Label(String(localized: "immersive_lock_controls"), systemImage: "lock")
                        }
                    }
                }
            }

            if !snapshot.fallbackActions.isEmpty || !snapshot.spokenFallbackActions.isEmpty {
                Section {
                    ForEach(snapshot.fallbackActions, id: \.self) { action in
                        fallbackItem(action)
                    }
                    ForEach(snapshot.spokenFallbackActions, id: \.self) { item in
                        spokenFallbackItem(item)
                    }
                }
            }

            Section {
                if snapshot.showsAddToPlaylist, !promotesAddToPlaylist, !snapshot.isPodcastEpisode {
                    addToPlaylistButton(inQuickRow: false)
                }

                if !snapshot.isSpokenWord, snapshot.showsScrape {
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

                if !snapshot.isSpokenWord, snapshot.showsSimilarSongs {
                    Button(action: onShowSimilarSongs) {
                        Label(String(localized: "similar_songs"), systemImage: "sparkles")
                    }
                    .disabled(!snapshot.hasSong)
                }

                if snapshot.canDislike {
                    // 不喜欢(#193): 记下来并切到下一首; 已经不喜欢时再点只撤销。
                    // 心形保持「喜欢 / 取消喜欢」两态, 不叠第三态。
                    Button(action: onToggleDislike) {
                        if snapshot.isCurrentDisliked {
                            Label(String(localized: "song_undislike"), systemImage: "hand.thumbsdown.fill")
                        } else {
                            Label(String(localized: "song_dislike"), systemImage: "hand.thumbsdown")
                        }
                    }
                }

                // 播放时间段:设过时是开关加「编辑」,没设过时是「设置播放时间段…」。
                if let rangeSong = snapshot.playbackRangeSong {
                    SongPlaybackRangeMenuItems(song: rangeSong, onEdit: onEditPlaybackRange)
                }

                if !snapshot.isAppleMusicMode, !snapshot.isPodcastEpisode {
                    if snapshot.showsTagEditor {
                        Button(action: onEditTags) {
                            Label(String(localized: "tag_editor_menu"), systemImage: "tag")
                        }
                        .disabled(!snapshot.hasSong)
                    }

                    if snapshot.showsLyricsEditor {
                        Button(action: onEditLyrics) {
                            Label(String(localized: "lyrics_editor_menu"), systemImage: "quote.bubble")
                        }
                        .disabled(!snapshot.hasSong)
                    }
                }
            }

            Section {
                if snapshot.isPodcastEpisode {
                    if snapshot.canOpenPodcastEpisode {
                        Button(action: onOpenBook) {
                            Label(String(localized: "podcast_player_episode_details"), systemImage: "info.circle")
                        }
                    }
                    if snapshot.canOpenPodcastShow {
                        Button(action: onOpenPodcastShow) {
                            Label(String(localized: "podcast_go_to_show"), systemImage: "rectangle.stack")
                        }
                    }
                } else if snapshot.showsSongInfo {
                    Button(action: onShowSongInfo) {
                        Label(String(localized: "song_info"), systemImage: "info.circle")
                    }
                    .disabled(!snapshot.hasSong)
                }

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

            if snapshot.showsCastAction {
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

                    if snapshot.showsCompanionFontSize {
                        Picker(selection: $lyricsTranslationFontScale) {
                            Text("lyrics_translation_font_follow").tag(0.0)
                            Text("lyrics_font_small").tag(0.85)
                            Text("lyrics_font_medium").tag(1.0)
                            Text("lyrics_font_large").tag(1.2)
                            Text("lyrics_font_xlarge").tag(1.5)
                        } label: {
                            Label(String(localized: "lyrics_translation_font_size"), systemImage: "character.textbox")
                        }
                        .pickerStyle(.menu)
                    }

                    if let offsetKey = snapshot.transcriptOffsetItemKey {
                        transcriptOffsetMenu(key: offsetKey, delay: snapshot.transcriptOffsetItemDelay)
                    }

                    // 关闭 / 系统翻译 / 智能翻译直接在这里选,不用先去设置里找翻译方式。
                    Menu {
                        Picker(selection: Binding<LyricsTranslationMode?>(
                            get: {
                                guard snapshot.isLyricsTranslationEnabled else { return nil }
                                return snapshot.lyricsTranslationMode == .intelligentWithSystemFallback
                                    && !snapshot.offersSmartLyricsTranslation
                                    ? .system : snapshot.lyricsTranslationMode
                            },
                            set: { onSelectLyricsTranslation($0) }
                        )) {
                            Text("lyrics_translation_mode_off").tag(LyricsTranslationMode?.none)
                            Text("lyrics_translation_mode_system")
                                .tag(LyricsTranslationMode?.some(.system))
                            if snapshot.offersSmartLyricsTranslation {
                                Text("lyrics_translation_mode_smart")
                                    .tag(LyricsTranslationMode?.some(.intelligentWithSystemFallback))
                            }
                            if snapshot.offersBaiduLyricsTranslation {
                                Text("lyrics_translation_mode_baidu")
                                    .tag(LyricsTranslationMode?.some(.baidu))
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.inline)

                        if snapshot.lyricsHaveBundledTranslations {
                            Section {
                                Toggle(isOn: Binding(
                                    get: { snapshot.showsBundledLyricsTranslations },
                                    set: { onSetBundledLyricsTranslationsShown($0) }
                                )) {
                                    Text("lyrics_bundled_translation_shown")
                                }
                            }
                        }
                    } label: {
                        Label(
                            String(localized: "lyrics_translation_title"),
                            systemImage: snapshot.isLyricsTranslationEnabled
                                ? "character.bubble.fill"
                                : "character.bubble"
                        )
                    }
                }
            }

            Section {
                if !snapshot.isSpokenWord, snapshot.showsLyricsMotion {
                    // 系统菜单里置灰的项点不动；原生全屏下照样能拨（换了效果就生效），副标题写明现在不起作用。
                    Toggle(isOn: $lyricsMotionEnabled) {
                        Label {
                            Text("immersive_lyrics_motion_title")
                            if snapshot.fullscreenEffectIsNative {
                                Text("immersive_lyrics_motion_native_note")
                            }
                        } icon: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        }
                    }
                }

                if snapshot.showsSleepTimer {
                    Button(action: onShowSleepTimer) {
                        Label(
                            snapshot.isSleepTimerActive
                                ? String(localized: "sleep_timer_active")
                                : String(localized: "sleep_timer"),
                            systemImage: snapshot.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz"
                        )
                    }
                }

                if snapshot.showsEqualizer {
                    NowPlayingEqualizerMenu(
                        eq: equalizer,
                        isBypassed: snapshot.isEqualizerBypassed,
                        onAdjust: onAdjustEqualizer,
                        onShowBypassNotice: onShowEqualizerBypassNotice
                    )
                }

                if !snapshot.isAppleMusicMode, snapshot.showsPlaybackRate {
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
            menuLabel
        }
    }

    @ViewBuilder
    private var menuLabel: some View {
        if immersiveChrome {
            chromeMenuLabel
        } else if let plainLabel, let tile = plainLabel.tile {
            SpokenWordTileFace(
                layout: tile.layout,
                tileHeight: tile.tileHeight,
                labelStyle: tile.labelStyle,
                palette: SpokenWordPlayerPalette(
                    primary: plainLabel.tint,
                    secondary: tile.secondary,
                    tertiary: tile.secondary,
                    accent: plainLabel.tint,
                    tileFill: tile.tileFill
                )
            ) {
                Image(systemName: "ellipsis")
                    .font(plainLabel.font)
                    .foregroundStyle(plainLabel.tint)
            } caption: {
                Text("more")
            }
        } else if let plainLabel {
            Image(systemName: "ellipsis")
                .font(plainLabel.font)
                .foregroundStyle(plainLabel.tint)
                .frame(width: 44, height: plainLabel.height)
                .contentShape(Rectangle())
        } else {
            // 只有图标,和隔空播放键一样不垫圆底。
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(appearance.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
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

/// 「更多」里的均衡器子菜单:第一项「关闭」,往下是预设(与均衡器页的卡片同序),
/// 最后一项打开完整的均衡器页。自己读 `EqualizerService`,开关、换预设只重画这一小块,
/// 不经过外层那份菜单快照。
private struct NowPlayingEqualizerMenu: View {
    let eq: EqualizerService
    let isBypassed: Bool
    let onAdjust: () -> Void
    let onShowBypassNotice: () -> Void

    var body: some View {
        if isBypassed {
            // 高保真直通不经过均衡器。系统菜单里置灰的项点不动,所以这里不置灰:
            // 副标题写明原因,点了弹说明,可以一键切到音效输出。
            Button(action: onShowBypassNotice) { label }
        } else {
            presetMenu
        }
    }

    private var presetMenu: some View {
        Menu {
            Section {
                Picker(selection: Binding(
                    get: { eq.menuSelectionID },
                    set: { eq.selectFromMenu($0) }
                )) {
                    Text("eq_menu_off")
                        .tag(EqualizerService.menuOffID)
                    ForEach(eq.menuPresets) { preset in
                        Text(verbatim: preset.localizedName)
                            .tag(preset.id)
                    }
                } label: {
                    Text("equalizer")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                Button(action: onAdjust) {
                    Label(String(localized: "eq_menu_adjust"), systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            label
        }
    }

    private var label: some View {
        Label {
            Text("equalizer")
            Text(verbatim: isBypassed
                ? String(localized: "eq_menu_high_fidelity_unavailable")
                : eq.menuSelectionTitle)
        } icon: {
            Image(systemName: "slider.vertical.3")
        }
    }
}

// MARK: - LyricsScrollView (隔离的歌词渲染子 view)

/// 歌词各行的竖排容器:行数多时惰性排版,只建屏幕附近的行(见 `LyricsScrollView.usesLazyRows`)。
private struct LyricsRowStack<Content: View>: View {
    let isLazy: Bool
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if isLazy {
            LazyVStack(alignment: .leading, spacing: spacing) { content }
        } else {
            VStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}

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
    /// 选了智能翻译,但它此刻发不出去(差同意、差允许发送或没有服务),改用了系统翻译。
    case intelligentNotReady(LyricsAITranslationReadiness)
    case systemPreparationRequired
    case systemUnavailable
    /// The offline model is translating pairs the system does not offer.
    case localTranslating
    /// Those pairs need the offline model, which is not downloaded yet.
    case localModelRequired
    /// 百度翻译在翻(#320)。
    case baiduLoading
    case baiduSuccess
    /// 选了百度翻译却没用上(没填好、译不成这种语言或请求出错),改用了系统翻译。
    case baiduNotReady(BaiduTranslateIssue)
}

extension LyricsAITranslationReadiness {
    /// 歌词页提示用的一句:智能翻译差哪一步,这次改用了系统翻译。
    var systemFallbackNotice: String {
        switch self {
        case .needsBuiltInConsent:
            String(localized: "lyrics_translation_ai_notice_builtin_consent")
        case .needsRemoteConsent:
            String(localized: "lyrics_translation_ai_notice_remote_consent")
        case .noService:
            String(localized: "lyrics_translation_ai_notice_no_service")
        case .ready, .regionUnavailable:
            String(localized: "lyrics_translation_ai_system_fallback")
        }
    }
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

/// 竖屏封面模式进度条上面那几行歌词: 行数与字号按「播放页样式与按钮」里的设置。
/// 字号只在这一层读, 拖字号滑块不牵动整个播放页重算。
private struct NowPlayingArtworkLyricPreview: View {
    let lyrics: [LyricLine]
    let player: AudioPlayerService
    let songID: String?
    let lyricsRevision: UInt
    let isSceneActive: Bool
    let appearance: NowPlayingAppearance
    /// 定好的行数; nil 时是「自动」: 这一层铺在歌名下那段空白上, 下面紧接着 `NowPlayingArtworkLyricSlot`
    /// 那一格。歌词从那一格的底边往上排, 顶上和歌名之间至少留 `artworkLyricHeadingGap`, 能放几行放几行。
    let lineCount: Int?
    let onTap: () -> Void

    @AppStorage(PlayerAppearancePreferences.artworkLyricsFontScaleKey)
    private var fontScale = PlayerAppearancePreferences.artworkLyricsFontScaleByDefault
    /// `.callout` 的字号, 跟着系统字体大小走。
    @ScaledMetric(relativeTo: .callout) private var baseFontSize: CGFloat = 16

    var body: some View {
        let fontSize = NowPlayingView.artworkLyricFontSize(base: baseFontSize, scale: fontScale)
        let lineHeight = NowPlayingView.artworkLyricLineHeight(fontSize: fontSize)
        if let lineCount {
            preview(rowCount: lineCount, fontSize: fontSize, lineHeight: lineHeight)
        } else {
            GeometryReader { proxy in
                // 空白和下面那一格之间隔着同样的 `artworkLyricHeadingGap`: 整块往下错开这么多,
                // 顶上和歌名之间留出间隔, 底边正好落在那一格的底边。
                let height = proxy.size.height + lineHeight
                preview(
                    rowCount: NowPlayingView.artworkLyricRowCount(fitting: height, lineHeight: lineHeight),
                    fontSize: fontSize,
                    lineHeight: lineHeight
                )
                .frame(width: proxy.size.width, height: height, alignment: .bottom)
                .offset(y: NowPlayingView.artworkLyricHeadingGap)
            }
        }
    }

    private func preview(rowCount: Int, fontSize: CGFloat, lineHeight: CGFloat) -> some View {
        NowPlayingLyricPreview(
            lyrics: lyrics,
            player: player,
            songID: songID,
            lyricsRevision: lyricsRevision,
            isSceneActive: isSceneActive,
            tint: appearance.primary,
            statusTint: appearance.tertiary,
            font: .system(size: fontSize),
            emphasizesLine: true,
            lineHeight: lineHeight,
            rowCount: rowCount,
            pastOpacity: appearance.pastLyricOpacity,
            upcomingOpacity: appearance.futureLyricOpacity,
            onTap: onTap
        )
    }
}

/// 封面下的歌词选了「自动」时进度条上面那一格: 和「一行」时那一句同一位置、同一高度, 歌词从这一格往上
/// 排进歌名下的空白(见 `NowPlayingArtworkLyricPreview`)。版面靠这一格定高, 才和「一行」时一样排得下。
struct NowPlayingArtworkLyricSlot: View {
    @AppStorage(PlayerAppearancePreferences.artworkLyricsFontScaleKey)
    private var fontScale = PlayerAppearancePreferences.artworkLyricsFontScaleByDefault
    @ScaledMetric(relativeTo: .callout) private var baseFontSize: CGFloat = 16

    var body: some View {
        Color.clear
            .frame(height: NowPlayingView.artworkLyricLineHeight(
                fontSize: NowPlayingView.artworkLyricFontSize(base: baseFontSize, scale: fontScale)
            ))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 播放页封面模式里跟着播放走的那一行歌词: 手机横屏普通模式右栏的「当前歌词行」;
/// 竖屏进度条上面那一行(#69 加的,设置里打开;#318 起默认只放一行,设置里可以放几行)。
///
/// 放什么由 `NowPlayingLyricPreviewPolicy` 按播放时间定: 第一句开唱前不提前露出它,
/// 前奏够长时轮换几句提示; 唱的时候只有当前这一句; 间奏里是间奏标签; 下一句开唱前
/// 换成跳两下的三个点。几种状态占同一个定高的格子, 换来换去下面的进度条不挪。
/// 多行时正在唱的那句(或这几种提示)停在固定一格, 上下是唱过的和接下来的, 换句时整列上移。
///
/// 当前行得跟着播放位置走, 但 `NowPlayingView.body` 是七千行规模的大 body,
/// 不能让它跟着时间每几百毫秒重算一遍。所以照 `LyricsScrollView` 的办法把
/// 时间读取整个关在这棵小子树里: 外面只传进不随播放进度变化的入参, 显示状态
/// 是本 view 自己的 `@State`。
private struct NowPlayingLyricPreview: View {
    let lyrics: [LyricLine]
    let player: AudioPlayerService
    let songID: String?
    let lyricsRevision: UInt
    let isSceneActive: Bool
    let tint: Color
    /// 前奏提示、间奏标签与心跳点的颜色。
    let statusTint: Color
    var font: Font = .callout
    /// 正在唱的那句加粗(竖屏);横屏照常字重。
    var emphasizesLine = false
    let lineHeight: CGFloat
    /// 几行;大于 1 时唱过的、接下来的几句按这两个浓淡调淡(和歌词页一样)。
    var rowCount = 1
    var pastOpacity = 0.32
    var upcomingOpacity = 0.46
    let onTap: () -> Void

    @AppStorage(PlayerAppearancePreferences.showsLyricsInterludeKey)
    private var showsLyricsInterlude = PlayerAppearancePreferences.showsLyricsInterludeByDefault
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var display: NowPlayingLyricPreviewPolicy.Display = .empty
    @State private var nextChange: TimeInterval?
    /// 多行时每一格放什么;一行时不用。
    @State private var rows: [NowPlayingLyricPreviewPolicy.Row] = []

    /// 最长隔这么久看一次播放位置(拖动进度条、倍速之后靠它跟上)。离下一个变化点
    /// 更近时睡到那一刻, 换行、出现心跳点都准时。
    private static let maximumPollInterval: TimeInterval = 0.25
    private static let lookahead: TimeInterval = 0.25

    private struct FollowIdentity: Hashable {
        let songID: String?
        let lyricsRevision: UInt
        let isPlaying: Bool
        let isSceneActive: Bool
        let showsLyricsInterlude: Bool
        let rowCount: Int
    }

    private var hasSynchronizedLyrics: Bool {
        lyrics.contains { $0.isSynchronized }
    }

    private var followIdentity: FollowIdentity {
        FollowIdentity(
            songID: songID,
            lyricsRevision: lyricsRevision,
            isPlaying: player.isPlaying,
            isSceneActive: isSceneActive,
            showsLyricsInterlude: showsLyricsInterlude,
            rowCount: rowCount
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

    /// 换状态时整格淡入淡出;同一状态里内容变了(换了一句、换了一条提示)也算换。
    private var displayIdentity: String {
        switch display {
        case .empty: "empty"
        case .line(let index): "line-\(lyrics.indices.contains(index) ? lyrics[index].id : "\(index)")"
        case .intro(let message): "intro-\(message)"
        case .instrumental: "instrumental"
        case .anticipation(let window): "anticipation-\(window.nextLineStart)"
        }
    }

    var body: some View {
        Group {
            if rowCount > 1 {
                multiRowContent
            } else {
                ZStack(alignment: .leading) {
                    content
                        .id(displayIdentity)
                        .transition(.opacity)
                }
                .animation(.smooth(duration: 0.35, extraBounce: 0), value: displayIdentity)
            }
        }
        // 没有歌词时也占同样高度, 布局不会在有无歌词、几种状态之间上下跳。
        .frame(height: lineHeight * CGFloat(max(1, rowCount)), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: followIdentity) {
            update()
            guard hasSynchronizedLyrics, activityPolicy.shouldPollLyrics else { return }
            while !Task.isCancelled {
                let now = player.interpolatedTime()
                let untilChange = nextChange.map { $0 - now } ?? Self.maximumPollInterval
                let wait = min(max(untilChange, 0.02), Self.maximumPollInterval)
                do {
                    try await Task.sleep(for: .seconds(wait))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                update()
            }
        }
        .background {
            // 暂停时没有轮询, 拖动进度条后的新位置靠这个零尺寸观察者补上。
            LyricsPausedTimeObserver(
                player: player,
                isEnabled: hasSynchronizedLyrics && isSceneActive
            ) {
                update()
            }
        }
        .onChange(of: songID) { _, _ in
            apply(.init(display: .empty, nextChange: nil))
            if !rows.isEmpty { rows = [] }
        }
    }

    private struct RowItem: Identifiable {
        let id: String
        let row: NowPlayingLyricPreviewPolicy.Row
    }

    /// 句子按下标认, 换句时同一句从下一格挪到这一格; 提示那一格只有一个; 空格按位置认。
    private var rowItems: [RowItem] {
        rows.enumerated().map { position, row in
            switch row {
            case .line(let index, _): RowItem(id: "line-\(index)", row: row)
            case .status: RowItem(id: "status", row: row)
            case .blank: RowItem(id: "blank-\(position)", row: row)
            }
        }
    }

    /// 多行: 正在唱的满色, 唱过的、接下来的调淡, 字重都一样(换句时只变浓淡, 字不跳);
    /// 提示那一格照一行时的写法。
    private var multiRowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rowItems) { item in
                Group {
                    switch item.row {
                    case .line(let index, let role):
                        if lyrics.indices.contains(index) {
                            Text(verbatim: lyrics[index].text)
                                .font(emphasizesLine ? font.weight(.semibold) : font)
                                .foregroundStyle(tint)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .opacity(opacity(for: role))
                        }
                    case .status:
                        ZStack(alignment: .leading) {
                            content
                                .id(displayIdentity)
                                .transition(.opacity)
                        }
                    case .blank:
                        Color.clear
                    }
                }
                .frame(height: lineHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.45, extraBounce: 0), value: rows)
        .animation(.smooth(duration: 0.35, extraBounce: 0), value: displayIdentity)
    }

    private func opacity(for role: NowPlayingLyricPreviewPolicy.LineRole) -> Double {
        switch role {
        case .past: pastOpacity
        case .current: 1
        case .upcoming: upcomingOpacity
        }
    }

    @ViewBuilder
    private var content: some View {
        switch display {
        case .empty:
            Color.clear
        case .line(let index):
            if lyrics.indices.contains(index) {
                Text(verbatim: lyrics[index].text)
                    .font(emphasizesLine ? font.weight(.semibold) : font)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .intro(let message):
            Text(Self.introMessageKey(message))
                .font(font)
                .foregroundStyle(statusTint)
                .lineLimit(1)
                .truncationMode(.tail)
        case .instrumental:
            NowPlayingInstrumentalLabel(
                font: font,
                tint: statusTint,
                isAnimating: player.isPlaying && isSceneActive && !reduceMotion
            )
        case .anticipation(let window):
            LyricInterludeDots(
                isActive: true,
                isPlaying: player.isPlaying && isSceneActive,
                phase: {
                    LyricPlaybackPositionPolicy.phase(
                        of: window,
                        at: player.interpolatedTime(),
                        lookahead: Self.lookahead
                    )
                },
                tint: statusTint,
                restingOpacity: 0.5,
                dotSize: 6,
                spacing: 5
            )
            .padding(.leading, 2)
        }
    }

    private static func introMessageKey(_ message: NowPlayingLyricPreviewPolicy.IntroMessage) -> LocalizedStringKey {
        switch message {
        case .starting: "lyrics_preview_intro_starting"
        case .settingTheMood: "lyrics_preview_intro_mood"
        case .musicTakesOver: "lyrics_preview_intro_take_over"
        case .almostThere: "lyrics_preview_intro_almost"
        case .vocalsIncoming: "lyrics_preview_intro_vocals"
        }
    }

    private func update() {
        guard hasSynchronizedLyrics else {
            apply(.init(display: .empty, nextChange: nil))
            if !rows.isEmpty { rows = [] }
            return
        }
        let now = player.interpolatedTime()
        let resolution = NowPlayingLyricPreviewPolicy.resolve(
            in: lyrics,
            at: now,
            lookahead: Self.lookahead,
            showsInterludes: showsLyricsInterlude
        )
        apply(resolution)
        // 一行时不排格子;多行时每次都按同一刻重排(几十句的筛选,一秒最多四次)。
        let nextRows = rowCount > 1
            ? NowPlayingLyricPreviewPolicy.rows(
                for: resolution.display,
                in: lyrics,
                at: now,
                lookahead: Self.lookahead,
                rowCount: rowCount
            )
            : []
        if rows != nextRows { rows = nextRows }
    }

    private func apply(_ resolution: NowPlayingLyricPreviewPolicy.Resolution) {
        if display != resolution.display { display = resolution.display }
        if nextChange != resolution.nextChange { nextChange = resolution.nextChange }
    }
}

/// 间奏里那一行的标签:两侧各一个音符,轻轻地明暗起伏;暂停、减弱动效时静止。
private struct NowPlayingInstrumentalLabel: View {
    let font: Font
    let tint: Color
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !isAnimating)) { context in
            let wave = isAnimating
                ? 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.6)
                : 1
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .imageScale(.small)
                Text("lyrics_preview_instrumental")
                Image(systemName: "music.note")
                    .imageScale(.small)
            }
            .font(font)
            .foregroundStyle(tint)
            .lineLimit(1)
            .opacity(0.62 + 0.38 * wave)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("lyrics_preview_instrumental"))
    }
}

/// 见 `LyricsScrollView.rowAnchorYs`。
final class LyricRowAnchorYs {
    var values: [Int: CGFloat] = [:]
}

/// 拖动歌词时横在定位线上的标尺：一根两端淡出的细线，时间和播放键收在歌词
/// 对齐方向的另一侧，尽量不压住正在看的那句。
struct LyricsBrowseTimeline: View {
    let timeText: String
    /// 时间和播放键放在左侧（歌词靠右对齐时）。
    let placesControlsOnLeft: Bool
    let onSeek: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let appearance = NowPlayingAppearance(colorScheme: colorScheme, contrast: contrast)
        let increasedContrast = contrast == .increased
        HStack(spacing: 10) {
            if placesControlsOnLeft {
                controls(appearance: appearance, increasedContrast: increasedContrast)
            }
            hairline(appearance: appearance, increasedContrast: increasedContrast)
            if !placesControlsOnLeft {
                controls(appearance: appearance, increasedContrast: increasedContrast)
            }
        }
        .frame(height: 44)
        .environment(\.layoutDirection, .leftToRight)
        .sensoryFeedback(.selection, trigger: timeText)
    }

    private func hairline(appearance: NowPlayingAppearance, increasedContrast: Bool) -> some View {
        let strong = appearance.primary.opacity(increasedContrast ? 0.6 : 0.3)
        let stops: [Gradient.Stop] = [
            .init(color: strong.opacity(0), location: 0),
            .init(color: strong, location: 0.45),
            .init(color: strong, location: 1),
        ]
        return Rectangle()
            .fill(LinearGradient(
                stops: stops,
                startPoint: placesControlsOnLeft ? .trailing : .leading,
                endPoint: placesControlsOnLeft ? .leading : .trailing
            ))
            .frame(height: max(1 / max(displayScale, 1), 0.5))
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func controls(appearance: NowPlayingAppearance, increasedContrast: Bool) -> some View {
        HStack(spacing: 2) {
            if placesControlsOnLeft { playButton(appearance: appearance, increasedContrast: increasedContrast) }
            Text(verbatim: timeText)
                .font(.system(.caption2, design: .rounded, weight: .medium).monospacedDigit())
                .foregroundStyle(appearance.secondary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: timeText)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .fixedSize()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if !placesControlsOnLeft { playButton(appearance: appearance, increasedContrast: increasedContrast) }
        }
    }

    private func playButton(appearance: NowPlayingAppearance, increasedContrast: Bool) -> some View {
        Button(action: onSeek) {
            Image(systemName: "play.fill")
                .font(.system(size: 9, weight: .bold))
                .offset(x: 0.5)
                .foregroundStyle(appearance.primary)
                .frame(width: 24, height: 24)
                .background {
                    Circle()
                        .fill(appearance.primary.opacity(increasedContrast ? 0.2 : 0.1))
                        .overlay {
                            Circle().strokeBorder(
                                appearance.primary.opacity(increasedContrast ? 0.45 : 0.16),
                                lineWidth: max(1 / max(displayScale, 1), 0.5)
                            )
                        }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("lyrics_play_from_line"))
        .accessibilityValue(Text(verbatim: timeText))
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
    /// 用户亲手往上翻了一段歌词（往回拉、程序滚动、双指缩放不算）。竖屏播放页用它收起底部控件。
    var onUserScroll: (() -> Void)? = nil
    /// 有声内容没有文字稿时那一页(写明没有、能生成就给生成、生成中显示进度,#314);为空时是音乐的
    /// 「暂无歌词」与刮削、听歌识词。
    var spokenWordEmptyState: SpokenTranscriptEmptyState.Content? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    /// 译文(和注音)行自己的字号;0 = 跟原文一起缩放(#320)。
    @AppStorage(CloudKVSKey.lyricsTranslationFontScale) private var lyricsTranslationFontScale: Double = 0
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
    @AppStorage(PlayerAppearancePreferences.showsLyricsBrowseTimelineKey)
    private var showsLyricsBrowseTimeline = PlayerAppearancePreferences.showsLyricsBrowseTimelineByDefault
    @AppStorage(PlayerAppearancePreferences.showsLyricsInterludeKey)
    private var showsLyricsInterlude = PlayerAppearancePreferences.showsLyricsInterludeByDefault
    @State private var lyricsPinchScale: CGFloat = 1.0
    @State private var isPinchingLyrics = false
    /// 这次亲手拖动开始时的滚动位置。往上翻过 `chromeCollapseScrollDistance` 才收起控件:
    /// 一碰就收的话, 往下拉(回看前几句、下拉收起播放页)也会先弹出整屏歌词, 控件让出的
    /// 高度还把歌词整体往下推, 跟着手指的那几帧整页重排, 看着就是一卡。
    @State private var userScrollStartOffsetY: CGFloat?
    @State private var currentLineIndex = -1
    /// 正在显示的间奏提示点:第一句前的前奏,或跟在某一句后面的那一段。
    @State private var activeInterlude: ActiveInterludeMarker? = nil
    @State private var visualPlaybackTime: TimeInterval = 0
    @State private var isRestoringVisualPosition = false
    @State private var isManuallyBrowsingLyrics = false
    /// Row taps and the surface tap are simultaneous gestures. Remember the
    /// row event briefly so tapping lyrics seeks only, while tapping unused
    /// space can switch the normal Now Playing surface back to artwork.
    @State private var lastLyricRowTapAt: Date = .distantPast
    /// 按住不放是在准备拖歌词，松手时不能当成点空白回封面。
    @State private var lastSurfaceLongPressAt: Date = .distantPast
    /// 手动浏览时停在定位线上的那一句（网易云式的时间线标识）。
    @State private var browsedLineIndex: Int?
    /// 各行定位点在滚动内容里的纵坐标。只随排版变化，放在引用盒子里，
    /// 写入不触发重绘；滚动时按它找出定位线上的那一句。
    @State private var rowAnchorYs = LyricRowAnchorYs()

    // 用户手动拖动歌词时, 暂时冻结自动滚动 ── 否则刚拖到想看的位置, 下一帧
    // auto follow 又把视图拽回当前行, 等于不能浏览。lastUserScrollTime 静止
    // 超过 manualScrollGracePeriod 后恢复 auto follow。
    @State private var lastUserScrollTime: Date = .distantPast
    /// 歌词在手动浏览保护期结束时必须主动归位。旧实现只在歌词索引
    /// 下一次变化时尝试 scrollTo，遇到长句/间奏就会长期停在错误位置。
    @State private var lineAutoFollowResumeTask: Task<Void, Never>? = nil
    private static let manualScrollGracePeriod: TimeInterval = 3.0
    private static let chromeCollapseScrollDistance: CGFloat = 24

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

    /// 译文与注音行的缩放:单独设过就用自己的,捏合照样一起放大缩小;没设过跟原文。
    private var effectiveCompanionScale: Double {
        guard lyricsTranslationFontScale > 0 else { return effectiveLyricsScale }
        let combined = lyricsTranslationFontScale * Double(lyricsPinchScale)
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

    /// 整首有两个声部（TTML 的 ttm:agent、LYS/QRC 的对唱标记）时按声部分左右。
    private var isDuetLyrics: Bool {
        KaraokeDuetGatePolicy.hasDuetParts(lyrics)
    }

    /// 对唱时每一行按声部摆到一侧；不是对唱就是用户选的对齐方式。
    private func duetAlignment(for line: LyricLine, isDuet: Bool) -> PlayerLyricsAlignment {
        let preferred: LyricDuetLayoutPolicy.Side = switch lyricsAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return switch LyricDuetLayoutPolicy.side(for: line.voice, preferred: preferred, isDuet: isDuet) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
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
                } else if let spokenWordEmptyState {
                    SpokenTranscriptEmptyState(
                        content: spokenWordEmptyState,
                        palette: SpokenWordPlayerPalette(
                            primary: appearance.primary,
                            secondary: appearance.secondary,
                            tertiary: appearance.faint,
                            accent: appearance.primary,
                            tileFill: appearance.primary.opacity(appearance.isLight ? 0.07 : 0.12)
                        )
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
                activeInterlude = nil
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
            activeInterlude = nil
            lastLyricRowTapAt = .distantPast
            lastSurfaceLongPressAt = .distantPast
            lastUserScrollTime = .distantPast
            browsedLineIndex = nil
            rowAnchorYs.values.removeAll()
            lyricsPinchScale = 1
            isPinchingLyrics = false
            userScrollStartOffsetY = nil
            lineAutoFollowResumeTask?.cancel()
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            LongPressGesture(
                minimumDuration: LyricsBackgroundTapPolicy.longPressDuration,
                maximumDistance: 12
            )
            .onEnded { _ in lastSurfaceLongPressAt = Date() }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { _ in
                    let eventTime = Date()
                    Task { @MainActor in
                        await Task.yield()
                        // 一次长按只挡紧跟着的这一下松手，不留到之后正常的点按。
                        let longPressAt = lastSurfaceLongPressAt
                        lastSurfaceLongPressAt = .distantPast
                        guard LyricsBackgroundTapPolicy.shouldHandle(
                            hasLyrics: !lyrics.isEmpty,
                            isPinching: isPinchingLyrics,
                            rowTapTimeDistance: lastLyricRowTapAt.timeIntervalSince(eventTime),
                            timeSinceUserScroll: eventTime.timeIntervalSince(lastUserScrollTime),
                            timeSinceLongPress: eventTime.timeIntervalSince(longPressAt)
                        ) else { return }
                        onBackgroundTap()
                    }
                }
        )
    }

    private var translationStatusBadge: some View {
        // 点这颗状态标签不能被外层当成「点空白回封面」。
        LyricsTranslationStatusChip(activity: translationActivity) {
            lastLyricRowTapAt = Date()
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
            let isDuet = isDuetLyrics

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LyricsRowStack(isLazy: usesLazyRows, spacing: Self.lyricsRowSpacing) {
                        // Give the first and last rows enough physical room to
                        // reach the same visual anchor as every middle row.
                        Spacer().frame(height: geo.size.height * Self.lyricsVisualAnchor)

                        lyricRowCells(isDuet: isDuet, textWidth: textWidth) { index in
                            lineLevelRowVisualActivity(index: index)
                        }

                        Spacer().frame(height: geo.size.height * (1 - Self.lyricsVisualAnchor))
                    }
                    .frame(width: layoutWidth, alignment: .topLeading)
                    .coordinateSpace(.named(Self.lyricsContentSpace))
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
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height * Self.lyricsVisualAnchor
                } action: { _, anchorY in
                    updateBrowsedLine(anchorY: anchorY)
                }
                .overlay(alignment: .top) {
                    browseTimelineIndicator(viewportHeight: geo.size.height)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offsetY in
                    collapseChromeIfScrolledUp(offsetY: offsetY)
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    trackUserScrollStart(
                        from: oldPhase,
                        to: newPhase,
                        offsetY: context.geometry.contentOffset.y
                    )
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
                .onChange(of: lyricsTranslationFontScale) { _, _ in
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
                    userScrollStartOffsetY = nil
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
            let isDuet = isDuetLyrics
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LyricsRowStack(isLazy: usesLazyRows, spacing: Self.lyricsRowSpacing) {
                        Spacer().frame(height: geo.size.height * Self.lyricsVisualAnchor)

                        wordLevelBadge

                        lyricRowCells(isDuet: isDuet, textWidth: textWidth) { index in
                            rowVisualActivity(index: index)
                        }

                        Spacer().frame(height: geo.size.height * (1 - Self.lyricsVisualAnchor))
                    }
                    .frame(width: layoutWidth, alignment: .topLeading)
                    .coordinateSpace(.named(Self.lyricsContentSpace))
                    .padding(.horizontal, Self.lyricsHorizontalPadding)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in beginLineManualBrowsing() }
                        .onEnded { _ in endLineManualBrowsing(proxy: proxy) }
                )
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height * Self.lyricsVisualAnchor
                } action: { _, anchorY in
                    updateBrowsedLine(anchorY: anchorY)
                }
                .overlay(alignment: .top) {
                    browseTimelineIndicator(viewportHeight: geo.size.height)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offsetY in
                    collapseChromeIfScrolledUp(offsetY: offsetY)
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    trackUserScrollStart(
                        from: oldPhase,
                        to: newPhase,
                        offsetY: context.geometry.contentOffset.y
                    )
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
                .onChange(of: lyricsTranslationFontScale) { _, _ in
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
                    userScrollStartOffsetY = nil
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
        case intro
    }

    private enum ActiveInterludeMarker: Equatable {
        case intro
        case afterLine(Int)
    }

    private var playbackScrollTarget: LyricsScrollTarget? {
        switch activeInterlude {
        case .intro:
            return .intro
        case .afterLine(let index) where lyrics.indices.contains(index):
            return .interlude(afterLineID: lyrics[index].id)
        default:
            break
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

    /// 亲手开始拖动时记下起点, 停下或改成程序滚动时清掉。
    private func trackUserScrollStart(from oldPhase: ScrollPhase, to newPhase: ScrollPhase, offsetY: CGFloat) {
        if newPhase == .interacting, oldPhase != .interacting, !isPinchingLyrics, onUserScroll != nil {
            userScrollStartOffsetY = offsetY
        } else if newPhase == .idle || newPhase == .animating {
            userScrollStartOffsetY = nil
        }
    }

    /// 从起点往上翻够一段才收起控件; 松手后的惯性接着往上也算。往回拉偏移只会变小, 不收。
    private func collapseChromeIfScrolledUp(offsetY: CGFloat) {
        guard let start = userScrollStartOffsetY,
              !isPinchingLyrics,
              offsetY - start >= Self.chromeCollapseScrollDistance else { return }
        userScrollStartOffsetY = nil
        onUserScroll?()
    }

    private func beginLineManualBrowsing() {
        lineAutoFollowResumeTask?.cancel()
        lastUserScrollTime = Date()
        // 按住后拖动了就是滚动，滚动自己有保护期；长按记录不再留着挡后面的点按。
        lastSurfaceLongPressAt = .distantPast
        guard !isManuallyBrowsingLyrics else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isManuallyBrowsingLyrics = true
        }
    }

    /// 歌词内容自己的坐标系：行的位置只随排版变，不随滚动变。
    private static let lyricsContentSpace = "lyricsContent"

    private static func rowAnchorY(_ frame: CGRect) -> CGFloat {
        // 自动跟随用 anchor(y: lyricsVisualAnchor) 对齐，定位点取行内同一比例的位置。
        frame.minY + frame.height * lyricsVisualAnchor
    }

    private func updateBrowsedLine(anchorY: CGFloat) {
        guard showsLyricsBrowseTimeline, isManuallyBrowsingLyrics, hasSynchronizedLyrics else { return }
        var nearest: Int?
        var nearestDistance = CGFloat.infinity
        for (index, y) in rowAnchorYs.values where lyrics.indices.contains(index) {
            let distance = abs(y - anchorY)
            if distance < nearestDistance {
                nearest = index
                nearestDistance = distance
            }
        }
        if nearest != browsedLineIndex { browsedLineIndex = nearest }
    }

    private func browsedOpacity(index: Int, base: Double) -> Double {
        showsLyricsBrowseTimeline && isManuallyBrowsingLyrics && browsedLineIndex == index ? 1 : base
    }

    @ViewBuilder
    private func browseTimelineIndicator(viewportHeight: CGFloat) -> some View {
        if showsLyricsBrowseTimeline,
           isManuallyBrowsingLyrics,
           let index = browsedLineIndex,
           lyrics.indices.contains(index),
           lyrics[index].isSynchronized {
            let line = lyrics[index]
            LyricsBrowseTimeline(
                timeText: Self.browseTimeText(line.timestamp),
                placesControlsOnLeft: lyricsScaleAnchor.x > 0.5
            ) {
                lastLyricRowTapAt = Date()
                player.seekToTappedLine(at: line.timestamp)
                // 跳过去之后立刻回到跟随，定位线随之收起。
                lineAutoFollowResumeTask?.cancel()
                lastUserScrollTime = .distantPast
                withAnimation(.smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0)) {
                    isManuallyBrowsingLyrics = false
                    browsedLineIndex = nil
                }
            }
            .padding(.horizontal, Self.lyricsHorizontalPadding - 12)
            .frame(height: 44)
            .offset(y: viewportHeight * Self.lyricsVisualAnchor - 22)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private static func browseTimeText(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
                browsedLineIndex = nil
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
        let resolvedTarget = lazyRowScrollTarget(for: target)
        let update = {
            proxy.scrollTo(
                resolvedTarget,
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

    /// 间奏时上一句下面那三个点:和那一句同一侧对齐,跟着间奏的时间依次点亮(#198),
    /// 下一句开唱前跳两下(#315)。只在这段间奏真正开始后才展开出现,下一句开唱时收起;
    /// 没轮到的间奏不占位置也看不见。展开、收起与滚动走同一条曲线(见 `updateCurrentLine`)。
    private func interludeMarker(
        _ window: LyricPlaybackPositionPolicy.InterludeWindow,
        isActive: Bool,
        alignment: PlayerLyricsAlignment,
        spacingEdge: Edge.Set = .top
    ) -> some View {
        let lookahead = hasWordLevelLyrics ? Self.wordLevelLineLookahead : Self.lineLevelLookahead
        return LyricInterludeDots(
            isActive: isActive,
            isPlaying: player.isPlaying,
            phase: {
                LyricPlaybackPositionPolicy.phase(
                    of: window,
                    at: player.interpolatedTime(),
                    lookahead: lookahead
                )
            },
            tint: appearance.primary,
            restingOpacity: 0
        )
        .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
        .frame(height: Self.interludeMarkerHeight)
        // 展开时自带一份行间距(这一格和上一句同在一个 spacing 0 的 VStack 里)。
        .padding(spacingEdge, Self.lyricsRowSpacing)
        .opacity(isActive ? 1 : 0)
        .frame(
            height: isActive ? Self.interludeMarkerHeight + Self.lyricsRowSpacing : 0,
            alignment: .top
        )
        .allowsHitTesting(false)
    }

    private static let interludeMarkerHeight: CGFloat = 24
    /// 歌词列表里行与行之间的距离(两种列表的 VStack spacing)。
    private static let lyricsRowSpacing: CGFloat = 12

    /// 行数多到这个份上(播客、有声书生成的文字稿动辄上千行)就改用惰性排版:全部实排时
    /// 每换一句、每写回一批译文都要把上千行连同逐字排版重算一遍,主线程一直是满的。
    /// 一首歌的歌词远到不了这么多行,照旧全部排好,滚动定位和过渡都不变。
    private static let lazyRowThreshold = 240

    private var usesLazyRows: Bool { lyrics.count >= Self.lazyRowThreshold }

    /// 惰性排版时间奏提示点在格子里面,那一格没建出来就找不到它;改滚到它所在的那一格。
    private func lazyRowScrollTarget(for target: LyricsScrollTarget) -> LyricsScrollTarget {
        guard usesLazyRows else { return target }
        switch target {
        case .line:
            return target
        case .interlude(let lineID):
            return .line(id: lineID)
        case .intro:
            return lyrics.first.map { .line(id: $0.id) } ?? target
        }
    }

    private struct LyricRowEntry: Identifiable {
        let index: Int
        let line: LyricLine
        var id: LyricsScrollTarget { .line(id: line.id) }
    }

    /// 歌词的每一格。惰性排版时还没建出来的行也要能滚过去:滚动目标挂在格子本身上,
    /// 并且和 ForEach 的身份是同一个值(Mac 歌词同一种做法);全部实排时仍挂在那一句上。
    @ViewBuilder
    private func lyricRowCells(
        isDuet: Bool,
        textWidth: CGFloat,
        activity: @escaping (Int) -> RowActivity
    ) -> some View {
        if usesLazyRows {
            ForEach(lyrics.indices.map { LyricRowEntry(index: $0, line: lyrics[$0]) }) { entry in
                lyricRowCell(
                    index: entry.index,
                    line: entry.line,
                    activity: activity(entry.index),
                    isDuet: isDuet,
                    textWidth: textWidth
                )
                .id(entry.id)
            }
        } else {
            ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                lyricRowCell(
                    index: index,
                    line: line,
                    activity: activity(index),
                    isDuet: isDuet,
                    textWidth: textWidth
                )
            }
        }
    }

    /// 一句和跟在它后面的间奏提示点算一格:提示点收起时不占位置,也不多出一份行间距。
    @ViewBuilder
    private func lyricRowCell(
        index: Int,
        line: LyricLine,
        activity: RowActivity,
        isDuet: Bool,
        textWidth: CGFloat
    ) -> some View {
        let alignment = duetAlignment(for: line, isDuet: isDuet)
        VStack(alignment: .leading, spacing: 0) {
            if index == 0 {
                introMarker(isDuet: isDuet)
            }

            LyricsScaleEnvelopeLayout(
                maximumScale: Self.lyricsActiveVisualScale,
                horizontalAnchor: alignment.scaleAnchor(in: lyricLayoutDirection)
            ) {
                lyricsRow(
                    line: line,
                    index: index,
                    dimmedByAmbient: true,
                    availableWidth: textWidth,
                    visualScale: CGFloat(activity.scale),
                    rowAlignment: alignment
                )
            }
            .if(!usesLazyRows) { $0.id(LyricsScrollTarget.line(id: line.id)) }
            .opacity(browsedOpacity(index: index, base: activity.opacity))
            .blur(radius: inactiveLyricBlurRadius(for: index))
            // Highlight, scale, and scroll all travel on one curve instead of
            // snapping the row style before scrolling it.
            .animation(
                .smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0),
                value: currentLineIndex
            )
            .padding(.vertical, 5)
            .onGeometryChange(for: CGFloat.self) { proxy in
                Self.rowAnchorY(proxy.frame(in: .named(Self.lyricsContentSpace)))
            } action: { y in
                rowAnchorYs.values[index] = y
            }

            if showsLyricsInterlude, let window = LyricPlaybackPositionPolicy.interludeWindow(
                afterLine: index,
                in: lyrics
            ) {
                interludeMarker(
                    window,
                    isActive: activeInterlude == .afterLine(index),
                    alignment: alignment
                )
                .id(LyricsScrollTarget.interlude(afterLineID: line.id))
            }
        }
    }

    /// 第一句前的前奏够长时,第一句上面那一行点(只在前奏里展开);对齐跟第一句。
    @ViewBuilder
    private func introMarker(isDuet: Bool) -> some View {
        if showsLyricsInterlude,
           let window = LyricPlaybackPositionPolicy.introWindow(in: lyrics),
           let first = lyrics.first {
            interludeMarker(
                window,
                isActive: activeInterlude == .intro,
                alignment: duetAlignment(for: first, isDuet: isDuet),
                spacingEdge: .bottom
            )
            .id(LyricsScrollTarget.intro)
        }
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
        ).map(LyricCompanionTextPolicy.displayText)
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
        visualScale: CGFloat = 1,
        rowAlignment: PlayerLyricsAlignment
    ) -> some View {
        let isActive = index == currentLineIndex
        let fontSize = Self.lyricsLayoutBaseSize * CGFloat(effectiveLyricsScale)
        let companionFontSize = Self.lyricsLayoutBaseSize * CGFloat(effectiveCompanionScale) * 0.65
        // weight 在统一动效模式下固定 .semibold。active 行已有 scale + opacity
        // 强调, weight 瞬时跳变只会让切句增加视觉颗粒感。
        let weight: Font.Weight = dimmedByAmbient ? .semibold : (isActive ? .bold : .semibold)
        let alignment = rowAlignment.horizontalAlignment
        let frameAlignment = rowAlignment.frameAlignment
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
                textAlignment: rowAlignment.textAlignment,
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

            // 歌词翻译 — 在原文下面以略小的字号显示。字号默认取原文的 0.65 +
            // medium weight, 视觉上是 secondary; 设置里可以单独调(#320)。注音和译文
            // 共用一个时间戳时两条都属于这一句, 按文件里的先后顺序依次排在原文下面。
            ForEach(companions.indices, id: \.self) { slot in
                Text(companions[slot])
                    .font(.system(size: companionFontSize, weight: .medium))
                    .foregroundStyle(
                        dimmedByAmbient
                            ? appearance.secondary
                            : isActive ? appearance.secondary
                            : index < currentLineIndex
                                ? appearance.primary.opacity(appearance.pastLyricOpacity * 0.72)
                                : appearance.primary.opacity(appearance.futureLyricOpacity * 0.72)
                    )
                    .multilineTextAlignment(rowAlignment.textAlignment)
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
                // 只有带和声的行才读播放进度:放在每行开头读,逐行歌词整列每 0.5s 重建一次。
                let playbackTime = timelineTime ?? player.currentTime
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
                        textAlignment: rowAlignment.textAlignment,
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
                            .font(.system(size: companionFontSize * 0.7, weight: .medium))
                            .foregroundStyle(appearance.secondary)
                            .multilineTextAlignment(rowAlignment.textAlignment)
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
        // This effect sits inside the row's own layout direction, where SwiftUI
        // already mirrors horizontal anchors; the pre-flipped
        // `lyricsScaleAnchor` (meant for the left-to-right envelope layout)
        // would flip twice and grow right-to-left lyrics off the right edge.
        .scaleEffect(visualScale, anchor: rowAlignment.scaleAnchor(in: .leftToRight))
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    private func seekToLyricLine(_ line: LyricLine) {
        lastLyricRowTapAt = Date()
        guard canSeekToLyricLine(line) else { return }
        player.seekToTappedLine(at: line.timestamp)
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
                deactivationTime: dimmedByAmbient ? deactivationTime : nil,
                glowsSungSyllables: !appearance.isLight
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
            if activeInterlude != nil { activeInterlude = nil }
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
                if activeInterlude != nil { activeInterlude = nil }
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
        let interlude: ActiveInterludeMarker?
        let scrollTarget: LyricsScrollTarget?
        switch position {
        case .line(let index):
            guard lyrics.indices.contains(index) else { return nil }
            activeIndex = index
            interlude = nil
            scrollTarget = .line(id: lyrics[index].id)
        case .interlude(let index):
            guard lyrics.indices.contains(index) else { return nil }
            activeIndex = index
            // 关掉了间奏提示点就没有那一行可停,照旧停在上一句。
            if showsLyricsInterlude {
                interlude = .afterLine(index)
                scrollTarget = .interlude(afterLineID: lyrics[index].id)
            } else {
                interlude = nil
                scrollTarget = .line(id: lyrics[index].id)
            }
        case .intro:
            // 第一句还没开始:没有当前句;关掉了提示点就像原来一样停在开头不动。
            activeIndex = -1
            interlude = showsLyricsInterlude ? .intro : nil
            scrollTarget = showsLyricsInterlude ? .intro : nil
        }

        let update = {
            if currentLineIndex != activeIndex {
                currentLineIndex = activeIndex
            }
            if activeInterlude != interlude {
                activeInterlude = interlude
            }
        }
        if disableAnimations {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                update()
            }
        } else if activeInterlude != interlude {
            // 提示点那一格展开或收起会把下面几句推开、拉回,整份歌词跟滚动一起走同一条曲线。
            withAnimation(.smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0), update)
        } else {
            update()
        }
        return scrollTarget
    }
}

/// 歌词页右上角的翻译状态。状态刚出现或变化时展开成「图标 + 说明」，停一会儿
/// 自动收成只剩图标的小圆片，不再一直压着歌词；点图标再展开。图标的颜色区分
/// 成功、退回、失败与需要处理。需要处理的状态展开后，点说明才执行动作。
private struct LyricsTranslationStatusChip: View {
    let activity: LyricsTranslationActivity
    /// 每次点到标签都先报给歌词页，挡掉同一下的「点空白回封面」。
    let onInteraction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true
    /// 手动点开时换一个值，重新计时收起。
    @State private var revealGeneration = 0
    /// 点了「下载翻译模型」，等确认框（包名、大小、流量提醒、上次失败原因）。
    @State private var pendingModelDownload: LocalLyricsTranslationModel.Pack?

    private var localModel: LocalLyricsTranslationService { .shared }

    private enum Tone { case success, warning, failure, progress, action }

    private struct Status {
        /// 同一个 key 视为同一状态：下载百分比跳动不会反复展开。
        let key: String
        let title: String
        let systemImage: String
        let tone: Tone
        let action: (() -> Void)?
    }

    private struct RevealIdentity: Hashable {
        let key: String?
        let generation: Int
    }

    private var status: Status? {
        switch activity {
        case .idle, .notNeeded:
            return nil
        case .intelligentLoading:
            return Status(key: "aiLoading",
                          title: String(localized: "lyrics_translation_ai_loading"),
                          systemImage: "sparkles", tone: .progress, action: nil)
        case .intelligentCached:
            return Status(key: "aiCached",
                          title: String(localized: "lyrics_translation_ai_cached"),
                          systemImage: "checkmark.circle.fill", tone: .success, action: nil)
        case .intelligentSuccess(let provider, let fallbackDepth):
            let name = provider.isEmpty ? String(localized: "ai_provider_default_name") : provider
            return Status(
                key: "aiSuccess|\(provider)|\(fallbackDepth)",
                title: String(
                    format: String(localized: fallbackDepth > 0
                                   ? "lyrics_translation_ai_fallback_success_format"
                                   : "lyrics_translation_ai_success_format"),
                    name
                ),
                systemImage: fallbackDepth > 0 ? "arrow.trianglehead.branch" : "checkmark.circle.fill",
                tone: fallbackDepth > 0 ? .warning : .success,
                action: nil
            )
        case .systemFallback:
            return Status(key: "systemFallback",
                          title: String(localized: "lyrics_translation_ai_system_fallback"),
                          systemImage: "arrow.uturn.backward.circle.fill", tone: .warning, action: nil)
        case .intelligentNotReady(let readiness):
            return Status(key: "intelligentNotReady|\(readiness)",
                          title: readiness.systemFallbackNotice,
                          systemImage: "sparkles", tone: .warning, action: nil)
        case .systemPreparationRequired:
            return Status(key: "systemPreparation",
                          title: String(localized: "Translate Lyrics"),
                          systemImage: "arrow.down.circle.fill", tone: .action) {
                LyricsTranslationSettingsStore.shared.requestSystemTranslationPreparation()
            }
        case .systemUnavailable:
            return Status(key: "systemUnavailable",
                          title: String(localized: "lyrics_translation_unavailable"),
                          systemImage: "exclamationmark.triangle.fill", tone: .failure, action: nil)
        case .localTranslating:
            return Status(key: "localTranslating",
                          title: String(localized: "lyrics_translation_local_translating"),
                          systemImage: "character.book.closed.fill", tone: .progress, action: nil)
        case .localModelRequired:
            return localModelStatus
        case .baiduLoading:
            return Status(key: "baiduLoading",
                          title: String(localized: "baidu_translate_loading"),
                          systemImage: "character.bubble", tone: .progress, action: nil)
        case .baiduSuccess:
            return Status(key: "baiduSuccess",
                          title: String(localized: "baidu_translate_success"),
                          systemImage: "checkmark.circle.fill", tone: .success, action: nil)
        case .baiduNotReady(let issue):
            // 没填好的给一键去设置;译不成或出错的只说原因。
            return Status(key: "baiduNotReady|\(issue)",
                          title: issue.notice,
                          systemImage: "character.bubble", tone: .warning,
                          action: issue == .notConfigured ? {
                              SettingsNavigation.shared.open("intelligence.baiduTranslate")
                          } : nil)
        }
    }

    /// 与 `LocalTranslationModelBadge` 同一套文案与动作，只是拆成图标和说明两半。
    /// 点了先弹确认框，写明是哪个包、多大，再下载。
    private var localModelStatus: Status? {
        let pack = localModel.requestedPack
        switch localModel.modelState {
        case .notDownloaded:
            return Status(key: "localModelDownload",
                          title: String(localized: "lyrics_translation_local_download")
                            + " · " + pack.formattedDownloadSize,
                          systemImage: "arrow.down.circle.fill", tone: .action) {
                pendingModelDownload = pack
            }
        case .failed:
            return Status(key: "localModelFailed",
                          title: String(localized: "lyrics_translation_local_retry"),
                          systemImage: "arrow.clockwise.circle.fill", tone: .failure) {
                pendingModelDownload = pack
            }
        case .downloading(let fraction):
            return Status(
                key: "localModelDownloading",
                title: String(
                    format: String(localized: "lyrics_translation_local_downloading_format"),
                    fraction.formatted(.percent.precision(.fractionLength(0)))
                ),
                systemImage: "arrow.down.circle.dotted", tone: .progress, action: nil
            )
        case .ready, .unsupportedSystem:
            return nil
        }
    }

    private func tint(for tone: Tone) -> Color {
        switch tone {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        case .progress: .secondary
        case .action: .accentColor
        }
    }

    /// 要用户动手的状态多留一会儿，别人还没看清按钮就收了。
    private func visibleDuration(for status: Status) -> Duration {
        status.action == nil ? .seconds(3.5) : .seconds(6)
    }

    /// 缺离线翻译包、下载中、下载失败一直展开到解决：缩成图标容易被忽略，进度也看不见。
    private func staysExpanded(_ status: Status) -> Bool {
        ["localModelDownload", "localModelFailed", "localModelDownloading"].contains(status.key)
    }

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.38, extraBounce: 0.08)
    }

    var body: some View {
        let status = status
        ZStack(alignment: .topTrailing) {
            if let status {
                chip(status)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .topTrailing)))
            }
        }
        .animation(animation, value: status?.key)
        .task(id: RevealIdentity(key: status?.key, generation: revealGeneration)) {
            guard let status else { return }
            if !isExpanded {
                withAnimation(animation) { isExpanded = true }
            }
            guard !staysExpanded(status) else { return }
            do {
                try await Task.sleep(for: visibleDuration(for: status))
            } catch {
                return
            }
            withAnimation(animation) { isExpanded = false }
        }
    }

    private func chip(_ status: Status) -> some View {
        Button {
            onInteraction()
            if !isExpanded {
                revealGeneration &+= 1
            } else if let action = status.action {
                action()
            } else {
                withAnimation(animation) { isExpanded = false }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: status.systemImage)
                    .foregroundStyle(tint(for: status.tone))
                    .symbolEffect(.pulse, isActive: status.tone == .progress && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16, height: 16)
                if isExpanded {
                    Text(status.title)
                        .lineLimit(1)
                        .monospacedDigit()
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, isExpanded ? 10 : 6)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.title)
        // 挂在标签上，确认框从它长出来。
        .modifier(LocalTranslationModelDownloadConfirmation(pack: $pendingModelDownload))
    }
}

// MARK: - PlaybackProgressBar (隔离 player.currentTime 高频读)

/// 进度条 + 双端时间标签。父 NowPlayingView body 不直接读 `player.currentTime`,
/// 把高频属性的 Observation 追踪限制在本 view 内。这样 currentTime 每 0.5s 变化
/// 只重算本 view,不会让父 body 重算 → 父 view 里的 SwiftUI Menu submenu (字号
/// 选择)在用户操作期间不会被强制关闭。
///
/// 两个时间中间可以放一组标签(`centerAccessory`,音质与来源)。标签叠在时间那一行上、不占
/// 高度 —— 手机横屏是按这一行原本的高度排版的。有声内容那里写本章还剩多久,标签只在等
/// iCloud 下载时借这个位置。
// MARK: - 正在播的歌对应的专辑与艺人

extension MusicLibrary {
    /// Resolve a playing song back to the library entities used by the detail
    /// screens. Older scans may not have persisted artistID/albumID, so retain a
    /// normalized-name fallback instead of silently hiding links.
    /// 播放页、迷你条的「前往艺人」都走这里。
    func linkedArtists(for song: Song) -> [Artist] {
        // 播放页每次更新都会读几遍, 按 id 走曲库的 O(1) 索引, 别整库建字典。
        func byID(_ name: String) -> Artist? {
            visibleArtist(id: MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey(name)))
        }
        var artists: [Artist] = []
        for name in artistNames(for: song) {
            if let artist = byID(name) ?? visibleArtist(named: name) {
                artists.append(artist)
            } else {
                // 曲库没拆开的合唱署名(A & B、feat.)再按展示写法拆一次;各段只按 id 查。
                artists += ArtistLinkResolutionPolicy.fallbackPieces(of: name).compactMap(byID)
            }
        }
        var seen = Set<String>()
        return artists.filter { seen.insert($0.id).inserted }
    }

    /// 播放页、迷你条的「前往专辑」都走这里。
    func linkedAlbum(for song: Song) -> Album? {
        if let albumID = song.albumID,
           let album = visibleAlbum(id: albumID) {
            return album
        }
        let albumTitle = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !albumTitle.isEmpty else { return nil }
        let artistName = (song.albumArtistName ?? artistNames(for: song).first)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return visibleAlbum(titled: albumTitle, artistName: artistName)
    }
}

// MARK: - 下拉收起与顶栏按钮

/// 播放页下拉收起手势的起点、认出的方向与最近一次动静的时刻。不可观察：拖动时每一帧都写。
@MainActor
private final class NowPlayingMinimizeDragActivity {
    var lastEventAt = Date.distantPast
    var startLocation: CGPoint?
    var axis: NowPlayingDismissGesturePolicy.Axis?
}

/// 手指拖着整页、或者已经开始收进迷你条时，背景色场、律动与大封面的动画先停下。
/// 只有那几处动画读它，整页版面不跟着它重建（#322）。
@MainActor
@Observable
final class NowPlayingSurfaceMotion {
    var isDragging = false
    var isDismissing = false

    var isHeld: Bool { isDragging || isDismissing }
}

// MARK: - 按住快退 / 快进

/// 音乐的上一首 / 下一首按住不放 = 快退 / 快进。按住时只在进度条上走预览位置，松手才真正跳一次：
/// 播放器每次跳转都要停下、从新位置重新解码，按住期间连着跳会让播放键一直转圈、声音一顿一顿。
/// 按得越久走得越快。
@MainActor @Observable
fileprivate final class TransportHoldScrub {
    private(set) var previewTime: TimeInterval?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var songID: String?
    @ObservationIgnored private var endedAt = Date.distantPast

    /// 每秒走过多少秒的歌：先慢后快，长歌也不用按太久。
    nonisolated static func rate(heldFor seconds: TimeInterval) -> TimeInterval {
        switch seconds {
        case ..<1.5: 6
        case ..<3.5: 15
        default: 30
        }
    }

    func begin(forward: Bool, player: AudioPlayerService) {
        guard task == nil, let song = player.currentSong else { return }
        let duration = player.duration
        guard duration > 0 else { return }
        songID = song.id
        let start = min(max(0, player.currentTime), duration)
        previewTime = start
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        let beganAt = Date()
        task = Task { [weak self] in
            var position = start
            var lastTick = beganAt
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                let now = Date()
                let step = Self.rate(heldFor: now.timeIntervalSince(beganAt)) * now.timeIntervalSince(lastTick)
                lastTick = now
                // 快进停在结尾前一秒：真跳到结尾等于直接切歌，不是「快进」。
                position = min(max(0, position + (forward ? step : -step)), max(0, duration - 1))
                self.previewTime = position
            }
        }
    }

    func end(player: AudioPlayerService) {
        guard let task else { return }
        task.cancel()
        self.task = nil
        endedAt = Date()
        let target = previewTime
        previewTime = nil
        // 按住期间自己播完换了歌，预览的是上一首的位置，不跳。
        guard let target, player.currentSong?.id == songID else { return }
        player.seek(to: target)
    }

    /// 按住后松手，按钮自己的点按也会触发；这一下吃掉，不再切歌。
    func consumesTap() -> Bool {
        if task != nil { return true }
        guard Date().timeIntervalSince(endedAt) < 0.6 else { return false }
        endedAt = .distantPast
        return true
    }
}

/// 挂在上一首 / 下一首键上。和按钮的点按同时识别：短按照常切歌，按满 0.45 秒开始快退 / 快进，
/// 松手(或手势被打断)时结束。
fileprivate struct TransportHoldScrubGesture: ViewModifier {
    let forward: Bool
    let isEnabled: Bool
    let scrub: TransportHoldScrub
    let player: AudioPlayerService
    @GestureState private var isHolding = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45, maximumDistance: 24)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($isHolding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    },
                including: isEnabled ? .all : .subviews
            )
            .onChange(of: isHolding) { _, holding in
                if holding {
                    scrub.begin(forward: forward, player: player)
                } else {
                    scrub.end(player: player)
                }
            }
    }
}

fileprivate struct PlaybackProgressBar<CenterAccessory: View>: View {
    var fillTint: Color?
    let centerAccessory: CenterAccessory
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// 可选读法:播放页以外单独用到这条进度条时没有注入,也不会崩。
    @Environment(TransportHoldScrub.self) private var holdScrub: TransportHoldScrub?
    @AppStorage(PlayerAppearancePreferences.progressStyleKey)
    private var progressStyleRawValue = NowPlayingProgressStyle.standard.rawValue
    @AppStorage(PlayerAppearancePreferences.progressGlowKey)
    private var progressGlows = PlayerAppearancePreferences.progressGlowByDefault
    @State private var previewTime: TimeInterval?

    /// 两端时间各留这么宽,中间的标签不会压到「-1:02:34」这种长时间上。
    private static var timeLabelReserve: CGFloat { 50 }

    init(fillTint: Color? = nil, @ViewBuilder centerAccessory: () -> CenterAccessory) {
        self.fillTint = fillTint
        self.centerAccessory = centerAccessory()
    }

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    /// 时间标签 0.5 秒跳一次, 正好是数字翻页动画还撑得住的频率上限, 所以按整秒
    /// 驱动而不是按浮点进度。拖动时数字是跟手的, 翻页追不上, 这段期间给 nil。
    private var animatedSecond: Int? {
        guard previewTime == nil, holdScrub?.previewTime == nil else { return nil }
        return player.currentTime.sanitizedDuration.rounded(.down).finiteInt()
    }

    var body: some View {
        let holdPreviewTime = holdScrub?.previewTime
        let displayedTime = previewTime ?? holdPreviewTime ?? player.currentTime
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
                let isSpokenWord = player.currentItemIsSpokenWord
                let isFetchingFromICloud = player.currentSong.map {
                    player.iCloudDownloadingSongID == $0.id
                } ?? false
                VStack(spacing: 4) {
                    ProgressSlider(
                        value: holdPreviewTime ?? player.currentTime,
                        total: player.duration,
                        interactionID: player.currentSong?.id,
                        fillTint: fillTint,
                        trackStyle: .forProgressStyle(
                            PlayerAppearancePreferences.progressStyle(rawValue: progressStyleRawValue),
                            glows: progressGlows
                        ),
                        isPlaying: player.isPlaying,
                        onPreview: { previewTime = $0 },
                        onSeek: { player.seek(to: $0) }
                    )
                    .overlay {
                        // 有声内容在进度条上标出本条目的书签。
                        if isSpokenWord {
                            SpokenWordBookmarkTicks(color: appearance.primary.opacity(0.8))
                        } else {
                            // 开着播放时间段时标出它从哪里开始。
                            SongPlaybackRangeStartTick(color: appearance.primary.opacity(0.8))
                        }
                    }
                    HStack {
                        Text(displayedTime.formattedDuration)
                            .contentTransition(.numericText()); Spacer()
                        if isSpokenWord, previewTime == nil, !isFetchingFromICloud,
                           let remaining = SpokenWordPlayerText.partRemaining(player) {
                            // 按这本书的语速折算,不是内容时长。
                            Text(verbatim: remaining)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer()
                        }
                        Text("-\(max(0, player.duration - displayedTime).formattedDuration)")
                            .contentTransition(.numericText())
                    }
                    .font(.caption2).foregroundStyle(appearance.tertiary).monospacedDigit()
                    .pmAnimation(.control, value: animatedSecond)
                    .overlay {
                        if !isSpokenWord || isFetchingFromICloud {
                            centerAccessory
                                .padding(.horizontal, Self.timeLabelReserve)
                        }
                    }
                }
            }
        }
    }
}

extension PlaybackProgressBar where CenterAccessory == EmptyView {
    init(fillTint: Color? = nil) {
        self.init(fillTint: fillTint) { EmptyView() }
    }
}

// MARK: - 底部状态行

/// 播放页最底下那一行:不止一个音乐源时写这首歌来自哪个源;声音没从手机扬声器出(耳机、蓝牙、
/// 隔空播放、车载、投放到 DLNA 设备)时写设备名,开着睡眠定时时写还剩多久。
/// 几项排成一组整体居中,中间用「·」隔开,不往两端分。
/// 什么都没有就空着。落在 Home 指示条那一带,只是文字、不可点。自己读播放器状态,
/// 倒计时每秒只重画这一行。
fileprivate struct NowPlayingStatusLine: View {
    /// 有声内容的定时写在下面的「定时」块里,这里不重复;「播放页按钮」里也能关掉。
    let showsSleepTimer: Bool
    let showsOutput: Bool
    let source: NowPlayingSourceLabel?
    let tint: Color
    @Environment(AudioPlayerService.self) private var player

    #if DEBUG
    /// 取证用:模拟器没有耳机,`PRIMUSE_DEBUG_STATUS_OUTPUT=<设备名>` 冒充连着这台蓝牙设备;
    /// `PRIMUSE_DEBUG_SLEEP_MINUTES=<分钟>` 一出现就开一个睡眠定时。
    private static let debugOutputName = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_STATUS_OUTPUT"]
    private static let debugSleepMinutes = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SLEEP_MINUTES"]
        .flatMap(Int.init)
    #endif

    private struct Output: Equatable {
        let symbol: String
        let name: String
    }

    var body: some View {
        let output = showsOutput ? self.output : nil
        let showsSleep = showsSleepTimer && player.isSleepTimerActive
        HStack(spacing: 6) {
            if let source {
                HStack(spacing: 3) {
                    Image(systemName: source.iconName)
                        .imageScale(.small)
                    Text(verbatim: source.name)
                        .contentTransition(.opacity)
                }
                .transition(.opacity)
            }
            if source != nil, output != nil || showsSleep {
                separator
            }
            if let output {
                HStack(spacing: 3) {
                    Image(systemName: output.symbol)
                        .imageScale(.small)
                    Text(verbatim: output.name)
                }
                .transition(.opacity)
            }
            if output != nil, showsSleep {
                separator
            }
            if showsSleep {
                // 放不下时先截来源和设备名,倒计时总是完整的。
                sleepLabel
                    .fixedSize()
                    .layoutPriority(1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(tint)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .pmAnimation(.control, value: output)
        .pmAnimation(.control, value: showsSleep)
        .pmAnimation(.trackChange, value: source)
        #if DEBUG
        .task {
            guard let minutes = Self.debugSleepMinutes, !player.isSleepTimerActive else { return }
            player.scheduleSleep(minutes: minutes)
        }
        #endif
    }

    private var separator: some View {
        Text(verbatim: "·")
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    private var sleepLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "moon.zzz.fill")
                .imageScale(.small)
                .accessibilityLabel(Text("sleep_timer_active"))
            if let end = player.sleepTimerEndDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: max(0, end.timeIntervalSince(context.date)).formattedDuration)
                }
            } else {
                Text(verbatim: sleepModeText)
            }
        }
    }

    private var sleepModeText: String {
        if player.sleepStopAfterChapter != nil {
            return String(localized: "sleep_at_chapter_end")
        }
        if player.sleepStopAfterBook != nil {
            return String(localized: "sleep_at_book_end")
        }
        return String(localized: "Stop After Current Song")
    }

    /// 投放时写投放的那台;否则是音频会话现在的出口,手机自己的扬声器不写。
    private var output: Output? {
        if let renderer = player.castingRenderer {
            return Output(symbol: "hifispeaker", name: renderer.friendlyName)
        }
        #if DEBUG
        if let name = Self.debugOutputName {
            return Output(symbol: Self.symbol(for: EQOutputDevice(id: name, name: name, kind: .bluetooth)), name: name)
        }
        #endif
        guard let device = player.equalizerService.currentOutputDevice,
              device.kind != .builtInSpeaker else { return nil }
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return Output(symbol: Self.symbol(for: device), name: name)
    }

    private static func symbol(for device: EQOutputDevice) -> String {
        switch device.kind {
        case .airPlay: return "airplayaudio"
        case .carAudio: return "car"
        case .hdmi: return "tv"
        case .usb: return "cable.connector"
        case .headphones, .bluetooth:
            let name = device.name.lowercased()
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("beats") { return "beats.headphones" }
            return "headphones"
        case .builtInSpeaker, .other: return "hifispeaker"
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
    /// Mac 上照控制中心「声音」输出列表的样子: 一行标题, 「这台 Mac」在最上面, 下面是局域网设备,
    /// 当前的那一个打勾; 高度跟着设备数走, 设备多了才滚动。
    private var macBody: some View {
        let remoteRenderers = renderer.discoveredRenderers.values.sorted { $0.friendlyName < $1.friendlyName }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("cast_picker_title")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                Button {
                    renderer.refreshRemoteRenderers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text("refresh"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            macDeviceRow(
                symbol: "speaker.wave.2.fill",
                title: String(localized: "cast_this_mac"),
                subtitle: nil,
                selected: !player.isCastingMode
            ) {
                await player.stopCasting()
            }

            Text("cast_lan_devices")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textFaint)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)

            if remoteRenderers.isEmpty {
                macScanningState
            } else if remoteRenderers.count > Self.macVisibleDeviceLimit {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(remoteRenderers) { macRendererRow($0) }
                    }
                }
                .pmForceHideScrollers()
                .frame(height: CGFloat(Self.macVisibleDeviceLimit) * Self.macDeviceRowHeight)
            } else {
                ForEach(remoteRenderers) { macRendererRow($0) }
            }
        }
        .padding(.bottom, 8)
        .frame(width: 300)
        // 当作为 popover 弹出时, 系统已经包了 chrome (圆角材质 + 边框 + 阴影 + 箭头),
        // 这里不再画自己的底, 否则跟系统 chrome 叠成双层框。
    }

    private static let macVisibleDeviceLimit = 6
    private static let macDeviceRowHeight: CGFloat = 44

    private func macRendererRow(_ dev: RemoteRenderer) -> some View {
        macDeviceRow(
            symbol: rendererSymbol(for: dev),
            title: dev.friendlyName,
            subtitle: rendererSubtitle(for: dev),
            selected: player.castingRenderer?.udn == dev.udn
        ) {
            await player.startCasting(to: dev)
        }
    }

    private func macDeviceRow(
        symbol: String,
        title: String,
        subtitle: String?,
        selected: Bool,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task {
                await action()
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? PMColor.brand : PMColor.textMuted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: Self.macDeviceRowHeight - 8)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var macScanningState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("cast_scanning")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
            }
            Text("cast_dlna_required_hint_mac")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
            List {
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
