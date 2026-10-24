import PrimuseKit
import SwiftUI

/// 全屏效果「动态歌词」的一句（每个字此刻的样子见 `ImmersiveKineticLyricsPolicy`）。
///
/// 整句仍是一个 `Text`：换行、行数上限、放不下时缩小字号、从右往左的文字都交给系统排版；只在绘制时
/// 按字（每个字带一个 `ImmersiveKineticTokenIndex`）各自位移、缩放、虚化、发光。`TextRenderer` 要
/// iOS 18 / macOS 15 / tvOS 18，前两个就是最低系统；tvOS 17 由调用方退回普通的当前句。
@available(tvOS 18.0, *)
struct ImmersiveKineticLyricText: View {
    let tokens: [ImmersiveKineticLyricsPolicy.Token]
    let appearances: [ImmersiveKineticLyricsPolicy.Appearance]
    let fontSize: CGFloat
    let lineLimit: Int
    let glowColor: Color
    /// 字与字之间插什么：竖排时是换行，一个字一行。
    var separator = ""

    @Environment(\.lyricsTypeface) private var lyricsTypeface

    var body: some View {
        indexedText
            .font(lyricsTypeface.font(size: fontSize, weight: .bold))
            .foregroundStyle(ImmersiveStagePalette.ink)
            .multilineTextAlignment(.center)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.6)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(ImmersiveKineticLyricRenderer(
                appearances: appearances,
                fontSize: fontSize,
                glowColor: glowColor
            ))
    }

    /// 逐字拼回整句，每个字标上下标，绘制时按下标取它此刻的样子。
    private var indexedText: Text {
        tokens.indices.reduce(Text(verbatim: "")) { text, index in
            let token = Text(verbatim: tokens[index].text)
                .customAttribute(ImmersiveKineticTokenIndex(index: index))
            guard index > 0, !separator.isEmpty else { return Text("\(text)\(token)") }
            return Text("\(text)\(Text(verbatim: separator))\(token)")
        }
    }
}

@available(tvOS 18.0, *)
private struct ImmersiveKineticTokenIndex: TextAttribute {
    let index: Int
}

@available(tvOS 18.0, *)
private struct ImmersiveKineticLyricRenderer: TextRenderer {
    let appearances: [ImmersiveKineticLyricsPolicy.Appearance]
    let fontSize: CGFloat
    let glowColor: Color

    /// 入场从下方弹上来、退场往上飘、光都会画出字框，按最大幅度留边。只随字号变，不随时间变。
    var displayPadding: EdgeInsets {
        let overhang = (fontSize * CGFloat(ImmersiveKineticLyricsPolicy.maximumOverhangRatio)).rounded(.up)
        return EdgeInsets(top: overhang, leading: overhang / 2, bottom: overhang, trailing: overhang / 2)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let index = run[ImmersiveKineticTokenIndex.self]?.index,
                      appearances.indices.contains(index) else {
                    context.draw(run)
                    continue
                }
                draw(run, appearance: appearances[index], in: context)
            }
        }
    }

    private func draw(
        _ run: Text.Layout.Run,
        appearance: ImmersiveKineticLyricsPolicy.Appearance,
        in base: GraphicsContext
    ) {
        guard appearance.opacity > 0.002 else { return }
        let bounds = run.typographicBounds.rect
        if appearance.ripple > 0 {
            drawRipple(under: bounds, progress: appearance.ripple, opacity: appearance.opacity, in: base)
        }
        var context = base
        context.opacity = appearance.opacity
        // 绕这个字自己的中心缩放，再整体上下挪。
        let anchor = CGPoint(x: bounds.midX, y: bounds.midY)
        context.translateBy(x: anchor.x, y: anchor.y + CGFloat(appearance.offset) * fontSize)
        context.scaleBy(x: CGFloat(appearance.scale), y: CGFloat(appearance.scale))
        context.translateBy(x: -anchor.x, y: -anchor.y)
        // 虚化只在入场、退场那半秒里有；停稳的字不经过模糊。
        if appearance.blur > 0.004 {
            context.addFilter(.blur(radius: CGFloat(appearance.blur) * fontSize))
        }
        if appearance.glitch > 0.01 {
            // 故障字：红、青两色往两边错开。
            let shift = CGFloat(appearance.glitch) * fontSize * 0.11
            for (tint, dx) in [(Color(red: 1, green: 0.15, blue: 0.3), -shift), (Color(red: 0.1, green: 0.95, blue: 1), shift)] {
                var copy = context
                copy.opacity = appearance.opacity * 0.75 * appearance.glitch
                copy.translateBy(x: dx, y: 0)
                copy.addFilter(.colorMultiply(tint))
                copy.blendMode = .screen
                copy.draw(run)
            }
        }
        if appearance.glow > 0.01 {
            var glow = context
            glow.addFilter(.shadow(
                color: glowColor.opacity(0.9 * appearance.glow),
                radius: fontSize * CGFloat(ImmersiveKineticLyricsPolicy.glowRadiusRatio * appearance.glow),
                options: .shadowOnly
            ))
            glow.draw(run)
        }
        context.draw(run)
    }

    /// 落字成纹：字脚下荡开一圈压扁的涟漪，越荡越大、越细、越淡。
    private func drawRipple(under bounds: CGRect, progress: Double, opacity: Double, in base: GraphicsContext) {
        let spread = 1 - pow(1 - progress, 2.2)
        let width = fontSize * (0.55 + 2.2 * spread)
        let height = width * 0.3
        let center = CGPoint(x: bounds.midX, y: bounds.maxY + fontSize * 0.06)
        let ring = Path(ellipseIn: CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        ))
        var context = base
        context.opacity = opacity * 0.7 * pow(1 - progress, 1.4)
        context.stroke(ring, with: .color(glowColor), lineWidth: max(fontSize * 0.04 * (1 - progress), 0.5))
    }
}

/// 镜头带着整句走时（`ImmersiveKineticDirectionPolicy`）整句此刻的位移、缩放、虚化、透明度；甩镜时身后拖几道
/// 越来越淡的残影，圈入圈出时套一个圆形遮罩。
struct ImmersiveKineticLineMotion: ViewModifier {
    let transform: ImmersiveKineticLineTransform
    /// 甩镜往哪边走：1 往左。
    let side: Double
    let width: CGFloat
    let fontSize: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        // 圈入圈出才套遮罩；同一句的镜头不会中途换，视图结构不会来回变。
        if let iris = transform.iris {
            moved(content).mask {
                GeometryReader { proxy in
                    let radius = CGFloat(iris) * hypot(proxy.size.width, proxy.size.height) / 2 + 1
                    Circle()
                        .frame(width: radius * 2, height: radius * 2)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        } else {
            moved(content)
        }
    }

    private func moved(_ content: Content) -> some View {
        let offsetX = CGFloat(transform.offsetX) * width
        let smear = CGFloat(transform.smear)
        return ZStack {
            if smear > 0.05 {
                // 残影排在运动方向的后面。
                ForEach(1..<4, id: \.self) { step in
                    content
                        .opacity(Double(smear) * (0.42 - 0.12 * Double(step)))
                        .offset(x: CGFloat(side) * smear * fontSize * 0.55 * CGFloat(step))
                }
            }
            content
        }
        .scaleEffect(CGFloat(transform.scale))
        .blur(radius: CGFloat(transform.blur) * fontSize)
        .opacity(transform.opacity)
        .offset(x: offsetX, y: CGFloat(transform.offsetY) * fontSize)
    }
}

/// 斜面透视：整块歌词排在一块向远处倾斜的平面上，机位慢慢左右摇；平视、竖排时原样。
struct ImmersiveKineticStagingEffect: ViewModifier {
    let staging: ImmersiveKineticStaging
    let time: TimeInterval
    let animates: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch staging {
        case .flat, .vertical:
            content
        case .tilted:
            // 一行字只靠俯仰几乎看不出斜面，要靠左右摇和够强的透视；摇到 15° 时近端放大，整句会出画。
            content
                .rotation3DEffect(.degrees(26), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 1.4)
                .rotation3DEffect(
                    .degrees(animates ? sin(time * 0.16) * 12 : 8),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    perspective: 1.4
                )
        }
    }
}

/// 「动态歌词」的底：专辑色铺底，几团柔光慢慢漂。不读频谱，Apple Music、电台、MV 一样会动。
struct ImmersiveKineticBackdrop: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    @Environment(\.immersiveMotionIntensity) private var motion
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool

    var body: some View {
        // 光团漂得很慢，铺满整屏的渐变一秒画二十次就够；电视上不超过三十次。
        TimelineView(.animation(
            minimumInterval: frameRate.minimumInterval(base: 1.0 / 20, televisionFloor: 1.0 / 30),
            paused: !isAnimating
        )) { context in
            let time = context.date.timeIntervalSinceReferenceDate * motion.speed
            GeometryReader { geometry in
                let reach = max(geometry.size.width, geometry.size.height)
                ZStack {
                    LinearGradient(
                        colors: [palette.secondary, ImmersiveStagePalette.obsidian],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    glow(
                        palette.primary.opacity(0.58),
                        center: drift(time, period: 29, phase: 0, base: (0.26, 0.30), reach: (0.16, 0.10)),
                        radius: reach * 0.62
                    )
                    glow(
                        palette.primary.opacity(0.34),
                        center: drift(time, period: 37, phase: 2.2, base: (0.78, 0.72), reach: (0.12, 0.14)),
                        radius: reach * 0.56
                    )
                    glow(
                        ImmersiveStagePalette.ink.opacity(0.07),
                        center: drift(time, period: 43, phase: 4.1, base: (0.55, 0.46), reach: (0.20, 0.16)),
                        radius: reach * 0.42
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(colors: [color, .clear], center: center, startRadius: 0, endRadius: radius)
    }

    /// 绕 `base` 画一个慢慢转的椭圆；幅度跟动效强度走。
    private func drift(
        _ time: TimeInterval,
        period: Double,
        phase: Double,
        base: (Double, Double),
        reach: (Double, Double)
    ) -> UnitPoint {
        guard isAnimating else { return UnitPoint(x: base.0, y: base.1) }
        let angle = time / period * 2 * .pi + phase
        let amplitude = motion.amplitude
        return UnitPoint(
            x: base.0 + reach.0 * amplitude * cos(angle),
            y: base.1 + reach.1 * amplitude * sin(angle * 0.8)
        )
    }
}

/// 两句之间空档里的三个点，一个接一个轻轻起伏。
struct ImmersiveKineticInterlude: View {
    let visibility: Double
    let time: TimeInterval
    let dotSize: CGFloat
    let color: Color
    let animates: Bool

    var body: some View {
        HStack(spacing: dotSize * 0.9) {
            ForEach(0..<3, id: \.self) { index in
                let wave = animates ? (sin(time * 2.4 - Double(index) * 0.7) + 1) / 2 : 0.5
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(0.72 + 0.28 * wave)
                    .opacity(0.35 + 0.55 * wave)
            }
        }
        .opacity(visibility)
        .accessibilityHidden(true)
    }
}
