import Foundation

/// 方形金属板的一种振动模式。板面坐标 x、y 都在 0…1，板上一点的振幅是
/// cos(nπx)·cos(mπy) ± cos(mπx)·cos(nπy)（克拉尼图形的经典近似），振幅为 0 的地方就是节线，
/// 沙子最后都停在那里。
public struct ChladniMode: Hashable, Sendable {
    public let m: Int
    public let n: Int
    /// +1 取两项之和，-1 取两项之差；同一对 (m, n) 两种符号的花纹完全不同。
    public let sign: Int

    public init(m: Int, n: Int, sign: Int) {
        self.m = m
        self.n = n
        self.sign = sign >= 0 ? 1 : -1
    }

    /// 振幅和它对 x、y 的偏导。`mix` 是第二项的权重（0…1）：1 是经典花纹，越小越接近横平竖直的方格，
    /// 两者之间节线连续地弯过去（同一对 (m, n) 两个简并振型的叠加，真实的板子上也会这样变形）。
    /// 振幅范围是 -2…2。
    public func field(x: Double, y: Double, mix: Double = 1) -> (value: Double, dx: Double, dy: Double) {
        let pn = Double(n) * .pi
        let pm = Double(m) * .pi
        let cnx = cos(pn * x), snx = sin(pn * x)
        let cmx = cos(pm * x), smx = sin(pm * x)
        let cny = cos(pn * y), sny = sin(pn * y)
        let cmy = cos(pm * y), smy = sin(pm * y)
        let s = Double(sign) * mix
        let value = cnx * cmy + s * cmx * cny
        let dx = -pn * snx * cmy - s * pm * smx * cny
        let dy = -pm * cnx * smy - s * pn * cmx * sny
        return (value, dx, dy)
    }

    /// 只要振幅、不要偏导时用：省掉一半三角函数。
    public func value(x: Double, y: Double, mix: Double = 1) -> Double {
        let pn = Double(n) * .pi
        let pm = Double(m) * .pi
        return cos(pn * x) * cos(pm * y) + Double(sign) * mix * cos(pm * x) * cos(pn * y)
    }

    /// 波数的平方：节线越密越大。
    var wavenumberSquared: Double { .pi * .pi * Double(m * m + n * n) }
}

public enum ChladniPlate {
    /// 由简到繁排好的模式表。(m, n) 只差 1 的几种节线是一排斜条纹，只留最简单的 (1, 2) 给最安静的段落；
    /// 它取和的那一种节线是一圈贴着板边的闭合曲线，看起来像空板，也去掉。
    public static let modes: [ChladniMode] = {
        var result: [ChladniMode] = []
        for n in 2...8 {
            for m in 1..<n {
                for sign in [-1, 1] {
                    if n - m == 1, m >= 2 || sign == 1 { continue }
                    result.append(ChladniMode(m: m, n: n, sign: sign))
                }
            }
        }
        return result.sorted {
            let left = $0.m * $0.m + $0.n * $0.n
            let right = $1.m * $1.m + $1.n * $1.n
            if left != right { return left < right }
            if $0.m != $1.m { return $0.m < $1.m }
            return $0.sign < $1.sign
        }
    }()

    /// 花纹分几档：一首歌在自己的起伏里越激烈，挑得越繁。
    public static let levelCount = 4
    /// 相邻两档在模式表里隔多远；每首歌的偏移在这一段里，四档合起来用到表的前三分之二。
    static let levelStride = 7

    /// 第 `level` 档（0 最安静）的花纹；每首歌按歌名带一点偏移，同一档的两首歌花纹也不一样。
    /// 副歌回来时回到同一档，花纹也就回到同一个。
    public static func modeIndex(level: Int, songOffset: Int) -> Int {
        let clampedLevel = min(max(level, 0), levelCount - 1)
        let index = clampedLevel * levelStride + min(max(songOffset, 0), levelStride)
        return min(max(index, 0), modes.count - 1)
    }

    public static func songOffset(seed: UInt64) -> Int {
        Int(seed % UInt64(levelStride + 1))
    }

    /// 一次起音临时激起的另一个振型：低段（底鼓）激起更疏的大块，高段（镲片）激起很密的细纹。
    /// 正在显示的花纹的节线上它不是零，所以排好的沙会照着它的形状跳一下。
    static func transientIndex(for register: ImmersiveAudioRegister, around index: Int) -> Int {
        let offset: Int
        switch register {
        case .low: offset = -7
        case .mid: offset = 3
        case .high: offset = 10
        }
        let home = modes[min(max(index, 0), modes.count - 1)]
        var candidate = min(max(index + offset, 0), modes.count - 1)
        // 贴着表头表尾截断后可能又落回同一对 (m, n)：朝表中间挪到不同的那一对。
        let step = candidate > modes.count / 2 ? -1 : 1
        while modes[candidate].m == home.m, modes[candidate].n == home.n,
              modes.indices.contains(candidate + step) {
            candidate += step
        }
        return candidate
    }
}

/// 板上的沙子。振幅越大的地方沙粒跳得越厉害，同时被推向最近的节线；
/// 换模式时旧花纹在约一秒内过渡到新花纹，沙子顺着流过去。
///
/// 跟着歌走的有四样：这首歌此刻在自己的起伏里有多激烈挑花纹的繁简（`ChladniPlate.levelCount` 档）；
/// 音色比平常亮还是暗让同一个花纹在两种形态之间连续变形；每次起音按声部激起另一个振型，
/// 排好的沙照着它的形状跳起来再落回节线；越激烈沙线越粗、越活。
public struct ChladniSandSimulation: Sendable {
    /// 两次换花纹之间至少停这么久，让沙子有时间排好。
    static let minimumHold: TimeInterval = 3.5
    /// 想换的档位要持续这么久才真的换，免得在两档交界来回抖。
    static let dwell: TimeInterval = 0.8
    static let transitionDuration: TimeInterval = 1.2
    /// 档位之间的回差：激烈程度要越过分界这么多才算进了下一档。
    static let levelHysteresis = 0.1

    public private(set) var xs: [Double]
    public private(set) var ys: [Double]
    /// 每粒沙此刻所在位置的振幅大小（0…1），渲染时用来分出静止的亮沙与在跳的暗沙。
    public private(set) var agitation: [Double]
    public private(set) var mode: ChladniMode
    public private(set) var previousMode: ChladniMode?
    /// 0 是还停在上一个花纹，1 是完全换成 `mode`。
    public private(set) var transition: Double = 1
    /// 当前的档位（0 最安静）。
    public private(set) var level: Int
    /// 第二项的权重（见 `ChladniMode.field(x:y:mix:)`），随音色的明暗在 0.24…1 之间慢慢变。
    public private(set) var mix: Double = 0.7

    private var random: ImmersiveRandom
    private var songOffset: Int
    /// 挑档位看的是一两秒内的激烈程度，不跟着每一拍跳。
    private var intensity: Double
    private var holdElapsed: TimeInterval = 0
    private var pendingLevel: Int?
    private var pendingElapsed: TimeInterval = 0

    public init(count: Int, seed: UInt64, songSeed: UInt64, level: Int = 1) {
        random = ImmersiveRandom(seed: seed)
        songOffset = ChladniPlate.songOffset(seed: songSeed)
        let startLevel = min(max(level, 0), ChladniPlate.levelCount - 1)
        self.level = startLevel
        intensity = (Double(startLevel) + 0.5) / Double(ChladniPlate.levelCount)
        mode = ChladniPlate.modes[ChladniPlate.modeIndex(level: startLevel, songOffset: songOffset)]
        xs = []
        ys = []
        agitation = []
        let total = max(count, 0)
        xs.reserveCapacity(total)
        ys.reserveCapacity(total)
        for index in 0..<total {
            let point = settledPoint(scattered: index % 11 == 0)
            xs.append(point.x)
            ys.append(point.y)
        }
        agitation = Array(repeating: 0, count: total)
        holdElapsed = Self.minimumHold
    }

    public var modeIndex: Int {
        ChladniPlate.modes.firstIndex(of: mode) ?? 0
    }

    /// 换歌：花纹按新歌的偏移重新挑，沙子留在原处顺着流过去。
    public mutating func changeSong(seed: UInt64) {
        songOffset = ChladniPlate.songOffset(seed: seed)
        let index = ChladniPlate.modeIndex(level: level, songOffset: songOffset)
        if ChladniPlate.modes[index] != mode { begin(index) }
        pendingLevel = nil
        pendingElapsed = 0
    }

    /// 推进一帧。
    public mutating func step(dt rawDT: TimeInterval, features: ImmersiveAudioFeatures) {
        let dt = min(max(rawDT, 0), 1.0 / 15)
        guard dt > 0 else { return }
        let drive = min(max(features.energy, 0), 1)
        let liveliness = drive > ImmersiveBeatTracker.silenceFloor ? min(max(features.intensity, 0), 1) : 0
        intensity += (liveliness - intensity) * (1 - ImmersiveBeatTracker.decay(dt, halfLife: 1.0))
        chooseLevel(dt: dt)
        if transition < 1 {
            transition = min(1, transition + dt / Self.transitionDuration)
            if transition >= 1 { previousMode = nil }
        }
        // 音色亮一点、中段（人声）满一点，花纹就往经典的那一形态弯；暗下来、人声停了就往方格那边回。
        let midPresence = features.registerIntensity.indices.contains(1) ? features.registerIntensity[1] : 0.5
        let timbre = min(max(0.6 * features.brightnessShift + 0.4 * (midPresence * 2 - 1), -1), 1)
        let mixTarget = drive > ImmersiveBeatTracker.silenceFloor ? 0.62 + 0.38 * timbre : mix
        mix += (mixTarget - mix) * (1 - ImmersiveBeatTracker.decay(dt, halfLife: 0.7))

        let blend = smoothstep(transition)
        let current = mode
        let currentMix = mix
        let previous = transition < 1 ? previousMode : nil
        let k2 = previous.map { max($0.wavenumberSquared, current.wavenumberSquared) } ?? current.wavenumberSquared
        // 节线附近按 e^(-6t) 收拢：一拍里被鼓点震散的沙，下一拍之前大半已经落回线上。
        let attraction = 6.0 * (0.5 + 0.5 * drive)
        let vibration = 0.006 + 0.07 * drive
        // 越激烈，节线上的沙抖得越开，线也就越粗。
        let floorJitter = 0.0028 + 0.011 * intensity
        let root = dt.squareRoot()
        let hops = hopSources(features: features)

        // 坐标数组先挪到局部变量里再按指针改写（不复制）；随机数也拿到局部，循环里不碰 self。
        var random = self.random
        var xs = self.xs
        var ys = self.ys
        var agitation = self.agitation
        self.xs = []
        self.ys = []
        self.agitation = []
        let count = xs.count
        let basisSize = Self.basisSize
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 4 * basisSize) { basis in
            guard let table = basis.baseAddress else { return }
            let cosX = table
            let sinX = table + basisSize
            let cosY = table + 2 * basisSize
            let sinY = table + 3 * basisSize
            hops.withUnsafeBufferPointer { hopBuffer in
                xs.withUnsafeMutableBufferPointer { xBuffer in
                    ys.withUnsafeMutableBufferPointer { yBuffer in
                        agitation.withUnsafeMutableBufferPointer { agitationBuffer in
                            guard let px = xBuffer.baseAddress, let py = yBuffer.baseAddress,
                                  let pa = agitationBuffer.baseAddress else { return }
                            let hopCount = hopBuffer.count
                            var index = 0
                            while index < count {
                                let x = px[index]
                                let y = py[index]
                                Self.fillBasis(x, cosines: cosX, sines: sinX)
                                Self.fillBasis(y, cosines: cosY, sines: sinY)
                                var (value, dx, dy) = Self.field(current, mix: currentMix, cosX, sinX, cosY, sinY)
                                if let previous {
                                    let old = Self.field(previous, mix: currentMix, cosX, sinX, cosY, sinY)
                                    value = old.value + (value - old.value) * blend
                                    dx = old.dx + (dx - old.dx) * blend
                                    dy = old.dy + (dy - old.dy) * blend
                                }
                                // 循环里的取绝对值与夹取都直接比较：`min`、`max`、`abs` 是泛型函数，Debug 构建下很慢。
                                let amplitude = Self.clamp((value < 0 ? -value : value) / 2, 0, 1)
                                // 朝 |f| 变小的方向（-f·∇f），按波数归一，花纹疏密不同收拢速度一样。
                                let limit = 0.05
                                let moveX = Self.clamp(-attraction * value * dx / k2 * dt, -limit, limit)
                                let moveY = Self.clamp(-attraction * value * dy / k2 * dt, -limit, limit)
                                let jitter = (floorJitter + vibration * amplitude) * root
                                var hopX = 0.0
                                var hopY = 0.0
                                var hopIndex = 0
                                while hopIndex < hopCount {
                                    let hop = hopBuffer[hopIndex]
                                    let excitation = Self.field(hop.mode, mix: 1, cosX, sinX, cosY, sinY).value
                                    let push = hop.size * Self.clamp((excitation < 0 ? -excitation : excitation) / 2, 0, 1)
                                    hopX += push * random.centered()
                                    hopY += push * random.centered()
                                    hopIndex += 1
                                }
                                px[index] = Self.reflect(x + moveX + jitter * random.centered() + hopX)
                                py[index] = Self.reflect(y + moveY + jitter * random.centered() + hopY)
                                pa[index] = amplitude
                                index += 1
                            }
                        }
                    }
                }
            }
        }
        self.xs = xs
        self.ys = ys
        self.agitation = agitation
        self.random = random
    }

    // MARK: - 逐粒的振幅

    @inline(__always)
    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        value < lower ? lower : (value > upper ? upper : value)
    }

    /// cos(kπt)、sin(kπt) 预先算到 k = 8（模式表里最大的波数）。
    static let basisSize = 9

    /// 只算一次 cos(πt)、sin(πt)，其余倍角按和角公式递推：每粒沙每帧四次三角函数，
    /// 换花纹的过渡与起音激起的振型都不再另算。
    @inline(__always)
    static func fillBasis(_ t: Double, cosines: UnsafeMutablePointer<Double>, sines: UnsafeMutablePointer<Double>) {
        let c1 = cos(Double.pi * t)
        let s1 = sin(Double.pi * t)
        cosines[0] = 1
        sines[0] = 0
        cosines[1] = c1
        sines[1] = s1
        var k = 2
        while k < basisSize {
            cosines[k] = cosines[k - 1] * c1 - sines[k - 1] * s1
            sines[k] = sines[k - 1] * c1 + cosines[k - 1] * s1
            k += 1
        }
    }

    /// 和 `ChladniMode.field(x:y:mix:)` 相同，只是三角函数从预先算好的表里取。
    @inline(__always)
    static func field(
        _ mode: ChladniMode,
        mix: Double,
        _ cosX: UnsafeMutablePointer<Double>,
        _ sinX: UnsafeMutablePointer<Double>,
        _ cosY: UnsafeMutablePointer<Double>,
        _ sinY: UnsafeMutablePointer<Double>
    ) -> (value: Double, dx: Double, dy: Double) {
        let n = mode.n
        let m = mode.m
        let s = Double(mode.sign) * mix
        let pn = Double(n) * .pi
        let pm = Double(m) * .pi
        let value = cosX[n] * cosY[m] + s * cosX[m] * cosY[n]
        let dx = -pn * sinX[n] * cosY[m] - s * pm * sinX[m] * cosY[n]
        let dy = -pm * cosX[n] * sinY[m] - s * pn * cosX[m] * sinY[n]
        return (value, dx, dy)
    }

    // MARK: - 起音

    private struct Hop {
        let mode: ChladniMode
        let size: Double
    }

    /// 这一帧有起音的声部各激起一个振型；越激烈跳得越高。
    private func hopSources(features: ImmersiveAudioFeatures) -> [Hop] {
        var result: [Hop] = []
        let base = modeIndex
        for register in ImmersiveAudioRegister.allCases {
            let strength = features.onsets.indices.contains(register.rawValue)
                ? min(max(features.onsets[register.rawValue], 0), 1)
                : 0
            guard strength > 0 else { continue }
            let height: Double
            switch register {
            case .low: height = 0.06
            case .mid: height = 0.03
            case .high: height = 0.014
            }
            let size = height * strength.squareRoot() * (0.45 + 0.55 * intensity)
            let transient = ChladniPlate.modes[ChladniPlate.transientIndex(for: register, around: base)]
            result.append(Hop(mode: transient, size: size))
        }
        return result
    }

    // MARK: - 挑花纹

    private mutating func chooseLevel(dt: TimeInterval) {
        holdElapsed += dt
        let scaled = intensity * Double(ChladniPlate.levelCount)
        var target = level
        while target < ChladniPlate.levelCount - 1, scaled > Double(target + 1) + Self.levelHysteresis {
            target += 1
        }
        while target > 0, scaled < Double(target) - Self.levelHysteresis {
            target -= 1
        }
        guard target != level else {
            pendingLevel = nil
            pendingElapsed = 0
            return
        }
        if pendingLevel != target {
            pendingLevel = target
            pendingElapsed = 0
        }
        pendingElapsed += dt
        if pendingElapsed >= Self.dwell, holdElapsed >= Self.minimumHold {
            level = target
            let index = ChladniPlate.modeIndex(level: target, songOffset: songOffset)
            if ChladniPlate.modes[index] != mode { begin(index) }
            pendingLevel = nil
            pendingElapsed = 0
        }
    }

    private mutating func begin(_ index: Int) {
        previousMode = transition < 1 ? (previousMode ?? mode) : mode
        mode = ChladniPlate.modes[index]
        transition = 0
        holdElapsed = 0
        pendingLevel = nil
        pendingElapsed = 0
    }

    /// 起始时直接落在节线附近的一点（拒绝采样），一小部分故意撒开，看起来像刚撒上去的。
    /// 按到节线的距离（|f| / |∇f|）取舍，不按 |f|：节线交叉处 |f| 一大片都很小，按它取会在交点堆成一团。
    private mutating func settledPoint(scattered: Bool) -> (x: Double, y: Double) {
        var x = random.unit()
        var y = random.unit()
        if scattered { return (x, y) }
        for _ in 0..<64 {
            let field = mode.field(x: x, y: y, mix: mix)
            let slope = (field.dx * field.dx + field.dy * field.dy).squareRoot()
            if abs(field.value) < 0.004 * max(slope, 1) { break }
            x = random.unit()
            y = random.unit()
        }
        return (x, y)
    }

    private static func reflect(_ value: Double) -> Double {
        if value < 0 { return min(-value, 1) }
        if value > 1 { return max(2 - value, 0) }
        return value
    }

    private func smoothstep(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
