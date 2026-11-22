import CoreGraphics
import Foundation
import PrimuseKit
import SwiftUI

// 「水彩小剧场」每一帧的画法（只读 `ImmersiveTheaterFrame`）：背景图按背景镜头摆好，上面描会抖的墨线、
// 月光与路灯光；角色先垫一层错开的淡影和一圈墨色剪影，再把分件按骨骼一件件盖上去，染一点场景的光；
// 道具、粒子、前景的雨和花，最后是闪光与转场。墨线一秒换十二种抖法（`boil`），和原型一样。

// MARK: - 墨线

enum ImmersiveTheaterInk {
    /// 手绘墨线：每个点按这一次的抖法挪一点，相邻两点的中点连成二次曲线；默认再描一笔细一些、淡一些的。
    static func strokes(
        _ points: [CGPoint],
        width: Double,
        seed: Int,
        closed: Bool = false,
        color: ImmersiveTheaterRGB,
        amplitude: Double,
        opacity: Double = 1,
        single: Bool = false,
        boil: Int
    ) -> [ImmersiveTheaterInkStroke] {
        let count = points.count
        guard count > 1 else { return [] }
        var result: [ImmersiveTheaterInkStroke] = []
        for pass in 0..<(single ? 1 : 2) {
            var path = Path()
            var previous = CGPoint.zero
            var first = CGPoint.zero
            let total = count + (closed ? 1 : 0)
            for step in 0..<total {
                let index = step % count
                let point = points[index]
                let dx: Double = ImmersiveTheaterNoise.jitter(boil, seed + pass * 131, index * 2) * amplitude
                let dy: Double = ImmersiveTheaterNoise.jitter(boil, seed + pass * 131, index * 2 + 1) * amplitude
                let moved = CGPoint(x: Double(point.x) + dx, y: Double(point.y) + dy)
                if step == 0 {
                    path.move(to: moved)
                    first = moved
                } else {
                    let middle = CGPoint(x: (previous.x + moved.x) / 2, y: (previous.y + moved.y) / 2)
                    path.addQuadCurve(to: middle, control: previous)
                }
                previous = moved
            }
            if closed {
                path.addQuadCurve(to: first, control: previous)
            } else {
                path.addLine(to: previous)
            }
            result.append(ImmersiveTheaterInkStroke(
                path: path,
                width: CGFloat(pass == 0 ? width : width * 0.42),
                color: color.color,
                opacity: opacity * (pass == 0 ? 0.92 : 0.45)
            ))
        }
        return result
    }

    static func circle(_ x: Double, _ y: Double, _ radius: Double, count: Int = 28, radiusY: Double? = nil) -> [CGPoint] {
        (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * Double.pi
            return CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * (radiusY ?? radius))
        }
    }

    static func star(_ x: Double, _ y: Double, _ radius: Double, points: Int = 5, inner: Double = 0.45, rotation: Double = -Double.pi / 2) -> [CGPoint] {
        (0..<(points * 2)).map { index in
            let r = index % 2 == 1 ? radius * inner : radius
            let angle = rotation + Double(index) * Double.pi / Double(points)
            return CGPoint(x: x + cos(angle) * r, y: y + sin(angle) * r)
        }
    }

    static func heart(_ x: Double, _ y: Double, _ size: Double) -> [CGPoint] {
        (0..<24).map { index in
            let t = Double(index) / 24 * 2 * Double.pi
            let hx: Double = 16 * pow(sin(t), 3)
            let hy: Double = -(13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t))
            return CGPoint(x: x + hx * size / 16, y: y + hy * size / 16)
        }
    }

    static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// 背景上的墨线（世界坐标）：月亮、星星、山脊；楼顶、路灯、地平线、水洼；太阳和光芒。
    static func backSheet(
        layout: ImmersiveTheaterSceneLayout,
        palette: ImmersiveTheaterScenePalette,
        boil: Int,
        time: Double,
        beatPulse: Double,
        beatIndex: Int,
        highOnset: Bool
    ) -> ImmersiveTheaterInkSheet {
        var sheet = ImmersiveTheaterInkSheet()
        let ink = palette.ink
        switch layout.template {
        case .night:
            if let moon = layout.orb {
                sheet.strokes += strokes(circle(moon.x, moon.y, moon.radius, count: 30), width: 3.2, seed: 11, closed: true,
                                         color: ink, amplitude: 1.6, boil: boil)
            }
            for (index, star) in layout.stars.enumerated() {
                let wave: Double = 0.55 + 0.45 * sin(time * (1.3 + star.size) + star.phase * 2 * Double.pi)
                let flare: Double = highOnset && index % 3 == ((beatIndex % 3) + 3) % 3 ? 0.8 : 0
                let radius: Double = 5 + 6 * star.size * min(max(wave + flare, 0.2), 1.6)
                if star.sparkles {
                    sheet.fills.append(ImmersiveTheaterInkFill(
                        path: polygon(Self.star(star.x, star.y, radius, points: 4, inner: 0.32, rotation: 0)),
                        color: palette.star.color,
                        opacity: 0.95
                    ))
                }
                let lineColor = star.sparkles ? ink : palette.star
                sheet.strokes += strokes([CGPoint(x: star.x - radius, y: star.y), CGPoint(x: star.x + radius, y: star.y)],
                                         width: 1.6, seed: 100 + index, color: lineColor, amplitude: 0.6, single: !star.sparkles, boil: boil)
                sheet.strokes += strokes([CGPoint(x: star.x, y: star.y - radius), CGPoint(x: star.x, y: star.y + radius)],
                                         width: 1.6, seed: 200 + index, color: lineColor, amplitude: 0.6, single: !star.sparkles, boil: boil)
            }
            sheet.strokes += strokes(layout.farRidge, width: 2.6, seed: 31, color: ink, amplitude: 1.8, boil: boil)
            sheet.strokes += strokes(layout.nearRidge, width: 3.2, seed: 37, color: ink, amplitude: 1.8, boil: boil)
        case .rain:
            sheet.strokes += strokes(layout.frontSkyline, width: 2.4, seed: 41, color: ink, amplitude: 1.4, boil: boil)
            if let lamp = layout.lamp {
                sheet.strokes += strokes([
                    CGPoint(x: lamp.x - 9, y: lamp.base), CGPoint(x: lamp.x - 9, y: lamp.top),
                    CGPoint(x: lamp.x + 9, y: lamp.top), CGPoint(x: lamp.x + 9, y: lamp.base),
                ], width: 2.6, seed: 43, color: ink, amplitude: 1.2, boil: boil)
                sheet.strokes += strokes(circle(lamp.x, lamp.top - 18, 34, count: 14, radiusY: 26), width: 2.6, seed: 47,
                                         closed: true, color: ink, amplitude: 1.2, boil: boil)
            }
            let rect = layout.world.backdropRect
            let horizon = layout.world.horizon + 8
            sheet.strokes += strokes([CGPoint(x: Double(rect.minX), y: horizon), CGPoint(x: Double(rect.maxX), y: horizon)],
                                     width: 2.2, seed: 49, color: ink, amplitude: 2, boil: boil)
            for (index, puddle) in layout.puddles.enumerated() {
                sheet.strokes += strokes(circle(puddle.x, puddle.y, puddle.rx, count: 20, radiusY: puddle.ry), width: 1.8,
                                         seed: 60 + index, closed: true, color: ink, amplitude: 1.2, opacity: 0.7, boil: boil)
            }
        case .flower:
            if let sun = layout.orb {
                let turn = time * 0.12
                for index in 0..<14 {
                    let angle = turn + Double(index) * 2 * Double.pi / 14
                    let inner = sun.radius * 1.25
                    let outer: Double = sun.radius * (1.62 + (index % 2 == 1 ? 0.12 : 0) + 0.18 * beatPulse)
                    sheet.strokes += strokes([
                        CGPoint(x: sun.x + cos(angle) * inner, y: sun.y + sin(angle) * inner),
                        CGPoint(x: sun.x + cos(angle) * outer, y: sun.y + sin(angle) * outer),
                    ], width: 3, seed: 70 + index, color: ink, amplitude: 1, boil: boil)
                }
                sheet.strokes += strokes(circle(sun.x, sun.y, sun.radius, count: 30), width: 3.2, seed: 13, closed: true,
                                         color: ink, amplitude: 1.6, boil: boil)
            }
            sheet.strokes += strokes(layout.farRidge, width: 2.4, seed: 51, color: ink, amplitude: 1.8, opacity: 0.8, boil: boil)
            sheet.strokes += strokes(layout.nearRidge, width: 3, seed: 53, color: ink, amplitude: 1.8, boil: boil)
        }
        return sheet
    }
}

// MARK: - 画一帧

enum ImmersiveTheaterRenderer {
    static func draw(_ frame: ImmersiveTheaterFrame, in context: inout GraphicsContext) {
        let base = context.transform
        let viewRect = CGRect(origin: .zero, size: frame.size)
        let palette = frame.palette
        context.fill(Path(viewRect), with: .color(palette.paper.color))
        let irisClosing = frame.transition.map { $0.kind == .iris && $0.progress < 0.5 } ?? false

        if let backdrop = frame.backdrop {
            var layer = context
            layer.transform = frame.background.concatenating(base)
            layer.draw(Image(decorative: backdrop.image, scale: 1), in: backdrop.rect)
            if !irisClosing {
                drawSceneBack(backdrop, frame: frame, in: &layer)
            }
        }
        if let transition = frame.transition {
            drawOutgoing(transition, frame: frame, base: base, in: &context)
        }

        var stage = context
        stage.transform = frame.foreground.concatenating(base)
        for figure in frame.actors {
            drawGroundShadow(figure, palette: palette, in: &stage)
        }
        if frame.speedLines > 0.05, let lead = frame.actors.first(where: { $0.member.character == .yuanyin }) {
            drawSpeedLines(lead, progress: frame.speedLines, palette: palette, boil: frame.boil, in: &stage)
        }
        drawCastShadows(frame, base: base, in: &context)
        for figure in frame.actors {
            drawProps(figure, front: false, frame: frame, base: base, in: &context)
            drawFigure(figure, frame: frame, base: base, in: &context)
            drawProps(figure, front: true, frame: frame, base: base, in: &context)
        }
        drawParticles(frame.particles, palette: palette, boil: frame.boil, in: &stage)
        if !irisClosing, let backdrop = frame.backdrop {
            let fade = frame.transition.map { $0.kind == .brush ? min($0.progress * 1.5, 1) : 1 } ?? 1
            drawSceneFront(backdrop, frame: frame, opacity: fade, in: &stage)
        }
        if frame.flash > 0.01 {
            var flash = context
            flash.blendMode = .plusLighter
            flash.fill(Path(viewRect), with: .color(frame.flashColor.color.opacity(min(frame.flash * 0.45, 1))))
        }
        if let transition = frame.transition, transition.kind == .iris {
            drawIris(transition, frame: frame, in: &context)
        }
    }

    // MARK: 背景上的动静

    private static func drawStrokes(_ sheet: ImmersiveTheaterInkSheet, in context: inout GraphicsContext) {
        for fill in sheet.fills {
            context.fill(fill.path, with: .color(fill.color.opacity(fill.opacity)))
        }
        for stroke in sheet.strokes {
            context.stroke(
                stroke.path,
                with: .color(stroke.color.opacity(stroke.opacity)),
                style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private static func drawSceneBack(_ backdrop: ImmersiveTheaterBackdrop, frame: ImmersiveTheaterFrame, in context: inout GraphicsContext) {
        let layout = backdrop.layout
        let palette = backdrop.palette
        switch layout.template {
        case .night:
            if let moon = layout.orb {
                let pulse = frame.beatPulse * 0.5 + frame.high * 0.3
                var glow = context
                glow.blendMode = .plusLighter
                let center = CGPoint(x: moon.x, y: moon.y)
                let outer = moon.radius * (2.4 + pulse)
                glow.fill(
                    Path(ellipseIn: CGRect(x: moon.x - outer, y: moon.y - outer, width: outer * 2, height: outer * 2)),
                    with: .radialGradient(
                        Gradient(colors: [palette.glow.color.opacity(0.25 + 0.15 * pulse), palette.glow.color.opacity(0)]),
                        center: center,
                        startRadius: CGFloat(moon.radius * 0.8),
                        endRadius: CGFloat(outer)
                    )
                )
            }
            if let ink = frame.ink { drawStrokes(ink, in: &context) }
        case .rain:
            if let lamp = layout.lamp {
                let flicker: Double = 0.75 + 0.25 * frame.high
                    + (ImmersiveTheaterNoise.hash3(Int((frame.time * 9).rounded(.down)), 1, 2) < 0.06 ? -0.35 : 0)
                var glow = context
                glow.blendMode = .plusLighter
                let center = CGPoint(x: lamp.x, y: lamp.top - 18)
                glow.fill(
                    Path(ellipseIn: CGRect(x: lamp.x - 260, y: lamp.top - 18 - 260, width: 520, height: 520)),
                    with: .radialGradient(
                        Gradient(colors: [palette.lamp.color.opacity(0.5 * flicker), palette.lamp.color.opacity(0)]),
                        center: center,
                        startRadius: 10,
                        endRadius: 260
                    )
                )
                var cone = Path()
                cone.move(to: CGPoint(x: lamp.x - 26, y: lamp.top))
                cone.addLine(to: CGPoint(x: lamp.x + 26, y: lamp.top))
                cone.addLine(to: CGPoint(x: lamp.x + 190, y: lamp.base + 60))
                cone.addLine(to: CGPoint(x: lamp.x - 190, y: lamp.base + 60))
                cone.closeSubpath()
                glow.fill(cone, with: .linearGradient(
                    Gradient(colors: [palette.lamp.color.opacity(0.22 * flicker), palette.lamp.color.opacity(0.02)]),
                    startPoint: CGPoint(x: lamp.x, y: lamp.top),
                    endPoint: CGPoint(x: lamp.x, y: lamp.base + 60)
                ))
            }
            if let ink = frame.ink { drawStrokes(ink, in: &context) }
            drawRain(frame, palette: palette, front: false, in: &context)
        case .flower:
            if let ink = frame.ink { drawStrokes(ink, in: &context) }
        }
    }

    private static func drawRain(_ frame: ImmersiveTheaterFrame, palette: ImmersiveTheaterScenePalette, front: Bool, in context: inout GraphicsContext) {
        let world = frame.world
        let layer = front ? 1 : 0
        let count = Int(Double(front ? 46 : 80) * (0.45 + 0.7 * frame.intensity) * max(world.width / 1600, 0.6))
        let wind: Double = 0.18 + 0.08 * sin(frame.time * 0.3)
        let span: Double = world.height * 1.28
        let length: Double = front ? 46 : 30
        var path = Path()
        for index in 0..<max(count, 0) {
            let startX: Double = ImmersiveTheaterNoise.hash3(index, layer, 9) * world.width * 1.25 - world.width * 0.125
            let speed: Double = (front ? 1500 : 1000) + ImmersiveTheaterNoise.hash3(index, layer, 4) * 400
            let offset: Double = ImmersiveTheaterNoise.hash3(index, layer, 7) * span
            let y: Double = (frame.time * speed + offset).truncatingRemainder(dividingBy: span) - 120
            let x: Double = startX + y * wind
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + length * wind, y: y + length))
        }
        let color = front ? palette.rain.color.opacity(0.55) : Color(red: 0.78, green: 0.84, blue: 0.92).opacity(0.35)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: front ? 2.2 : 1.4, lineCap: .round))
    }

    private static func drawSceneFront(_ backdrop: ImmersiveTheaterBackdrop, frame: ImmersiveTheaterFrame, opacity: Double, in context: inout GraphicsContext) {
        var layer = context
        layer.opacity = opacity
        let palette = backdrop.palette
        switch backdrop.layout.template {
        case .rain:
            drawRain(frame, palette: palette, front: true, in: &layer)
        case .flower:
            let stem = ImmersiveTheaterRGB(hex: 0x2C4A22)
            for (index, flower) in backdrop.layout.frontFlowers.enumerated() {
                let sway: Double = 0.18 * sin(Double.pi * (frame.beatPosition + flower.phase * 2)) * (0.4 + frame.intensity)
                let headX: Double = flower.x + sin(sway) * 60
                let headY: Double = flower.y - 60 * cos(sway)
                drawStrokes(ImmersiveTheaterInkSheet(strokes: ImmersiveTheaterInk.strokes(
                    [CGPoint(x: flower.x, y: flower.y + 40), CGPoint(x: (flower.x + headX) / 2 + 4, y: (flower.y + headY) / 2),
                     CGPoint(x: headX, y: headY)],
                    width: 2.4, seed: 300 + index, color: stem, amplitude: 1, boil: frame.boil
                )), in: &layer)
                let colors = palette.flowers
                let color = colors.isEmpty ? palette.light : colors[flower.color % colors.count]
                var petals = Path()
                for petal in 0..<5 {
                    let angle = sway + Double(petal) * 2 * Double.pi / 5
                    let px: Double = headX + cos(angle) * flower.size * 0.6
                    let py: Double = headY + sin(angle) * flower.size * 0.6
                    let r: Double = flower.size * 0.46
                    petals.addEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
                }
                layer.fill(petals, with: .color(color.color.opacity(0.9)))
                let core = flower.size * 0.28
                layer.fill(Path(ellipseIn: CGRect(x: headX - core, y: headY - core, width: core * 2, height: core * 2)),
                           with: .color(palette.sun.color))
                drawStrokes(ImmersiveTheaterInkSheet(strokes: ImmersiveTheaterInk.strokes(
                    ImmersiveTheaterInk.circle(headX, headY, flower.size * 1.05, count: 14), width: 2, seed: 400 + index,
                    closed: true, color: palette.ink, amplitude: 1.4, opacity: 0.8, boil: frame.boil
                )), in: &layer)
            }
        case .night:
            break
        }
    }

    // MARK: 转场

    /// 上一个镜头的背景：笔刷一道道擦掉，或者圆形收拢前一直盖着。
    private static func drawOutgoing(
        _ transition: ImmersiveTheaterTransitionFrame,
        frame: ImmersiveTheaterFrame,
        base: CGAffineTransform,
        in context: inout GraphicsContext
    ) {
        let progress = min(max(transition.progress, 0), 1)
        let size = frame.size
        let old = transition.old
        switch transition.kind {
        case .iris:
            guard progress < 0.5 else { return }
            var layer = context
            layer.transform = frame.background.concatenating(base)
            layer.draw(Image(decorative: old.image, scale: 1), in: old.rect)
        case .brush:
            let bands = 5
            let bandHeight = Double(size.height) / Double(bands)
            let width = Double(size.width)
            var heads: [(x: Double, y: Double, progress: Double)] = []
            context.drawLayer { layer in
                layer.transform = frame.background.concatenating(base)
                layer.draw(Image(decorative: old.image, scale: 1), in: old.rect)
                layer.transform = base
                layer.blendMode = .destinationOut
                for band in 0..<bands {
                    let start = Double(band) * 0.11
                    let reach = min(max((progress - start) / 0.5, 0), 1)
                    guard reach > 0 else { continue }
                    let leftToRight = band % 2 == 0
                    let center: Double = (Double(band) + 0.5) * bandHeight
                        + (ImmersiveTheaterNoise.hash3(transition.seed, band, 1) - 0.5) * bandHeight * 0.3
                    let from: Double = leftToRight ? -60 : width + 60
                    let to: Double = leftToRight ? -60 + reach * (width + 120) : width + 60 - reach * (width + 120)
                    let drift: Double = (ImmersiveTheaterNoise.hash3(transition.seed, band, 2) - 0.5) * 10
                    var stroke = Path()
                    stroke.move(to: CGPoint(x: from, y: center))
                    stroke.addLine(to: CGPoint(x: to, y: center + drift))
                    layer.stroke(stroke, with: .color(.black), style: StrokeStyle(lineWidth: CGFloat(bandHeight * 1.25), lineCap: .round))
                    // 笔刷边上的干笔毛刺。
                    for bristle in 0..<7 {
                        let offset: Double = (Double(bristle) / 6 - 0.5) * bandHeight * 1.6
                        let gap = ImmersiveTheaterNoise.hash3(transition.seed + Int((progress * 40).rounded(.down)), band, bristle) < 0.25
                        if gap { continue }
                        let thickness: Double = bandHeight * (0.08 + ImmersiveTheaterNoise.hash3(transition.seed, band, bristle + 9) * 0.1)
                        var line = Path()
                        line.move(to: CGPoint(x: from, y: center + offset))
                        line.addLine(to: CGPoint(x: to, y: center + offset * 1.05))
                        layer.stroke(line, with: .color(.black), style: StrokeStyle(lineWidth: CGFloat(thickness), lineCap: .round))
                    }
                    heads.append((to, center, reach))
                }
            }
            // 笔头那里湿的颜料。
            var wet = context
            wet.transform = base
            for head in heads where head.progress < 1 {
                let rx = bandHeight * 0.25
                let ry = bandHeight * 0.62
                wet.fill(
                    Path(ellipseIn: CGRect(x: head.x - rx, y: head.y - ry, width: rx * 2, height: ry * 2)),
                    with: .color(Color(red: 0.106, green: 0.086, blue: 0.125).opacity(0.18 * (1 - head.progress)))
                )
            }
        }
    }

    private static func drawIris(_ transition: ImmersiveTheaterTransitionFrame, frame: ImmersiveTheaterFrame, in context: inout GraphicsContext) {
        let progress = min(max(transition.progress, 0), 1)
        let size = frame.size
        let focus = transition.focus
        let reachX = max(Double(focus.x), Double(size.width) - Double(focus.x))
        let reachY = max(Double(focus.y), Double(size.height) - Double(focus.y))
        let full = hypot(reachX, reachY) * 1.05
        let closing = progress < 0.5
        let radius = closing ? full * (1 - easeInOut(progress / 0.5)) : full * easeInOut((progress - 0.5) / 0.5)
        var mask = Path(CGRect(origin: .zero, size: size))
        var circle: [CGPoint] = []
        for index in 0..<40 {
            let angle = Double(index) / 40 * 2 * Double.pi
            let wobble = 1 + (ImmersiveTheaterNoise.hash3(frame.boil, index, transition.seed) - 0.5) * 0.06
            let r = max(0, radius * wobble)
            circle.append(CGPoint(x: Double(focus.x) + cos(angle) * r, y: Double(focus.y) + sin(angle) * r))
        }
        mask.addPath(ImmersiveTheaterInk.polygon(circle))
        context.fill(mask, with: .color(Color(red: 0.09, green: 0.078, blue: 0.11)), style: FillStyle(eoFill: true))
    }

    private static func easeInOut(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    // MARK: 角色

    private static func drawGroundShadow(_ figure: ImmersiveTheaterActorFrame, palette: ImmersiveTheaterScenePalette, in context: inout GraphicsContext) {
        let scale = figure.slot.scale
        let pose = figure.pose
        let x: Double = figure.slot.x + pose.shadowShift * scale
        let air = pose.airborne
        let rx: Double = (270 + 260 * pose.lie) * scale * (1 - 0.45 * air)
        let ry: Double = 46 * scale * (1 - 0.4 * air)
        for ring in 0..<3 {
            let shrinkX = 1 - Double(ring) * 0.12
            let shrinkY = 1 - Double(ring) * 0.1
            let cx = x + Double(ring - 1) * 4
            context.fill(
                Path(ellipseIn: CGRect(x: cx - rx * shrinkX, y: figure.slot.y + 2 - ry * shrinkY, width: rx * 2 * shrinkX, height: ry * 2 * shrinkY)),
                with: .color(palette.shadow.color.opacity(0.11 * (1 - air * 0.6)))
            )
        }
    }

    private static func drawSpeedLines(
        _ lead: ImmersiveTheaterActorFrame,
        progress: Double,
        palette: ImmersiveTheaterScenePalette,
        boil: Int,
        in context: inout GraphicsContext
    ) {
        let cx = lead.slot.x
        let cy = lead.slot.y - 190
        var sheet = ImmersiveTheaterInkSheet()
        for index in 0..<18 {
            let angle = Double(index) / 18 * 2 * Double.pi + 0.2
            let inner: Double = 230 + 30 * ImmersiveTheaterNoise.jitter(boil, 900 + index, 1)
            let outer: Double = inner + 40 + 90 * progress
            sheet.strokes += ImmersiveTheaterInk.strokes(
                [CGPoint(x: cx + cos(angle) * inner, y: cy + sin(angle) * inner * 0.8),
                 CGPoint(x: cx + cos(angle) * outer, y: cy + sin(angle) * outer * 0.8)],
                width: 2.4, seed: 950 + index, color: palette.ink, amplitude: 1.6,
                opacity: 0.35 + 0.5 * progress, single: true, boil: boil
            )
        }
        drawStrokes(sheet, in: &context)
    }

    /// 视口里一个世界单位有多少点（含镜头推近）。
    private static func viewUnit(_ frame: ImmersiveTheaterFrame) -> Double {
        let transform = frame.foreground
        return max(Double(hypot(transform.a, transform.b)), 0.01)
    }

    /// 所有角色错开的那一块淡影画在同一层里，叠在一起的部件不会更深。
    private static func drawCastShadows(_ frame: ImmersiveTheaterFrame, base: CGAffineTransform, in context: inout GraphicsContext) {
        guard !frame.actors.isEmpty else { return }
        let unit = viewUnit(frame)
        let offset = CGAffineTransform(translationX: 5 * unit, y: 4 * unit)
        var shadow = context
        shadow.opacity = 0.2
        shadow.drawLayer { layer in
            for figure in frame.actors {
                let toView = figure.viewTransform.concatenating(base)
                for item in figure.puppet.drawList(for: figure.pose.expression) {
                    guard let sprite = figure.puppet.sprites[item.part], sprite.castsShadow, let outline = sprite.outline,
                          figure.bones.indices.contains(item.bone) else { continue }
                    layer.transform = figure.bones[item.bone].concatenating(toView).concatenating(offset)
                    layer.draw(Image(decorative: outline, scale: 1), in: sprite.outlineRect)
                }
            }
        }
    }

    private static func drawFigure(
        _ figure: ImmersiveTheaterActorFrame,
        frame: ImmersiveTheaterFrame,
        base: CGAffineTransform,
        in context: inout GraphicsContext
    ) {
        let puppet = figure.puppet
        let items = puppet.drawList(for: figure.pose.expression)
        let toView = figure.viewTransform.concatenating(base)
        let unit = viewUnit(frame)
        // 外描边：墨色剪影一秒换十二次位置，像手描的线在抖。
        let seed = figure.member.character.hashSeed
        let jitter = CGAffineTransform(
            translationX: ImmersiveTheaterNoise.jitter(frame.boil, seed, 1) * 0.6 * unit,
            y: ImmersiveTheaterNoise.jitter(frame.boil, seed, 2) * 0.6 * unit
        )
        var outline = context
        outline.opacity = 0.95
        for item in items {
            guard let sprite = puppet.sprites[item.part], let silhouette = sprite.outline,
                  figure.bones.indices.contains(item.bone) else { continue }
            outline.transform = figure.bones[item.bone].concatenating(toView).concatenating(jitter)
            outline.draw(Image(decorative: silhouette, scale: 1), in: sprite.outlineRect)
        }
        // 部件本身：乘一点场景的光，夜里偏冷、花田里偏暖。
        var body = context
        let palette = frame.palette
        let tint = ImmersiveTheaterRGB(1, 1, 1).mixed(with: palette.tint, min(palette.tintAlpha * 1.5, 1))
        body.addFilter(.colorMultiply(tint.color))
        for item in items {
            guard let sprite = puppet.sprites[item.part], figure.bones.indices.contains(item.bone) else { continue }
            body.opacity = item.alpha
            body.transform = figure.bones[item.bone].concatenating(toView)
            body.draw(Image(decorative: sprite.image, scale: 1), in: sprite.rect)
        }
        body.opacity = 1
        drawFaceExtras(figure, palette: palette, time: frame.time, toView: toView, in: &body)
    }

    /// 画在头上的：眼泪、汗珠、鼻涕泡（母版坐标）。
    private static func drawFaceExtras(
        _ figure: ImmersiveTheaterActorFrame,
        palette: ImmersiveTheaterScenePalette,
        time: Double,
        toView: CGAffineTransform,
        in context: inout GraphicsContext
    ) {
        let pose = figure.pose
        let puppet = figure.puppet
        let headIndex = puppet.bone(named: "head")
        guard figure.bones.indices.contains(headIndex) else { return }
        var head = context
        head.transform = figure.bones[headIndex].concatenating(toView)
        if pose.expression.tears {
            for from in puppet.tearFrom {
                let wobble = sin(time * 6 + Double(from.x)) * 10
                var path = Path()
                path.move(to: from)
                path.addQuadCurve(
                    to: CGPoint(x: from.x - 6, y: from.y + 150),
                    control: CGPoint(x: Double(from.x) + wobble, y: Double(from.y) + 70)
                )
                head.stroke(path, with: .color(Color(red: 0.486, green: 0.769, blue: 0.949).opacity(0.75)),
                            style: StrokeStyle(lineWidth: 26, lineCap: .round))
            }
        }
        if pose.expression.sweat {
            let top = puppet.anchor("headTop")
            let x = Double(top.x) + 330
            let y = Double(top.y) + 320
            var drop = Path()
            drop.move(to: CGPoint(x: x, y: y - 70))
            drop.addQuadCurve(to: CGPoint(x: x, y: y + 40), control: CGPoint(x: x + 50, y: y))
            drop.addQuadCurve(to: CGPoint(x: x, y: y - 70), control: CGPoint(x: x - 50, y: y))
            head.fill(drop, with: .color(Color(red: 0.624, green: 0.847, blue: 1)))
            head.stroke(drop, with: .color(palette.ink.color), lineWidth: 12)
        }
        if let bubble = pose.props.bubble, figure.member.character == .yuanyin {
            let radius = 30 + 55 * bubble
            let center = CGPoint(x: 860, y: 830 + radius * 0.4)
            let circle = Path(ellipseIn: CGRect(x: Double(center.x) - radius, y: Double(center.y) - radius, width: radius * 2, height: radius * 2))
            head.fill(circle, with: .color(Color(red: 0.847, green: 0.937, blue: 1).opacity(0.55)))
            head.stroke(circle, with: .color(palette.ink.color), lineWidth: 9)
            let shine = radius * 0.18
            head.fill(Path(ellipseIn: CGRect(x: Double(center.x) - radius * 0.35 - shine, y: Double(center.y) - radius * 0.05 - shine,
                                             width: shine * 2, height: shine * 2)), with: .color(.white))
        }
    }

    // MARK: 道具

    private static func point(_ figure: ImmersiveTheaterActorFrame, bone: String, _ point: CGPoint, world: Bool) -> CGPoint {
        let index = figure.puppet.bone(named: bone)
        let boneTransform = figure.bones.indices.contains(index) ? figure.bones[index] : .identity
        return point.applying(boneTransform.concatenating(world ? figure.worldTransform : figure.viewTransform))
    }

    private static func drawProps(
        _ figure: ImmersiveTheaterActorFrame,
        front: Bool,
        frame: ImmersiveTheaterFrame,
        base: CGAffineTransform,
        in context: inout GraphicsContext
    ) {
        let props = figure.pose.props
        let palette = frame.palette
        let boil = frame.boil
        let ink = palette.ink
        let accent = palette.accent(0)
        var character = context
        character.transform = figure.viewTransform.concatenating(base)

        if props.drums, front {
            let kick = 1 + 0.05 * props.drumKick
            let bass = CGRect(x: 800 - 235 * kick, y: 1290 - 178 * kick, width: 470 * kick, height: 356 * kick)
            character.fill(Path(ellipseIn: bass), with: .color(accent.mixed(with: ImmersiveTheaterRGB(1, 1, 1), 0.15).color))
            let skin = CGRect(x: 800 - 175 * kick, y: 1290 - 128 * kick, width: 350 * kick, height: 256 * kick)
            character.fill(Path(ellipseIn: skin), with: .color(ImmersiveTheaterRGB(hex: 0xFBF3E6).color))
            var lines = ImmersiveTheaterInkSheet()
            lines.strokes += ImmersiveTheaterInk.strokes(ImmersiveTheaterInk.circle(800, 1290, 235 * kick, count: 26, radiusY: 178 * kick),
                                                         width: 14, seed: 801, closed: true, color: ink, amplitude: 4, boil: boil)
            lines.strokes += ImmersiveTheaterInk.strokes(ImmersiveTheaterInk.circle(800, 1290, 175 * kick, count: 22, radiusY: 128 * kick),
                                                         width: 9, seed: 802, closed: true, color: ink, amplitude: 3, boil: boil)
            let hit = 1 + 0.08 * props.drumHit
            character.fill(Path(CGRect(x: 360, y: 1120, width: 220, height: 70)), with: .color(ImmersiveTheaterRGB(hex: 0xE9E2D6).color))
            character.fill(Path(ellipseIn: CGRect(x: 470 - 112 * hit, y: 1120 - 34 * hit, width: 224 * hit, height: 68 * hit)),
                           with: .color(ImmersiveTheaterRGB(hex: 0xF7F1E6).color))
            lines.strokes += ImmersiveTheaterInk.strokes(ImmersiveTheaterInk.circle(470, 1120, 112 * hit, count: 20, radiusY: 34 * hit),
                                                         width: 9, seed: 803, closed: true, color: ink, amplitude: 3, boil: boil)
            lines.strokes += ImmersiveTheaterInk.strokes([CGPoint(x: 360, y: 1122), CGPoint(x: 360, y: 1190), CGPoint(x: 580, y: 1190), CGPoint(x: 580, y: 1122)],
                                                         width: 9, seed: 804, color: ink, amplitude: 3, boil: boil)
            lines.strokes += ImmersiveTheaterInk.strokes([CGPoint(x: 470, y: 1190), CGPoint(x: 470, y: 1460)],
                                                         width: 8, seed: 805, color: ink, amplitude: 3, boil: boil)
            let tilt: Double = 0.12 * sin(frame.time * 18) * props.drumHit
            let cymbal = ImmersiveTheaterInk.circle(1150, 950, 130, count: 20, radiusY: 24).map { p in
                CGPoint(x: Double(p.x), y: Double(p.y) + (Double(p.x) - 1150) * tilt)
            }
            character.fill(ImmersiveTheaterInk.polygon(cymbal), with: .color(ImmersiveTheaterRGB(hex: 0xF2C94C).color))
            lines.strokes += ImmersiveTheaterInk.strokes(cymbal, width: 9, seed: 806, closed: true, color: ink, amplitude: 3, boil: boil)
            lines.strokes += ImmersiveTheaterInk.strokes([CGPoint(x: 1150, y: 960), CGPoint(x: 1150, y: 1460)],
                                                         width: 8, seed: 807, color: ink, amplitude: 3, boil: boil)
            drawStrokes(lines, in: &character)
            character.draw(
                Text(verbatim: "P")
                    .font(.system(size: 120, weight: .heavy, design: .rounded))
                    .foregroundStyle(accent.mixed(with: ink, 0.3).color),
                at: CGPoint(x: 800, y: 1295)
            )
        }
        if props.mill, (cos(props.millTheta) < 0) == front {
            drawMill(theta: props.millTheta, ink: ink, boil: boil, in: &character)
        }
        guard front else { return }
        if props.umbrella {
            drawUmbrella(figure, palette: palette, boil: boil, base: base, frame: frame, in: &context)
        }
        if props.carrot {
            drawCarrot(figure, time: frame.time, ink: ink, boil: boil, base: base, in: &context)
        }
        if props.cast {
            let potion = point(figure, bone: "potion", CGPoint(x: 1060, y: 1300), world: false).applying(base)
            let radius: Double = 90 * viewUnit(frame) * figure.slot.scale / 0.21 * (0.8 + 0.4 * props.glow)
            var glow = context
            glow.transform = .identity
            glow.blendMode = .plusLighter
            glow.fill(
                Path(ellipseIn: CGRect(x: Double(potion.x) - radius, y: Double(potion.y) - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 0.82, green: 1, blue: 0.75).opacity(0.85), location: 0),
                        .init(color: palette.accent(2).color.opacity(0.45), location: 0.4),
                        .init(color: palette.accent(2).color.opacity(0), location: 1),
                    ]),
                    center: potion,
                    startRadius: 0,
                    endRadius: CGFloat(radius)
                )
            )
        }
        if props.airGuitar {
            let hand = point(figure, bone: "handR", CGPoint(x: 1052, y: 1240), world: true)
            var stage = context
            stage.transform = frame.foreground.concatenating(base)
            var sheet = ImmersiveTheaterInkSheet()
            for ring in 0..<3 {
                let radius = (28 + Double(ring) * 14) * figure.slot.scale / 0.27
                let startAngle = -0.6 + Double(ring) * 0.1
                let arc: [CGPoint] = (0...6).map { step in
                    let angle = startAngle + Double(step) / 6 * 1.2
                    return CGPoint(x: Double(hand.x) + 30 * figure.slot.scale / 0.27 + cos(angle) * radius,
                                   y: Double(hand.y) + sin(angle) * radius)
                }
                sheet.strokes += ImmersiveTheaterInk.strokes(arc, width: 2.2, seed: 850 + ring, color: ink, amplitude: 1.2,
                                                             opacity: 0.8, single: true, boil: boil)
            }
            drawStrokes(sheet, in: &stage)
        }
    }

    private static func drawMill(theta: Double, ink: ImmersiveTheaterRGB, boil: Int, in context: inout GraphicsContext) {
        let cx = 800.0
        let cy = 1400.0
        let rx = 300.0
        let ry = 90.0
        let height = 130.0
        var stone = Path(CGRect(x: cx - rx, y: cy - height, width: rx * 2, height: height))
        stone.addPath(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)))
        context.fill(stone, with: .color(ImmersiveTheaterRGB(hex: 0x9A948B).color))
        context.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - height - ry, width: rx * 2, height: ry * 2)),
                     with: .color(ImmersiveTheaterRGB(hex: 0xC9C3B8).color))
        var sheet = ImmersiveTheaterInkSheet()
        sheet.strokes += ImmersiveTheaterInk.strokes(ImmersiveTheaterInk.circle(cx, cy - height, rx, count: 26, radiusY: ry),
                                                     width: 12, seed: 811, closed: true, color: ink, amplitude: 4, boil: boil)
        let lower = ImmersiveTheaterInk.circle(cx, cy, rx, count: 26, radiusY: ry)
            .filter { Double($0.y) >= cy }
            .sorted { $0.x < $1.x }
        sheet.strokes += ImmersiveTheaterInk.strokes(
            [CGPoint(x: cx - rx, y: cy - height), CGPoint(x: cx - rx, y: cy)] + lower + [CGPoint(x: cx + rx, y: cy), CGPoint(x: cx + rx, y: cy - height)],
            width: 12, seed: 812, color: ink, amplitude: 4, boil: boil
        )
        let endX = cx + 360 * sin(theta)
        let endY = cy - height - 40 + 30 * cos(theta)
        sheet.strokes += ImmersiveTheaterInk.strokes([CGPoint(x: cx, y: cy - height - 20), CGPoint(x: endX, y: endY - 330)],
                                                     width: 14, seed: 813, color: ImmersiveTheaterRGB(hex: 0x6B4A2B), amplitude: 3, boil: boil)
        sheet.strokes += ImmersiveTheaterInk.strokes([CGPoint(x: cx, y: cy - height - 40), CGPoint(x: cx, y: cy - height - 20)],
                                                     width: 30, seed: 814, color: ink, amplitude: 2, boil: boil)
        drawStrokes(sheet, in: &context)
    }

    private static func drawUmbrella(
        _ figure: ImmersiveTheaterActorFrame,
        palette: ImmersiveTheaterScenePalette,
        boil: Int,
        base: CGAffineTransform,
        frame: ImmersiveTheaterFrame,
        in context: inout GraphicsContext
    ) {
        let hand = point(figure, bone: "handR", CGPoint(x: 1052, y: 1240), world: true)
        let top = point(figure, bone: "head", CGPoint(x: 800, y: 60), world: true)
        let radius: Double = 165 * figure.slot.scale / 0.27
        let handX = Double(hand.x)
        let handY = Double(hand.y)
        let topX = Double(top.x)
        let topY = Double(top.y)
        let cx: Double = min(max(handX, topX - radius * 0.35), topX + radius * 0.45)
        let cy: Double = min(topY - 20, handY - 60)
        var canopy: [CGPoint] = []
        for step in 0...20 {
            let angle = Double.pi + Double(step) / 20 * Double.pi
            canopy.append(CGPoint(x: cx + cos(angle) * radius, y: cy + sin(angle) * radius * 0.75))
        }
        for step in stride(from: 6, through: 0, by: -1) {
            canopy.append(CGPoint(x: cx - radius + Double(step) / 6 * 2 * radius, y: cy + (step % 2 == 1 ? -10 : 0)))
        }
        var stage = context
        stage.transform = frame.foreground.concatenating(base)
        var sheet = ImmersiveTheaterInkSheet()
        sheet.strokes += ImmersiveTheaterInk.strokes([hand, CGPoint(x: cx, y: cy)], width: 4, seed: 821, color: palette.ink, amplitude: 1, boil: boil)
        stage.fill(ImmersiveTheaterInk.polygon(canopy), with: .color(palette.accent(1).color.opacity(0.95)))
        sheet.strokes += ImmersiveTheaterInk.strokes(canopy, width: 3.4, seed: 822, closed: true, color: palette.ink, amplitude: 1.2, boil: boil)
        sheet.strokes += ImmersiveTheaterInk.strokes([CGPoint(x: cx, y: cy - radius * 0.75), CGPoint(x: cx, y: cy - radius * 0.75 - 14)],
                                                     width: 3, seed: 823, color: palette.ink, amplitude: 0.6, boil: boil)
        drawStrokes(sheet, in: &stage)
    }

    private static func drawCarrot(
        _ figure: ImmersiveTheaterActorFrame,
        time: Double,
        ink: ImmersiveTheaterRGB,
        boil: Int,
        base: CGAffineTransform,
        in context: inout GraphicsContext
    ) {
        let headIndex = figure.puppet.bone(named: "head")
        guard figure.bones.indices.contains(headIndex) else { return }
        let mouth = figure.puppet.anchor("mouthPt")
        let chew = 0.08 * sin(time * 7)
        let local = CGAffineTransform(rotationAngle: 0.45 + chew)
            .concatenating(CGAffineTransform(translationX: mouth.x, y: mouth.y))
        var carrot = context
        carrot.transform = local.concatenating(figure.bones[headIndex]).concatenating(figure.viewTransform).concatenating(base)
        let body = [CGPoint(x: 0, y: -34), CGPoint(x: 250, y: -4), CGPoint(x: 262, y: 4), CGPoint(x: 0, y: 34)]
        carrot.fill(ImmersiveTheaterInk.polygon(body), with: .color(ImmersiveTheaterRGB(hex: 0xF08A2C).color))
        var sheet = ImmersiveTheaterInkSheet()
        sheet.strokes += ImmersiveTheaterInk.strokes(body, width: 12, seed: 831, closed: true, color: ink, amplitude: 3, boil: boil)
        for notch in 0..<3 {
            sheet.strokes += ImmersiveTheaterInk.strokes(
                [CGPoint(x: 60 + Double(notch) * 60, y: -22 + Double(notch) * 6), CGPoint(x: 70 + Double(notch) * 60, y: -2)],
                width: 7, seed: 832 + notch, color: ink, amplitude: 2, single: true, boil: boil
            )
        }
        for leaf in -1...1 {
            let points = [CGPoint(x: -10, y: 0), CGPoint(x: -90, y: Double(leaf) * 50 - 20), CGPoint(x: -60, y: Double(leaf) * 40), CGPoint(x: -10, y: 0)]
            carrot.fill(ImmersiveTheaterInk.polygon(points), with: .color(ImmersiveTheaterRGB(hex: 0x5AA34A).color))
            sheet.strokes += ImmersiveTheaterInk.strokes(points, width: 8, seed: 840 + leaf, closed: true, color: ink, amplitude: 2, boil: boil)
        }
        drawStrokes(sheet, in: &carrot)
    }

    // MARK: 粒子

    private static func drawParticles(
        _ particles: [ImmersiveTheaterParticle],
        palette: ImmersiveTheaterScenePalette,
        boil: Int,
        in context: inout GraphicsContext
    ) {
        for particle in particles {
            let progress = particle.age / max(particle.life, 0.01)
            let fade = progress > 0.75 ? 1 - (progress - 0.75) / 0.25 : 1
            var layer = context
            switch particle.kind {
            case .confetti:
                let squeeze = cos(particle.age * 9 + Double(particle.seed))
                layer.translateBy(x: particle.x, y: particle.y)
                layer.rotate(by: .radians(particle.rotation))
                layer.scaleBy(x: CGFloat(abs(squeeze) < 0.05 ? 0.05 : squeeze), y: 1)
                layer.opacity = fade
                let size = particle.size
                layer.fill(Path(CGRect(x: -size * 5, y: -size * 3, width: size * 10, height: size * 6)), with: .color(particle.color.color))
            case .star:
                let radius = particle.size * (progress < 0.15 ? progress / 0.15 : 1) * 14
                let points = ImmersiveTheaterInk.star(particle.x, particle.y, radius, rotation: particle.rotation)
                layer.opacity = fade
                layer.fill(ImmersiveTheaterInk.polygon(points), with: .color(particle.color.color))
                drawStrokes(ImmersiveTheaterInkSheet(strokes: ImmersiveTheaterInk.strokes(
                    points, width: 2.2, seed: particle.seed, closed: true, color: palette.ink, amplitude: 0.8, boil: boil
                )), in: &layer)
            case .heart:
                let size = particle.size * 15 * (0.6 + 0.4 * min(1, progress * 4))
                let points = ImmersiveTheaterInk.heart(particle.x + sin(particle.age * 3 + Double(particle.seed)) * 6, particle.y, size)
                layer.opacity = fade
                layer.fill(ImmersiveTheaterInk.polygon(points), with: .color(particle.color.color.opacity(0.85)))
                drawStrokes(ImmersiveTheaterInkSheet(strokes: ImmersiveTheaterInk.strokes(
                    points, width: 2, seed: particle.seed, closed: true, color: palette.ink, amplitude: 0.7, boil: boil
                )), in: &layer)
            case .note:
                drawNote(particle, fade: fade, palette: palette, boil: boil, in: &layer)
            case let .text(text):
                let size = particle.size * (particle.grows ? 0.7 + 0.6 * progress : 1)
                layer.translateBy(x: particle.x, y: particle.y)
                layer.rotate(by: .radians(particle.rotation))
                layer.opacity = fade
                let font = Font.system(size: CGFloat(size), weight: .heavy, design: .rounded)
                let halo = size * 0.06
                for (dx, dy) in [(halo, 0.0), (-halo, 0.0), (0.0, halo), (0.0, -halo)] {
                    layer.draw(Text(verbatim: text).font(font).foregroundStyle(Color(red: 1, green: 0.98, blue: 0.94)),
                               at: CGPoint(x: dx, y: dy))
                }
                layer.draw(Text(verbatim: text).font(font).foregroundStyle(particle.color.color), at: .zero)
            case .drop:
                let size = particle.size * 7
                var drop = Path()
                drop.move(to: CGPoint(x: particle.x, y: particle.y - size * 1.6))
                drop.addQuadCurve(to: CGPoint(x: particle.x, y: particle.y + size * 0.8), control: CGPoint(x: particle.x + size, y: particle.y - size * 0.2))
                drop.addQuadCurve(to: CGPoint(x: particle.x, y: particle.y - size * 1.6), control: CGPoint(x: particle.x - size, y: particle.y - size * 0.2))
                layer.fill(drop, with: .color(particle.color.color.opacity(0.85 * fade)))
            case .orb:
                let radius = particle.size * (18 + 30 * progress)
                layer.blendMode = .plusLighter
                layer.fill(
                    Path(ellipseIn: CGRect(x: particle.x - radius, y: particle.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(
                        Gradient(colors: [particle.color.color.opacity(0.55 * fade), particle.color.color.opacity(0)]),
                        center: CGPoint(x: particle.x, y: particle.y),
                        startRadius: 0,
                        endRadius: CGFloat(radius)
                    )
                )
            case .spark:
                let radius = particle.size * 10 * (1 - progress * 0.5)
                var sheet = ImmersiveTheaterInkSheet()
                sheet.strokes += ImmersiveTheaterInk.strokes([CGPoint(x: particle.x - radius, y: particle.y), CGPoint(x: particle.x + radius, y: particle.y)],
                                                             width: 2.4, seed: particle.seed, color: particle.color, amplitude: 0.5,
                                                             opacity: fade, single: true, boil: boil)
                sheet.strokes += ImmersiveTheaterInk.strokes([CGPoint(x: particle.x, y: particle.y - radius), CGPoint(x: particle.x, y: particle.y + radius)],
                                                             width: 2.4, seed: particle.seed + 1, color: particle.color, amplitude: 0.5,
                                                             opacity: fade, single: true, boil: boil)
                drawStrokes(sheet, in: &layer)
            case .dust:
                let radius = particle.size * (6 + 18 * progress)
                drawStrokes(ImmersiveTheaterInkSheet(strokes: ImmersiveTheaterInk.strokes(
                    ImmersiveTheaterInk.circle(particle.x, particle.y, radius, count: 10, radiusY: radius * 0.7),
                    width: 1.6, seed: particle.seed, closed: true, color: palette.ink, amplitude: 1.2, opacity: 0.6 * (1 - progress), boil: boil
                )), in: &layer)
            case .petal:
                layer.translateBy(x: particle.x, y: particle.y)
                layer.rotate(by: .radians(particle.rotation))
                layer.scaleBy(x: 1, y: CGFloat(abs(cos(particle.age * 2 + Double(particle.seed))) * 0.8 + 0.2))
                let size = particle.size
                layer.fill(Path(ellipseIn: CGRect(x: -7 * size, y: -4 * size, width: 14 * size, height: 8 * size)),
                           with: .color(particle.color.color.opacity(0.85 * fade)))
            case .ripple:
                let radius = particle.size * (10 + 60 * progress)
                drawStrokes(ImmersiveTheaterInkSheet(strokes: ImmersiveTheaterInk.strokes(
                    ImmersiveTheaterInk.circle(particle.x, particle.y, radius, count: 18, radiusY: radius * 0.22),
                    width: 1.4, seed: particle.seed, closed: true, color: particle.color, amplitude: 0.8,
                    opacity: 0.7 * (1 - progress), single: true, boil: boil
                )), in: &layer)
            case .meteor:
                let tailX = particle.x - particle.vx * 0.12
                let tailY = particle.y - particle.vy * 0.12
                drawStrokes(ImmersiveTheaterInkSheet(strokes: ImmersiveTheaterInk.strokes(
                    [CGPoint(x: tailX, y: tailY), CGPoint(x: (tailX + particle.x) / 2, y: (tailY + particle.y) / 2), CGPoint(x: particle.x, y: particle.y)],
                    width: 3, seed: particle.seed, color: particle.color, amplitude: 0.6, opacity: fade, boil: boil
                )), in: &layer)
            }
        }
    }

    /// 音符借水彩绘本里画好的那几种抖法。
    private static func drawNote(
        _ particle: ImmersiveTheaterParticle,
        fade: Double,
        palette: ImmersiveTheaterScenePalette,
        boil: Int,
        in context: inout GraphicsContext
    ) {
        let glyphs = ImmersiveWatercolorGlyphs.all
        guard let variants = glyphs.first, !variants.isEmpty else { return }
        let glyph = variants[((boil + particle.seed) % variants.count + variants.count) % variants.count]
        let extent = 34 * particle.size
        let cosine = cos(particle.rotation)
        let sine = sin(particle.rotation)
        func place(_ point: CGPoint) -> CGPoint {
            let x = Double(point.x) * extent
            let y = Double(point.y) * extent
            return CGPoint(x: particle.x + x * cosine - y * sine, y: particle.y + x * sine + y * cosine)
        }
        var layer = context
        layer.opacity = fade
        for fill in glyph.fills {
            layer.fill(ImmersiveTheaterInk.polygon(fill.map(place)), with: .color(palette.ink.color))
        }
        for stroke in glyph.strokes {
            var path = Path()
            path.addLines(stroke.map(place))
            layer.stroke(path, with: .color(palette.ink.color), style: StrokeStyle(lineWidth: CGFloat(extent * 0.07), lineCap: .round, lineJoin: .round))
        }
    }
}

extension ImmersiveTheaterCharacter {
    /// 每个角色自己的抖动种子。
    var hashSeed: Int {
        switch self {
        case .yuanyin: 401
        case .xiaohei: 503
        case .ajiu: 607
        case .xiaohuolv: 709
        }
    }
}
