#if os(iOS)
import PrimuseKit
import SwiftUI
import UIKit

// MARK: - 画布

/// 预览按哪块屏幕排:这台设备竖着拿时播放页铺开的尺寸与上下安全区。
struct NowPlayingPreviewCanvas: Equatable {
    var size: CGSize
    var topSafeArea: CGFloat
    var bottomSafeArea: CGFloat
    /// 只有 iPhone 的竖屏播放页会把封面铺满(iPad 竖屏太宽,照旧是卡片)。
    var isPhone: Bool

    var aspect: CGFloat { size.width / max(size.height, 1) }

    /// 屏幕四角的圆角(按真机尺寸)。
    var cornerRadius: CGFloat { isPhone ? 48 : 20 }

    @MainActor
    static func current() -> NowPlayingPreviewCanvas {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        let bounds = window?.bounds.size ?? scene?.screen.bounds.size ?? CGSize(width: 393, height: 852)
        let insets = window?.safeAreaInsets ?? .zero
        let isLandscape = bounds.width > bounds.height
        // 横着拿时刘海 / 灵动岛那一侧的安全区在左右,竖过来就是顶上那一截;Home 指示条竖屏时是 34。
        let top = isLandscape ? max(insets.top, insets.left, insets.right) : insets.top
        let bottom = isLandscape && insets.bottom > 0 ? max(insets.bottom, 34) : insets.bottom
        return NowPlayingPreviewCanvas(
            size: CGSize(width: min(bounds.width, bounds.height), height: max(bounds.width, bounds.height)),
            topSafeArea: max(top, 20),
            bottomSafeArea: bottom,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone
        )
    }
}

// MARK: - 界面与位置

/// 预览画哪一种播放页:音乐的四种界面,以及有声书、播客、电台。
enum NowPlayingPreviewSurface: String, CaseIterable, Identifiable {
    case cover
    case lyrics
    case immersiveLyrics
    case effect
    case audiobook
    case podcast
    case radio

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .cover: "player_controls_surface_cover"
        case .lyrics: "player_controls_surface_lyrics"
        case .immersiveLyrics: "player_controls_surface_immersive_lyrics"
        case .effect: "player_controls_surface_effect"
        case .audiobook: "listening_space_spoken_word"
        case .podcast: "listening_space_podcast"
        case .radio: "listening_space_radio"
        }
    }

    var symbol: String {
        switch self {
        case .cover: "photo"
        case .lyrics: "quote.bubble"
        case .immersiveLyrics: "text.viewfinder"
        case .effect: "sparkles"
        case .audiobook: ListeningSpace.spokenWord.systemImage
        case .podcast: ListeningSpace.podcast.systemImage
        case .radio: ListeningSpace.radio.systemImage
        }
    }
}

/// 预览里能换按钮的一格(各种播放页的位置合在一起)。
enum NowPlayingPreviewSlot: Hashable, Identifiable {
    case cover(NowPlayingControlSlot)
    case lyrics(NowPlayingControlSlot)
    case lyricsExtra
    case immersive(NowPlayingImmersiveLyricsSlot)
    case effect(NowPlayingEffectPlayerSlot)
    case spoken(SpokenWordPlayerKind, SpokenWordControlSlot)

    var id: String {
        switch self {
        case .cover(let slot): "cover.\(slot.rawValue)"
        case .lyrics(let slot): "lyrics.\(slot.rawValue)"
        case .lyricsExtra: "lyrics.extra"
        case .immersive(let slot): "immersive.\(slot.rawValue)"
        case .effect(let slot): "effect.\(slot.rawValue)"
        case .spoken(let kind, let slot): "\(kind.rawValue).\(slot.rawValue)"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .cover(let slot), .lyrics(let slot): slot.editorTitleKey
        case .lyricsExtra: "player_controls_slot_lyrics_extra"
        case .immersive(let slot): slot.editorTitleKey
        case .effect(let slot): slot.editorTitleKey
        case .spoken(_, let slot): slot.editorTitleKey
        }
    }
}

/// 预览里能换按钮的位置怎么画。
enum NowPlayingStylePreviewSlotMode: Equatable {
    /// 都描虚线、可以点(实际大小里打开编辑时)。
    case editable
    /// 只圈出正在挑按钮的那一格,不能点(浮在页面上的小预览)。
    case selectionOnly
    /// 什么都不描,就是播放页本来的样子。
    case plain
}

/// 各种播放页预览共用的那几样:按哪块屏排、怎么画能换的位置、点了告诉谁。
struct NowPlayingPreviewContext {
    let canvas: NowPlayingPreviewCanvas
    let selectedSlot: NowPlayingPreviewSlot?
    let slotMode: NowPlayingStylePreviewSlotMode
    /// 缩小之后虚线还要看得清:线宽、虚线段按缩放倒数放大。
    let strokeScale: CGFloat
    let animatesStage: Bool
    let onSelect: (NowPlayingPreviewSlot) -> Void

    /// 空着的格子画不画加号:编辑时都画,小预览里只画正在挑的那一格。
    func showsPlaceholder(for target: NowPlayingPreviewSlot) -> Bool {
        switch slotMode {
        case .editable: true
        case .selectionOnly: selectedSlot == target
        case .plain: false
        }
    }
}

// MARK: - 预览

/// 「播放页样式与按钮」里那张按真机比例画的播放页。
///
/// 先按这台设备竖屏的实际尺寸与安全区排好,再整体缩小放进来,封面大小、几行控件之间的空白都和播放页
/// 同一套算法。背景直接用播放页那一层(`NowPlayingAmbientBackdrop`),音乐用正在放的这首的封面与歌名,
/// 没在放时用演示内容;有声书、播客、电台用示例内容。一律按「正在播放」画。
struct NowPlayingStylePreview: View {
    let canvas: NowPlayingPreviewCanvas
    let surface: NowPlayingPreviewSurface
    var selectedSlot: NowPlayingPreviewSlot?
    var slotMode: NowPlayingStylePreviewSlotMode = .editable
    /// 全屏效果的舞台跟着动(「实际大小」);浮动的小预览停在一帧上。
    var animatesStage = false
    var onSelect: (NowPlayingPreviewSlot) -> Void = { _ in }

    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(PlayerAppearancePreferences.alwaysDarkKey)
    private var alwaysDark = PlayerAppearancePreferences.alwaysDarkByDefault

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / max(canvas.size.width, 1),
                geometry.size.height / max(canvas.size.height, 1)
            )
            let context = NowPlayingPreviewContext(
                canvas: canvas,
                selectedSlot: selectedSlot,
                slotMode: slotMode,
                strokeScale: 1 / max(scale, 0.01),
                animatesStage: animatesStage,
                onSelect: onSelect
            )
            screen(context)
                .frame(width: canvas.size.width, height: canvas.size.height)
                .clipShape(RoundedRectangle(cornerRadius: canvas.cornerRadius, style: .continuous))
                // 全屏效果页本来就固定深色;其余按「播放页始终用深色」。
                .environment(\.colorScheme, surface == .effect || alwaysDark ? .dark : systemColorScheme)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(canvas.size, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func screen(_ context: NowPlayingPreviewContext) -> some View {
        switch surface {
        case .cover: MusicPortraitPreviewScreen(context: context, showsLyrics: false)
        case .lyrics: MusicPortraitPreviewScreen(context: context, showsLyrics: true)
        case .immersiveLyrics: ImmersiveLyricsPreviewScreen(context: context)
        case .effect: EffectPlayerPreviewScreen(context: context)
        case .audiobook: AudiobookPreviewScreen(context: context)
        case .podcast: PodcastPreviewScreen(context: context)
        case .radio: RadioPreviewScreen(context: context)
        }
    }
}

// MARK: - 共用零件

/// 预览里能换按钮的一格:编辑时描虚线、可以点;小预览里只圈出正在挑的那一格;看效果时就是按钮本身。
/// `isEditable` 为假时(歌词页跟着封面那组时)只画不让点。
struct PreviewSlotCell<Face: View>: View {
    let target: NowPlayingPreviewSlot
    let context: NowPlayingPreviewContext
    var isEditable = true
    var cornerRadius: CGFloat = 10
    @ViewBuilder let face: () -> Face

    var body: some View {
        let isSelected = context.selectedSlot == target
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let scale = context.strokeScale
        switch context.slotMode {
        case .editable where isEditable:
            Button { context.onSelect(target) } label: {
                face()
                    .background {
                        shape.fill(isSelected ? AnyShapeStyle(.tint.opacity(0.28)) : AnyShapeStyle(.clear))
                    }
                    .overlay {
                        shape.strokeBorder(
                            .tint,
                            style: StrokeStyle(lineWidth: 1.4 * scale, dash: [3.5 * scale, 2.5 * scale])
                        )
                    }
                    // 缩小以后一格只有二十来点宽,点的范围往外放一圈。
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(target.titleKey))
            .accessibilityHint(Text("player_controls_slot_hint"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        case .selectionOnly where isSelected:
            // 正在给这一格挑按钮时圈出来,看得出改的是哪儿。
            face()
                .background { shape.fill(.tint.opacity(0.28)) }
                .overlay { shape.strokeBorder(.tint, lineWidth: 2 * scale) }
                .accessibilityHidden(true)
        default:
            face()
                .accessibilityHidden(true)
        }
    }
}

/// 空着的格子:编辑时一个淡淡的加号,看效果时什么都没有。
struct PreviewEmptySlotFace: View {
    let showsPlaceholder: Bool
    let tint: Color

    var body: some View {
        if showsPlaceholder {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
        } else {
            Color.clear
        }
    }
}

/// 播放页那一层背景:底色加封面取色的色场 / 流动色彩 / 声音律动 / 背景图。
struct PreviewPlayerBackdrop: View {
    let song: Song?

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        ZStack {
            NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast).backgroundBase
            NowPlayingAmbientBackdrop(
                song: song,
                isPlaying: player.isPlaying,
                isSurfaceVisible: true,
                isSceneActive: true,
                allowsImageLoading: true
            )
        }
    }
}

/// 进度条与两端的时间,用播放页那根 `ProgressSlider`,按设置里的画法与发光。
struct PreviewProgressBar: View {
    let fillTint: Color
    let timeTint: Color
    var trackStyle: ProgressSlider.TrackStyle?

    @AppStorage(PlayerAppearancePreferences.progressStyleKey)
    private var progressStyleRawValue = NowPlayingProgressStyle.standard.rawValue
    @AppStorage(PlayerAppearancePreferences.progressGlowKey)
    private var progressGlows = PlayerAppearancePreferences.progressGlowByDefault

    /// 示例进度:总长 3:38,播到三成多。
    static let sampleDuration: TimeInterval = 218
    static let sampleElapsed: TimeInterval = 83

    var body: some View {
        VStack(spacing: 4) {
            ProgressSlider(
                value: Self.sampleElapsed,
                total: Self.sampleDuration,
                fillTint: fillTint,
                trackStyle: trackStyle ?? .forProgressStyle(
                    PlayerAppearancePreferences.progressStyle(rawValue: progressStyleRawValue),
                    glows: progressGlows
                ),
                isPlaying: true,
                onSeek: { _ in }
            )
            .allowsHitTesting(false)
            HStack {
                Text(Self.sampleElapsed.formattedDuration)
                Spacer()
                Text(verbatim: "-\((Self.sampleDuration - Self.sampleElapsed).formattedDuration)")
            }
            .font(.caption2)
            .foregroundStyle(timeTint)
            .monospacedDigit()
        }
        .accessibilityHidden(true)
    }
}

/// 系统音量条的样子:细轨道、前景色填充、12 点的圆钮。
struct PreviewVolumeRow: View {
    let primary: Color
    let iconTint: Color

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(iconTint)
            GeometryReader { track in
                let filled = track.size.width * 0.62
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(primary.opacity(colorSchemeContrast == .increased ? 0.3 : 0.2))
                        .frame(height: 4)
                    Capsule()
                        .fill(primary)
                        .frame(width: filled, height: 4)
                    Circle()
                        .fill(primary)
                        .frame(width: 12, height: 12)
                        .offset(x: filled - 6)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: NowPlayingView.portraitVolumeRowHeight)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(iconTint)
        }
        .accessibilityHidden(true)
    }
}

/// 播放页的圆形玻璃键(全屏歌词顶上那一排):随明暗外观的玻璃底与描边。
struct PreviewGlassCircle: View {
    let symbol: String?
    var diameter: CGFloat = 44
    var isSelected = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let appearance = NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(appearance.isLight ? Color.white.opacity(0.42) : Color.black.opacity(0.16))
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.34, weight: .semibold))
                    .foregroundStyle(appearance.primary.opacity(0.88))
            }
        }
        .overlay {
            Circle().strokeBorder(
                appearance.isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.2),
                lineWidth: 0.8
            )
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 播放页上一首 / 下一首(按设置里的图标样式;`fixedSymbol` 给了就照它画,有声内容的快退快进用)。
struct PreviewSkipGlyph: View {
    let forward: Bool
    let tint: Color
    var fixedSymbol: String? = nil

    @AppStorage(PlayerAppearancePreferences.skipButtonStyleKey)
    private var skipButtonStyleRawValue = NowPlayingSkipButtonStyle.standard.rawValue

    var body: some View {
        let skip = PlayerAppearancePreferences.skipButtonStyle(rawValue: skipButtonStyleRawValue)
        Image(systemName: fixedSymbol ?? skip.symbol(forward: forward))
            .font(fixedSymbol == nil ? skip.font : .title)
            .foregroundStyle(tint)
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
    }
}

/// 播放页的播放 / 暂停键(按设置里的样式,显示暂停,和正在播放一样)。
struct PreviewPlayGlyph: View {
    let tint: Color
    var diameter: CGFloat = 56

    @AppStorage(PlayerAppearancePreferences.playButtonStyleKey)
    private var playButtonStyleRawValue = NowPlayingPlayButtonStyle.filledCircle.rawValue

    var body: some View {
        ZStack {
            Image(systemName: "play.circle.fill")
                .font(.system(size: diameter))
                .opacity(0)
            NowPlayingPlayPauseFace(
                style: PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue),
                showsPause: true,
                diameter: diameter,
                tint: tint
            )
        }
        .accessibilityHidden(true)
    }
}

/// 预览用的演示歌名、艺人与歌词(和全屏效果的预览同一套)。
enum NowPlayingPreviewDemo {
    static var title: String { ImmersiveDemoContent.title }
    static var subtitle: String { "\(ImmersiveDemoContent.artist) · \(ImmersiveDemoContent.album)" }
    static var lyrics: [String] { ImmersiveDemoContent.lyrics }
}

/// 播放页控件的强调色,和播放页 `themedControlAccent` 同一个取法。
@MainActor
func nowPlayingPreviewAccent(
    appearance: NowPlayingAppearance,
    theme: ThemeService,
    controlTintRawValue: String
) -> Color {
    if PlayerAppearancePreferences.controlTint(rawValue: controlTintRawValue) == .monochrome
        || ThemeColorSettings.shared.isWhiteTheme {
        return appearance.primary
    }
    guard theme.colorID != "default" else { return appearance.primary }
    return appearance.isLight ? theme.darkAccent : theme.accentColor
}

// MARK: - 音乐:封面与歌词

/// 音乐竖屏播放页:封面那一面与看歌词那一面。版面照 `NowPlayingView.portraitLayout`;下面几行两边共用,
/// 看歌词时用歌词页那组按钮(没单独设置时跟着封面那组,只画不让点)。
private struct MusicPortraitPreviewScreen: View {
    let context: NowPlayingPreviewContext
    let showsLyrics: Bool

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(ThemeService.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var storage = ""
    @AppStorage(NowPlayingLyricsPageControls.storageKey) private var lyricsStorage = ""
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.showsArtworkLyricsKey)
    private var showsArtworkLyrics = PlayerAppearancePreferences.showsArtworkLyricsByDefault
    @AppStorage(PlayerAppearancePreferences.artworkLyricsLinesKey)
    private var artworkLyricsLinesRawValue = NowPlayingArtworkLyricsLines.one.rawValue
    @AppStorage(PlayerAppearancePreferences.artworkStyleKey)
    private var artworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.controlTintKey)
    private var controlTintRawValue = NowPlayingControlTint.theme.rawValue
    @AppStorage(AppThemePreferences.ambientStrengthKey)
    private var ambientStrength = AppThemePreferences.defaultAmbientStrength

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var song: Song? {
        player.isLiveRadio ? nil : player.currentSong
    }

    private var coverLayout: NowPlayingControlLayout { .decode(storage) }
    private var lyricsControls: NowPlayingLyricsPageControls { .decode(lyricsStorage) }

    /// 这一面实际用的那组按钮。
    private var layout: NowPlayingControlLayout {
        showsLyrics ? lyricsControls.resolvedLayout(cover: coverLayout) : coverLayout
    }

    private func previewTarget(_ slot: NowPlayingControlSlot) -> NowPlayingPreviewSlot {
        showsLyrics ? .lyrics(slot) : .cover(slot)
    }

    /// 这一格排不排出来:和播放页一样空着的不占位;能点的虚线框(编辑时、正在给这一格挑按钮时)照样排出来。
    private func arranges(_ slot: NowPlayingControlSlot) -> Bool {
        layout.action(in: slot) != nil || (slotsEditable && context.showsPlaceholder(for: previewTarget(slot)))
    }

    /// 传输键一行,排法同 `NowPlayingView.musicTransportRow`:左右两半各自排开,播放键在正中。
    private var transportRow: some View {
        let hasLeading = arranges(.leadingEdge)
        let hasTrailing = arranges(.trailingEdge)
        let keepsCompact = !hasLeading && !hasTrailing
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                if hasLeading {
                    slot(.leadingEdge, style: .edge)
                    Spacer()
                } else if keepsCompact {
                    Color.clear.frame(width: 44, height: 44)
                    Spacer()
                }
                PreviewSkipGlyph(forward: false, tint: appearance.primary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            PreviewPlayGlyph(tint: appearance.primary)
            HStack(spacing: 0) {
                Spacer()
                PreviewSkipGlyph(forward: true, tint: appearance.primary)
                Spacer()
                if hasTrailing {
                    slot(.trailingEdge, style: .edge)
                    Spacer()
                } else if keepsCompact {
                    Color.clear.frame(width: 44, height: 44)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 最下面那一排,排法同 `NowPlayingView.musicBottomBar`:空着的格不占位。
    private var bottomBar: some View {
        let slots = NowPlayingControlSlot.bar.filter(arranges)
        return HStack(spacing: 0) {
            if slots.count == 1 { Spacer(minLength: 0) }
            ForEach(Array(slots.enumerated()), id: \.element) { index, item in
                if index > 0 { Spacer(minLength: 0) }
                slot(item, style: .bar)
            }
            if slots.count == 1 { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var slotsEditable: Bool {
        !showsLyrics || lyricsControls.usesOwnButtons
    }

    private var usesFullBleedArtwork: Bool {
        !showsLyrics
            && context.canvas.isPhone
            && PlayerAppearancePreferences.artworkStyle(rawValue: artworkStyleRawValue) == .fullBleed
    }

    var body: some View {
        let canvas = context.canvas
        let size = canvas.size
        let artSize = NowPlayingView.portraitArtworkSize(in: size)
        let controlGap = NowPlayingView.portraitControlGap(forHeight: size.height)
        // 封面下的那几行歌词只在封面那一面出现;关掉音量条空出来的高度照播放页的分法
        // (`NowPlayingView.portraitLayout`):行数选了「自动」时归歌词,否则分到封面上方和几行控件之间。
        let artworkLyrics = showsArtworkLyrics && !showsLyrics
        let artworkLyricsLines = PlayerAppearancePreferences.artworkLyricsLines(rawValue: artworkLyricsLinesRawValue)
        let artworkLyricsFill = showsArtworkLyrics && artworkLyricsLines == .fill
        let volumeSlack: CGFloat = showsVolumeBar || artworkLyricsFill
            ? 0
            : NowPlayingView.portraitVolumeRowHeight + 10 + controlGap
        let grabberBand = canvas.topSafeArea + 21
        let accent = nowPlayingPreviewAccent(
            appearance: appearance,
            theme: theme,
            controlTintRawValue: controlTintRawValue
        )

        ZStack {
            PreviewPlayerBackdrop(song: song)

            VStack(spacing: 0) {
                Capsule()
                    .fill(appearance.tertiary)
                    .frame(width: 48, height: 5)
                    .padding(.top, canvas.topSafeArea + 6)
                    .padding(.bottom, 10)

                if showsLyrics {
                    lyricsHeader
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                    PreviewLyricLines(
                        tint: appearance.primary,
                        pastOpacity: appearance.pastLyricOpacity,
                        futureOpacity: appearance.futureLyricOpacity,
                        anchor: 0.3
                    )
                } else {
                    if usesFullBleedArtwork {
                        GeometryReader { region in
                            fullBleedArtwork(width: size.width, height: region.size.height + grabberBand)
                                .frame(width: region.size.width, height: region.size.height, alignment: .bottom)
                        }
                        .frame(maxHeight: NowPlayingView.fullBleedArtworkRegionLimit(
                            width: size.width,
                            topSafeArea: canvas.topSafeArea,
                            extendsBelowSquare: !artworkLyricsFill
                        ))
                        .anchorPreference(key: PreviewFullBleedRegionKey.self, value: .bounds) { $0 }
                        .layoutPriority(1)
                        .zIndex(1)
                    } else {
                        Spacer(minLength: 0)
                            .frame(maxHeight: 16 + volumeSlack * 0.4)
                        GeometryReader { region in
                            let side = min(artSize, max(1, region.size.height - 24))
                            artwork(side: side, cornerRadius: 12)
                                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(maxHeight: artSize + 24)
                        .layoutPriority(1)
                    }

                    // 铺满时歌名贴着进度条,空白在封面与歌名之间(照 `NowPlayingView.portraitLayout`)。
                    let headingHugsProgress = usesFullBleedArtwork && !artworkLyricsFill
                    if headingHugsProgress {
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                            .frame(maxHeight: 16)
                    }

                    songHeader
                        .padding(.horizontal, 26)
                        .padding(.top, 12)

                    // 「自动」照播放页的排法: 这段空白先分给歌词, 下面留着定高的那一格。
                    if artworkLyricsFill {
                        Color.clear
                            .overlay { PreviewArtworkLyricRows(lines: artworkLyricsLines, appearance: appearance) }
                            .padding(.horizontal, 26)
                            .layoutPriority(0.5)
                        NowPlayingArtworkLyricSlot()
                            .padding(.top, NowPlayingView.artworkLyricHeadingGap)
                            .padding(.bottom, 4)
                    } else {
                        if !headingHugsProgress {
                            Spacer(minLength: 0)
                        }
                        if artworkLyrics {
                            PreviewArtworkLyricRows(lines: artworkLyricsLines, appearance: appearance)
                                .padding(.horizontal, 26)
                                .padding(.top, NowPlayingView.artworkLyricHeadingGap)
                                .padding(.bottom, 4)
                        }
                    }
                }

                PreviewProgressBar(fillTint: accent, timeTint: appearance.tertiary)
                    .padding(.horizontal, 26)
                    .padding(.top, 8)

                transportRow
                    .padding(.top, 12 + controlGap + volumeSlack * 0.3)

                if showsVolumeBar {
                    PreviewVolumeRow(primary: appearance.primary, iconTint: appearance.tertiary)
                        .padding(.horizontal, 26)
                        .padding(.top, 10 + controlGap)
                }

                bottomBar
                .font(.body)
                .padding(.horizontal, 46)
                .padding(.top, 12)
                .padding(.top, controlGap / 2 + volumeSlack * 0.3)

                statusLine
                    .frame(height: max(canvas.bottomSafeArea - 8, 20), alignment: .top)
                    .offset(y: -4)
            }
            // 铺满封面下面那一截垫在歌名和控件底下,和播放页一样只在背景是封面取色时铺。
            .backgroundPreferenceValue(PreviewFullBleedRegionKey.self) { region in
                if let region, usesFullBleedArtwork,
                   PlayerBackdropSettingsStore.shared.effectiveSource == .coverAmbient {
                    GeometryReader { proxy in
                        FullBleedArtworkExtension(
                            song: song,
                            coverRevision: player.coverRevision,
                            // 封面从屏幕顶端画到这一块的下沿。
                            artworkRect: CGRect(x: 0, y: 0, width: proxy.size.width, height: proxy[region].maxY),
                            pageSize: proxy.size,
                            isLight: appearance.isLight,
                            strength: AppThemePreferences.normalizedAmbientStrength(ambientStrength),
                            usesIncreasedContrast: colorSchemeContrast == .increased,
                            allowsLoading: true
                        )
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: 封面

    private func artwork(side: CGFloat, cornerRadius: CGFloat) -> some View {
        CachedArtworkView(
            coverRef: song?.coverArtFileName,
            songID: song?.id,
            size: side,
            cornerRadius: cornerRadius,
            sourceID: song?.sourceID,
            filePath: song?.filePath,
            fileFormat: song?.fileFormat,
            revisionToken: player.coverRevision
        )
        .frame(width: side, height: side)
    }

    /// 铺满:整宽、从屏幕顶端画到这一块的下沿,直角,下沿渐隐;顶上垫一道淡底,把手画在封面上。
    private func fullBleedArtwork(width: CGFloat, height: CGFloat) -> some View {
        PreviewFullBleedArtwork(
            width: width,
            height: height,
            topSafeArea: context.canvas.topSafeArea,
            appearance: appearance
        ) {
            artwork(side: max(width, height), cornerRadius: 0)
        }
    }

    // MARK: 歌名

    private var title: String {
        song?.title ?? NowPlayingPreviewDemo.title
    }

    private var subtitle: String {
        guard let song else { return NowPlayingPreviewDemo.subtitle }
        return [library.artistDisplayName(for: song) ?? "", song.albumTitle ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var songHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    slot(.header, style: .header)
                    moreButton
                }
                .fixedSize()
            }
            Text(verbatim: subtitle)
                .font(.body)
                .foregroundStyle(appearance.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 看歌词时顶上那一行:小封面、歌名与艺人,歌词页多出来那一格,歌名旁那一格和更多。
    private var lyricsHeader: some View {
        let extra = lyricsControls.headerExtra
        return HStack(spacing: 10) {
            artwork(side: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            PreviewSlotCell(target: .lyricsExtra, context: context) {
                actionFace(extra, style: .header, target: .lyricsExtra)
            }
            slot(.header, style: .header)
            moreButton
        }
    }

    private var moreButton: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(appearance.secondary)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }

    /// 最底下那行:开着的几项各画一个图标和一截占位。
    private var statusLine: some View {
        let items: [(item: NowPlayingStatusItem, symbol: String)] = [
            (item: .source, symbol: "externaldrive"),
            (item: .output, symbol: "headphones"),
            (item: .sleepTimer, symbol: "moon.zzz.fill"),
        ]
        let shown = items.filter { coverLayout.showsStatusItem($0.item) }
        return HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Text(verbatim: "·")
                }
                Image(systemName: entry.symbol)
                    .imageScale(.small)
                Capsule()
                    .fill(appearance.tertiary.opacity(0.6))
                    .frame(width: 38, height: 5)
            }
        }
        .font(.caption2)
        .foregroundStyle(appearance.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 26)
        .accessibilityHidden(true)
    }

    // MARK: 能换的位置

    private enum SlotStyle {
        /// 歌名旁:和隔空播放键一样只有图标,次要色。
        case header
        /// 播放键两端与最下面那一排:正文字号,淡色。
        case edge
        case bar
    }

    private func slot(_ slot: NowPlayingControlSlot, style: SlotStyle) -> some View {
        let target = previewTarget(slot)
        return PreviewSlotCell(target: target, context: context, isEditable: slotsEditable) {
            actionFace(layout.action(in: slot), style: style, target: target)
        }
    }

    @ViewBuilder
    private func actionFace(
        _ action: NowPlayingControlAction?,
        style: SlotStyle,
        target: NowPlayingPreviewSlot
    ) -> some View {
        Group {
            if let action {
                let tint = style == .header ? appearance.secondary : appearance.tertiary
                if action == .airPlay {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: style == .header ? 18 : 20))
                        .foregroundStyle(tint)
                } else if style == .header {
                    Image(systemName: action.editorSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 38, height: 38)
                } else {
                    Image(systemName: action.editorSymbol)
                        .font(.body)
                        .foregroundStyle(tint)
                }
            } else {
                PreviewEmptySlotFace(
                    showsPlaceholder: context.showsPlaceholder(for: target),
                    tint: appearance.faint
                )
            }
        }
        .frame(width: 44, height: 44)
    }
}

/// 几行演示歌词:当前那句放大、实色,前后几句按播放页的深浅淡下去;对齐与字号跟着歌词设置。
/// `anchor` 是当前那句落在这一块高度的几成处。
struct PreviewLyricLines: View {
    let tint: Color
    let pastOpacity: Double
    let futureOpacity: Double
    var anchor: CGFloat = 0.36
    var baseSize: CGFloat = 26

    @AppStorage(CloudKVSKey.lyricsFontScale) private var lyricsFontScale: Double = 1.0
    @AppStorage(PlayerAppearancePreferences.lyricsAlignmentKey)
    private var alignmentRawValue = PlayerLyricsAlignment.defaultValue.rawValue

    var body: some View {
        let alignment = PlayerLyricsAlignment(rawValue: alignmentRawValue) ?? .defaultValue
        let fontSize = baseSize * CGFloat(lyricsFontScale)
        let lines = Array(NowPlayingPreviewDemo.lyrics.prefix(8))
        GeometryReader { geometry in
            // 当前那句放大 1.08 倍:先按缩回来的宽度折行,放大后正好占满,不出右边。
            let squeeze = max(0, geometry.size.width - 48) * 0.08
            VStack(alignment: alignment.horizontalAlignment, spacing: 22) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    // 第二句是正在唱的,上面一句唱过了,下面几句还没到。
                    let isCurrent = index == 1
                    Text(verbatim: line)
                        .font(.system(size: fontSize, weight: .semibold))
                        .multilineTextAlignment(alignment.textAlignment)
                        .foregroundStyle(tint.opacity(isCurrent ? 1 : (index < 1 ? pastOpacity : futureOpacity)))
                        .padding(alignment == .trailing ? .leading : .trailing, isCurrent && alignment != .center ? squeeze : 0)
                        .padding(.horizontal, isCurrent && alignment == .center ? squeeze / 2 : 0)
                        .scaleEffect(isCurrent ? 1.08 : 1, anchor: alignment.scaleAnchor(in: .leftToRight))
                        .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
                }
            }
            .padding(.horizontal, 24)
            .offset(y: geometry.size.height * anchor - fontSize * 2.3)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// 铺满的封面(台标)在预览里的画法:整宽、从屏幕顶端画到 `height`,直角,下沿渐隐;顶上垫一道淡底,
/// 把手画在封面上。音乐、播客、电台三屏共用,和播放页的铺满一个样子。
struct PreviewFullBleedArtwork<Artwork: View>: View {
    let width: CGFloat
    let height: CGFloat
    let topSafeArea: CGFloat
    let appearance: NowPlayingAppearance
    @ViewBuilder let artwork: () -> Artwork

    var body: some View {
        ZStack(alignment: .top) {
            artwork()
                .frame(width: width, height: height)
                .clipped()
                .mask { FullBleedArtworkFadeMask() }

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
}

/// 封面下的那几行歌词:行数、字号照设置,「自动」时铺在歌名下那段空白上、从下面那一格往上排满;尺寸与
/// 播放页 `NowPlayingArtworkLyricPreview` 同一套。正在唱的那句停在 `anchorRow` 那一格,唱过的、接下来的调淡。
private struct PreviewArtworkLyricRows: View {
    let lines: NowPlayingArtworkLyricsLines
    let appearance: NowPlayingAppearance

    @AppStorage(PlayerAppearancePreferences.artworkLyricsFontScaleKey)
    private var fontScale = PlayerAppearancePreferences.artworkLyricsFontScaleByDefault
    @ScaledMetric(relativeTo: .callout) private var baseFontSize: CGFloat = 16

    var body: some View {
        let fontSize = NowPlayingView.artworkLyricFontSize(base: baseFontSize, scale: fontScale)
        let lineHeight = NowPlayingView.artworkLyricLineHeight(fontSize: fontSize)
        if let count = lines.fixedCount {
            rows(count: count, fontSize: fontSize, lineHeight: lineHeight)
        } else {
            GeometryReader { proxy in
                let height = proxy.size.height + lineHeight
                rows(
                    count: NowPlayingView.artworkLyricRowCount(fitting: height, lineHeight: lineHeight),
                    fontSize: fontSize,
                    lineHeight: lineHeight
                )
                .frame(width: proxy.size.width, height: height, alignment: .bottom)
                .offset(y: NowPlayingView.artworkLyricHeadingGap)
            }
        }
    }

    private func rows(count: Int, fontSize: CGFloat, lineHeight: CGFloat) -> some View {
        let demo = NowPlayingPreviewDemo.lyrics
        let anchor = NowPlayingLyricPreviewPolicy.anchorRow(rowCount: count)
        // 一行时和原来一样放第二句;上面要留唱过的几句时从第一句排起。
        let first = max(1, anchor) - anchor
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { row in
                let index = first + row
                Text(verbatim: demo.indices.contains(index) ? demo[index] : "")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(appearance.primary)
                    .opacity(row == anchor ? 1 : (row < anchor ? appearance.pastLyricOpacity : appearance.futureLyricOpacity))
                    .lineLimit(1)
                    .frame(height: lineHeight, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 铺满封面那一块在预览这块屏里的位置,给封面下面那截延伸定位。
private struct PreviewFullBleedRegionKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
#endif
