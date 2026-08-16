import Foundation
import SwiftUI

struct ImmersiveStageLyric: Identifiable, Equatable {
    let id: Int
    let text: String
    let isActive: Bool
    let offset: Int
    let fillProgress: Double?

    init(id: Int, text: String, isActive: Bool, offset: Int, fillProgress: Double? = nil) {
        self.id = id
        self.text = text
        self.isActive = isActive
        self.offset = offset
        self.fillProgress = fillProgress.map { min(max($0, 0), 1) }
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
    var levels: [CGFloat] = []
    var galleryArtworkCount = 0
    var galleryArtwork: (Int, CGFloat) -> AnyView = { _, _ in AnyView(Color.clear) }
    var reduceMotion = false
    var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    var lyricInterlude = false
    var lyricsPlaceholder = ""
    var visualizerDisclosure = ""
    var controlsInset: CGFloat = 0
    var showsClock = false
    var chromeBlurRadius: CGFloat = 52
    @ViewBuilder var artwork: (CGFloat) -> Artwork

    var body: some View {
        ZStack {
            scene
            persistentOverlay
            ImmersiveGrain(opacity: 0.032)
        }
        .background(ImmersiveStagePalette.obsidian)
        .foregroundStyle(ImmersiveStagePalette.ink)
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
            kineticTitleScene
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

    private var sceneIsAnimating: Bool {
        !reduceMotion && track.isPlaying
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
                    singleLyric(fontSize: metrics.s(platform == .tvOS ? 31 : 20))
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
                colors: [ImmersiveStagePalette.obsidian.opacity(0.44), ImmersiveStagePalette.obsidian.opacity(0.90)],
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
                        singleLyric(fontSize: metrics.s(platform == .tvOS ? 29 : 18))
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
            Text("正在播放 · \(track.source.isEmpty ? track.album : track.source)")
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
            ImmersiveVignette(color: ImmersiveStagePalette.obsidian, clearStop: 0.25, strength: 0.64)

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
                        singleLyric(fontSize: metrics.s(platform == .tvOS ? 28 : 18))
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
            ImmersiveStagePalette.obsidian
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
                                fontSize: metrics.s(platform == .tvOS ? 27 : 17)
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
                    formatAndLyric(fontSize: metrics.s(14))
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
                        formatAndLyric(fontSize: metrics.s(platform == .tvOS ? 24 : 15))
                    }
                    .frame(maxWidth: metrics.size.width * 0.43, alignment: .leading)
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
        }
    }

    private func formatAndLyric(fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: metrics.s(12)) {
            Text(track.format.uppercased())
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .tracking(fontSize * 0.14)
                .foregroundStyle(ImmersiveStagePalette.text.opacity(0.78))
                .lineLimit(1)
            singleLyric(fontSize: fontSize * 1.08)
        }
    }

    // MARK: - 6. 动态字幕

    private var kineticTitleScene: some View {
        ZStack {
            ImmersiveStagePalette.obsidian
            ImmersivePaletteFlowBackdrop(palette: palette, isAnimating: sceneIsAnimating, intensity: 0.32)
            ImmersiveKineticTitleField(
                title: track.title,
                palette: palette,
                isAnimating: sceneIsAnimating,
                fontSize: metrics.s(platform == .tvOS ? 150 : (metrics.isPortrait ? 82 : 112))
            )
            LinearGradient(
                colors: [.clear, ImmersiveStagePalette.obsidian.opacity(0.76)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                compactHeader(artSide: metrics.s(platform == .tvOS ? 92 : 58))
                Spacer()
                Text(track.title)
                    .font(.system(
                        size: metrics.s(platform == .tvOS ? 126 : (metrics.isPortrait ? 62 : 82)),
                        weight: .semibold
                    ))
                    .tracking(metrics.f(-2.3))
                    .lineLimit(2)
                    .minimumScaleFactor(0.45)
                singleLyric(fontSize: metrics.s(platform == .tvOS ? 30 : 18))
                    .padding(.top, metrics.s(28))
            }
            .padding(.horizontal, horizontalInset)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset + metrics.s(12))
        }
    }

    // MARK: - 7. 环形声谱

    private var radialPulseScene: some View {
        let diameter = min(
            metrics.size.height * (metrics.isPortrait ? 0.46 : 0.70),
            metrics.size.width * (metrics.isPortrait ? 0.88 : 0.49)
        )
        return ZStack {
            ImmersiveStagePalette.obsidian
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
                        Text(track.format.uppercased())
                            .font(.system(size: metrics.s(platform == .tvOS ? 23 : 14), weight: .medium, design: .monospaced))
                            .tracking(metrics.f(2))
                            .foregroundStyle(ImmersiveStagePalette.text.opacity(0.68))
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
                isPlaying: track.isPlaying
            )

            rotatingCircularArtwork(diameter: diameter * 0.60)
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - 8. 实时波形

    private var liveWaveformScene: some View {
        ZStack {
            ImmersivePaletteFlowBackdrop(palette: palette, isAnimating: sceneIsAnimating, intensity: 0.50)
            ImmersiveVignette(color: ImmersiveStagePalette.obsidian, clearStop: 0.14, strength: 0.72)

            if metrics.isPortrait {
                VStack(alignment: .leading, spacing: metrics.s(22)) {
                    artworkPlate(
                        side: min(metrics.size.width * 0.76, metrics.size.height * 0.37),
                        radius: metrics.f(20)
                    )
                    titleBlock(size: metrics.s(42), weight: .semibold)
                    waveformPanel(height: metrics.s(72))
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
            isPlaying: track.isPlaying,
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

    @ViewBuilder
    private func singleLyric(fontSize: CGFloat) -> some View {
        let text = resolvedCurrentLyric
        if !text.isEmpty {
            Text(text)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(ImmersiveStagePalette.ink.opacity(0.90))
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .id(lyricsMotionEnabled ? text : "static-lyric")
                .transition(lyricsMotionEnabled ? .opacity.combined(with: .offset(y: 8)) : .identity)
                .animation(.easeOut(duration: 0.26), value: text)
        }
    }

    private func threeLineLyrics(alignment: TextAlignment, fontSize: CGFloat) -> some View {
        let lines = resolvedThreeLyrics
        return VStack(alignment: alignment == .trailing ? .trailing : .leading, spacing: fontSize * 0.72) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(size: line.isActive ? fontSize * 1.16 : fontSize, weight: line.isActive ? .semibold : .regular))
                    .foregroundStyle(
                        line.isActive
                            ? ImmersiveStagePalette.ink.opacity(0.94)
                            : ImmersiveStagePalette.text.opacity(0.38)
                    )
                    .multilineTextAlignment(alignment)
                    .lineLimit(2)
            }
        }
    }

    private var resolvedCurrentLyric: String {
        if let active = lyricWindow.first(where: \.isActive)?.text,
           !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return active
        }
        if let currentLyric,
           !currentLyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return currentLyric
        }
        return lyricInterlude ? "" : lyricsPlaceholder
    }

    private var resolvedThreeLyrics: [ImmersiveStageLyric] {
        let lines = lyricWindow
            .filter { (-1...1).contains($0.offset) }
            .sorted { $0.offset < $1.offset }
        if !lines.isEmpty { return lines }
        guard !resolvedCurrentLyric.isEmpty else { return [] }
        return [ImmersiveStageLyric(id: 0, text: resolvedCurrentLyric, isActive: true, offset: 0)]
    }

    private var persistentOverlay: some View {
        ZStack(alignment: .bottom) {
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

            if style.scene != .liveWaveform {
                ImmersiveHairlinePlaybackProgress(
                    initialElapsed: track.elapsed,
                    duration: track.duration,
                    isPlaying: track.isPlaying,
                    playbackTime: playbackTime,
                    height: max(1, metrics.f(platform == .tvOS ? 4 : 2)),
                    accent: palette.primary
                )
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
            VStack(spacing: spacing) {
                ImmersiveLiveWaveform(
                    levels: levels,
                    progress: ImmersivePlaybackClock.fraction(elapsed: elapsed, duration: duration),
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
                        opacity: (isLuminous ? 0.92 : 0.70) * intensity
                    )
                    .frame(width: side * 1.45, height: side * 1.45)
                    .position(
                        x: geometry.size.width * 0.30 + wave(time, period: 27, amplitude: side * 0.09),
                        y: geometry.size.height * 0.30 + wave(time, period: 33, amplitude: side * 0.07)
                    )
                    glow(
                        color: palette.secondary,
                        radius: side * 0.64,
                        opacity: (isLuminous ? 0.86 : 0.56) * intensity
                    )
                    .frame(width: side * 1.35, height: side * 1.35)
                    .position(
                        x: geometry.size.width * 0.72 - wave(time, period: 35, amplitude: side * 0.08),
                        y: geometry.size.height * 0.68 - wave(time, period: 29, amplitude: side * 0.06)
                    )
                    if isLuminous {
                        glow(color: .white, radius: side * 0.38, opacity: 0.15 * intensity)
                            .frame(width: side, height: side)
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

private struct ImmersiveKineticTitleField: View {
    let title: String
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool
    let fontSize: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0

            GeometryReader { geometry in
                ZStack {
                    ForEach(0..<6, id: \.self) { index in
                        let rowSize = fontSize * (0.62 + CGFloat(index) * 0.105)
                        let speed = 0.09 + Double(index) * 0.018
                        let phase = time * speed + Double(index) * 0.88
                        let breathing = 0.92 + CGFloat((sin(phase * 1.7) + 1) * 0.065)
                        let horizontalDrift = CGFloat(sin(phase)) * geometry.size.width * (0.035 + CGFloat(index) * 0.006)
                        let verticalDrift = CGFloat(cos(phase * 0.73)) * rowSize * 0.18
                        let baseY = geometry.size.height * (0.14 + CGFloat(index) * 0.145)

                        ImmersiveTypeWall(
                            title: title,
                            fontSize: rowSize,
                            rowCount: 1,
                            solidRow: index == 2 ? 0 : -1,
                            lineWidth: max(0.8, rowSize * 0.011),
                            tint: index.isMultiple(of: 2) ? palette.primary : ImmersiveStagePalette.accent200
                        )
                        .frame(width: geometry.size.width * 1.18, height: rowSize * 1.18)
                        .scaleEffect(
                            x: breathing * (index.isMultiple(of: 2) ? 1 : 1.04),
                            y: breathing,
                            anchor: index.isMultiple(of: 2) ? .leading : .trailing
                        )
                        .rotationEffect(.degrees(sin(phase * 0.56) * (index.isMultiple(of: 2) ? 0.9 : -0.7)))
                        .position(
                            x: geometry.size.width / 2 + horizontalDrift,
                            y: baseY + verticalDrift
                        )
                        .opacity(index == 2 ? 0.74 : 0.26 + Double(index % 3) * 0.07)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ImmersiveLiveWaveform: View {
    let levels: [CGFloat]
    let progress: Double
    let active: Color
    let inactive: Color

    var body: some View {
        Canvas(rendersAsynchronously: true) { canvas, size in
            let count = 52
            let spacing = max(size.width * 0.006, 2)
            let width = max((size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 2)
            let centerY = size.height / 2

            for index in 0..<count {
                let level = levels.isEmpty
                    ? 0
                    : mirroredLevel(at: index, outputCount: count, source: levels)
                let barHeight = max(3, size.height * (0.06 + level * 0.88))
                let rect = CGRect(
                    x: CGFloat(index) * (width + spacing),
                    y: centerY - barHeight / 2,
                    width: width,
                    height: barHeight
                )
                let isPlayed = Double(index) / Double(max(count - 1, 1)) <= min(max(progress, 0), 1)
                canvas.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(isPlayed ? active.opacity(0.94) : inactive)
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// 横向声谱以中心为低频、两侧为高频做镜像，避免真实音乐普遍较强的
    /// 低频全部挤在左侧，形成截图里那种从左到右单调塌下的错误形态。
    private func mirroredLevel(at index: Int, outputCount: Int, source: [CGFloat]) -> CGFloat {
        guard !source.isEmpty, outputCount > 1 else { return 0 }
        guard source.count > 1 else { return min(max(source[0], 0), 1) }
        let center = Double(outputCount - 1) / 2
        let distance = abs(Double(index) - center) / max(center, 1)
        let position = distance * Double(source.count - 1)
        let lower = min(Int(floor(position)), source.count - 1)
        let upper = min(lower + 1, source.count - 1)
        let fraction = CGFloat(position - floor(position))
        let value = source[lower] + (source[upper] - source[lower]) * fraction
        return min(max(value, 0), 1)
    }
}
