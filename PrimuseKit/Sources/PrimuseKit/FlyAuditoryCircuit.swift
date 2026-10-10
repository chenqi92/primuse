import Foundation

/// 全屏「果蝇听歌」用的一小块真实果蝇大脑：雄性果蝇中枢神经连接组（Male CNS v1.0，
/// Janelia FlyEM 与 Google，CC BY 4.0）里从触角听觉神经元（江氏器 JO-A、JO-B）出发、
/// 沿真实突触连接往脑里走四层的几百个神经元，以及脑区切片轮廓与推算的突触位置。
///
/// 资源 `FlyAuditoryCircuit.bin` 由离线脚本生成：神经元骨架裁到脑内、剪掉细枝再化简；
/// 坐标按整个脑的包围盒归一到 -1…1（x 从左到右，y 从背侧到腹侧，z 从前到后）后存成 Int16。
public struct FlyAuditoryCircuit: Sendable {
    public enum Role: UInt8, Sendable {
        /// 江氏器 A 组：偏高频的振动。
        case highFrequencyInput = 0
        /// 江氏器 B 组：偏低频的振动。
        case lowFrequencyInput = 1
        case interneuron = 2
        /// 下行神经元：把信号送去身体（运动）。
        case descending = 3
    }

    public struct Outline: Sendable {
        /// 第 0 位：切片轮廓；第 1 位：听觉相关的脑区（AMMC、SAD、WED、AVLP）；第 2 位：纵向切片。
        public let flags: UInt8
        public let points: Range<Int>

        public var isAuditory: Bool { flags & 2 != 0 }
    }

    public struct Neuron: Sendable {
        /// 离听觉入口隔了几层（入口本身是 0）。
        public let layer: Int
        /// 递质推断出的符号：乙酰胆碱 +1，GABA 与谷氨酸 -1，其余（调节性）0。
        public let sign: Int
        public let role: Role
        /// 江氏器亚型编号（JO-A1 的 1），其余为 0。
        public let subtype: Int
        /// 这个神经元的几条折线在 `polylines` 里的范围。
        public let polylines: Range<Int>
    }

    public struct Edge: Sendable {
        public let pre: Int
        public let post: Int
        public let weight: Int
    }

    public struct Synapse: Sendable {
        public let pre: Int
        public let post: Int
        public let point: SIMD3<Float>
    }

    public struct Label: Sendable {
        public let name: String
        public let point: SIMD3<Float>
    }

    /// 切片轮廓的全部点，按 `outlines[i].points` 分段。
    public let outlinePoints: [SIMD3<Float>]
    public let outlines: [Outline]
    /// 神经元折线的全部点。
    public let neuronPoints: [SIMD3<Float>]
    /// 每个点沿神经元到起点的路程，按这个神经元的最远路程归一到 0…1（信号沿它往外走）。
    public let neuronPointDistance: [Float]
    /// 每条折线在 `neuronPoints` 里的范围。
    public let polylines: [Range<Int>]
    /// 每条折线属于哪个神经元。
    public let polylineNeuron: [Int]
    public let neurons: [Neuron]
    /// 按突触前神经元排好序。
    public let edges: [Edge]
    /// 按突触前神经元排好序。
    public let synapses: [Synapse]
    public let labels: [Label]
    /// 归一化前的半边长（µm）。
    public let micrometersPerUnit: Float

    public enum DecodeError: Error, Equatable {
        case badHeader
        case truncated
        case inconsistent
    }

    public static let resourceName = "FlyAuditoryCircuit"
    public static let resourceExtension = "bin"

    /// 读包里带的那份。读不到或格式不对时为 nil（效果退回只画外壳）。
    public static func bundled() -> FlyAuditoryCircuit? {
        guard let url = Bundle.primuseKit.url(forResource: resourceName, withExtension: resourceExtension),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? decode(data)
    }

    public static func decode(_ data: Data) throws -> FlyAuditoryCircuit {
        var reader = Reader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Array("PMFC".utf8) else { throw DecodeError.badHeader }
        let version = try reader.u16()
        _ = try reader.u16()
        guard version == 1 else { throw DecodeError.badHeader }
        let micrometers = try reader.f32()
        let outlineCount = Int(try reader.u32())
        let neuronCount = Int(try reader.u16())
        let edgeCount = Int(try reader.u32())
        let synapseCount = Int(try reader.u32())
        let labelCount = Int(try reader.u16())

        var outlinePoints: [SIMD3<Float>] = []
        var outlines: [Outline] = []
        outlines.reserveCapacity(outlineCount)
        for _ in 0..<outlineCount {
            _ = try reader.u8()
            let flags = try reader.u8()
            let count = Int(try reader.u16())
            let start = outlinePoints.count
            for _ in 0..<count { outlinePoints.append(try reader.point()) }
            outlines.append(Outline(flags: flags, points: start..<outlinePoints.count))
        }

        var neuronPoints: [SIMD3<Float>] = []
        var distances: [Float] = []
        var polylines: [Range<Int>] = []
        var polylineNeuron: [Int] = []
        var neurons: [Neuron] = []
        neurons.reserveCapacity(neuronCount)
        for index in 0..<neuronCount {
            let layer = Int(try reader.u8())
            let sign = Int(Int8(bitPattern: try reader.u8()))
            guard let role = Role(rawValue: try reader.u8()) else { throw DecodeError.inconsistent }
            let subtype = Int(try reader.u8())
            let lineCount = Int(try reader.u16())
            let firstLine = polylines.count
            for _ in 0..<lineCount {
                let count = Int(try reader.u16())
                let start = neuronPoints.count
                for _ in 0..<count {
                    neuronPoints.append(try reader.point())
                    distances.append(Float(try reader.u16()) / 65535)
                }
                polylines.append(start..<neuronPoints.count)
                polylineNeuron.append(index)
            }
            neurons.append(Neuron(
                layer: layer,
                sign: max(-1, min(1, sign)),
                role: role,
                subtype: subtype,
                polylines: firstLine..<polylines.count
            ))
        }

        var edges: [Edge] = []
        edges.reserveCapacity(edgeCount)
        for _ in 0..<edgeCount {
            let pre = Int(try reader.u16())
            let post = Int(try reader.u16())
            let weight = Int(try reader.u16())
            guard pre < neuronCount, post < neuronCount else { throw DecodeError.inconsistent }
            edges.append(Edge(pre: pre, post: post, weight: weight))
        }

        var synapses: [Synapse] = []
        synapses.reserveCapacity(synapseCount)
        for _ in 0..<synapseCount {
            let pre = Int(try reader.u16())
            let post = Int(try reader.u16())
            guard pre < neuronCount, post < neuronCount else { throw DecodeError.inconsistent }
            synapses.append(Synapse(pre: pre, post: post, point: try reader.point()))
        }

        var labels: [Label] = []
        for _ in 0..<labelCount {
            let length = Int(try reader.u8())
            let name = String(decoding: try reader.bytes(length), as: UTF8.self)
            labels.append(Label(name: name, point: try reader.point()))
        }
        guard reader.isAtEnd else { throw DecodeError.inconsistent }

        return FlyAuditoryCircuit(
            outlinePoints: outlinePoints,
            outlines: outlines,
            neuronPoints: neuronPoints,
            neuronPointDistance: distances,
            polylines: polylines,
            polylineNeuron: polylineNeuron,
            neurons: neurons,
            edges: edges.sorted { ($0.pre, $0.post) < ($1.pre, $1.post) },
            synapses: synapses.sorted { ($0.pre, $0.post) < ($1.pre, $1.post) },
            labels: labels,
            micrometersPerUnit: micrometers
        )
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw DecodeError.truncated }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw DecodeError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() throws -> UInt16 {
            let low = UInt16(try u8())
            let high = UInt16(try u8())
            return low | high << 8
        }

        mutating func u32() throws -> UInt32 {
            let low = UInt32(try u16())
            let high = UInt32(try u16())
            return low | high << 16
        }

        mutating func f32() throws -> Float {
            Float(bitPattern: try u32())
        }

        mutating func point() throws -> SIMD3<Float> {
            let x = Int16(bitPattern: try u16())
            let y = Int16(bitPattern: try u16())
            let z = Int16(bitPattern: try u16())
            return SIMD3(Float(x), Float(y), Float(z)) / 32767
        }
    }
}

/// 斜看过去、慢慢转着的透视相机。模型坐标 x 向右、y 向下、z 向里；先绕竖轴转 `yaw`，
/// 再绕水平轴俯仰 `pitch`，最后按 `distance` 做透视。投影结果以画布中心为原点、以 `scale` 点为单位。
public struct FlyBrainCamera: Sendable, Equatable {
    public var yaw: Float
    public var pitch: Float
    public var distance: Float = 3.2

    public init(yaw: Float, pitch: Float, distance: Float = 3.2) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
    }

    /// 转得很慢的往复：约 50 秒一个来回，左右各转 26°，俯仰在 10°…16° 之间。
    public static func orbit(at time: TimeInterval) -> FlyBrainCamera {
        let yaw = 0.45 * sin(time * 2 * .pi / 50)
        let pitch = 0.23 + 0.05 * sin(time * 2 * .pi / 37 + 1.3)
        return FlyBrainCamera(yaw: Float(yaw), pitch: Float(pitch))
    }

    /// 静止画面用的角度：略侧一点，看得出立体。
    public static let resting = FlyBrainCamera(yaw: 0.32, pitch: 0.24)

    /// 投影成 (x, y, 透视缩放)。透视缩放 > 1 的离镜头更近。
    public func project(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let cosYaw = cos(yaw), sinYaw = sin(yaw)
        let cosPitch = cos(pitch), sinPitch = sin(pitch)
        let x1 = point.x * cosYaw + point.z * sinYaw
        let z1 = -point.x * sinYaw + point.z * cosYaw
        let y2 = point.y * cosPitch - z1 * sinPitch
        let z2 = point.y * sinPitch + z1 * cosPitch
        let perspective = distance / max(distance + z2, 0.2)
        return SIMD3(x1 * perspective, y2 * perspective, perspective)
    }

    /// 批量投影到 `output`（只取 x、y），省掉每个点各算一次三角函数。
    public func project(_ points: [SIMD3<Float>], into output: inout [SIMD2<Float>]) {
        let cosYaw = cos(yaw), sinYaw = sin(yaw)
        let cosPitch = cos(pitch), sinPitch = sin(pitch)
        if output.count != points.count {
            output = Array(repeating: .zero, count: points.count)
        }
        for index in points.indices {
            let point = points[index]
            let x1 = point.x * cosYaw + point.z * sinYaw
            let z1 = -point.x * sinYaw + point.z * cosYaw
            let y2 = point.y * cosPitch - z1 * sinPitch
            let z2 = point.y * sinPitch + z1 * cosPitch
            let perspective = distance / max(distance + z2, 0.2)
            output[index] = SIMD2(x1 * perspective, y2 * perspective)
        }
    }
}

/// 在真实接线上跑的一个简化神经元模型（发放率模型）：触角听觉神经元按各自偏好的频段读频谱，
/// 信号沿真实突触往里传；兴奋性的推高下游，抑制性的压低。神经元活跃度越过阈值就「放电」一次，
/// 渲染层沿它的纤维画一道往外跑的光，并点亮它发出的突触。
///
/// 这是艺术化的演示：接线是真的，「怎么听」是设计出来的。真实果蝇只对几百赫兹的近场振动有反应。
public struct FlyAuditorySimulation: Sendable {
    /// 一次放电：哪个神经元、从模拟时钟的哪一刻开始。
    public struct Spike: Sendable, Equatable {
        public let neuron: Int
        public let start: TimeInterval
    }

    /// 放电的光沿纤维从起点跑到最远处要多久。
    public static let spikeTravel: TimeInterval = 0.42
    /// 兴奋性上游满负荷时下游收到的输入。大于 1 才能让信号一路传到下行神经元。
    static let gain: Float = 3.0
    /// 同一时刻最多画这么多道光，再多就挑活跃度高的。
    static let maximumSpikes = 140
    static let firingThreshold: Float = 0.5

    public private(set) var activation: [Float]
    public private(set) var spikes: [Spike] = []
    public private(set) var time: TimeInterval = 0

    private let inputBand: [Float]
    private let incoming: [[(source: Int, weight: Float)]]
    private let timeConstant: [Float]
    private var refractory: [Float]
    /// 听觉神经元各自频段最近一段的平均响度：它们主要对「比刚才更响」起反应（适应），
    /// 一直响着的音只留一点持续的活跃。
    private var adaptation: [Float]
    /// 每个神经元的疲劳：一直兴奋着就慢慢自己压下去，深层的回路不会在静音后自己转个不停。
    private var fatigue: [Float]
    private var random: ImmersiveRandom

    public init(circuit: FlyAuditoryCircuit, seed: UInt64 = 0xF1A1) {
        random = ImmersiveRandom(seed: seed)
        let count = circuit.neurons.count
        activation = Array(repeating: 0, count: count)
        refractory = Array(repeating: 0, count: count)
        adaptation = Array(repeating: 0, count: count)
        fatigue = Array(repeating: 0, count: count)

        // 每个听觉神经元偏好频率轴上的一个位置：B 组在低频那段，A 组偏中高频，同组不同亚型错开。
        var bands = Array(repeating: Float(-1), count: count)
        var times = Array(repeating: Float(0.09), count: count)
        for (index, neuron) in circuit.neurons.enumerated() {
            let jitter = Float(random.unit()) * 0.06
            switch neuron.role {
            case .lowFrequencyInput:
                bands[index] = 0.02 + Float(max(neuron.subtype - 1, 0)) * 0.06 + jitter
            case .highFrequencyInput:
                bands[index] = 0.24 + Float(max(neuron.subtype - 1, 0)) * 0.09 + jitter
            case .interneuron, .descending:
                // 越往里反应越慢一点，信号一层层往里推的样子才看得出来。
                times[index] = 0.08 + 0.025 * Float(neuron.layer) + Float(random.unit()) * 0.04
            }
        }
        inputBand = bands
        timeConstant = times

        // 每个神经元收到的输入按兴奋性上游的总权重归一：兴奋性上游都满负荷时输入是 `gain`。
        var lists = Array(repeating: [(source: Int, weight: Float)](), count: count)
        var excitatory = Array(repeating: Float(0), count: count)
        for edge in circuit.edges where circuit.neurons[edge.pre].sign >= 0 {
            excitatory[edge.post] += Float(edge.weight)
        }
        for edge in circuit.edges {
            let sign = circuit.neurons[edge.pre].sign
            let signed: Float = sign > 0 ? 1 : (sign < 0 ? -0.9 : 0.4)
            let normalized = Float(edge.weight) / max(excitatory[edge.post], 1)
            lists[edge.post].append((edge.pre, signed * normalized * Self.gain))
        }
        incoming = lists
    }

    /// 推进一帧。`levels` 是频谱（低频在前），`beat` 是这一帧的鼓点力度。
    public mutating func step(dt rawDT: TimeInterval, levels: [Double], beat: Double) {
        let dt = Float(min(max(rawDT, 0), 1.0 / 15))
        guard dt > 0 else { return }
        time += Double(dt)
        let previous = activation
        let kick = Float(min(max(beat, 0), 1))

        let adaptationFollow = 1 - exp(-dt / 0.5)
        let fatigueFollow = 1 - exp(-dt / 1.2)
        for index in activation.indices {
            var drive: Float
            if inputBand[index] >= 0 {
                let level = Float(Self.sample(levels, at: Double(inputBand[index])))
                let rise = max(0, level - adaptation[index])
                adaptation[index] += (level - adaptation[index]) * adaptationFollow
                // 有一点自发的底噪，安静段落里也偶尔闪一下。
                let noise: Float = Float(random.unit()) < 0.0015 ? 0.9 : 0
                drive = rise * 5 + level * 0.3 + kick * level * 0.6 + noise
            } else {
                drive = 0
                for (source, weight) in incoming[index] {
                    drive += previous[source] * weight
                }
            }
            drive -= fatigue[index] * 0.9
            let target = min(max((drive - 0.18) * 1.5, 0), 1)
            let follow = 1 - exp(-dt / timeConstant[index])
            activation[index] += (target - activation[index]) * follow
            fatigue[index] += (activation[index] - fatigue[index]) * fatigueFollow

            refractory[index] = max(0, refractory[index] - dt)
            if activation[index] > Self.firingThreshold, refractory[index] == 0 {
                spikes.append(Spike(neuron: index, start: time))
                refractory[index] = 0.24 + Float(random.unit()) * 0.22
            }
        }

        let horizon = time - Self.spikeTravel * 1.6
        spikes.removeAll { $0.start < horizon }
        if spikes.count > Self.maximumSpikes {
            spikes.removeFirst(spikes.count - Self.maximumSpikes)
        }
    }

    /// 某次放电此刻跑到了纤维的哪儿（0…1 的路程比例），跑完以后大于 1。
    public func front(of spike: Spike) -> Double {
        (time - spike.start) / Self.spikeTravel
    }

    /// 频率轴上 0…1 的位置取频谱的值（线性插值）。
    static func sample(_ levels: [Double], at position: Double) -> Double {
        guard !levels.isEmpty else { return 0 }
        guard levels.count > 1 else { return min(max(levels[0], 0), 1) }
        let scaled = min(max(position, 0), 1) * Double(levels.count - 1)
        let lower = Int(scaled)
        let upper = min(lower + 1, levels.count - 1)
        let fraction = scaled - Double(lower)
        let value = levels[lower] + (levels[upper] - levels[lower]) * fraction
        return min(max(value, 0), 1)
    }
}
