import Foundation
import SwiftUI

// 沉浸舞台的动态渲染层：新增的黑胶、镜面、极光、天际线、粒子场，以及既有
// 场景升级后使用的深空星野、有机声纹、光束、呼吸光环与悬浮封面。
//
// 与 ImmersiveStageScenery.swift 一样只依赖 SwiftUI，同时编进 Primuse(iOS)、
// PrimuseMac 与 PrimuseTV 三个 target(见 project.yml)。所有层都用
// TimelineView + Canvas 以固定帧率重绘，帧率与模糊半径按 Apple TV 的填充率
// 上限取值，避免整屏高频高斯模糊。

// MARK: - 频谱摘要与确定性随机

/// 从实时频段里取低频与整体能量，供粒子、涟漪、能量光晕等节拍响应层使用。
enum ImmersiveSpectrumSummary {
    static func bass(_ levels: [CGFloat]) -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        let count = max(1, min(levels.count, max(2, levels.count / 6)))
        let sum = levels.prefix(count).reduce(0, +)
        return min(max(sum / CGFloat(count), 0), 1)
    }

    static func energy(_ levels: [CGFloat]) -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        let sum = levels.reduce(0, +)
        return min(max(sum / CGFloat(levels.count), 0), 1)
    }
}

/// 无状态的确定性伪随机：同一 index / salt 每帧结果一致，重绘不会闪烁。
enum ImmersiveSeed {
    static func unit(_ index: Int, salt: Int = 0) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43_758.5453
        return value - floor(value)
    }

    static func wrapped(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 1)
        return result < 0 ? result + 1 : result
    }

    static func wave(_ time: TimeInterval, period: Double, phase: Double = 0) -> Double {
        sin(time / period * 2 * .pi + phase)
    }
}

// MARK: - 深空星野

/// 星夜的星空：三层视差星点、封面色星云、一条斜向银河与偶尔划过的流星。
/// 远层星点最小最慢，近层带光晕；所有位置由确定性种子决定。
struct ImmersiveDeepStarField: View {
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    var showsNebula = true
    var showsShootingStars = true

    private struct Layer {
        let count: Int
        let speed: Double
        let minRadius: CGFloat
        let maxRadius: CGFloat
        let alpha: Double
    }

    private static let layers = [
        Layer(count: 150, speed: 0.0018, minRadius: 0.45, maxRadius: 0.95, alpha: 0.42),
        Layer(count: 72, speed: 0.0034, minRadius: 0.9, maxRadius: 1.6, alpha: 0.64),
        Layer(count: 26, speed: 0.0052, minRadius: 1.6, maxRadius: 2.6, alpha: 0.94),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 18, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                let bounds = Path(CGRect(origin: .zero, size: size))
                canvas.fill(bounds, with: .linearGradient(
                    Gradient(colors: [ImmersiveStagePalette.obsidian, palette.secondary.opacity(0.78)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width * 0.4, y: size.height)
                ))

                if showsNebula {
                    drawNebula(in: &canvas, bounds: bounds, size: size, time: time)
                }
                drawStars(in: &canvas, size: size, time: time)
                if showsShootingStars, isAnimating {
                    drawShootingStar(in: &canvas, size: size, time: time)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawNebula(in canvas: inout GraphicsContext, bounds: Path, size: CGSize, time: TimeInterval) {
        let diagonal = max(size.width, size.height)
        let primaryCenter = CGPoint(
            x: size.width * 0.74 + CGFloat(ImmersiveSeed.wave(time, period: 41)) * size.width * 0.05,
            y: size.height * 0.30 + CGFloat(ImmersiveSeed.wave(time, period: 53, phase: 1.3)) * size.height * 0.04
        )
        let secondaryCenter = CGPoint(
            x: size.width * 0.22 - CGFloat(ImmersiveSeed.wave(time, period: 47)) * size.width * 0.04,
            y: size.height * 0.76 + CGFloat(ImmersiveSeed.wave(time, period: 37, phase: 0.6)) * size.height * 0.05
        )
        canvas.fill(bounds, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.primary.opacity(0.30), location: 0),
                .init(color: palette.primary.opacity(0.11), location: 0.45),
                .init(color: .clear, location: 1),
            ]),
            center: primaryCenter,
            startRadius: 0,
            endRadius: diagonal * 0.46
        ))
        canvas.fill(bounds, with: .radialGradient(
            Gradient(stops: [
                .init(color: palette.secondary.opacity(0.62), location: 0),
                .init(color: palette.secondary.opacity(0.22), location: 0.5),
                .init(color: .clear, location: 1),
            ]),
            center: secondaryCenter,
            startRadius: 0,
            endRadius: diagonal * 0.42
        ))
        // 斜向银河：一条很淡的亮带穿过画面，让星空有纵深而不是均匀撒点。
        canvas.fill(bounds, with: .linearGradient(
            Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: ImmersiveStagePalette.ink.opacity(0.045), location: 0.40),
                .init(color: ImmersiveStagePalette.ink.opacity(0.085), location: 0.50),
                .init(color: ImmersiveStagePalette.ink.opacity(0.045), location: 0.60),
                .init(color: .clear, location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: size.height * 0.15),
            endPoint: CGPoint(x: size.width, y: size.height * 0.95)
        ))
    }

    private func drawStars(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        for (layerIndex, layer) in Self.layers.enumerated() {
            for index in 0..<layer.count {
                let seedA = ImmersiveSeed.unit(index, salt: layerIndex * 7 + 1)
                let seedB = ImmersiveSeed.unit(index, salt: layerIndex * 7 + 2)
                let seedC = ImmersiveSeed.unit(index, salt: layerIndex * 7 + 3)
                let drift: Double = isAnimating ? time * layer.speed : 0
                let x: Double = ImmersiveSeed.wrapped(seedA + drift * (0.6 + seedC * 0.8))
                let y: Double = ImmersiveSeed.wrapped(seedB + drift * 0.28)
                let twinkle: Double = isAnimating
                    ? (sin(time * (0.7 + seedC * 1.6) + seedA * 6.28) + 1) / 2
                    : 0.6
                let radius: CGFloat = layer.minRadius + CGFloat(seedC) * (layer.maxRadius - layer.minRadius)
                let alpha: Double = layer.alpha * (0.45 + twinkle * 0.55)
                let center = CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
                let tint = seedB < 0.18 ? palette.primary : ImmersiveStagePalette.ink

                if layerIndex == 2 {
                    let haloRadius = radius * 3.4
                    canvas.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - haloRadius,
                            y: center.y - haloRadius,
                            width: haloRadius * 2,
                            height: haloRadius * 2
                        )),
                        with: .radialGradient(
                            Gradient(colors: [tint.opacity(alpha * 0.38), .clear]),
                            center: center,
                            startRadius: 0,
                            endRadius: haloRadius
                        )
                    )
                }
                canvas.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(tint.opacity(alpha))
                )
            }
        }
    }

    private func drawShootingStar(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let period = 9.5
        let cycle = floor(time / period)
        let progress = (time - cycle * period) / period
        let window = 0.16
        guard progress < window else { return }

        let unit = progress / window
        let seedA = ImmersiveSeed.unit(Int(cycle), salt: 11)
        let seedB = ImmersiveSeed.unit(Int(cycle), salt: 12)
        let towardsLeft = seedB > 0.5
        let start = CGPoint(
            x: size.width * (towardsLeft ? 0.55 + seedA * 0.35 : 0.10 + seedA * 0.35),
            y: size.height * (0.08 + seedB * 0.22)
        )
        let direction = CGVector(dx: towardsLeft ? -0.83 : 0.83, dy: 0.56)
        let length = size.width * 0.34
        let head = CGPoint(
            x: start.x + direction.dx * length * CGFloat(unit),
            y: start.y + direction.dy * length * CGFloat(unit)
        )
        let envelope = sin(unit * .pi)
        let tailLength = size.width * 0.13 * CGFloat(envelope)
        let tail = CGPoint(
            x: head.x - direction.dx * tailLength,
            y: head.y - direction.dy * tailLength
        )

        var streak = Path()
        streak.move(to: tail)
        streak.addLine(to: head)
        canvas.stroke(
            streak,
            with: .linearGradient(
                Gradient(colors: [.clear, ImmersiveStagePalette.ink.opacity(0.92 * envelope)]),
                startPoint: tail,
                endPoint: head
            ),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
        )
        let glowRadius: CGFloat = 4
        canvas.fill(
            Path(ellipseIn: CGRect(
                x: head.x - glowRadius,
                y: head.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [ImmersiveStagePalette.ink.opacity(0.9 * envelope), .clear]),
                center: head,
                startRadius: 0,
                endRadius: glowRadius
            )
        )
    }
}

// MARK: - 有机声纹

/// 流动声纹的线场：以封面为圆心的多层轮廓线，叠加三组不同频率的波动持续
/// 演化；每第四圈用封面色并带柔光，其余为淡色细线。
struct ImmersiveOrganicContourField: View {
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    var center: UnitPoint = .center
    var ringCount = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 18, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                let origin = CGPoint(x: size.width * center.x, y: size.height * center.y)
                let shortSide = min(size.width, size.height)
                let base = shortSide * 0.10
                let step = shortSide * 0.034
                let pointCount = 140

                canvas.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(colors: [palette.primary.opacity(0.30), .clear]),
                        center: origin,
                        startRadius: 0,
                        endRadius: base * 4.2
                    )
                )

                var accentRings = Path()
                var quietRings = Path()
                for ring in 0..<ringCount {
                    let ringPhase = Double(ring)
                    let radius: CGFloat = base + CGFloat(ring) * step
                    var path = Path()
                    for point in 0...pointCount {
                        // 每个中间量都标注类型:这里 Double 与 CGFloat 混算,
                        // 两者之间存在隐式转换,不标注的话类型检查器要在一个
                        // 长表达式里穷举所有组合,直接超时编译失败。
                        let angle: Double = Double(point) / Double(pointCount) * 2 * .pi
                        let first: Double = sin(angle * 3 + time * 0.31 + ringPhase * 0.29) * 0.075
                        let second: Double = cos(angle * 5 - time * 0.19 + ringPhase * 0.17) * 0.04
                        let third: Double = sin(angle * 2 + time * 0.12 - ringPhase * 0.11) * 0.05
                        let wobble: CGFloat = CGFloat(first + second + third)
                        let scaled: CGFloat = radius * (1 + wobble)
                        let drift: CGFloat = CGFloat(sin(time * 0.17 + ringPhase * 0.5)) * radius * 0.05
                        let valueX: CGFloat = origin.x + CGFloat(cos(angle)) * scaled * 1.12 + drift
                        let valueY: CGFloat = origin.y + CGFloat(sin(angle)) * scaled * 0.88
                        let value = CGPoint(x: valueX, y: valueY)
                        if point == 0 { path.move(to: value) } else { path.addLine(to: value) }
                    }
                    path.closeSubpath()
                    if ring.isMultiple(of: 4) {
                        accentRings.addPath(path)
                    } else {
                        quietRings.addPath(path)
                    }
                }

                canvas.drawLayer { glow in
                    glow.addFilter(.blur(radius: 6))
                    glow.stroke(accentRings, with: .color(palette.primary.opacity(0.55)), lineWidth: 3)
                }
                canvas.stroke(
                    quietRings,
                    with: .linearGradient(
                        Gradient(colors: [
                            ImmersiveStagePalette.text.opacity(0.10),
                            ImmersiveStagePalette.text.opacity(0.26),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    ),
                    lineWidth: 0.8
                )
                canvas.stroke(accentRings, with: .color(palette.primary.opacity(0.62)), lineWidth: 1.3)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 围绕圆形封面的轨道环：一段封面色渐变弧线与一颗亮点反向慢速绕行。
struct ImmersiveOrbitRing: View {
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    var diameter: CGFloat
    var period: Double = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            let angle = -time.truncatingRemainder(dividingBy: period) / period * 360
            ZStack {
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                palette.primary.opacity(0),
                                palette.primary.opacity(0.95),
                                ImmersiveStagePalette.ink.opacity(0.75),
                                palette.primary.opacity(0),
                            ],
                            center: .center
                        ),
                        lineWidth: max(1, diameter * 0.008)
                    )
                Circle()
                    .fill(ImmersiveStagePalette.ink)
                    .frame(width: diameter * 0.028, height: diameter * 0.028)
                    .shadow(color: palette.primary.opacity(0.9), radius: diameter * 0.02)
                    .offset(y: -diameter / 2 + diameter * 0.004)
            }
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(angle))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 光束与呼吸光环

/// 从画面一角射入的柔和光束：若干楔形以不同周期缓慢摆动、明暗起伏，
/// 经一次模糊后成为丁达尔光。
struct ImmersiveLightRays: View {
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    var origin = UnitPoint(x: 0.10, y: -0.10)
    var rayCount = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                let source = CGPoint(x: size.width * origin.x, y: size.height * origin.y)
                let reach: CGFloat = (size.width * size.width + size.height * size.height).squareRoot() * 1.2
                canvas.blendMode = .plusLighter
                for index in 0..<rayCount {
                    let seed: Double = ImmersiveSeed.unit(index, salt: 3)
                    let baseAngle: Double = 0.30 + Double(index) / Double(max(rayCount - 1, 1)) * 1.05
                    let sway: Double = isAnimating
                        ? sin(time / (17 + seed * 9) * 2 * .pi + seed * 6.28) * 0.05
                        : 0
                    let angle: Double = baseAngle + sway
                    let halfWidth: Double = 0.03 + seed * 0.05
                    // 顶点坐标先各自算成 CGFloat 再组装,理由同上。
                    let leadX: CGFloat = source.x + CGFloat(cos(angle - halfWidth)) * reach
                    let leadY: CGFloat = source.y + CGFloat(sin(angle - halfWidth)) * reach
                    let trailX: CGFloat = source.x + CGFloat(cos(angle + halfWidth)) * reach
                    let trailY: CGFloat = source.y + CGFloat(sin(angle + halfWidth)) * reach
                    var wedge = Path()
                    wedge.move(to: source)
                    wedge.addLine(to: CGPoint(x: leadX, y: leadY))
                    wedge.addLine(to: CGPoint(x: trailX, y: trailY))
                    wedge.closeSubpath()

                    let shimmer: Double = isAnimating
                        ? (sin(time / (5 + seed * 4) * 2 * .pi + Double(index)) + 1) / 2
                        : 0.5
                    let alpha: Double = 0.05 + shimmer * 0.09
                    let endX: CGFloat = source.x + CGFloat(cos(angle)) * reach * 0.8
                    let endY: CGFloat = source.y + CGFloat(sin(angle)) * reach * 0.8
                    canvas.fill(wedge, with: .linearGradient(
                        Gradient(colors: [
                            palette.primary.opacity(alpha),
                            palette.primary.opacity(alpha * 0.5),
                            .clear,
                        ]),
                        startPoint: source,
                        endPoint: CGPoint(x: endX, y: endY)
                    ))
                }
            }
            .blur(radius: 22)
        }
        .allowsHitTesting(false)
    }
}

/// 封面背后的呼吸光环：柔光随周期涨落，一圈渐变细环缓慢自转。
struct ImmersiveBreathingHalo: View {
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    var diameter: CGFloat
    var period: Double = 8.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            // Double 与 CGFloat 分开标注,避免类型检查器在混算表达式里穷举组合。
            let breath: Double = isAnimating ? (sin(time / period * 2 * .pi) + 1) / 2 : 0.5
            let ringScale: CGFloat = CGFloat(1.10 + breath * 0.06)
            let bodyScale: CGFloat = CGFloat(0.98 + breath * 0.05)
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [palette.primary.opacity(0.40 + breath * 0.22), .clear],
                            center: .center,
                            startRadius: diameter * 0.30,
                            endRadius: diameter * 0.64
                        )
                    )
                    .frame(width: diameter * 1.3, height: diameter * 1.3)
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                palette.primary.opacity(0),
                                palette.primary.opacity(0.85),
                                ImmersiveStagePalette.ink.opacity(0.55),
                                palette.primary.opacity(0),
                            ],
                            center: .center
                        ),
                        lineWidth: max(1, diameter * 0.006)
                    )
                    .frame(
                        width: diameter * ringScale,
                        height: diameter * ringScale
                    )
                    .rotationEffect(.degrees(time / 40 * 360))
                    .blur(radius: 1.2)
            }
            .scaleEffect(bodyScale)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 悬浮封面

/// 封面流光的主视觉：封面缓慢升降、轻微透视倾斜，间歇有一道斜向高光扫过。
struct ImmersiveLevitatingPlate<Content: View>: View {
    var isAnimating: Bool
    var side: CGFloat
    var cornerRadius: CGFloat
    var glow: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            let amplitude = side * 0.028
            let lift: CGFloat = CGFloat(sin(time / 5.6 * 2 * .pi)) * amplitude
            let tilt: Double = sin(time / 7.3 * 2 * .pi) * 1.8
            let sweep: Double = ImmersiveSeed.wrapped(time / 7.5)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            content()
                .overlay {
                    // 高光只在周期前 30% 扫过，其余时间停在画面外。
                    let travel = sweep < 0.30 ? CGFloat(sweep / 0.30) : -1
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.26), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: side * 0.38, height: side * 1.8)
                        .rotationEffect(.degrees(28))
                        .offset(x: travel < 0 ? side * 2 : -side * 0.9 + travel * side * 1.8)
                        .blendMode(.screen)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
                .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .offset(y: lift)
                .shadow(
                    color: glow.opacity(0.55),
                    radius: side * 0.14 + lift * 0.4,
                    y: side * 0.08 - lift * 0.6
                )
        }
    }
}

// MARK: - 黑胶唱机

/// 静态唱片本体：径向渐变胶面、几十圈音槽、固定光源的两道反光与外缘描边。
/// 绘制一次即可，旋转部分由 ImmersiveVinylRecord 单独驱动。
private struct ImmersiveVinylDisc: View, Equatable {
    var diameter: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: true) { canvas, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let disc = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            canvas.fill(disc, with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(white: 0.17), location: 0),
                    .init(color: Color(white: 0.09), location: 0.40),
                    .init(color: Color(white: 0.125), location: 0.72),
                    .init(color: Color(white: 0.07), location: 0.96),
                    .init(color: Color(white: 0.03), location: 1),
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            ))

            var grooves = Path()
            var brightGrooves = Path()
            let grooveCount = 54
            let start = radius * 0.40
            let end = radius * 0.965
            for index in 0..<grooveCount {
                let ringRadius = start + (end - start) * CGFloat(index) / CGFloat(grooveCount - 1)
                let ring = Path(ellipseIn: CGRect(
                    x: center.x - ringRadius,
                    y: center.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                ))
                if index % 9 == 4 {
                    brightGrooves.addPath(ring)
                } else {
                    grooves.addPath(ring)
                }
            }
            canvas.stroke(grooves, with: .color(.white.opacity(0.045)), lineWidth: 0.7)
            canvas.stroke(brightGrooves, with: .color(.white.opacity(0.11)), lineWidth: 1)

            var shine = canvas
            shine.clip(to: disc)
            shine.fill(disc, with: .conicGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.13), location: 0.10),
                    .init(color: .clear, location: 0.20),
                    .init(color: .clear, location: 0.50),
                    .init(color: .white.opacity(0.09), location: 0.61),
                    .init(color: .clear, location: 0.71),
                    .init(color: .clear, location: 1),
                ]),
                center: center,
                angle: .degrees(-35)
            ))
            canvas.stroke(disc, with: .color(.white.opacity(0.16)), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 随唱片旋转的细微划痕，让旋转在纯对称的音槽之外也能被看见。
private struct ImmersiveVinylScratches: View, Equatable {
    var diameter: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: true) { canvas, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            for index in 0..<14 {
                let seedA = ImmersiveSeed.unit(index, salt: 21)
                let seedB = ImmersiveSeed.unit(index, salt: 22)
                let seedC = ImmersiveSeed.unit(index, salt: 23)
                let arcRadius = radius * (0.42 + CGFloat(seedA) * 0.52)
                let startAngle = Angle.radians(seedB * 2 * .pi)
                let endAngle = Angle.radians(seedB * 2 * .pi + 0.25 + seedC * 0.6)
                var arc = Path()
                arc.addArc(
                    center: center,
                    radius: arcRadius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: false
                )
                canvas.stroke(arc, with: .color(.white.opacity(0.05 + seedC * 0.05)), lineWidth: 0.8)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 黑胶唱片：静态胶面 + 随播放旋转的圆标(封面)、划痕与中轴。
/// 旋转角始终取自同一时钟，暂停时停在当前角度而不是跳回起点。
struct ImmersiveVinylRecord<Label: View>: View {
    var palette: ImmersiveArtworkPalette
    var isSpinning: Bool
    var reduceMotion: Bool
    var diameter: CGFloat
    var spinPeriod: Double = 4.8
    @ViewBuilder var label: (CGFloat) -> Label

    var body: some View {
        let labelDiameter = diameter * 0.37
        ZStack {
            ImmersiveVinylDisc(diameter: diameter)
                .equatable()
                .shadow(color: palette.primary.opacity(0.42), radius: diameter * 0.10, y: diameter * 0.04)
                .shadow(color: .black.opacity(0.62), radius: diameter * 0.05, y: diameter * 0.03)

            TimelineView(.animation(minimumInterval: 1 / 24, paused: !isSpinning || reduceMotion)) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                let angle = reduceMotion ? 0 : seconds.truncatingRemainder(dividingBy: spinPeriod) / spinPeriod * 360
                ZStack {
                    ImmersiveVinylScratches(diameter: diameter)
                        .equatable()
                    label(labelDiameter)
                        .frame(width: labelDiameter, height: labelDiameter)
                        .clipShape(Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        }
                    Circle()
                        .fill(Color(white: 0.05))
                        .frame(width: diameter * 0.028, height: diameter * 0.028)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.32), lineWidth: 0.8)
                        }
                }
                .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// 唱臂：支点在唱片右上方，播放时落到音槽上，暂停时抬回臂架。
struct ImmersiveVinylTonearm: View {
    var recordDiameter: CGFloat
    var isPlaying: Bool
    var tint: Color

    /// 唱臂组件所占画布：比唱片宽 14%，让支点落在唱片之外。
    static func canvasSize(recordDiameter: CGFloat) -> CGSize {
        CGSize(width: recordDiameter * 1.14, height: recordDiameter)
    }

    var body: some View {
        let size = Self.canvasSize(recordDiameter: recordDiameter)
        let pivot = CGPoint(x: recordDiameter * 1.04, y: recordDiameter * 0.08)
        let armLength = recordDiameter * 0.62
        let anchor = UnitPoint(x: pivot.x / size.width, y: pivot.y / size.height)

        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.34), Color(white: 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: recordDiameter * 0.13, height: recordDiameter * 0.13)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.26), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: recordDiameter * 0.015, y: recordDiameter * 0.01)
                .position(pivot)

            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.24), Color(white: 0.16)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: recordDiameter * 0.052, height: recordDiameter * 0.10)
                    .position(x: pivot.x, y: pivot.y - recordDiameter * 0.085)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.86), Color(white: 0.58)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: recordDiameter * 0.020, height: armLength)
                    .position(x: pivot.x, y: pivot.y + armLength / 2)
                RoundedRectangle(cornerRadius: recordDiameter * 0.012, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.90), Color(white: 0.62)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: recordDiameter * 0.044, height: recordDiameter * 0.11)
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(tint)
                            .frame(width: recordDiameter * 0.012, height: recordDiameter * 0.03)
                            .offset(y: recordDiameter * 0.012)
                    }
                    .position(x: pivot.x, y: pivot.y + armLength + recordDiameter * 0.035)
            }
            .shadow(color: .black.opacity(0.55), radius: recordDiameter * 0.02, x: recordDiameter * 0.008, y: recordDiameter * 0.02)
            .rotationEffect(.degrees(isPlaying ? 24 : -4), anchor: anchor)
            .animation(.easeInOut(duration: 1.1), value: isPlaying)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

// MARK: - 镜面地板

/// 镜面展台的舞台：天幕、发光地平线、镜面地板、封面正下方的聚光斑与
/// 缓慢向观众推进的地板光带。倒影本身由场景用封面视图翻转生成。
struct ImmersiveMirrorFloor: View {
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    /// 地平线在画布内的绝对纵坐标。
    var horizonY: CGFloat
    /// 聚光斑与天幕光晕的横坐标(封面中心)。
    var spotlightX: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas(rendersAsynchronously: true) { canvas, size in
                let horizon = min(max(horizonY, 1), size.height - 1)
                let bounds = Path(CGRect(origin: .zero, size: size))
                let skyRect = CGRect(x: 0, y: 0, width: size.width, height: horizon)
                let floorRect = CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)

                canvas.fill(Path(skyRect), with: .linearGradient(
                    Gradient(colors: [palette.secondary.opacity(0.92), ImmersiveStagePalette.obsidian]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: horizon)
                ))
                canvas.fill(bounds, with: .radialGradient(
                    Gradient(colors: [palette.primary.opacity(0.30), .clear]),
                    center: CGPoint(x: spotlightX, y: horizon * 0.55),
                    startRadius: 0,
                    endRadius: horizon * 0.95
                ))

                canvas.fill(Path(floorRect), with: .linearGradient(
                    Gradient(colors: [
                        palette.primary.opacity(0.26),
                        palette.secondary.opacity(0.55),
                        ImmersiveStagePalette.obsidian,
                    ]),
                    startPoint: CGPoint(x: 0, y: horizon),
                    endPoint: CGPoint(x: 0, y: size.height)
                ))

                var spot = canvas
                spot.clip(to: Path(floorRect))
                spot.translateBy(x: spotlightX, y: horizon + floorRect.height * 0.16)
                spot.scaleBy(x: 1, y: 0.32)
                let spotRadius = size.width * 0.36
                spot.fill(
                    Path(ellipseIn: CGRect(
                        x: -spotRadius,
                        y: -spotRadius,
                        width: spotRadius * 2,
                        height: spotRadius * 2
                    )),
                    with: .radialGradient(
                        Gradient(colors: [palette.primary.opacity(0.46), .clear]),
                        center: .zero,
                        startRadius: 0,
                        endRadius: spotRadius
                    )
                )

                var floorLight = canvas
                floorLight.clip(to: Path(floorRect))
                floorLight.blendMode = .plusLighter
                for index in 0..<3 {
                    let phase = isAnimating
                        ? ImmersiveSeed.wrapped(time / (9 + Double(index) * 3) + Double(index) * 0.33)
                        : Double(index) * 0.33
                    let y = horizon + CGFloat(phase) * floorRect.height
                    let thickness = 1 + CGFloat(phase) * 6
                    let alpha = 0.06 * (1 - phase) + 0.02
                    floorLight.fill(
                        Path(CGRect(x: 0, y: y - thickness / 2, width: size.width, height: thickness)),
                        with: .linearGradient(
                            Gradient(colors: [
                                .clear,
                                ImmersiveStagePalette.ink.opacity(alpha),
                                .clear,
                            ]),
                            startPoint: CGPoint(x: 0, y: y),
                            endPoint: CGPoint(x: size.width, y: y)
                        )
                    )
                }

                canvas.drawLayer { glow in
                    glow.addFilter(.blur(radius: 8))
                    glow.fill(
                        Path(CGRect(x: 0, y: horizon - 3, width: size.width, height: 6)),
                        with: .color(palette.primary.opacity(0.6))
                    )
                }
                canvas.fill(
                    Path(CGRect(x: 0, y: horizon - 0.75, width: size.width, height: 1.5)),
                    with: .linearGradient(
                        Gradient(colors: [
                            .clear,
                            palette.primary.opacity(0.95),
                            ImmersiveStagePalette.ink.opacity(0.9),
                            palette.primary.opacity(0.95),
                            .clear,
                        ]),
                        startPoint: CGPoint(x: 0, y: horizon),
                        endPoint: CGPoint(x: size.width, y: horizon)
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 极光帷幕

/// 极光：星空之上四条封面色光幕以不同速度起伏，幕内有闪烁的竖向光柱，
/// 底部压一层深色地面剪影。整层只做一次模糊。
struct ImmersiveAuroraCurtains: View {
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool

    private struct Band {
        let color: Color
        let baseY: Double
        let height: Double
        let speed: Double
        let alpha: Double
    }

    private var bands: [Band] {
        [
            Band(color: palette.primary, baseY: 0.30, height: 0.34, speed: 1.0, alpha: 0.50),
            Band(color: ImmersiveStagePalette.ink, baseY: 0.36, height: 0.22, speed: 1.35, alpha: 0.16),
            Band(color: palette.secondary, baseY: 0.44, height: 0.36, speed: 0.8, alpha: 0.62),
            Band(color: palette.primary, baseY: 0.20, height: 0.26, speed: 0.6, alpha: 0.30),
        ]
    }

    var body: some View {
        ZStack {
            ImmersiveDeepStarField(
                palette: palette,
                isAnimating: isAnimating,
                showsNebula: false,
                showsShootingStars: false
            )

            TimelineView(.animation(minimumInterval: 1 / 15, paused: !isAnimating)) { context in
                let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
                Canvas(rendersAsynchronously: true) { canvas, size in
                    canvas.blendMode = .plusLighter
                    let samples = 64
                    for (index, band) in bands.enumerated() {
                        let offset = Double(index)
                        var curtain = Path()
                        for sample in 0...samples {
                            let x: Double = Double(sample) / Double(samples)
                            // 三段波分开写:合成一个长加法式会让类型检查超时。
                            let waveA: Double = sin(x * 5.2 + time * 0.23 * band.speed + offset * 1.7) * 0.06
                            let waveB: Double = sin(x * 11.3 - time * 0.17 * band.speed + offset) * 0.03
                            let waveC: Double = cos(x * 2.1 + time * 0.09 * band.speed) * 0.05
                            let wave: Double = waveA + waveB + waveC
                            let point = CGPoint(
                                x: CGFloat(x) * size.width,
                                y: CGFloat(band.baseY + wave) * size.height
                            )
                            if sample == 0 { curtain.move(to: point) } else { curtain.addLine(to: point) }
                        }
                        for sample in stride(from: samples, through: 0, by: -1) {
                            let x: Double = Double(sample) / Double(samples)
                            let waveA: Double = sin(x * 4.1 - time * 0.19 * band.speed + offset * 0.9) * 0.05
                            let waveB: Double = cos(x * 9.7 + time * 0.13 * band.speed) * 0.025
                            let wave: Double = waveA + waveB
                            curtain.addLine(to: CGPoint(
                                x: CGFloat(x) * size.width,
                                y: CGFloat(band.baseY + band.height + wave) * size.height
                            ))
                        }
                        curtain.closeSubpath()
                        canvas.fill(curtain, with: .linearGradient(
                            Gradient(stops: [
                                .init(color: band.color.opacity(band.alpha), location: 0),
                                .init(color: band.color.opacity(band.alpha * 0.55), location: 0.35),
                                .init(color: .clear, location: 1),
                            ]),
                            startPoint: CGPoint(x: 0, y: CGFloat(band.baseY) * size.height),
                            endPoint: CGPoint(x: 0, y: CGFloat(band.baseY + band.height) * size.height)
                        ))
                    }

                    for index in 0..<28 {
                        let seed = ImmersiveSeed.unit(index, salt: 5)
                        let x = CGFloat(ImmersiveSeed.wrapped(seed + time * 0.006 * (0.5 + seed))) * size.width
                        let shimmer = isAnimating
                            ? (sin(time * (0.9 + seed * 1.4) + seed * 6.28) + 1) / 2
                            : 0.5
                        let top = size.height * CGFloat(0.24 + ImmersiveSeed.unit(index, salt: 6) * 0.14)
                        let bottom = top + size.height * CGFloat(0.22 + seed * 0.2)
                        canvas.fill(
                            Path(CGRect(x: x, y: top, width: CGFloat(1.2 + seed * 2), height: bottom - top)),
                            with: .linearGradient(
                                Gradient(colors: [
                                    .clear,
                                    ImmersiveStagePalette.ink.opacity(0.10 + shimmer * 0.14),
                                    .clear,
                                ]),
                                startPoint: CGPoint(x: x, y: top),
                                endPoint: CGPoint(x: x, y: bottom)
                            )
                        )
                    }
                }
                .blur(radius: 18)
            }

            LinearGradient(
                colors: [.clear, ImmersiveStagePalette.obsidian.opacity(0.85), ImmersiveStagePalette.obsidian],
                startPoint: UnitPoint(x: 0.5, y: 0.62),
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 声场地平线

/// 整幅频谱天际线：低频在中央、高频向两侧展开，从发光地平线向上升起，
/// 并在地平线下形成渐隐的镜像。频段只在这一层读取。
struct ImmersiveSpectrumSkyline: View {
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var horizonY: CGFloat
    var maxBarHeight: CGFloat

    var body: some View {
        let levels = levelsProvider()
        Canvas(rendersAsynchronously: true) { canvas, size in
            let horizon = min(max(horizonY, 1), size.height - 1)
            let count = min(max(Int(size.width / 14), 36), 96)
            let gap = max(size.width * 0.004, 1.5)
            let width = max((size.width - gap * CGFloat(count - 1)) / CGFloat(count), 2)

            var skyline = Path()
            var reflection = Path()
            for index in 0..<count {
                let level = levels.isEmpty ? 0 : shapedLevel(at: index, outputCount: count, source: levels)
                let height = max(width * 0.6, maxBarHeight * (0.06 + level * 0.94))
                let x = CGFloat(index) * (width + gap)
                skyline.addPath(Path(
                    roundedRect: CGRect(x: x, y: horizon - height, width: width, height: height),
                    cornerRadius: width * 0.35
                ))
                reflection.addPath(Path(
                    roundedRect: CGRect(x: x, y: horizon, width: width, height: height * 0.62),
                    cornerRadius: width * 0.35
                ))
            }

            canvas.drawLayer { glow in
                glow.addFilter(.blur(radius: max(6, width)))
                glow.fill(skyline, with: .color(palette.primary.opacity(0.42)))
            }
            canvas.fill(skyline, with: .linearGradient(
                Gradient(colors: [
                    ImmersiveStagePalette.ink.opacity(0.95),
                    palette.primary.opacity(0.92),
                    palette.primary.opacity(0.28),
                ]),
                startPoint: CGPoint(x: 0, y: horizon - maxBarHeight),
                endPoint: CGPoint(x: 0, y: horizon)
            ))
            canvas.fill(reflection, with: .linearGradient(
                Gradient(colors: [palette.primary.opacity(0.30), .clear]),
                startPoint: CGPoint(x: 0, y: horizon),
                endPoint: CGPoint(x: 0, y: horizon + maxBarHeight * 0.62)
            ))
            canvas.fill(
                Path(CGRect(x: 0, y: horizon - 0.6, width: size.width, height: 1.2)),
                with: .linearGradient(
                    Gradient(colors: [.clear, ImmersiveStagePalette.ink.opacity(0.7), .clear]),
                    startPoint: CGPoint(x: 0, y: horizon),
                    endPoint: CGPoint(x: size.width, y: horizon)
                )
            )
        }
        .allowsHitTesting(false)
    }

    /// 低频落在画面中央，两侧对称展开到高频；轻微压缩让高频也能看见。
    private func shapedLevel(at index: Int, outputCount: Int, source: [CGFloat]) -> CGFloat {
        guard source.count > 1, outputCount > 1 else { return min(max(source.first ?? 0, 0), 1) }
        let x = CGFloat(index) / CGFloat(outputCount - 1)
        let folded = abs(x - 0.5) * 2
        let position = pow(min(max(folded, 0), 1), 1.15) * CGFloat(source.count - 1)
        let lower = min(Int(floor(position)), source.count - 1)
        let upper = min(lower + 1, source.count - 1)
        let fraction = position - CGFloat(lower)
        let value = source[lower] + (source[upper] - source[lower]) * fraction
        let lifted = value * (0.92 + folded * 0.30)
        return pow(min(max(lifted, 0), 1), 0.68)
    }
}

// MARK: - 星尘粒子

/// 从封面向外扩散的星尘：位置只由时间决定，保证运动连续；低频推高粒子
/// 尺寸与封面背后的光晕，整体能量决定亮度。
struct ImmersiveParticleField: View {
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    var emitter: UnitPoint
    var count = 150

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            let levels = levelsProvider()
            let bass = ImmersiveSpectrumSummary.bass(levels)
            let energy = ImmersiveSpectrumSummary.energy(levels)
            Canvas(rendersAsynchronously: true) { canvas, size in
                let origin = CGPoint(x: size.width * emitter.x, y: size.height * emitter.y)
                let maxDistance = (size.width * size.width + size.height * size.height).squareRoot() * 0.62
                canvas.blendMode = .plusLighter

                let glowRadius = min(size.width, size.height) * (0.22 + bass * 0.16)
                canvas.fill(
                    Path(ellipseIn: CGRect(
                        x: origin.x - glowRadius,
                        y: origin.y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )),
                    with: .radialGradient(
                        Gradient(colors: [palette.primary.opacity(0.10 + Double(bass) * 0.35), .clear]),
                        center: origin,
                        startRadius: glowRadius * 0.35,
                        endRadius: glowRadius
                    )
                )

                for index in 0..<count {
                    let seedA = ImmersiveSeed.unit(index, salt: 31)
                    let seedB = ImmersiveSeed.unit(index, salt: 32)
                    let seedC = ImmersiveSeed.unit(index, salt: 33)
                    let period: Double = 5.0 + seedA * 7.0
                    let phase: Double = isAnimating
                        ? ImmersiveSeed.wrapped(time / period + seedB)
                        : ImmersiveSeed.wrapped(seedB + 0.3 * seedC)
                    let angle: Double = seedC * 2 * .pi + (isAnimating ? time * 0.03 * (seedA - 0.5) : 0)
                    let distance: CGFloat = CGFloat(pow(phase, 0.8)) * maxDistance * CGFloat(0.35 + seedA * 0.65)
                    let pointX: CGFloat = origin.x + CGFloat(cos(angle)) * distance * 1.08
                    let pointY: CGFloat = origin.y + CGFloat(sin(angle)) * distance * 0.92
                    let point = CGPoint(x: pointX, y: pointY)
                    let fade: Double = (1 - phase) * min(1, phase * 6)
                    let alpha: Double = fade * (0.22 + Double(energy) * 0.62)
                    let radius: CGFloat = CGFloat(0.8 + seedB * 1.8) * (1 + bass * 0.9)
                    let tint = seedA < 0.28 ? palette.primary : ImmersiveStagePalette.ink

                    if seedB > 0.82 {
                        let haloRadius = radius * 3
                        canvas.fill(
                            Path(ellipseIn: CGRect(
                                x: point.x - haloRadius,
                                y: point.y - haloRadius,
                                width: haloRadius * 2,
                                height: haloRadius * 2
                            )),
                            with: .radialGradient(
                                Gradient(colors: [tint.opacity(alpha * 0.45), .clear]),
                                center: point,
                                startRadius: 0,
                                endRadius: haloRadius
                            )
                        )
                    }
                    canvas.fill(
                        Path(ellipseIn: CGRect(
                            x: point.x - radius,
                            y: point.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )),
                        with: .color(tint.opacity(alpha))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 封面随整体能量轻微起伏的圆形封面宿主：缩放与光晕在这一层求值，
/// 不让频谱采样波及整个场景。
struct ImmersivePulsingArtwork<Artwork: View>: View {
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var diameter: CGFloat
    @ViewBuilder var artwork: (CGFloat) -> Artwork

    var body: some View {
        let energy = ImmersiveSpectrumSummary.energy(levelsProvider())
        let bass = ImmersiveSpectrumSummary.bass(levelsProvider())
        artwork(diameter)
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: palette.primary.opacity(0.35 + Double(bass) * 0.45), radius: diameter * (0.10 + bass * 0.08))
            .scaleEffect(1 + energy * 0.035)
            .animation(.easeOut(duration: 0.12), value: energy)
            .frame(width: diameter, height: diameter)
    }
}

// MARK: - 环形声谱的涟漪与能量光晕

/// 从频谱环内缘向外扩散的三圈涟漪，透明度随低频强弱。
struct ImmersiveBassRipples: View {
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    /// 涟漪起点半径相对画布短边一半的占比。
    var startRatio: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isAnimating)) { context in
            let time = isAnimating ? context.date.timeIntervalSinceReferenceDate : 0
            let bass = ImmersiveSpectrumSummary.bass(levelsProvider())
            Canvas(rendersAsynchronously: true) { canvas, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2
                let inner = outer * startRatio
                for index in 0..<3 {
                    let phase = isAnimating
                        ? ImmersiveSeed.wrapped(time / 2.6 + Double(index) / 3)
                        : Double(index) / 3
                    let radius = inner + CGFloat(phase) * (outer - inner)
                    let alpha = (1 - phase) * (0.08 + Double(bass) * 0.5)
                    canvas.stroke(
                        Path(ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )),
                        with: .color(palette.primary.opacity(alpha)),
                        lineWidth: 1 + CGFloat(1 - phase) * 2
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 随整体能量明暗的径向光晕。
struct ImmersiveEnergyGlow: View {
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var center: UnitPoint
    var radius: CGFloat
    var baseOpacity = 0.16
    var reactiveOpacity = 0.40

    var body: some View {
        let energy = ImmersiveSpectrumSummary.energy(levelsProvider())
        RadialGradient(
            colors: [palette.primary.opacity(baseOpacity + Double(energy) * reactiveOpacity), .clear],
            center: center,
            startRadius: 0,
            endRadius: radius
        )
        .allowsHitTesting(false)
    }
}
