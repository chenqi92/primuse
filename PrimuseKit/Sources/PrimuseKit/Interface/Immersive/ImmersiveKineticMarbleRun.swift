import Foundation

/// 「动态歌词」的弹珠落音场景（`ImmersiveKineticScene.marbleDrop`）：一颗发光的小球一直往下掉，从头到尾都是它，
/// 画面跟着它走。谱面上的每一个音（`ImmersiveKineticRhythmChart`，提前一两秒就知道）都是一根接住它的音条：音条
/// 提前出现在球那一刻会到的地方，球正好在音响的那一下落上去弹开；颜色按轨道分。长音是一段斜坡，球落上去顺着坡
/// 滚到长音结束才飞出去；一阵子没有音时铺一段缓坡让它滑着，不会一直往下坠。读不到拍子、谱面上没有音时，听到的
/// 起音当场在球底下垫一根音条。
///
/// 坐标按画面高度算，y 向下；球和音条都在一张无限大的纸上，`cameraX`、`cameraY` 是画面左上角在纸上的位置。
/// 时间是播放时间：暂停时球停住，拖进度从头来。弹跳、滚坡都按解析式算到该碰的那一刻，不受帧率影响。
public struct ImmersiveKineticMarbleRun: Sendable {
    public struct Ball: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var vx: Double
        public var vy: Double
        public var radius: Double
        /// 球自己转了多少（弧度）：滚坡时按走过的路算，球面上的高光跟着转。
        public var spin: Double
        /// 最近碰到音条的时刻。
        public var lastContact: TimeInterval
        /// 最近几个位置，最新的在前：画拖尾用。
        public var trail: [SIMD2<Double>]
    }

    public enum PadKind: Int, Sendable {
        /// 一下弹开的音条。
        case bounce
        /// 长音的斜坡：球顺着滚到长音结束。
        case ramp
        /// 没有音时垫的缓坡（暗一些，不算音）。
        case glide
    }

    public struct Pad: Equatable, Sendable {
        /// 弹开的音条：撞点；坡：坡的起点（球心在它上方一个半径）。
        public var x: Double
        public var y: Double
        /// 弹开的音条：朝着球那一面的法线方向；坡：顺着坡往下滚的方向（弧度，y 向下）。
        public var angle: Double
        public var length: Double
        /// 球碰到它的时刻。
        public var contact: TimeInterval
        /// 坡上滚多久；弹开的音条为 0。
        public var duration: TimeInterval
        /// 颜色按轨道分（谱面音符的轨道号，0…3）。
        public var lane: Int
        public var strength: Double
        public var kind: PadKind
        /// 弹开以后球的速度（只有弹开的音条有）。
        var outgoing: SIMD2<Double>
    }

    /// 球此刻怎么走：飞（抛物线）或滚（沿坡匀速）。都从 `since` 起算。
    enum Motion: Equatable, Sendable {
        case flying(from: SIMD2<Double>, velocity: SIMD2<Double>, since: TimeInterval)
        case rolling(from: SIMD2<Double>, direction: SIMD2<Double>, speed: Double, since: TimeInterval, until: TimeInterval)

        func position(at time: TimeInterval) -> SIMD2<Double> {
            switch self {
            case let .flying(from, velocity, since):
                let t = max(time - since, 0)
                return from + velocity * t + SIMD2(0, 0.5 * ImmersiveKineticMarbleRun.gravity * t * t)
            case let .rolling(from, direction, speed, since, until):
                let t = min(max(time - since, 0), until - since)
                return from + direction * (speed * t)
            }
        }

        func velocity(at time: TimeInterval) -> SIMD2<Double> {
            switch self {
            case let .flying(_, velocity, since):
                return velocity + SIMD2(0, ImmersiveKineticMarbleRun.gravity * max(time - since, 0))
            case let .rolling(_, direction, speed, _, _):
                return direction * speed
            }
        }

        var startTime: TimeInterval {
            switch self {
            case let .flying(_, _, since): since
            case let .rolling(_, _, _, since, _): since
            }
        }

        /// 滚坡在什么时候滚完；飞着时为 nil。
        var rollEnd: TimeInterval? {
            if case let .rolling(_, _, _, _, until) = self { return until }
            return nil
        }
    }

    public static let gravity = 2.4
    public static let ballRadius = 0.03
    /// 音条提前多久出现在球要到的地方。
    public static let preview: TimeInterval = 0.9
    /// 一个音往下走多少（画面高度）：一拍一拍地往下，像下台阶。
    static let stepDown = 0.06
    /// 坡有多斜（弧度），长音坡和缓坡。
    static let rampSlope = 0.34
    static let glideSlope = 0.24
    /// 飞了这么久还没有下一个音，就在它底下垫一段缓坡。
    static let longestFall: TimeInterval = 0.75
    static let padLifetime: TimeInterval = 8
    static let padCapacity = 60
    static let trailInterval: TimeInterval = 0.025
    static let trailLength = 10
    /// 球保持在画面里哪个位置附近（占画面宽、高的几成）。
    static let cameraAnchor = SIMD2(0.5, 0.42)

    public private(set) var ball = Ball(x: 0, y: 0, vx: 0, vy: 0, radius: ballRadius, spin: 0, lastContact: -10, trail: [])
    public private(set) var pads: [Pad] = []
    public private(set) var cameraX = 0.0
    public private(set) var cameraY = 0.0
    private var motion = Motion.flying(from: .zero, velocity: .zero, since: 0)
    /// 最后一根已经排好的音条之后球怎么走（排下一根时从它推）。
    private var plannedMotion = Motion.flying(from: .zero, velocity: .zero, since: 0)
    /// 已经排了音条的谱面音符（按该打的时刻），免得一个音排两次。
    private var scheduledNotes: Set<Int> = []
    private var random: ImmersiveRandom
    private var lastTime: TimeInterval?
    private var aspect = 0.5
    private var trailClock = 0.0
    private var side = 1.0
    private var hasStarted = false

    public init(seed: UInt64) {
        random = ImmersiveRandom(seed: seed ^ 0xBA11_0F_5EED)
    }

    /// 走一帧。`notes` 是谱面上的音符（`ImmersiveKineticRhythmChart.notes`）；`hits` 是这一帧听到的起音力度
    /// （谱面上附近没有音时当场垫一根音条用）；`aspect` 是画面的宽高比；`time` 是播放时间。
    public mutating func update(
        notes: [ImmersiveKineticRhythmChart.Note],
        hits: [Double],
        aspect: Double,
        at time: TimeInterval
    ) {
        guard time.isFinite, aspect.isFinite, aspect > 0 else { return }
        self.aspect = aspect
        if !hasStarted || lastTime.map({ time < $0 - 0.05 || time - $0 > 1.5 }) == true {
            reset(at: time)
        }
        let dt = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time

        schedule(notes: notes, at: time)
        contactPads(through: time)
        if let hit = hits.max(), hit >= 0.35 {
            bounceNow(strength: hit, notes: notes, at: time)
        }

        let position = motion.position(at: time)
        let velocity = motion.velocity(at: time)
        if motion.rollEnd != nil {
            ball.spin += hypot(velocity.x, velocity.y) * dt / ball.radius * (velocity.x >= 0 ? 1 : -1)
        } else {
            ball.spin += velocity.x * dt / ball.radius * 0.5
        }
        ball.x = position.x
        ball.y = position.y
        ball.vx = velocity.x
        ball.vy = velocity.y

        trailClock += dt
        if trailClock >= Self.trailInterval {
            trailClock = trailClock.truncatingRemainder(dividingBy: Self.trailInterval)
            ball.trail.insert(SIMD2(ball.x, ball.y), at: 0)
            if ball.trail.count > Self.trailLength { ball.trail.removeLast() }
        }

        // 画面跟着球走，横竖都跟；落得快时追得也快一点，球不会冲出画面。
        let targetX = ball.x - Self.cameraAnchor.x * aspect
        let targetY = ball.y - Self.cameraAnchor.y
        let follow = 1 - pow(0.5, dt / 0.35)
        cameraX += (targetX - cameraX) * follow
        cameraY += (targetY - cameraY) * follow
        cameraY = min(max(cameraY, ball.y - 0.85), ball.y - 0.1)

        pads.removeAll { pad in
            time - pad.contact - pad.duration > Self.padLifetime
                || pad.y - cameraY < -0.6
                || abs(pad.x - (cameraX + aspect / 2)) > aspect * 2 + 1
        }
        if pads.count > Self.padCapacity { pads.removeFirst(pads.count - Self.padCapacity) }
        scheduledNotes = scheduledNotes.filter { Double($0) / 1000 > time - 5 }
    }

    private mutating func reset(at time: TimeInterval) {
        hasStarted = true
        pads.removeAll()
        scheduledNotes.removeAll()
        trailClock = 0
        let start = SIMD2(0.5 * aspect, -0.05)
        motion = .flying(from: start, velocity: SIMD2(0, 0.2), since: time)
        plannedMotion = motion
        ball = Ball(x: start.x, y: start.y, vx: 0, vy: 0.2, radius: Self.ballRadius, spin: 0, lastContact: time - 10, trail: [])
        cameraX = 0
        cameraY = start.y - Self.cameraAnchor.y
        lastTime = time
    }

    /// 谱面上 `preview` 以内的音符，按时间一个个排上音条：音条放在球那一刻会到的地方。长音排一段坡；离上一根
    /// 太久时先垫一段缓坡。坡上滚着的时候来的音不排（球正滚着）。
    private mutating func schedule(notes: [ImmersiveKineticRhythmChart.Note], at time: TimeInterval) {
        let horizon = time + Self.preview
        let known = notes.map(\.time).sorted()
        // 同一时刻的双押只算一下。
        var upcoming: [ImmersiveKineticRhythmChart.Note] = []
        for note in notes.sorted(by: { $0.time < $1.time })
        where note.time > plannedMotion.startTime + 0.08 && note.time <= horizon && !scheduledNotes.contains(Self.key(note.time)) {
            if let last = upcoming.last, abs(last.time - note.time) < 0.05 { continue }
            upcoming.append(note)
        }
        for (index, note) in upcoming.enumerated() {
            insertGlideIfNeeded(before: note.time, known: known)
            let following = index + 1 < upcoming.count ? upcoming[index + 1].time : nil
            if note.isHold {
                placeRamp(at: note.time, duration: note.duration, lane: note.lane, strength: note.strength, kind: .ramp)
            } else {
                placeBounce(at: note.time, nextNote: following, lane: note.lane, strength: note.strength)
            }
            scheduledNotes.insert(Self.key(note.time))
        }
        // 前面没有音了：飞得太久就垫缓坡。
        insertGlideIfNeeded(before: nil, known: known)
    }

    private static func key(_ time: TimeInterval) -> Int { Int((time * 1000).rounded()) }

    /// 球从最后一根排好的音条飞出去以后，到下一个音（`next`，不知道时按谱面上已知的下一个，再没有就按大半秒）
    /// 还要飞超过 `longestFall`：在飞到第 `longestFall`·0.8 秒那里垫一段缓坡，滑到下一个音前一点（最长一秒半）
    /// 再接着飞。谱面上已经知道的音不会被缓坡占掉。
    private mutating func insertGlideIfNeeded(before next: TimeInterval?, known: [TimeInterval]) {
        let start = plannedMotion.startTime
        let contact = start + Self.longestFall * 0.8
        let target = next ?? known.first { $0 > contact + 0.05 }
        if let target, target - start <= Self.longestFall { return }
        guard next != nil || lastTime.map({ $0 + Self.preview - start > Self.longestFall }) == true else { return }
        // 不知道下一个音时只铺到谱面看得到的范围以内（提前 `leadTime`），之后冒出来的音不会落在坡上。
        let end = (target ?? contact + 0.9) - 0.2
        let duration = min(max(end - contact, 0.3), 1.5)
        if let target, contact + duration > target - 0.1 { return }
        placeRamp(at: contact, duration: duration, lane: -1, strength: 0.3, kind: .glide)
    }

    /// 在球 `time` 那一刻的位置垫一根弹开的音条：弹开的力道按到下一个音还有多久定，下一个音来时球正好比这次低
    /// 一级；横向一下往左一下往右。音条的朝向按速度的变化定，看着就是照着它反弹的。
    private mutating func placeBounce(at time: TimeInterval, nextNote: TimeInterval?, lane: Int, strength: Double) {
        let position = plannedMotion.position(at: time)
        let incoming = plannedMotion.velocity(at: time)
        let gap = min(max((nextNote ?? time + 0.5) - time, 0.18), 1.1)
        side = random.unit() < 0.75 ? -side : side
        let dx = side * (0.06 + 0.08 * random.unit()) * min(gap / 0.5, 1.6)
        let dy = Self.stepDown * (1.3 - 0.6 * strength)
        var outgoing = SIMD2(dx / gap, (dy - 0.5 * Self.gravity * gap * gap) / gap)
        outgoing.y = min(max(outgoing.y, -1.5), -0.12)
        var normal = outgoing - incoming
        let length = (normal.x * normal.x + normal.y * normal.y).squareRoot()
        normal = length < 1e-3 ? SIMD2(0, -1) : normal / length
        let contact = position - normal * (Self.ballRadius * 1.15)
        pads.append(Pad(
            x: contact.x,
            y: contact.y,
            angle: atan2(normal.y, normal.x),
            length: 0.07 + 0.05 * strength,
            contact: time,
            duration: 0,
            lane: lane,
            strength: min(max(strength, 0), 1),
            kind: .bounce,
            outgoing: outgoing
        ))
        plannedMotion = .flying(from: position, velocity: outgoing, since: time)
    }

    /// 在球 `time` 那一刻的位置铺一段坡，球贴着坡滚 `duration` 秒；坡往这一下的横向那边倾斜。
    private mutating func placeRamp(at time: TimeInterval, duration: TimeInterval, lane: Int, strength: Double, kind: PadKind) {
        let position = plannedMotion.position(at: time)
        let incoming = plannedMotion.velocity(at: time)
        // 往球本来横着走的方向倾斜，没怎么横着走时左右轮着来。
        let heading: Double = abs(incoming.x) > 0.05 ? (incoming.x > 0 ? 1 : -1) : side
        side = heading
        let slope = kind == .glide ? Self.glideSlope : Self.rampSlope
        let direction = SIMD2(heading * cos(slope), sin(slope))
        let speed = kind == .glide ? 0.28 : 0.32 + 0.2 * strength
        let length = speed * duration
        // 坡面在球心下方一个半径：沿坡的法线往下挪。
        let normal = SIMD2(direction.y * heading, -direction.x * heading)
        let surface = position - normal * Self.ballRadius
        pads.append(Pad(
            x: surface.x,
            y: surface.y,
            angle: atan2(direction.y, direction.x),
            length: length,
            contact: time,
            duration: duration,
            lane: lane,
            strength: min(max(strength, 0), 1),
            kind: kind,
            outgoing: direction * speed
        ))
        plannedMotion = .rolling(from: position, direction: direction, speed: speed, since: time, until: time + duration)
        // 滚完以后顺着坡飞出去。
        let exit = plannedMotion.position(at: time + duration)
        plannedMotion = .flying(from: exit, velocity: direction * speed + SIMD2(0, -0.12), since: time + duration)
        // 滚坡那一段单独记下：`motion` 走到它时照着滚。
        rolls.append(Roll(from: position, direction: direction, speed: speed, since: time, until: time + duration))
    }

    private struct Roll: Equatable, Sendable {
        var from: SIMD2<Double>
        var direction: SIMD2<Double>
        var speed: Double
        var since: TimeInterval
        var until: TimeInterval
    }

    private var rolls: [Roll] = []

    /// 走到 `time` 为止该碰的音条一根根碰掉：弹开的照记下的速度飞出去，坡上贴着滚，滚完顺着坡飞出去。
    private mutating func contactPads(through time: TimeInterval) {
        while true {
            let pending = pads.indices
                .filter { pads[$0].contact > motion.startTime + 1e-6 && pads[$0].contact <= time }
                .min { pads[$0].contact < pads[$1].contact }
            let rollEnd = motion.rollEnd.flatMap { $0 <= time ? $0 : nil }
            if let rollEnd, pending.map({ pads[$0].contact >= rollEnd }) ?? true {
                // 滚完了：顺着坡飞出去。
                let exit = motion.position(at: rollEnd)
                let velocity = motion.velocity(at: rollEnd) + SIMD2(0, -0.12)
                motion = .flying(from: exit, velocity: velocity, since: rollEnd)
                continue
            }
            guard let index = pending else { return }
            let pad = pads[index]
            let position = motion.position(at: pad.contact)
            ball.lastContact = pad.contact
            switch pad.kind {
            case .bounce:
                motion = .flying(from: position, velocity: pad.outgoing, since: pad.contact)
            case .ramp, .glide:
                if let roll = rolls.first(where: { abs($0.since - pad.contact) < 1e-6 }) {
                    motion = .rolling(from: roll.from, direction: roll.direction, speed: roll.speed, since: roll.since, until: roll.until)
                } else {
                    let speed = hypot(pad.outgoing.x, pad.outgoing.y)
                    let direction = speed > 0 ? pad.outgoing / speed : SIMD2(1, 0)
                    motion = .rolling(from: position, direction: direction, speed: speed, since: pad.contact, until: pad.contact + pad.duration)
                }
                rolls.removeAll { $0.until < pad.contact - 1 }
            }
        }
    }

    /// 谱面上附近没有音、也没有排好的音条时听到一下起音：当场在球底下垫一根音条把它弹开。还没滚到的缓坡作废，
    /// 正在缓坡上滚着就滚到这儿为止。
    private mutating func bounceNow(strength: Double, notes: [ImmersiveKineticRhythmChart.Note], at time: TimeInterval) {
        guard time - ball.lastContact >= 0.16,
              !pads.contains(where: { $0.kind != .glide && $0.contact > time - 0.15 }),
              !notes.contains(where: { $0.time > time - 0.15 && $0.time < time + Self.preview }) else { return }
        if motion.rollEnd != nil {
            guard let index = pads.firstIndex(where: { $0.kind == .glide && abs($0.contact - motion.startTime) < 1e-6 }) else {
                return
            }
            let rolled = max(time - pads[index].contact, 0)
            pads[index].length *= pads[index].duration > 0 ? rolled / pads[index].duration : 0
            pads[index].duration = rolled
        }
        pads.removeAll { $0.kind == .glide && $0.contact > time }
        rolls.removeAll { $0.since > time }
        plannedMotion = motion
        placeBounce(at: time, nextNote: nil, lane: Int(random.unit() * 4) % 4, strength: strength)
        motion = plannedMotion
        ball.lastContact = time
    }

    // MARK: - 交给着色器

    public static let propsCapacity = 128
    static let trailOffset = 3
    static let padsOffset = 8

    /// 交给着色器的数据，float4 一组，位置已经换成画面里的（左上为原点，按画面高度算）。格式见
    /// `ImmersiveKineticShaderSource` 里弹珠落音的说明。
    public func packed(at time: TimeInterval) -> [SIMD4<Float>] {
        var props = [SIMD4<Float>](repeating: .zero, count: Self.propsCapacity)
        let shown = pads.suffix((Self.propsCapacity - Self.padsOffset) / 2)
        props[0] = SIMD4(
            Float(shown.count),
            Float(ball.trail.count),
            Float(cameraY.truncatingRemainder(dividingBy: 64)),
            Float(cameraX.truncatingRemainder(dividingBy: 64))
        )
        props[1] = SIMD4(Float(ball.x - cameraX), Float(ball.y - cameraY), Float(ball.radius), Float(ball.spin.truncatingRemainder(dividingBy: 2 * .pi)))
        props[2] = SIMD4(
            Float(time - ball.lastContact),
            Float(hypot(ball.vx, ball.vy)),
            motion.rollEnd != nil ? 1 : 0,
            0
        )
        for pair in 0..<(Self.trailLength / 2) {
            let a = ball.trail.indices.contains(pair * 2) ? ball.trail[pair * 2] : SIMD2(ball.x, ball.y)
            let b = ball.trail.indices.contains(pair * 2 + 1) ? ball.trail[pair * 2 + 1] : a
            props[Self.trailOffset + pair] = SIMD4(
                Float(a.x - cameraX), Float(a.y - cameraY), Float(b.x - cameraX), Float(b.y - cameraY)
            )
        }
        for (offset, pad) in shown.enumerated() {
            props[Self.padsOffset + offset * 2] = SIMD4(
                Float(pad.x - cameraX), Float(pad.y - cameraY), Float(pad.angle), Float(pad.length)
            )
            props[Self.padsOffset + offset * 2 + 1] = SIMD4(
                Float(time - pad.contact),
                Float(pad.lane + 1 + 8 * pad.kind.rawValue),
                Float(pad.strength),
                Float(pad.duration)
            )
        }
        return props
    }
}
