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

/// iOS、macOS 与 tvOS 共用的十一类动态播放舞台。封面、封面墙与实时频谱由平台容器注入。
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
    var typographyFieldLines: [String] = []
    var isRenderingActive = true
    var reduceMotion = false
    var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    var lyricInterlude = false
    var lyricsPlaceholder = ""
    var visualizerDisclosure = ""
    var controlsInset: CGFloat = 0
    var showsClock = false
    /// 休憩时舞台把可读文字淡出，只留画面；时钟与歌词由容器的休憩层负责。
    var isResting = false
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

    private var lyricTextAlignment: TextAlignment {
        .leading
    }

    private var lyricFrameAlignment: Alignment {
        .leading
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
        .overlay(alignment: .bottom) {
            ImmersiveHairlinePlaybackProgress(
                initialElapsed: track.elapsed,
                duration: track.duration,
                isPlaying: playbackClockIsActive,
                playbackTime: playbackTime,
                height: max(1, metrics.f(platform == .tvOS ? 4 : 2)),
                accent: palette.primary
            )
        }
        .clipped()
    }

    /// 每个场景都经 `ImmersiveStageDeferredScene` 推迟构造，别直接内联回来（见那个类型的说明）。
    @ViewBuilder
    private var scene: some View {
        switch style.scene {
        case .coverFlow:
            ImmersiveStageDeferredScene { coverFlowScene }
        case .coverGallery:
            ImmersiveStageDeferredScene { coverGalleryScene }
        case .starryNight:
            ImmersiveStageDeferredScene { starryNightScene }
        case .flowingLines:
            ImmersiveStageDeferredScene { flowingLinesScene }
        case .kineticTitle:
            ImmersiveStageDeferredScene { kineticTitleWallScene }
        case .radialPulse:
            ImmersiveStageDeferredScene { radialPulseScene }
        case .vinylDeck:
            ImmersiveStageDeferredScene { vinylDeckScene }
        case .mirrorStage:
            ImmersiveStageDeferredScene { mirrorStageScene }
        case .auroraVeil:
            ImmersiveStageDeferredScene { auroraVeilScene }
        case .spectrumHorizon:
            ImmersiveStageDeferredScene { spectrumHorizonScene }
        case .particleBloom:
            ImmersiveStageDeferredScene { particleBloomScene }
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
        switch metrics.layout {
        case .phonePortrait:
            max(metrics.safeArea.top, metrics.s(54)) + metrics.s(30)
        case .phoneLandscape:
            max(metrics.safeArea.top, metrics.s(20)) + metrics.s(18)
        case .wide:
            max(metrics.safeArea.top, metrics.s(platform == .tvOS ? 76 : 48))
        }
    }

    private var bottomInset: CGFloat {
        max(metrics.safeArea.bottom, metrics.s(14)) + controlsInset
    }

    private var playbackClockIsActive: Bool {
        isRenderingActive && track.isPlaying
    }

    private var sceneIsAnimating: Bool {
        !reduceMotion && playbackClockIsActive
    }

    // MARK: - 1. 封面流光

    /// 居中构图：悬浮封面在正中，标题与歌词居中排在其下；手机横屏高度不够，
    /// 退回左封面右文字。
    private var coverFlowScene: some View {
        let isPhoneLandscape = metrics.layout == .phoneLandscape
        let side = metrics.isPortrait
            ? min(metrics.size.width * 0.72, metrics.size.height * 0.36)
            : (isPhoneLandscape
                ? min(metrics.size.height * 0.56, metrics.size.width * 0.30)
                : min(metrics.size.height * 0.40, metrics.size.width * 0.28))
        let textWidth = metrics.isPortrait ? nil : metrics.size.width * 0.62

        return ZStack {
            ImmersivePaletteFlowBackdrop(palette: palette, isAnimating: sceneIsAnimating)
            ImmersiveArtworkAtmosphere(
                isAnimating: sceneIsAnimating,
                blur: metrics.s(platform == .tvOS ? 82 : 58),
                opacity: 0.26,
                saturation: 1.5,
                artwork: artwork
            )
            .blendMode(.screen)
            ImmersiveFlowingLightRibbons(palette: palette, isAnimating: sceneIsAnimating)
            ImmersiveVignette(color: palette.secondary, center: .center, clearStop: 0.22, strength: 0.66)

            if isPhoneLandscape {
                HStack(spacing: metrics.s(56)) {
                    levitatingArtwork(side: side, radius: metrics.f(20))
                    VStack(alignment: .leading, spacing: metrics.s(20)) {
                        titleBlock(size: metrics.s(56), weight: .semibold)
                        singleLyric(fontSize: metrics.s(19), availableWidth: metrics.size.width * 0.46)
                    }
                    .frame(maxWidth: metrics.size.width * 0.46, alignment: .leading)
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            } else {
                VStack(spacing: metrics.s(metrics.isPortrait ? 28 : 22)) {
                    levitatingArtwork(side: side, radius: metrics.f(metrics.isPortrait ? 18 : 22))
                    titleBlock(
                        size: metrics.s(metrics.isPortrait ? 44 : (platform == .tvOS ? 84 : 54)),
                        weight: .semibold,
                        maxWidth: textWidth,
                        alignment: .center
                    )
                    singleLyric(
                        fontSize: metrics.s(metrics.isPortrait ? 17 : (platform == .tvOS ? 30 : 19)),
                        availableWidth: textWidth,
                        alignment: .center
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: metrics.isPortrait ? .top : .center)
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset + metrics.s(metrics.isPortrait ? 16 : 0))
                .padding(.bottom, bottomInset)
            }
        }
    }

    private func levitatingArtwork(side: CGFloat, radius: CGFloat) -> some View {
        ImmersiveLevitatingPlate(
            isAnimating: sceneIsAnimating,
            side: side,
            cornerRadius: radius,
            glow: palette.primary
        ) {
            artworkPlate(side: side, radius: radius)
        }
        .frame(width: side, height: side)
    }

    // MARK: - 2. 流动封面墙

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

    // MARK: - 3. 星夜

    /// 杂志式构图：左上小封面与艺人，正中一行细体大标题，底部一句歌词，
    /// 让文字像浮在夜空里。
    private var starryNightScene: some View {
        ZStack {
            ImmersiveDeepStarField(palette: palette, isAnimating: sceneIsAnimating)
            ImmersiveVignette(color: palette.secondary, clearStop: 0.28, strength: 0.58)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(24)) {
                    compactHeader(artSide: metrics.s(58))
                    Spacer(minLength: metrics.s(44))
                    titleBlock(size: metrics.s(58), weight: .light)
                    Spacer()
                    singleLyric(fontSize: metrics.s(17))
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset + metrics.s(30))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        compactHeader(artSide: metrics.s(platform == .tvOS ? 94 : 60))
                        Spacer()
                    }
                    Spacer()
                    titleBlock(
                        size: metrics.s(platform == .tvOS ? 132 : 82),
                        weight: .light,
                        maxWidth: metrics.size.width * 0.68
                    )
                    Spacer()
                    singleLyric(
                        fontSize: metrics.s(platform == .tvOS ? 31 : 20),
                        availableWidth: metrics.size.width * 0.72
                    )
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset + metrics.s(10))
            }
        }
    }

    // MARK: - 4. 流动声纹

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

    // MARK: - 5. 曲名展墙

    private var kineticTitleWallScene: some View {
        let current = resolvedCurrentStageLyric
        let currentDirection = current.map(writingDirection(for:)) ?? lyricsWritingDirection
        let titleWidth = metrics.size.width * (metrics.isPortrait ? 0.82 : (platform == .tvOS ? 0.62 : 0.66))
        let lyricWidth = metrics.size.width * (metrics.isPortrait ? 0.82 : (platform == .tvOS ? 0.72 : 0.68))
        let titleFontSize = CGFloat(ImmersiveLyricTypographyPolicy.fieldTitleFontSize(
            for: track.title,
            canvasWidth: metrics.size.width,
            canvasHeight: metrics.size.height,
            availableWidth: titleWidth,
            platform: lyricDisplayPlatform
        ))
        let lyricTypography = ImmersiveLyricTypographyPolicy.metrics(
            for: current?.text ?? "",
            canvasWidth: metrics.size.width,
            canvasHeight: metrics.size.height,
            availableWidth: lyricWidth,
            platform: lyricDisplayPlatform
        )
        let estimatedLyricHeight = CGFloat(lyricTypography.currentLineLimit)
            * CGFloat(lyricTypography.currentFontSize) * 1.18
        let desiredLyricCenterY = metrics.size.height * (metrics.isPortrait ? 0.73 : 0.78)
        let lyricCenterY = min(
            desiredLyricCenterY,
            metrics.size.height - controlsInset - estimatedLyricHeight / 2 - metrics.s(18)
        )
        let titleCenterX = leadingInset + titleWidth / 2
        let lyricCenterX = currentDirection == .rightToLeft
            ? metrics.size.width - trailingInset - lyricWidth / 2
            : leadingInset + lyricWidth / 2

        return ZStack {
            palette.secondary
            ImmersiveTypographyMotion(
                isAnimating: sceneIsAnimating && lyricsMotionEnabled,
                palette: palette
            )
                .opacity(0.52)
            ImmersiveStagePalette.obsidian.opacity(0.20)
            RadialGradient(
                colors: [palette.primary.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: max(metrics.size.width, metrics.size.height) * 0.72
            )

            ImmersiveLyricsTypographyField(
                lines: typographyFieldLines,
                currentLyric: current?.text,
                title: track.title,
                canvasSize: metrics.size,
                platform: lyricDisplayPlatform,
                tint: ImmersiveStagePalette.text.opacity(0.86),
                isAnimating: sceneIsAnimating && lyricsMotionEnabled,
                reduceMotion: reduceMotion
            )

            LinearGradient(
                colors: [
                    palette.secondary.opacity(0.42),
                    .clear,
                    .clear,
                    palette.secondary.opacity(0.78),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: metrics.s(platform == .tvOS ? 18 : 10)) {
                Text(track.title)
                    .font(.system(size: titleFontSize, weight: .bold))
                    .tracking(-titleFontSize * 0.035)
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.54))
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)
                    .fixedSize(horizontal: false, vertical: true)
                Text(track.subtitle)
                    .font(.system(
                        size: max(metrics.s(platform == .tvOS ? 28 : 16), titleFontSize * 0.20),
                        weight: .medium
                    ))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
            .frame(width: titleWidth, alignment: .leading)
            .position(
                x: titleCenterX,
                y: metrics.size.height * (metrics.isPortrait ? 0.34 : 0.43)
            )
            .accessibilityElement(children: .combine)
            .immersiveRestingText(isResting)

            if let current, !current.text.isEmpty {
                lyricLine(
                    current,
                    fontSize: CGFloat(lyricTypography.currentFontSize),
                    lineLimit: lyricTypography.currentLineLimit,
                    textAlignment: lyricTextAlignment
                )
                .frame(
                    width: lyricWidth,
                    alignment: currentDirection == .rightToLeft ? .trailing : lyricFrameAlignment
                )
                .position(
                    x: lyricCenterX,
                    y: lyricCenterY
                )
                .immersiveRestingText(isResting)
            }
        }
    }

    // MARK: - 6. 环形声谱

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
                isPlaying: playbackClockIsActive
            )
            .frame(width: span, height: span)
            .blur(radius: max(4, metrics.f(12)))
            .opacity(0.9)

            ImmersiveSpectrumRingHost(
                levelsProvider: spectrumProvider,
                barWidth: barWidth,
                isAnimating: sceneIsAnimating,
                tint: palette.primary,
                isPlaying: playbackClockIsActive
            )
            .frame(width: span, height: span)

            rotatingCircularArtwork(diameter: diameter * 0.60)
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - 7. 黑胶唱机

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
                isSpinning: playbackClockIsActive,
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

    // MARK: - 8. 镜面展台

    /// 横屏时文字在左、封面立在右侧镜面地板上；竖屏封面居中立于地板，文字在地平线下。
    private var mirrorStageScene: some View {
        let side = metrics.isPortrait
            ? min(metrics.size.width * 0.60, metrics.size.height * 0.30)
            : min(metrics.size.height * 0.46, metrics.size.width * 0.30)
        let availableTop = topInset
        let availableBottom = metrics.size.height - bottomInset
        let horizonY: CGFloat = metrics.isPortrait
            ? availableTop + metrics.s(36) + side
            : availableTop + (availableBottom - availableTop) * 0.5 + side * 0.42
        let plateX: CGFloat = metrics.isPortrait
            ? metrics.size.width / 2
            : metrics.size.width - trailingInset - side / 2 - metrics.s(12)
        let radius = metrics.f(10)
        let textGap = metrics.s(platform == .tvOS ? 90 : 56)

        return ZStack {
            ImmersiveMirrorFloor(
                palette: palette,
                isAnimating: sceneIsAnimating,
                horizonY: horizonY,
                spotlightX: plateX
            )
            ImmersiveVignette(color: .black, clearStop: 0.30, strength: 0.50)

            artwork(side)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .scaleEffect(y: -1)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.55), location: 0),
                            .init(color: .black.opacity(0.12), location: 0.45),
                            .init(color: .clear, location: 0.75),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .blur(radius: max(1, metrics.f(1.5)))
                .position(x: plateX, y: horizonY + side / 2 + metrics.f(2))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            artworkPlate(side: side, radius: radius)
                .position(x: plateX, y: horizonY - side / 2)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(14)) {
                    titleBlock(size: metrics.s(40), weight: .semibold)
                    singleLyric(fontSize: metrics.s(16))
                }
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, horizonY + metrics.s(30))
            } else {
                VStack(alignment: .leading, spacing: metrics.s(20)) {
                    titleBlock(size: metrics.s(platform == .tvOS ? 92 : 58), weight: .semibold)
                    singleLyric(
                        fontSize: metrics.s(platform == .tvOS ? 28 : 18),
                        availableWidth: metrics.size.width * 0.42
                    )
                }
                .frame(width: metrics.size.width * 0.42, alignment: .leading)
                .position(
                    x: plateX - side / 2 - textGap - metrics.size.width * 0.21,
                    y: horizonY - side / 2
                )
            }
        }
    }

    // MARK: - 9. 极光帷幕

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

    // MARK: - 10. 声场地平线

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

    // MARK: - 11. 星尘律动

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
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !sceneIsAnimating)) { context in
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
                    minimumInterval: reduceMotion ? 0.10 : 1 / 30,
                    paused: !playbackClockIsActive
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
                    minimumInterval: reduceMotion ? 0.10 : 1 / 30,
                    paused: !playbackClockIsActive
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
/// Debug（-Onone）构建不复用栈槽：`scene` 这个 13 路 switch 会给每个场景、每层
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

// MARK: - Dynamic scene renderers

private struct ImmersivePaletteFlowBackdrop: View {
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool
    var isLuminous = false
    var intensity = 1.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geometry in
                let side = max(geometry.size.width, geometry.size.height)
                let breath = isLuminous && isAnimating
                    ? (sin(time / 8.4 * 2 * .pi) + 1) / 2
                    : 0.5
                let primaryScale = isLuminous ? CGFloat(0.92 + breath * 0.16) : 1
                let secondaryScale = isLuminous ? CGFloat(1.08 - breath * 0.12) : 1
                ZStack {
                    palette.secondary.opacity(0.88)
                    LinearGradient(
                        colors: [palette.secondary.opacity(0.95), ImmersiveStagePalette.obsidian],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    glow(
                        color: palette.primary,
                        radius: side * 0.72,
                        opacity: (isLuminous ? 0.58 + breath * 0.38 : 0.70) * intensity
                    )
                    .frame(width: side * 1.45, height: side * 1.45)
                    .scaleEffect(primaryScale)
                    .position(
                        x: geometry.size.width * 0.30 + wave(time, period: 27, amplitude: side * 0.09),
                        y: geometry.size.height * 0.30 + wave(time, period: 33, amplitude: side * 0.07)
                    )
                    glow(
                        color: palette.secondary,
                        radius: side * 0.64,
                        opacity: (isLuminous ? 0.60 + (1 - breath) * 0.30 : 0.56) * intensity
                    )
                    .frame(width: side * 1.35, height: side * 1.35)
                    .scaleEffect(secondaryScale)
                    .position(
                        x: geometry.size.width * 0.72 - wave(time, period: 35, amplitude: side * 0.08),
                        y: geometry.size.height * 0.68 - wave(time, period: 29, amplitude: side * 0.06)
                    )
                    if isLuminous {
                        glow(
                            color: .white,
                            radius: side * 0.38,
                            opacity: (0.06 + breath * 0.16) * intensity
                        )
                            .frame(width: side, height: side)
                            .scaleEffect(CGFloat(0.82 + breath * 0.30))
                            .position(
                                x: geometry.size.width * 0.62 + wave(time, period: 21, amplitude: side * 0.05),
                                y: geometry.size.height * 0.28
                            )
                            .blendMode(.screen)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private func wave(_ time: TimeInterval, period: Double, amplitude: CGFloat) -> CGFloat {
        guard isAnimating else { return 0 }
        return CGFloat(sin(time / period * 2 * .pi)) * amplitude
    }

    private func glow(color: Color, radius: CGFloat, opacity: Double) -> some View {
        RadialGradient(
            stops: [
                .init(color: color.opacity(opacity), location: 0),
                .init(color: color.opacity(opacity * 0.42), location: 0.36),
                .init(color: color.opacity(0), location: 1),
            ],
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

/// 封面流光的可见运动层。真实封面负责色彩与模糊纹理，这组不同周期的柔光
/// 带负责让画面明确“流动”，而不是只剩几乎看不出的整屏渐变位移。
private struct ImmersiveFlowingLightRibbons: View {
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                canvas.blendMode = .plusLighter
                for index in 0..<5 {
                    let phase = wrapped(time / (18 + Double(index) * 4.5) + Double(index) * 0.19)
                    let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1
                    let originX = (CGFloat(phase) * 1.55 - 0.28) * size.width
                    let baseY = size.height * (0.16 + CGFloat(index) * 0.17)
                    let amplitude = size.height * (0.08 + CGFloat(index % 3) * 0.028)

                    var path = Path()
                    path.move(to: CGPoint(x: originX - size.width * 0.62, y: baseY))
                    path.addCurve(
                        to: CGPoint(x: originX + size.width * 0.72, y: baseY + amplitude * direction),
                        control1: CGPoint(
                            x: originX - size.width * 0.20,
                            y: baseY + amplitude * direction * 1.8
                        ),
                        control2: CGPoint(
                            x: originX + size.width * 0.26,
                            y: baseY - amplitude * direction * 1.5
                        )
                    )

                    let color = index.isMultiple(of: 2) ? palette.primary : palette.secondary
                    canvas.stroke(
                        path,
                        with: .color(color.opacity(index == 2 ? 0.42 : 0.24)),
                        style: StrokeStyle(
                            lineWidth: max(2, size.height * (index == 2 ? 0.028 : 0.014)),
                            lineCap: .round
                        )
                    )
                }
            }
            .blur(radius: max(8, metricsBlurRadius))
        }
        .opacity(0.78)
        .allowsHitTesting(false)
    }

    private var metricsBlurRadius: CGFloat { 18 }

    private func wrapped(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 1)
        return result < 0 ? result + 1 : result
    }
}

private struct ImmersiveGalleryBackdrop: View {
    let count: Int
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool
    let artwork: (Int, CGFloat) -> AnyView

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geometry in
                let columns = geometry.size.width > geometry.size.height ? 5 : 3
                let gap = max(geometry.size.width * 0.022, 10)
                let side = max((geometry.size.width - gap * CGFloat(columns + 1)) / CGFloat(columns), 72)
                // 封面墙只需要足以覆盖视口并完成循环的卡片。库里可能有数万首歌，
                // 绝不能把 count 直接变成同时驻留的 SwiftUI 图片视图。
                let visualCount = count > 0 ? min(max(count, columns * 3), columns * 4) : 0
                let rows = max(1, Int(ceil(Double(max(visualCount, 1)) / Double(columns))))
                let contentHeight = CGFloat(rows) * (side * 1.22 + gap)

                let isWide = geometry.size.width > geometry.size.height
                ZStack {
                    LinearGradient(
                        colors: [palette.secondary.opacity(0.82), ImmersiveStagePalette.obsidian],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    // 封面墙带透视倾斜：近端放大、远端收缩，画面有纵深而不是一张平铺贴图。
                    ZStack {
                        ForEach(0..<visualCount, id: \.self) { index in
                            let column = index % columns
                            let row = index / columns
                            let phase = isAnimating
                                ? CGFloat((time / (72 + Double(column) * 9)).truncatingRemainder(dividingBy: 1))
                                : 0.28
                            let direction: CGFloat = column.isMultiple(of: 2) ? 1 : -1
                            let loopHeight = max(contentHeight, geometry.size.height + side + gap)
                            let baseY = CGFloat(row) * (side * 1.22 + gap) + side / 2
                            let y = wrapped(baseY + phase * loopHeight * direction, modulus: loopHeight) - side / 2

                            artwork(index % count, side)
                                .frame(width: side, height: side * 1.17)
                                .clipShape(RoundedRectangle(cornerRadius: side * 0.07, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: side * 0.07, style: .continuous)
                                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
                                }
                                .position(
                                    x: gap + side / 2 + CGFloat(column) * (side + gap),
                                    y: y
                                )
                                .opacity(0.50)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .rotation3DEffect(
                        .degrees(isWide ? -12 : -7),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.5
                    )
                    .scaleEffect(1.34)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private func wrapped(_ value: CGFloat, modulus: CGFloat) -> CGFloat {
        guard modulus > 0 else { return value }
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }
}

private struct ImmersiveLyricsTypographyField: View {
    let lines: [String]
    let currentLyric: String?
    let title: String
    let canvasSize: CGSize
    let platform: ImmersiveLyricDisplayPlatform
    let tint: Color
    let isAnimating: Bool
    let reduceMotion: Bool

    @State private var cachedRenderItems: [ImmersiveTypographyFieldRenderItem] = []
    @State private var cachedLayoutKey = ""

    private var cacheKey: String {
        "\(platform.rawValue)|\(Int(canvasSize.width))x\(Int(canvasSize.height))|\(reduceMotion)|\(lines.joined(separator: "\u{1F}"))"
    }

    private var renderItems: [ImmersiveTypographyFieldRenderItem] {
        cachedLayoutKey == cacheKey ? cachedRenderItems : []
    }

    private var baseFontSize: CGFloat {
        let reference: CGSize
        let base: CGFloat
        switch platform {
        case .handheld:
            reference = CGSize(width: 393, height: 852)
            base = 38
        case .desktop:
            reference = CGSize(width: 1728, height: 1080)
            base = 56
        case .television:
            reference = CGSize(width: 1920, height: 1080)
            base = 72
        }
        let scale = min(canvasSize.width / reference.width, canvasSize.height / reference.height)
        return base * min(1.35, max(platform == .handheld ? 0.78 : 0.52, scale))
    }

    var body: some View {
        let foregroundKey = ImmersiveTypographyFieldPolicy.normalizedKey(currentLyric ?? "")
        let titleKey = ImmersiveTypographyFieldPolicy.normalizedKey(title)
        let items = renderItems
        ZStack {
            TimelineView(.animation(
                minimumInterval: ImmersiveTypographyFieldMotionPolicy.refreshInterval,
                paused: !isAnimating
            )) { context in
                let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
                Canvas(rendersAsynchronously: true) { canvas, _ in
                    for renderItem in items {
                        let item = renderItem.item
                        guard let path = renderItem.path,
                              item.normalizedTextKey != foregroundKey,
                              item.normalizedTextKey != titleKey else { continue }

                        let motion = ImmersiveTypographyFieldMotionPolicy.state(
                            for: item,
                            at: time,
                            allowsMotion: isAnimating
                        )
                        var itemCanvas = canvas
                        itemCanvas.translateBy(
                            x: canvasSize.width * CGFloat(motion.xOffsetFraction),
                            y: canvasSize.height * CGFloat(motion.yOffsetFraction)
                        )
                        itemCanvas.opacity = item.opacity * motion.opacityMultiplier
                        if item.blurRadius > 0 {
                            itemCanvas.addFilter(.blur(radius: CGFloat(item.blurRadius)))
                        }
                        if item.isOutlined {
                            itemCanvas.stroke(
                                path,
                                with: .color(tint),
                                lineWidth: max(0.8, renderItem.fontSize * 0.014)
                            )
                        } else {
                            itemCanvas.fill(
                                path,
                                with: .color(ImmersiveStagePalette.text)
                            )
                        }
                    }
                }
            }

            // Color emoji and other glyphs without a CoreText outline keep a
            // static fallback. They are rare, and must not rebuild the moving
            // field's render tree on every frame.
            ForEach(items.filter { $0.path == nil }) { renderItem in
                let item = renderItem.item
                let isForegroundText = item.normalizedTextKey == foregroundKey
                    || item.normalizedTextKey == titleKey
                Text(item.text)
                    .font(.system(size: renderItem.fontSize, weight: .semibold))
                    .foregroundStyle(
                        item.isOutlined ? tint.opacity(0.46) : ImmersiveStagePalette.text
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .allowsTightening(true)
                    .frame(
                        width: canvasSize.width * CGFloat(item.widthFraction),
                        height: renderItem.fontSize * 1.28
                    )
                    .rotationEffect(.degrees(item.rotationDegrees))
                    .opacity(isForegroundText ? 0 : item.opacity)
                    .position(
                        x: canvasSize.width * CGFloat(item.normalizedX),
                        y: canvasSize.height * CGFloat(item.normalizedY)
                    )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipped()
        .task(id: cacheKey) {
            let updatedLayout = ImmersiveTypographyFieldPolicy.layout(
                lines: lines,
                canvasWidth: canvasSize.width,
                canvasHeight: canvasSize.height,
                platform: platform,
                reduceMotion: reduceMotion
            )
            var prepared: [ImmersiveTypographyFieldRenderItem] = []
            prepared.reserveCapacity(updatedLayout.count)
            for (index, item) in updatedLayout.enumerated() {
                guard !Task.isCancelled else { return }
                let fontSize = baseFontSize * CGFloat(item.fontScale)
                let glyphs = ImmersiveGlyphLine.make(text: item.text, fontSize: fontSize)
                let path = glyphs.map {
                    transformedPath(
                        $0,
                        item: item,
                        fontSize: fontSize,
                        center: CGPoint(
                            x: canvasSize.width * CGFloat(item.normalizedX),
                            y: canvasSize.height * CGFloat(item.normalizedY)
                        )
                    )
                }
                prepared.append(ImmersiveTypographyFieldRenderItem(
                    item: item,
                    fontSize: fontSize,
                    path: path
                ))
                if index.isMultiple(of: 4) {
                    await Task.yield()
                }
            }
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cachedRenderItems = prepared
                cachedLayoutKey = cacheKey
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func transformedPath(
        _ glyphs: ImmersiveGlyphLine,
        item: ImmersiveTypographyFieldItem,
        fontSize: CGFloat,
        center: CGPoint
    ) -> Path {
        let targetWidth = canvasSize.width * CGFloat(item.widthFraction)
        let targetHeight = fontSize * 1.28
        let scale = min(
            1,
            min(
                targetWidth / max(glyphs.size.width, 1),
                targetHeight / max(glyphs.size.height, 1)
            )
        )
        let angle = CGFloat(item.rotationDegrees * .pi / 180)
        let cosine = cos(angle)
        let sine = sin(angle)
        let a = scale * cosine
        let b = scale * sine
        let c = -scale * sine
        let d = scale * cosine
        let sourceCenter = CGPoint(x: glyphs.size.width / 2, y: glyphs.size.height / 2)
        let transform = CGAffineTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: center.x - a * sourceCenter.x - c * sourceCenter.y,
            ty: center.y - b * sourceCenter.x - d * sourceCenter.y
        )
        return glyphs.path.applying(transform)
    }
}

private struct ImmersiveTypographyFieldRenderItem: Identifiable {
    let item: ImmersiveTypographyFieldItem
    let fontSize: CGFloat
    let path: Path?

    var id: Int { item.id }
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
