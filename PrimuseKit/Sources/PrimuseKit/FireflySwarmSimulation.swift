import Foundation

/// 一片草地上的萤火虫，分三层各跟一段声音：贴着草的跟低段（底鼓），半空的跟中段（军鼓、人声的字头），
/// 高处的跟高段（镲片）。每只按自己的节律慢慢充能，充过一半以后，所跟那一段的起音会让它当场闪一下，
/// 于是同一层的会在起音上对齐；那一段没有起音时就各闪各的。一段声音在这首歌里越热闹，那一层醒着的
/// 萤火越多：前奏只有钢琴时只有中间那层亮，鼓进来以后贴着草的才一片片醒过来。
///
/// 坐标都在 0…1：x 从左到右；y 是萤火能活动的那一段高度里的位置，0 是最高处、1 贴着草尖，
/// 渲染层再把它放进画面里的一段。
public struct FireflySwarmSimulation: Sendable {
    public struct Firefly: Sendable, Equatable {
        public let homeX: Double
        public let homeY: Double
        /// 0 是远处（小、暗），1 是近处。
        public let depth: Double
        /// 跟哪一段声音。
        public let register: ImmersiveAudioRegister
        /// 0…1 的充能：走到 1 时自己闪一下并回到 0；充过 `receptiveThreshold` 以后，起音会让它提前闪。
        public internal(set) var phase: Double
        /// 自己的节律相对整群基准的倍数，在 1 附近。
        let rateFactor: Double
        /// 醒来的先后（0…1）：所在那一层越热闹，排得越后的也醒过来。
        let rank: Double
        /// 醒着的程度（0…1），醒来和睡去都是慢慢淡入淡出。
        public internal(set) var awake: Double
        /// 上一次闪的模拟时刻。
        public internal(set) var lastFlash: TimeInterval
        /// 上一次闪有多亮（0…1）：起音越重越亮，没等到起音、自己闪的偏暗。
        public internal(set) var flashStrength: Double
        /// 上一次闪是不是被起音带出来的。
        public internal(set) var flashFollowedOnset: Bool
        public internal(set) var x: Double
        public internal(set) var y: Double
        var velocityX: Double
        var velocityY: Double

        public static func == (lhs: Firefly, rhs: Firefly) -> Bool {
            lhs.homeX == rhs.homeX && lhs.homeY == rhs.homeY && lhs.phase == rhs.phase
                && lhs.lastFlash == rhs.lastFlash && lhs.x == rhs.x && lhs.y == rhs.y
        }
    }

    /// 没有拍子时整群的基准节律（每秒闪几次）。
    static let restingRate = 0.55
    /// 自然节律彼此相差的幅度。
    static let rateSpread = 0.14
    /// 离家最远这么远（场地宽高的比例）。
    static let maximumDrift = 0.055
    /// 三层各占多少只。
    static let registerShares: [Double] = [0.42, 0.36, 0.22]
    /// 三层各自的高度范围（0 最高、1 贴草），彼此略有交叠。
    static let registerBands: [ClosedRange<Double>] = [0.64...1.0, 0.30...0.72, 0.0...0.38]
    /// 闪过以后亮度衰减一半要多久：贴着草的光晕大而慢，高处的是一闪即逝的细点。
    static let flashHalfLife: [Double] = [0.2, 0.14, 0.075]

    public private(set) var fireflies: [Firefly]
    /// 醒着的萤火里，相位有多一致（Kuramoto 序参量）：1 是完全一齐，0 是各闪各的。
    public private(set) var coherence: Double = 0
    /// 模拟内部的时钟，暂停时不走。
    public private(set) var time: TimeInterval = 0
    /// 当前整群的基准节律（每秒闪几次）。有拍速时是拍速的一半，没被起音带着的也大致合拍。
    public private(set) var baseRate = restingRate
    /// 三层各自醒着的比例（0…1）。
    public private(set) var population: [Double] = [0.2, 0.2, 0.2]
    /// 这首歌此刻有多激烈（平滑过的 `ImmersiveAudioFeatures.intensity`）。
    public private(set) var liveliness = 0.0
    /// 三层各自最近每秒几次起音。没有起音的那一层醒着的也少：前奏没有鼓时，贴着草的那层只有零星几只。
    public private(set) var onsetRate: [Double] = [0, 0, 0]

    private var random: ImmersiveRandom

    public init(count: Int, seed: UInt64) {
        random = ImmersiveRandom(seed: seed)
        fireflies = []
        let total = max(count, 0)
        fireflies.reserveCapacity(total)
        let lowCount = Int((Double(total) * Self.registerShares[0]).rounded())
        let midCount = Int((Double(total) * Self.registerShares[1]).rounded())
        for index in 0..<total {
            let register: ImmersiveAudioRegister = index < lowCount
                ? .low
                : (index < lowCount + midCount ? .mid : .high)
            let band = Self.registerBands[register.rawValue]
            let depth = random.unit()
            let homeX = random.unit()
            // 每层里也是越靠下越密，像贴着草尖飞；远处的偏上一点。
            let within = random.unit().squareRoot()
            let homeY = min(max(band.lowerBound + (band.upperBound - band.lowerBound) * within - 0.06 * (1 - depth), 0), 1)
            let rank = random.unit()
            fireflies.append(Firefly(
                homeX: homeX,
                homeY: homeY,
                depth: depth,
                register: register,
                phase: random.unit(),
                rateFactor: 1 + (random.unit() * 2 - 1) * Self.rateSpread,
                rank: rank,
                awake: rank < 0.2 ? 1 : 0,
                lastFlash: -10 - random.unit() * 10,
                flashStrength: 0,
                flashFollowedOnset: false,
                x: homeX,
                y: homeY,
                velocityX: 0,
                velocityY: 0
            ))
        }
        coherence = Self.orderParameter(of: fireflies).magnitude
    }

    /// 推进一帧。
    public mutating func step(dt rawDT: TimeInterval, features: ImmersiveAudioFeatures) {
        let dt = min(max(rawDT, 0), 1.0 / 15)
        guard dt > 0, !fireflies.isEmpty else { return }
        time += dt

        let audible = features.energy > ImmersiveBeatTracker.silenceFloor
        liveliness += ((audible ? features.intensity : 0) - liveliness)
            * (1 - ImmersiveBeatTracker.decay(dt, halfLife: 1.2))
        // 一拍闪一次太急：每秒两拍上下的歌按半速，正好落在每隔一拍上。
        let targetRate = features.beatsPerSecond.map { $0 / 2 } ?? Self.restingRate
        baseRate += (targetRate - baseRate) * (1 - ImmersiveBeatTracker.decay(dt, halfLife: 1.5))

        let follow = 1 - ImmersiveBeatTracker.decay(dt, halfLife: 1.6)
        let activityFollow = 1 - ImmersiveBeatTracker.decay(dt, halfLife: 2.5)
        for register in ImmersiveAudioRegister.allCases {
            let index = register.rawValue
            // 每次起音记一个冲量，按 2.5 秒的半衰期平均成「每秒几次」；每秒两次以上算满。
            let impulse = value(features.onsets, index) > 0 ? 1 / dt : 0
            onsetRate[index] += (impulse - onsetRate[index]) * activityFollow
            let activity = min(max(onsetRate[index] / 2, 0), 1)
            let target: Double
            if audible {
                let relative = value(features.registerIntensity, index) * 0.55 + features.intensity * 0.45
                // 这一段几乎没声音（例如没有镲片）时，那一层不管相对起伏怎样都只留零星几只。
                let presence = min(max((value(features.registerLevels, index) - 0.08) / 0.22, 0), 1)
                target = 0.12 + 0.88 * Self.smoothstep(relative) * presence * (0.5 + 0.5 * activity)
            } else {
                target = 0.1
            }
            population[index] += (target - population[index]) * follow
        }

        // 充过这么多才会被起音带着闪：比一拍略长，同一只不会每一拍都闪。
        let receptiveThreshold = 0.55
        // 充好能的里面，一次起音带出多少：越激烈、起音越重，亮的一片越大；每次是另一批，不会两拨轮流。
        let responseBase = 0.3 + 0.5 * liveliness
        let noise = 0.05 * dt.squareRoot()
        let wake = 1 - ImmersiveBeatTracker.decay(dt, halfLife: 0.7)
        let pull = 1.4
        let damping = 1.6
        let flutter = (0.022 + 0.03 * liveliness) * dt.squareRoot()

        for index in fireflies.indices {
            var firefly = fireflies[index]
            let register = firefly.register.rawValue
            let awakeTarget: Double = firefly.rank < population[register] ? 1 : 0
            firefly.awake += (awakeTarget - firefly.awake) * wake

            var phase = firefly.phase + baseRate * firefly.rateFactor * dt + noise * random.centered()
            let onset = min(max(value(features.onsets, register), 0), 1)
            var flashed = false
            var strength = 0.0
            var followedOnset = false
            if onset > 0, firefly.awake > 0.3, phase >= receptiveThreshold,
               random.unit() < responseBase * (0.6 + 0.4 * onset) {
                flashed = true
                followedOnset = true
                strength = 0.5 + 0.5 * onset
            }
            if !flashed, phase >= 1 {
                flashed = true
                strength = 0.3 + 0.2 * liveliness
            }
            if flashed {
                phase = phase >= 1 ? phase - floor(phase) : 0
                if firefly.awake > 0.05 {
                    firefly.lastFlash = time
                    firefly.flashStrength = strength
                    firefly.flashFollowedOnset = followedOnset
                }
            }
            firefly.phase = min(max(phase, 0), 0.999_999)

            // 绕着自己的家随机漂：被拉回家、被空气阻着、再被一点点乱流推着走，不会重复同一条路线。
            let reach = 0.6 + 0.4 * firefly.depth
            firefly.velocityX += (-pull * (firefly.x - firefly.homeX) - damping * firefly.velocityX) * dt
                + flutter * reach * random.centered()
            firefly.velocityY += (-pull * (firefly.y - firefly.homeY) - damping * firefly.velocityY) * dt
                + flutter * reach * 0.7 * random.centered()
            firefly.x += firefly.velocityX * dt
            firefly.y += firefly.velocityY * dt
            if abs(firefly.x - firefly.homeX) > Self.maximumDrift {
                firefly.x = firefly.homeX + (firefly.x > firefly.homeX ? 1 : -1) * Self.maximumDrift
                firefly.velocityX *= -0.3
            }
            if abs(firefly.y - firefly.homeY) > Self.maximumDrift {
                firefly.y = firefly.homeY + (firefly.y > firefly.homeY ? 1 : -1) * Self.maximumDrift
                firefly.velocityY *= -0.3
            }
            fireflies[index] = firefly
        }
        coherence = Self.orderParameter(of: fireflies.filter { $0.awake > 0.5 }).magnitude
    }

    /// 0…1 的亮度：闪的那一刻 50 毫秒亮起，随后按所在那一层的半衰期暗下去；乘上醒着的程度。
    public func brightness(of index: Int) -> Double {
        guard fireflies.indices.contains(index) else { return 0 }
        let firefly = fireflies[index]
        let since = time - firefly.lastFlash
        guard since >= 0 else { return 0 }
        let envelope: Double
        if since < 0.05 {
            envelope = since / 0.05
        } else {
            envelope = pow(0.5, (since - 0.05) / Self.flashHalfLife[firefly.register.rawValue])
        }
        return envelope * firefly.flashStrength * firefly.awake
    }

    /// 此刻的位置。
    public func position(of index: Int) -> (x: Double, y: Double) {
        guard fireflies.indices.contains(index) else { return (0, 0) }
        return (fireflies[index].x, fireflies[index].y)
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

    private func value(_ values: [Double], _ index: Int) -> Double {
        values.indices.contains(index) ? values[index] : 0
    }

    private static func smoothstep(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
