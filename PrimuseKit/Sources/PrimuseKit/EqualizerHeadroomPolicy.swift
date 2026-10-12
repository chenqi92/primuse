import Foundation

/// 均衡器有频段提升时整体先压低多少，免得接近满刻度的歌被推过 0 dBFS 削波。
///
/// 按整条曲线的实际最高点算，不按单段最大值：参数型频段带宽 1 倍频程、频段间隔也是
/// 1 倍频程，相邻频段的裙边会叠起来。「低音」预设单段最高 +6，叠加后 +7.1 dB；
/// 十段全 +12 时最高到 +19.2 dB。滤波器按 RBJ 峰值均衡（带宽以倍频程计）建模，
/// 与 AVAudioUnitEQ `.parametric` 频段实测的频响逐点一致。
public enum EqualizerHeadroomPolicy {
    /// 低于这个量的提升不压：听不出差别，也免得曲线几乎是平的时候提示一个 -0.0 dB。
    static let ignoredBoostDB = 0.05

    /// 整体增益（dB），只会是 0 或负数。
    public static func preampDB(
        bandGainsDB: [Float],
        frequencies: [Float],
        bandwidthOctaves: Float,
        sampleRate: Double
    ) -> Float {
        let peak = peakGainDB(
            bandGainsDB: bandGainsDB,
            frequencies: frequencies,
            bandwidthOctaves: bandwidthOctaves,
            sampleRate: sampleRate
        )
        guard peak > ignoredBoostDB else { return 0 }
        return Float(-peak)
    }

    // MARK: - 换曲线的过渡
    //
    // 频段增益和整体增益都不是一写就到位：AVAudioUnitEQ 的频段增益在约 25 ms 里平滑过去，
    // 过渡中会比终值多出约 1 dB（全 -12 切回平直时最明显）；混音节点音量要约一个渲染周期
    // （4096 帧缓冲时约 85 ms）。两者同时改，近满幅的歌会短暂冲过 0 dBFS。所以换曲线时
    // 先按新旧曲线的上包络再多压一点，等压下去了再改频段，频段到位后才放回终值。
    // 编译机上离线渲染，预设两两互切、25 Hz–18 kHz 正弦都不过冲。

    /// 过渡期间在上包络之外再多压的量。
    public static let transitionMarginDB: Float = 2

    /// 频段改完后过多久把整体增益放回终值。
    public static let releaseDelay: TimeInterval = 0.15

    /// 过渡中出现过的曲线逐段取大。
    public static func ceiling(_ a: [Float], _ b: [Float]) -> [Float] {
        (0..<max(a.count, b.count)).map { index in
            max(index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
        }
    }

    /// 过渡期间的整体增益（dB）：按上包络压，再多压 `transitionMarginDB`。
    public static func transitionPreampDB(
        ceilingBandGainsDB: [Float],
        frequencies: [Float],
        bandwidthOctaves: Float,
        sampleRate: Double
    ) -> Float {
        preampDB(
            bandGainsDB: ceilingBandGainsDB,
            frequencies: frequencies,
            bandwidthOctaves: bandwidthOctaves,
            sampleRate: sampleRate
        ) - transitionMarginDB
    }

    /// 压低整体增益后要等多久再改频段：音量约一个渲染周期才到位，写入又可能落在周期中间，
    /// 按两个周期再加 15 ms 算，至少 60 ms。读不到缓冲时长时按 4096 帧 / 44.1 kHz 估。
    public static func lowerSettleDelay(ioBufferDuration: TimeInterval?) -> TimeInterval {
        let fallback = 4_096.0 / 44_100
        var buffer = ioBufferDuration ?? fallback
        if !buffer.isFinite || buffer <= 0 { buffer = fallback }
        return max(0.06, 2 * min(buffer, 0.5) + 0.015)
    }

    /// 20 Hz 到 20 kHz（或奈奎斯特频率以下）内曲线的最高增益（dB）。
    public static func peakGainDB(
        bandGainsDB: [Float],
        frequencies: [Float],
        bandwidthOctaves: Float,
        sampleRate: Double
    ) -> Double {
        guard sampleRate.isFinite, sampleRate > 0, bandwidthOctaves > 0 else { return 0 }
        let filters = zip(bandGainsDB, frequencies).compactMap { gain, frequency in
            PeakingFilter(
                gainDB: Double(gain),
                frequency: Double(frequency),
                bandwidthOctaves: Double(bandwidthOctaves),
                sampleRate: sampleRate
            )
        }
        guard !filters.isEmpty else { return 0 }

        // 1/48 倍频程的网格加上各频段中心：1 倍频程宽的峰在格点之间差不到 0.01 dB。
        // 拖动频段时每次都要重算，三角函数每个频点只算一次。
        let upper = min(20_000, sampleRate * 0.49)
        var probes = filters.map(\.frequency).filter { $0 >= 20 && $0 <= upper }
        var frequency = 20.0
        while frequency <= upper {
            probes.append(frequency)
            frequency *= pow(2, 1.0 / 48)
        }
        var peak = -Double.infinity
        for probe in probes {
            let w = 2 * Double.pi * probe / sampleRate
            let point = FrequencyPoint(cos1: cos(w), sin1: sin(w), cos2: cos(2 * w), sin2: sin(2 * w))
            var powerRatio = 1.0
            for filter in filters { powerRatio *= filter.powerRatio(at: point) }
            peak = max(peak, 10 * log10(powerRatio))
        }
        return peak
    }

    private struct FrequencyPoint {
        let cos1, sin1, cos2, sin2: Double
    }

    /// 一个参数型频段的双二阶滤波器系数（a0 归一前）。
    private struct PeakingFilter {
        let frequency: Double
        let b0, b1, b2, a0, a1, a2: Double

        init?(gainDB: Double, frequency: Double, bandwidthOctaves: Double, sampleRate: Double) {
            guard gainDB.isFinite, gainDB != 0, frequency > 0, frequency < sampleRate / 2 else {
                return nil
            }
            let a = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) * sinh(log(2) / 2 * bandwidthOctaves * w0 / sin(w0))
            self.frequency = frequency
            b0 = 1 + alpha * a
            b1 = -2 * cos(w0)
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cos(w0)
            a2 = 1 - alpha / a
        }

        /// 这个频点上输出与输入的功率比（|H|²）。
        func powerRatio(at point: FrequencyPoint) -> Double {
            func power(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
                let real = c0 + c1 * point.cos1 + c2 * point.cos2
                let imaginary = c1 * point.sin1 + c2 * point.sin2
                return real * real + imaginary * imaginary
            }
            return power(b0, b1, b2) / power(a0, a1, a2)
        }
    }
}
