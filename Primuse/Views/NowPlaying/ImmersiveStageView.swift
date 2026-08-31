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

    init(
        id: Int,
        text: String,
        isActive: Bool,
        offset: Int,
        fillProgress: Double? = nil,
        syllables: [LyricSyllable]? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        writingDirection: LyricWritingDirection? = nil
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
    }
}

/// iOS、macOS 与 tvOS 共用的八类动态播放舞台。封面、封面墙与实时频谱由平台容器注入。
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

    @ViewBuilder
    private var scene: some View {
        switch style.scene {
        case .coverFlow:
            coverFlowScene
        case .coverGallery:
            coverGalleryScene
        case .starryNight:
            starryNightScene
        case .flowingLines:
            flowingLinesScene
        case .lightRhythm:
            lightRhythmScene
        case .kineticTitle:
            kineticTitleWallScene
        case .radialPulse:
            radialPulseScene
        case .liveWaveform:
            liveWaveformScene
        }
    }

    private var horizontalInset: CGFloat {
        switch metrics.layout {
        case .phonePortrait:
            max(metrics.safeArea.leading, metrics.s(24))
        case .phoneLandscape:
            max(metrics.safeArea.leading, metrics.s(36))
        case .wide:
            max(metrics.safeArea.leading, metrics.s(platform == .tvOS ? 118 : 76))
        }
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

    private var coverFlowScene: some View {
        ZStack {
            ImmersivePaletteFlowBackdrop(palette: palette, isAnimating: sceneIsAnimating)
            ImmersiveArtworkAtmosphere(
                isAnimating: sceneIsAnimating,
                blur: metrics.s(platform == .tvOS ? 82 : 58),
                opacity: 0.24,
                saturation: 1.5,
                artwork: artwork
            )
            .blendMode(.screen)
            ImmersiveFlowingLightRibbons(palette: palette, isAnimating: sceneIsAnimating)
            ImmersiveVignette(color: palette.secondary, center: .center, clearStop: 0.22, strength: 0.68)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(24)) {
                    compactHeader(artSide: metrics.s(58))
                    Spacer(minLength: metrics.s(44))
                    titleBlock(size: metrics.s(58), weight: .light)
                    Spacer()
                    singleLyric(fontSize: metrics.s(17))
                }
                .padding(.horizontal, horizontalInset)
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
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset + metrics.s(10))
            }
        }
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
                colors: [palette.secondary.opacity(0.44), palette.secondary.opacity(0.90)],
                startPoint: .top,
                endPoint: .bottom
            )
            ImmersiveVignette(color: .black, clearStop: 0.08, strength: 0.62)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(22)) {
                    artworkPlate(
                        side: min(metrics.size.width * 0.63, metrics.size.height * 0.31),
                        radius: metrics.f(8)
                    )
                    galleryTrackBlock
                    singleLyric(fontSize: metrics.s(16))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset + metrics.s(22))
                .padding(.bottom, bottomInset)
            } else {
                HStack(spacing: metrics.s(platform == .tvOS ? 82 : 46)) {
                    artworkPlate(
                        side: min(metrics.size.height * 0.48, metrics.size.width * 0.30),
                        radius: metrics.f(10)
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
                .padding(.horizontal, horizontalInset)
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
    }

    // MARK: - 3. 星夜

    private var starryNightScene: some View {
        ZStack {
            ImmersiveMovingStarField(palette: palette, isAnimating: sceneIsAnimating)
            RadialGradient(
                colors: [palette.primary.opacity(0.34), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: max(metrics.size.width, metrics.size.height) * 0.76
            )
            ImmersiveVignette(color: palette.secondary, clearStop: 0.25, strength: 0.64)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(24)) {
                    artworkPlate(
                        side: min(metrics.size.width * 0.69, metrics.size.height * 0.36),
                        radius: metrics.f(8)
                    )
                    titleBlock(size: metrics.s(48), weight: .light)
                    singleLyric(fontSize: metrics.s(16))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset + metrics.s(18))
                .padding(.bottom, bottomInset)
            } else {
                HStack(spacing: metrics.s(platform == .tvOS ? 82 : 48)) {
                    artworkPlate(
                        side: min(metrics.size.height * 0.50, metrics.size.width * 0.31),
                        radius: metrics.f(8)
                    )
                    VStack(alignment: .leading, spacing: metrics.s(18)) {
                        titleBlock(size: metrics.s(platform == .tvOS ? 96 : 60), weight: .light)
                        singleLyric(
                            fontSize: metrics.s(platform == .tvOS ? 28 : 18),
                            availableWidth: metrics.size.width * 0.46
                        )
                    }
                    .frame(maxWidth: metrics.size.width * 0.46, alignment: .leading)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    // MARK: - 4. 流动声纹

    private var flowingLinesScene: some View {
        ZStack {
            LinearGradient(
                colors: [palette.secondary, ImmersiveStagePalette.obsidian.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ImmersiveFlowingContourField(palette: palette, isAnimating: sceneIsAnimating)
            ImmersiveVignette(color: .black, clearStop: 0.30, strength: 0.56)

            if metrics.isPortrait {
                VStack(spacing: metrics.s(18)) {
                    threeLineLyrics(alignment: .trailing, fontSize: metrics.s(13))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    rotatingCircularArtwork(diameter: min(metrics.size.width * 0.54, metrics.size.height * 0.28))
                    Spacer()
                    titleBlock(size: metrics.s(44), weight: .semibold)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset + metrics.s(12))
            } else {
                ZStack {
                    rotatingCircularArtwork(
                        diameter: min(metrics.size.height * 0.54, metrics.size.width * 0.34)
                    )
                    .offset(x: metrics.size.width * 0.03, y: -metrics.size.height * 0.05)

                    VStack {
                        HStack(alignment: .top) {
                            Spacer()
                            threeLineLyrics(
                                alignment: .trailing,
                                fontSize: metrics.s(platform == .tvOS ? 27 : 17),
                                availableWidth: metrics.size.width * 0.34
                            )
                            .frame(maxWidth: metrics.size.width * 0.34, alignment: .trailing)
                        }
                        Spacer()
                        titleBlock(
                            size: metrics.s(platform == .tvOS ? 94 : 58),
                            weight: .semibold,
                            maxWidth: metrics.size.width * 0.46
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    // MARK: - 5. 光影呼吸

    private var lightRhythmScene: some View {
        ZStack {
            ImmersivePaletteFlowBackdrop(palette: palette, isAnimating: sceneIsAnimating, isLuminous: true)
            ImmersiveVignette(color: palette.secondary, clearStop: 0.18, strength: 0.58)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(22)) {
                    artworkPlate(
                        side: min(metrics.size.width * 0.73, metrics.size.height * 0.37),
                        radius: metrics.f(18)
                    )
                    titleBlock(size: metrics.s(43), weight: .semibold)
                    formatAndLyric(
                        fontSize: metrics.s(14),
                        availableWidth: metrics.size.width - horizontalInset * 2
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset + metrics.s(12))
                .padding(.bottom, bottomInset)
            } else {
                HStack(spacing: metrics.s(platform == .tvOS ? 82 : 48)) {
                    artworkPlate(
                        side: min(metrics.size.height * 0.56, metrics.size.width * 0.35),
                        radius: metrics.f(22)
                    )
                    VStack(alignment: .leading, spacing: metrics.s(22)) {
                        titleBlock(size: metrics.s(platform == .tvOS ? 98 : 62), weight: .semibold)
                        formatAndLyric(
                            fontSize: metrics.s(platform == .tvOS ? 24 : 15),
                            availableWidth: metrics.size.width * 0.43
                        )
                    }
                    .frame(maxWidth: metrics.size.width * 0.43, alignment: .leading)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
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
    }

    // MARK: - 6. 曲名展墙

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
        let titleCenterX = horizontalInset + titleWidth / 2
        let lyricCenterX = currentDirection == .rightToLeft
            ? metrics.size.width - horizontalInset - lyricWidth / 2
            : horizontalInset + lyricWidth / 2

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
            }
        }
    }

    // MARK: - 7. 环形声谱

    private var radialPulseScene: some View {
        let diameter = min(
            metrics.size.height * (metrics.isPortrait ? 0.46 : 0.70),
            metrics.size.width * (metrics.isPortrait ? 0.88 : 0.49)
        )
        return ZStack {
            palette.secondary
            RadialGradient(
                colors: [palette.primary.opacity(0.38), .clear],
                center: metrics.isPortrait ? .top : .leading,
                startRadius: 0,
                endRadius: diameter * 1.2
            )

            if metrics.isPortrait {
                VStack(spacing: metrics.s(28)) {
                    radialArtwork(diameter: diameter)
                    titleBlock(size: metrics.s(43), weight: .semibold)
                    formatAndLyric(
                        fontSize: metrics.s(12),
                        availableWidth: metrics.size.width - horizontalInset * 2
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset + metrics.s(14))
                .padding(.bottom, bottomInset)
            } else {
                HStack(spacing: metrics.s(platform == .tvOS ? 82 : 52)) {
                    radialArtwork(diameter: diameter)
                    VStack(alignment: .leading, spacing: metrics.s(18)) {
                        titleBlock(size: metrics.s(platform == .tvOS ? 94 : 60), weight: .semibold)
                        formatAndLyric(
                            fontSize: metrics.s(platform == .tvOS ? 23 : 14),
                            availableWidth: metrics.size.width * 0.38
                        )
                    }
                    .frame(maxWidth: metrics.size.width * 0.38, alignment: .leading)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    private func radialArtwork(diameter: CGFloat) -> some View {
        ZStack {
            ImmersiveSpectrumRing(
                levels: levels,
                barWidth: max(1.4, metrics.f(platform == .tvOS ? 5 : 3)),
                isAnimating: sceneIsAnimating,
                tint: palette.primary,
                isPlaying: playbackClockIsActive
            )

            rotatingCircularArtwork(diameter: diameter * 0.60)
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - 8. 实时波形

    private var liveWaveformScene: some View {
        ZStack {
            ImmersivePaletteFlowBackdrop(palette: palette, isAnimating: sceneIsAnimating, intensity: 0.50)
            ImmersiveVignette(color: palette.secondary, clearStop: 0.14, strength: 0.72)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(22)) {
                    artworkPlate(
                        side: min(metrics.size.width * 0.76, metrics.size.height * 0.37),
                        radius: metrics.f(20)
                    )
                    titleBlock(size: metrics.s(42), weight: .semibold)
                    waveformPanel(height: metrics.s(72))
                    singleLyric(fontSize: metrics.s(16))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset + metrics.s(14))
                .padding(.bottom, bottomInset)
            } else {
                HStack(spacing: metrics.s(platform == .tvOS ? 82 : 48)) {
                    artworkPlate(
                        side: min(metrics.size.height * 0.55, metrics.size.width * 0.34),
                        radius: metrics.f(20)
                    )
                    VStack(alignment: .leading, spacing: metrics.s(22)) {
                        titleBlock(size: metrics.s(platform == .tvOS ? 92 : 58), weight: .semibold)
                        waveformPanel(height: metrics.s(platform == .tvOS ? 118 : 74))
                        singleLyric(
                            fontSize: metrics.s(platform == .tvOS ? 27 : 17),
                            availableWidth: metrics.size.width * 0.46
                        )
                    }
                    .frame(maxWidth: metrics.size.width * 0.46, alignment: .leading)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    private func waveformPanel(height: CGFloat) -> some View {
        ImmersiveWaveformPlaybackPanel(
            levels: levels,
            initialElapsed: track.elapsed,
            duration: track.duration,
            isPlaying: playbackClockIsActive,
            playbackTime: playbackTime,
            active: palette.primary,
            inactive: ImmersiveStagePalette.text.opacity(0.22),
            waveformHeight: height,
            labelFontSize: metrics.s(platform == .tvOS ? 20 : 11),
            spacing: metrics.s(8)
        )
        .accessibilityLabel(visualizerDisclosure)
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
    }

    private func titleBlock(
        size: CGFloat,
        weight: Font.Weight,
        maxWidth: CGFloat? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.s(8)) {
            Text(track.title)
                .font(.system(size: size, weight: weight))
                .tracking(-size * 0.028)
                .lineLimit(2)
                .minimumScaleFactor(0.44)
            Text(track.subtitle)
                .font(.system(size: max(size * 0.27, metrics.s(12)), weight: .regular))
                .foregroundStyle(ImmersiveStagePalette.text.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: maxWidth ?? .infinity, alignment: .leading)
    }

    private func artworkPlate(side: CGFloat, radius: CGFloat) -> some View {
        ImmersiveArtworkPlate(
            side: side,
            cornerRadius: radius,
            glowColor: palette.primary,
            artwork: artwork
        )
    }

    private func rotatingCircularArtwork(diameter: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !sceneIsAnimating)) { context in
            let seconds = sceneIsAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            artwork(diameter)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
                .shadow(color: palette.primary.opacity(0.38), radius: diameter * 0.12)
                .rotationEffect(.degrees(seconds.truncatingRemainder(dividingBy: 22) / 22 * 360))
        }
        .frame(width: diameter, height: diameter)
    }

    private func singleLyric(
        fontSize: CGFloat,
        availableWidth: CGFloat? = nil
    ) -> some View {
        focusedLyrics(
            alignment: .leading,
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
            availableWidth ?? (metrics.size.width - horizontalInset * 2)
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
        return VStack(alignment: .leading, spacing: CGFloat(typography.verticalSpacing)) {
            ForEach(lines) { line in
                let direction = writingDirection(for: line)
                let resolvedAlignment: TextAlignment = direction == .rightToLeft
                    ? .leading
                    : alignment
                let frameAlignment: Alignment = resolvedAlignment == .trailing
                    ? .trailing
                    : (direction == .rightToLeft ? .trailing : .leading)
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
            alignment: alignment == .trailing ? .trailing : .leading
        )
        .animation(
            .easeOut(duration: lyricsMotionEnabled && !reduceMotion ? 0.28 : 0.01),
            value: resolvedCurrentLyric
        )
    }

    @ViewBuilder
    private func lyricLine(
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
        .environment(\.layoutDirection, layoutDirection(for: line))
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
                        GeometryReader { geometry in
                            HStack(spacing: 0) {
                                if lineWritingDirection == .rightToLeft {
                                    Spacer(minLength: 0)
                                }
                                Rectangle()
                                    .frame(width: geometry.size.width * clampedProgress)
                                if lineWritingDirection != .rightToLeft {
                                    Spacer(minLength: 0)
                                }
                            }
                            .environment(\.layoutDirection, .leftToRight)
                        }
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

private struct ImmersiveWaveformPlaybackPanel: View {
    let levels: [CGFloat]
    let initialElapsed: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let playbackTime: (@MainActor () -> TimeInterval)?
    let active: Color
    let inactive: Color
    let waveformHeight: CGFloat
    let labelFontSize: CGFloat
    let spacing: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !isPlaying)) { _ in
            let elapsed = ImmersivePlaybackClock.elapsed(
                playbackTime?() ?? initialElapsed,
                duration: duration
            )
            let progress = ImmersivePlaybackClock.fraction(elapsed: elapsed, duration: duration)
            VStack(spacing: spacing) {
                ImmersiveLiveWaveform(
                    levels: levels,
                    progress: progress,
                    active: active,
                    inactive: inactive
                )
                .frame(height: waveformHeight)

                HStack {
                    Text(ImmersivePlaybackClock.timeString(elapsed))
                    Spacer()
                    Text("−\(ImmersivePlaybackClock.timeString(max(duration - elapsed, 0)))")
                }
                .font(.system(size: labelFontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(ImmersiveStagePalette.text.opacity(0.55))
                .monospacedDigit()
            }
        }
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

                ZStack {
                    LinearGradient(
                        colors: [palette.secondary.opacity(0.82), ImmersiveStagePalette.obsidian],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

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

private struct ImmersiveMovingStarField: View {
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 18, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [ImmersiveStagePalette.obsidian, palette.secondary.opacity(0.72)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                ))

                for index in 0..<112 {
                    let seed = Double((index &* 1103515245 &+ 12345) & 0x7fffffff) / Double(Int32.max)
                    let seed2 = Double((index &* 214013 &+ 2531011) & 0x7fffffff) / Double(Int32.max)
                    let drift = isAnimating ? time * (0.0025 + seed * 0.006) : 0
                    let xRatio = (seed + drift).truncatingRemainder(dividingBy: 1)
                    let yRatio = (seed2 + drift * (0.35 + seed)).truncatingRemainder(dividingBy: 1)
                    let pulse = isAnimating ? (sin(time * (0.55 + seed) + Double(index)) + 1) / 2 : 0.55
                    let radius = CGFloat(0.7 + seed2 * 1.8)
                    let rect = CGRect(
                        x: CGFloat(xRatio) * size.width,
                        y: CGFloat(yRatio) * size.height,
                        width: radius * 2,
                        height: radius * 2
                    )
                    let color = index.isMultiple(of: 4) ? palette.primary : ImmersiveStagePalette.ink
                    canvas.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.20 + pulse * 0.62)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ImmersiveFlowingContourField: View {
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 18, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                let center = CGPoint(x: size.width * 0.52, y: size.height * 0.43)
                let base = min(size.width, size.height) * 0.11
                for ring in 0..<24 {
                    var path = Path()
                    let ringScale = base + CGFloat(ring) * min(size.width, size.height) * 0.035
                    let points = 128
                    for point in 0...points {
                        let angle = Double(point) / Double(points) * 2 * .pi
                        let ringPhase = Double(ring)
                        let primaryPhase = angle * 3 + time * 0.34 + ringPhase * 0.31
                        let secondaryPhase = angle * 5 - time * 0.22 + ringPhase * 0.18
                        let primaryWave = sin(primaryPhase) * 0.08
                        let secondaryWave = cos(secondaryPhase) * 0.045
                        let wave = primaryWave + secondaryWave
                        let xRadius = ringScale * (1.18 + CGFloat(wave))
                        let yRadius = ringScale * (0.82 + CGFloat(wave * 0.72))
                        let driftPhase = time * 0.19 + ringPhase
                        let horizontalDrift = CGFloat(sin(driftPhase)) * ringScale * 0.07
                        let pointValue = CGPoint(
                            x: center.x + cos(angle) * xRadius + horizontalDrift,
                            y: center.y + sin(angle) * yRadius
                        )
                        if point == 0 { path.move(to: pointValue) } else { path.addLine(to: pointValue) }
                    }
                    path.closeSubpath()
                    canvas.stroke(
                        path,
                        with: .color((ring.isMultiple(of: 3) ? palette.primary : ImmersiveStagePalette.text).opacity(0.16 + Double(ring % 4) * 0.045)),
                        lineWidth: ring.isMultiple(of: 3) ? 1.4 : 0.75
                    )
                }
            }
        }
        .allowsHitTesting(false)
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

private struct ImmersiveLiveWaveform: View {
    let levels: [CGFloat]
    let progress: Double
    let active: Color
    let inactive: Color

    var body: some View {
        Canvas(rendersAsynchronously: true) { canvas, size in
            let preferredWidth = max(size.height * 0.045, 3)
            let preferredSpacing = max(preferredWidth * 0.82, 2.2)
            let availableCount = Int((size.width + preferredSpacing) / (preferredWidth + preferredSpacing))
            let count = min(max(availableCount, 38), 68)
            let spacing = max(min(preferredSpacing, size.width * 0.012), 2)
            let width = max((size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 2.4)
            let centerY = size.height / 2
            let playedWidth = size.width * CGFloat(min(max(progress, 0), 1))
            let baselineHeight = max(0.8, width * 0.18)

            let baseline = CGRect(
                x: 0,
                y: centerY - baselineHeight / 2,
                width: size.width,
                height: baselineHeight
            )
            canvas.fill(
                Path(roundedRect: baseline, cornerRadius: baselineHeight / 2),
                with: .color(inactive.opacity(0.48))
            )

            var playedBars = Path()
            var upcomingBars = Path()
            var currentBar: CGRect?

            for index in 0..<count {
                let level = levels.isEmpty
                    ? 0
                    : displayedLevel(at: index, outputCount: count, source: levels)
                let barHeight = max(width, size.height * (0.075 + level * 0.82))
                let rect = CGRect(
                    x: CGFloat(index) * (width + spacing),
                    y: centerY - barHeight / 2,
                    width: width,
                    height: barHeight
                )
                let path = Path(roundedRect: rect, cornerRadius: width / 2)
                if rect.midX <= playedWidth {
                    playedBars.addPath(path)
                    currentBar = rect
                } else {
                    upcomingBars.addPath(path)
                }
            }

            canvas.fill(upcomingBars, with: .color(inactive.opacity(0.88)))

            canvas.drawLayer { glow in
                glow.addFilter(.blur(radius: max(2, width * 1.2)))
                glow.fill(playedBars, with: .color(active.opacity(0.34)))
            }
            canvas.fill(
                playedBars,
                with: .linearGradient(
                    Gradient(colors: [
                        active.opacity(0.72),
                        ImmersiveStagePalette.ink.opacity(0.92),
                        active.opacity(0.78),
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            if let currentBar {
                let marker = currentBar.insetBy(dx: -max(0.6, width * 0.12), dy: -max(1.2, width * 0.28))
                canvas.fill(
                    Path(roundedRect: marker, cornerRadius: marker.width / 2),
                    with: .color(ImmersiveStagePalette.ink.opacity(0.92))
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// 低频落在略偏左的视觉重心，两侧分别用不同频率曲线展开。它保留真实
    /// FFT 的起伏，但不会形成机械的左右镜像或从左到右单调塌下的柱状图。
    private func displayedLevel(at index: Int, outputCount: Int, source: [CGFloat]) -> CGFloat {
        guard !source.isEmpty, outputCount > 1 else { return 0 }
        guard source.count > 1 else { return min(max(source[0], 0), 1) }

        let x = CGFloat(index) / CGFloat(outputCount - 1)
        let center: CGFloat = 0.43
        let distance: CGFloat
        let exponent: CGFloat
        if x < center {
            distance = (center - x) / center
            exponent = 0.86
        } else {
            distance = (x - center) / (1 - center)
            exponent = 1.14
        }

        let primaryPosition = pow(min(max(distance, 0), 1), exponent)
        let companionPosition = x < center
            ? min(primaryPosition * 0.58 + 0.12, 1)
            : min(primaryPosition * 0.72 + 0.18, 1)
        let primaryWeight: CGFloat = x < center ? 0.80 : 0.72
        let spectralValue = interpolatedLevel(at: primaryPosition, source: source) * primaryWeight
            + interpolatedLevel(at: companionPosition, source: source) * (1 - primaryWeight)
        let highFrequencyLift = 0.92 + primaryPosition * 0.34
        let compressed = pow(min(max(spectralValue * highFrequencyLift, 0), 1), 0.62)
        return min(max(compressed, 0), 1)
    }

    private func interpolatedLevel(at position: CGFloat, source: [CGFloat]) -> CGFloat {
        let scaled = min(max(position, 0), 1) * CGFloat(source.count - 1)
        let lower = min(Int(floor(scaled)), source.count - 1)
        let upper = min(lower + 1, source.count - 1)
        let fraction = scaled - CGFloat(lower)
        return source[lower] + (source[upper] - source[lower]) * fraction
    }
}
