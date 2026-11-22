import Foundation

// 「水彩小剧场」的表演层：按判定层的状态（`ImmersiveTheaterState`）给每个角色定动作和表情。
// 动作都挂在弹簧通道上（目标一变，弹簧带着过冲追过去），起跳分预备下蹲、腾空拉长、落地压扁三段。
// 输出的是骨骼参数（位移、转角、沿骨骼方向的拉伸，单位同角色母版 SVG）和表情插槽，画法交给 App。
//
// 叠加顺序照原型：速度律动打底 → 音色 → 各自的分工 → 情绪 → 歌词意象 → 能量走向 → 点角色 → 播放情境，
// 后面的盖过前面的。

// MARK: - 弹簧

/// 半隐式欧拉的阻尼弹簧，欠阻尼时会冲过头再回来。
public struct ImmersiveTheaterSpring: Equatable, Sendable {
    public var value: Double
    public var velocity = 0.0
    public var target: Double
    public var stiffness: Double
    public var damping: Double
    /// 定格：不再往目标走（突然安静那一下）。
    public var frozen = false

    public init(value: Double, stiffness: Double, damping: Double) {
        self.value = value
        self.target = value
        self.stiffness = stiffness
        self.damping = damping
    }

    public mutating func step(_ dt: Double) {
        guard !frozen, dt > 0 else { return }
        let limit = 1.0 / 30
        let count = dt > limit ? Int((dt / limit).rounded(.up)) : 1
        let sub = dt / Double(count)
        for _ in 0..<count {
            let acceleration = stiffness * (target - value) - damping * velocity
            velocity += acceleration * sub
            value += velocity * sub
        }
    }

    public mutating func kick(_ delta: Double) {
        velocity += delta
    }
}

/// 每个角色身上的弹簧通道。数值是 [静止值, 刚度, 阻尼]。
public enum ImmersiveTheaterChannel: Int, CaseIterable, Sendable {
    case rootX, rootY, rootRot, sx, sy
    case hipsRot, hipsY, headRot, headX, headY
    case armL, armR, armLs, armRs, handL, handR
    case legL, legR, legLy, legRy, tail, earL, earR
    case phonesX, phonesY, phonesRot, phonesS, glassesY
    case browL, browR, browY, jaw, mouthS, lie, hat

    public var rest: Double {
        switch self {
        case .sx, .sy, .armLs, .armRs, .phonesS, .mouthS: 1
        default: 0
        }
    }

    var stiffness: Double {
        switch self {
        case .rootX, .rootRot: 120
        case .rootY, .hipsY, .headX: 160
        case .sx, .sy: 320
        case .hipsRot: 140
        case .headRot, .headY: 180
        case .armL, .armR, .legLy, .legRy: 260
        case .armLs, .armRs, .handL, .handR, .legL, .legR, .browL, .browR, .browY: 200
        case .tail: 90
        case .earL, .earR: 160
        case .phonesX, .phonesY, .phonesRot, .phonesS: 60
        case .glassesY: 90
        case .jaw: 420
        case .mouthS: 300
        case .lie: 18
        case .hat: 140
        }
    }

    var damping: Double {
        switch self {
        case .rootX, .headY, .hipsY, .headX: 13
        case .rootY: 14
        case .rootRot, .sx, .sy, .phonesX, .phonesY, .phonesRot, .phonesS: 12
        case .hipsRot: 11
        case .headRot, .glassesY: 13
        case .armL, .armR, .legLy, .legRy: 17
        case .armLs, .armRs, .browL, .browR, .browY: 16
        case .handL, .handR, .legL, .legR: 15
        case .tail: 7
        case .earL, .earR, .hat: 8
        case .jaw: 26
        case .mouthS: 20
        case .lie: 8
        }
    }
}

// MARK: - 输出

public enum ImmersiveTheaterEyes: String, CaseIterable, Sendable {
    case open, closed, happy, wide, up
}

public enum ImmersiveTheaterMouthShape: String, CaseIterable, Sendable {
    case rest, smile, open, wide
    case round = "O"
    case frown
}

public struct ImmersiveTheaterExpression: Equatable, Sendable {
    public var eyes = ImmersiveTheaterEyes.open
    public var mouth = ImmersiveTheaterMouthShape.rest
    /// 腮红浓淡 0…1。
    public var blush = 0.0
    public var tears = false
    public var sweat = false
    public var mouthAmount = 0.0

    public init() {}
}

/// 角色身边的道具和效果。
public struct ImmersiveTheaterProps: Equatable, Sendable {
    public var drums = false
    public var cast = false
    public var mill = false
    public var carrot = false
    public var umbrella = false
    public var airGuitar = false
    /// 鼻涕泡大小（猿音打呼时），nil 是没有。
    public var bubble: Double?
    /// 蓄力线 0…1。
    public var speedLines = 0.0
    public var millTheta = 0.0
    public var drumHit = 0.0
    public var drumKick = 0.0
    /// 药瓶的光 0…1。
    public var glow = 0.0

    public init() {}
}

/// 一根骨骼此刻的参数：位移（母版单位）、转角（弧度）、沿骨骼方向与垂直方向的拉伸。
public struct ImmersiveTheaterBonePose: Equatable, Sendable {
    public var tx = 0.0
    public var ty = 0.0
    public var rotation = 0.0
    public var stretchA = 1.0
    public var stretchB = 1.0

    public init(tx: Double = 0, ty: Double = 0, rotation: Double = 0, stretchA: Double = 1, stretchB: Double = 1) {
        self.tx = tx
        self.ty = ty
        self.rotation = rotation
        self.stretchA = stretchA
        self.stretchB = stretchB
    }
}

public struct ImmersiveTheaterPose: Equatable, Sendable {
    /// 骨骼名同角色清单（manifest.json）。没列出的骨骼不动。
    public var bones: [String: ImmersiveTheaterBonePose] = [:]
    public var expression = ImmersiveTheaterExpression()
    public var props = ImmersiveTheaterProps()
    /// 地上影子相对站位的横向偏移（母版单位）。
    public var shadowShift = 0.0
    /// 离地多高 0…1：影子跟着缩小变淡。
    public var airborne = 0.0
    /// 躺下的程度 0…1。
    public var lie = 0.0

    public init() {}
}

/// 表演层请 App 生成的小东西（音符、心、Z、问号、汗珠……），位置按角色身上的锚点算。
public enum ImmersiveTheaterSpawn: Equatable, Sendable {
    case note
    case heart
    case snore(size: Double)
    case question
    case sweat
    case puff
    case dust(count: Int)
    case tear
    case potionFlash(strength: Double)
    case greeting
}

public enum ImmersiveTheaterPokeKind: String, Sendable {
    /// 第一下：挥手打招呼。
    case greet
    /// 4 秒内再点：害羞捂脸。
    case shy
}

// MARK: - 表演

/// 一个角色的表演。值类型，每个在场的角色一份。
public struct ImmersiveTheaterPerformer: Sendable {
    public static let pokeMemory: TimeInterval = 4

    private enum JumpPhase: Sendable {
        case none, wait, crouch, air, land
    }

    private struct Jump: Sendable {
        var phase = JumpPhase.none
        var time = 0.0
        var height = 0.0
        var duration = 0.0
        var y = 0.0
        var velocity = 0.0
        var gravity = 0.0
    }

    public let member: ImmersiveTheaterCast.Member
    private var springs: [ImmersiveTheaterSpring]
    private var jump = Jump()
    private var blinkNext: Double
    private var longNote = 0.0
    private var lastSpawn: [String: Double] = [:]
    private var poke: (kind: ImmersiveTheaterPokeKind, start: Double)?
    private var lastPoke: (kind: ImmersiveTheaterPokeKind, time: Double)?
    private var random: ImmersiveRandom
    private var drumHit = 0.0
    private var drumKick = 0.0
    private var glow = 0.0
    private let characterHash: Int

    public private(set) var pose = ImmersiveTheaterPose()

    public init(member: ImmersiveTheaterCast.Member, seed: UInt64) {
        self.member = member
        springs = ImmersiveTheaterChannel.allCases.map { channel in
            ImmersiveTheaterSpring(value: channel.rest, stiffness: channel.stiffness, damping: channel.damping)
        }
        blinkNext = 1 + member.phase * 3
        random = ImmersiveRandom(seed: seed ^ ImmersiveRandom.seed(for: "performer." + member.character.rawValue))
        characterHash = Int(truncatingIfNeeded: ImmersiveRandom.seed(for: member.character.rawValue) & 0xFFFF)
    }

    public var character: ImmersiveTheaterCharacter { member.character }
    public var isPoked: Bool { poke != nil }

    /// 点了这个角色一下：第一下打招呼，4 秒内（或者正在打招呼时）再点就害羞。
    @discardableResult
    public mutating func receivePoke(at time: Double) -> ImmersiveTheaterPokeKind {
        let recentGreet = lastPoke.map { $0.kind == .greet && time - $0.time < Self.pokeMemory } ?? false
        let kind: ImmersiveTheaterPokeKind = poke?.kind == .greet || recentGreet ? .shy : .greet
        poke = (kind, time)
        lastPoke = (kind, time)
        return kind
    }

    private func value(_ channel: ImmersiveTheaterChannel) -> Double {
        springs[channel.rawValue].value
    }

    private mutating func kickSquash(_ amount: Double) {
        springs[ImmersiveTheaterChannel.sy.rawValue].kick(-amount)
        springs[ImmersiveTheaterChannel.sx.rawValue].kick(amount * 0.6)
    }

    private mutating func kick(_ channel: ImmersiveTheaterChannel, _ amount: Double) {
        springs[channel.rawValue].kick(amount)
    }

    /// 限频：同一种东西至少隔 `period` 秒才再冒一次。
    private mutating func every(_ key: String, _ period: Double, _ time: Double) -> Bool {
        let last = lastSpawn[key] ?? -Double.infinity
        guard time - last >= period else { return false }
        lastSpawn[key] = time
        return true
    }

    private mutating func startJump(height: Double, duration: Double, delay: Double = 0) {
        guard jump.phase == .none || jump.phase == .land else { return }
        jump.phase = .wait
        jump.time = -delay
        jump.height = height
        jump.duration = duration
    }

    /// 走一帧。`time` 是动画时钟（秒），`moonOnLeft` 是月亮在画面左边（月夜意象时指月亮）。
    public mutating func perform(
        _ state: ImmersiveTheaterState,
        time: Double,
        dt: Double,
        moonOnLeft: Bool?
    ) -> [ImmersiveTheaterSpawn] {
        var spawns: [ImmersiveTheaterSpawn] = []
        var target = ImmersiveTheaterChannel.allCases.map(\.rest)
        func set(_ channel: ImmersiveTheaterChannel, _ value: Double) { target[channel.rawValue] = value }
        func targetOf(_ channel: ImmersiveTheaterChannel) -> Double { target[channel.rawValue] }
        func add(_ channel: ImmersiveTheaterChannel, _ value: Double) { target[channel.rawValue] += value }

        var expression = ImmersiveTheaterExpression()
        var browMood = BrowMood.none
        var props = ImmersiveTheaterProps()
        let amp = member.personality.amplitude
        let phase = member.phase
        let w = time
        let bp = state.beatPosition
        let ph = state.beatPhase
        let bi = state.beatIndex
        let alt: Double = bi % 2 != 0 ? 1 : -1
        let sway2 = sin(Double.pi * bp)
        let isLead = member.character == .yuanyin
        let side = member.slot.side
        let events = state.events

        // 1. 速度律动（打底）
        switch state.groove {
        case .slow:
            set(.hipsRot, 0.075 * amp * sway2)
            set(.headRot, -0.05 * amp * sin(Double.pi * bp - 0.6))
            set(.rootX, 16 * amp * sway2)
            set(.armL, 0.35 + 0.15 * sway2)
            set(.armR, 0.35 - 0.15 * sway2)
            expression.eyes = Self.positiveModulo(bi, 8) == 7 ? .open : .closed
            expression.mouth = .smile
        case .mid:
            set(.headY, 20 * amp * Self.pulse(ph))
            set(.headRot, 0.05 * alt * amp)
            set(.hipsY, 7 * Self.pulse(ph))
            if bi % 2 != 0 { set(.legLy, -24 * Self.pulse(ph, 7)) } else { set(.legRy, -24 * Self.pulse(ph, 7)) }
            set(.armL, 0.25 + 0.12 * sway2)
            set(.armR, 0.25 - 0.12 * sway2)
            if events.beat { kickSquash(0.55 * amp) }
            expression.mouth = .smile
        case .fast:
            set(.rootY, -95 * amp * Self.hop(ph))
            set(.headRot, 0.2 * amp * alt * sin(Double.pi * ph))
            set(.armL, alt > 0 ? 1.9 : 0.55)
            set(.armR, alt > 0 ? 0.55 : 1.9)
            set(.armLs, 1.12)
            set(.armRs, 1.12)
            if events.beat { kickSquash(1.3 * amp) }
            expression.eyes = Self.positiveModulo(bi >> 1, 2) != 0 ? .happy : .open
            expression.mouth = .open
        case .unsteady:
            func noise(_ salt: Int) -> Double { (Self.valueNoise(w * 1.6 + phase * 9, seed: salt) - 0.5) * 2 }
            set(.hipsRot, 0.13 * amp * noise(1))
            set(.headRot, 0.1 * noise(2))
            set(.rootX, 30 * noise(3))
            set(.armL, 0.55 + 0.6 * noise(4))
            set(.armR, 0.55 + 0.6 * noise(5))
            if events.onset {
                let twist = (random.unit() - 0.5) * 3 * amp
                kick(.hipsRot, twist)
            }
            expression.eyes = state.onsetPulse[1] > 0.6 ? .wide : .open
            expression.mouth = Self.positiveModulo(Int((w * 0.7 + phase * 3).rounded(.down)), 3) == 0 ? .round : .smile
        case .float:
            set(.rootY, -170 - 45 * sin(w * 0.9 + phase * 6))
            set(.rootRot, 0.06 * sin(w * 0.5 + phase * 5))
            set(.armL, 1.2 + 0.25 * sin(w * 0.8))
            set(.armR, 1.2 + 0.25 * sin(w * 0.8 + 1))
            set(.legL, 0.14 * sin(w * 0.7))
            set(.legR, -0.14 * sin(w * 0.7 + 0.5))
            expression.eyes = .closed
            expression.mouth = .smile
        }
        set(.tail, 0.22 * sin(w * 2 + phase * 6) + (state.groove == .mid || state.groove == .fast ? 0.25 * alt : 0))
        if events.highOnset, random.unit() < 0.5 {
            kick(.earL, 3)
            kick(.earR, -3)
        }

        // 2. 音色：低音、人声、器乐
        if state.bass {
            add(.rootY, -38 * state.lowEnvelope * amp)
            if events.lowOnset { kickSquash(1.1 * amp * (0.5 + events.lowStrength)) }
        }
        if state.timbre == .vocal {
            if isLead {
                let mouth = state.mouth
                expression.mouthAmount = mouth
                if state.mouthRound {
                    expression.mouth = .round
                } else if mouth > 0.5 {
                    expression.mouth = .wide
                } else if mouth > 0.12 {
                    expression.mouth = .open
                } else {
                    expression.mouth = .rest
                }
                add(.headY, 12 * mouth)
                longNote = mouth > 0.45 ? longNote + dt : 0
                if longNote > 0.6 {
                    // 长音：一只手捂住耳机。
                    set(.armL, 2.35)
                    set(.armLs, 1.3)
                }
                set(.armR, max(targetOf(.armR), 0.9 + 0.7 * mouth))
            } else {
                expression.mouth = expression.mouth == .open ? .open : .smile
            }
        } else if state.timbre == .instrumental, isLead {
            // 空气吉他。
            set(.armL, 1.25 + 0.08 * sin(w * 7))
            set(.armLs, 1.15)
            set(.armR, 0.6 + 0.38 * sin(2 * Double.pi * bp))
            set(.armRs, 1.1)
            set(.rootRot, -0.06)
            add(.headY, 14 * Self.pulse(ph))
            if events.beat { kickSquash(0.6) }
            expression.eyes = Self.positiveModulo(bi >> 2, 2) != 0 ? .closed : .happy
            expression.mouth = .round
            props.airGuitar = true
            if events.onset, every("note", 0.45, w) { spawns.append(.note) }
        }

        // 3. 各自的分工
        switch member.character {
        case .xiaohei:
            if state.roles.drum {
                props.drums = true
                let leftHit = Self.positiveModulo(bi, 2) == 0
                let up = ph > 0.55 ? 1.9 : ph < 0.14 ? 0.15 : 0.9
                set(.armL, leftHit ? up : 0.5)
                set(.armR, leftHit ? 0.5 : up)
                set(.armLs, 1.15)
                set(.armRs, 1.15)
                if events.onset, !events.beat {
                    let leftArm = random.unit() < 0.5
                    kick(leftArm ? .armL : .armR, -9)
                }
                if events.lowOnset {
                    set(.legRy, -30)
                    drumKick = 1
                }
                if events.beat {
                    drumHit = 1
                    kickSquash(0.5)
                }
                add(.headY, 16 * Self.pulse(ph))
                expression.eyes = state.arc == .climax ? .happy : .closed
                expression.mouth = state.arc == .climax ? .wide : .round
            } else {
                set(.armL, max(targetOf(.armL), alt > 0 ? 1.6 * Self.pulse(ph, 2.5) + 0.3 : 0.3))
                set(.armR, max(targetOf(.armR), alt < 0 ? 1.6 * Self.pulse(ph, 2.5) + 0.3 : 0.3))
            }
        case .ajiu:
            if state.roles.cast {
                props.cast = true
                set(.armR, 1.4 + 0.35 * sin(Double.pi * bp))
                set(.armRs, 1.35)
                set(.armL, 0.9 + 0.2 * sin(Double.pi * bp + 1))
                set(.hat, 0.1 * alt)
                expression.eyes = Self.positiveModulo(bi, 4) == 0 && ph < 0.3 ? .wide : .happy
                expression.mouth = .open
                if events.beat {
                    glow = 1
                    spawns.append(.potionFlash(strength: Self.positiveModulo(bi, 4) == 0 ? 1 : 0.55))
                }
            } else {
                set(.hat, 0.04 * sin(w * 2))
            }
        case .xiaohuolv:
            switch state.roles.donkey {
            case .lie:
                set(.lie, 1)
                set(.sy, 1 + 0.025 * sin(w * 1.6))
                set(.legL, 0.22 * sin(w * 1.2))
                set(.legR, 0.22 * sin(w * 1.2 + 1))
                set(.armL, 0.2)
                set(.armR, 0.4)
                set(.headRot, 0.05 * sin(w * 0.7))
                set(.rootX, 0)
                set(.rootY, 0)
                set(.hipsRot, 0)
                expression.eyes = Self.positiveModulo(Int((w / 3 + phase * 5).rounded(.down)), 4) == 0 ? .closed : .open
                expression.mouth = .rest
                props.carrot = true
            case .mill:
                let theta = Double.pi * bp / 4
                props.millTheta = theta
                set(.rootX, 360 * sin(theta))
                set(.rootY, -32 * Self.hop(ph))
                set(.rootRot, 0.08 * cos(theta))
                set(.legL, 0.28 * sin(Double.pi * bp))
                set(.legR, -0.28 * sin(Double.pi * bp))
                set(.armL, 0.5 + 0.3 * sin(Double.pi * bp))
                set(.armR, 0.5 - 0.3 * sin(Double.pi * bp))
                set(.headRot, 0)
                set(.hipsRot, 0)
                expression.eyes = .open
                expression.mouth = .smile
                props.mill = true
            case .metronome:
                set(.tail, 0.55 * alt)
                set(.headRot, 0.09 * alt)
                if events.beat, Self.positiveModulo(bi, 4) == 0 {
                    kick(.earL, 4)
                    kick(.earR, -4)
                }
            }
        case .yuanyin:
            break
        }

        // 4. 情绪：打底的表情
        switch state.mood {
        case .happy:
            if expression.eyes == .open { expression.eyes = Self.positiveModulo(bi >> 1, 2) == 0 ? .happy : .open }
            if expression.mouth == .rest { expression.mouth = .smile }
            expression.blush = max(expression.blush, 0.3)
        case .sad:
            add(.headY, 22)
            add(.headRot, 0.04 * side)
            browMood = .sad
            if expression.mouth == .smile || expression.mouth == .rest { expression.mouth = .frown }
            if isLead || member.character == .ajiu,
               (w + phase * 7).truncatingRemainder(dividingBy: 14) < 4.5 {
                expression.tears = true
            }
        case .tender:
            if expression.mouth == .rest { expression.mouth = .smile }
            expression.blush = max(expression.blush, 0.5)
            add(.headRot, 0.06 * side)
            if expression.eyes == .open, (w + phase * 4).truncatingRemainder(dividingBy: 4) < 0.6 {
                expression.eyes = .closed
            }
        case .neutral:
            break
        }

        // 5. 歌词意象
        switch state.imagery {
        case .rain:
            if state.mood == .sad {
                if isLead { expression.tears = true }
            } else if isLead {
                set(.armR, 2.15)
                set(.armRs, 1.3)
                props.umbrella = true
            } else if expression.eyes == .open {
                expression.eyes = .closed
            }
        case .tears:
            if isLead || state.mood == .sad || member.character == .ajiu {
                expression.tears = true
                expression.eyes = .closed
                expression.mouth = .frown
                browMood = .sad
                add(.headY, 16)
            }
        case .love:
            expression.blush = 0.9
            if expression.eyes == .open || expression.eyes == .closed { expression.eyes = .happy }
            if every("heart", 0.75 + phase * 0.4, w) { spawns.append(.heart) }
        case .moon:
            add(.headY, -16)
            expression.eyes = .up
            browMood = .up
            if isLead {
                if moonOnLeft == true {
                    set(.armL, 2.5)
                    set(.armLs, 1.3)
                } else {
                    set(.armR, 2.5)
                    set(.armRs, 1.3)
                }
            }
        case nil:
            break
        }

        // 6. 能量走向（盖过动作）
        let busyArms = props.drums || props.cast
        switch state.arc {
        case .intro:
            expression.eyes = .closed
            expression.mouth = .rest
            set(.headY, 26 + 10 * sin(w * 0.8 + phase))
            set(.headRot, 0.08 * sin(w * 0.35 + phase * 6))
            set(.sy, 1 + 0.02 * sin(w * 1.5 + phase))
            set(.armL, 0.08)
            set(.armR, 0.08)
            set(.rootY, min(targetOf(.rootY), 0) * 0.2)
            set(.hipsRot, 0)
            set(.rootX, 0)
            // 隔几秒猛点一下头惊醒。
            if (w + phase * 5).truncatingRemainder(dividingBy: 4.6) > 4.25 {
                set(.headY, -12)
                expression.eyes = .wide
            }
            if isLead || member.slot == .left, every("z", 2.3, w) { spawns.append(.snore(size: 0.7)) }
        case .build:
            let progress = state.buildProgress
            set(.sy, 1 - 0.16 * progress)
            set(.sx, 1 + 0.08 * progress)
            set(.hipsY, 20 * progress)
            add(.headY, 10 * progress)
            if !busyArms {
                set(.armL, 0.45)
                set(.armR, 0.45)
            }
            add(.rootX, (Self.hash3(Int((w * 30).rounded(.down)), characterHash, 1) - 0.5) * 18 * progress)
            set(.rootY, 0)
            browMood = .angry
            expression.eyes = progress > 0.6 ? .wide : .open
            expression.mouth = progress > 0.7 ? .round : .rest
            props.speedLines = progress
        case .climax:
            if state.groove == .float {
                // 没拍子可跳：整个人往上飘。
                add(.rootY, -120)
                set(.armL, 2.2)
                set(.armR, 2.2)
                expression.eyes = .happy
                expression.mouth = .open
                expression.blush = max(expression.blush, 0.4)
            } else {
                if state.arcEnter {
                    startJump(
                        height: 420 * amp + 60 * phase,
                        duration: 0.85,
                        delay: member.slot.depth == 2 ? 0 : 0.06 + phase * 0.08
                    )
                }
                let jumpEvery = (state.beatsPerMinute >= 100 || state.groove == .fast) ? 1 : 2
                if events.beat, Self.positiveModulo(bi, jumpEvery) == 0, state.arcTime > 0.9 {
                    startJump(height: 150 * amp, duration: min(0.42, state.beatPeriod * Double(jumpEvery) * 0.7))
                }
                if !busyArms {
                    set(.armL, alt > 0 ? 2.35 : 1.6)
                    set(.armR, alt > 0 ? 1.6 : 2.35)
                    set(.armLs, 1.2)
                    set(.armRs, 1.2)
                }
                expression.eyes = .happy
                expression.mouth = isLead && state.timbre == .vocal ? (state.mouth > 0.12 ? .wide : .open) : .wide
                expression.blush = max(expression.blush, 0.4)
                if member.character == .xiaohuolv, state.roles.donkey == .lie { set(.lie, 0) }
            }
        case .quiet:
            let elapsed = state.arcTime
            let freeze = elapsed < 0.45
            for index in springs.indices { springs[index].frozen = freeze }
            if !freeze {
                let look: Double = sin(Double.pi * (elapsed - 0.45) / 0.8) >= 0 ? 1 : -1
                set(.headRot, 0.12 * look)
                set(.headX, 22 * look)
                set(.rootY, 0)
                set(.armL, 0.55)
                set(.armR, 0.55)
                set(.rootX, 0)
                set(.hipsRot, 0)
                expression.eyes = .wide
                expression.mouth = .round
                browMood = .up
                if elapsed > 0.5, every("q", 2.5, w) { spawns.append(.question) }
            }
        case .cooldown:
            let c = state.arcTime
            if c < 1.8 {
                let k = c < 0.45 ? c / 0.45 : c < 1.15 ? 1 : 1 - (c - 1.15) / 0.65
                let wiping = c > 0.45 && c < 1.15
                let raised = wiping ? 2.55 - 0.45 * sin((c - 0.45) / 0.7 * Double.pi) : 2.55
                set(.armR, 0.3 + (raised - 0.3) * k)
                set(.armRs, 1 + 0.55 * k)
                set(.headRot, wiping ? -0.08 : 0)
                set(.sy, 0.97)
                add(.headY, 8)
                set(.rootY, 0)
                expression.eyes = c < 1.2 ? .closed : .happy
                expression.mouth = c > 1.1 && c < 1.5 ? .round : .smile
                expression.sweat = c < 1.6
                if c > 0.85, every("sweat", 3, w) { spawns.append(.sweat) }
                if c > 1.15, every("puff", 3, w) { spawns.append(.puff) }
            } else {
                set(.sy, 0.985)
                expression.eyes = .happy
            }
        case .normal:
            break
        }
        if state.arc != .quiet {
            for index in springs.indices { springs[index].frozen = false }
        }

        // 7. 点角色
        if let poke {
            let elapsed = w - poke.start
            if elapsed > (poke.kind == .greet ? 1.9 : 2.3) || elapsed < 0 {
                self.poke = nil
            } else if poke.kind == .greet {
                // 右边的角色举左手，免得手挡住中间。
                let useLeft = side > 0 && !isLead
                if useLeft {
                    set(.armL, 2.45 + 0.35 * sin(w * 14))
                    set(.armLs, 1.2)
                } else {
                    set(.armR, 2.45 + 0.35 * sin(w * 14))
                    set(.armRs, 1.2)
                }
                set(.headRot, 0.08 * (side == 0 ? 1 : side))
                expression.eyes = .happy
                expression.mouth = .wide
                set(.lie, 0)
            } else {
                set(.armL, 2.05)
                set(.armR, 2.05)
                set(.armLs, 1.32)
                set(.armRs, 1.32)
                set(.headRot, -0.1 * sin(w * 3))
                add(.headY, 14)
                set(.rootX, 10 * sin(w * 3))
                expression.blush = 1
                expression.eyes = .closed
                expression.mouth = .rest
                set(.lie, 0)
            }
        }

        // 8. 播放情境（最优先）
        if state.playback != .playing {
            let paused = state.pausedFor
            for channel in [ImmersiveTheaterChannel.rootX, .rootY, .rootRot, .hipsRot, .hipsY, .legLy, .legRy, .legL, .legR] {
                set(channel, channel.rest)
            }
            set(.sx, 1)
            set(.sy, 1 + 0.015 * sin(w * 1.4 + phase))
            set(.headX, 0)
            if isLead {
                // 摘下耳机拎在手里，推起墨镜，露出眼睛看镜头。
                set(.armL, 0.2)
                set(.armR, 0.2)
                set(.armLs, 1)
                set(.armRs, 1)
                if paused < 0.55 {
                    set(.armL, 2.25)
                    set(.armR, 2.25)
                    set(.armLs, 1.35)
                    set(.armRs, 1.35)
                } else if paused < 1.1 {
                    set(.armL, 2.6)
                    set(.armR, 2.6)
                    set(.armLs, 1.45)
                    set(.armRs, 1.45)
                    set(.phonesY, -260)
                    set(.phonesRot, -0.12)
                } else {
                    set(.phonesX, 470)
                    set(.phonesY, 600)
                    set(.phonesRot, 0.9)
                    set(.phonesS, 0.6)
                    set(.armR, 0.5)
                }
                if paused >= 1.6, paused < 2.15 {
                    set(.armL, 2.55)
                    set(.armLs, 1.55)
                }
                if paused >= 1.75 { set(.glassesY, -195) }
                if paused >= 2.15 {
                    expression.eyes = paused < 2.35 ? .wide : .open
                    set(.browY, -16)
                    set(.headRot, 0.1)
                    expression.mouth = paused < 3 ? .round : .rest
                } else {
                    expression.eyes = .open
                }
                if paused > 2.6, paused < 2.7, every("q", 5, w) { spawns.append(.question) }
            } else {
                set(.armL, 0.2)
                set(.armR, 0.2)
                expression.eyes = paused < 0.5 ? .wide : .open
                expression.mouth = paused < 1.5 ? .round : .rest
                set(.headRot, 0.06 * side)
                if member.character == .xiaohuolv { set(.lie, 0) }
            }
            if state.playback == .snore {
                let breath = sin(w * 2.4)
                expression.eyes = .closed
                set(.headY, 30)
                set(.headRot, 0.12 * (side == 0 ? 1 : side))
                set(.sy, 1 + 0.03 * breath)
                expression.mouth = breath > 0.3 ? .round : .rest
                if isLead {
                    set(.phonesX, 470)
                    set(.phonesY, 600)
                    set(.phonesRot, 0.9)
                    set(.phonesS, 0.6)
                    set(.glassesY, -195)
                    props.bubble = 0.5 + 0.5 * breath
                }
                if member.character == .xiaohuolv { set(.lie, 1) }
                if every("z", isLead ? 1.2 : 2 + phase, w) { spawns.append(.snore(size: 1.2)) }
            }
        }

        if expression.tears, every("tear", 0.55, w) { spawns.append(.tear) }
        // 眨眼。
        if expression.eyes == .open {
            if w > blinkNext + 0.13 {
                blinkNext = w + 2.2 + Self.hash3(Int(w.rounded(.down)), characterHash, 5) * 3
            } else if w > blinkNext {
                expression.eyes = .closed
            }
        }
        switch browMood {
        case .sad:
            set(.browL, -0.22)
            set(.browR, 0.22)
            add(.browY, 6)
        case .angry:
            set(.browL, 0.24)
            set(.browR, -0.24)
            add(.browY, 8)
        case .up:
            add(.browY, -18)
        case .none:
            break
        }
        // 嘴张多大。
        set(.jaw, expression.mouth == .wide ? 1 : expression.mouth == .open ? 0.5 : 0)
        if isLead, state.timbre == .vocal, state.playback == .playing { set(.jaw, expression.mouthAmount) }
        switch expression.mouth {
        case .wide: set(.mouthS, 0.85 + 0.35 * max(expression.mouthAmount, 0.5))
        case .open: set(.mouthS, 0.8 + 0.4 * expression.mouthAmount)
        default: set(.mouthS, 1)
        }

        // 起跳那几段盖过身体的压扁拉长：预备时往下蹲，腾空时拉长。
        switch jump.phase {
        case .crouch:
            set(.sy, 0.8)
            set(.sx, 1.12)
        case .air:
            set(.sy, jump.velocity < 0 ? 1.12 : 1.04)
            set(.sx, jump.velocity < 0 ? 0.92 : 0.98)
        case .none, .wait, .land:
            break
        }
        for index in springs.indices {
            springs[index].target = target[index]
            springs[index].step(dt)
        }
        if let dust = advanceJump(dt: dt) { spawns.append(dust) }

        drumHit *= 0.85
        drumKick *= 0.85
        glow *= 0.9
        props.drumHit = drumHit
        props.drumKick = drumKick
        props.glow = glow
        pose = makePose(expression: expression, props: props)
        return spawns
    }

    /// 起跳：预备下蹲 0.1 秒 → 腾空时拉长 → 落地压扁。
    private mutating func advanceJump(dt: Double) -> ImmersiveTheaterSpawn? {
        let sy = ImmersiveTheaterChannel.sy.rawValue
        let sx = ImmersiveTheaterChannel.sx.rawValue
        guard !springs[ImmersiveTheaterChannel.rootY.rawValue].frozen else { return nil }
        switch jump.phase {
        case .none:
            return nil
        case .wait:
            jump.time += dt
            if jump.time >= 0 {
                jump.phase = .crouch
                jump.time = 0
            }
        case .crouch:
            jump.time += dt
            if jump.time > 0.1 {
                jump.phase = .air
                let duration = max(jump.duration, 0.1)
                jump.velocity = -4 * jump.height / duration
                jump.gravity = 8 * jump.height / (duration * duration)
                jump.y = 0
                springs[sy].kick(3)
            }
        case .air:
            jump.velocity += jump.gravity * dt
            jump.y += jump.velocity * dt
            if jump.y >= 0 {
                jump.y = 0
                jump.phase = .land
                jump.time = 0
                springs[sy].kick(-3.2)
                springs[sx].kick(1.8)
                if jump.height > 300 { return .dust(count: 3) }
            }
        case .land:
            jump.time += dt
            if jump.time > 0.12 { jump.phase = .none }
        }
        return nil
    }

    private func makePose(expression: ImmersiveTheaterExpression, props: ImmersiveTheaterProps) -> ImmersiveTheaterPose {
        let lie = value(.lie)
        var bones: [String: ImmersiveTheaterBonePose] = [:]
        var root = ImmersiveTheaterBonePose(
            tx: value(.rootX) + 380 * lie,
            ty: value(.rootY) + jump.y - 330 * lie,
            rotation: value(.rootRot) - 1.42 * lie,
            stretchA: value(.sx),
            stretchB: value(.sy)
        )
        if props.mill {
            let depth = cos(props.millTheta)
            root.stretchA *= 1 + 0.08 * depth
            root.stretchB *= 1 + 0.08 * depth
        }
        bones["root"] = root
        bones["hips"] = ImmersiveTheaterBonePose(ty: value(.hipsY), rotation: value(.hipsRot))
        bones["head"] = ImmersiveTheaterBonePose(tx: value(.headX), ty: value(.headY), rotation: value(.headRot))
        bones["armL"] = ImmersiveTheaterBonePose(rotation: value(.armL), stretchA: value(.armLs))
        bones["armR"] = ImmersiveTheaterBonePose(rotation: -value(.armR), stretchA: value(.armRs))
        bones["handL"] = ImmersiveTheaterBonePose(rotation: value(.handL))
        bones["handR"] = ImmersiveTheaterBonePose(rotation: -value(.handR))
        bones["legL"] = ImmersiveTheaterBonePose(ty: value(.legLy), rotation: value(.legL))
        bones["legR"] = ImmersiveTheaterBonePose(ty: value(.legRy), rotation: value(.legR))
        bones["tail"] = ImmersiveTheaterBonePose(rotation: value(.tail))
        bones["earL"] = ImmersiveTheaterBonePose(rotation: -value(.earL) * 0.6)
        bones["earR"] = ImmersiveTheaterBonePose(rotation: value(.earR) * 0.6)
        bones["browL"] = ImmersiveTheaterBonePose(ty: value(.browY), rotation: value(.browL))
        bones["browR"] = ImmersiveTheaterBonePose(ty: value(.browY), rotation: value(.browR))
        bones["mouth"] = ImmersiveTheaterBonePose(stretchB: value(.mouthS))
        switch member.character {
        case .yuanyin:
            let scale = value(.phonesS)
            bones["phones"] = ImmersiveTheaterBonePose(
                tx: value(.phonesX),
                ty: value(.phonesY),
                rotation: value(.phonesRot),
                stretchA: scale,
                stretchB: scale
            )
            bones["glasses"] = ImmersiveTheaterBonePose(ty: value(.glassesY))
        case .xiaohei:
            let jaw = min(max(value(.jaw), 0), 1.2)
            bones["jaw"] = ImmersiveTheaterBonePose(ty: 62 * jaw)
            bones["inner"] = ImmersiveTheaterBonePose(ty: 10 * jaw, stretchB: max(0.02, jaw))
            bones["lipU"] = ImmersiveTheaterBonePose(ty: -8 * jaw, stretchA: expression.mouth == .frown ? 0.82 : 1)
            bones["eyes"] = ImmersiveTheaterBonePose(ty: expression.eyes == .up ? -6 : 0)
        case .ajiu:
            bones["sleeveL"] = ImmersiveTheaterBonePose(rotation: value(.armL) * 0.28)
            bones["sleeveR"] = ImmersiveTheaterBonePose(rotation: -value(.armR) * 0.28)
            bones["hat"] = ImmersiveTheaterBonePose(rotation: value(.hat) + value(.headRot) * 0.2)
        case .xiaohuolv:
            break
        }
        var pose = ImmersiveTheaterPose()
        pose.bones = bones
        pose.expression = expression
        pose.props = props
        pose.lie = lie
        pose.shadowShift = value(.rootX) + 120 * lie
        pose.airborne = min(max(-(value(.rootY) + jump.y) / 700, 0), 1)
        return pose
    }

    private enum BrowMood {
        case none, sad, angry, up
    }

    // MARK: 工具

    /// 拍点后迅速落下的包络。
    static func pulse(_ phase: Double, _ rate: Double = 5) -> Double { exp(-phase * rate) }

    /// 一拍里的一跳：拍上贴地，拍中最高。
    static func hop(_ phase: Double) -> Double {
        pow(sin(Double.pi * min(max(phase, 0), 1)), 0.8)
    }

    static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        guard divisor != 0 else { return 0 }
        return ((value % divisor) + divisor) % divisor
    }

    /// 三个整数打散成 0…1。
    static func hash3(_ a: Int, _ b: Int, _ c: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: a) &* 0x27D4_EB2D
            ^ UInt32(truncatingIfNeeded: b) &* 0x1656_67B1
            ^ UInt32(truncatingIfNeeded: c) &* 0x9E37_79B1
        h ^= h >> 15
        h = h &* 0x85EB_CA6B
        h ^= h >> 13
        h = h &* 0xC2B2_AE35
        h ^= h >> 16
        return Double(h) / 4_294_967_296
    }

    /// 一维值噪声 0…1，平滑、确定。
    static func valueNoise(_ x: Double, seed: Int) -> Double {
        let base = x.rounded(.down)
        let fraction = x - base
        let index = Int(base)
        let a = hash3(index, seed, 7)
        let b = hash3(index + 1, seed, 7)
        let eased = fraction * fraction * (3 - 2 * fraction)
        return a + (b - a) * eased
    }
}
