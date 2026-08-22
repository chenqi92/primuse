import CoreGraphics
import CoreText
import Foundation
import PrimuseKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// 八类沉浸场景共用的色彩、封面、控制与声音响应组件。
//
// iOS / macOS / tvOS 共用 Nocturne 色彩、颗粒、封面与基础控件；布局和控件
// 组合由每种效果单独决定。
// 本文件只依赖 SwiftUI / CoreText,不碰任何 app 模型,因此可以同时编进
// Primuse(iOS)、PrimuseMac 和 PrimuseTV 三个 target(见 project.yml)。

// MARK: - 调色板

/// Nocturne 语义色,取值对应设计稿 `_ds` 里的 CSS 变量。改这里等于改全端。
enum ImmersiveStagePalette {
    /// #f7f6fb — 标题与主要文字
    static let ink = Color(red: 0.969, green: 0.965, blue: 0.984)
    /// #e9e9ed — 次级文字基色,使用时再叠 opacity
    static let text = Color(red: 0.914, green: 0.914, blue: 0.929)
    /// #d2cefd — accent-200
    static let accent200 = Color(red: 0.824, green: 0.808, blue: 0.992)
    /// #b5abfc — accent-300,进度条与强调线
    static let accent300 = Color(red: 0.710, green: 0.671, blue: 0.988)
    /// #9184d9 — accent
    static let accent = Color(red: 0.569, green: 0.518, blue: 0.851)
    /// #7a67dd — accent-600
    static let accent600 = Color(red: 0.478, green: 0.404, blue: 0.867)
    /// #5b4fb0 — accent-700
    static let accent700 = Color(red: 0.357, green: 0.310, blue: 0.690)
    /// #c3b2f7
    static let lilac = Color(red: 0.765, green: 0.698, blue: 0.969)
    /// #8f7fe8
    static let violet = Color(red: 0.561, green: 0.498, blue: 0.910)
    /// #2c3aa0
    static let indigo = Color(red: 0.173, green: 0.227, blue: 0.627)
    /// #8149b0
    static let orchid = Color(red: 0.506, green: 0.286, blue: 0.690)
    /// #241f3d
    static let plum = Color(red: 0.141, green: 0.122, blue: 0.239)
    /// #161826 — Nocturne 主背景
    static let night = Color(red: 0.086, green: 0.094, blue: 0.149)
    /// 封面组使用略深一档，但保持同一蓝黑色相。
    static let obsidian = Color(red: 0.063, green: 0.071, blue: 0.118)
    /// 排印组使用略冷一档。
    static let slate = Color(red: 0.075, green: 0.082, blue: 0.133)
}

/// 当前封面提取出的双色场景主题。primary 用于高亮，secondary 用于深背景。
struct ImmersiveArtworkPalette {
    var primary: Color
    var secondary: Color

    static let fallback = ImmersiveArtworkPalette(
        primary: Color(red: 0.078, green: 0.490, blue: 0.541),
        secondary: Color(red: 0.043, green: 0.267, blue: 0.294)
    )
}

// MARK: - 版式尺度

/// 沉浸画面的三种视口。设计稿分别画到 393×852 / 852×393 / 1920×1080。
enum ImmersiveStageLayout {
    case phonePortrait
    case phoneLandscape
    /// macOS 全屏、tvOS,以及 iPad 这类大画布
    case wide
}

/// A–E 只共享语义，构图由平台决定。
enum ImmersiveStagePlatform {
    case iOS
    case macOS
    case tvOS
}

/// 把设计稿上的绝对像素换算成当前视口的实际点数。
///
/// 每个视口在设计稿里都有固定基准尺寸,按比例缩放即可保持构图关系;
/// 上下限用来防止超宽屏(比如 21:9 的外接显示器)把字号顶到荒谬的大小。
struct ImmersiveStageMetrics {
    let layout: ImmersiveStageLayout
    let size: CGSize
    let safeArea: EdgeInsets
    let scale: CGFloat

    init(size: CGSize, safeArea: EdgeInsets = EdgeInsets(), prefersWide: Bool = false) {
        self.size = size
        self.safeArea = safeArea

        let isLandscape = size.width > size.height
        // 大画布判定看短边:iPhone 横屏短边不到 500pt,iPad / Mac / TV 都远超。
        let shortSide = min(size.width, size.height)
        if prefersWide || shortSide >= 500 {
            layout = .wide
        } else {
            layout = isLandscape ? .phoneLandscape : .phonePortrait
        }

        switch layout {
        case .wide:
            // 1920×1080 基准。宽高同时约束,窗口变矮时字号跟着收,不会顶出画面。
            scale = min(max(min(size.width / 1920, size.height / 1080), 0.42), 1.35)
        case .phoneLandscape:
            scale = min(max(size.width / 852, 0.78), 1.25)
        case .phonePortrait:
            scale = min(max(size.width / 393, 0.82), 1.35)
        }
    }

    var isWide: Bool { layout == .wide }
    var isPortrait: Bool { layout == .phonePortrait }

    /// 设计稿像素 → 当前视口点数(取整,用于间距与字号)
    func s(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

    /// 同上但不取整,用于半径、线宽这类需要连续变化的量
    func f(_ value: CGFloat) -> CGFloat { value * scale }
}

// MARK: - 曲目上下文

/// 展示屏要显示的全部文字信息。三端各自从自己的播放模型组装成这一份值。
struct ImmersiveStageTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    /// "柳川 · 夜航 · Deluxe" —— 艺人与专辑合并成一行
    var subtitle: String
    /// "hi-res 96/24 flac" —— 已排好的规格串,展示时统一转大写并拉开字距
    var format: String
    var isPlaying: Bool
    /// 0...1
    var progress: Double
    var trackNumber: Int?
    var trackCount: Int?
    var elapsed: TimeInterval
    var duration: TimeInterval
    var source: String
    var nextTitle: String
    var queueSummary: String
    var genre: String
    var year: Int?

    var positionLabel: String {
        guard let trackNumber, trackNumber > 0 else { return "NOW PLAYING" }
        if let trackCount,
           trackCount > 0,
           trackCount <= 99,
           trackNumber <= trackCount {
            return String(format: "TRACK %02d / %02d", trackNumber, trackCount)
        }
        return String(format: "TRACK %02d", trackNumber)
    }

    init(
        title: String,
        artist: String,
        album: String,
        format: String,
        isPlaying: Bool,
        progress: Double,
        trackNumber: Int? = nil,
        trackCount: Int? = nil,
        elapsed: TimeInterval = 0,
        duration: TimeInterval = 0,
        source: String = "",
        nextTitle: String = "",
        queueSummary: String = "",
        genre: String = "",
        year: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.format = format
        self.isPlaying = isPlaying
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.source = source
        self.nextTitle = nextTitle
        self.queueSummary = queueSummary
        self.genre = genre
        self.year = year
        if album.isEmpty || album == "—" {
            subtitle = artist
        } else {
            subtitle = "\(artist) · \(album)"
        }
    }
}

/// 设置预览和无曲目状态使用固定品牌内容，避免把演示曲目误认为真实歌曲。
enum ImmersiveDemoContent {
    static let title = "猿音"
    static let artist = "Primuse"
    static let album = "Immersive Player"
    static let format = "HI-RES 96/24 FLAC"
    static let lyrics = [
        "音乐在此刻铺满整个空间",
        "Primuse turns every song into a scene",
        "让声音拥有自己的光与形状",
        "Every note finds its own light",
        "猿音，让聆听成为一场演出",
    ]

    static var track: ImmersiveStageTrack {
        ImmersiveStageTrack(
            title: title,
            artist: artist,
            album: album,
            format: format,
            isPlaying: true,
            progress: 0.43,
            trackNumber: 3,
            trackCount: 9,
            elapsed: 108,
            duration: 252,
            source: PMString("ext.tv.nav.library"),
            nextTitle: "Primuse",
            queueSummary: PMString("ext.tv.songsCount", 9),
            genre: "electronic",
            year: 2024
        )
    }
}

// MARK: - 设置页真实效果预览

/// 设置页与效果选择器共用的真实舞台缩略图。这里直接缩放正式的
/// `ImmersiveStageView`，避免设置页展示的示意图与最终全屏效果不一致。
/// 只有选中或聚焦的卡片才会运行动画；其余卡片停在真实静态帧。
struct ImmersiveEffectPreview: View {
    var effect: FullscreenPlayerEffect
    var isActive = false
    var palette: ImmersiveArtworkPalette = .fallback

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let canvasSize = CGSize(width: 960, height: 540)

    private var animates: Bool {
        isActive && !accessibilityReduceMotion
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / canvasSize.width,
                geometry.size.height / canvasSize.height
            )

            ZStack {
                previewContent
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .scaleEffect(scale)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(ImmersiveStagePalette.obsidian)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var previewContent: some View {
        if effect.isNative {
            ImmersiveNativeEffectPreview(
                isAnimating: animates,
                palette: palette
            )
        } else if effect.usesRealtimeSpectrum {
            TimelineView(.animation(minimumInterval: 1 / 12, paused: !animates)) { context in
                immersiveStage(
                    levels: animatedLevels(at: animates ? context.date.timeIntervalSinceReferenceDate : 0),
                    elapsed: previewElapsed(at: animates ? context.date.timeIntervalSinceReferenceDate : 0)
                )
            }
        } else {
            immersiveStage(levels: Self.baseLevels, elapsed: 108)
        }
    }

    private func immersiveStage(levels: [CGFloat], elapsed: TimeInterval) -> some View {
        var track = ImmersiveDemoContent.track
        track.isPlaying = animates
        track.elapsed = elapsed
        track.progress = track.duration > 0 ? elapsed / track.duration : 0

        return ImmersiveStageView(
            style: effect,
            platform: previewPlatform,
            metrics: ImmersiveStageMetrics(size: canvasSize, prefersWide: true),
            track: track,
            palette: palette,
            lyricWindow: previewLyrics,
            currentLyric: ImmersiveDemoContent.lyrics[1],
            nextLyric: ImmersiveDemoContent.lyrics[2],
            levels: levels,
            galleryArtworkCount: 8,
            galleryArtwork: { index, side in
                AnyView(
                    ImmersivePreviewArtwork(
                        variant: index + 1,
                        palette: palette
                    )
                    .frame(width: side, height: side)
                )
            },
            titleWallTitles: previewTitles,
            reduceMotion: !animates,
            lyricsMotionEnabled: animates,
            lyricInterlude: false,
            lyricsPlaceholder: ImmersiveDemoContent.lyrics[1],
            controlsInset: 0,
            showsClock: false
        ) { side in
            ImmersivePreviewArtwork(variant: 0, palette: palette)
                .frame(width: side, height: side)
        }
    }

    private var previewPlatform: ImmersiveStagePlatform {
        #if os(tvOS)
        .tvOS
        #elseif os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }

    private var previewLyrics: [ImmersiveStageLyric] {
        Array(ImmersiveDemoContent.lyrics.prefix(3)).enumerated().map { index, text in
            ImmersiveStageLyric(
                id: index,
                text: text,
                isActive: index == 1,
                offset: index - 1
            )
        }
    }

    private var previewTitles: [String] {
        [
            "猿音",
            "PRIMUSE",
            "猿音 · PRIMUSE",
            "PRIMUSE / 猿音",
        ]
    }

    private func previewElapsed(at time: TimeInterval) -> TimeInterval {
        guard animates else { return 108 }
        return 36 + time.truncatingRemainder(dividingBy: 176)
    }

    private func animatedLevels(at time: TimeInterval) -> [CGFloat] {
        guard animates else { return Self.baseLevels }
        return Self.baseLevels.enumerated().map { index, value in
            let primary = sin(time * 3.1 + Double(index) * 0.73)
            let secondary = sin(time * 1.7 - Double(index) * 0.41)
            let pulse = CGFloat(0.76 + primary * 0.17 + secondary * 0.07)
            return min(max(value * pulse + 0.035, 0), 1)
        }
    }

    private static let baseLevels: [CGFloat] = [
        0.18, 0.31, 0.46, 0.38, 0.62, 0.74, 0.54, 0.82,
        0.66, 0.43, 0.57, 0.91, 0.70, 0.48, 0.79, 0.60,
        0.36, 0.52, 0.68, 0.44, 0.73, 0.58, 0.39, 0.63,
        0.47, 0.34, 0.51, 0.41, 0.29, 0.38, 0.24, 0.17,
    ]
}

private struct ImmersiveNativeEffectPreview: View {
    var isAnimating: Bool
    var palette: ImmersiveArtworkPalette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !isAnimating)) { context in
            let progress = isAnimating
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 48) / 48
                : 0.43

            ZStack {
                LinearGradient(
                    colors: [
                        palette.secondary.opacity(0.96),
                        ImmersiveStagePalette.obsidian,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                HStack(spacing: 54) {
                    ImmersivePreviewArtwork(variant: 0, palette: palette)
                        .frame(width: 286, height: 286)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: palette.primary.opacity(0.32), radius: 34, y: 18)

                    VStack(alignment: .leading, spacing: 18) {
                        Text(ImmersiveDemoContent.title)
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(ImmersiveStagePalette.ink)
                            .lineLimit(1)
                        Text("\(ImmersiveDemoContent.artist) · \(ImmersiveDemoContent.album)")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(ImmersiveStagePalette.text.opacity(0.62))
                            .lineLimit(1)

                        ImmersiveHairlineProgress(
                            fraction: progress,
                            height: 5,
                            accent: palette.primary,
                            trackOpacity: 0.18
                        )
                        .frame(width: 420)

                        HStack(spacing: 34) {
                            Image(systemName: "backward.fill")
                            Image(systemName: "pause.fill")
                                .font(.system(size: 29, weight: .semibold))
                                .frame(width: 68, height: 68)
                                .background(.white.opacity(0.11), in: Circle())
                            Image(systemName: "forward.fill")
                        }
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(ImmersiveStagePalette.ink.opacity(0.92))
                    }
                }
                .padding(.horizontal, 66)
            }
            .overlay(alignment: .bottom) {
                ImmersiveHairlineProgress(
                    fraction: progress,
                    height: 3,
                    accent: palette.primary
                )
            }
        }
    }
}

private struct ImmersivePreviewArtwork: View {
    var variant: Int
    var palette: ImmersiveArtworkPalette

    private var accent: Color {
        variant.isMultiple(of: 2) ? palette.primary : palette.secondary
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [accent.opacity(0.92), palette.secondary, ImmersiveStagePalette.obsidian],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            applicationIcon
                .scaledToFill()
                .scaleEffect(variant == 0 ? 1 : 1.025)
                .overlay {
                    LinearGradient(
                        colors: [
                            .clear,
                            accent.opacity(variant == 0 ? 0.02 : 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 2)
                .padding(20)
        }
        .clipped()
    }

    @ViewBuilder
    private var applicationIcon: some View {
        #if os(tvOS)
        Image("BrandMark")
            .resizable()
        #else
        Image("AppIconPreview")
            .resizable()
        #endif
    }
}

struct ImmersiveArtworkFallback: View {
    var palette: ImmersiveArtworkPalette = .fallback

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.primary.opacity(0.72), palette.secondary.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .symbolRenderingMode(.hierarchical)
        }
    }
}

// MARK: - 胶片颗粒

/// 满幅胶片颗粒。设计稿用 feTurbulence 噪声图平铺 + overlay 混合,这里换成
/// 一次性生成的 128×128 灰度噪点位图平铺,观感一致而运行时开销为零。
struct ImmersiveGrain: View {
    var opacity: Double = 0.07

    var body: some View {
        if let texture = ImmersiveGrainTexture.image {
            texture
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.overlay)
                .allowsHitTesting(false)
        }
    }
}

private enum ImmersiveGrainTexture {
    static let image: Image? = make()

    private static func make() -> Image? {
        let side = 128
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)

        // 固定种子的线性同余:每次启动噪点分布一致,否则前后两次进入沉浸播放
        // 颗粒会整体跳一下。
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = UInt8(truncatingIfNeeded: state >> 33)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }

        return Image(decorative: cgImage, scale: 1)
    }
}

// MARK: - 暗角

/// 满幅暗角。半径取对角线的 0.62 倍,画面四角正好落在最深的一档,
/// 边缘中点则更浅——这与设计稿椭圆渐变的观感一致,且不需要各向异性缩放。
struct ImmersiveVignette: View {
    var color: Color
    var center: UnitPoint = UnitPoint(x: 0.5, y: 0.46)
    /// 中心多大比例内完全透明
    var clearStop: Double = 0.34
    var strength: Double = 0.72

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = max(geometry.size.height, 1)
            let diagonal = (width * width + height * height).squareRoot()

            RadialGradient(
                stops: [
                    .init(color: color.opacity(0), location: clearStop),
                    .init(color: color.opacity(strength), location: 0.84),
                    .init(color: color, location: 1),
                ],
                center: center,
                startRadius: 0,
                endRadius: diagonal * 0.62
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 右上角时钟

/// 展示屏右上角的时钟。大屏带星期与日期,手机横屏待机只留时间。
struct ImmersiveStageClock: View {
    var showsDate: Bool
    var timeSize: CGFloat
    var dateSize: CGFloat
    var tint: Color = ImmersiveStagePalette.text

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .trailing, spacing: dateSize * 0.35) {
                Text(context.date.formatted(.dateTime.hour().minute()))
                    .font(.system(size: timeSize, weight: .regular))
                    .monospacedDigit()
                    .tracking(-timeSize * 0.02)
                    .foregroundStyle(tint.opacity(0.90))

                if showsDate {
                    Text(dateLine(for: context.date))
                        .font(.system(size: dateSize, weight: .regular))
                        .tracking(dateSize * 0.14)
                        .textCase(.uppercase)
                        .foregroundStyle(tint.opacity(0.42))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func dateLine(for date: Date) -> String {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let day = date.formatted(.dateTime.month().day())
        return "\(weekday) · \(day)"
    }
}

// MARK: - 底边发丝进度条

/// 贴着屏幕最下缘的一条发丝进度。五种风格共用同一根,且不参与控件的空闲
/// 淡出——画面再安静也能一眼看出播到哪儿。
struct ImmersiveHairlineProgress: View {
    var fraction: Double
    var height: CGFloat
    var accent: Color = ImmersiveStagePalette.accent300
    var trackOpacity: Double = 0.12

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(ImmersiveStagePalette.text.opacity(trackOpacity))
                Rectangle()
                    .fill(accent)
                    .frame(width: geometry.size.width * clamped)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.4), value: clamped)
    }

    private var clamped: Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }
}

// MARK: - 玻璃药丸

/// 浮在画面上的控件底座:深色半透明 + 背景模糊 + 上缘 1px 高光。
/// 只负责容器,按钮由各端自己塞进来(tvOS 要可聚焦按钮,iOS/macOS 是点按)。
struct ImmersiveGlassPill<Content: View>: View {
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    /// 液态铬用亮色玻璃,其余风格用深色玻璃
    var isLight: Bool = false
    /// tvOS 焦点层需要越过胶囊边界，避免放大、上抬后的描边被裁切。
    var clipsContent: Bool = true
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if clipsContent {
            surface.clipShape(Capsule(style: .continuous))
        } else {
            surface
        }
    }

    private var surface: some View {
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                    Capsule(style: .continuous)
                        .fill(
                            isLight
                                ? Color.white.opacity(0.14)
                                : Color(red: 0.071, green: 0.075, blue: 0.122).opacity(0.42)
                        )
                }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(isLight ? 0.34 : 0.20),
                                .white.opacity(0.04),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
    }
}

/// 同一层级的圆形玻璃动作外观。Button 与 Menu 共用这一个 label，避免全屏
/// 顶栏的退出、效果、喜欢和更多按钮出现有的带底、有的不带底。
struct ImmersiveGlassActionLabel: View {
    var symbol: String
    var tint: Color = ImmersiveStagePalette.ink
    var diameter: CGFloat = 44
    var isSelected = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.34, weight: .semibold))
            .foregroundStyle(isSelected ? tint : tint.opacity(0.88))
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                Circle()
                    .fill(isSelected ? tint.opacity(0.18) : .black.opacity(0.16))
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        isSelected ? tint.opacity(0.62) : .white.opacity(0.20),
                        lineWidth: isSelected ? 1.1 : 0.8
                    )
            }
            .contentShape(Circle())
    }
}

/// 同一层级的圆形动作按钮。只有设计指定为浮动玻璃动作时才使用，模式内的
/// 传输控件由各场景按自身构图决定布局。
struct ImmersiveGlassActionButton: View {
    var symbol: String
    var label: LocalizedStringKey
    var tint: Color = ImmersiveStagePalette.ink
    var diameter: CGFloat = 44
    var isSelected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ImmersiveGlassActionLabel(
                symbol: symbol,
                tint: tint,
                diameter: diameter,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// 全屏内的效果选择面板。显式面板替代层层嵌套的系统 Menu：宿主可以准确知道
/// 面板是否仍在展示，并在此期间暂停浮动控件的自动隐藏计时。
struct ImmersiveEffectPickerPanel: View {
    var selected: FullscreenPlayerEffect
    var palette: ImmersiveArtworkPalette = .fallback
    var panelWidth: CGFloat = 340
    var panelHeight: CGFloat = 500
    var onSelect: (FullscreenPlayerEffect) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(FullscreenEffectCollection.allCases) { collection in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(collection.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(collection.effects) { candidate in
                            Button {
                                onSelect(candidate)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: candidate.symbolName)
                                        .font(.system(size: 17, weight: .semibold))
                                        .frame(width: 24, height: 24)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.localizedTitle)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text(candidate.motionDescription)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer(minLength: 8)

                                    if candidate == selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(palette.primary)
                                    }
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    candidate == selected
                                        ? palette.primary.opacity(0.15)
                                        : Color.primary.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            candidate == selected
                                                ? palette.primary.opacity(0.48)
                                                : Color.primary.opacity(0.08),
                                            lineWidth: 0.8
                                        )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: panelWidth, height: panelHeight)
        .accessibilityElement(children: .contain)
    }
}

/// 播放器内部承载效果列表的深色表面，避免 macOS NSPopover 自带的浅色外壳。
struct ImmersiveEffectPickerSurface: View {
    var selected: FullscreenPlayerEffect
    var palette: ImmersiveArtworkPalette = .fallback
    var panelWidth: CGFloat = 420
    var panelHeight: CGFloat = 560
    var onSelect: (FullscreenPlayerEffect) -> Void

    var body: some View {
        ImmersiveEffectPickerPanel(
            selected: selected,
            palette: palette,
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            onSelect: onSelect
        )
            .background {
                ZStack {
                    ImmersiveStagePalette.obsidian
                    LinearGradient(
                        colors: [
                            palette.secondary.opacity(0.72),
                            palette.primary.opacity(0.24),
                            ImmersiveStagePalette.obsidian.opacity(0.96),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(ImmersiveStagePalette.ink.opacity(0.18), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.46), radius: 28, y: 14)
            .environment(\.colorScheme, .dark)
    }
}

/// Typography 的背景不再完全静止: 极慢的色相旋转和扫描线为长时间播放
/// 提供持续但不抢歌词注意力的运动。Reduce Motion 时 TimelineView 会暂停。
struct ImmersiveTypographyMotion: View {
    var isAnimating: Bool
    var palette: ImmersiveArtworkPalette = .fallback

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 8, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geometry in
                ZStack {
                    AngularGradient(
                        colors: [
                            palette.secondary.opacity(0.30),
                            palette.primary.opacity(0.10),
                            .clear,
                            palette.primary.opacity(0.18),
                            palette.secondary.opacity(0.30),
                        ],
                        center: .center
                    )
                    .rotationEffect(.degrees(time / 90 * 360))
                    .scaleEffect(1.18)

                    ForEach(0..<3, id: \.self) { index in
                        Rectangle()
                            .fill(ImmersiveStagePalette.text.opacity(0.055))
                            .frame(height: 1)
                            .offset(y: scanOffset(time: time, index: index, height: geometry.size.height))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }

    private func scanOffset(time: TimeInterval, index: Int, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        let phase = time / 26 + Double(index) / 3
        return CGFloat((phase.truncatingRemainder(dividingBy: 1) * 2 - 0.5)) * height
    }
}

// MARK: - 跳动的均衡器小条

/// 规格串前面那一小簇跳动竖条。对应设计稿 CSS 的 `omEq` 关键帧
/// (scaleY .28 → 1,相邻条错开 0.22s)。
struct ImmersiveEqualizerTicks: View {
    var isAnimating: Bool
    var color: Color
    var barWidth: CGFloat
    var barHeight: CGFloat
    var spacing: CGFloat
    var count: Int = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: barHeight)
                        .scaleEffect(y: level(at: index, time: time), anchor: .bottom)
                }
            }
            .frame(height: barHeight, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    private func level(at index: Int, time: TimeInterval) -> CGFloat {
        guard isAnimating else { return 0.55 }
        let phase = (time / 0.9 + Double(index) * 0.244) * .pi
        return CGFloat(0.28 + (sin(phase) + 1) / 2 * 0.72)
    }
}

/// 规格徽标:跳动小条 + 大写、拉开字距的格式串。
struct ImmersiveFormatBadge: View {
    var text: String
    var isAnimating: Bool
    var fontSize: CGFloat
    var tint: Color = ImmersiveStagePalette.accent200

    var body: some View {
        HStack(spacing: fontSize * 0.78) {
            ImmersiveEqualizerTicks(
                isAnimating: isAnimating,
                color: tint,
                barWidth: max(1.5, fontSize * 0.17),
                barHeight: fontSize * 0.9,
                spacing: max(1.5, fontSize * 0.17)
            )

            Text(text)
                .font(.system(size: fontSize, weight: .regular))
                .tracking(fontSize * 0.18)
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
    }
}

// MARK: - 光雾 Aurora Drift

/// 三层光雾以不同速度漂移(26s / 34s / 19s)。
///
/// 设计稿写的是 `radial-gradient` + `blur(96px)`;这里改成落点更软的多档
/// RadialGradient 直接出图,省掉整屏实时高斯模糊——Apple TV 的 GPU 扛不住
/// 1080p 每帧一次 96pt 模糊,而两者观感几乎没有差别。
struct ImmersiveAuroraBackdrop: View {
    var isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0

            GeometryReader { geometry in
                let side = max(geometry.size.width, geometry.size.height)
                ZStack {
                    ImmersiveStagePalette.night

                    softGlow(ImmersiveStagePalette.violet, radius: side * 0.52, opacity: 0.92)
                        .frame(width: side * 1.5, height: side * 1.5)
                        .position(
                            x: geometry.size.width * 0.30 + drift(time, period: 26, amplitude: side * 0.06),
                            y: geometry.size.height * 0.34 + drift(time, period: 31, amplitude: side * 0.04)
                        )

                    softGlow(ImmersiveStagePalette.indigo, radius: side * 0.48, opacity: 0.88)
                        .frame(width: side * 1.4, height: side * 1.4)
                        .position(
                            x: geometry.size.width * 0.70 - drift(time, period: 34, amplitude: side * 0.07),
                            y: geometry.size.height * 0.62 - drift(time, period: 29, amplitude: side * 0.05)
                        )

                    softGlow(ImmersiveStagePalette.lilac, radius: side * 0.33, opacity: 0.55)
                        .frame(width: side, height: side)
                        .position(
                            x: geometry.size.width * 0.58 + drift(time, period: 19, amplitude: side * 0.05),
                            y: geometry.size.height * 0.24 + drift(time, period: 23, amplitude: side * 0.04)
                        )
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private func drift(_ time: TimeInterval, period: Double, amplitude: CGFloat) -> CGFloat {
        guard isAnimating else { return 0 }
        return CGFloat(sin(time / period * 2 * .pi)) * amplitude
    }

    private func softGlow(_ color: Color, radius: CGFloat, opacity: Double) -> some View {
        RadialGradient(
            stops: [
                .init(color: color.opacity(opacity), location: 0),
                .init(color: color.opacity(opacity * 0.52), location: 0.30),
                .init(color: color.opacity(opacity * 0.16), location: 0.58),
                .init(color: color.opacity(0), location: 1),
            ],
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

// MARK: - 液态铬 Liquid Chrome

/// 两层锥形渐变反向自转(90s / 60s)并重度虚化,形成缓慢流动的虹彩金属。
struct ImmersiveLiquidChromeBackdrop: View {
    var isAnimating: Bool
    /// 模糊半径。整屏只此一处模糊,tvOS 传更小的值以降低填充率压力。
    var blurRadius: CGFloat = 90

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0

            GeometryReader { geometry in
                // 渐变层远大于视口,模糊在边缘取样到的仍是渐变本身,不会透出空白。
                let side = max(geometry.size.width, geometry.size.height) * 1.9
                ZStack {
                    ImmersiveStagePalette.obsidian

                    ZStack {
                        AngularGradient(
                            colors: [
                                ImmersiveStagePalette.lilac,
                                ImmersiveStagePalette.indigo,
                                ImmersiveStagePalette.orchid,
                                ImmersiveStagePalette.accent600,
                                ImmersiveStagePalette.accent700,
                                ImmersiveStagePalette.lilac,
                            ],
                            center: .center
                        )
                        .frame(width: side, height: side)
                        .rotationEffect(.degrees(angle(time, period: 90)))
                        .saturation(1.25)
                        .opacity(0.9)

                        AngularGradient(
                            stops: [
                                .init(color: ImmersiveStagePalette.lilac.opacity(0.7), location: 0),
                                .init(color: ImmersiveStagePalette.plum.opacity(0.2), location: 0.30),
                                .init(color: ImmersiveStagePalette.orchid.opacity(0.6), location: 0.58),
                                .init(color: ImmersiveStagePalette.plum.opacity(0.2), location: 0.78),
                                .init(color: ImmersiveStagePalette.lilac.opacity(0.7), location: 1),
                            ],
                            center: .center,
                            angle: .degrees(180)
                        )
                        .frame(width: side * 0.8, height: side * 0.8)
                        .rotationEffect(.degrees(-angle(time, period: 60)))
                        .opacity(0.5)
                    }
                    .blur(radius: blurRadius)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private func angle(_ time: TimeInterval, period: Double) -> Double {
        guard isAnimating else { return 0 }
        return time.truncatingRemainder(dividingBy: period) / period * 360
    }
}

// MARK: - 环形频谱 Radial Spectrum

/// 一圈频谱柱绕着圆形封面,整环缓慢自转,柱体向内渐隐。
///
/// 72 根柱子合成一条 Path 一次填充,渐变用以环心为中心的 RadialGradient——
/// 柱子本来就沿半径方向排布,所以一个径向渐变等价于给每根柱子各画一遍纵向渐变。
struct ImmersiveSpectrumRing: View {
    /// 0...1 的真实频段强度。少于 barCount 时镜像插值；为空时保持静止基线。
    var levels: [CGFloat]
    var barCount: Int = 72
    /// 环内侧留给封面的半径占比
    var innerRatio: CGFloat = 0.60
    var barWidth: CGFloat
    var isAnimating: Bool
    var tint: Color = ImmersiveStagePalette.accent200
    /// 播放状态只控制真实数据到来后的整体旋转，不生成替代波形。
    var isPlaying: Bool = true
    /// 整环自转周期(秒)
    var spinPeriod: Double = 120

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let hasSignal = levels.contains { $0 > 0.002 }
            let spin = isAnimating && hasSignal
                ? time.truncatingRemainder(dividingBy: spinPeriod) / spinPeriod * 360
                : 0

            Canvas(rendersAsynchronously: true) { canvas, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2
                let inner = outer * innerRatio
                let span = outer - inner
                guard span > 1, barCount > 0 else { return }

                var path = Path()
                for index in 0..<barCount {
                    let level = levels.isEmpty
                        ? 0
                        : mirroredLevel(at: index, outputCount: barCount, source: levels)
                    let length = span * (0.08 + level * 0.92)
                    let bar = Path(
                        roundedRect: CGRect(
                            x: -barWidth / 2,
                            y: -outer,
                            width: barWidth,
                            height: length
                        ),
                        cornerRadius: barWidth / 2
                    )
                    let radians = Double(index) / Double(barCount) * 2 * .pi
                    path.addPath(
                        bar,
                        transform: CGAffineTransform(rotationAngle: radians)
                            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
                    )
                }

                canvas.fill(
                    path,
                    with: .radialGradient(
                        Gradient(colors: [
                            tint.opacity(0.14),
                            tint.opacity(0.98),
                        ]),
                        center: center,
                        startRadius: inner,
                        endRadius: outer
                    )
                )
            }
            .rotationEffect(.degrees(spin))
        }
        .allowsHitTesting(false)
    }

    /// 频谱从顶部沿左右两侧低频→高频镜像展开。直接把低到高频绕一整圈会
    /// 让低频全部堆在单侧，看起来像一半在跳、另一半没有声音。
    private func mirroredLevel(at index: Int, outputCount: Int, source: [CGFloat]) -> CGFloat {
        guard !source.isEmpty, outputCount > 0 else { return 0 }
        guard source.count > 1 else { return min(max(source[0], 0), 1) }
        let phase = Double(index) / Double(outputCount)
        let folded = phase <= 0.5 ? phase * 2 : (1 - phase) * 2
        let position = folded * Double(source.count - 1)
        let lower = min(Int(floor(position)), source.count - 1)
        let upper = min(lower + 1, source.count - 1)
        let fraction = CGFloat(position - floor(position))
        let value = source[lower] + (source[upper] - source[lower]) * fraction
        return min(max(value, 0), 1)
    }
}

// MARK: - 字墙 Type Wall

/// 曲名以空心字堆成一面墙,唯一实心的一行就是当前曲目。
///
/// SwiftUI 没有描边文字,所以走 CoreText 取字形轮廓再 stroke。轮廓按
/// (曲名, 字号) 缓存,重绘不会重复解析字形。
struct ImmersiveTypeWall: View {
    var title: String
    var fontSize: CGFloat
    /// 墙的行数，由场景按当前画布高度决定。
    var rowCount: Int
    /// 实心那一行在墙里的下标
    var solidRow: Int
    var lineWidth: CGFloat = 1
    var tint: Color = ImmersiveStagePalette.accent200
    var outlineOpacity: Double?
    var fillsSolidRow = false

    @State private var glyphs: ImmersiveGlyphLine?

    private static let rowOffsetRatios: [CGFloat] = [0, -0.72, 0, -0.36, 0]
    private static let rowOpacities: [Double] = [0.16, 0.22, 0.50, 0.20, 0.12]

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: fontSize * -0.06) {
                ForEach(Array(0..<max(rowCount, 1)), id: \.self) { index in
                    wallRow(at: index, available: geometry.size.width)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
            .clipped()
        }
        .task(id: cacheKey) {
            glyphs = ImmersiveGlyphLine.make(text: title, fontSize: fontSize)
        }
        .allowsHitTesting(false)
    }

    private var cacheKey: String { "\(title)#\(Int(fontSize))" }

    @ViewBuilder
    private func wallRow(at index: Int, available: CGFloat) -> some View {
        let isSolid = index == solidRow
        // 相邻行左右错开,免得整面墙对得太齐显得死板(设计稿是 -120 / -60px)。
        let offset = Self.rowOffsetRatios[index % Self.rowOffsetRatios.count] * fontSize
        let opacity = outlineOpacity ?? Self.rowOpacities[index % Self.rowOpacities.count]

        if let glyphs, glyphs.advance > 1 {
            let repeats = max(1, Int((available / glyphs.advance).rounded(.up)) + 1)
            ImmersiveGlyphRow(
                line: glyphs,
                repeats: repeats,
                isSolid: isSolid,
                fillsSolidRow: fillsSolidRow,
                lineWidth: lineWidth,
                strokeOpacity: opacity,
                tint: tint
            )
            .frame(height: glyphs.size.height * 0.94, alignment: .leading)
            .offset(x: offset)
        } else {
            // 字形还没算好(或取轮廓失败)时先用低透明度实心字占位,不留空白。
            Text(String(repeating: title + "  ", count: 3))
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle((isSolid ? ImmersiveStagePalette.ink : tint).opacity(isSolid ? 1 : opacity))
                .frame(height: fontSize * 0.94, alignment: .leading)
                .offset(x: offset)
        }
    }
}

/// 一行字形轮廓 + 它的排版尺寸。
struct ImmersiveGlyphLine: Equatable {
    let path: Path
    let size: CGSize
    /// 一次重复的步进(行宽 + 词间距)
    let advance: CGFloat

    static func == (lhs: ImmersiveGlyphLine, rhs: ImmersiveGlyphLine) -> Bool {
        lhs.size == rhs.size && lhs.advance == rhs.advance
    }

    /// 用 CoreText 把字符串转成 SwiftUI 坐标系(y 向下、原点在行框左上)的轮廓。
    @MainActor
    static func make(text: String, fontSize: CGFloat) -> ImmersiveGlyphLine? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, fontSize > 1 else { return nil }

        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        #elseif canImport(AppKit)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        #else
        return nil
        #endif

        let attributed = NSAttributedString(string: trimmed, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        guard width > 1, let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] else { return nil }

        let combined = CGMutablePath()
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // CoreText 会给缺字的段落换字体(中文 / emoji),所以每个 run 要用它自己的字体。
            guard let value = attributes[kCTFontAttributeName as String],
                  CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { continue }
            let runFont = value as! CTFont

            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)

            for index in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                let transform = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                combined.addPath(glyphPath, transform: transform)
            }
        }

        guard !combined.isEmpty else { return nil }

        // CoreText 的 y 轴向上、原点在基线;翻成 SwiftUI 的 y 向下、原点在行框顶部。
        var flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ascent)
        let flipped = combined.copy(using: &flip) ?? combined

        return ImmersiveGlyphLine(
            path: Path(flipped),
            size: CGSize(width: width, height: ascent + descent),
            advance: width + fontSize * 0.34
        )
    }
}

/// 把一行轮廓横向重复铺满；实心行可只填首个副本，也可填满整行。
private struct ImmersiveGlyphRow: View {
    let line: ImmersiveGlyphLine
    let repeats: Int
    let isSolid: Bool
    let fillsSolidRow: Bool
    let lineWidth: CGFloat
    let strokeOpacity: Double
    let tint: Color

    var body: some View {
        Canvas { canvas, _ in
            for index in 0..<repeats {
                let shifted = line.path.applying(
                    CGAffineTransform(translationX: CGFloat(index) * line.advance, y: 0)
                )
                if isSolid, fillsSolidRow || index == 0 {
                    canvas.fill(shifted, with: .color(ImmersiveStagePalette.ink))
                } else {
                    canvas.stroke(
                        shifted,
                        with: .color(
                            isSolid
                                ? tint.opacity(0.56)
                                : tint.opacity(strokeOpacity)
                        ),
                        lineWidth: lineWidth
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 封面氛围底

/// 把封面放大虚化铺满整屏并缓慢漂移——歌词台用它当底。
/// 封面视图由调用方注入,三端的封面组件不同(CachedArtworkView / TVArtworkView)。
struct ImmersiveArtworkAtmosphere<Artwork: View>: View {
    var isAnimating: Bool
    var blur: CGFloat
    var opacity: Double
    var saturation: Double = 1.35
    @ViewBuilder var artwork: (CGFloat) -> Artwork

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0

            GeometryReader { geometry in
                let side = max(geometry.size.width, geometry.size.height)
                artwork(side)
                    .frame(width: side, height: side)
                    .scaleEffect(1.42 + CGFloat(sin(time / 30 * 2 * .pi)) * 0.05)
                    .offset(
                        x: CGFloat(sin(time / 26 * 2 * .pi)) * side * 0.04,
                        y: CGFloat(cos(time / 34 * 2 * .pi)) * side * 0.03
                    )
                    .blur(radius: blur)
                    .saturation(saturation)
                    .opacity(opacity)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 封面卡片

/// 展示屏中央那块封面:玻璃描边 + 彩色投影 + 斜向镜面高光。
/// `chrome` 打开时换成液态铬那一版更亮的描边与更强的高光。
struct ImmersiveArtworkPlate<Artwork: View>: View {
    var side: CGFloat
    var cornerRadius: CGFloat
    var chrome: Bool = false
    var glowColor: Color = ImmersiveStagePalette.accent700
    @ViewBuilder var artwork: (CGFloat) -> Artwork

    var body: some View {
        artwork(side)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(chrome ? 0.34 : 0.17), location: 0),
                                .init(color: .white.opacity(chrome ? 0.06 : 0.03), location: 0.16),
                                .init(color: .white.opacity(0), location: 0.34),
                                .init(color: .white.opacity(0), location: 0.68),
                                .init(color: .white.opacity(chrome ? 0.12 : 0), location: 1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(chrome ? 0.30 : 0.13), lineWidth: 1)
            }
            .shadow(
                color: chrome ? .black.opacity(0.80) : glowColor.opacity(0.85),
                radius: side * 0.16,
                y: side * 0.10
            )
    }
}

/// 封面下方那一片倒影:同色渐变 + 竖向渐隐遮罩。
struct ImmersiveArtworkReflection: View {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat
    var tint: Color = ImmersiveStagePalette.lilac

    var body: some View {
        LinearGradient(
            colors: [tint.opacity(0.5), ImmersiveStagePalette.plum.opacity(0.3), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: width, height: height)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
        .opacity(0.26)
        .blur(radius: 5)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.8), location: 0),
                    .init(color: .clear, location: 0.8),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 星场 Star Field

/// 三层确定性星点分别以 32 / 46 / 62 秒漂移；没有随机状态，也不会在重绘时闪烁。
struct ImmersiveStarFieldBackdrop: View {
    var isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ImmersiveStagePalette.obsidian))
                for layer in 0..<3 {
                    let count = [150, 92, 48][layer]
                    let period = [46.0, 32.0, 62.0][layer]
                    let radius = [0.7, 1.1, 1.7][layer]
                    let opacity = [0.28, 0.44, 0.66][layer]
                    let phase = time / period
                    for index in 0..<count {
                        let seed = Double(index + layer * 317)
                        let x = wrapped(fract(sin(seed * 12.9898) * 43_758.5453) + phase * (layer.isMultiple(of: 2) ? 0.016 : -0.012))
                        let y = wrapped(fract(sin(seed * 78.233) * 12_345.6789) + phase * (layer == 1 ? 0.010 : -0.008))
                        let rect = CGRect(
                            x: x * size.width,
                            y: y * size.height,
                            width: radius * 2,
                            height: radius * 2
                        )
                        canvas.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func fract(_ value: Double) -> Double { value - floor(value) }
    private func wrapped(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 1)
        return result < 0 ? result + 1 : result
    }
}

// MARK: - 声纹地形 Contour

/// 两组椭圆轮廓以 44 / 66 秒反向旋转，并用 12 秒周期轻微呼吸。
struct ImmersiveContourBackdrop: View {
    var isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { geometry in
                let pulse = isAnimating ? 1 + CGFloat(sin(time / 12 * 2 * .pi)) * 0.035 : 1
                ZStack {
                    contourSet(size: geometry.size, rotation: angle(time, 44), opacity: 0.33)
                    contourSet(size: geometry.size, rotation: -angle(time, 66), opacity: 0.17)
                        .scaleEffect(1.08)
                }
                .scaleEffect(pulse)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .allowsHitTesting(false)
    }

    private func contourSet(size: CGSize, rotation: Double, opacity: Double) -> some View {
        Canvas(rendersAsynchronously: true) { canvas, canvasSize in
            let center = CGPoint(x: canvasSize.width * 0.66, y: canvasSize.height * 0.56)
            let maxRadius = max(canvasSize.width, canvasSize.height) * 0.82
            for index in 0..<30 {
                let ratio = CGFloat(index + 1) / 30
                let width = maxRadius * ratio * 2
                let height = width * (0.48 + CGFloat(index % 5) * 0.018)
                var path = Path(ellipseIn: CGRect(
                    x: center.x - width / 2,
                    y: center.y - height / 2,
                    width: width,
                    height: height
                ))
                path = path.applying(CGAffineTransform(translationX: CGFloat(index % 4) * 4, y: CGFloat(index % 3) * -3))
                canvas.stroke(
                    path,
                    with: .color(ImmersiveStagePalette.accent300.opacity(opacity * (0.46 + Double(ratio) * 0.54))),
                    lineWidth: max(0.6, 1.25 - ratio * 0.45)
                )
            }
        }
        .rotationEffect(.degrees(rotation))
    }

    private func angle(_ time: TimeInterval, _ period: Double) -> Double {
        guard isAnimating else { return 0 }
        return time.truncatingRemainder(dividingBy: period) / period * 360
    }
}

// MARK: - 规格串

/// 把「格式 + 采样率 + 位深」拼成展示屏用的规格串,例如 "hi-res 96/24 flac"。
/// 采样率 ≥ 88.2kHz 或位深 ≥ 24 视为 Hi-Res,前面冠 "hi-res"。
enum ImmersiveAudioSpec {
    static func line(format: String, sampleRate: Int?, bitDepth: Int?) -> String {
        var parts: [String] = []

        if let sampleRate, sampleRate > 0 {
            let khz = Double(sampleRate) / 1000
            let khzText = khz.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(khz))
                : String(format: "%.1f", khz)
            if let bitDepth, bitDepth > 0 {
                parts.append("\(khzText)/\(bitDepth)")
            } else {
                parts.append("\(khzText)kHz")
            }
        }

        let trimmedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFormat.isEmpty, trimmedFormat != "—" {
            parts.append(trimmedFormat.lowercased())
        }

        let isHiRes = (sampleRate ?? 0) >= 88_200 || (bitDepth ?? 0) >= 24
        if isHiRes {
            parts.insert("hi-res", at: 0)
        }

        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }
}
