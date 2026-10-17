#if os(iOS)
import PrimuseKit
import SwiftUI
import UIKit

/// 预览按哪块屏幕排:这台设备竖着拿时播放页铺开的尺寸与上下安全区。
struct NowPlayingPreviewCanvas: Equatable {
    var size: CGSize
    var topSafeArea: CGFloat
    var bottomSafeArea: CGFloat
    /// 只有 iPhone 的竖屏播放页会把封面铺满(iPad 竖屏太宽,照旧是卡片)。
    var isPhone: Bool

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

/// 「播放页样式与按钮」里那张按真机比例画的音乐播放页(竖屏、封面那一面)。
///
/// 先按这台设备竖屏的实际尺寸与安全区排好,再整体缩小放进来,封面大小、几行控件之间的空白都和
/// 播放页同一套算法(`NowPlayingView.portraitArtworkSize` 等)。背景、封面、歌名是正在放的这首,
/// 背景直接用播放页那一层(`NowPlayingAmbientBackdrop`);没在放时是占位封面与示例歌名。
/// 一律按「正在播放」画:波浪在流动、光晕亮着、播放键显示暂停。
///
/// 能换按钮的六个位置怎么画见 `NowPlayingStylePreviewSlotMode`。
struct NowPlayingStylePreview: View {
    let canvas: NowPlayingPreviewCanvas
    let layout: NowPlayingControlLayout
    var selectedSlot: NowPlayingControlSlot?
    var slotMode: NowPlayingStylePreviewSlotMode = .editable
    var onSelect: (NowPlayingControlSlot) -> Void = { _ in }

    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(PlayerAppearancePreferences.alwaysDarkKey)
    private var alwaysDark = PlayerAppearancePreferences.alwaysDarkByDefault

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / max(canvas.size.width, 1),
                geometry.size.height / max(canvas.size.height, 1)
            )
            let corner: CGFloat = canvas.isPhone ? 48 : 20
            NowPlayingStylePreviewScreen(
                canvas: canvas,
                layout: layout,
                selectedSlot: selectedSlot,
                slotMode: slotMode,
                strokeScale: 1 / max(scale, 0.01),
                onSelect: onSelect
            )
            .frame(width: canvas.size.width, height: canvas.size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .environment(\.colorScheme, alwaysDark ? .dark : systemColorScheme)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(canvas.size, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }
}

/// 预览里的那块屏,按真机尺寸排。版面照 `NowPlayingView.portraitLayout` 的音乐、封面那一面。
private struct NowPlayingStylePreviewScreen: View {
    let canvas: NowPlayingPreviewCanvas
    let layout: NowPlayingControlLayout
    let selectedSlot: NowPlayingControlSlot?
    let slotMode: NowPlayingStylePreviewSlotMode
    /// 缩小之后虚线还要看得清:线宽、虚线段按缩放倒数放大。
    let strokeScale: CGFloat
    let onSelect: (NowPlayingControlSlot) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(ThemeService.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.showsArtworkLyricsKey)
    private var showsArtworkLyrics = PlayerAppearancePreferences.showsArtworkLyricsByDefault
    @AppStorage(PlayerAppearancePreferences.artworkStyleKey)
    private var artworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.progressStyleKey)
    private var progressStyleRawValue = NowPlayingProgressStyle.standard.rawValue
    @AppStorage(PlayerAppearancePreferences.progressGlowKey)
    private var progressGlows = PlayerAppearancePreferences.progressGlowByDefault
    @AppStorage(PlayerAppearancePreferences.controlTintKey)
    private var controlTintRawValue = NowPlayingControlTint.theme.rawValue
    @AppStorage(PlayerAppearancePreferences.playButtonStyleKey)
    private var playButtonStyleRawValue = NowPlayingPlayButtonStyle.filledCircle.rawValue
    @AppStorage(PlayerAppearancePreferences.skipButtonStyleKey)
    private var skipButtonStyleRawValue = NowPlayingSkipButtonStyle.standard.rawValue
    @AppStorage(AppThemePreferences.ambientStrengthKey)
    private var ambientStrength = AppThemePreferences.defaultAmbientStrength

    /// 示例进度:总长 3:38,播到三成多。
    private static let sampleDuration: TimeInterval = 218
    private static let sampleElapsed: TimeInterval = 83

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var song: Song? {
        player.isLiveRadio ? nil : player.currentSong
    }

    /// 和播放页 `themedControlAccent` 同一个取法(有声书那两套设计不在预览里)。
    private var controlAccent: Color {
        if PlayerAppearancePreferences.controlTint(rawValue: controlTintRawValue) == .monochrome
            || ThemeColorSettings.shared.isWhiteTheme {
            return appearance.primary
        }
        guard theme.colorID != "default" else { return appearance.primary }
        return appearance.isLight ? theme.darkAccent : theme.accentColor
    }

    private var usesFullBleedArtwork: Bool {
        canvas.isPhone
            && PlayerAppearancePreferences.artworkStyle(rawValue: artworkStyleRawValue) == .fullBleed
    }

    var body: some View {
        let size = canvas.size
        let artSize = NowPlayingView.portraitArtworkSize(in: size)
        let controlGap = NowPlayingView.portraitControlGap(forHeight: size.height)
        let volumeSlack: CGFloat = showsVolumeBar || showsArtworkLyrics
            ? 0
            : NowPlayingView.portraitVolumeRowHeight + 10 + controlGap
        let grabberBand = canvas.topSafeArea + 21

        ZStack {
            appearance.backgroundBase
            NowPlayingAmbientBackdrop(
                song: song,
                isPlaying: player.isPlaying,
                isSurfaceVisible: true,
                isSceneActive: true,
                allowsImageLoading: true
            )

            VStack(spacing: 0) {
                Capsule()
                    .fill(appearance.tertiary)
                    .frame(width: 48, height: 5)
                    .padding(.top, canvas.topSafeArea + 6)
                    .padding(.bottom, 10)

                if usesFullBleedArtwork {
                    GeometryReader { region in
                        fullBleedArtwork(width: size.width, height: region.size.height + grabberBand)
                            .frame(width: region.size.width, height: region.size.height, alignment: .bottom)
                    }
                    .frame(maxHeight: max(0, size.width - grabberBand))
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

                Spacer(minLength: 0)
                    .frame(maxHeight: 16)

                songHeader
                    .padding(.horizontal, 26)
                    .padding(.top, 12)

                Spacer(minLength: 0)

                if showsArtworkLyrics {
                    Text("player_preview_sample_lyric")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(appearance.primary)
                        .lineLimit(1)
                        .frame(height: 24, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 26)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                }

                progress
                    .padding(.horizontal, 26)
                    .padding(.top, 8)

                transportRow
                    .padding(.top, 12 + controlGap + volumeSlack * 0.3)

                if showsVolumeBar {
                    volumeRow
                        .padding(.horizontal, 26)
                        .padding(.top, 10 + controlGap)
                }

                HStack {
                    slot(.barLeading, placement: .bar)
                    Spacer()
                    slot(.barCenter, placement: .bar)
                    Spacer()
                    slot(.barTrailing, placement: .bar)
                }
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

    @ViewBuilder
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

    /// 铺满:整宽、从屏幕顶端画到这一块的下沿,直角,下沿四成渐隐;顶上垫一道淡底,把手画在封面上。
    private func fullBleedArtwork(width: CGFloat, height: CGFloat) -> some View {
        let side = max(width, height)
        let fade = FullBleedArtworkExtension.fadeFraction
        return ZStack(alignment: .top) {
            artwork(side: side, cornerRadius: 0)
                .frame(width: width, height: height)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 1 - fade),
                            .init(color: .black.opacity(0.844), location: 1 - fade * 0.75),
                            .init(color: .black.opacity(0.5), location: 1 - fade * 0.5),
                            .init(color: .black.opacity(0.156), location: 1 - fade * 0.25),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            LinearGradient(
                colors: [appearance.backgroundBase.opacity(0.42), appearance.backgroundBase.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: canvas.topSafeArea + 44)

            Capsule()
                .fill(appearance.primary.opacity(0.5))
                .frame(width: 48, height: 5)
                .padding(.top, canvas.topSafeArea + 6)
        }
        .frame(width: width, height: height)
    }

    // MARK: 歌名

    private var songHeader: some View {
        let title = song?.title ?? String(localized: "player_preview_sample_title")
        let metadata: String = {
            guard let song else { return String(localized: "player_preview_sample_artist") }
            return [library.artistDisplayName(for: song) ?? "", song.albumTitle ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    slot(.header, placement: .header)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(appearance.secondary)
                        .frame(width: 44, height: 44)
                }
                .fixedSize()
            }
            Text(verbatim: metadata)
                .font(.body)
                .foregroundStyle(appearance.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 进度、传输键、音量

    private var progress: some View {
        VStack(spacing: 4) {
            ProgressSlider(
                value: Self.sampleElapsed,
                total: Self.sampleDuration,
                fillTint: controlAccent,
                trackStyle: .forProgressStyle(
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
            .foregroundStyle(appearance.tertiary)
            .monospacedDigit()
        }
    }

    private var transportRow: some View {
        let skip = PlayerAppearancePreferences.skipButtonStyle(rawValue: skipButtonStyleRawValue)
        return HStack(spacing: 0) {
            Spacer()
            slot(.leadingEdge, placement: .edge)
            Spacer()
            Image(systemName: skip.symbol(forward: false))
                .font(skip.font)
                .foregroundStyle(appearance.primary)
                .frame(width: 56, height: 56)
            Spacer()
            ZStack {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .opacity(0)
                NowPlayingPlayPauseFace(
                    style: PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue),
                    showsPause: true,
                    diameter: 56,
                    tint: appearance.primary
                )
            }
            Spacer()
            Image(systemName: skip.symbol(forward: true))
                .font(skip.font)
                .foregroundStyle(appearance.primary)
                .frame(width: 56, height: 56)
            Spacer()
            slot(.trailingEdge, placement: .edge)
            Spacer()
        }
        .accessibilityHidden(true)
    }

    /// 系统音量条的样子:细轨道、前景色填充、12 点的圆钮。
    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(appearance.tertiary)
            GeometryReader { track in
                let filled = track.size.width * 0.62
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(appearance.primary.opacity(colorSchemeContrast == .increased ? 0.3 : 0.2))
                        .frame(height: 4)
                    Capsule()
                        .fill(appearance.primary)
                        .frame(width: filled, height: 4)
                    Circle()
                        .fill(appearance.primary)
                        .frame(width: 12, height: 12)
                        .offset(x: filled - 6)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: NowPlayingView.portraitVolumeRowHeight)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(appearance.tertiary)
        }
        .accessibilityHidden(true)
    }

    /// 最底下那行:开着的几项各画一个图标和一截占位。
    private var statusLine: some View {
        let items: [(item: NowPlayingStatusItem, symbol: String)] = [
            (item: .source, symbol: "externaldrive"),
            (item: .output, symbol: "headphones"),
            (item: .sleepTimer, symbol: "moon.zzz.fill"),
        ]
        let shown = items.filter { layout.showsStatusItem($0.item) }
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

    private enum SlotPlacement {
        /// 歌名旁:和隔空播放键一样只有图标,次要色。
        case header
        /// 播放键两端与最下面那一排:正文字号,淡色。
        case edge
        case bar
    }

    @ViewBuilder
    private func slot(_ slot: NowPlayingControlSlot, placement: SlotPlacement) -> some View {
        let action = layout.action(in: slot)
        let isSelected = selectedSlot == slot
        let face = slotFace(
            action,
            placement: placement,
            showsPlaceholder: slotMode == .editable || (slotMode == .selectionOnly && isSelected)
        )
        .frame(width: 44, height: 44)
        switch slotMode {
        case .editable:
            Button { onSelect(slot) } label: {
                face
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.28)) : AnyShapeStyle(.clear))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                .tint,
                                style: StrokeStyle(
                                    lineWidth: 1.4 * strokeScale,
                                    dash: [3.5 * strokeScale, 2.5 * strokeScale]
                                )
                            )
                    }
                    // 缩小以后一格只有二十来点宽,点的范围往外放一圈。
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(slot.editorTitleKey))
            .accessibilityValue(Text(action?.editorTitleKey ?? "player_controls_empty"))
            .accessibilityHint(Text("player_controls_slot_hint"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        case .selectionOnly:
            // 正在给这一格挑按钮时圈出来,看得出改的是哪儿。
            face
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.tint.opacity(0.28))
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 2 * strokeScale)
                    }
                }
                .accessibilityHidden(true)
        case .plain:
            face
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func slotFace(
        _ action: NowPlayingControlAction?,
        placement: SlotPlacement,
        showsPlaceholder: Bool
    ) -> some View {
        if let action {
            let tint = placement == .header ? appearance.secondary : appearance.tertiary
            if action == .airPlay {
                Image(systemName: "airplayaudio")
                    .font(.system(size: placement == .header ? 18 : 20))
                    .foregroundStyle(tint)
            } else if placement == .header {
                Image(systemName: action.editorSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
            } else {
                Image(systemName: action.editorSymbol)
                    .font(.body)
                    .foregroundStyle(tint)
            }
        } else if showsPlaceholder {
            // 空着的格只在编辑时画个加号,看效果时就是空的。
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(appearance.faint)
        } else {
            Color.clear
        }
    }
}
/// 预览里能换按钮的六个位置怎么画。
enum NowPlayingStylePreviewSlotMode: Equatable {
    /// 六格都描虚线、可以点(实际大小里打开编辑时)。
    case editable
    /// 只圈出正在挑按钮的那一格,不能点(浮在页面上的小预览)。
    case selectionOnly
    /// 什么都不描,就是播放页本来的样子。
    case plain
}

/// 铺满封面那一块在预览这块屏里的位置,给封面下面那截延伸定位。
private struct PreviewFullBleedRegionKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
#endif
