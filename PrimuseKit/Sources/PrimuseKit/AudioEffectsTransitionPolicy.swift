import Foundation

// 压缩器(Apple DynamicsProcessor)和混响(AVAudioUnitReverb)的参数一写就是硬切,没有内部平滑。
// 编译机 macOS 27 上离线渲染实测(5 kHz 高通后的毛刺,信号 -3 dBFS):
// 旁通开压缩器 -19 到 -11 dBFS,阈值一步跳下去约 -40 dBFS,混响干湿比一步 20→60 约 -25 dBFS。
// 所以压缩器按速率一点点挪参数,混响改成并联、干湿比落在混音节点的音量上(那里有平滑)。

/// 压缩器的开关、切预设、拖参数:每 10 ms 挪一小步,先降增益、再改压缩形状、最后升增益,
/// 每一步的总增益都不超过当时形状下不会削波的上限。
public enum CompressorTransitionPolicy {
    public struct Parameters: Equatable, Sendable {
        public var threshold: Float
        public var headRoom: Float
        public var gain: Float

        public init(threshold: Float, headRoom: Float, gain: Float) {
            self.threshold = threshold
            self.headRoom = headRoom
            self.gain = gain
        }
    }

    /// 「关」:阈值高于任何不削波的信号,逐样本透明。
    public static let neutralThreshold: Float = 20
    /// 每一步最多挪多少。阈值每 10 ms 降 1 dB 时毛刺在 -53 dBFS 以下;增益每步 0.25 dB 约 -58 dBFS。
    public static let shapeStepDB: Float = 1
    public static let gainStepDB: Float = 0.25
    public static let tickInterval: TimeInterval = 0.01

    /// 输入 0 dBFS、总增益 0 时的输出峰值(dBFS),按阈值 × 余量实测(噪声、正弦、鼓点,起音 1 / 10 ms
    /// 取最坏,含起音过冲)。阈值到 0 以上就不压了。
    static let ceilingThresholds: [Float] = [-40, -30, -20, -10, -5, 0]
    static let ceilingHeadRooms: [Float] = [0.1, 2, 5, 10, 20, 40]
    static let ceilingTable: [[Float]] = [
        [-26.6, -24.8, -22.0, -17.9, -11.7, -7.8],
        [-16.6, -14.8, -12.2, -9.7, -7.7, -4.5],
        [-9.2, -8.5, -7.3, -5.9, -3.7, -1.8],
        [-4.2, -3.3, -2.2, -1.4, -0.6, 0],
        [-1.2, -0.7, -0.4, 0, 0, 0],
        [0, 0, 0, 0, 0, 0],
    ]
    /// 插值在格点之间可能偏乐观,再留一点。
    static let ceilingMarginDB: Float = 0.5

    /// 这组阈值与余量下,总增益最多加多少还不会把满幅的歌推过 0 dBFS。
    public static func maximumGainDB(threshold: Float, headRoom: Float) -> Float {
        let ceiling = interpolate(
            ceilingTable,
            rows: ceilingThresholds, row: threshold,
            columns: ceilingHeadRooms, column: headRoom
        )
        return max(0, -ceiling - ceilingMarginDB)
    }

    /// 实际生效的目标:开着时用户的阈值与余量、总增益封顶;关着时阈值放到透明、总增益 0。
    public static func target(
        enabled: Bool,
        threshold: Float,
        headRoom: Float,
        gain: Float
    ) -> Parameters {
        guard enabled else {
            return Parameters(threshold: neutralThreshold, headRoom: headRoom, gain: 0)
        }
        let cap = maximumGainDB(threshold: threshold, headRoom: headRoom)
        return Parameters(threshold: threshold, headRoom: headRoom, gain: min(gain, cap))
    }

    /// 从 `current` 往 `target` 走一步;已经到了就原样返回。
    public static func step(from current: Parameters, toward target: Parameters) -> Parameters {
        let shape = nextShape(from: current, toward: target)
        // 增益先降:比目标高,或者高到改完这一步形状就会削波。
        let ceiling = min(
            target.gain,
            maximumGainDB(threshold: current.threshold, headRoom: current.headRoom),
            maximumGainDB(threshold: shape.threshold, headRoom: shape.headRoom)
        )
        var next = current
        if current.gain > ceiling {
            next.gain = approach(current.gain, ceiling, by: gainStepDB)
        } else if shape != current {
            next = shape
        } else {
            next.gain = approach(current.gain, target.gain, by: gainStepDB)
        }
        return next
    }

    /// 只挪阈值或余量中的一个,先阈值。
    private static func nextShape(from current: Parameters, toward target: Parameters) -> Parameters {
        var next = current
        if current.threshold != target.threshold {
            if current.threshold >= 0, target.threshold >= 0 {
                // 0 dBFS 以上都等于不压,直接跳。
                next.threshold = target.threshold
            } else if target.threshold < 0 {
                // 从不压的那段往下走时从 0 dBFS 起步。
                next.threshold = approach(min(current.threshold, 0), target.threshold, by: shapeStepDB)
            } else {
                // 往上走到 0 dBFS 后直接放到目标。
                next.threshold = approach(current.threshold, 0, by: shapeStepDB)
                if next.threshold >= 0 { next.threshold = target.threshold }
            }
        } else {
            next.headRoom = approach(current.headRoom, target.headRoom, by: shapeStepDB)
        }
        return next
    }

    static func approach(_ value: Float, _ target: Float, by step: Float) -> Float {
        if value < target { return min(target, value + step) }
        if value > target { return max(target, value - step) }
        return value
    }
}

/// 混响:并联的干湿两路音量、开着时要预留的余量。
public enum ReverbTransitionPolicy {
    /// AVAudioUnitReverb 的 wetDryMix = w(百分比)等于干声 × √(1−w) + 全湿 × √w,实测残差 -150 dB。
    public static func mixGains(wetPercent: Float) -> (dry: Float, wet: Float) {
        let wet = max(0, min(1, wetPercent / 100))
        return (sqrt(1 - wet), sqrt(wet))
    }

    /// 开着混响时峰值比干声高多少(dB),按 AVAudioUnitReverbPreset 原始值。100 Hz–5 kHz 正弦与
    /// 白噪声里取最坏;稀疏的鼓点峰值反而下降。
    static let headroomWetPercents: [Float] = [0, 1, 2, 5, 10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100]
    static let headroomByPreset: [Int: [Float]] = [
        0: [0, 0.56, 0.77, 1.19, 1.80, 2.22, 2.53, 2.76, 2.95, 3.22, 3.39, 3.46, 3.45, 3.32, 2.99, 1.49],
        1: [0, 1.17, 1.65, 2.50, 3.32, 3.86, 4.26, 4.58, 4.84, 5.25, 5.61, 5.86, 6.03, 6.10, 6.03, 6.19],
        2: [0, 0.83, 1.15, 1.75, 2.39, 2.81, 3.11, 3.35, 3.54, 3.82, 3.98, 4.06, 4.05, 3.92, 3.60, 2.39],
        3: [0, 0.85, 1.18, 1.77, 2.36, 2.77, 3.07, 3.30, 3.51, 3.82, 4.02, 4.16, 4.22, 4.18, 4.02, 3.23],
        4: [0, 1.02, 1.47, 2.26, 3.03, 3.53, 3.91, 4.21, 4.45, 4.82, 5.07, 5.23, 5.30, 5.26, 5.33, 5.21],
        5: [0, 1.18, 1.62, 2.40, 3.15, 3.70, 4.13, 4.47, 4.75, 5.18, 5.52, 5.89, 6.16, 6.34, 6.40, 6.13],
        8: [0, 0.72, 0.98, 1.44, 1.86, 2.13, 2.31, 2.45, 2.55, 2.67, 2.69, 2.62, 2.52, 2.49, 2.28, 3.61],
    ]

    /// 噪声的峰值每段都不一样,表里是一段的结果,再留一点。
    static let headroomMarginDB: Float = 0.5

    /// 干湿比每 10 ms 最多变多少(百分点)。混音节点约一个渲染周期就到位,一下子把湿声关掉会把
    /// 混响尾巴截得太陡(换房间时 1 kHz 上约 -45 dBFS 的毛刺)。
    public static let wetStepPercent: Float = 5

    /// 开着混响时整体要压低多少(dB,≥ 0)。没测过的预设按所有预设里最坏的算。
    public static func headroomDB(presetRawValue: Int, wetPercent: Float) -> Float {
        guard wetPercent > 0 else { return 0 }
        let rows = headroomByPreset[presetRawValue].map { [$0] } ?? Array(headroomByPreset.values)
        let measured = rows.map { interpolate($0, at: headroomWetPercents, wetPercent) }.max() ?? 0
        return measured + headroomMarginDB
    }
}

// MARK: - 插值

private func interpolate(_ values: [Float], at grid: [Float], _ x: Float) -> Float {
    guard let first = grid.first, let last = grid.last, values.count == grid.count else { return 0 }
    if !(x > first) { return values[0] }
    if x >= last { return values[values.count - 1] }
    let upper = grid.firstIndex { $0 >= x } ?? grid.count - 1
    let lower = upper - 1
    let t = (x - grid[lower]) / (grid[upper] - grid[lower])
    return values[lower] + (values[upper] - values[lower]) * t
}

private func interpolate(
    _ table: [[Float]],
    rows: [Float], row: Float,
    columns: [Float], column: Float
) -> Float {
    let perRow = table.map { interpolate($0, at: columns, column) }
    return interpolate(perRow, at: rows, row)
}
