import Foundation
import PrimuseKit
import SwiftUI

// 画面来自一段持续运行的模拟的沉浸层：克拉尼沙画。模拟本身（沙子怎么走、鼓点怎么找）
// 在 PrimuseKit，这里只负责逐帧推进和画。
//
// 和 ImmersiveStageRenderers.swift 一样同时编进 Primuse(iOS)、PrimuseMac 与 PrimuseTV。
// 模拟状态放在 @State 持有的引用里，在 TimelineView 的内容闭包（主线程）里推进，
// 推进完拷一份值给 Canvas，Canvas 异步绘制时不碰会变的状态。

// MARK: - 克拉尼沙画

/// 克拉尼沙画的模拟宿主：频谱 → 鼓点与重心 → 沙子走一步。暂停、减少动态效果或省电时停在原处，
/// 沙子就像板子停振那样静静躺着。
@MainActor
final class ImmersiveChladniModel {
    struct Frame {
        var xs: [Double] = []
        var ys: [Double] = []
        var agitation: [Double] = []
        var mode = ChladniPlate.modes[0]
    }

    private var simulation: ChladniSandSimulation?
    private var tracker = ImmersiveBeatTracker()
    private var lastTime: TimeInterval?
    private var songSeed: UInt64?

    func frame(time: TimeInterval, levels: [CGFloat], songKey: String, grainCount: Int, advances: Bool) -> Frame {
        let seed = ImmersiveRandom.seed(for: songKey)
        let samples = levels.map { Double($0) }
        let features = tracker.update(levels: samples, at: time)

        if simulation == nil || needsRebuild(for: grainCount) {
            simulation = ChladniSandSimulation(count: grainCount, seed: 0xC1AD_1A, songSeed: seed)
            songSeed = seed
            lastTime = nil
        }
        guard var current = simulation else { return Frame() }
        // 先放手再改：两处同时持有时每一步都会把整组坐标复制一遍。
        simulation = nil
        if songSeed != seed {
            songSeed = seed
            current.changeSong(seed: seed, centroid: features.centroid)
        }
        if advances {
            let dt = lastTime.map { time - $0 } ?? 0
            current.step(dt: dt, centroid: features.centroid, drive: features.energy, kick: features.beat)
            lastTime = time
        } else {
            lastTime = nil
        }
        simulation = current
        return Frame(xs: current.xs, ys: current.ys, agitation: current.agitation, mode: current.mode)
    }

    /// 转屏、换视口后沙子数差得多才重新撒；差一点就沿用，免得一转屏花纹就重来。
    private func needsRebuild(for grainCount: Int) -> Bool {
        guard let simulation else { return true }
        let existing = simulation.xs.count
        return abs(existing - grainCount) > max(existing, grainCount) * 3 / 10
    }
}

/// 一块振动的方形金属板，上面撒满细沙。频谱重心与响度挑振动模式（花纹），沙子顺着流到节线上；
/// 鼓点让振幅大的地方的沙粒蹦起来。板角标出当前的模式 (m, n)。
struct ImmersiveChladniPlate: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    /// 换歌时换一组花纹；同一首歌的种子固定。
    var songKey: String
    var side: CGFloat
    var labelSize: CGFloat

    @State private var model = ImmersiveChladniModel()

    /// 节线是一维的，沙粒数跟边长成正比，线上的疏密在各种尺寸下差不多。
    private var grainCount: Int {
        min(max(Int(side * 8), 900), 6000)
    }

    var body: some View {
        let radius = max(side * 0.014, 2)
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.13, green: 0.135, blue: 0.16),
                            ImmersiveStagePalette.obsidian,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    // 金属板上一道很淡的斜向反光。
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0), location: 0.25),
                            .init(color: .white.opacity(0.05), location: 0.45),
                            .init(color: .white.opacity(0), location: 0.62),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.13), lineWidth: 1)
                }
                .shadow(color: palette.primary.opacity(0.28), radius: side * 0.05)

            TimelineView(.animation(
                minimumInterval: frameRate.minimumInterval(base: 1.0 / 24),
                paused: !isAnimating
            )) { context in
                let frame = model.frame(
                    time: context.date.timeIntervalSinceReferenceDate,
                    levels: levelsProvider(),
                    songKey: songKey,
                    grainCount: grainCount,
                    advances: isAnimating
                )
                ZStack(alignment: .bottomLeading) {
                    sand(frame)
                    Text(verbatim: "m \(frame.mode.m) · n \(frame.mode.n)")
                        .font(.system(size: labelSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(ImmersiveStagePalette.text.opacity(0.42))
                        .padding(side * 0.03)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    private func sand(_ frame: ImmersiveChladniModel.Frame) -> some View {
        Canvas(rendersAsynchronously: true) { canvas, size in
            let inset = size.width * 0.018
            let span = size.width - inset * 2
            let grain = max(span / 380, 1)
            var settled = Path()
            var bouncing = Path()
            for index in frame.xs.indices {
                let rect = CGRect(
                    x: inset + CGFloat(frame.xs[index]) * span - grain / 2,
                    y: inset + CGFloat(frame.ys[index]) * span - grain / 2,
                    width: grain,
                    height: grain
                )
                if frame.agitation[index] < 0.22 {
                    settled.addRect(rect)
                } else {
                    bouncing.addRect(rect)
                }
            }
            canvas.fill(bouncing, with: .color(ImmersiveStagePalette.ink.opacity(0.38)))
            canvas.fill(settled, with: .color(Color(red: 0.96, green: 0.93, blue: 0.86).opacity(0.92)))
        }
    }
}

// MARK: - 萤火同步

/// 萤火同步的模拟宿主：频谱 → 鼓点与拍速 → 萤火虫群走一步。暂停时整片停在当下那一刻。
@MainActor
final class ImmersiveFireflyModel {
    struct Light {
        var x: Double
        var y: Double
        var depth: Double
        var brightness: Double
    }

    struct Frame {
        var lights: [Light] = []
        /// 模拟时钟，草叶摆动跟它走，暂停时一起停。
        var time: TimeInterval = 0
        /// 这一刻整片有多亮（平均亮度），草地被照亮的程度。
        var glow: Double = 0
    }

    private var swarm: FireflySwarmSimulation?
    private var tracker = ImmersiveBeatTracker()
    private var lastTime: TimeInterval?

    func frame(time: TimeInterval, levels: [CGFloat], count: Int, advances: Bool) -> Frame {
        let features = tracker.update(levels: levels.map { Double($0) }, at: time)
        if swarm?.fireflies.count != count {
            swarm = FireflySwarmSimulation(count: count, seed: 0xF1_5EF1)
            lastTime = nil
        }
        guard var current = swarm else { return Frame() }
        swarm = nil
        if advances {
            current.step(dt: lastTime.map { time - $0 } ?? 0, features: features)
            lastTime = time
        } else {
            lastTime = nil
        }
        var lights: [Light] = []
        lights.reserveCapacity(current.fireflies.count)
        var total = 0.0
        for index in current.fireflies.indices {
            let position = current.position(of: index)
            let brightness = current.brightness(of: index)
            total += brightness
            lights.append(Light(
                x: position.x,
                y: position.y,
                depth: current.fireflies[index].depth,
                brightness: brightness
            ))
        }
        swarm = current
        return Frame(
            lights: lights,
            time: current.time,
            glow: lights.isEmpty ? 0 : total / Double(lights.count)
        )
    }
}

/// 夜里的一片草地，几百只萤火虫各闪各的；歌的节拍越稳，它们越会慢慢对上，最后整片一齐闪，
/// 把草尖都照亮。光晕画成同一张预先栅格化的小图，按亮度缩放、叠加。
struct ImmersiveFireflyMeadow: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    var count: Int

    @State private var model = ImmersiveFireflyModel()

    private static let lime = Color(red: 0.80, green: 0.98, blue: 0.42)
    private static let core = Color(red: 1.0, green: 1.0, blue: 0.84)
    private static let glowSymbolID = 0

    var body: some View {
        TimelineView(.animation(
            minimumInterval: frameRate.minimumInterval(base: 1.0 / 30),
            paused: !isAnimating
        )) { context in
            let frame = model.frame(
                time: context.date.timeIntervalSinceReferenceDate,
                levels: levelsProvider(),
                count: count,
                advances: isAnimating
            )
            Canvas(rendersAsynchronously: true) { canvas, size in
                drawSky(in: &canvas, size: size)
                drawFireflies(frame, in: &canvas, size: size)
                drawGrass(frame, in: &canvas, size: size)
            } symbols: {
                Circle()
                    .fill(RadialGradient(
                        colors: [Self.lime.opacity(0.95), Self.lime.opacity(0.32), Self.lime.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 32
                    ))
                    .frame(width: 64, height: 64)
                    .tag(Self.glowSymbolID)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawSky(in canvas: inout GraphicsContext, size: CGSize) {
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [
                    ImmersiveStagePalette.obsidian,
                    palette.secondary.opacity(0.55),
                    Color(red: 0.03, green: 0.06, blue: 0.05),
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        // 天上几颗很暗的星，位置固定。
        var stars = Path()
        let starCount = Int(size.width / 14)
        for index in 0..<starCount {
            let x: CGFloat = CGFloat(ImmersiveSeed.unit(index, salt: 71)) * size.width
            let height: CGFloat = CGFloat(pow(ImmersiveSeed.unit(index, salt: 72), 1.6))
            let y: CGFloat = height * size.height * 0.42
            let radius: CGFloat = 0.5 + CGFloat(ImmersiveSeed.unit(index, salt: 73)) * 0.8
            stars.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        canvas.fill(stars, with: .color(ImmersiveStagePalette.ink.opacity(0.32)))
    }

    private func drawFireflies(_ frame: ImmersiveFireflyModel.Frame, in canvas: inout GraphicsContext, size: CGSize) {
        guard let glow = canvas.resolveSymbol(id: Self.glowSymbolID) else { return }
        let unit: CGFloat = min(size.width, size.height) / 400
        var embers = Path()
        var cores = Path()
        canvas.drawLayer { layer in
            layer.blendMode = .plusLighter
            for light in frame.lights {
                let pointX: CGFloat = CGFloat(light.x) * size.width
                let pointY: CGFloat = CGFloat(light.y) * size.height
                let point = CGPoint(x: pointX, y: pointY)
                let depth: CGFloat = CGFloat(light.depth)
                let brightness: CGFloat = CGFloat(light.brightness)
                let near: Double = 0.45 + 0.55 * light.depth
                let emberRadius: CGFloat = max(0.6, unit * (0.7 + 1.1 * depth))
                if light.brightness < 0.04 {
                    // 两次闪之间只剩一点余光。
                    embers.addEllipse(in: CGRect(
                        x: point.x - emberRadius,
                        y: point.y - emberRadius,
                        width: emberRadius * 2,
                        height: emberRadius * 2
                    ))
                    continue
                }
                let reach: CGFloat = unit * (7 + 15 * depth)
                let radius: CGFloat = reach * (0.65 + 0.35 * brightness)
                layer.opacity = min(1, light.brightness * near)
                layer.draw(glow, in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                let coreRadius: CGFloat = emberRadius * (1 + brightness)
                cores.addEllipse(in: CGRect(
                    x: point.x - coreRadius,
                    y: point.y - coreRadius,
                    width: coreRadius * 2,
                    height: coreRadius * 2
                ))
            }
        }
        canvas.fill(embers, with: .color(Self.lime.opacity(0.16)))
        canvas.fill(cores, with: .color(Self.core.opacity(0.9)))
    }

    /// 画面底边一排草，随风轻摆；整片一齐闪时草尖被照亮。
    private func drawGrass(_ frame: ImmersiveFireflyModel.Frame, in canvas: inout GraphicsContext, size: CGSize) {
        let groundTop: CGFloat = size.height * 0.90
        if frame.glow > 0.01 {
            let radius: CGFloat = max(size.width, size.height) * 0.6
            let center = CGPoint(x: size.width / 2, y: size.height)
            canvas.fill(
                Path(CGRect(x: 0, y: size.height - radius, width: size.width, height: radius)),
                with: .radialGradient(
                    Gradient(colors: [Self.lime.opacity(min(frame.glow * 0.5, 0.28)), Self.lime.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
        canvas.fill(
            Path(CGRect(x: 0, y: groundTop, width: size.width, height: size.height - groundTop)),
            with: .linearGradient(
                Gradient(colors: [Color(red: 0.02, green: 0.04, blue: 0.03).opacity(0), Color(red: 0.01, green: 0.02, blue: 0.015)]),
                startPoint: CGPoint(x: 0, y: groundTop - size.height * 0.04),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        var blades = Path()
        let bladeCount = Int(size.width / 5)
        let unit: CGFloat = min(size.width, size.height) / 400
        for index in 0..<bladeCount {
            let slot: Double = (Double(index) + ImmersiveSeed.unit(index, salt: 81)) / Double(max(bladeCount, 1))
            let baseX: CGFloat = CGFloat(slot) * size.width
            let height: CGFloat = unit * (14 + 34 * CGFloat(ImmersiveSeed.unit(index, salt: 82)))
            let restingLean: CGFloat = CGFloat(ImmersiveSeed.unit(index, salt: 83) - 0.5) * height * 0.5
            let sway: CGFloat = CGFloat(sin(frame.time * 0.7 + Double(baseX) * 0.012)) * height * 0.08
            let lean: CGFloat = restingLean + sway
            let base = CGPoint(x: baseX, y: size.height + 2)
            let tip = CGPoint(x: baseX + lean, y: size.height - height)
            let control = CGPoint(x: baseX + lean * 0.15, y: size.height - height * 0.55)
            blades.move(to: base)
            blades.addQuadCurve(to: tip, control: control)
        }
        canvas.stroke(blades, with: .color(Color(red: 0.02, green: 0.05, blue: 0.035)), lineWidth: max(1.2, unit * 1.6))
        if frame.glow > 0.02 {
            canvas.stroke(blades, with: .color(Self.lime.opacity(min(frame.glow * 0.35, 0.22))), lineWidth: max(0.6, unit * 0.6))
        }
    }
}

// MARK: - 果蝇听歌

/// 果蝇听歌的模拟宿主：频谱 → 听觉通路的神经活动 → 这一帧的投影。接线数据只读一次，各舞台共用。
@MainActor
final class ImmersiveFlyBrainModel {
    struct Pulse {
        var neuron: Int
        /// 光跑到纤维的哪儿（0…1 的路程比例）。
        var front: Float
    }

    struct Flash {
        var synapse: Int
        var glow: Float
    }

    struct Frame {
        var outline: [SIMD2<Float>] = []
        var neurons: [SIMD2<Float>] = []
        var activation: [Float] = []
        var pulses: [Pulse] = []
        var flashes: [Flash] = []
        var synapses: [SIMD2<Float>] = []
        var platform: [SIMD2<Float>] = []
        var labels: [(name: String, point: SIMD2<Float>, isAuditory: Bool)] = []
        /// 听觉入口整体有多活跃，听觉脑区的轮廓跟着亮。
        var inputGlow: Float = 0
    }

    /// 解一次就够：28 万字节，Debug 下也只要几十毫秒。
    nonisolated static let circuit: FlyAuditoryCircuit? = FlyAuditoryCircuit.bundled()
    private static let synapsePoints: [SIMD3<Float>] = circuit?.synapses.map(\.point) ?? []

    /// 投影台：大脑下方一圈水平的圆。
    private static let platformRing: [SIMD3<Float>] = (0...72).map { step in
        let angle = Float(step) / 72 * 2 * .pi
        return SIMD3(cos(angle) * 0.9, 0.6, sin(angle) * 0.55 + 0.05)
    }

    private static let auditoryLabels: Set<String> = ["AMMC", "WED", "SAD", "AVLP"]
    /// 只标这几处：听觉通路经过的四个脑区，加上嗅叶、侧角与两块视叶作参照。
    private static let shownLabels: Set<String> = auditoryLabels.union(["AL", "LH", "ME", "LO"])

    private var simulation: FlyAuditorySimulation?
    private var tracker = ImmersiveBeatTracker()
    private var lastTime: TimeInterval?
    private var orbitClock: TimeInterval = 8
    private var synapseRanges: [Range<Int>] = []

    func frame(time: TimeInterval, levels: [CGFloat], advances: Bool) -> Frame {
        guard let circuit = Self.circuit else { return Frame() }
        let samples = levels.map { Double($0) }
        let features = tracker.update(levels: samples, at: time)
        if simulation == nil {
            simulation = Self.preRolled(circuit)
            synapseRanges = Self.ranges(of: circuit)
        }
        guard var current = simulation else { return Frame() }
        simulation = nil
        if advances {
            let dt = lastTime.map { time - $0 } ?? 0
            current.step(dt: dt, levels: samples, beat: features.beat)
            orbitClock += min(max(dt, 0), 0.25)
            lastTime = time
        } else {
            lastTime = nil
        }
        simulation = current

        let camera = advances ? FlyBrainCamera.orbit(at: orbitClock) : FlyBrainCamera.resting
        var frame = Frame()
        camera.project(circuit.outlinePoints, into: &frame.outline)
        camera.project(circuit.neuronPoints, into: &frame.neurons)
        camera.project(Self.synapsePoints, into: &frame.synapses)
        camera.project(Self.platformRing, into: &frame.platform)
        frame.activation = current.activation

        var inputTotal: Float = 0
        var inputCount: Float = 0
        for (index, neuron) in circuit.neurons.enumerated() where neuron.layer == 0 {
            inputTotal += current.activation[index]
            inputCount += 1
        }
        frame.inputGlow = inputCount > 0 ? inputTotal / inputCount : 0

        for spike in current.spikes {
            let front = Float(current.front(of: spike))
            if front <= 1.12 {
                frame.pulses.append(Pulse(neuron: spike.neuron, front: front))
            }
            // 光跑到末梢附近时，这个神经元发出的突触亮一下。
            let glow = 1 - abs(front - 0.95) / 0.45
            if glow > 0, synapseRanges.indices.contains(spike.neuron) {
                for synapse in synapseRanges[spike.neuron] {
                    frame.flashes.append(Flash(synapse: synapse, glow: glow))
                }
            }
        }

        var seen = Set<String>()
        for label in circuit.labels {
            let name = label.name.components(separatedBy: "(").first ?? label.name
            guard Self.shownLabels.contains(name), seen.insert(name).inserted else { continue }
            let projected = camera.project(label.point)
            frame.labels.append((name, SIMD2(projected.x, projected.y), Self.auditoryLabels.contains(name)))
        }
        return frame
    }

    /// 开场先让一段假想的声音跑不到一秒：静止的缩略图里也能看到几条亮着的通路。
    private static func preRolled(_ circuit: FlyAuditoryCircuit) -> FlyAuditorySimulation {
        var simulation = FlyAuditorySimulation(circuit: circuit)
        let quiet = Array(repeating: 0.2, count: 32)
        let burst = (0..<32).map { $0 < 18 ? 0.9 : 0.3 }
        for step in 0..<24 {
            simulation.step(dt: 1.0 / 30, levels: step < 3 || (step >= 12 && step < 14) ? burst : quiet, beat: step == 0 ? 1 : 0)
        }
        return simulation
    }

    private static func ranges(of circuit: FlyAuditoryCircuit) -> [Range<Int>] {
        var result = Array(repeating: 0..<0, count: circuit.neurons.count)
        var start = 0
        while start < circuit.synapses.count {
            let pre = circuit.synapses[start].pre
            var end = start
            while end < circuit.synapses.count, circuit.synapses[end].pre == pre { end += 1 }
            result[pre] = start..<end
            start = end
        }
        return result
    }
}

/// 全息投影台上一颗慢慢转动的果蝇大脑：蓝色虚线是一层层脑区切片的轮廓，里面是听觉通路的真实神经纤维。
/// 声音进来时触角那一侧的入口先亮，信号沿纤维一级级往里传（一道光跑过纤维），跑到末梢时突触闪一下。
struct ImmersiveFlyBrain: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    /// 大脑中心在画布里的位置。
    var center: UnitPoint
    /// 大脑左右半宽（点）。
    var halfWidth: CGFloat
    var labelSize: CGFloat

    @State private var model = ImmersiveFlyBrainModel()

    private static let shell = Color(red: 0.36, green: 0.64, blue: 1.0)
    private static let auditory = Color(red: 0.42, green: 0.90, blue: 1.0)
    private static let fiber = Color(red: 0.30, green: 0.55, blue: 1.0)
    private static let spark = Color(red: 0.86, green: 0.97, blue: 1.0)

    var body: some View {
        TimelineView(.animation(
            minimumInterval: frameRate.minimumInterval(base: 1.0 / 24),
            paused: !isAnimating
        )) { context in
            let frame = model.frame(
                time: context.date.timeIntervalSinceReferenceDate,
                levels: levelsProvider(),
                advances: isAnimating
            )
            Canvas(rendersAsynchronously: true) { canvas, size in
                draw(frame, in: &canvas, size: size)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ frame: ImmersiveFlyBrainModel.Frame, in canvas: inout GraphicsContext, size: CGSize) {
        guard let circuit = ImmersiveFlyBrainModel.circuit else { return }
        let originX: CGFloat = size.width * center.x
        let originY: CGFloat = size.height * center.y
        let scale: CGFloat = halfWidth
        let unit: CGFloat = max(halfWidth / 320, 0.6)
        func point(_ value: SIMD2<Float>) -> CGPoint {
            CGPoint(x: originX + CGFloat(value.x) * scale, y: originY + CGFloat(value.y) * scale)
        }

        // 投影台：大脑下方一圈虚线椭圆。
        var platform = Path()
        for (index, value) in frame.platform.enumerated() {
            if index == 0 { platform.move(to: point(value)) } else { platform.addLine(to: point(value)) }
        }
        canvas.stroke(
            platform,
            with: .color(Self.shell.opacity(0.24)),
            style: StrokeStyle(lineWidth: unit, dash: [unit * 2, unit * 5])
        )

        func addLine(through points: [SIMD2<Float>], _ range: Range<Int>, to path: inout Path) {
            guard range.count >= 2 else { return }
            path.move(to: point(points[range.lowerBound]))
            for index in (range.lowerBound + 1)..<range.upperBound {
                path.addLine(to: point(points[index]))
            }
        }

        // 脑区切片轮廓：外壳虚线，听觉脑区实线并随入口的活跃度亮起来。
        var shell = Path()
        var hearing = Path()
        for outline in circuit.outlines {
            if outline.isAuditory {
                addLine(through: frame.outline, outline.points, to: &hearing)
            } else {
                addLine(through: frame.outline, outline.points, to: &shell)
            }
        }
        canvas.stroke(
            shell,
            with: .color(Self.shell.opacity(0.44)),
            style: StrokeStyle(lineWidth: unit, dash: [unit * 3, unit * 4])
        )
        let hearingOpacity: Double = 0.42 + 0.45 * Double(min(frame.inputGlow * 1.6, 1))
        canvas.stroke(hearing, with: .color(Self.auditory.opacity(hearingOpacity)), lineWidth: unit)

        // 神经纤维：平时很淡，按活跃度分三档加亮。
        var resting = Path()
        var warm = Path()
        var bright = Path()
        var hot = Path()
        for (line, range) in circuit.polylines.enumerated() {
            let activation = frame.activation[circuit.polylineNeuron[line]]
            if activation > 0.6 {
                addLine(through: frame.neurons, range, to: &hot)
            } else if activation > 0.35 {
                addLine(through: frame.neurons, range, to: &bright)
            } else if activation > 0.12 {
                addLine(through: frame.neurons, range, to: &warm)
            } else {
                addLine(through: frame.neurons, range, to: &resting)
            }
        }
        canvas.stroke(resting, with: .color(Self.fiber.opacity(0.24)), lineWidth: unit * 0.7)
        canvas.stroke(warm, with: .color(Self.auditory.opacity(0.36)), lineWidth: unit * 0.85)
        canvas.stroke(bright, with: .color(Self.auditory.opacity(0.55)), lineWidth: unit)
        // 光晕用两层更宽、更淡的描边叠出来，不做整幅模糊（电视的填充率扛不住每帧整屏模糊）。
        canvas.stroke(hot, with: .color(Self.auditory.opacity(0.12)), lineWidth: unit * 5)
        canvas.stroke(hot, with: .color(Self.auditory.opacity(0.28)), lineWidth: unit * 2.4)
        canvas.stroke(hot, with: .color(Self.spark.opacity(0.85)), lineWidth: unit * 1.1)

        // 放电：一小段光沿纤维从起点往外跑。
        var pulses = Path()
        for pulse in frame.pulses {
            let tail: Float = pulse.front - 0.12
            for line in circuit.neurons[pulse.neuron].polylines {
                let range = circuit.polylines[line]
                var drawing = false
                for index in range {
                    let distance = circuit.neuronPointDistance[index]
                    let inside = distance >= tail && distance <= pulse.front
                    if inside {
                        let value = point(frame.neurons[index])
                        if drawing {
                            pulses.addLine(to: value)
                        } else {
                            pulses.move(to: value)
                            drawing = true
                        }
                    } else {
                        drawing = false
                    }
                }
            }
        }
        canvas.stroke(pulses, with: .color(Self.auditory.opacity(0.16)), lineWidth: unit * 6)
        canvas.stroke(pulses, with: .color(Self.auditory.opacity(0.42)), lineWidth: unit * 3)
        canvas.stroke(pulses, with: .color(Self.spark), lineWidth: unit * 1.4)

        // 突触：平时是极淡的点，被放电点亮时闪一下。
        var dots = Path()
        let dot: CGFloat = unit * 0.9
        for (index, value) in frame.synapses.enumerated() where index % 2 == 0 {
            let center = point(value)
            dots.addRect(CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
        }
        canvas.fill(dots, with: .color(Self.auditory.opacity(0.32)))
        canvas.drawLayer { layer in
            layer.blendMode = .plusLighter
            for flash in frame.flashes {
                let center = point(frame.synapses[flash.synapse])
                let radius: CGFloat = unit * (0.8 + 1.5 * CGFloat(flash.glow))
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(Self.auditory.opacity(Double(flash.glow) * 0.7))
                )
            }
        }

        // 脑区标签：一条细引线加缩写，听觉脑区亮一点。
        for label in frame.labels {
            let anchor = point(label.point)
            let toRight = label.point.x >= 0
            let elbow = CGPoint(x: anchor.x + (toRight ? 1 : -1) * unit * 16, y: anchor.y - unit * 14)
            let end = CGPoint(x: elbow.x + (toRight ? 1 : -1) * unit * 12, y: elbow.y)
            var leader = Path()
            leader.move(to: anchor)
            leader.addLine(to: elbow)
            leader.addLine(to: end)
            let opacity: Double = label.isAuditory ? 0.75 : 0.38
            canvas.stroke(leader, with: .color(Self.auditory.opacity(opacity * 0.6)), lineWidth: max(0.5, unit * 0.6))
            canvas.fill(
                Path(ellipseIn: CGRect(x: anchor.x - unit * 1.4, y: anchor.y - unit * 1.4, width: unit * 2.8, height: unit * 2.8)),
                with: .color(Self.auditory.opacity(opacity))
            )
            let text = Text(verbatim: label.name)
                .font(.system(size: labelSize, weight: .medium, design: .monospaced))
                .foregroundStyle(Self.auditory.opacity(opacity))
            canvas.draw(
                text,
                at: CGPoint(x: end.x + (toRight ? 1 : -1) * unit * 3, y: end.y),
                anchor: toRight ? .leading : .trailing
            )
        }
    }
}
