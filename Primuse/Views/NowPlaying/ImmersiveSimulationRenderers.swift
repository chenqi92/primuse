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

/// 克拉尼沙画的模拟宿主：频谱 → 起音、激烈程度与音色 → 沙子走一步。暂停、减少动态效果或省电时停在原处，
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
            current.changeSong(seed: seed)
        }
        if advances {
            let dt = lastTime.map { time - $0 } ?? 0
            current.step(dt: dt, features: features)
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

/// 一块振动的方形金属板，上面撒满细沙。这首歌此刻在自己的起伏里有多激烈挑振动模式（花纹），
/// 音色的明暗让花纹连续变形，沙子顺着流到节线上；每次起音把排好的沙震散，再落回线上。
/// 板角标出当前的模式 (m, n)。
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
            var stirring = Path()
            var bouncing = Path()
            // 按指针读：几千粒沙逐个取数组下标，在 Debug 构建里每次都是一次泛型调用。
            frame.xs.withUnsafeBufferPointer { xBuffer in
                frame.ys.withUnsafeBufferPointer { yBuffer in
                    frame.agitation.withUnsafeBufferPointer { agitationBuffer in
                        guard let xs = xBuffer.baseAddress, let ys = yBuffer.baseAddress,
                              let agitation = agitationBuffer.baseAddress else { return }
                        let count = Swift.min(xBuffer.count, yBuffer.count, agitationBuffer.count)
                        var index = 0
                        while index < count {
                            let rect = CGRect(
                                x: inset + CGFloat(xs[index]) * span - grain / 2,
                                y: inset + CGFloat(ys[index]) * span - grain / 2,
                                width: grain,
                                height: grain
                            )
                            // 三档：落在线上的亮、刚被震离一点的半亮、还在振幅大处跳的暗。
                            let level = agitation[index]
                            if level < 0.12 {
                                settled.addRect(rect)
                            } else if level < 0.35 {
                                stirring.addRect(rect)
                            } else {
                                bouncing.addRect(rect)
                            }
                            index += 1
                        }
                    }
                }
            }
            let sand = Color(red: 0.96, green: 0.93, blue: 0.86)
            canvas.fill(bouncing, with: .color(ImmersiveStagePalette.ink.opacity(0.34)))
            canvas.fill(stirring, with: .color(sand.opacity(0.6)))
            canvas.fill(settled, with: .color(sand.opacity(0.92)))
        }
    }
}

// MARK: - 萤火同步

/// 萤火同步的模拟宿主：频谱 → 三段起音与热闹程度 → 萤火虫群走一步。暂停时整片停在当下那一刻。
@MainActor
final class ImmersiveFireflyModel {
    struct Light {
        var x: Double
        /// 萤火活动那一段高度里的位置：0 最高、1 贴着草尖。
        var y: Double
        var depth: Double
        var brightness: Double
        /// 醒着的程度，两次闪之间的余光跟着它淡入淡出。
        var awake: Double
        var register: ImmersiveAudioRegister
    }

    struct Frame {
        var lights: [Light] = []
        /// 模拟时钟，草叶摆动跟它走，暂停时一起停。
        var time: TimeInterval = 0
        /// 贴着草的那层此刻有多亮（平均亮度），草地被照亮的程度。
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
        var groundTotal = 0.0
        var groundCount = 0
        for index in current.fireflies.indices {
            let firefly = current.fireflies[index]
            let position = current.position(of: index)
            let brightness = current.brightness(of: index)
            if firefly.register == .low {
                groundTotal += brightness
                groundCount += 1
            }
            lights.append(Light(
                x: position.x,
                y: position.y,
                depth: firefly.depth,
                brightness: brightness,
                awake: firefly.awake,
                register: firefly.register
            ))
        }
        swarm = current
        return Frame(
            lights: lights,
            time: current.time,
            glow: groundCount == 0 ? 0 : groundTotal / Double(groundCount)
        )
    }
}

/// 夜里的一片草地，几百只萤火虫分三层：贴着草的跟着底鼓闪，半空的跟着军鼓与人声的字头闪，
/// 高处的跟着镲片一闪一闪；哪一段声音在歌里越热闹，那一层醒着的越多。
/// 光晕画成预先栅格化的小图（每层一种色调），按亮度缩放、叠加。
struct ImmersiveFireflyMeadow: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    var count: Int
    /// 萤火活动那一段的上沿（画面高度的比例）；下沿固定贴着草尖。横屏把上面一截夜空留给歌词。
    var fieldTop: CGFloat = 0.30

    @State private var model = ImmersiveFireflyModel()

    private static let fieldBottom: CGFloat = 0.93
    private static let lime = Color(red: 0.80, green: 0.98, blue: 0.42)
    private static let core = Color(red: 1.0, green: 1.0, blue: 0.84)
    /// 三层的光：贴草的偏暖、大而柔，高处的偏白、小而利。
    private static let tints: [Color] = [
        Color(red: 0.88, green: 0.96, blue: 0.38),
        lime,
        Color(red: 0.84, green: 1.0, blue: 0.78),
    ]
    private static let reachScale: [CGFloat] = [1.25, 1.0, 0.62]

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
                ForEach(Self.tints.indices, id: \.self) { index in
                    Circle()
                        .fill(RadialGradient(
                            colors: [Self.tints[index].opacity(0.95), Self.tints[index].opacity(0.32), Self.tints[index].opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 32
                        ))
                        .frame(width: 64, height: 64)
                        .tag(index)
                }
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
        let glows = Self.tints.indices.compactMap { canvas.resolveSymbol(id: $0) }
        guard glows.count == Self.tints.count else { return }
        let unit: CGFloat = min(size.width, size.height) / 400
        let top: CGFloat = min(max(fieldTop, 0), Self.fieldBottom - 0.1)
        let span: CGFloat = Self.fieldBottom - top
        // 余光分三档透明度，按醒着的程度归档：醒来、睡去都是渐变的。
        var embers = [Path(), Path(), Path()]
        var cores = Path()
        canvas.drawLayer { layer in
            layer.blendMode = .plusLighter
            for light in frame.lights {
                guard light.awake > 0.03 else { continue }
                let pointX: CGFloat = CGFloat(light.x) * size.width
                let pointY: CGFloat = (top + span * CGFloat(light.y)) * size.height
                let point = CGPoint(x: pointX, y: pointY)
                let depth: CGFloat = CGFloat(light.depth)
                let brightness: CGFloat = CGFloat(light.brightness)
                let near: Double = 0.45 + 0.55 * light.depth
                let layerIndex = light.register.rawValue
                let emberRadius: CGFloat = max(0.6, unit * (0.7 + 1.1 * depth) * (layerIndex == 2 ? 0.8 : 1))
                if light.brightness < 0.04 {
                    // 两次闪之间只剩一点余光。
                    let bucket = light.awake > 0.66 ? 2 : (light.awake > 0.33 ? 1 : 0)
                    embers[bucket].addEllipse(in: CGRect(
                        x: point.x - emberRadius,
                        y: point.y - emberRadius,
                        width: emberRadius * 2,
                        height: emberRadius * 2
                    ))
                    continue
                }
                let reach: CGFloat = unit * (7 + 15 * depth) * Self.reachScale[layerIndex]
                let radius: CGFloat = reach * (0.65 + 0.35 * brightness)
                layer.opacity = min(1, light.brightness * near)
                layer.draw(glows[layerIndex], in: CGRect(
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
        canvas.fill(embers[0], with: .color(Self.lime.opacity(0.05)))
        canvas.fill(embers[1], with: .color(Self.lime.opacity(0.10)))
        canvas.fill(embers[2], with: .color(Self.lime.opacity(0.16)))
        canvas.fill(cores, with: .color(Self.core.opacity(0.9)))
    }

    /// 画面底边一排草，随风轻摆；贴着草的那层一起闪时草尖被照亮。
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

// MARK: - 神经共鸣

/// 神经共鸣的模拟宿主：频谱 → 听觉通路的神经活动 → 这一帧的投影。接线数据只读一次，各舞台共用。
///
/// 画面分两层取数：`structure` 是只随相机变的那一层（外壳、全部纤维的静息底色、突触底点、投影台、标签），
/// 相机转得很慢，按活动层一半的帧率投影一次 2 万多个点；`activity` 是随神经活动变的那一层，
/// 只画亮起来的纤维、放电的光和闪的突触，沿用最近一次的投影，两层对得上。
/// 投影出来的平面坐标都是交错排列的 Float（第 i 个点是 `[2i]`、`[2i + 1]`），画的时候按指针读。
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

    struct Label {
        var name: String
        var point: SIMD2<Float>
        var isAuditory: Bool
    }

    struct Structure {
        var outline: [Float] = []
        var neurons: [Float] = []
        var synapses: [Float] = []
        var platform: [Float] = []
        var labels: [Label] = []
        /// 听觉入口整体有多活跃，听觉脑区的轮廓跟着亮。
        var inputGlow: Float = 0
    }

    struct Activity {
        /// 和 `Structure` 同一次投影的神经元点与突触点。
        var neurons: [Float] = []
        var synapses: [Float] = []
        var activation: [Float] = []
        var pulses: [Pulse] = []
        var flashes: [Flash] = []
    }

    /// 解一次就够：28 万字节，Debug 下也只要几十毫秒。
    nonisolated static let circuit: FlyAuditoryCircuit? = FlyAuditoryCircuit.bundled()

    private static let outlineCloud = FlyBrainPointCloud(circuit?.outlinePoints ?? [])
    private static let neuronCloud = FlyBrainPointCloud(circuit?.neuronPoints ?? [])
    private static let synapseCloud = FlyBrainPointCloud(circuit?.synapses.map(\.point) ?? [])
    /// 投影台：大脑下方一圈水平的圆。
    private static let platformCloud = FlyBrainPointCloud((0...72).map { step in
        let angle = Float(step) / 72 * 2 * .pi
        return SIMD3(cos(angle) * 0.9, 0.6, sin(angle) * 0.55 + 0.05)
    })

    /// 折线的起止点，交错排列（`[2i]` 起、`[2i + 1]` 止）；画的时候按指针读，不逐条取 `Range`。
    nonisolated static let polylineBounds: [Int] = circuit.map { circuit in
        circuit.polylines.flatMap { [$0.lowerBound, $0.upperBound] }
    } ?? []
    nonisolated static let outlineBounds: [Int] = circuit.map { circuit in
        circuit.outlines.flatMap { [$0.points.lowerBound, $0.points.upperBound] }
    } ?? []

    private static let auditoryLabels: Set<String> = ["AMMC", "WED", "SAD", "AVLP"]

    /// 只标这几处：听觉通路经过的四个脑区，加上嗅叶、侧角与两块视叶作参照。同名的只取第一个。
    static let shownLabels: [(name: String, point: SIMD3<Float>, isAuditory: Bool)] = {
        let shown = auditoryLabels.union(["AL", "LH", "ME", "LO"])
        var seen = Set<String>()
        var result: [(name: String, point: SIMD3<Float>, isAuditory: Bool)] = []
        for label in circuit?.labels ?? [] {
            let name = label.name.components(separatedBy: "(").first ?? label.name
            guard shown.contains(name), seen.insert(name).inserted else { continue }
            result.append((name, label.point, auditoryLabels.contains(name)))
        }
        return result
    }()

    /// 听觉入口（第 0 层）的神经元编号。
    private static let inputNeurons: [Int] = circuit.map { circuit in
        circuit.neurons.indices.filter { circuit.neurons[$0].layer == 0 }
    } ?? []

    private var simulation: FlyAuditorySimulation?
    private var tracker = ImmersiveBeatTracker()
    private var lastTime: TimeInterval?
    private var orbitClock: TimeInterval = 8
    private var synapseRanges: [Range<Int>] = []
    private var projectedNeurons: [Float] = []
    private var projectedSynapses: [Float] = []

    /// 只随相机变的那一层：按当前的相机角度把外壳、纤维、突触、投影台与标签投影一次。
    func structure(advances: Bool) -> Structure {
        guard let circuit = Self.circuit else { return Structure() }
        ensureSimulation(circuit)
        let camera = advances ? FlyBrainCamera.orbit(at: orbitClock) : FlyBrainCamera.resting
        var structure = Structure()
        Self.outlineCloud.project(with: camera, into: &structure.outline)
        Self.neuronCloud.project(with: camera, into: &structure.neurons)
        Self.synapseCloud.project(with: camera, into: &structure.synapses)
        Self.platformCloud.project(with: camera, into: &structure.platform)
        projectedNeurons = structure.neurons
        projectedSynapses = structure.synapses

        if let activation = simulation?.activation, !Self.inputNeurons.isEmpty {
            var total: Float = 0
            for index in Self.inputNeurons { total += activation[index] }
            structure.inputGlow = total / Float(Self.inputNeurons.count)
        }
        structure.labels = Self.shownLabels.map { label in
            let projected = camera.project(label.point)
            return Label(name: label.name, point: SIMD2(projected.x, projected.y), isAuditory: label.isAuditory)
        }
        return structure
    }

    /// 随神经活动变的那一层：神经元走一步，挑出亮着的纤维、正在跑的光和该闪的突触。
    func activity(time: TimeInterval, levels: [CGFloat], advances: Bool) -> Activity {
        guard let circuit = Self.circuit else { return Activity() }
        let samples = levels.map { Double($0) }
        let features = tracker.update(levels: samples, at: time)
        ensureSimulation(circuit)
        guard var current = simulation else { return Activity() }
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

        // 活动层先于结构层求值的那一帧（刚出现时）还没有投影：先补一次。
        if projectedNeurons.count != Self.neuronCloud.count * 2 {
            _ = structure(advances: advances)
        }
        var activity = Activity(
            neurons: projectedNeurons,
            synapses: projectedSynapses,
            activation: current.activation
        )
        for spike in current.spikes {
            let front = Float(current.front(of: spike))
            if front <= 1.12 {
                activity.pulses.append(Pulse(neuron: spike.neuron, front: front))
            }
            // 光跑到末梢附近时，这个神经元发出的突触亮一下。
            let glow = 1 - abs(front - 0.95) / 0.45
            if glow > 0, synapseRanges.indices.contains(spike.neuron) {
                for synapse in synapseRanges[spike.neuron] {
                    activity.flashes.append(Flash(synapse: synapse, glow: glow))
                }
            }
        }
        return activity
    }

    private func ensureSimulation(_ circuit: FlyAuditoryCircuit) {
        guard simulation == nil, synapseRanges.isEmpty else { return }
        simulation = Self.preRolled(circuit)
        synapseRanges = Self.ranges(of: circuit)
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
///
/// 两层画布叠在一起：下面那层只随相机变，按上面那层一半的帧率重画（2 万多个点的纤维、虚线外壳和标签都在这层）；
/// 上面那层只画亮起来的那一小部分。拼路径的循环都按指针读平面坐标：Debug 构建不特化泛型，
/// 数组下标与 `Range` 迭代在那里每次都是一次运行时调用。
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

    /// 活动层的最小间隔；`nil` 是跟着屏幕刷新。
    private var activityInterval: TimeInterval? {
        frameRate.minimumInterval(base: 1.0 / 24)
    }

    /// 结构层按活动层一半的帧率，最快每秒 30 次：相机一秒只转零点几度，再勤也看不出差别。
    private var structureInterval: TimeInterval {
        max(activityInterval ?? 1.0 / 60, 1.0 / 60) * 2
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: structureInterval, paused: !isAnimating)) { _ in
                let structure = model.structure(advances: isAnimating)
                Canvas(rendersAsynchronously: true) { canvas, size in
                    drawStructure(structure, in: &canvas, size: size)
                } symbols: {
                    ForEach(ImmersiveFlyBrainModel.shownLabels.indices, id: \.self) { index in
                        Text(verbatim: ImmersiveFlyBrainModel.shownLabels[index].name)
                            .font(.system(size: labelSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(Self.auditory)
                            .fixedSize()
                            .tag(index)
                    }
                }
            }
            TimelineView(.animation(minimumInterval: activityInterval, paused: !isAnimating)) { context in
                let activity = model.activity(
                    time: context.date.timeIntervalSinceReferenceDate,
                    levels: levelsProvider(),
                    advances: isAnimating
                )
                Canvas(rendersAsynchronously: true) { canvas, size in
                    drawActivity(activity, in: &canvas, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private struct Projection {
        let originX: CGFloat
        let originY: CGFloat
        let scale: CGFloat
        let unit: CGFloat

        func point(_ value: SIMD2<Float>) -> CGPoint {
            CGPoint(x: originX + CGFloat(value.x) * scale, y: originY + CGFloat(value.y) * scale)
        }

        /// 交错坐标里的第 `index` 个点。
        func point(_ points: UnsafePointer<Float>, _ index: Int) -> CGPoint {
            CGPoint(x: originX + CGFloat(points[2 * index]) * scale, y: originY + CGFloat(points[2 * index + 1]) * scale)
        }

        /// 把第 `start..<end` 个点连成一条折线加进 `path`。
        func addPolyline(_ points: UnsafePointer<Float>, from start: Int, to end: Int, to path: inout Path) {
            guard end - start >= 2 else { return }
            path.move(to: point(points, start))
            var index = start + 1
            while index < end {
                path.addLine(to: point(points, index))
                index += 1
            }
        }
    }

    private func projection(in size: CGSize) -> Projection {
        Projection(
            originX: size.width * center.x,
            originY: size.height * center.y,
            scale: halfWidth,
            unit: max(halfWidth / 320, 0.6)
        )
    }

    private func drawStructure(_ frame: ImmersiveFlyBrainModel.Structure, in canvas: inout GraphicsContext, size: CGSize) {
        guard let circuit = ImmersiveFlyBrainModel.circuit,
              frame.neurons.count == circuit.neuronPoints.count * 2,
              frame.outline.count == circuit.outlinePoints.count * 2 else { return }
        let projection = projection(in: size)
        let unit = projection.unit

        // 投影台：大脑下方一圈虚线椭圆。
        var platform = Path()
        frame.platform.withUnsafeBufferPointer { buffer in
            guard let points = buffer.baseAddress else { return }
            projection.addPolyline(points, from: 0, to: buffer.count / 2, to: &platform)
        }
        canvas.stroke(
            platform,
            with: .color(Self.shell.opacity(0.24)),
            style: StrokeStyle(lineWidth: unit, dash: [unit * 2, unit * 5])
        )

        // 脑区切片轮廓：外壳虚线，听觉脑区实线并随入口的活跃度亮起来。
        var shell = Path()
        var hearing = Path()
        frame.outline.withUnsafeBufferPointer { pointBuffer in
            ImmersiveFlyBrainModel.outlineBounds.withUnsafeBufferPointer { boundBuffer in
                guard let points = pointBuffer.baseAddress, let bounds = boundBuffer.baseAddress else { return }
                for (index, outline) in circuit.outlines.enumerated() {
                    if outline.isAuditory {
                        projection.addPolyline(points, from: bounds[2 * index], to: bounds[2 * index + 1], to: &hearing)
                    } else {
                        projection.addPolyline(points, from: bounds[2 * index], to: bounds[2 * index + 1], to: &shell)
                    }
                }
            }
        }
        canvas.stroke(
            shell,
            with: .color(Self.shell.opacity(0.44)),
            style: StrokeStyle(lineWidth: unit, dash: [unit * 3, unit * 4])
        )
        let hearingOpacity: Double = 0.42 + 0.45 * Double(min(frame.inputGlow * 1.6, 1))
        canvas.stroke(hearing, with: .color(Self.auditory.opacity(hearingOpacity)), lineWidth: unit)

        // 全部纤维的静息底色；亮起来的那些由活动层叠在上面。
        var resting = Path()
        frame.neurons.withUnsafeBufferPointer { pointBuffer in
            ImmersiveFlyBrainModel.polylineBounds.withUnsafeBufferPointer { boundBuffer in
                guard let points = pointBuffer.baseAddress, let bounds = boundBuffer.baseAddress else { return }
                let lineCount = boundBuffer.count / 2
                var line = 0
                while line < lineCount {
                    projection.addPolyline(points, from: bounds[2 * line], to: bounds[2 * line + 1], to: &resting)
                    line += 1
                }
            }
        }
        canvas.stroke(resting, with: .color(Self.fiber.opacity(0.24)), lineWidth: unit * 0.7)

        // 突触：平时是极淡的点，被放电点亮时由活动层闪一下。
        var dots = Path()
        let dot: CGFloat = unit * 0.9
        frame.synapses.withUnsafeBufferPointer { buffer in
            guard let points = buffer.baseAddress else { return }
            let count = buffer.count / 2
            var index = 0
            while index < count {
                let center = projection.point(points, index)
                dots.addRect(CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
                index += 2
            }
        }
        canvas.fill(dots, with: .color(Self.auditory.opacity(0.32)))

        // 脑区标签：一条细引线加缩写，听觉脑区亮一点。文字是预先栅格化的符号，不必每帧排版。
        for (index, label) in frame.labels.enumerated() {
            let anchor = projection.point(label.point)
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
            if let text = canvas.resolveSymbol(id: index) {
                var context = canvas
                context.opacity = opacity
                context.draw(
                    text,
                    at: CGPoint(x: end.x + (toRight ? 1 : -1) * unit * 3, y: end.y),
                    anchor: toRight ? .leading : .trailing
                )
            }
        }
    }

    private func drawActivity(_ frame: ImmersiveFlyBrainModel.Activity, in canvas: inout GraphicsContext, size: CGSize) {
        guard let circuit = ImmersiveFlyBrainModel.circuit,
              frame.neurons.count == circuit.neuronPoints.count * 2,
              frame.activation.count == circuit.neurons.count else { return }
        let projection = projection(in: size)
        let unit = projection.unit

        // 亮起来的纤维按活跃度分三档加亮；底下已经有一层静息底色，这里的透明度按叠上去以后的观感取。
        var warm = Path()
        var bright = Path()
        var hot = Path()
        // 放电：一小段光沿纤维从起点往外跑。
        var pulses = Path()
        frame.neurons.withUnsafeBufferPointer { pointBuffer in
            ImmersiveFlyBrainModel.polylineBounds.withUnsafeBufferPointer { boundBuffer in
                frame.activation.withUnsafeBufferPointer { activationBuffer in
                    circuit.polylineNeuron.withUnsafeBufferPointer { ownerBuffer in
                        guard let points = pointBuffer.baseAddress, let bounds = boundBuffer.baseAddress,
                              let activation = activationBuffer.baseAddress, let owner = ownerBuffer.baseAddress else { return }
                        let lineCount = ownerBuffer.count
                        var line = 0
                        while line < lineCount {
                            let level = activation[owner[line]]
                            if level > 0.12 {
                                let start = bounds[2 * line]
                                let end = bounds[2 * line + 1]
                                if level > 0.6 {
                                    projection.addPolyline(points, from: start, to: end, to: &hot)
                                } else if level > 0.35 {
                                    projection.addPolyline(points, from: start, to: end, to: &bright)
                                } else {
                                    projection.addPolyline(points, from: start, to: end, to: &warm)
                                }
                            }
                            line += 1
                        }

                        circuit.neuronPointDistance.withUnsafeBufferPointer { distanceBuffer in
                            guard let distances = distanceBuffer.baseAddress else { return }
                            for pulse in frame.pulses {
                                let tail: Float = pulse.front - 0.12
                                for line in circuit.neurons[pulse.neuron].polylines {
                                    var drawing = false
                                    var index = bounds[2 * line]
                                    let end = bounds[2 * line + 1]
                                    while index < end {
                                        let distance = distances[index]
                                        if distance >= tail && distance <= pulse.front {
                                            let value = projection.point(points, index)
                                            if drawing {
                                                pulses.addLine(to: value)
                                            } else {
                                                pulses.move(to: value)
                                                drawing = true
                                            }
                                        } else {
                                            drawing = false
                                        }
                                        index += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        canvas.stroke(warm, with: .color(Self.auditory.opacity(0.2)), lineWidth: unit * 0.85)
        canvas.stroke(bright, with: .color(Self.auditory.opacity(0.45)), lineWidth: unit)
        // 光晕用两层更宽、更淡的描边叠出来，不做整幅模糊（电视的填充率扛不住每帧整屏模糊）。
        canvas.stroke(hot, with: .color(Self.auditory.opacity(0.12)), lineWidth: unit * 5)
        canvas.stroke(hot, with: .color(Self.auditory.opacity(0.28)), lineWidth: unit * 2.4)
        canvas.stroke(hot, with: .color(Self.spark.opacity(0.85)), lineWidth: unit * 1.1)
        canvas.stroke(pulses, with: .color(Self.auditory.opacity(0.16)), lineWidth: unit * 6)
        canvas.stroke(pulses, with: .color(Self.auditory.opacity(0.42)), lineWidth: unit * 3)
        canvas.stroke(pulses, with: .color(Self.spark), lineWidth: unit * 1.4)

        // 突触闪光按亮度归成三档，一档一次填充，不逐个填。
        var flashes = [Path(), Path(), Path()]
        frame.synapses.withUnsafeBufferPointer { buffer in
            guard let points = buffer.baseAddress else { return }
            let count = buffer.count / 2
            for flash in frame.flashes where flash.synapse >= 0 && flash.synapse < count {
                let bucket = min(max(Int(flash.glow * 3), 0), 2)
                let center = projection.point(points, flash.synapse)
                let radius: CGFloat = unit * (0.8 + 1.5 * (CGFloat(bucket) + 0.5) / 3)
                flashes[bucket].addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        canvas.drawLayer { layer in
            layer.blendMode = .plusLighter
            for bucket in flashes.indices {
                layer.fill(flashes[bucket], with: .color(Self.auditory.opacity(0.7 * (Double(bucket) + 0.5) / 3)))
            }
        }
    }
}
