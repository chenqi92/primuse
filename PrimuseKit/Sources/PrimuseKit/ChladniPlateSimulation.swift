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

    /// 振幅和它对 x、y 的偏导。振幅范围是 -2…2。
    public func field(x: Double, y: Double) -> (value: Double, dx: Double, dy: Double) {
        let pn = Double(n) * .pi
        let pm = Double(m) * .pi
        let cnx = cos(pn * x), snx = sin(pn * x)
        let cmx = cos(pm * x), smx = sin(pm * x)
        let cny = cos(pn * y), sny = sin(pn * y)
        let cmy = cos(pm * y), smy = sin(pm * y)
        let s = Double(sign)
        let value = cnx * cmy + s * cmx * cny
        let dx = -pn * snx * cmy - s * pm * smx * cny
        let dy = -pm * cnx * smy - s * pn * cmx * sny
        return (value, dx, dy)
    }

    /// 波数的平方：节线越密越大。
    var wavenumberSquared: Double { .pi * .pi * Double(m * m + n * n) }
}

public enum ChladniPlate {
    /// 由简到繁排好的模式表。去掉了 (m, n) 相差 1 且取和的几种：它们的节线是一圈闭合曲线贴着板边，
    /// 看起来像空板。
    public static let modes: [ChladniMode] = {
        var result: [ChladniMode] = []
        for n in 2...8 {
            for m in 1..<n {
                for sign in [-1, 1] {
                    if sign == 1, n - m == 1, m <= 2 { continue }
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

    /// 歌越亮（频谱重心越高）、越响，花纹越繁。音乐的重心大多落在 0.36…0.5 之间，按这一段展开；
    /// 每首歌再按歌名带一点偏移，同样亮度的两首歌花纹也不一样。
    public static func modeIndex(centroid: Double, energy: Double, songOffset: Int) -> Int {
        let brightness = min(max((centroid - 0.30) / 0.24, 0), 1)
        let loudness = min(max((energy - 0.25) / 0.5, 0), 1)
        let complexity = brightness * 0.65 + loudness * 0.35
        let span = Double(modes.count - 1) * 0.7
        let index = Int((complexity * span).rounded()) + songOffset
        return min(max(index, 0), modes.count - 1)
    }

    public static func songOffset(seed: UInt64) -> Int {
        Int(seed % 9)
    }
}

/// 板上的沙子。振幅越大的地方沙粒跳得越厉害，同时被推向最近的节线；
/// 换模式时旧花纹在约一秒内过渡到新花纹，沙子顺着流过去。
public struct ChladniSandSimulation: Sendable {
    /// 两次换花纹之间至少停这么久，让沙子有时间排好。
    static let minimumHold: TimeInterval = 5
    /// 想换的花纹要持续这么久才真的换，免得重心在两档之间来回抖。
    static let dwell: TimeInterval = 1.6
    static let transitionDuration: TimeInterval = 1.2

    public private(set) var xs: [Double]
    public private(set) var ys: [Double]
    /// 每粒沙此刻所在位置的振幅大小（0…1），渲染时用来分出静止的亮沙与在跳的暗沙。
    public private(set) var agitation: [Double]
    public private(set) var mode: ChladniMode
    public private(set) var previousMode: ChladniMode?
    /// 0 是还停在上一个花纹，1 是完全换成 `mode`。
    public private(set) var transition: Double = 1

    private var random: ImmersiveRandom
    private var songOffset: Int
    /// 挑花纹看的是一两秒内的平均响度，不跟着每一拍跳。
    private var loudness: Double
    private var holdElapsed: TimeInterval = 0
    private var pendingIndex: Int?
    private var pendingElapsed: TimeInterval = 0

    public init(
        count: Int,
        seed: UInt64,
        songSeed: UInt64,
        centroid: Double = ImmersiveBeatTracker.restingCentroid,
        energy: Double = 0.4
    ) {
        random = ImmersiveRandom(seed: seed)
        songOffset = ChladniPlate.songOffset(seed: songSeed)
        loudness = energy
        mode = ChladniPlate.modes[
            ChladniPlate.modeIndex(centroid: centroid, energy: energy, songOffset: songOffset)
        ]
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
    public mutating func changeSong(seed: UInt64, centroid: Double) {
        songOffset = ChladniPlate.songOffset(seed: seed)
        let index = ChladniPlate.modeIndex(centroid: centroid, energy: loudness, songOffset: songOffset)
        if ChladniPlate.modes[index] != mode { begin(index) }
        pendingIndex = nil
        pendingElapsed = 0
    }

    /// 推进一帧。`drive` 是板子此刻振得多猛（0…1，通常取整体能量），`kick` 是这一帧的鼓点力度。
    public mutating func step(dt rawDT: TimeInterval, centroid: Double, drive: Double, kick: Double) {
        let dt = min(max(rawDT, 0), 1.0 / 15)
        guard dt > 0 else { return }
        loudness += (min(max(drive, 0), 1) - loudness) * (1 - ImmersiveBeatTracker.decay(dt, halfLife: 1.2))
        chooseMode(centroid: centroid, dt: dt)
        if transition < 1 {
            transition = min(1, transition + dt / Self.transitionDuration)
            if transition >= 1 { previousMode = nil }
        }

        let blend = smoothstep(transition)
        let current = mode
        let previous = transition < 1 ? previousMode : nil
        let k2 = previous.map { max($0.wavenumberSquared, current.wavenumberSquared) } ?? current.wavenumberSquared
        // 节线附近按 e^(-3t) 收拢；只要有声音，沙粒就会在振幅大的地方蹦。
        let attraction = 3.2 * (0.35 + 0.65 * min(max(drive, 0), 1))
        let vibration = 0.006 + 0.07 * min(max(drive, 0), 1)
        let hop = 0.022 * min(max(kick, 0), 1)
        let floorJitter = 0.0035
        let root = dt.squareRoot()

        for index in xs.indices {
            let x = xs[index]
            let y = ys[index]
            var (value, dx, dy) = current.field(x: x, y: y)
            if let previous {
                let old = previous.field(x: x, y: y)
                value = old.value + (value - old.value) * blend
                dx = old.dx + (dx - old.dx) * blend
                dy = old.dy + (dy - old.dy) * blend
            }
            let amplitude = min(abs(value) / 2, 1)
            // 朝 |f| 变小的方向（-f·∇f），按波数归一，花纹疏密不同收拢速度一样。
            var moveX = -attraction * value * dx / k2 * dt
            var moveY = -attraction * value * dy / k2 * dt
            let limit = 0.05
            moveX = min(max(moveX, -limit), limit)
            moveY = min(max(moveY, -limit), limit)
            let jitter = (floorJitter + vibration * amplitude) * root + hop * amplitude
            let nextX = reflect(x + moveX + jitter * random.centered())
            let nextY = reflect(y + moveY + jitter * random.centered())
            xs[index] = nextX
            ys[index] = nextY
            agitation[index] = amplitude
        }
    }

    // MARK: - 挑花纹

    private mutating func chooseMode(centroid: Double, dt: TimeInterval) {
        holdElapsed += dt
        let target = ChladniPlate.modeIndex(centroid: centroid, energy: loudness, songOffset: songOffset)
        let current = modeIndex
        guard target != current else {
            pendingIndex = nil
            pendingElapsed = 0
            return
        }
        if pendingIndex != target {
            // 只差一档时要更久才算数：重心在两档交界附近晃很常见。
            pendingIndex = target
            pendingElapsed = 0
        }
        pendingElapsed += dt
        let required = abs(target - current) >= 2 ? Self.dwell : Self.dwell * 2
        if pendingElapsed >= required, holdElapsed >= Self.minimumHold {
            begin(target)
        }
    }

    private mutating func begin(_ index: Int) {
        previousMode = transition < 1 ? (previousMode ?? mode) : mode
        mode = ChladniPlate.modes[index]
        transition = 0
        holdElapsed = 0
        pendingIndex = nil
        pendingElapsed = 0
    }

    /// 起始时直接落在节线附近的一点（拒绝采样），一小部分故意撒开，看起来像刚撒上去的。
    /// 按到节线的距离（|f| / |∇f|）取舍，不按 |f|：节线交叉处 |f| 一大片都很小，按它取会在交点堆成一团。
    private mutating func settledPoint(scattered: Bool) -> (x: Double, y: Double) {
        var x = random.unit()
        var y = random.unit()
        if scattered { return (x, y) }
        for _ in 0..<64 {
            let field = mode.field(x: x, y: y)
            let slope = (field.dx * field.dx + field.dy * field.dy).squareRoot()
            if abs(field.value) < 0.004 * max(slope, 1) { break }
            x = random.unit()
            y = random.unit()
        }
        return (x, y)
    }

    private func reflect(_ value: Double) -> Double {
        if value < 0 { return min(-value, 1) }
        if value > 1 { return max(2 - value, 0) }
        return value
    }

    private func smoothstep(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
