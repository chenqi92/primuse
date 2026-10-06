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

/// iOS、macOS 与 tvOS 共用的七类动态播放舞台。封面、封面墙与实时频谱由平台容器注入。
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

    private var sceneIsAnimating: Bool {
        !reduceMotion && playbackClockIsActive
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
                    minimumInterval: reduceMotion ? 0.10 : frameRate.minimumInterval(base: 1 / 30),
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
