import Foundation

/// 一片草地上的萤火虫。每只按自己略有不同的节律闪，彼此看得见就会慢慢对上（Kuramoto 平均场耦合）；
/// 歌里的鼓点再把每只往「该闪了」那一侧推一把。节拍稳、声音足的段落里整片渐渐一齐闪，
/// 安静或节拍乱的段落里又各闪各的。
///
/// 坐标都在 0…1：x 从左到右，y 从上到下。
public struct FireflySwarmSimulation: Sendable {
    public struct Firefly: Sendable, Equatable {
        public let homeX: Double
        public let homeY: Double
        /// 0 是远处（小、暗、慢），1 是近处。
        public let depth: Double
        /// 0…1，走到 1 时闪一下并回到 0。
        public internal(set) var phase: Double
        /// 自己的节律相对整群基准的倍数，在 1 附近。
        let rateFactor: Double
        let wander: (Double, Double, Double, Double)
        /// 上一次闪的模拟时刻。
        public internal(set) var lastFlash: TimeInterval

        public static func == (lhs: Firefly, rhs: Firefly) -> Bool {
            lhs.homeX == rhs.homeX && lhs.homeY == rhs.homeY && lhs.phase == rhs.phase
                && lhs.lastFlash == rhs.lastFlash
        }
    }

    /// 没有拍子时整群的基准节律（每秒闪几次）。
    static let restingRate = 0.75
    /// 自然节律彼此相差的幅度。
    static let rateSpread = 0.14

    public private(set) var fireflies: [Firefly]
    /// 整群相位的一致程度（Kuramoto 序参量）：1 是完全一齐闪，0 是各闪各的。
    public private(set) var coherence: Double = 0
    /// 模拟内部的时钟，暂停时不走。
    public private(set) var time: TimeInterval = 0
    /// 当前整群的基准节律（每秒闪几次）。
    public private(set) var baseRate = restingRate
    /// 「这段音乐有多适合一起闪」：节拍整齐度乘上声音够不够大，按几秒的时间常数跟随。
    /// 歌与歌之间停顿一下不会让整群马上散开，新歌也要过上十来秒才慢慢对齐。
    public private(set) var groove = 0.0

    private var random: ImmersiveRandom

    public init(count: Int, seed: UInt64) {
        random = ImmersiveRandom(seed: seed)
        fireflies = []
        fireflies.reserveCapacity(max(count, 0))
        for _ in 0..<max(count, 0) {
            let depth = random.unit()
            // 越靠下越密，像贴着草尖飞；远处的偏上一点。
            let lower = random.unit().squareRoot()
            let homeY = 0.30 + 0.62 * lower - 0.10 * (1 - depth)
            fireflies.append(Firefly(
                homeX: random.unit(),
                homeY: min(max(homeY, 0.12), 0.95),
                depth: depth,
                phase: random.unit(),
                rateFactor: 1 + (random.unit() * 2 - 1) * Self.rateSpread,
                wander: (random.unit(), random.unit(), random.unit(), random.unit()),
                lastFlash: -10 - random.unit() * 10
            ))
        }
        coherence = Self.orderParameter(of: fireflies).magnitude
    }

    /// 推进一帧。
    public mutating func step(dt rawDT: TimeInterval, features: ImmersiveAudioFeatures) {
        let dt = min(max(rawDT, 0), 1.0 / 15)
        guard dt > 0, !fireflies.isEmpty else { return }
        time += dt

        let steadiness = features.beatsPerSecond == nil ? 0 : features.steadiness
        // 一拍闪一次太急：每秒两拍上下的歌按半速闪，正好落在每隔一拍上。
        let targetRate = features.beatsPerSecond.map { $0 / 2 } ?? Self.restingRate
        baseRate += (targetRate - baseRate) * (1 - ImmersiveBeatTracker.decay(dt, halfLife: 1.5))

        let presence = min(max(features.energy * 2.2, 0), 1)
        groove += (steadiness * presence - groove) * (1 - ImmersiveBeatTracker.decay(dt, halfLife: 3))
        let coupling = 0.3 + 2.2 * groove
        let noise = (0.02 + 0.07 * (1 - groove)) * dt.squareRoot()
        let field = Self.orderParameter(of: fireflies)
        let kick = features.beat * 0.35 * (0.4 + 0.6 * groove)

        for index in fireflies.indices {
            var firefly = fireflies[index]
            let twoPiPhase = 2 * Double.pi * firefly.phase
            var advance = baseRate * firefly.rateFactor * dt
            advance += coupling / (2 * .pi) * field.magnitude * sin(field.angle - twoPiPhase) * dt
            advance += noise * random.centered()
            if kick > 0 {
                // 相位响应：快到闪的往前推、刚闪完的往回拉，两边都朝鼓点那一刻收拢；正中间不受影响。
                advance -= kick * sin(twoPiPhase) / (2 * .pi)
            }
            var phase = firefly.phase + advance
            if phase >= 1 {
                phase -= floor(phase)
                firefly.lastFlash = time
            } else if phase < 0 {
                phase = 0
            }
            firefly.phase = phase
            fireflies[index] = firefly
        }
        coherence = Self.orderParameter(of: fireflies).magnitude
    }

    /// 0…1 的亮度：闪的那一刻 50 毫秒亮起，随后约 0.16 秒衰减，平时只剩一点点余光。
    public func brightness(of index: Int) -> Double {
        guard fireflies.indices.contains(index) else { return 0 }
        let since = time - fireflies[index].lastFlash
        guard since >= 0 else { return 0 }
        if since < 0.05 { return since / 0.05 }
        return exp(-(since - 0.05) / 0.16)
    }

    /// 此刻的位置：绕着自己的家缓缓打转，近处的飘得远一点。
    public func position(of index: Int) -> (x: Double, y: Double) {
        guard fireflies.indices.contains(index) else { return (0, 0) }
        let firefly = fireflies[index]
        let (a, b, c, d) = firefly.wander
        let reach = 0.012 + 0.022 * firefly.depth
        let t = time
        let x = firefly.homeX
            + reach * sin(t * (0.21 + 0.17 * a) + a * 6.283)
            + reach * 0.5 * sin(t * (0.53 + 0.31 * b) + b * 6.283)
        let y = firefly.homeY
            + reach * 0.8 * sin(t * (0.17 + 0.13 * c) + c * 6.283)
            + reach * 0.4 * cos(t * (0.47 + 0.29 * d) + d * 6.283)
        return (x, y)
    }

    static func orderParameter(of fireflies: [Firefly]) -> (magnitude: Double, angle: Double) {
        guard !fireflies.isEmpty else { return (0, 0) }
        var sumCos = 0.0
        var sumSin = 0.0
        for firefly in fireflies {
            let angle = 2 * Double.pi * firefly.phase
            sumCos += cos(angle)
            sumSin += sin(angle)
        }
        let count = Double(fireflies.count)
        let x = sumCos / count
        let y = sumSin / count
        return ((x * x + y * y).squareRoot(), atan2(y, x))
    }
}
