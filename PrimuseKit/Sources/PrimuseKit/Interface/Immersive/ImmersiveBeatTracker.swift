import Foundation

/// 全屏效果从频谱里读出来的一帧摘要：整体能量、低频、频谱重心，加上从低频起伏里找到的鼓点、
/// 鼓点后迅速衰减的包络，以及最近几拍推出来的拍速。
///
/// 频段按对数频率从低到高排（手机与 Mac 32 段、电视 96 段），这里只看相对位置，不依赖段数。
public struct ImmersiveAudioFeatures: Equatable, Sendable {
    public var energy: Double = 0
    public var bass: Double = 0
    /// 能量在频率轴上的重心：0 是最低频，1 是最高频。
    public var centroid: Double = ImmersiveBeatTracker.restingCentroid
    /// 这一帧检测到鼓点时是它的力度（0…1），其余帧是 0。
    public var beat: Double = 0
    /// 鼓点那一刻接近 1，之后约 0.2 秒衰减一半。
    public var pulse: Double = 0
    /// 最近几拍的间隔折算出的拍速（每秒几拍，折进 1.3…2.6 这一个八度）；拍数不够时为 nil。
    public var beatsPerSecond: Double?
    /// 最近几拍的间隔有多整齐：1 是严丝合缝，0 是乱的或还没有拍子。
    public var steadiness: Double = 0
    /// 低、中、高三段（`ImmersiveAudioRegister`）这一帧的起音力度（0…1），没有起音时是 0。
    /// 低段就是 `beat`；中段多是军鼓与人声的字头，高段多是镲片。
    public var onsets: [Double] = [0, 0, 0]
    /// 这一刻在这首歌自己的响度范围里排在哪儿：0 是最近最安静的段落，1 是最响的段落，按零点几秒平滑。
    /// 母带压得很平的歌整首的整体电平只差几个百分点，按绝对值看不出主歌与副歌，所以按最近的起伏展开。
    public var intensity: Double = 0
    /// 低、中、高三段各自在自己的范围里排在哪儿，算法同 `intensity`。前奏只有钢琴时中段高、低段低。
    public var registerIntensity: [Double] = [0, 0, 0]
    /// 低、中、高三段这一帧的平均电平（0…1，未展开），用来分辨某一段是真的没声音还是一直很平。
    public var registerLevels: [Double] = [0, 0, 0]
    /// 音色比这首歌最近十几秒的平常亮多少：-1…1（频谱重心偏离均值多少个标准差，压进这个区间）。
    public var brightnessShift: Double = 0

    public init() {}
}

/// 频谱按对数频率分成的三段，全屏效果里按声部分工用。
public enum ImmersiveAudioRegister: Int, CaseIterable, Sendable {
    /// 最低的六分之一：底鼓、贝斯。
    case low
    /// 到八分之五：军鼓、人声、大部分旋律乐器。
    case mid
    /// 其余：镲片、齿音、空气感。
    case high

    /// 这一段在 `count` 个频段里占哪几段。
    public static func range(_ register: ImmersiveAudioRegister, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let lowEnd = min(count, max(1, count / 6))
        let midEnd = min(count, max(lowEnd + 1, count * 5 / 8))
        switch register {
        case .low: return 0..<lowEnd
        case .mid: return lowEnd..<midEnd
        case .high: return midEnd..<count
        }
    }
}

/// 一个电平在这首歌里的相对位置：此刻的电平（零点几秒平滑）在最近 40 秒里排第几（百分位）。
/// 一直一样响时落在 0.5 附近；主歌接副歌时副歌排在前面，间奏排到最后。几乎静音时不记，
/// 歌与歌之间的停顿不会把后面的都抬成「很响」。
struct ImmersiveDynamicRange: Sendable {
    /// 每隔这么久记一个样本。
    static let sampleInterval: TimeInterval = 0.25
    /// 记最近这么多个样本（40 秒）。
    static let capacity = 160
    /// 相差不到这么多算一样响：整首几乎一样响的歌不会被细小的抖动拉成满幅。
    static let tolerance = 0.012
    /// 样本不够时先报中间值。
    static let minimumSamples = 8

    private(set) var level = 0.0
    private var primed = false
    private var samples: [Double] = []
    private var cursor = 0
    private var sinceSample: TimeInterval = .infinity

    mutating func reset() {
        primed = false
        samples.removeAll(keepingCapacity: true)
        cursor = 0
        sinceSample = .infinity
    }

    /// 喂一帧电平，返回 0…1 的相对位置；`audible` 为 false（几乎静音）时返回 0。
    mutating func update(_ value: Double, dt: TimeInterval, audible: Bool) -> Double {
        guard audible else {
            primed = false
            return 0
        }
        if !primed {
            primed = true
            level = value
        }
        level += (value - level) * (1 - ImmersiveBeatTracker.decay(dt, halfLife: 0.35))
        sinceSample += dt
        if sinceSample >= Self.sampleInterval {
            sinceSample = 0
            if samples.count < Self.capacity {
                samples.append(level)
            } else {
                samples[cursor] = level
                cursor = (cursor + 1) % Self.capacity
            }
        }
        guard samples.count >= Self.minimumSamples else { return 0.5 }
        var below = 0.0
        for sample in samples {
            if sample < level - Self.tolerance {
                below += 1
            } else if sample <= level + Self.tolerance {
                below += 0.5
            }
        }
        return below / Double(samples.count)
    }
}

/// 一段频率上的起音：正向变化量高过最近一段的均值加 1.4 个标准差就算一次。
struct ImmersiveOnsetDetector: Sendable {
    let refractory: TimeInterval
    private var mean = 0.0
    private var variance = 0.0
    private var lastOnset = -Double.infinity

    init(refractory: TimeInterval) {
        self.refractory = refractory
    }

    /// 返回这一帧的起音力度（0 是没有）。
    mutating func update(flux: Double, at time: TimeInterval, dt: TimeInterval, audible: Bool) -> Double {
        let deviation = variance.squareRoot()
        let threshold = mean + 1.4 * deviation + 0.012
        var strength = 0.0
        if flux > threshold, audible, time - lastOnset >= refractory {
            strength = min(max((flux - mean) / (3 * deviation + 0.03), 0.15), 1)
            lastOnset = time
        }
        let follow = 1 - ImmersiveBeatTracker.decay(dt, halfLife: 1.0)
        mean += (flux - mean) * follow
        variance += ((flux - mean) * (flux - mean) - variance) * follow
        return strength
    }
}

/// 逐帧喂频谱、吐出 `ImmersiveAudioFeatures`。值类型，由渲染层各自持有一份，
/// 同一个舞台里的几层不共享状态。
public struct ImmersiveBeatTracker: Sendable {
    public static let restingCentroid = 0.35

    /// 两个鼓点之间至少隔这么久，免得一记重拍的上升沿被数成两拍。
    static let refractoryInterval: TimeInterval = 0.2
    /// 低于这个整体能量（几乎静音）不找鼓点。
    static let silenceFloor = 0.04
    /// 只拿最近这些拍算拍速。
    static let onsetMemory = 10
    /// 折算拍间隔的那个八度：0.385…0.77 秒，也就是每分钟 78…156 拍。
    static let foldedIntervalRange = 0.385..<0.77

    private var lastTime: TimeInterval?
    private var previousLevels: [Double] = []
    private var fluxMean = 0.0
    private var fluxVariance = 0.0
    private var lastBeatTime = -Double.infinity
    private var onsets: [TimeInterval] = []
    private var centroid = restingCentroid
    private var pulse = 0.0
    private var midOnsets = ImmersiveOnsetDetector(refractory: 0.14)
    private var highOnsets = ImmersiveOnsetDetector(refractory: 0.1)
    private var loudness = ImmersiveDynamicRange()
    private var registerLoudness = Array(repeating: ImmersiveDynamicRange(), count: 3)
    private var centroidMean = restingCentroid
    private var centroidVariance = 0.0
    private var centroidPrimed = false

    public init() {}

    public mutating func update(levels: [Double], at time: TimeInterval) -> ImmersiveAudioFeatures {
        let elapsed = lastTime.map { time - $0 } ?? 0
        lastTime = time
        // 暂停、切后台回来时间会跳一大截：旧的拍子已经不算数了。
        if elapsed > 1.5 || elapsed < 0 {
            onsets.removeAll()
            previousLevels.removeAll()
        }
        // 停了半分钟以上多半已经换了歌：按新的起伏重新展开。
        if elapsed > 30 {
            loudness.reset()
            for index in registerLoudness.indices { registerLoudness[index].reset() }
            centroidPrimed = false
        }
        let dt = min(max(elapsed, 0), 0.25)

        var features = ImmersiveAudioFeatures()
        let clamped = levels.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        guard !clamped.isEmpty else {
            pulse *= Self.decay(dt, halfLife: 0.2)
            previousLevels.removeAll()
            features.pulse = pulse
            features.centroid = centroid
            return features
        }

        let count = clamped.count
        let energy = clamped.reduce(0, +) / Double(count)
        let lowCount = max(1, min(count, max(2, count / 6)))
        let bass = clamped.prefix(lowCount).reduce(0, +) / Double(lowCount)
        features.energy = energy
        features.bass = bass

        let total = clamped.reduce(0, +)
        if total > 0.01, count > 1 {
            var weighted = 0.0
            for (index, level) in clamped.enumerated() {
                weighted += Double(index) / Double(count - 1) * level
            }
            centroid += (weighted / total - centroid) * (1 - Self.decay(dt, halfLife: 0.45))
        }
        features.centroid = centroid

        let audible = energy > Self.silenceFloor
        if audible, dt > 0 {
            if !centroidPrimed {
                centroidPrimed = true
                centroidMean = centroid
                centroidVariance = 0
            }
            let follow = 1 - Self.decay(dt, halfLife: 12)
            centroidMean += (centroid - centroidMean) * follow
            centroidVariance += ((centroid - centroidMean) * (centroid - centroidMean) - centroidVariance) * follow
            let deviation = max(centroidVariance.squareRoot(), 0.012)
            features.brightnessShift = tanh((centroid - centroidMean) / deviation * 0.6)
        }
        features.intensity = loudness.update(energy, dt: dt, audible: audible)
        for register in ImmersiveAudioRegister.allCases {
            let range = ImmersiveAudioRegister.range(register, count: count)
            let level = range.isEmpty ? 0 : clamped[range].reduce(0, +) / Double(range.count)
            features.registerLevels[register.rawValue] = level
            features.registerIntensity[register.rawValue] = registerLoudness[register.rawValue]
                .update(level, dt: dt, audible: audible)
        }

        // 鼓点：低三分之一频段的正向变化量，高过最近一段的均值加 1.4 个标准差。
        var flux = 0.0
        var registerFlux = [0.0, 0.0, 0.0]
        if previousLevels.count == count {
            let fluxCount = max(1, count / 3)
            for index in 0..<fluxCount {
                let rise = clamped[index] - previousLevels[index]
                if rise > 0 { flux += rise * (index < lowCount ? 1.5 : 1) }
            }
            flux /= Double(fluxCount)
            for register in [ImmersiveAudioRegister.mid, .high] {
                let range = ImmersiveAudioRegister.range(register, count: count)
                guard !range.isEmpty else { continue }
                var rise = 0.0
                for index in range where clamped[index] > previousLevels[index] {
                    rise += clamped[index] - previousLevels[index]
                }
                registerFlux[register.rawValue] = rise / Double(range.count)
            }
        }
        previousLevels = clamped
        features.onsets[ImmersiveAudioRegister.mid.rawValue] = midOnsets.update(
            flux: registerFlux[ImmersiveAudioRegister.mid.rawValue], at: time, dt: dt, audible: audible
        )
        features.onsets[ImmersiveAudioRegister.high.rawValue] = highOnsets.update(
            flux: registerFlux[ImmersiveAudioRegister.high.rawValue], at: time, dt: dt, audible: audible
        )

        let deviation = fluxVariance.squareRoot()
        let threshold = fluxMean + 1.4 * deviation + 0.012
        if flux > threshold,
           energy > Self.silenceFloor,
           time - lastBeatTime >= Self.refractoryInterval {
            let strength = min(max((flux - fluxMean) / (3 * deviation + 0.03), 0.15), 1)
            features.beat = strength
            lastBeatTime = time
            onsets.append(time)
            if onsets.count > Self.onsetMemory { onsets.removeFirst(onsets.count - Self.onsetMemory) }
            pulse = max(pulse, strength)
            features.onsets[ImmersiveAudioRegister.low.rawValue] = strength
        }
        let follow = 1 - Self.decay(dt, halfLife: 1.0)
        fluxMean += (flux - fluxMean) * follow
        fluxVariance += ((flux - fluxMean) * (flux - fluxMean) - fluxVariance) * follow

        if features.beat == 0 { pulse *= Self.decay(dt, halfLife: 0.2) }
        features.pulse = pulse

        // 太久没拍子就不再报拍速。
        if let last = onsets.last, time - last > 4 { onsets.removeAll() }
        let tempo = Self.tempo(onsets: onsets)
        features.beatsPerSecond = tempo.map { 1 / $0.interval }
        features.steadiness = tempo?.steadiness ?? 0
        return features
    }

    /// 把相邻鼓点的间隔折进同一个八度后取中位数；整齐度看偏离中位数的平均幅度。
    static func tempo(onsets: [TimeInterval]) -> (interval: Double, steadiness: Double)? {
        guard onsets.count >= 4 else { return nil }
        var folded: [Double] = []
        for index in 1..<onsets.count {
            var interval = onsets[index] - onsets[index - 1]
            guard interval > 0.12, interval < 2.4 else { continue }
            while interval < foldedIntervalRange.lowerBound { interval *= 2 }
            while interval >= foldedIntervalRange.upperBound { interval /= 2 }
            folded.append(interval)
        }
        guard folded.count >= 3 else { return nil }
        let sorted = folded.sorted()
        let median = sorted[sorted.count / 2]
        let spread = folded.reduce(0) { $0 + abs($1 - median) } / Double(folded.count)
        let steadiness = min(max(1 - spread / median * 5, 0), 1)
        return (median, steadiness)
    }

    /// 经过 `dt` 秒后剩下的比例。
    static func decay(_ dt: TimeInterval, halfLife: TimeInterval) -> Double {
        guard dt > 0, halfLife > 0 else { return 1 }
        return pow(0.5, dt / halfLife)
    }
}

/// 全屏效果里的模拟共用的确定性随机数（xorshift64*）。同一个种子每次得到同一串数，
/// 设置页缩略图、取证页的静帧因此每次都一样。
public struct ImmersiveRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// [0, 1) 均匀分布。
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// 均值 0、方差约 1 的近似正态（三个均匀数相加，比 Box-Muller 便宜，尾巴有界）。
    public mutating func centered() -> Double {
        (unit() + unit() + unit() - 1.5) * 2
    }

    /// 把一段文字（例如歌名）变成稳定的种子；不用 `hashValue`，它每次启动都不同。
    public static func seed(for text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
