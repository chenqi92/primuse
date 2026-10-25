import Foundation

/// 「动态歌词」的弹珠落音场景（`ImmersiveKineticScene.marbleDrop`）：几颗发光的小球一直往下掉，每听到一个音，
/// 对应声部的那颗球正好在那一刻撞上一根冒出来的音条弹开——音条就长在球此刻的位置上，所以每一下都踩在音上，不用
/// 预报。弹开的方向朝这个声部的地盘拐一点，球不会跑出画面。音条撞完留着慢慢暗下去，画面跟着球往下走，一路留下的
/// 音条就是这首歌的样子。
///
/// 坐标按画面高度算：x 从 0 到宽高比，y 向下；`cameraY` 是画面上沿在这条路上的位置。时间是播放时间：暂停时球停住。
public struct ImmersiveKineticMarbleRun: Sendable {
    public struct Ball: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var vx: Double
        public var vy: Double
        /// 0 低音（底鼓、贝斯），1 中段（军鼓、人声），2 高音（镲片）。
        public var voice: Int
        public var radius: Double
        public var lastBounce: TimeInterval
        /// 最近几个位置，最新的在前：画拖尾用。
        public var trail: [SIMD2<Double>]
    }

    public struct Bar: Equatable, Sendable {
        /// 撞的那一点。
        public var x: Double
        public var y: Double
        /// 朝着球那一面的法线方向（弧度，y 向下）：音条横在跟它垂直的方向上。
        public var angle: Double
        public var length: Double
        public var time: TimeInterval
        public var voice: Int
        public var strength: Double
    }

    public static let gravity = 2.4
    /// 掉得再久也不超过这个速度（每秒几个画面高）。
    public static let terminalSpeed = 1.05
    public static let barLifetime: TimeInterval = 7
    static let barCapacity = 52
    static let trailInterval: TimeInterval = 0.025
    static let trailLength = 10
    /// 每个声部两次弹开至少隔多久：镲片一秒十来下，球会被弹得悬在半空。
    static let minimumBounceInterval: [TimeInterval] = [0.16, 0.16, 0.34]
    /// 每个声部多重的起音才算一个音。
    static let hitThreshold = [0.3, 0.35, 0.55]
    static let radii = [0.027, 0.021, 0.015]
    /// 三个声部各自的地盘（占画面宽度的几成）。
    static let homes = [0.3, 0.52, 0.72]
    /// 球保持在画面里哪个高度附近。
    static let cameraTarget = 0.42
    /// 照着节奏一个音往下走多少（画面高度）。
    static let stepDown = 0.055

    public private(set) var balls: [Ball] = []
    public private(set) var bars: [Bar] = []
    public private(set) var cameraY = 0.0
    private var random: ImmersiveRandom
    private var lastTime: TimeInterval?
    private var aspect = 0.5
    private var trailClock = 0.0
    private var wander = [0.0, 0.0, 0.0]
    /// 每颗球最近两个音之间大约隔多久（平滑过）。
    private var intervals = [0.45, 0.45, 0.45]
    /// 每颗球上一次往哪边弹：1 往右，-1 往左。
    private var sides = [1.0, -1.0, 1.0]

    public init(seed: UInt64) {
        random = ImmersiveRandom(seed: seed ^ 0xBA11_0F_5EED)
    }

    /// 走一帧。`hits` 是低、中、高三段这一帧的起音力度；读不到频谱时（`followsSpectrum` 为 false）只有中段，是
    /// 歌词的字头，交给画面里最靠下的那颗球。`aspect` 是画面的宽高比，`time` 是播放时间。
    public mutating func update(hits: [Double], followsSpectrum: Bool, aspect: Double, at time: TimeInterval) {
        guard time.isFinite, aspect.isFinite, aspect > 0 else { return }
        self.aspect = aspect
        if balls.isEmpty || lastTime.map({ time < $0 - 0.05 || time - $0 > 1.5 }) == true {
            reset(at: time)
        }
        let dt = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time
        var remaining = dt
        while remaining > 1e-6 {
            let step = min(remaining, 1.0 / 120)
            integrate(step)
            remaining -= step
        }

        if followsSpectrum {
            for voice in 0..<min(hits.count, balls.count)
            where hits[voice] >= Self.hitThreshold[voice]
                && time - balls[voice].lastBounce >= Self.minimumBounceInterval[voice] {
                bounce(voice, strength: hits[voice], at: time)
            }
        } else if let hit = hits.max(), hit > 0 {
            // 歌词的字头：给最靠下、刚才没弹过的那颗。
            let candidates = balls.indices.filter { time - balls[$0].lastBounce >= 0.12 }
            if let lowest = candidates.max(by: { balls[$0].y < balls[$1].y }) {
                bounce(lowest, strength: hit, at: time)
            }
        }

        trailClock += dt
        if trailClock >= Self.trailInterval {
            trailClock = trailClock.truncatingRemainder(dividingBy: Self.trailInterval)
            for index in balls.indices {
                balls[index].trail.insert(SIMD2(balls[index].x, balls[index].y), at: 0)
                if balls[index].trail.count > Self.trailLength { balls[index].trail.removeLast() }
            }
        }

        // 画面跟着球往下走，只往下不往上：追着最近弹过的那几颗球的平均高度（都没弹过时看全部）。
        let active = balls.filter { time - $0.lastBounce < 1.5 }
        let followed = active.isEmpty ? balls : active
        let target = followed.map(\.y).reduce(0, +) / Double(followed.count) - Self.cameraTarget
        if target > cameraY {
            cameraY = target + (cameraY - target) * pow(0.5, dt / 0.8)
        }

        // 掉出画面下沿、被甩在上沿外面的球，从上沿外面重新落进来。
        for index in balls.indices where balls[index].y - cameraY > 1.12 || balls[index].y - cameraY < -0.35 {
            respawn(index, above: 0.08)
        }
        bars.removeAll { time - $0.time > Self.barLifetime || $0.y - cameraY < -0.3 }
        if bars.count > Self.barCapacity { bars.removeFirst(bars.count - Self.barCapacity) }
    }

    private mutating func reset(at time: TimeInterval) {
        bars.removeAll()
        cameraY = 0
        trailClock = 0
        wander = [0, 0, 0]
        intervals = [0.45, 0.45, 0.45]
        balls = (0..<3).map { voice in
            Ball(
                x: Self.homes[voice] * aspect,
                y: -0.03 - 0.09 * Double(voice),
                vx: 0,
                vy: 0.2,
                voice: voice,
                radius: Self.radii[voice],
                lastBounce: time - 10,
                trail: []
            )
        }
        lastTime = time
    }

    private mutating func respawn(_ index: Int, above offset: Double) {
        let voice = balls[index].voice
        balls[index].x = (Self.homes[voice] + wander[voice]) * aspect
        balls[index].y = cameraY - offset - 0.1 * random.unit()
        balls[index].vx = random.centered() * 0.05
        balls[index].vy = 0.15
        balls[index].trail.removeAll()
    }

    private mutating func integrate(_ dt: TimeInterval) {
        let drag = pow(0.7, dt)
        for index in balls.indices {
            var ball = balls[index]
            ball.vy = min(ball.vy + Self.gravity * dt, Self.terminalSpeed)
            ball.vx *= drag
            ball.x += ball.vx * dt
            ball.y += ball.vy * dt
            // 画面两侧是墙，碰到就弹回来。
            if ball.x < ball.radius {
                ball.x = ball.radius
                ball.vx = abs(ball.vx) * 0.8
            } else if ball.x > aspect - ball.radius {
                ball.x = aspect - ball.radius
                ball.vx = -abs(ball.vx) * 0.8
            }
            balls[index] = ball
        }
    }

    /// 让第 `index` 颗球此刻撞上一根音条。往下掉时音条在它下面：弹起的力道按这颗球最近两个音隔多久来定，照这个
    /// 节奏下一个音来时它正好比这次低一点，一个音一级台阶地往下走；重的音弹得高一点。还在往上飞时（音来得比预想的早）
    /// 音条在它上面、把它往下压。横向一下往左一下往右，偏离自己的地盘时往回拐。音条的朝向按速度的变化定，看着就是
    /// 照着它反弹的。
    private mutating func bounce(_ index: Int, strength: Double, at time: TimeInterval) {
        var ball = balls[index]
        let voice = ball.voice
        let since = time - ball.lastBounce
        if since < 2 {
            intervals[index] += (min(max(since, Self.minimumBounceInterval[voice]), 0.9) - intervals[index]) * 0.3
        }
        let rising = ball.vy < -0.25
        let newVy: Double
        if rising {
            newVy = 0.2 + 0.2 * strength
        } else {
            let gap = intervals[index]
            let step = Self.stepDown * (1.3 - 0.6 * strength)
            newVy = min(max((step - 0.5 * Self.gravity * gap * gap) / gap, -1.2), -0.1)
        }
        wander[voice] = min(max(wander[voice] + random.centered() * 0.06, -0.14), 0.14)
        let home = (Self.homes[voice] + wander[voice]) * aspect
        sides[index] = random.unit() < 0.75 ? -sides[index] : sides[index]
        // 横向只拐一点：音条大多是平的，一路排下来像一级级台阶，不是满屏乱撒的小棍。
        let swing = sides[index] * (0.06 + 0.1 * random.unit())
        let newVx = min(max(swing + (home - ball.x) * 1.0, -0.3), 0.3)
        var nx = newVx - ball.vx
        var ny = newVy - ball.vy
        let length = (nx * nx + ny * ny).squareRoot()
        if length < 1e-3 {
            nx = 0
            ny = rising ? 1 : -1
        } else {
            nx /= length
            ny /= length
        }
        bars.append(Bar(
            x: ball.x - nx * ball.radius * 1.15,
            y: ball.y - ny * ball.radius * 1.15,
            angle: atan2(ny, nx),
            length: 0.05 + 0.05 * strength,
            time: time,
            voice: voice,
            strength: min(max(strength, 0), 1)
        ))
        ball.vx = newVx
        ball.vy = newVy
        ball.lastBounce = time
        balls[index] = ball
    }

    // MARK: - 交给着色器

    public static let propsCapacity = 128
    static let trailsOffset = 8
    static let barsOffset = 24

    /// 交给着色器的数据，float4 一组，y 已经换成画面里的位置（0 是上沿），格式见 `ImmersiveKineticShaderSource`
    /// 里弹珠落音的说明。
    public func packed(at time: TimeInterval) -> [SIMD4<Float>] {
        var props = [SIMD4<Float>](repeating: .zero, count: Self.propsCapacity)
        let shownBars = bars.suffix((Self.propsCapacity - Self.barsOffset) / 2)
        props[0] = SIMD4(Float(balls.count), Float(shownBars.count), Float(Self.trailLength), 0)
        for (index, ball) in balls.prefix(3).enumerated() {
            props[1 + index] = SIMD4(Float(ball.x), Float(ball.y - cameraY), Float(ball.radius), Float(ball.voice))
            props[4 + index] = SIMD4(
                Float(time - ball.lastBounce),
                Float((ball.vx * ball.vx + ball.vy * ball.vy).squareRoot()),
                Float(ball.trail.count),
                0
            )
            // 拖尾：每颗球 `trailLength` 个点，两个点一组。
            for pair in 0..<(Self.trailLength / 2) {
                let a = ball.trail.indices.contains(pair * 2) ? ball.trail[pair * 2] : SIMD2(ball.x, ball.y)
                let b = ball.trail.indices.contains(pair * 2 + 1) ? ball.trail[pair * 2 + 1] : a
                props[Self.trailsOffset + index * (Self.trailLength / 2) + pair] = SIMD4(
                    Float(a.x), Float(a.y - cameraY), Float(b.x), Float(b.y - cameraY)
                )
            }
        }
        for (offset, bar) in shownBars.enumerated() {
            props[Self.barsOffset + offset * 2] = SIMD4(Float(bar.x), Float(bar.y - cameraY), Float(bar.angle), Float(bar.length))
            props[Self.barsOffset + offset * 2 + 1] = SIMD4(Float(time - bar.time), Float(bar.voice), Float(bar.strength), 0)
        }
        return props
    }
}
