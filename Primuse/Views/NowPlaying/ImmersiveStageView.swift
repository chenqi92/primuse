import Foundation
import PrimuseKit
import SwiftUI

struct ImmersiveStageLyric: Identifiable, Equatable {
    let id: Int
    let text: String
    let isActive: Bool
    let offset: Int
    let fillProgress: Double?
    let syllables: [LyricSyllable]?
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let writingDirection: LyricWritingDirection?
    /// Backing vocals answering this line. They run on their own time window,
    /// so they are nested instead of taking a row of their own — a row of
    /// their own would compete with the lead line for the current position.
    let background: [ImmersiveStageBackgroundLyric]
    /// Authored rows that belong to this line but are not sung: a romanization
    /// first, then a translation. They are resolved by the platform container,
    /// which knows whether a translation is available at all.
    let companions: [String]

    init(
        id: Int,
        text: String,
        isActive: Bool,
        offset: Int,
        fillProgress: Double? = nil,
        syllables: [LyricSyllable]? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        writingDirection: LyricWritingDirection? = nil,
        background: [ImmersiveStageBackgroundLyric] = [],
        companions: [String] = []
    ) {
        self.id = id
        self.text = text
        self.isActive = isActive
        self.offset = offset
        self.fillProgress = fillProgress.map { min(max($0, 0), 1) }
        self.syllables = syllables?.isEmpty == false ? syllables : nil
        self.startTime = startTime
        self.endTime = endTime
        self.writingDirection = writingDirection
        self.background = background
        self.companions = companions.compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// One backing-vocal row. It never nests further, which keeps the row view
/// free of recursion.
struct ImmersiveStageBackgroundLyric: Identifiable, Equatable {
    let id: String
    let text: String
    let syllables: [LyricSyllable]?
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let writingDirection: LyricWritingDirection?

    init(
        id: String,
        text: String,
        syllables: [LyricSyllable]? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        writingDirection: LyricWritingDirection? = nil
    ) {
        self.id = id
        self.text = text
        self.syllables = syllables?.isEmpty == false ? syllables : nil
        self.startTime = startTime
        self.endTime = endTime
        self.writingDirection = writingDirection
    }
}

extension ImmersiveStageBackgroundLyric {
    /// Projects the backing groups of one lyric line onto the stage model.
    static func rows(
        for line: LyricLine,
        documentFallback: LyricWritingDirection
    ) -> [ImmersiveStageBackgroundLyric] {
        (line.background ?? []).compactMap { background in
            let text = background.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ImmersiveStageBackgroundLyric(
                id: background.id,
                text: text,
                syllables: background.syllables,
                startTime: background.isSynchronized ? background.timestamp : nil,
                endTime: background.endTime,
                writingDirection: LyricWritingDirectionPolicy.resolvePresentationDirection(
                    for: background,
                    documentFallback: documentFallback
                )
            )
        }
    }
}

/// iOS、macOS 与 tvOS 共用的八类动态播放舞台。封面、封面墙、封面流与实时频谱由平台容器注入。
struct ImmersiveStageView<Artwork: View>: View {
    var style: FullscreenPlayerEffect
    var platform: ImmersiveStagePlatform = .iOS
    var metrics: ImmersiveStageMetrics
    var track: ImmersiveStageTrack
    /// Read by small progress-only children so playback ticks do not invalidate
    /// the complete full-screen scene tree.
    var playbackTime: (@MainActor () -> TimeInterval)? = nil
    var palette: ImmersiveArtworkPalette = .fallback
    var lyricWindow: [ImmersiveStageLyric] = []
    var currentLyric: String?
    var nextLyric: String?
    var lyricsWritingDirection: LyricWritingDirection = .natural
    var levels: [CGFloat] = []
    /// 首选输入：只在消费频谱的叶子视图内求值，避免 25 Hz 采样让整棵沉浸树重算。
    var levelsProvider: (@MainActor () -> [CGFloat])?
    var galleryArtworkCount = 0
    var galleryArtwork: (Int, CGFloat) -> AnyView = { _, _ in AnyView(Color.clear) }
    /// 封面流(#191)两侧的封面：偏移量 -1…-`flowBeforeCount` 在左（刚放过的）、1…`flowAfterCount` 在右
    /// （接下来的）；0 是正在播的这首的静态封面，垫在中间那张底下、也给倒影用。由平台容器按播放队列给。
    var flowBeforeCount = 0
    var flowAfterCount = 0
    var flowArtwork: (Int, CGFloat) -> AnyView = { _, _ in AnyView(Color.clear) }
    /// 偏移量上那一张的身份（0 是中间这张）。换歌时每张沿用自己的身份，整排从旧位置滑到新位置；
    /// 没给时按偏移量，换歌就原地换图。
    var flowItemID: (Int) -> String? = { _ in nil }
    /// 整排挪了几格：手指拖动时跟着手走，向左拖为正。松手后由容器带动画归位或挪满一格再换歌。
    var flowShift: Double = 0
    var isRenderingActive = true
    var reduceMotion = false
    var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    /// 各动态层的重绘帧率；经环境传给舞台里的每一层。
    var frameRate: ImmersiveFrameRateMode = .defaultValue
    var lyricInterlude = false
    var lyricsPlaceholder = ""
    var visualizerDisclosure = ""
    var controlsInset: CGFloat = 0
    var showsClock = false
    /// 休憩时舞台把可读文字淡出，只留画面；时钟与歌词由容器的休憩层负责。
    var isResting = false
    /// 省电档（`ImmersiveIdlePowerPolicy`）：装饰动画、频谱、唱片转动都停下。
    var isLowPower = false
    /// 底部细进度条跟随容器的浮动控件一起出现、一起隐去。
    var showsPlaybackProgress = true
    var chromeBlurRadius: CGFloat = 52
    @ViewBuilder var artwork: (CGFloat) -> Artwork

    @Environment(\.layoutDirection) private var inheritedLayoutDirection

    private func writingDirection(for line: ImmersiveStageLyric) -> LyricWritingDirection {
        line.writingDirection ?? LyricWritingDirectionPolicy.resolvePresentationDirection(
            for: line.text,
            documentFallback: lyricsWritingDirection
        )
    }

    private func layoutDirection(for line: ImmersiveStageLyric) -> LayoutDirection {
        switch writingDirection(for: line) {
        case .natural: inheritedLayoutDirection
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    private var lyricDisplayPlatform: ImmersiveLyricDisplayPlatform {
        switch platform {
        case .iOS: .handheld
        case .macOS: .desktop
        case .tvOS: .television
        }
    }

    var body: some View {
        ZStack {
            scene
            persistentOverlay
            ImmersiveGrain(opacity: 0.032)
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .background(palette.secondary)
        .foregroundStyle(ImmersiveStagePalette.ink)
        .environment(\.immersiveFrameRate, frameRate)
        .overlay(alignment: .bottom) {
            ImmersiveHairlinePlaybackProgress(
                initialElapsed: track.elapsed,
                duration: track.duration,
                isPlaying: playbackClockIsActive && showsPlaybackProgress,
                playbackTime: playbackTime,
                height: max(1, metrics.f(platform == .tvOS ? 4 : 2)),
                accent: palette.primary
            )
            .opacity(showsPlaybackProgress ? 1 : 0)
        }
        .clipped()
    }

    /// 每个场景都经 `ImmersiveStageDeferredScene` 推迟构造，别直接内联回来（见那个类型的说明）。
    @ViewBuilder
    private var scene: some View {
        switch style.scene {
        case .coverGallery:
            ImmersiveStageDeferredScene { coverGalleryScene }
        case .flowingLines:
            ImmersiveStageDeferredScene { flowingLinesScene }
        case .radialPulse:
            ImmersiveStageDeferredScene { radialPulseScene }
        case .vinylDeck:
            ImmersiveStageDeferredScene { vinylDeckScene }
        case .auroraVeil:
            ImmersiveStageDeferredScene { auroraVeilScene }
        case .spectrumHorizon:
            ImmersiveStageDeferredScene { spectrumHorizonScene }
        case .particleBloom:
            ImmersiveStageDeferredScene { particleBloomScene }
        case .albumFlow:
            ImmersiveStageDeferredScene { albumFlowScene }
        case .chladniPlate:
            ImmersiveStageDeferredScene { chladniPlateScene }
        case .fireflySync:
            ImmersiveStageDeferredScene { fireflySyncScene }
        case .flyBrain:
            ImmersiveStageDeferredScene { flyBrainScene }
        }
    }

    /// 未提供闭包时退回静态数组，与旧的 levels 输入行为一致。
    private var spectrumProvider: @MainActor () -> [CGFloat] {
        if let levelsProvider { return levelsProvider }
        let snapshot = levels
        return { snapshot }
    }

    private var baseHorizontalInset: CGFloat {
        switch metrics.layout {
        case .phonePortrait:
            metrics.s(24)
        case .phoneLandscape:
            metrics.s(36)
        case .wide:
            metrics.s(platform == .tvOS ? 118 : 76)
        }
    }

    /// 前后缘分别取各自的安全区，避免把一侧的系统控件或摄像头区域套到另一侧。
    private var leadingInset: CGFloat {
        max(metrics.safeArea.leading, baseHorizontalInset)
    }

    private var trailingInset: CGFloat {
        max(metrics.safeArea.trailing, baseHorizontalInset)
    }

    private var topInset: CGFloat {
        metrics.stageContentTopInset(isTV: platform == .tvOS)
    }

    private var bottomInset: CGFloat {
        max(metrics.safeArea.bottom, metrics.s(14)) + controlsInset
    }

    private var playbackClockIsActive: Bool {
        isRenderingActive && track.isPlaying
    }

    /// 装饰性的动态（背景动画、频谱、唱片转动）。省电档里停下，歌词照常跟着播放走。
    private var decorativeClockIsActive: Bool {
        playbackClockIsActive && !isLowPower
    }

    private var sceneIsAnimating: Bool {
        !reduceMotion && decorativeClockIsActive
    }

    // MARK: - 1. 流动封面墙

    private var coverGalleryScene: some View {
        ZStack {
            ImmersiveGalleryBackdrop(
                count: galleryArtworkCount,
                palette: palette,
                isAnimating: sceneIsAnimating,
                artwork: galleryArtwork
            )
            LinearGradient(
                colors: [palette.secondary.opacity(0.40), palette.secondary.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [palette.primary.opacity(0.28), .clear],
                center: metrics.isPortrait ? UnitPoint(x: 0.5, y: 0.30) : UnitPoint(x: 0.24, y: 0.5),
                startRadius: 0,
                endRadius: max(metrics.size.width, metrics.size.height) * 0.5
            )
            ImmersiveVignette(color: .black, clearStop: 0.08, strength: 0.60)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(22)) {
                    portraitArtworkPlate(
                        side: min(metrics.size.width * 0.63, metrics.size.height * 0.31),
                        radius: metrics.f(12)
                    )
                    galleryTrackBlock
                    singleLyric(fontSize: metrics.s(16))
                    Spacer(minLength: 0)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset + metrics.s(22))
                .padding(.bottom, bottomInset)
            } else {
                HStack(spacing: metrics.s(platform == .tvOS ? 82 : 46)) {
                    artworkPlate(
                        side: min(metrics.size.height * 0.48, metrics.size.width * 0.30),
                        radius: metrics.f(14)
                    )
                    VStack(alignment: .leading, spacing: metrics.s(18)) {
                        galleryTrackBlock
                        singleLyric(
                            fontSize: metrics.s(platform == .tvOS ? 29 : 18),
                            availableWidth: metrics.size.width * 0.48
                        )
                    }
                    .frame(maxWidth: metrics.size.width * 0.48, alignment: .leading)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    // MARK: - 8. 封面流(#191)

    /// 正在播的这首居中、正对着人，播放队列里刚放过的斜着排在左边、接下来的排在右边，都立在一面映着
    /// 专辑色的玻璃台面上；背景铺专辑色，歌名在上面，歌词在倒影下面。几何与全屏页的拖动、点按判定共用
    /// `ImmersiveAlbumFlowGeometry`。
    private var albumFlowScene: some View {
        let layout = ImmersiveAlbumFlowGeometry.layout(
            metrics: metrics,
            platform: platform,
            controlsInset: controlsInset
        )
        let lyricFonts = ImmersiveAlbumFlowGeometry.lyricFonts(metrics: metrics, platform: platform)
        let centerSide = CGFloat(layout.centerSide)
        let baseline = CGFloat(layout.baseline)
        let radius = metrics.f(platform == .tvOS ? 10 : 6)
        let reflection = CGFloat(layout.reflectionFraction)
        // 每边比放得下的多画一张：拖动时最外那张从画布边外滑进来，边上不会突然空出一块。
        let before = min(flowBeforeCount, layout.neighborsPerSide + 1)
        let after = min(flowAfterCount, layout.neighborsPerSide + 1)
        let slots = albumFlowSlots(before: before, after: after)
        let textWidth = metrics.size.width - leadingInset - trailingInset

        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [palette.primary.opacity(0.92), palette.secondary],
                startPoint: .top,
                endPoint: .bottom
            )
            ImmersiveAlbumFlowAmbience(
                tint: palette.primary,
                glowCenter: UnitPoint(
                    x: 0.5,
                    y: Double(layout.centerMidY) / Double(max(metrics.size.height, 1))
                ),
                glowRadius: centerSide * 1.5,
                baseline: baseline,
                isAnimating: sceneIsAnimating
            )
            ImmersiveVignette(color: .black, clearStop: 0.18, strength: 0.42)

            // 每张按队列条目的身份画：换歌时整排滑过一格，上一首转到左边、下一首转正到中间，
            // 像 iPod 的封面流翻过去；离得远的跳转就淡入淡出。拖动时按 `flowShift` 跟着手走。
            ZStack(alignment: .topLeading) {
                ForEach(slots) { slot in
                    let position = Double(slot.offset) - flowShift
                    let placement = layout.placement(at: position)
                    let side = CGFloat(placement.side)
                    ImmersiveAlbumFlowCover(
                        side: side,
                        artworkSide: centerSide,
                        cornerRadius: radius,
                        tiltDegrees: placement.tiltDegrees,
                        reflectionFraction: reflection,
                        tint: palette.primary,
                        // 统一按中间那张的尺寸取图再整张缩放：滑到中间时还是同一张图，不重新取、不闪。
                        cover: flowArtwork(slot.offset, centerSide),
                        // 中间这张再叠上舞台通用的封面卡片：动态封面、玻璃描边、斜向高光与专辑色投影。
                        hero: slot.offset == 0 ? AnyView(artworkPlate(side: centerSide, radius: radius)) : nil
                    )
                    .opacity(placement.opacity)
                    .position(
                        x: CGFloat(placement.midX),
                        // 大小不一的封面立在同一条底线上。
                        y: baseline - side
                            + ImmersiveAlbumFlowCover.height(side: side, reflectionFraction: reflection) / 2
                    )
                    // 外侧的压在下面，越靠中间的越在上面。
                    .zIndex(-abs(position))
                    .transition(.opacity)
                }
            }
            .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
            .animation(reduceMotion ? nil : .smooth(duration: 0.55), value: slots.map(\.id))

            albumFlowTitle(width: textWidth)
                .frame(
                    width: textWidth,
                    height: CGFloat(layout.titleHeight),
                    alignment: .bottom
                )
                .position(
                    x: metrics.size.width / 2,
                    y: CGFloat(layout.titleOriginY) + CGFloat(layout.titleHeight) / 2
                )

            albumFlowLyrics(fonts: lyricFonts, width: textWidth)
                .frame(width: textWidth, height: CGFloat(layout.lyricHeight), alignment: .top)
                .position(
                    x: metrics.size.width / 2,
                    y: CGFloat(layout.lyricOriginY) + CGFloat(layout.lyricHeight) / 2
                )
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
        .environment(\.layoutDirection, .leftToRight)
    }

    private struct AlbumFlowSlot: Identifiable {
        let id: String
        let offset: Int
    }

    /// 中间加两侧要画的几张。身份重复（容器没给、或同一条目出现两次）时退回按偏移量区分。
    private func albumFlowSlots(before: Int, after: Int) -> [AlbumFlowSlot] {
        var seen = Set<String>()
        return (-before ... after).map { offset in
            let candidate = flowItemID(offset) ?? "offset:\(offset)"
            let id = seen.insert(candidate).inserted ? candidate : "\(candidate)#\(offset)"
            seen.insert(id)
            return AlbumFlowSlot(id: id, offset: offset)
        }
    }

    /// 封面流的歌词：当前这句（逐字歌词照样扫光），下面再带一句淡一些的下一句；当前这句带译文时
    /// 让译文占那一行。手机横屏只放当前这句。没歌词时是「暂无歌词」。
    private func albumFlowLyrics(fonts: ImmersiveAlbumFlowGeometry.LyricFonts, width: CGFloat) -> some View {
        let current = resolvedCurrentStageLyric
        let next = fonts.showsNextLine && current?.companions.isEmpty != false
            ? resolvedFocusLyrics.first { !$0.isActive && $0.offset > 0 }
            : nil
        return VStack(spacing: fonts.spacing) {
            if let current {
                lyricLine(
                    current,
                    fontSize: fonts.current,
                    lineLimit: fonts.currentLineLimit,
                    textAlignment: .center
                )
                .frame(maxWidth: .infinity)
            }
            if let next {
                lyricLine(next, fontSize: fonts.next, lineLimit: 1, textAlignment: .center)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width)
        .animation(
            .easeOut(duration: lyricsMotionEnabled && !reduceMotion ? 0.28 : 0.01),
            value: resolvedCurrentLyric
        )
        .immersiveRestingText(isResting)
    }

    private func albumFlowTitle(width: CGFloat) -> some View {
        let titleSize = ImmersiveAlbumFlowGeometry.titleSize(metrics: metrics, platform: platform)
        return VStack(spacing: metrics.s(4)) {
            Text(track.title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(track.subtitle)
                .font(.system(size: ImmersiveAlbumFlowGeometry.subtitleSize(metrics: metrics, platform: platform)))
                .foregroundStyle(ImmersiveStagePalette.text.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: width)
        .environment(\.layoutDirection, inheritedLayoutDirection)
        .immersiveRestingText(isResting)
    }

    // MARK: - 9. 克拉尼沙画

    /// 竖屏：板在上、文字在下。其余视口：板贴前缘、在内容区里竖直居中，从板的右边再留出间距只放歌词
    /// （`lyricsOnlyColumn`）；控件在歌词这一侧。
    private var chladniPlateScene: some View {
        let isPhoneLandscape = metrics.layout == .phoneLandscape
        let innerWidth = metrics.size.width - leadingInset - trailingInset
        let contentBottom = metrics.size.height - max(metrics.safeArea.bottom, metrics.s(14))
        let plateSide = metrics.isPortrait
            ? min(innerWidth, metrics.size.height * 0.44)
            : min(
                contentBottom - topInset - metrics.s(isPhoneLandscape ? 6 : 28),
                innerWidth * (isPhoneLandscape ? 0.46 : 0.44)
            )
        let plateCenterY = topInset + (contentBottom - topInset) / 2
        let textLeading = leadingInset + plateSide
            + metrics.s(isPhoneLandscape ? 40 : (platform == .tvOS ? 110 : 76))
        let textWidth = max(metrics.s(160), metrics.size.width - trailingInset - textLeading)
        let plateCenter = metrics.isPortrait
            ? UnitPoint(x: 0.5, y: (topInset + metrics.s(14) + plateSide / 2) / max(metrics.size.height, 1))
            : UnitPoint(
                x: (leadingInset + plateSide / 2) / max(metrics.size.width, 1),
                y: plateCenterY / max(metrics.size.height, 1)
            )

        return ZStack {
            LinearGradient(
                colors: [palette.secondary.opacity(0.88), ImmersiveStagePalette.obsidian],
                startPoint: .top,
                endPoint: .bottom
            )
            ImmersiveEnergyGlow(
                levelsProvider: spectrumProvider,
                palette: palette,
                center: plateCenter,
                radius: plateSide * 0.95,
                baseOpacity: 0.12,
                reactiveOpacity: 0.22
            )
            ImmersiveVignette(color: ImmersiveStagePalette.obsidian, clearStop: 0.30, strength: 0.46)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(24)) {
                    chladniPlate(side: plateSide)
                        .frame(maxWidth: .infinity, alignment: .center)
                    titleBlock(size: metrics.s(40), weight: .semibold)
                    formatAndLyric(fontSize: metrics.s(12), availableWidth: innerWidth)
                    Spacer(minLength: 0)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset + metrics.s(14))
                .padding(.bottom, bottomInset)
            } else {
                chladniPlate(side: plateSide)
                    .position(x: leadingInset + plateSide / 2, y: plateCenterY)

                lyricsOnlyColumn(
                    fontSize: metrics.s(isPhoneLandscape ? 25 : (platform == .tvOS ? 58 : 48)),
                    width: textWidth,
                    alignment: .leading
                )
                .position(x: textLeading + textWidth / 2, y: lyricsOnlyCenterY)
            }
        }
    }

    private func chladniPlate(side: CGFloat) -> some View {
        ImmersiveChladniPlate(
            levelsProvider: spectrumProvider,
            palette: palette,
            isAnimating: sceneIsAnimating,
            songKey: "\(track.title)\u{1F}\(track.artist)\u{1F}\(track.album)",
            side: side,
            labelSize: metrics.s(platform == .tvOS ? 17 : 10)
        )
    }

    // MARK: - 10. 萤火同步

    /// 萤火与草地铺满整幅。竖屏文字靠上：专辑小卡、歌名、当前这句歌词，萤火虫偏下。
    /// 其余视口萤火压到下面六成，上面那截夜空居中只放歌词（`lyricsOnlyColumn`）。
    private var fireflySyncScene: some View {
        let isPhoneLandscape = metrics.layout == .phoneLandscape
        let textWidth = metrics.size.width - leadingInset - trailingInset
        let fieldTop: CGFloat = metrics.isPortrait ? 0.30 : 0.44

        return ZStack {
            ImmersiveFireflyMeadow(
                levelsProvider: spectrumProvider,
                palette: palette,
                isAnimating: sceneIsAnimating,
                count: metrics.layout == .wide ? 360 : 220,
                fieldTop: fieldTop
            )
            ImmersiveVignette(color: ImmersiveStagePalette.obsidian, clearStop: 0.42, strength: 0.38)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(14)) {
                    compactHeader(artSide: metrics.s(60))
                    titleBlock(size: metrics.s(38), weight: .semibold, maxWidth: textWidth)
                    singleLyric(fontSize: metrics.s(18), availableWidth: textWidth)
                        .frame(maxWidth: textWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset + metrics.s(8))
                .padding(.bottom, bottomInset)
            } else {
                let skyBottom = metrics.size.height * fieldTop
                lyricsOnlyColumn(
                    fontSize: metrics.s(isPhoneLandscape ? 24 : (platform == .tvOS ? 58 : 48)),
                    width: metrics.size.width * (isPhoneLandscape ? 0.70 : 0.62),
                    alignment: .center
                )
                .position(
                    x: metrics.size.width / 2,
                    y: topInset + max(skyBottom - topInset, 0) / 2 + metrics.s(6)
                )
            }
        }
    }

    // MARK: - 11. 神经共鸣

    /// 竖屏：文字在上、大脑居中、歌词在下。其余视口：前缘一列只放歌词（`lyricsOnlyColumn`），
    /// 和大脑的中心齐平，大脑占后面那一大块；角落一行小字写数据来源（CC BY 4.0 要求署名）。
    private var flyBrainScene: some View {
        let isPhoneLandscape = metrics.layout == .phoneLandscape
        let innerWidth = metrics.size.width - leadingInset - trailingInset
        let availableTop = topInset
        let availableHeight = max(metrics.size.height - bottomInset - availableTop, 1)
        let textWidth = metrics.isPortrait ? innerWidth : innerWidth * (isPhoneLandscape ? 0.38 : 0.34)
        let brainLeading = metrics.isPortrait
            ? leadingInset
            : leadingInset + textWidth + metrics.s(isPhoneLandscape ? 12 : 32)
        let brainWidth = metrics.isPortrait ? innerWidth : metrics.size.width - trailingInset - brainLeading
        let halfWidth = metrics.isPortrait
            ? min(innerWidth * 0.48, metrics.size.height * 0.23)
            : min(brainWidth * 0.45, availableHeight * 0.64)
        let brainCenterX = brainLeading + brainWidth / 2
        let brainCenterY = metrics.isPortrait
            ? metrics.size.height * 0.50
            : availableTop + availableHeight * 0.47
        let center = UnitPoint(
            x: brainCenterX / max(metrics.size.width, 1),
            y: brainCenterY / max(metrics.size.height, 1)
        )

        return ZStack {
            LinearGradient(
                colors: [Color(red: 0.020, green: 0.040, blue: 0.090), Color(red: 0.008, green: 0.016, blue: 0.040)],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [palette.primary.opacity(0.14), .clear],
                center: center,
                startRadius: 0,
                endRadius: halfWidth * 1.5
            )
            // 全息投影的冷光：中心一团很淡的蓝。
            RadialGradient(
                colors: [Color(red: 0.30, green: 0.62, blue: 1.0).opacity(0.12), .clear],
                center: center,
                startRadius: 0,
                endRadius: halfWidth * 0.9
            )
            ImmersiveFlyBrain(
                levelsProvider: spectrumProvider,
                palette: palette,
                isAnimating: sceneIsAnimating,
                center: center,
                halfWidth: halfWidth,
                labelSize: metrics.s(platform == .tvOS ? 15 : 9)
            )
            ImmersiveVignette(color: .black, clearStop: 0.40, strength: 0.40)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(12)) {
                    compactHeader(artSide: metrics.s(56))
                    titleBlock(size: metrics.s(34), weight: .semibold)
                    Spacer(minLength: 0)
                    singleLyric(fontSize: metrics.s(17), availableWidth: innerWidth)
                    flyBrainCredit
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset + metrics.s(8))
                .padding(.bottom, bottomInset)
            } else {
                lyricsOnlyColumn(
                    fontSize: metrics.s(isPhoneLandscape ? 22 : (platform == .tvOS ? 50 : 40)),
                    width: textWidth,
                    alignment: .leading
                )
                .position(x: leadingInset + textWidth / 2, y: brainCenterY)

                flyBrainCredit
                    .frame(width: textWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, leadingInset)
                    .padding(.bottom, bottomInset)
            }
        }
    }

    /// 数据来源：Male CNS 连接组（CC BY 4.0）。专有名词，不翻译。
    private var flyBrainCredit: some View {
        Text(verbatim: "Male CNS v1.0 · Janelia FlyEM / Google · CC BY 4.0")
            .font(.system(size: metrics.s(platform == .tvOS ? 13 : 8), weight: .regular, design: .monospaced))
            .foregroundStyle(ImmersiveStagePalette.text.opacity(0.36))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .immersiveRestingText(isResting)
    }

    // MARK: - 只放歌词（沙画、萤火、神经共鸣的非竖屏）

    /// 只放歌词那一列的竖直中心：内容区上沿到控件让出的那一段之间的正中。
    private var lyricsOnlyCenterY: CGFloat {
        topInset + max(metrics.size.height - bottomInset - topInset, 0) / 2
    }

    /// 这首歌有能显示的歌词（间奏里暂时没有当前句也算）；只有「暂无歌词」「正在加载」这类占位时为 false。
    private var hasStageLyrics: Bool {
        if lyricInterlude { return true }
        if lyricWindow.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }
        return currentLyric?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// 这三个效果在非竖屏里不放封面、歌名与歌手，画面之外只有歌词：前后句压暗、当前句放大。
    /// 没有歌词时这里改放歌名与歌手；点出控件时歌词上方淡入一行「歌名 · 歌手」，控件藏起来就跟着藏，
    /// 歌词本身不挪位置。
    @ViewBuilder
    private func lyricsOnlyColumn(fontSize: CGFloat, width: CGFloat, alignment: TextAlignment) -> some View {
        let horizontal: HorizontalAlignment = alignment == .center ? .center : .leading
        let frameAlignment = Alignment(horizontal: horizontal, vertical: .center)
        if hasStageLyrics {
            focusedLyrics(alignment: alignment, proposedCurrentFontSize: fontSize, availableWidth: width)
                .frame(width: width, alignment: frameAlignment)
                .overlay(alignment: Alignment(horizontal: horizontal, vertical: .top)) {
                    lyricsOnlyEyebrow(alignment: alignment)
                        .frame(width: width, alignment: frameAlignment)
                        .alignmentGuide(.top) { $0[.bottom] + metrics.s(platform == .tvOS ? 26 : 16) }
                        .opacity(showsPlaybackProgress ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: showsPlaybackProgress)
                }
        } else {
            titleBlock(size: fontSize * 1.5, weight: .semibold, maxWidth: width, alignment: horizontal)
                .frame(width: width, alignment: frameAlignment)
        }
    }

    private func lyricsOnlyEyebrow(alignment: TextAlignment) -> some View {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return Text(verbatim: artist.isEmpty ? track.title : "\(track.title) · \(artist)")
            .font(.system(size: metrics.s(platform == .tvOS ? 22 : (metrics.isWide ? 17 : 13)), weight: .semibold))
            .foregroundStyle(ImmersiveStagePalette.text.opacity(0.62))
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .immersiveRestingText(isResting)
    }

    private var galleryTrackBlock: some View {
        VStack(alignment: .leading, spacing: metrics.s(platform == .tvOS ? 18 : 9)) {
            Text(verbatim: "\(PMString("ext.tv.nowPlaying.eyebrow")) · \(track.source.isEmpty ? track.album : track.source)")
                .font(.system(size: metrics.s(platform == .tvOS ? 18 : 10), weight: .semibold, design: .monospaced))
                .tracking(metrics.f(1.8))
                .foregroundStyle(palette.primary.opacity(0.86))
                .lineLimit(1)
            titleBlock(
                size: metrics.s(platform == .tvOS ? 90 : (metrics.isPortrait ? 44 : 52)),
                weight: .light
            )
        }
        .immersiveRestingText(isResting)
    }

    // MARK: - 2. 流动声纹

    private var flowingLinesScene: some View {
        let diameter = metrics.isPortrait
            ? min(metrics.size.width * 0.54, metrics.size.height * 0.28)
            : min(metrics.size.height * 0.54, metrics.size.width * 0.34)
        let fieldCenter = metrics.isPortrait
            ? UnitPoint(x: 0.5, y: 0.42)
            : UnitPoint(x: 0.53, y: 0.44)

        return ZStack {
            LinearGradient(
                colors: [palette.secondary, ImmersiveStagePalette.obsidian.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ImmersiveOrganicContourField(
                palette: palette,
                isAnimating: sceneIsAnimating,
                center: fieldCenter
            )
            ImmersiveVignette(color: .black, clearStop: 0.30, strength: 0.54)

            orbitingArtwork(diameter: diameter)
                .position(
                    x: metrics.size.width * fieldCenter.x,
                    y: metrics.size.height * fieldCenter.y
                )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Spacer(minLength: 0)
                    threeLineLyrics(
                        alignment: .trailing,
                        fontSize: metrics.s(metrics.isPortrait ? 13 : (platform == .tvOS ? 27 : 17)),
                        availableWidth: metrics.size.width * (metrics.isPortrait ? 0.66 : 0.34)
                    )
                    .frame(
                        maxWidth: metrics.size.width * (metrics.isPortrait ? 0.66 : 0.34),
                        alignment: .trailing
                    )
                }
                Spacer()
                titleBlock(
                    size: metrics.s(metrics.isPortrait ? 44 : (platform == .tvOS ? 94 : 58)),
                    weight: .semibold,
                    maxWidth: metrics.isPortrait ? nil : metrics.size.width * 0.46
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset + metrics.s(metrics.isPortrait ? 12 : 0))
        }
    }

    private func orbitingArtwork(diameter: CGFloat) -> some View {
        ZStack {
            ImmersiveOrbitRing(
                palette: palette,
                isAnimating: sceneIsAnimating,
                diameter: diameter * 1.16
            )
            rotatingCircularArtwork(diameter: diameter)
        }
        .frame(width: diameter * 1.16, height: diameter * 1.16)
    }

    private func formatAndLyric(fontSize: CGFloat, availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: metrics.s(12)) {
            Text(track.format.uppercased())
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .tracking(fontSize * 0.14)
                .foregroundStyle(ImmersiveStagePalette.text.opacity(0.78))
                .lineLimit(1)
            singleLyric(fontSize: fontSize * 1.08, availableWidth: availableWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .immersiveRestingText(isResting)
    }

    // MARK: - 3. 环形声谱

    /// 环形声谱的可见外沿是 `radialArtwork` 里涟漪层的 1.4 倍直径，三层都按这个尺寸摆。
    private var radialRingSpanRatio: CGFloat { 1.4 }

    /// 竖屏：环在上、文字在下。其余视口：环贴前缘、整高居中，文字列从环的可见外沿
    /// 再留出间距、占满到后缘；控件在文字这一侧（`ImmersivePlayerView.showcaseControlAlignment`）。
    private var radialPulseScene: some View {
        let isPhoneLandscape = metrics.layout == .phoneLandscape
        let innerWidth = metrics.size.width - leadingInset - trailingInset
        let landscapeRingSpan = min(
            metrics.size.height - topInset - max(metrics.safeArea.bottom, metrics.s(14))
                - metrics.s(isPhoneLandscape ? 4 : 24),
            innerWidth * (isPhoneLandscape ? 0.44 : 0.42)
        )
        let diameter = metrics.isPortrait
            ? min(metrics.size.height * 0.46, metrics.size.width * 0.88)
            : landscapeRingSpan / radialRingSpanRatio
        let ringSpan = diameter * radialRingSpanRatio
        let textLeading = leadingInset + ringSpan
            + metrics.s(isPhoneLandscape ? 32 : (platform == .tvOS ? 96 : 64))
        let textWidth = max(metrics.s(160), metrics.size.width - trailingInset - textLeading)
        return ZStack {
            palette.secondary
            ImmersiveEnergyGlow(
                levelsProvider: spectrumProvider,
                palette: palette,
                center: metrics.isPortrait ? .top : .leading,
                radius: diameter * 1.2,
                baseOpacity: 0.26,
                reactiveOpacity: 0.34
            )
            ImmersiveVignette(color: ImmersiveStagePalette.obsidian, clearStop: 0.34, strength: 0.46)

            if metrics.isPortrait {
                VStack(spacing: metrics.s(28)) {
                    radialArtwork(diameter: diameter)
                    titleBlock(size: metrics.s(43), weight: .semibold)
                    formatAndLyric(
                        fontSize: metrics.s(12),
                        availableWidth: metrics.size.width - leadingInset - trailingInset
                    )
                    Spacer(minLength: 0)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset + metrics.s(14))
                .padding(.bottom, bottomInset)
            } else {
                radialArtwork(diameter: diameter)
                    .position(x: leadingInset + ringSpan / 2, y: metrics.size.height / 2)

                VStack(alignment: .leading, spacing: metrics.s(18)) {
                    titleBlock(
                        size: metrics.s(isPhoneLandscape ? 46 : (platform == .tvOS ? 94 : 60)),
                        weight: .semibold
                    )
                    formatAndLyric(
                        fontSize: metrics.s(platform == .tvOS ? 23 : 14),
                        availableWidth: textWidth
                    )
                }
                .frame(width: textWidth, alignment: .leading)
                .position(x: textLeading + textWidth / 2, y: metrics.size.height / 2)
            }
        }
    }

    /// 三层都显式按可见外沿定尺寸，不靠 ZStack 把画布撑到涟漪层的大小。
    private func radialArtwork(diameter: CGFloat) -> some View {
        let barWidth = max(1.4, metrics.f(platform == .tvOS ? 5 : 3))
        let span = diameter * radialRingSpanRatio
        return ZStack {
            ImmersiveBassRipples(
                levelsProvider: spectrumProvider,
                palette: palette,
                isAnimating: sceneIsAnimating,
                startRatio: 0.60 / radialRingSpanRatio
            )
            .frame(width: span, height: span)

            ImmersiveSpectrumRingHost(
                levelsProvider: spectrumProvider,
                barWidth: barWidth,
                isAnimating: sceneIsAnimating,
                tint: palette.primary,
                isPlaying: decorativeClockIsActive
            )
            .frame(width: span, height: span)
            .blur(radius: max(4, metrics.f(12)))
            .opacity(0.9)

            ImmersiveSpectrumRingHost(
                levelsProvider: spectrumProvider,
                barWidth: barWidth,
                isAnimating: sceneIsAnimating,
                tint: palette.primary,
                isPlaying: decorativeClockIsActive
            )
            .frame(width: span, height: span)

            rotatingCircularArtwork(diameter: diameter * 0.60)
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - 4. 黑胶唱机

    private var vinylDeckScene: some View {
        let diameter = min(
            metrics.size.height * (metrics.isPortrait ? 0.44 : 0.78),
            metrics.size.width * (metrics.isPortrait ? 0.74 : 0.44)
        )
        return ZStack {
            LinearGradient(
                colors: [palette.secondary.opacity(0.96), ImmersiveStagePalette.obsidian],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [palette.primary.opacity(0.34), .clear],
                center: metrics.isPortrait ? UnitPoint(x: 0.5, y: 0.22) : UnitPoint(x: 0.26, y: 0.42),
                startRadius: 0,
                endRadius: diameter * 1.1
            )
            ImmersiveVignette(color: .black, clearStop: 0.20, strength: 0.70)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(24)) {
                    turntable(diameter: diameter)
                        .frame(maxWidth: .infinity, alignment: .center)
                    titleBlock(size: metrics.s(40), weight: .semibold)
                    formatAndLyric(
                        fontSize: metrics.s(13),
                        availableWidth: metrics.size.width - leadingInset - trailingInset
                    )
                    Spacer(minLength: 0)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset + metrics.s(8))
                .padding(.bottom, bottomInset)
            } else {
                HStack(spacing: metrics.s(platform == .tvOS ? 90 : 52)) {
                    turntable(diameter: diameter)
                    VStack(alignment: .leading, spacing: metrics.s(20)) {
                        titleBlock(size: metrics.s(platform == .tvOS ? 92 : 58), weight: .semibold)
                        formatAndLyric(
                            fontSize: metrics.s(platform == .tvOS ? 23 : 14),
                            availableWidth: metrics.size.width * 0.40
                        )
                    }
                    .frame(maxWidth: metrics.size.width * 0.40, alignment: .leading)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    private func turntable(diameter: CGFloat) -> some View {
        let canvas = ImmersiveVinylTonearm.canvasSize(recordDiameter: diameter)
        return ZStack(alignment: .topLeading) {
            ImmersiveVinylRecord(
                palette: palette,
                isSpinning: decorativeClockIsActive,
                reduceMotion: reduceMotion,
                diameter: diameter
            ) { side in
                artwork(side)
            }
            ImmersiveVinylTonearm(
                recordDiameter: diameter,
                isPlaying: track.isPlaying,
                tint: palette.primary
            )
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    // MARK: - 5. 星夜极光

    /// 文字都落在下方深色地面上，大标题不压在最亮的极光带里；星空与流星在上半幅。
    private var auroraVeilScene: some View {
        ZStack {
            ImmersiveAuroraCurtains(palette: palette, isAnimating: sceneIsAnimating)
            ImmersiveVignette(color: ImmersiveStagePalette.obsidian, clearStop: 0.34, strength: 0.46)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(16)) {
                    compactHeader(artSide: metrics.s(64))
                    Spacer()
                    titleBlock(size: metrics.s(40), weight: .semibold)
                    singleLyric(fontSize: metrics.s(20))
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset + metrics.s(16))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    compactHeader(artSide: metrics.s(platform == .tvOS ? 100 : 66))
                    Spacer()
                    HStack(alignment: .bottom, spacing: metrics.s(48)) {
                        titleBlock(
                            size: metrics.s(platform == .tvOS ? 90 : 58),
                            weight: .semibold,
                            maxWidth: metrics.size.width * 0.40
                        )
                        Spacer(minLength: 0)
                        singleLyric(
                            fontSize: metrics.s(platform == .tvOS ? 30 : 20),
                            availableWidth: metrics.size.width * 0.36
                        )
                        .frame(maxWidth: metrics.size.width * 0.36, alignment: .leading)
                    }
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    // MARK: - 6. 声场地平线

    /// 舞台式构图：封面居中立在发光地平线上，频谱天际线在它身后升起，
    /// 标题与歌词居中排在封面上方。
    private var spectrumHorizonScene: some View {
        let isPhoneLandscape = metrics.layout == .phoneLandscape
        let horizonY = metrics.size.height - bottomInset + metrics.s(6)
        let side = metrics.isPortrait
            ? min(metrics.size.width * 0.58, metrics.size.height * 0.28)
            : (isPhoneLandscape
                ? min(metrics.size.height * 0.34, metrics.size.width * 0.22)
                : min(metrics.size.height * 0.40, metrics.size.width * 0.26))
        let barHeight = metrics.size.height * (metrics.isPortrait ? 0.20 : 0.24)
        let textRegionTop = topInset
        let textRegionHeight = max(1, horizonY - side - metrics.s(16) - textRegionTop)
        let textWidth = metrics.isPortrait ? nil : metrics.size.width * 0.64

        return ZStack {
            LinearGradient(
                colors: [palette.secondary.opacity(0.92), ImmersiveStagePalette.obsidian],
                startPoint: .top,
                endPoint: .bottom
            )
            ImmersiveEnergyGlow(
                levelsProvider: spectrumProvider,
                palette: palette,
                center: UnitPoint(x: 0.5, y: horizonY / max(metrics.size.height, 1)),
                radius: max(metrics.size.width, metrics.size.height) * 0.55,
                baseOpacity: 0.14,
                reactiveOpacity: 0.30
            )
            ImmersiveSpectrumSkyline(
                levelsProvider: spectrumProvider,
                palette: palette,
                horizonY: horizonY,
                maxBarHeight: barHeight
            )
            ImmersiveVignette(color: ImmersiveStagePalette.obsidian, clearStop: 0.30, strength: 0.42)

            artworkPlate(side: side, radius: metrics.f(metrics.isPortrait ? 16 : 20))
                .position(x: metrics.size.width / 2, y: horizonY - side / 2)

            VStack(spacing: metrics.s(14)) {
                titleBlock(
                    size: metrics.s(metrics.isPortrait ? 40 : (isPhoneLandscape ? 34 : (platform == .tvOS ? 84 : 56))),
                    weight: .semibold,
                    maxWidth: textWidth,
                    alignment: .center
                )
                singleLyric(
                    fontSize: metrics.s(metrics.isPortrait ? 16 : (isPhoneLandscape ? 16 : (platform == .tvOS ? 30 : 19))),
                    availableWidth: textWidth,
                    alignment: .center
                )
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(width: metrics.size.width, height: textRegionHeight, alignment: .center)
            .position(x: metrics.size.width / 2, y: textRegionTop + textRegionHeight / 2)
        }
    }

    // MARK: - 7. 星尘律动

    /// 横屏时文字在左、发射粒子的圆形封面在右；竖屏封面居中在上，文字在下。
    private var particleBloomScene: some View {
        let diameter = metrics.isPortrait
            ? min(metrics.size.width * 0.56, metrics.size.height * 0.28)
            : min(metrics.size.height * 0.52, metrics.size.width * 0.30)
        let availableTop = topInset
        let availableBottom = metrics.size.height - bottomInset
        let emitter = metrics.isPortrait
            ? UnitPoint(
                x: 0.5,
                y: (availableTop + metrics.s(20) + diameter / 2) / max(metrics.size.height, 1)
            )
            : UnitPoint(
                x: (metrics.size.width - trailingInset - diameter / 2) / max(metrics.size.width, 1),
                y: (availableTop + (availableBottom - availableTop) / 2) / max(metrics.size.height, 1)
            )

        return ZStack {
            LinearGradient(
                colors: [palette.secondary.opacity(0.94), ImmersiveStagePalette.obsidian],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ImmersiveParticleField(
                levelsProvider: spectrumProvider,
                palette: palette,
                isAnimating: sceneIsAnimating,
                emitter: emitter
            )
            ImmersiveVignette(color: ImmersiveStagePalette.obsidian, clearStop: 0.26, strength: 0.52)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(26)) {
                    pulsingArtwork(diameter: diameter)
                        .frame(maxWidth: .infinity, alignment: .center)
                    titleBlock(size: metrics.s(42), weight: .semibold)
                    formatAndLyric(
                        fontSize: metrics.s(13),
                        availableWidth: metrics.size.width - leadingInset - trailingInset
                    )
                    Spacer(minLength: 0)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset + metrics.s(20))
                .padding(.bottom, bottomInset)
            } else {
                HStack(spacing: metrics.s(platform == .tvOS ? 88 : 54)) {
                    VStack(alignment: .leading, spacing: metrics.s(18)) {
                        titleBlock(size: metrics.s(platform == .tvOS ? 92 : 58), weight: .semibold)
                        formatAndLyric(
                            fontSize: metrics.s(platform == .tvOS ? 23 : 14),
                            availableWidth: metrics.size.width * 0.40
                        )
                    }
                    .frame(maxWidth: metrics.size.width * 0.40, alignment: .leading)
                    Spacer(minLength: 0)
                    pulsingArtwork(diameter: diameter)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    private func pulsingArtwork(diameter: CGFloat) -> some View {
        ImmersivePulsingArtwork(
            levelsProvider: spectrumProvider,
            palette: palette,
            diameter: diameter,
            artwork: artwork
        )
    }

    // MARK: - Shared content

    private func compactHeader(artSide: CGFloat) -> some View {
        HStack(spacing: metrics.s(platform == .tvOS ? 22 : 13)) {
            artworkPlate(side: artSide, radius: metrics.f(8))
            VStack(alignment: .leading, spacing: metrics.s(5)) {
                Text(track.artist)
                    .font(.system(size: metrics.s(platform == .tvOS ? 25 : 14), weight: .semibold))
                    .lineLimit(1)
                Text(track.album.uppercased())
                    .font(.system(size: metrics.s(platform == .tvOS ? 16 : 9), weight: .medium, design: .monospaced))
                    .tracking(metrics.f(1.7))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.52))
                    .lineLimit(1)
            }
        }
        .immersiveRestingText(isResting)
    }

    private func titleBlock(
        size: CGFloat,
        weight: Font.Weight,
        maxWidth: CGFloat? = nil,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        let textAlignment: TextAlignment = alignment == .center
            ? .center
            : (alignment == .trailing ? .trailing : .leading)
        return VStack(alignment: alignment, spacing: metrics.s(8)) {
            Text(track.title)
                .font(.system(size: size, weight: weight))
                .tracking(-size * 0.028)
                .multilineTextAlignment(textAlignment)
                .lineLimit(2)
                .minimumScaleFactor(0.44)
            Text(track.subtitle)
                .font(.system(size: max(size * 0.27, metrics.s(12)), weight: .regular))
                .foregroundStyle(ImmersiveStagePalette.text.opacity(0.62))
                .multilineTextAlignment(textAlignment)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(
            maxWidth: maxWidth ?? .infinity,
            alignment: Alignment(horizontal: alignment, vertical: .center)
        )
        .immersiveRestingText(isResting)
    }

    private func artworkPlate(side: CGFloat, radius: CGFloat) -> some View {
        ImmersiveArtworkPlate(
            side: side,
            cornerRadius: radius,
            glowColor: palette.primary,
            artwork: artwork
        )
    }

    private func portraitArtworkPlate(side: CGFloat, radius: CGFloat) -> some View {
        artworkPlate(side: side, radius: radius)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 旋转角取自同一时钟：暂停时停在当前角度，恢复时从原处继续，不会跳回起点。
    private func rotatingCircularArtwork(diameter: CGFloat) -> some View {
        TimelineView(.animation(
            minimumInterval: frameRate.minimumInterval(base: 1 / 24),
            paused: !sceneIsAnimating
        )) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? 0 : seconds.truncatingRemainder(dividingBy: 22) / 22 * 360
            artwork(diameter)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                .shadow(color: palette.primary.opacity(0.38), radius: diameter * 0.12)
                .rotationEffect(.degrees(angle))
        }
        .frame(width: diameter, height: diameter)
    }

    private func singleLyric(
        fontSize: CGFloat,
        availableWidth: CGFloat? = nil,
        alignment: TextAlignment = .leading
    ) -> some View {
        focusedLyrics(
            alignment: alignment,
            proposedCurrentFontSize: fontSize,
            availableWidth: availableWidth
        )
    }

    private func threeLineLyrics(
        alignment: TextAlignment,
        fontSize: CGFloat,
        availableWidth: CGFloat? = nil
    ) -> some View {
        focusedLyrics(
            alignment: alignment,
            proposedCurrentFontSize: fontSize * 1.16,
            availableWidth: availableWidth
        )
    }

    private func focusedLyrics(
        alignment: TextAlignment,
        proposedCurrentFontSize: CGFloat,
        availableWidth: CGFloat?
    ) -> some View {
        let lines = resolvedFocusLyrics
        let width = max(
            1,
            availableWidth ?? (metrics.size.width - leadingInset - trailingInset)
        )
        let typography = ImmersiveLyricTypographyPolicy.metrics(
            for: resolvedCurrentLyric,
            canvasWidth: metrics.size.width,
            canvasHeight: metrics.size.height,
            availableWidth: width,
            platform: lyricDisplayPlatform
        )
        let currentFontSize = max(proposedCurrentFontSize, CGFloat(typography.currentFontSize))
        let adjacentFontSize = max(
            CGFloat(typography.adjacentFontSize),
            min(currentFontSize * 0.64, proposedCurrentFontSize)
        )
        let stackAlignment: HorizontalAlignment = alignment == .trailing
            ? .trailing
            : (alignment == .center ? .center : .leading)
        return VStack(alignment: stackAlignment, spacing: CGFloat(typography.verticalSpacing)) {
            ForEach(lines) { line in
                let direction = writingDirection(for: line)
                let resolvedAlignment: TextAlignment = direction == .rightToLeft
                    ? .leading
                    : alignment
                let frameAlignment: Alignment = resolvedAlignment == .trailing
                    ? .trailing
                    : (resolvedAlignment == .center
                        ? .center
                        : (direction == .rightToLeft ? .trailing : .leading))
                lyricLine(
                    line,
                    fontSize: line.isActive ? currentFontSize : adjacentFontSize,
                    lineLimit: line.isActive
                        ? typography.currentLineLimit
                        : typography.adjacentLineLimit,
                    textAlignment: resolvedAlignment
                )
                .frame(maxWidth: .infinity, alignment: frameAlignment)
            }
        }
        .frame(
            maxWidth: width,
            alignment: Alignment(horizontal: stackAlignment, vertical: .center)
        )
        .animation(
            .easeOut(duration: lyricsMotionEnabled && !reduceMotion ? 0.28 : 0.01),
            value: resolvedCurrentLyric
        )
        .immersiveRestingText(isResting)
    }

    @ViewBuilder
    private func lyricLine(
        _ line: ImmersiveStageLyric,
        fontSize: CGFloat,
        lineLimit: Int,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: lyricStackAlignment(for: textAlignment), spacing: fontSize * 0.18) {
            leadLyricLine(
                line,
                fontSize: fontSize,
                lineLimit: lineLimit,
                textAlignment: textAlignment
            )
            ForEach(line.background) { background in
                backgroundLyricLine(
                    background,
                    isLineActive: line.isActive,
                    fontSize: fontSize * 0.7,
                    lineLimit: lineLimit,
                    textAlignment: textAlignment
                )
            }
            ForEach(line.companions.indices, id: \.self) { slot in
                Text(line.companions[slot])
                    .font(.system(size: fontSize * 0.55, weight: .medium))
                    .foregroundStyle(
                        ImmersiveStagePalette.text.opacity(line.isActive ? 0.62 : 0.34)
                    )
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(lineLimit)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
                    // The lead row already announces the line.
                    .accessibilityHidden(true)
            }
        }
        .environment(\.layoutDirection, layoutDirection(for: line))
    }

    private func lyricStackAlignment(for textAlignment: TextAlignment) -> HorizontalAlignment {
        switch textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// Backing vocals sweep on their own window while the lead line is on
    /// screen, and stay dim once the lead line has moved on.
    @ViewBuilder
    private func backgroundLyricLine(
        _ line: ImmersiveStageBackgroundLyric,
        isLineActive: Bool,
        fontSize: CGFloat,
        lineLimit: Int,
        textAlignment: TextAlignment
    ) -> some View {
        let stageLyric = ImmersiveStageLyric(
            id: line.id.hashValue,
            text: line.text,
            isActive: isLineActive,
            offset: 0,
            syllables: line.syllables,
            startTime: line.startTime,
            endTime: line.endTime,
            writingDirection: line.writingDirection
        )
        Group {
            if isLineActive, line.syllables != nil || hasLineTiming(stageLyric) {
                TimelineView(.animation(
                    minimumInterval: reduceMotion ? 0.10 : frameRate.minimumInterval(base: 1 / 30),
                    // 休憩时舞台文字已经淡出，逐字扫光不必再按帧画。
                    paused: !playbackClockIsActive || isResting
                )) { _ in
                    activeLyricText(
                        stageLyric,
                        fontSize: fontSize,
                        lineLimit: lineLimit,
                        textAlignment: textAlignment,
                        progress: activeLyricProgress(
                            for: stageLyric,
                            at: playbackTime?() ?? track.elapsed
                        )
                    )
                }
            } else {
                Text(line.text)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.42))
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(lineLimit)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .opacity(0.72)
        // The lead row already carries the spoken lyric, so the backing group
        // must not announce itself as a second "current lyric".
        .accessibilityHidden(true)
        .environment(\.layoutDirection, layoutDirection(for: stageLyric))
    }

    @ViewBuilder
    private func leadLyricLine(
        _ line: ImmersiveStageLyric,
        fontSize: CGFloat,
        lineLimit: Int,
        textAlignment: TextAlignment
    ) -> some View {
        Group {
            if line.isActive, line.syllables != nil || hasLineTiming(line) {
                TimelineView(.animation(
                    minimumInterval: reduceMotion ? 0.10 : frameRate.minimumInterval(base: 1 / 30),
                    // 休憩时舞台文字已经淡出，逐字扫光不必再按帧画。
                    paused: !playbackClockIsActive || isResting
                )) { _ in
                    activeLyricText(
                        line,
                        fontSize: fontSize,
                        lineLimit: lineLimit,
                        textAlignment: textAlignment,
                        progress: activeLyricProgress(
                            for: line,
                            at: playbackTime?() ?? track.elapsed
                        )
                    )
                }
            } else if line.isActive {
                activeLyricText(
                    line,
                    fontSize: fontSize,
                    lineLimit: lineLimit,
                    textAlignment: textAlignment,
                    progress: line.fillProgress ?? 1
                )
            } else {
                Text(line.text)
                    .font(.system(
                        size: fontSize,
                        weight: line.offset < 0 ? .regular : .medium
                    ))
                    .foregroundStyle(
                        ImmersiveStagePalette.text.opacity(line.offset < 0 ? 0.30 : 0.56)
                    )
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(lineLimit)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }

    private func hasLineTiming(_ line: ImmersiveStageLyric) -> Bool {
        guard let start = line.startTime, let end = line.endTime else { return false }
        return start.isFinite && end.isFinite && end > start
    }

    private func activeLyricProgress(
        for line: ImmersiveStageLyric,
        at playbackTime: TimeInterval
    ) -> Double {
        if let fillProgress = line.fillProgress { return fillProgress }
        if let syllables = line.syllables {
            return ImmersiveLyricHighlightProgressPolicy.progress(
                in: syllables,
                at: playbackTime
            )
        }
        guard let start = line.startTime, let end = line.endTime else { return 1 }
        return ImmersiveLyricHighlightProgressPolicy.progress(
            from: start,
            to: end,
            at: playbackTime
        )
    }

    private func activeLyricText(
        _ line: ImmersiveStageLyric,
        fontSize: CGFloat,
        lineLimit: Int,
        textAlignment: TextAlignment,
        progress: Double
    ) -> some View {
        let clampedProgress = min(1, max(0, progress))
        let lineWritingDirection = writingDirection(for: line)
        let text = Text(line.text)
            .font(.system(size: fontSize, weight: .bold))
            .multilineTextAlignment(textAlignment)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.72)
            .fixedSize(horizontal: false, vertical: true)

        return text
            .foregroundStyle(ImmersiveStagePalette.ink.opacity(0.64))
            .overlay {
                text
                    .foregroundStyle(LinearGradient(
                        colors: [ImmersiveStagePalette.ink, palette.primary, ImmersiveStagePalette.ink],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .mask {
                        ImmersiveLyricFillMask(
                            progress: clampedProgress,
                            fontSize: fontSize,
                            isRightToLeft: lineWritingDirection == .rightToLeft
                        )
                    }
            }
            .shadow(color: palette.primary.opacity(0.34), radius: max(2, fontSize * 0.10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: PMString(
                "immersive_current_lyric_accessibility",
                line.text
            )))
    }

    private var resolvedCurrentStageLyric: ImmersiveStageLyric? {
        guard !lyricInterlude else { return nil }
        if let active = lyricWindow.first(where: \.isActive),
           !active.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return active
        }
        if let currentLyric,
           !currentLyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ImmersiveStageLyric(
                id: Int.min + 1,
                text: currentLyric,
                isActive: true,
                offset: 0,
                fillProgress: 1
            )
        }
        let placeholder = lyricsPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !placeholder.isEmpty else { return nil }
        return ImmersiveStageLyric(
            id: Int.min,
            text: placeholder,
            isActive: true,
            offset: 0,
            fillProgress: 1
        )
    }

    private var resolvedCurrentLyric: String {
        resolvedCurrentStageLyric?.text ?? ""
    }

    private var resolvedFocusLyrics: [ImmersiveStageLyric] {
        guard let current = resolvedCurrentStageLyric else { return [] }
        let currentKey = ImmersiveTypographyFieldPolicy.normalizedKey(current.text)
        var seen = Set([currentKey])
        let candidates = lyricWindow
            .filter { !$0.isActive && (-1...1).contains($0.offset) }
            .sorted { $0.offset < $1.offset }
            .filter { line in
                let key = ImmersiveTypographyFieldPolicy.normalizedKey(line.text)
                return !key.isEmpty && seen.insert(key).inserted
            }
        let previous = candidates.last { $0.offset < 0 }
        let next = candidates.first { $0.offset > 0 }
        return [previous, current, next].compactMap { $0 }
    }

    private var persistentOverlay: some View {
        ZStack {
            if showsClock {
                ImmersiveStageClock(
                    showsDate: metrics.isWide,
                    timeSize: metrics.s(platform == .tvOS ? 44 : 25),
                    dateSize: metrics.s(platform == .tvOS ? 16 : 10)
                )
                .padding(.top, max(metrics.safeArea.top, metrics.s(platform == .tvOS ? 66 : 24)))
                .padding(.trailing, max(metrics.safeArea.trailing, metrics.s(platform == .tvOS ? 92 : 28)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

}

/// 把一个场景的构造推迟到这一层自己的 `body` 里，由 SwiftUI 单独求值。
///
/// Debug（-Onone）构建不复用栈槽：`scene` 这个多路 switch 会给每个场景、每层
/// 条件包装都预留一份栈，没走到的分支也照样留。播放页同样形状的 switch 已经在 iPhone
/// 主线程 1MB 的栈上撞过保护页（见 `NowPlayingDeferredContent`）。包进这一层后
/// `scene` 只持有一个闭包大小的值，场景本身等这一层更新时才构造。
private struct ImmersiveStageDeferredScene<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
    }
}

/// Keeps the high-frequency playback clock inside the tiny progress layer.
/// Theme backgrounds, artwork and lyrics remain unchanged between real content
/// updates instead of being rebuilt for every engine time sample.
private struct ImmersiveHairlinePlaybackProgress: View {
    let initialElapsed: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let playbackTime: (@MainActor () -> TimeInterval)?
    let height: CGFloat
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !isPlaying)) { _ in
            ImmersiveHairlineProgress(
                fraction: ImmersivePlaybackClock.fraction(
                    elapsed: playbackTime?() ?? initialElapsed,
                    duration: duration
                ),
                height: height,
                accent: accent
            )
        }
    }
}

/// 频谱环的取数宿主：把 bandLevels 的读取限制在这一层，环本体仍收静态数组。
private struct ImmersiveSpectrumRingHost: View {
    let levelsProvider: @MainActor () -> [CGFloat]
    let barWidth: CGFloat
    let isAnimating: Bool
    let tint: Color
    let isPlaying: Bool

    var body: some View {
        ImmersiveSpectrumRing(
            levels: levelsProvider(),
            barWidth: barWidth,
            isAnimating: isAnimating,
            tint: tint,
            isPlaying: isPlaying
        )
    }
}

private enum ImmersivePlaybackClock {
    static func elapsed(_ value: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        let clamped = max(0, value)
        return duration > 0 ? min(clamped, duration) : clamped
    }

    static func fraction(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    static func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

// MARK: - 封面流(#191)

/// 封面流的几何：舞台画面与全屏页的拖动、点按判定（点中间那张 = 播放 / 暂停，点两侧 = 跳到那首）
/// 共用这一份，算法本身在 `AlbumFlowLayoutPolicy`。左右边距与舞台其他场景同一套取值。
enum ImmersiveAlbumFlowGeometry {
    /// 倒影下面那块歌词的字号与行数。歌词区的高度按它固定下来，换句时封面不跟着上下跳。
    struct LyricFonts {
        let current: CGFloat
        let next: CGFloat
        let currentLineLimit: Int
        /// 手机横屏高度紧，只放当前这句。
        let showsNextLine: Bool
        let spacing: CGFloat

        var height: CGFloat {
            let currentBlock = current * 1.25 * CGFloat(currentLineLimit)
            return showsNextLine ? currentBlock + spacing + next * 1.25 : currentBlock
        }
    }

    static func lyricFonts(metrics: ImmersiveStageMetrics, platform: ImmersiveStagePlatform) -> LyricFonts {
        switch metrics.layout {
        case .phonePortrait:
            LyricFonts(current: metrics.s(17), next: metrics.s(13), currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(6))
        case .phoneLandscape:
            LyricFonts(current: metrics.s(15), next: metrics.s(11), currentLineLimit: 1, showsNextLine: false, spacing: 0)
        case .wide:
            platform == .tvOS
                ? LyricFonts(current: metrics.s(40), next: metrics.s(27), currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(12))
                : LyricFonts(current: metrics.s(30), next: metrics.s(20), currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(8))
        }
    }

    static func titleSize(metrics: ImmersiveStageMetrics, platform: ImmersiveStagePlatform) -> CGFloat {
        metrics.s(platform == .tvOS ? 44 : (metrics.isPortrait ? 26 : 21))
    }

    static func subtitleSize(metrics: ImmersiveStageMetrics, platform: ImmersiveStagePlatform) -> CGFloat {
        max(titleSize(metrics: metrics, platform: platform) * 0.6, metrics.s(12))
    }

    static func layout(
        metrics: ImmersiveStageMetrics,
        platform: ImmersiveStagePlatform,
        controlsInset: CGFloat
    ) -> AlbumFlowLayoutPolicy.Layout {
        let baseHorizontalInset: CGFloat = switch metrics.layout {
        case .phonePortrait: metrics.s(24)
        case .phoneLandscape: metrics.s(36)
        case .wide: metrics.s(platform == .tvOS ? 118 : 76)
        }
        let horizontalInset = max(metrics.safeArea.leading, metrics.safeArea.trailing, baseHorizontalInset)
        let title = titleSize(metrics: metrics, platform: platform)
        let subtitle = subtitleSize(metrics: metrics, platform: platform)
        let titleHeight = title * 1.25 + subtitle * 1.3 + metrics.s(4)
        return AlbumFlowLayoutPolicy.layout(
            canvasWidth: Double(metrics.size.width),
            canvasHeight: Double(metrics.size.height),
            topInset: Double(metrics.stageContentTopInset(isTV: platform == .tvOS)),
            bottomInset: Double(max(metrics.safeArea.bottom, metrics.s(14)) + controlsInset),
            horizontalInset: Double(horizontalInset),
            titleHeight: Double(titleHeight),
            titleSpacing: Double(metrics.s(platform == .tvOS ? 26 : 12)),
            lyricHeight: Double(lyricFonts(metrics: metrics, platform: platform).height),
            lyricSpacing: Double(metrics.s(platform == .tvOS ? 14 : 8))
        )
    }
}

/// 封面流里的一张：封面正下方接一截倒影（同一张封面上下翻转，越往下越淡，再叠一层专辑色），
/// 两者一起绕竖轴转，倒影跟着封面斜。
private struct ImmersiveAlbumFlowCover: View {
    /// 画出来多大。
    let side: CGFloat
    /// 按多大排版、取图：整张卡（封面、倒影、描边）按这个尺寸画好再缩放到 `side`，
    /// 拖动、滑动途中图片不按新尺寸重新取。
    let artworkSide: CGFloat
    let cornerRadius: CGFloat
    let tiltDegrees: Double
    let reflectionFraction: CGFloat
    let tint: Color
    /// 这一张的静态封面，封面和倒影都用它。滑到中间、滑出中间都是同一张图，不必重新取。
    let cover: AnyView
    /// 中间那张叠在上面的成品卡片（动态封面、玻璃描边、投影）；两侧为 nil。
    let hero: AnyView?

    static func gap(side: CGFloat) -> CGFloat { max(side * 0.012, 1) }

    static func height(side: CGFloat, reflectionFraction: CGFloat) -> CGFloat {
        side + gap(side: side) + side * reflectionFraction
    }

    var body: some View {
        let base = max(artworkSide, 1)
        VStack(spacing: Self.gap(side: base)) {
            cover
                .frame(width: base, height: base)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .overlay {
                    if let hero {
                        hero
                            .frame(width: base, height: base)
                            .transition(.opacity)
                    }
                }
            cover
                .frame(width: base, height: base)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay { tint.opacity(0.22) }
                .scaleEffect(x: 1, y: -1)
                .frame(width: base, height: base * reflectionFraction, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.46), location: 0),
                            .init(color: .black.opacity(0.12), location: 0.55),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: base, height: Self.height(side: base, reflectionFraction: reflectionFraction))
        .scaleEffect(side / base)
        .frame(width: side, height: Self.height(side: side, reflectionFraction: reflectionFraction))
        .rotation3DEffect(
            .degrees(tiltDegrees),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.55
        )
        .accessibilityHidden(hero == nil)
    }
}

/// 封面流的光与台面：中间那张后面一团专辑色的光慢慢呼吸，台面上沿有一点高光从左往右缓缓扫过，
/// 像灯光掠过玻璃。和封面墙、唱片一组，只按时间走、不读频谱；暂停或减少动态效果时停成静止的样子。
private struct ImmersiveAlbumFlowAmbience: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    let tint: Color
    let glowCenter: UnitPoint
    let glowRadius: CGFloat
    /// 台面上沿（封面底边）在画布里的纵坐标。
    let baseline: CGFloat
    let isAnimating: Bool

    /// 呼吸一次、高光扫过一趟各要几秒。
    private static let breathPeriod = 9.0
    private static let sweepPeriod = 14.0

    var body: some View {
        TimelineView(.animation(
            minimumInterval: frameRate.minimumInterval(base: 1.0 / 20),
            paused: !isAnimating
        )) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = isAnimating ? sin(time / Self.breathPeriod * 2 * .pi) : 0
            let sweep = (time / Self.sweepPeriod).truncatingRemainder(dividingBy: 1)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RadialGradient(
                        colors: [tint.opacity(0.55 + 0.12 * breath), .clear],
                        center: glowCenter,
                        startRadius: 0,
                        endRadius: glowRadius * (1 + 0.06 * breath)
                    )
                    ImmersiveAlbumFlowFloor(tint: tint, glint: isAnimating ? sweep : nil)
                        .frame(
                            width: geometry.size.width,
                            height: max(geometry.size.height - baseline, 0)
                        )
                        .offset(y: baseline)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 封面立着的那面玻璃台面：上沿一道细高光，往下是渐淡的专辑色。
private struct ImmersiveAlbumFlowFloor: View {
    let tint: Color
    /// 扫过上沿的那点高光走到哪儿：0 在左边外面，1 在右边外面；nil 不画。
    var glint: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [tint.opacity(0.34), tint.opacity(0.10), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    colors: [.white.opacity(0), .white.opacity(0.22), .white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                if let glint {
                    let width = geometry.size.width * 0.32
                    // 从左边外面进来、右边外面出去，回到起点那一下看不见。
                    let x = (glint * 1.4 - 0.2) * geometry.size.width
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.14), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: width / 2
                            )
                        )
                        .frame(width: width, height: width * 0.16)
                        .position(x: x, y: 0)
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.5), .white.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width, height: 1)
                    .position(x: x, y: 0.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Dynamic scene renderers

private struct ImmersiveGalleryBackdrop: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    let count: Int
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool
    let artwork: (Int, CGFloat) -> AnyView

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width > geometry.size.height ? 5 : 3
            let gap = max(geometry.size.width * 0.022, 10)
            let side = max((geometry.size.width - gap * CGFloat(columns + 1)) / CGFloat(columns), 72)
            let visualCount = count > 0 ? min(max(count, columns * 3), columns * 4) : 0
            let rows = max(1, Int(ceil(Double(max(visualCount, 1)) / Double(columns))))
            let loopHeight = max(CGFloat(rows) * (side * 1.22 + gap), geometry.size.height + side + gap)

            ZStack {
                LinearGradient(
                    colors: [palette.secondary.opacity(0.82), ImmersiveStagePalette.obsidian],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // Resolve the artwork as reusable symbols. Animation only moves
                // rasterized tiles instead of laying out twenty image view trees.
                TimelineView(.animation(minimumInterval: frameRate.minimumInterval(base: 1.0 / 12), paused: !isAnimating)) { context in
                    Canvas(rendersAsynchronously: true) { canvas, _ in
                        let time = context.date.timeIntervalSinceReferenceDate
                        canvas.opacity = 0.50
                        for index in 0..<visualCount {
                            guard let tile = canvas.resolveSymbol(id: index) else { continue }
                            let column = index % columns
                            let row = index / columns
                            let phase = isAnimating
                                ? CGFloat((time / (72 + Double(column) * 9)).truncatingRemainder(dividingBy: 1))
                                : 0.28
                            let direction: CGFloat = column.isMultiple(of: 2) ? 1 : -1
                            let baseY = CGFloat(row) * (side * 1.22 + gap) + side / 2
                            canvas.draw(tile, at: CGPoint(
                                x: gap + side / 2 + CGFloat(column) * (side + gap),
                                y: wrapped(baseY + phase * loopHeight * direction, modulus: loopHeight) - side / 2
                            ))
                        }
                    } symbols: {
                        ForEach(0..<visualCount, id: \.self) { index in
                            artwork(index % count, side)
                                .frame(width: side, height: side * 1.17)
                                .clipShape(RoundedRectangle(cornerRadius: side * 0.07, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: side * 0.07, style: .continuous)
                                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
                                }
                                .tag(index)
                        }
                    }
                }
                .rotation3DEffect(
                    .degrees(geometry.size.width > geometry.size.height ? -12 : -7),
                    axis: (x: 0, y: 1, z: 0), perspective: 0.5
                )
                .scaleEffect(1.34)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    private func wrapped(_ value: CGFloat, modulus: CGFloat) -> CGFloat {
        guard modulus > 0 else { return value }
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }
}

private struct ImmersiveLyricFillMask: View {
    let progress: Double
    let fontSize: CGFloat
    let isRightToLeft: Bool

    /// 单行高度由探针量出,量到之前按一行处理(即退回旧行为,不会画错)。
    @State private var singleRowHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let rowCount = ImmersiveLyricRowFillPolicy.rowCount(
                totalHeight: Double(geometry.size.height),
                rowHeight: Double(singleRowHeight)
            )
            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { row in
                    let fill = ImmersiveLyricRowFillPolicy.fill(
                        progress: progress,
                        row: row,
                        rowCount: rowCount
                    )
                    HStack(spacing: 0) {
                        if isRightToLeft { Spacer(minLength: 0) }
                        Rectangle().frame(width: geometry.size.width * CGFloat(fill))
                        if !isRightToLeft { Spacer(minLength: 0) }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .background(alignment: .topLeading) { rowHeightProbe }
    }

    /// 用同一字号量一行文字的高度,据此判断整段被折成了几行。
    private var rowHeightProbe: some View {
        Text(verbatim: "M")
            .font(.system(size: fontSize, weight: .bold))
            .lineLimit(1)
            .hidden()
            .background {
                GeometryReader { probe in
                    Color.clear
                        .onAppear { singleRowHeight = probe.size.height }
                        .onChange(of: probe.size.height) { _, height in
                            singleRowHeight = height
                        }
                }
            }
    }
}

private extension View {
    /// 休憩时淡出可读文字：布局位置保留，退出休憩时原地淡回来，VoiceOver 也不再读到它。
    func immersiveRestingText(_ isResting: Bool) -> some View {
        opacity(isResting ? 0 : 1)
            .accessibilityHidden(isResting)
    }
}
