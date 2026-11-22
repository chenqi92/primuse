import Foundation
import PrimuseKit
import SwiftUI

// 「水彩小剧场」：水彩手绘 MV 的画风，猿音、小黑、阿酒、小火驴四个纸偶随音乐表演。
// 判定层、导演层和表演层在 PrimuseKit（ImmersiveTheaterConductor / Director / Performer），
// 这里只排版：舞台那一层（TimelineView 里每帧推进、Canvas 画），上面压纸纹和暗角，再放歌名和歌词带。
// 和 ImmersiveStageView 一样同时编进 Primuse(iOS)、PrimuseMac 与 PrimuseTV。

/// 水彩小剧场的整幅画面。歌词由舞台给（`lyrics`，白字）：夜空、雨夜里照样白字垫深色水彩带，花田里乘成墨色、
/// 垫浅色水彩带。
struct ImmersiveWatercolorTheaterScene<Lyrics: View>: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    @Environment(\.immersiveMotionIntensity) private var motion
    @Environment(\.displayScale) private var displayScale

    let metrics: ImmersiveStageMetrics
    let platform: ImmersiveStagePlatform
    let palette: ImmersiveArtworkPalette
    let title: String
    let subtitle: String
    /// 换歌时换一组角色、站位和镜头；同一首歌每次都一样。
    let songKey: String
    /// 舞台的内容边距：上沿、两侧安全区，下沿含控件让出的高度。
    let insets: EdgeInsets
    let hasLyrics: Bool
    let lyricCue: ImmersiveTheaterLyricCue?
    let firstLyricStart: TimeInterval?
    let elapsed: TimeInterval
    let duration: TimeInterval
    let playbackTime: (@MainActor () -> TimeInterval)?
    let isPlaying: Bool
    /// 允许动（没减弱动态效果、在屏幕上、不在省电档）。播放中一直动；暂停后先演一段「摘耳机看镜头」再打呼，
    /// 九秒后停在打呼那一帧。
    let motionAllowed: Bool
    let isResting: Bool
    /// 不建立观察的那份频谱。
    let levelsProvider: @MainActor () -> [CGFloat]
    /// 全屏页给的点角色通道；设置页预览和电视不给。
    let pokes: ImmersiveTheaterPokeChannel?
    let lyrics: (ImmersiveAlbumFlowGeometry.LyricFonts, CGFloat) -> Lyrics

    @State private var model = ImmersiveTheaterStageModel()
    @State private var pauseSettled = false

    /// 暂停后再动这么久就停住。
    private static var pauseWindow: Duration { .seconds(9) }

    var body: some View {
        let layout = ImmersiveTheaterSceneMetrics(metrics: metrics, platform: platform, insets: insets, hasLyrics: hasLyrics)
        let signals = model.signals
        let isLight = signals.isLightShot
        let running = motionAllowed && (isPlaying || !pauseSettled)
        ZStack(alignment: .topLeading) {
            ImmersiveTheaterStageLayer(
                model: model,
                inputs: stageInputs(layout: layout, running: running),
                revision: signals.revision
            )
            ImmersiveTheaterPaperOverlay()
            ImmersiveTheaterTitleBlock(
                title: title,
                subtitle: subtitle,
                metrics: layout,
                isLight: isLight,
                accent: palette.primary
            )
            .frame(width: layout.titleFrame.width, alignment: .leading)
            .position(x: layout.titleFrame.midX, y: layout.titleFrame.midY)
            .theaterRestingText(isResting)
            if hasLyrics {
                band(layout: layout, isLight: isLight)
                    .position(x: layout.bandFrame.midX, y: layout.bandFrame.midY)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
        .clipped()
        .animation(.easeInOut(duration: 0.6), value: isLight)
        .task(id: isPlaying) {
            pauseSettled = false
            guard !isPlaying else { return }
            try? await Task.sleep(for: Self.pauseWindow)
            if !Task.isCancelled { pauseSettled = true }
        }
    }

    private func stageInputs(layout: ImmersiveTheaterSceneMetrics, running: Bool) -> ImmersiveTheaterStageInputs {
        let size = metrics.size
        let world = ImmersiveTheaterWorld.fitting(size: size, floorY: layout.floorY, topY: layout.headroomY)
        let base: TimeInterval = platform == .tvOS ? 1.0 / 24 : 1.0 / 30
        let pixels = Double(size.width) * Double(max(displayScale, 1)) * 0.8
        return ImmersiveTheaterStageInputs(
            songKey: songKey,
            world: world,
            size: size,
            primary: ImmersiveTheaterRGB(palette.primary),
            secondary: ImmersiveTheaterRGB(palette.secondary),
            pixelWidth: Int(min(max(pixels, 640), 1700)),
            amplitude: motion.amplitude,
            // 暂停后那几秒（摘耳机、打呼）动作慢，按每秒十五帧画就够。
            interval: isPlaying ? frameRate.minimumInterval(base: base) : 1.0 / 15,
            running: running,
            isPlaying: isPlaying,
            elapsed: elapsed,
            duration: duration,
            playbackTime: playbackTime,
            levelsProvider: levelsProvider,
            lyricCue: lyricCue,
            hasLyrics: hasLyrics,
            firstLyricStart: firstLyricStart,
            pokes: pokes,
            acceptsPokes: !isResting
        )
    }

    /// 歌词带：舞台给的当前句（逐字照样扫光）和淡一些的下一句；后面垫一条歪歪的水彩。
    private func band(layout: ImmersiveTheaterSceneMetrics, isLight: Bool) -> some View {
        let padding = layout.bandPadding
        let width = layout.bandFrame.width
        let lyricWidth = max(width - padding.width * 2, 1)
        let washColor = isLight ? Color(red: 1, green: 0.98, blue: 0.925) : Color(red: 0.04, green: 0.047, blue: 0.10)
        return lyrics(layout.lyricFonts, lyricWidth)
            .colorMultiply(isLight ? ImmersiveWatercolorInk.ink : Color.white)
            .frame(width: lyricWidth, height: layout.lyricFonts.height)
            .padding(.horizontal, padding.width)
            .padding(.vertical, padding.height)
            .background {
                ImmersiveTheaterBandWash(
                    layers: model.bandLayers(for: songKey),
                    color: washColor,
                    opacity: isLight ? 0.55 : 0.45
                )
                .frame(width: width * 1.12, height: layout.bandFrame.height * 1.4)
                .theaterRestingText(isResting)
                .accessibilityHidden(true)
            }
    }
}

private extension View {
    /// 和舞台的 `immersiveRestingText` 一样：休憩时淡出可读文字，位置不动，VoiceOver 也不再读到它。
    func theaterRestingText(_ isResting: Bool) -> some View {
        opacity(isResting ? 0 : 1)
            .accessibilityHidden(isResting)
    }
}

// MARK: - 版式

/// 歌名在左上、歌词带在下面正中（控件上方）；角色的脚落在歌词带上面一点，头顶不顶到歌名。
struct ImmersiveTheaterSceneMetrics {
    let lyricFonts: ImmersiveAlbumFlowGeometry.LyricFonts
    let bandPadding: CGSize
    let bandFrame: CGRect
    let titleFrame: CGRect
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    /// 主唱的脚底在视口里的位置。
    let floorY: Double
    /// 头顶上面要留到哪。
    let headroomY: Double

    init(metrics: ImmersiveStageMetrics, platform: ImmersiveStagePlatform, insets: EdgeInsets, hasLyrics: Bool) {
        let size = metrics.size
        let isTV = platform == .tvOS
        let fonts: ImmersiveAlbumFlowGeometry.LyricFonts
        switch metrics.layout {
        case .phonePortrait:
            fonts = ImmersiveAlbumFlowGeometry.LyricFonts(
                current: max(metrics.s(19), 16), next: max(metrics.s(14), 12),
                currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(5)
            )
        case .phoneLandscape:
            fonts = ImmersiveAlbumFlowGeometry.LyricFonts(
                current: max(metrics.s(17), 15), next: max(metrics.s(13), 12),
                currentLineLimit: 1, showsNextLine: metrics.isHandheldLandscape, spacing: metrics.s(4)
            )
        case .wide:
            fonts = ImmersiveAlbumFlowGeometry.LyricFonts(
                current: max(metrics.s(isTV ? 40 : 32), 20), next: max(metrics.s(isTV ? 26 : 21), 14),
                currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(isTV ? 10 : 8)
            )
        }
        lyricFonts = fonts
        let padding = metrics.isWide
            ? CGSize(width: metrics.s(isTV ? 36 : 28), height: metrics.s(isTV ? 18 : 14))
            : CGSize(width: metrics.s(16), height: metrics.s(9))
        bandPadding = padding

        let left = insets.leading
        let right = size.width - insets.trailing
        let bottom = size.height - insets.bottom
        let innerWidth = max(right - left, 1)
        let bandWidth = min(innerWidth, metrics.isPortrait ? innerWidth : max(size.width * 0.62, min(innerWidth, metrics.s(520))))
        let bandHeight = fonts.height + padding.height * 2
        bandFrame = CGRect(
            x: (size.width - bandWidth) / 2,
            y: bottom - bandHeight,
            width: bandWidth,
            height: bandHeight
        )

        let title = max(metrics.s(metrics.isWide ? (isTV ? 40 : 30) : 20), metrics.isWide ? 22 : 17)
        titleSize = title
        subtitleSize = max(title * 0.5, metrics.isWide ? 14 : 12)
        let titleWidth = metrics.isPortrait ? innerWidth : min(innerWidth * 0.42, metrics.s(isTV ? 760 : 560))
        let titleHeight = title * 1.25 + subtitleSize * 1.4 + metrics.s(4)
        titleFrame = CGRect(x: left, y: insets.top, width: titleWidth, height: titleHeight)

        let floorLimit = hasLyrics ? bandFrame.minY - metrics.s(6) : bottom - metrics.s(10)
        floorY = Double(min(size.height * 0.88, floorLimit))
        // 竖屏歌名占满一行，头顶得在它下面；横屏歌名在左上角，主唱在中间，只要不出上沿。
        headroomY = Double(metrics.isPortrait ? titleFrame.maxY + metrics.s(12) : insets.top)
    }
}

// MARK: - 舞台层

struct ImmersiveTheaterStageInputs {
    let songKey: String
    let world: ImmersiveTheaterWorld
    let size: CGSize
    let primary: ImmersiveTheaterRGB
    let secondary: ImmersiveTheaterRGB
    let pixelWidth: Int
    let amplitude: Double
    let interval: TimeInterval?
    let running: Bool
    let isPlaying: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval
    let playbackTime: (@MainActor () -> TimeInterval)?
    let levelsProvider: @MainActor () -> [CGFloat]
    let lyricCue: ImmersiveTheaterLyricCue?
    let hasLyrics: Bool
    let firstLyricStart: TimeInterval?
    let pokes: ImmersiveTheaterPokeChannel?
    let acceptsPokes: Bool
}

/// 每帧推进宿主、交给 Canvas 画；没在动时停在最后一帧（设置页预览摆一个演唱的姿势）。
private struct ImmersiveTheaterStageLayer: View {
    let model: ImmersiveTheaterStageModel
    let inputs: ImmersiveTheaterStageInputs
    /// 背景或纸偶到了：停着的画面也要重画一次。
    let revision: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: inputs.interval, paused: !inputs.running)) { context in
            let frame = advance(to: context.date.timeIntervalSinceReferenceDate)
            Canvas { canvas, _ in
                ImmersiveTheaterRenderer.draw(frame, in: &canvas)
            }
        }
        .frame(width: inputs.size.width, height: inputs.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func advance(to now: TimeInterval) -> ImmersiveTheaterFrame {
        _ = revision
        model.configure(
            songKey: inputs.songKey,
            world: inputs.world,
            size: inputs.size,
            primary: inputs.primary,
            secondary: inputs.secondary,
            pixelWidth: inputs.pixelWidth,
            amplitude: inputs.amplitude
        )
        let provided: TimeInterval? = inputs.playbackTime.map { clock in clock() }
        let time = model.playbackTime(provided: provided, elapsed: inputs.elapsed, time: now, isPlaying: inputs.isPlaying)
        let levels: [CGFloat] = inputs.running && inputs.isPlaying ? inputs.levelsProvider() : []
        return model.frame(
            time: now,
            running: inputs.running,
            isPlaying: inputs.isPlaying,
            playbackTime: time,
            levels: levels,
            lyric: inputs.lyricCue,
            hasLyrics: inputs.hasLyrics,
            firstLyricStart: inputs.firstLyricStart,
            duration: inputs.duration,
            pokes: inputs.pokes,
            acceptsPokes: inputs.acceptsPokes
        )
    }
}

// MARK: - 纸与文字

/// 整幅画面上压一层纸纹和偏暖的暗角（正片叠底），角色和背景都像画在同一张纸上。
private struct ImmersiveTheaterPaperOverlay: View {
    var body: some View {
        ZStack {
            if let texture = ImmersiveWatercolorPaperTexture.image {
                texture
                    .resizable(resizingMode: .tile)
                    .blendMode(.multiply)
                    .opacity(0.85)
            }
            ImmersiveVignette(
                color: Color(red: 0.36, green: 0.27, blue: 0.19).opacity(0.5),
                center: .center,
                clearStop: 0.45,
                strength: 0.45
            )
            .blendMode(.multiply)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 左上角的歌名与歌手：夜里是米白字，花田里是墨色字，压一道封面色的错位阴影。
private struct ImmersiveTheaterTitleBlock: View {
    let title: String
    let subtitle: String
    let metrics: ImmersiveTheaterSceneMetrics
    let isLight: Bool
    let accent: Color

    var body: some View {
        let ink = isLight ? ImmersiveWatercolorInk.ink : Color(red: 0.97, green: 0.945, blue: 0.89)
        VStack(alignment: .leading, spacing: metrics.titleSize * 0.12) {
            Text(title)
                .font(.system(size: metrics.titleSize, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .shadow(color: accent.opacity(0.55), radius: 0, x: metrics.titleSize * 0.05, y: metrics.titleSize * 0.06)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: metrics.subtitleSize, weight: .semibold, design: .rounded))
                    .opacity(0.72)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(ink)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }
}

/// 歌词后面那条水彩：十层歪歪的长方形，每层很淡，叠出中间浓、边上晕开的一条。
private struct ImmersiveTheaterBandWash: View {
    let layers: [[CGPoint]]
    let color: Color
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            for (index, layer) in layers.enumerated() {
                let path = ImmersiveWatercolorGeometry.closedPolygon(layer, in: rect)
                context.fill(path, with: .color(color.opacity(opacity / 4)))
                if index % 3 == 0 {
                    context.stroke(path, with: .color(color.opacity(opacity / 3)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension ImmersiveTheaterStageModel {
    /// 这首歌的歌词带形状，按歌名定。
    func bandLayers(for songKey: String) -> [[CGPoint]] {
        if let cached = bandCache, cached.key == songKey { return cached.layers }
        var random = ImmersiveRandom(seed: ImmersiveRandom.seed(for: songKey) ^ 0xB4D0_7EA7_E2B4_ADD5)
        let layers = ImmersiveWatercolorGeometry.bandLayers(random: &random)
        bandCache = (songKey, layers)
        return layers
    }
}
