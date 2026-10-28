#if os(iOS)
import PrimuseKit
import SwiftUI

// 「播放页样式与按钮」预览里音乐封面、歌词以外的几种播放页:全屏歌词、全屏效果、有声书、播客、电台。
// 都按真机尺寸排(`NowPlayingPreviewContext.canvas`),版面照播放页那几处的写法;有声内容和电台用示例文字。

// MARK: - 全屏歌词

/// 原生全屏(竖屏):背景同播放页,歌词铺满整屏;顶上一排圆钮(锁、封面、全屏效果、能换的两格、更多、退出),
/// 底下进度与播放键直接摆在背景上,两侧各一格。版面照 `NowPlayingView.immersiveLyricsChrome`。
struct ImmersiveLyricsPreviewScreen: View {
    let context: NowPlayingPreviewContext

    @Environment(AudioPlayerService.self) private var player
    @Environment(ThemeService.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var storage = ""
    @AppStorage(NowPlayingLyricsPageControls.storageKey) private var lyricsStorage = ""
    @AppStorage(NowPlayingImmersiveLyricsControls.storageKey) private var immersiveStorage = ""
    @AppStorage(PlayerAppearancePreferences.controlTintKey)
    private var controlTintRawValue = NowPlayingControlTint.theme.rawValue
    @AppStorage(PlayerAppearancePreferences.playButtonStyleKey)
    private var playButtonStyleRawValue = NowPlayingPlayButtonStyle.filledCircle.rawValue

    /// 播放条那一块的高度(进度 36 + 间距 14 + 播放键 68),和播放页同一个值。
    private static let dockHeight: CGFloat = 118

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var controls: NowPlayingImmersiveLyricsControls { .decode(immersiveStorage) }

    /// 「跟歌名旁」跟的是看歌词时歌名旁那一格。
    private var followedHeader: NowPlayingControlAction? {
        let lyricsLayout = NowPlayingLyricsPageControls.decode(lyricsStorage).resolvedLayout(cover: .decode(storage))
        return NowPlayingImmersiveLyricsControls.followedHeaderAction(lyricsLayout.action(in: .header))
    }

    private func shownAction(in slot: NowPlayingImmersiveLyricsSlot) -> NowPlayingControlAction? {
        switch controls.choice(in: slot) {
        case .followHeader: followedHeader
        case .action(let action): action
        case .empty: nil
        }
    }

    /// 这一格在页面上出不出现:放了按钮的出现;空着的只在编辑、或正挑它时画个占位。
    private func showsCell(_ slot: NowPlayingImmersiveLyricsSlot) -> Bool {
        shownAction(in: slot) != nil || context.showsPlaceholder(for: .immersive(slot))
    }

    var body: some View {
        let canvas = context.canvas
        let bottomInset = max(canvas.bottomSafeArea, 12) + 8
        let topCells = [NowPlayingImmersiveLyricsSlot.topPrimary, .topSecondary].filter(showsCell)
        let dockEdges = showsCell(.dockLeading) || showsCell(.dockTrailing)
        let accent = nowPlayingPreviewAccent(
            appearance: appearance,
            theme: theme,
            controlTintRawValue: controlTintRawValue
        )

        ZStack {
            PreviewPlayerBackdrop(song: player.isLiveRadio ? nil : player.currentSong)

            PreviewLyricLines(
                tint: appearance.primary,
                pastOpacity: appearance.pastLyricOpacity,
                futureOpacity: appearance.futureLyricOpacity,
                anchor: 0.36
            )
            // 控件在时歌词在播放条上沿之前淡完,不和按钮叠在一起。
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 56)
                    Color.clear
                        .frame(height: bottomInset + Self.dockHeight + 16)
                }
            }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    PreviewGlassCircle(symbol: "lock")
                    Spacer(minLength: 0)
                    // 顶上两格不满两颗时,空出来的位置给「看封面」那一颗。
                    if topCells.count < 2 {
                        PreviewGlassCircle(symbol: "photo")
                    }
                    PreviewGlassCircle(symbol: "viewfinder.rectangular")
                    ForEach(topCells) { slot in
                        PreviewSlotCell(target: .immersive(slot), context: context, cornerRadius: 22) {
                            PreviewGlassCircle(symbol: shownAction(in: slot).map(Self.symbol) ?? "plus")
                        }
                    }
                    PreviewGlassCircle(symbol: "ellipsis")
                    PreviewGlassCircle(symbol: "arrow.down.right.and.arrow.up.left")
                }
                .padding(.horizontal, 20)
                .padding(.top, max(canvas.topSafeArea, 10) + 8)

                Spacer(minLength: 0)

                VStack(spacing: 14) {
                    PreviewProgressBar(fillTint: accent, timeTint: appearance.tertiary)
                        .padding(.horizontal, 6)
                    HStack(spacing: 10) {
                        if dockEdges {
                            dockEdge(.dockLeading)
                        }
                        Spacer(minLength: 0)
                        PreviewSkipGlyph(forward: false, tint: appearance.primary)
                        dockPlayButton
                        PreviewSkipGlyph(forward: true, tint: appearance.primary)
                        Spacer(minLength: 0)
                        if dockEdges {
                            dockEdge(.dockTrailing)
                        }
                    }
                    .frame(height: 68)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
        }
        .frame(width: canvas.size.width, height: canvas.size.height)
    }

    private static func symbol(_ action: NowPlayingControlAction) -> String {
        action == .airPlay ? "airplayaudio" : action.editorSymbol
    }

    private func dockEdge(_ slot: NowPlayingImmersiveLyricsSlot) -> some View {
        PreviewSlotCell(target: .immersive(slot), context: context) {
            Group {
                if let action = shownAction(in: slot) {
                    Image(systemName: Self.symbol(action))
                        .font(.body)
                        .foregroundStyle(appearance.tertiary)
                } else {
                    PreviewEmptySlotFace(
                        showsPlaceholder: context.showsPlaceholder(for: .immersive(slot)),
                        tint: appearance.faint
                    )
                }
            }
            .frame(width: 44, height: 44)
        }
    }

    /// 底排的播放键:实心圆里的三角用背景底色;别的样式和竖屏那颗同一种画法。
    @ViewBuilder
    private var dockPlayButton: some View {
        let style = PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue)
        if style == .filledCircle {
            ZStack {
                Circle().fill(appearance.primary)
                Image(systemName: "pause.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(appearance.backgroundBase)
            }
            .frame(width: 68, height: 68)
            .accessibilityHidden(true)
        } else {
            NowPlayingPlayPauseFace(style: style, showsPause: true, diameter: 68 * 0.86, tint: appearance.primary)
                .frame(width: 68, height: 68)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 全屏效果

/// 全屏效果页(竖屏):设置里选的那种效果画满整屏(选的是原生全屏时拿第一种效果来演示),
/// 顶上收起、效果抽屉与能换的一格,底下玻璃胶囊里的播放键两侧各一格。版面照 `ImmersivePlayerView.chrome`。
struct EffectPlayerPreviewScreen: View {
    let context: NowPlayingPreviewContext

    @Environment(ThemeService.self) private var theme
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var effectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(NowPlayingEffectPlayerControls.storageKey) private var effectStorage = ""

    private var controls: NowPlayingEffectPlayerControls { .decode(effectStorage) }

    private var effect: FullscreenPlayerEffect {
        let selected = FullscreenPlayerEffect(rawValue: effectRawValue) ?? .defaultValue
        return selected.isNative ? (FullscreenPlayerEffect.immersiveCases.first ?? selected) : selected
    }

    private func showsCell(_ slot: NowPlayingEffectPlayerSlot) -> Bool {
        controls.action(in: slot) != nil || context.showsPlaceholder(for: .effect(slot))
    }

    var body: some View {
        let canvas = context.canvas
        let metrics = ImmersiveStageMetrics(
            size: canvas.size,
            safeArea: EdgeInsets(top: canvas.topSafeArea, leading: 0, bottom: canvas.bottomSafeArea, trailing: 0),
            isHandheld: true
        )
        let palette = ImmersiveArtworkPalette(primary: theme.accentColor, secondary: theme.secondaryDarkAccent)
        let ink = ImmersiveStagePalette.ink
        let pillEdges = showsCell(.pillLeading) || showsCell(.pillTrailing)

        ZStack {
            ImmersiveDemoStage.make(
                effect: effect,
                metrics: metrics,
                palette: palette,
                levels: ImmersiveDemoStage.baseLevels,
                elapsed: 108,
                animates: context.animatesStage,
                controlsInset: metrics.s(106),
                song: .current(player: player, library: library)
            )
            .frame(width: canvas.size.width, height: canvas.size.height)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ImmersiveGlassActionLabel(symbol: "chevron.down")
                    Spacer(minLength: 0)
                    ImmersiveGlassActionLabel(symbol: "viewfinder.rectangular")
                    if showsCell(.topTrailing) {
                        PreviewSlotCell(target: .effect(.topTrailing), context: context, cornerRadius: 22) {
                            ImmersiveGlassActionLabel(symbol: controls.action(in: .topTrailing).map(Self.symbol) ?? "plus")
                        }
                    }
                }
                .accessibilityHidden(context.slotMode != .editable)
                .padding(.horizontal, 20)
                .padding(.top, max(canvas.topSafeArea + 10, metrics.s(55)))

                Spacer(minLength: 0)

                ImmersiveGlassPill(horizontalPadding: metrics.s(18), verticalPadding: metrics.s(8)) {
                    HStack(spacing: metrics.s(18)) {
                        if pillEdges {
                            pillEdge(.pillLeading, ink: ink)
                        }
                        pillGlyph("backward.fill", ink: ink)
                        ZStack {
                            Circle().fill(palette.primary.opacity(0.06))
                            Circle().strokeBorder(palette.primary.opacity(0.72), lineWidth: 1.2)
                            Image(systemName: "pause.fill")
                                .font(.system(size: 48 * 0.38, weight: .semibold))
                                .foregroundStyle(palette.primary)
                        }
                        .frame(width: 48, height: 48)
                        pillGlyph("forward.fill", ink: ink)
                        if pillEdges {
                            pillEdge(.pillTrailing, ink: ink)
                        }
                    }
                }
                .padding(.bottom, max(canvas.bottomSafeArea + 10, 18))
            }
        }
        .frame(width: canvas.size.width, height: canvas.size.height)
    }

    private static func symbol(_ action: NowPlayingControlAction) -> String {
        switch action {
        case .airPlay: "airplayaudio"
        case .queue: "list.bullet"
        default: action.editorSymbol
        }
    }

    private func pillGlyph(_ symbol: String, ink: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(ink.opacity(0.88))
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
    }

    private func pillEdge(_ slot: NowPlayingEffectPlayerSlot, ink: Color) -> some View {
        PreviewSlotCell(target: .effect(slot), context: context, cornerRadius: 19) {
            Group {
                if let action = controls.action(in: slot) {
                    pillGlyph(Self.symbol(action), ink: ink)
                } else {
                    PreviewEmptySlotFace(
                        showsPlaceholder: context.showsPlaceholder(for: .effect(slot)),
                        tint: ink.opacity(0.5)
                    )
                    .frame(width: 38, height: 38)
                }
            }
        }
    }
}

// MARK: - 有声内容共用

/// 有声书、播客那一排功能块:图标(语速写倍数)在上、说明在下,或排成一行。
private struct PreviewSpokenTiles: View {
    let kind: SpokenWordPlayerKind
    let tiles: [SpokenWordControlTile]
    let labelStyle: SpokenWordTileLabelStyle
    var stacked = true
    let height: CGFloat
    let primary: Color
    let secondary: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tiles) { tile in
                Group {
                    if stacked {
                        VStack(spacing: 6) {
                            icon(tile)
                                .frame(height: 24)
                            if labelStyle == .iconAndText {
                                caption(tile)
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            icon(tile)
                            if labelStyle == .iconAndText {
                                caption(tile)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func icon(_ tile: SpokenWordControlTile) -> some View {
        if tile == .speed {
            Text(verbatim: "1×")
                .font(.title3.weight(.light).monospacedDigit())
                .foregroundStyle(primary)
        } else {
            Image(systemName: tile.editorSymbol(for: kind))
                .font(.title3.weight(.light))
                .foregroundStyle(primary)
        }
    }

    private func caption(_ tile: SpokenWordControlTile) -> some View {
        Text(tile.editorTitleKey(for: kind))
            .font(.caption)
            .foregroundStyle(secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// 有声书、播客的示例封面:主题色的渐变上一个图标。
private struct PreviewSpokenCover: View {
    let symbol: String
    let cornerRadius: CGFloat

    @Environment(ThemeService.self) private var theme

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [theme.accentColor.opacity(0.9), theme.darkAccent],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
        }
        .accessibilityHidden(true)
    }
}

/// 有声内容播放键两侧(及有声书章节那一行)能换的一格。
private struct PreviewSpokenSlotKey: View {
    let kind: SpokenWordPlayerKind
    let slot: SpokenWordControlSlot
    let action: SpokenWordSlotAction?
    let context: NowPlayingPreviewContext
    let font: Font
    let tint: Color
    let faint: Color
    var height: CGFloat = 44

    var body: some View {
        PreviewSlotCell(target: .spoken(kind, slot), context: context) {
            Group {
                if action == .chapters, slot == .partRow {
                    // 章节那一行放的是上一章 / 下一章:两颗,和不换按钮时一样。
                    HStack(spacing: 0) {
                        Image(systemName: "backward.end.fill")
                            .frame(width: 44)
                        Image(systemName: "forward.end.fill")
                            .frame(width: 44)
                    }
                    .font(.callout)
                    .foregroundStyle(tint)
                } else if let action {
                    Image(systemName: action.editorSymbol(for: kind, in: slot))
                        .font(font)
                        .foregroundStyle(tint)
                } else {
                    PreviewEmptySlotFace(
                        showsPlaceholder: context.showsPlaceholder(for: .spoken(kind, slot)),
                        tint: faint
                    )
                }
            }
            .frame(minWidth: 44)
            .frame(height: height)
        }
    }
}

// MARK: - 有声书

/// 有声书的专版(深色墨黑、浅色暖白):顶栏、书名与封面那一块、当前章节、细进度、实心圆播放键与两侧两格、
/// 功能块与音量、最底下规格与音乐源。版面照 `NowPlayingView.audiobookPortraitLayout`。
struct AudiobookPreviewScreen: View {
    let context: NowPlayingPreviewContext

    @Environment(AudioPlayerService.self) private var player
    @Environment(ThemeService.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(SpokenWordControlLayout.storageKey(for: .audiobook)) private var storage = ""
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.progressStyleKey)
    private var progressStyleRawValue = NowPlayingProgressStyle.standard.rawValue
    @AppStorage(PlayerAppearancePreferences.progressGlowKey)
    private var progressGlows = PlayerAppearancePreferences.progressGlowByDefault
    @AppStorage(PlayerAppearancePreferences.progressStyleAppliesToAudiobooksKey)
    private var followsProgressStyle = PlayerAppearancePreferences.progressStyleAppliesToAudiobooksByDefault
    @AppStorage(PlayerAppearancePreferences.audiobookPlayButtonStyleKey)
    private var playButtonStyleRawValue = NowPlayingPlayButtonStyle.filledCircle.rawValue

    private var style: AudiobookPlayerStyle {
        AudiobookPlayerStyle(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var layout: SpokenWordControlLayout { .decode(storage, kind: .audiobook) }

    /// 按有文字稿的一条摆(选「自动」的格子就是那样)。
    private var controls: SpokenWordResolvedControls {
        layout.resolved(in: SpokenWordControlContext(hasTranscript: true, hasPartRow: true))
    }

    /// 和 `AudiobookProgressBar` 同一个取法:打开了「有声书也用」时三种都照音乐播放页画,
    /// 否则只有选了波浪才换掉自己那根细线。
    private var trackStyle: ProgressSlider.TrackStyle {
        AudiobookProgressBar.trackStyle(
            selected: PlayerAppearancePreferences.progressStyle(rawValue: progressStyleRawValue),
            glows: progressGlows,
            followsProgressStyle: followsProgressStyle,
            trackColor: style.track
        )
    }

    var body: some View {
        let canvas = context.canvas
        let style = self.style
        let isShort = canvas.size.height < 760
        let contentWidth = max(0, min(canvas.size.width, 680) - 56)
        let columnWidth = min(max((contentWidth * 0.23).rounded(), 72), 120)
        let gap = NowPlayingView.portraitControlGap(forHeight: canvas.size.height)
        let controls = self.controls

        ZStack {
            if style.isNocturne && PlayerBackdropSettingsStore.shared.settings.appliesToAudiobooks {
                PreviewPlayerBackdrop(song: nil)
            } else {
                style.background
            }

            VStack(spacing: 0) {
                if usesGrabber(controls) {
                    // 顶上的键都关掉了时只剩一根把手。
                    Capsule()
                        .fill(style.tertiary)
                        .frame(width: 48, height: 5)
                        .padding(.top, canvas.topSafeArea + 6)
                        .padding(.bottom, 10)
                } else {
                    topBar(controls: controls)
                        .padding(.top, canvas.topSafeArea)
                }

                VStack(spacing: 0) {
                    // 上下几段空白和播放页一样分(`AudiobookPortraitRhythm`,#367)。
                    if style.isNocturne {
                        Spacer(minLength: 0)
                        AudiobookPortraitRhythm.gap(minimum: isShort ? 8 : 16, limit: AudiobookPortraitRhythm.framingLimit)
                        titleBlock
                        // 封面顶边和左边「CHAPTER」对齐。
                        heroRow(columnLeading: true, columnWidth: columnWidth, spacing: 24)
                            .padding(.top, isShort ? 24 : 32)
                            .layoutPriority(2)
                        AudiobookPortraitRhythm.gap(minimum: isShort ? 16 : 28, limit: AudiobookPortraitRhythm.framingLimit)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                        AudiobookPortraitRhythm.gap(minimum: isShort ? 8 : 14, limit: AudiobookPortraitRhythm.framingLimit)
                        HStack(spacing: 12) {
                            AudiobookPlayerEyebrow(key: "spoken_word_player_now_listening", style: style)
                            Rectangle()
                                .fill(style.hairline)
                                .frame(height: 0.5)
                        }
                        heroRow(columnLeading: false, columnWidth: columnWidth, spacing: 28)
                            .padding(.top, isShort ? 14 : 22)
                            .layoutPriority(2)
                        titleBlock
                            .padding(.top, isShort ? 16 : 26)
                        AudiobookPortraitRhythm.gap(minimum: isShort ? 12 : 22, limit: AudiobookPortraitRhythm.framingLimit)
                        Spacer(minLength: 0)
                    }

                    partRow(controls: controls)

                    PreviewProgressBar(
                        fillTint: style.control(paper: style.accent),
                        timeTint: style.tertiary,
                        trackStyle: trackStyle
                    )
                        .padding(.top, 4)

                    let centering = AudiobookPortraitRhythm.transportCentering(
                        style: style,
                        belowIsActionRow: !showsVolumeBar,
                        showsCaptions: layout.tileLabelStyle == .iconAndText
                    )
                    AudiobookPortraitRhythm.gap(
                        minimum: (isShort ? 10 : 16) + gap * 0.5,
                        limit: AudiobookPortraitRhythm.controlLimit
                    )
                    transportRow(controls: controls, isShort: isShort)
                        .padding(.top, max(0, centering))
                        .padding(.bottom, max(0, -centering))
                    AudiobookPortraitRhythm.gap(
                        minimum: style.isNocturne
                            ? (showsVolumeBar ? (isShort ? 10 : 16) : (isShort ? 6 : 12) + gap * 0.3)
                            : (isShort ? 12 : 20) + gap * 0.3,
                        limit: AudiobookPortraitRhythm.controlLimit
                    )

                    if style.isNocturne {
                        if showsVolumeBar {
                            PreviewVolumeRow(
                                primary: style.primary,
                                iconTint: style.tertiary,
                                fillTint: style.control(paper: style.accent),
                                matchedTrack: trackStyle
                            )
                                .padding(.horizontal, 12)
                        }
                        PreviewSpokenTiles(
                            kind: .audiobook,
                            tiles: controls.tiles,
                            labelStyle: layout.tileLabelStyle,
                            height: 54,
                            primary: style.control(paper: style.primary),
                            secondary: style.control(paper: style.secondary)
                        )
                        .padding(.top, showsVolumeBar ? (isShort ? 6 : 12) + gap * 0.3 : 0)
                    } else {
                        Rectangle()
                            .fill(style.hairline)
                            .frame(height: 0.5)
                        PreviewSpokenTiles(
                            kind: .audiobook,
                            tiles: controls.tiles,
                            labelStyle: layout.tileLabelStyle,
                            stacked: false,
                            height: 40,
                            primary: style.control(paper: style.primary),
                            secondary: style.control(paper: style.secondary)
                        )
                        .padding(.top, 6)
                        if showsVolumeBar {
                            PreviewVolumeRow(
                                primary: style.primary,
                                iconTint: style.tertiary,
                                fillTint: style.control(paper: style.accent),
                                matchedTrack: trackStyle
                            )
                                .padding(.horizontal, 12)
                                .padding(.top, 4)
                        }
                    }

                    footer
                        .padding(.top, style.isNocturne ? (isShort ? 4 : 8) : (showsVolumeBar ? 4 : 0))
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 680)

                Color.clear
                    .frame(height: max(canvas.bottomSafeArea, 12))
            }
        }
        .frame(width: canvas.size.width, height: canvas.size.height)
    }

    private func usesGrabber(_ controls: SpokenWordResolvedControls) -> Bool {
        !(controls.headerShowsAirPlay || controls.headerShowsLike || controls.headerShowsMore)
    }

    private func topBar(controls: SpokenWordResolvedControls) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(style.control(paper: style.primary))
                .frame(width: 44, height: 44)
            Spacer(minLength: 0)
            if controls.headerShowsAirPlay {
                headerIcon("airplayaudio", width: 40)
            }
            if controls.headerShowsLike {
                headerIcon("heart", width: 40)
            }
            if controls.headerShowsMore {
                headerIcon("ellipsis", width: 44)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .accessibilityHidden(true)
    }

    private func headerIcon(_ symbol: String, width: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(style.control(paper: style.secondary))
            .frame(width: width, height: 44)
    }

    private func heroRow(columnLeading: Bool, columnWidth: CGFloat, spacing: CGFloat) -> some View {
        AudiobookHeroRowLayout(columnLeading: columnLeading, columnWidth: columnWidth, spacing: spacing, maxSide: 480) {
            chapterColumn
            PreviewSpokenCover(symbol: "book.closed", cornerRadius: 4)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(style.hairline, lineWidth: 0.5)
                }
                .shadow(
                    color: style.isNocturne
                        ? .black.opacity(0.55)
                        : Color(red: 0.30, green: 0.22, blue: 0.12).opacity(0.22),
                    radius: style.isNocturne ? 22 : 16,
                    y: style.isNocturne ? 12 : 10
                )
        }
    }

    /// 章号那一栏:「CHAPTER / 3 / ⁄ 24」,一条短竖线上的点是全书听到哪儿,再下面「全书 18%」。
    private var chapterColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            AudiobookPlayerEyebrow(
                key: style.isNocturne ? "spoken_word_player_chapter_eyebrow" : "spoken_word_player_current_part",
                style: style
            )
            Text(verbatim: "3")
                .font(style.isNocturne
                    ? .system(size: 64, weight: .thin)
                    : .system(size: 64, weight: .regular, design: .serif))
                .foregroundStyle(style.primary)
                .padding(.top, style.isNocturne ? 4 : 2)
            Text(verbatim: "/ 24")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(style.tertiary)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(style.track)
                    .frame(width: 1, height: 40)
                Circle()
                    .fill(style.bookMarker)
                    .frame(width: 5, height: 5)
                    .offset(y: 40 * 0.18 - 2.5)
            }
            .frame(width: 5, height: 40)
            .padding(.top, style.isNocturne ? 26 : 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: SpokenWordPlayerText.bookFraction(0.18))
                if let remaining = SpokenWordPlayerText.bookRemaining(
                    SpokenWordNowPlayingSummary(bookRemaining: 18 * 3_600), rate: 1
                ) {
                    Text(verbatim: remaining)
                }
            }
            .font(.caption2)
            .foregroundStyle(style.tertiary)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, style.isNocturne ? 0 : 20)
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("player_preview_sample_book")
                .font(style.isNocturne
                    ? .system(size: 30, weight: .semibold)
                    : .system(size: 30, weight: .light, design: .serif))
                .tracking(style.isNocturne ? 0 : 1)
                .foregroundStyle(style.primary)
                .lineLimit(2)
            Text("player_preview_sample_author")
                .font(.subheadline)
                .foregroundStyle(style.secondary)
                .padding(.top, style.isNocturne ? 10 : 12)
            Text("player_preview_sample_narrator")
                .font(.footnote)
                .foregroundStyle(style.tertiary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    /// 当前章节那一行:章号 | 章名,右边上一章 / 下一章或「章节那一行」那一格。
    private func partRow(controls: SpokenWordResolvedControls) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "03")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(style.primary)
            Rectangle()
                .fill(style.tertiary)
                .frame(width: 1, height: 14)
            Text("player_preview_sample_chapter")
                .font(style.isNocturne ? .body.weight(.medium) : .body)
                .foregroundStyle(style.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if controls.partRow != nil || context.showsPlaceholder(for: .spoken(.audiobook, .partRow)) {
                PreviewSpokenSlotKey(
                    kind: .audiobook,
                    slot: .partRow,
                    action: controls.partRow,
                    context: context,
                    font: .system(size: 18),
                    tint: style.control(paper: style.primary),
                    faint: style.faint
                )
            } else if layout.showsChapterButtons {
                HStack(spacing: 0) {
                    Image(systemName: "backward.end.fill")
                        .frame(width: 44, height: 44)
                    Image(systemName: "forward.end.fill")
                        .frame(width: 44, height: 44)
                }
                .font(.callout)
                .foregroundStyle(style.control(paper: style.primary))
                .padding(.trailing, -13)
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
    }

    /// 和播放页一样左右两半各自排开,空着的那一边不留空位;编辑时两格都画出虚线框好点。
    private func transportRow(controls: SpokenWordResolvedControls, isShort: Bool) -> some View {
        let diameter: CGFloat = isShort ? 64 : 72
        let editable = context.slotMode == .editable
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                if editable || controls.leadingSide != nil {
                    sideKey(.leadingSide, action: controls.leadingSide)
                }
                Spacer(minLength: 0)
                skipGlyph(player.spokenWordSkipBackwardSymbol)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            // 和播放页一样:实心圆是这一版自己的那颗,别的样式照音乐页画(#329)。
            let playStyle = PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue)
            ZStack {
                if playStyle == .filledCircle {
                    Circle().fill(style.accent)
                    Image(systemName: "pause.fill")
                        .font(.system(size: diameter * 0.36, weight: .semibold))
                        .foregroundStyle(style.onAccent)
                } else {
                    NowPlayingPlayPauseFace(style: playStyle, showsPause: true, diameter: diameter * 0.86, tint: style.accent)
                }
            }
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                skipGlyph(player.spokenWordSkipForwardSymbol)
                Spacer(minLength: 0)
                if editable || controls.trailingSide != nil {
                    sideKey(.trailingSide, action: controls.trailingSide)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func skipGlyph(_ symbol: String) -> some View {
        let playStyle = PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue)
        return Image(systemName: symbol)
            .font(.system(size: 28 * NowPlayingSkipButtonStyle.pairingScale(with: playStyle), weight: .light))
            .foregroundStyle(style.primary)
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
    }

    private func sideKey(_ slot: SpokenWordControlSlot, action: SpokenWordSlotAction?) -> some View {
        PreviewSpokenSlotKey(
            kind: .audiobook,
            slot: slot,
            action: action,
            context: context,
            font: .system(size: 22, weight: .light),
            tint: style.control(paper: style.secondary),
            faint: style.faint,
            height: 56
        )
    }

    /// 最底下那行:格式与采样率,打开了就再写音乐源。
    private var footer: some View {
        HStack(spacing: 5) {
            Text(verbatim: "M4B · 44.1 kHz")
            if layout.showsSource {
                Text(verbatim: "·")
                Image(systemName: "externaldrive")
                    .imageScale(.small)
                Text(verbatim: "NAS")
            }
        }
        .font(.caption2)
        .tracking(0.6)
        .foregroundStyle(style.faint)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: - 播客

/// 播客竖屏:封面、单集标题与节目名、进度、快退快进两边各一对上一章 / 下一章,外面再各一格,
/// 下面一排功能块。版面照 `NowPlayingView.portraitLayout` 的有声内容那一支。
struct PodcastPreviewScreen: View {
    let context: NowPlayingPreviewContext

    @Environment(AudioPlayerService.self) private var player
    @Environment(ThemeService.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(SpokenWordControlLayout.storageKey(for: .podcast)) private var storage = ""
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.controlTintKey)
    private var controlTintRawValue = NowPlayingControlTint.theme.rawValue
    @AppStorage(PlayerAppearancePreferences.podcastArtworkStyleKey)
    private var artworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var layout: SpokenWordControlLayout { .decode(storage, kind: .podcast) }

    /// 和播放页一样只在 iPhone 上铺满。
    private var usesFullBleedArtwork: Bool {
        context.canvas.isPhone
            && PlayerAppearancePreferences.artworkStyle(rawValue: artworkStyleRawValue) == .fullBleed
    }

    private var controls: SpokenWordResolvedControls {
        layout.resolved(in: SpokenWordControlContext(hasTranscript: true, hasInnerChapterPair: true))
    }

    var body: some View {
        let canvas = context.canvas
        let size = canvas.size
        let artSize = NowPlayingView.portraitArtworkSize(in: size)
        let gap = NowPlayingView.portraitControlGap(forHeight: size.height)
        let volumeSlack: CGFloat = showsVolumeBar ? 0 : NowPlayingView.portraitVolumeRowHeight + 10 + gap
        let barLift = NowPlayingView.portraitBottomBarLift(bottomSafeArea: canvas.bottomSafeArea)
        let controls = self.controls
        let accent = nowPlayingPreviewAccent(
            appearance: appearance,
            theme: theme,
            controlTintRawValue: controlTintRawValue
        )
        let grabberBand = canvas.topSafeArea + 21

        ZStack {
            PreviewPlayerBackdrop(song: nil)

            VStack(spacing: 0) {
                Capsule()
                    .fill(appearance.tertiary)
                    .frame(width: 48, height: 5)
                    .padding(.top, canvas.topSafeArea + 6)
                    .padding(.bottom, 10)

                if usesFullBleedArtwork {
                    // 铺满:这一块只占把手以下的高度,封面往上伸到屏幕顶端(照 `NowPlayingView.fullBleedArtworkRegion`)。
                    GeometryReader { region in
                        PreviewFullBleedArtwork(
                            width: size.width,
                            height: region.size.height + grabberBand,
                            topSafeArea: canvas.topSafeArea,
                            appearance: appearance
                        ) {
                            PreviewSpokenCover(symbol: "mic", cornerRadius: 0)
                        }
                        .frame(width: region.size.width, height: region.size.height, alignment: .bottom)
                    }
                    .frame(maxHeight: NowPlayingView.fullBleedArtworkRegionLimit(
                        width: size.width,
                        topSafeArea: canvas.topSafeArea,
                        extendsBelowSquare: true
                    ))
                    .layoutPriority(1)
                    .zIndex(1)
                } else {
                    Spacer(minLength: 0)
                        .frame(maxHeight: 16 + volumeSlack * 0.4)
                    GeometryReader { region in
                        let side = min(artSize, max(1, region.size.height - 24))
                        PreviewSpokenCover(symbol: "mic", cornerRadius: 12)
                            .frame(width: side, height: side)
                            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: artSize + 24)
                    .layoutPriority(1)
                }

                // 铺满时单集标题贴着进度条,空白在封面与标题之间(照 `NowPlayingView.portraitLayout`)。
                if usesFullBleedArtwork {
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                        .frame(maxHeight: 16)
                }

                heading(controls: controls)
                    .padding(.horizontal, 26)
                    .padding(.top, 12)

                if !usesFullBleedArtwork {
                    Spacer(minLength: 0)
                }

                PreviewProgressBar(fillTint: accent, timeTint: appearance.tertiary)
                    .padding(.horizontal, 26)
                    .padding(.top, 8)

                transportRow(controls: controls)
                    .padding(.top, 12 + gap * 0.75 + volumeSlack * 0.3)

                if showsVolumeBar {
                    PreviewVolumeRow(primary: appearance.primary, iconTint: appearance.tertiary, fillTint: accent)
                        .padding(.horizontal, 26)
                        .padding(.top, 10 + gap)
                }

                PreviewSpokenTiles(
                    kind: .podcast,
                    tiles: controls.tiles,
                    labelStyle: layout.tileLabelStyle,
                    height: 54,
                    primary: appearance.primary,
                    secondary: appearance.secondary
                )
                .padding(.horizontal, 22)
                .padding(.top, 12 + max(0, gap * 0.75 + volumeSlack * 0.3 - barLift))
                .padding(.bottom, barLift)

                Color.clear
                    .frame(height: NowPlayingView.portraitStatusBandHeight(bottomSafeArea: canvas.bottomSafeArea))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func heading(controls: SpokenWordResolvedControls) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text("player_preview_sample_episode")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    if controls.headerShowsAirPlay {
                        headerIcon("airplayaudio", width: 40)
                    }
                    if controls.headerShowsLike {
                        headerIcon("heart", width: 40)
                    }
                    if controls.headerShowsMore {
                        headerIcon("ellipsis", width: 44)
                    }
                }
                .fixedSize()
            }
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Text("player_preview_sample_show")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(appearance.secondary)
                Text(Date.now.addingTimeInterval(-3 * 86_400), format: .dateTime.month().day())
                    .foregroundStyle(appearance.tertiary)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .lineLimit(1)
        }
        .accessibilityHidden(true)
    }

    private func headerIcon(_ symbol: String, width: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(appearance.secondary)
            .frame(width: width, height: 44)
    }

    /// 快退快进两边各一颗上一章 / 下一章,外面两格按「播放页按钮」摆。和播放页一样左右两半各自排开,
    /// 空着的格不留空位;三颗键时两头各留一个键位的空白。编辑时两格都画出虚线框好点。
    private func transportRow(controls: SpokenWordResolvedControls) -> some View {
        let editable = context.slotMode == .editable
        let showsLeading = editable || controls.leadingSide != nil
        let showsTrailing = editable || controls.trailingSide != nil
        let keepsCompact = !showsLeading && !showsTrailing && !controls.showsInnerChapters
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsLeading {
                    Spacer(minLength: 0)
                    sideKey(.leadingSide, action: controls.leadingSide)
                }
                if controls.showsInnerChapters {
                    Spacer(minLength: 0)
                    chapterButton("backward.end.fill")
                } else if keepsCompact {
                    Spacer(minLength: 0)
                    Color.clear.frame(width: 44, height: 44)
                }
                Spacer(minLength: 0)
                PreviewSkipGlyph(
                    forward: false,
                    tint: appearance.primary,
                    fixedSymbol: player.spokenWordSkipBackwardSymbol,
                    playStyleKey: PlayerAppearancePreferences.podcastPlayButtonStyleKey
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            PreviewPlayGlyph(
                tint: appearance.primary,
                styleKey: PlayerAppearancePreferences.podcastPlayButtonStyleKey
            )
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                PreviewSkipGlyph(
                    forward: true,
                    tint: appearance.primary,
                    fixedSymbol: player.spokenWordSkipForwardSymbol,
                    playStyleKey: PlayerAppearancePreferences.podcastPlayButtonStyleKey
                )
                Spacer(minLength: 0)
                if controls.showsInnerChapters {
                    chapterButton("forward.end.fill")
                    Spacer(minLength: 0)
                } else if keepsCompact {
                    Color.clear.frame(width: 44, height: 44)
                    Spacer(minLength: 0)
                }
                if showsTrailing {
                    sideKey(.trailingSide, action: controls.trailingSide)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func chapterButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(appearance.secondary)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }

    private func sideKey(_ slot: SpokenWordControlSlot, action: SpokenWordSlotAction?) -> some View {
        PreviewSpokenSlotKey(
            kind: .podcast,
            slot: slot,
            action: action,
            context: context,
            font: .body,
            tint: appearance.secondary,
            faint: appearance.faint
        )
    }
}

// MARK: - 电台

/// 电台竖屏:台标、台名与正在播出、直播标签、上一台 / 停止 / 下一台、音量条,最下面那一排按「电台」那一页的
/// 顺序与显隐摆。版面照 `NowPlayingView.liveRadioLayout`。
struct RadioPreviewScreen: View {
    let context: NowPlayingPreviewContext

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(NowPlayingRadioControlLayout.storageKey) private var storage = ""
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.radioArtworkStyleKey)
    private var artworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.radioPlayButtonStyleKey)
    private var playButtonStyleRawValue = NowPlayingPlayButtonStyle.filledCircle.rawValue
    @AppStorage(PlayerAppearancePreferences.radioSkipButtonStyleKey)
    private var skipButtonStyleRawValue = NowPlayingSkipButtonStyle.standard.rawValue
    @AppStorage(PlayerAppearancePreferences.controlTintKey)
    private var controlTintRawValue = NowPlayingControlTint.theme.rawValue
    @Environment(ThemeService.self) private var theme

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        let canvas = context.canvas
        let skipStyle = PlayerAppearancePreferences.skipButtonStyle(rawValue: skipButtonStyleRawValue)
        let radioPlayStyle = PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue)
        let radioAccent = nowPlayingPreviewAccent(
            appearance: appearance,
            theme: theme,
            controlTintRawValue: controlTintRawValue
        )
        let size = canvas.size
        let gap = NowPlayingView.portraitControlGap(forHeight: size.height)
        let layout = NowPlayingRadioControlLayout.decode(storage)
        let showsVolume = showsVolumeBar && layout.showsVolumeBar
        let logoSide = min(size.width * 0.8, 430)
        // 和播放页一样只在 iPhone 竖屏上铺满。
        let fullBleedLogo = canvas.isPhone
            && PlayerAppearancePreferences.artworkStyle(rawValue: artworkStyleRawValue) == .fullBleed

        ZStack {
            PreviewPlayerBackdrop(song: nil)

            VStack(spacing: 0) {
                if fullBleedLogo {
                    // 台标从屏幕顶端铺满整宽,最多画成正方形(照 `NowPlayingView.liveRadioFullBleedLogo`)。
                    GeometryReader { region in
                        PreviewFullBleedArtwork(
                            width: region.size.width,
                            height: region.size.height,
                            topSafeArea: canvas.topSafeArea,
                            appearance: appearance,
                            allowsTopSoftening: false
                        ) {
                            RadioStationPlaceholderArtwork()
                        }
                    }
                    .frame(maxHeight: size.width)
                    .layoutPriority(1)
                    .accessibilityHidden(true)
                } else {
                    Capsule()
                        .fill(appearance.tertiary)
                        .frame(width: 48, height: 5)
                        .padding(.top, canvas.topSafeArea + 6)

                    Spacer(minLength: 12)

                    RadioStationPlaceholderArtwork()
                        .frame(width: logoSide, height: logoSide)
                        .clipShape(RoundedRectangle(cornerRadius: max(18, logoSide * 0.06), style: .continuous))
                        .shadow(color: .black.opacity(0.34), radius: 28, y: 14)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 22)

                VStack(spacing: 8) {
                    Text("player_preview_sample_station")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(appearance.primary)
                        .lineLimit(1)
                    Text("player_preview_sample_station_now")
                        .font(.body)
                        .foregroundStyle(appearance.secondary)
                        .lineLimit(2)
                    HStack(spacing: 7) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("live_badge")
                            .font(.caption.weight(.bold))
                        Text(verbatim: "· 12:34")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .foregroundStyle(appearance.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .accessibilityHidden(true)

                HStack(spacing: 38) {
                    Image(systemName: skipStyle.symbol(forward: false))
                        .font(skipStyle.compactFont(pairedWith: radioPlayStyle))
                        .frame(width: 44, height: 44)
                    ZStack {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 68))
                            .opacity(0)
                        NowPlayingPlayPauseFace(
                            style: PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue),
                            showsPause: true,
                            diameter: 68,
                            tint: appearance.primary,
                            stops: true
                        )
                    }
                    Image(systemName: skipStyle.symbol(forward: true))
                        .font(skipStyle.compactFont(pairedWith: radioPlayStyle))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(appearance.primary)
                .padding(.top, 20)
                .accessibilityHidden(true)

                if showsVolume {
                    PreviewVolumeRow(primary: appearance.primary, iconTint: appearance.tertiary, fillTint: radioAccent)
                        .frame(maxWidth: 460)
                        .padding(.horizontal, 36)
                        .padding(.top, 14 + gap)
                }

                HStack(spacing: 0) {
                    ForEach(layout.visibleItems) { item in
                        bottomItem(item)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.top, 14 + (showsVolume ? 0 : gap))
                .padding(.bottom, max(canvas.bottomSafeArea, 16))
                .accessibilityHidden(true)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func bottomItem(_ item: NowPlayingRadioControlItem) -> some View {
        if item == .info {
            Text(verbatim: "MP3 · 128 kbps")
                .font(.caption2)
                .foregroundStyle(appearance.faint)
                .lineLimit(1)
                .fixedSize()
        } else {
            Image(systemName: Self.symbol(item))
                .font(.system(size: 17))
                .foregroundStyle(appearance.secondary)
                .frame(width: 36, height: 36)
        }
    }

    private static func symbol(_ item: NowPlayingRadioControlItem) -> String {
        switch item {
        case .share: "square.and.arrow.up"
        case .history: "clock.arrow.circlepath"
        case .sleepTimer: "moon.zzz"
        default: item.editorSymbol
        }
    }
}
#endif
