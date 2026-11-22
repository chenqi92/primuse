import CoreGraphics
import Foundation
import Observation
import PrimuseKit
import SwiftUI

// 「水彩小剧场」的逐帧宿主：判定层（`ImmersiveTheaterConductor`）读频谱与歌词，导演层换镜头，表演层给每个角色
// 定姿势；这里再管镜头的推摇与抖动、粒子、转场和背景图的请求，最后交出一份只读的帧（`ImmersiveTheaterFrame`）
// 给 Canvas 画。都在主线程上跑，只是算数；背景图与纸偶在后台准备好了再接进来。

// MARK: - 点角色

/// 点角色的通道。全屏页持有一个交给舞台；舞台每帧写进角色在画面上的位置，全屏页的点按先问它点没点中角色。
@MainActor
final class ImmersiveTheaterPokeChannel {
    struct Shape {
        let inverse: CGAffineTransform
        let rect: CGRect
    }

    struct Target {
        let character: ImmersiveTheaterCharacter
        let shapes: [Shape]
    }

    fileprivate(set) var targets: [Target] = []
    fileprivate var pending: [ImmersiveTheaterCharacter] = []
    /// 舞台在动、没有休憩时才接点按；停着的画面上点角色没有反应，那一下照旧算点空白。
    fileprivate(set) var isAccepting = false

    init() {}

    /// `point` 是舞台坐标。点中角色时记下来交给下一帧，返回 true，全屏页就不再把这一下当成点空白。
    func poke(at point: CGPoint) -> Bool {
        guard isAccepting else { return false }
        for target in targets {
            for shape in target.shapes {
                let local = point.applying(shape.inverse)
                let inset = shape.rect.insetBy(dx: shape.rect.width * 0.08, dy: shape.rect.height * 0.08)
                if inset.contains(local) {
                    pending.append(target.character)
                    return true
                }
            }
        }
        return false
    }
}

/// 很少变的几件事：画面亮不亮（歌词换深色字）、背景或纸偶到了（停着的画面要重画一次）。
@MainActor
@Observable
final class ImmersiveTheaterSignals {
    var isLightShot = false
    var revision = 0
}

// MARK: - 帧

struct ImmersiveTheaterInkStroke {
    let path: Path
    let width: CGFloat
    let color: Color
    let opacity: Double
}

struct ImmersiveTheaterInkFill {
    let path: Path
    let color: Color
    let opacity: Double
}

/// 一组墨线（世界坐标）：一秒换十二次抖法，同一次抖法里只算一遍。
struct ImmersiveTheaterInkSheet {
    var strokes: [ImmersiveTheaterInkStroke] = []
    var fills: [ImmersiveTheaterInkFill] = []
}

struct ImmersiveTheaterParticle {
    enum Kind {
        case confetti, star, heart, note, drop, orb, spark, dust, petal, ripple, meteor
        case text(String)
    }

    var kind: Kind
    var x: Double
    var y: Double
    var vx = 0.0
    var vy = 0.0
    var gravity = 0.0
    var drag = 0.0
    var life = 1.0
    var age = 0.0
    var size = 1.0
    var rotation = 0.0
    var spin = 0.0
    var color = ImmersiveTheaterRGB(1, 1, 1)
    var seed = 0
    var grows = false
}

struct ImmersiveTheaterActorFrame {
    let puppet: ImmersiveTheaterPuppet
    let member: ImmersiveTheaterCast.Member
    /// 母版坐标 → 世界坐标（不含骨骼）。
    let worldTransform: CGAffineTransform
    /// 母版坐标 → 视口（不含骨骼）。
    let viewTransform: CGAffineTransform
    let bones: [CGAffineTransform]
    let pose: ImmersiveTheaterPose
    let slot: (x: Double, y: Double, scale: Double)
}

struct ImmersiveTheaterTransitionFrame {
    let kind: ImmersiveTheaterTransition
    let progress: Double
    let old: ImmersiveTheaterBackdrop
    /// 圆形开合的圆心（视口坐标）。
    let focus: CGPoint
    let seed: Int
}

/// 画一帧要的全部东西，只读。
struct ImmersiveTheaterFrame {
    var size: CGSize
    var world: ImmersiveTheaterWorld
    var palette: ImmersiveTheaterScenePalette
    var backdrop: ImmersiveTheaterBackdrop?
    /// 世界 → 视口：背景那一层（视差小一些）和角色那一层。
    var background: CGAffineTransform
    var foreground: CGAffineTransform
    var ink: ImmersiveTheaterInkSheet?
    var transition: ImmersiveTheaterTransitionFrame?
    var actors: [ImmersiveTheaterActorFrame]
    var particles: [ImmersiveTheaterParticle]
    var flash: Double
    var flashColor: ImmersiveTheaterRGB
    var time: Double
    var boil: Int
    var beatPosition: Double
    var beatPulse: Double
    var high: Double
    var intensity: Double
    var speedLines: Double
}

// MARK: - 镜头

/// 镜头：中心与缩放都挂在很软的弹簧上（缓推缓摇），鼓点给一下抖动，高潮那一下猛推。
struct ImmersiveTheaterCamera {
    var x = ImmersiveTheaterSpring(value: 800, stiffness: 7, damping: 5.3)
    var y = ImmersiveTheaterSpring(value: 450, stiffness: 7, damping: 5.3)
    var z = ImmersiveTheaterSpring(value: 1, stiffness: 7, damping: 5.3)
    var shake = 0.0
    var punch = 0.0
    var shakeX = 0.0
    var shakeY = 0.0
    var rotation = 0.0

    mutating func reset(x: Double, y: Double, z: Double) {
        self.x = ImmersiveTheaterSpring(value: x, stiffness: 7, damping: 5.3)
        self.y = ImmersiveTheaterSpring(value: y, stiffness: 7, damping: 5.3)
        self.z = ImmersiveTheaterSpring(value: z, stiffness: 7, damping: 5.3)
        shake = 0
        punch = 0
    }

    mutating func aim(x: Double, y: Double, z: Double) {
        self.x.target = x
        self.y.target = y
        self.z.target = z
    }

    mutating func impulse(_ strength: Double) {
        shake = min(14, shake + strength)
    }

    mutating func update(dt: Double, time: Double) {
        x.step(dt)
        y.step(dt)
        z.step(dt)
        shake *= exp(-dt / 0.12)
        punch *= exp(-dt / 0.16)
        let tick = Int((time * 30).rounded(.down))
        shakeX = (ImmersiveTheaterNoise.hash3(tick, 3, 1) - 0.5) * 2 * shake
        shakeY = (ImmersiveTheaterNoise.hash3(tick, 5, 2) - 0.5) * 2 * shake
        rotation = (ImmersiveTheaterNoise.hash3(tick, 7, 3) - 0.5) * 0.002 * shake
    }

    var zoom: Double { z.value * (1 + punch) }

    /// 世界 → 视口。`parallax` 小于 1 的是背景：推得少、摇得少、抖得轻。
    func matrix(world: ImmersiveTheaterWorld, scale: Double, parallax: Double) -> CGAffineTransform {
        let zoomed = parallax == 1 ? zoom : 1 + (zoom - 1) * 0.55
        let halfWidth = world.width / 2 / max(zoomed, 0.1)
        let halfHeight = world.height / 2 / max(zoomed, 0.1)
        let rect = world.backdropRect
        var centerX = Self.clamp(x.value, Double(rect.minX) + halfWidth + 10, Double(rect.maxX) - halfWidth - 10)
        var centerY = Self.clamp(y.value, Double(rect.minY) + halfHeight + 10, Double(rect.maxY) - halfHeight - 10)
        if parallax != 1 {
            centerX = world.width / 2 + (centerX - world.width / 2) * parallax
            centerY = world.height / 2 + (centerY - world.height / 2) * parallax
        }
        let shakeScale = parallax == 1 ? 1.0 : 0.6
        var matrix = CGAffineTransform(scaleX: scale, y: scale)
        matrix = ImmersiveTheaterPuppet.mul(matrix, CGAffineTransform(
            translationX: world.width / 2 + shakeX * shakeScale,
            y: world.height / 2 + shakeY * shakeScale
        ))
        matrix = ImmersiveTheaterPuppet.mul(matrix, CGAffineTransform(rotationAngle: rotation))
        matrix = ImmersiveTheaterPuppet.mul(matrix, CGAffineTransform(scaleX: zoomed, y: zoomed))
        return ImmersiveTheaterPuppet.mul(matrix, CGAffineTransform(translationX: -centerX, y: -centerY))
    }

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard low <= high else { return (low + high) / 2 }
        return min(max(value, low), high)
    }
}

/// 墨线抖动、镜头抖动用的确定性打散（照原型的 hash3）。
enum ImmersiveTheaterNoise {
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

    /// -1…1。
    static func jitter(_ frame: Int, _ seed: Int, _ index: Int) -> Double {
        hash3(frame, seed, index) * 2 - 1
    }
}

// MARK: - 宿主

@MainActor
final class ImmersiveTheaterStageModel {
    let signals = ImmersiveTheaterSignals()

    private var songKey: String?
    private var seed: UInt64 = 0
    private var members: [ImmersiveTheaterCast.Member] = []
    private var performers: [ImmersiveTheaterPerformer] = []
    private var conductor = ImmersiveTheaterConductor()
    private var director = ImmersiveTheaterShotDirector(seed: 0)
    private var tracker = ImmersiveBeatTracker()
    private var camera = ImmersiveTheaterCamera()
    private var particles: [ImmersiveTheaterParticle] = []
    private var random = ImmersiveRandom(seed: 0x7EA7_E2A5_0000_0001)
    private var origin: TimeInterval?
    private var lastTime: TimeInterval?
    private var elapsedAnchor: (elapsed: TimeInterval, time: TimeInterval)?
    private var hasAdvanced = false
    private var warmedUp = false
    private var state = ImmersiveTheaterState()
    private var shot: ImmersiveTheaterShot?
    private var shotStart = 0.0
    private var backdrop: ImmersiveTheaterBackdrop?
    private var transition: (kind: ImmersiveTheaterTransition, start: Double, old: ImmersiveTheaterBackdrop, focus: CGPoint, seed: Int)?
    private var pending: (shot: ImmersiveTheaterShot, key: String, immediate: Bool, since: Double)?
    private var requested: Set<String> = []
    private var world = ImmersiveTheaterWorld(width: 1600, height: 900, floor: 822, spread: 405)
    private var size = CGSize(width: 1600, height: 900)
    private var primary = ImmersiveTheaterRGB(hex: 0xE8875A)
    private var secondary = ImmersiveTheaterRGB(hex: 0xF2C46D)
    private var pixelWidth = 1024
    private var amplitude = 1.0
    private var flash = 0.0
    private var flashColor = ImmersiveTheaterRGB(1, 1, 1)
    private var inkKey: String?
    private var cachedInk: ImmersiveTheaterInkSheet?
    private var puppets: [ImmersiveTheaterCharacter: ImmersiveTheaterPuppet] = [:]
    private var lastActors: [ImmersiveTheaterActorFrame] = []
    private var lastLight: Bool?
    /// 歌词带的形状（`bandLayers(for:)`），按歌名缓存一份。
    var bandCache: (key: String, layers: [[CGPoint]])?

    static let particleLimit = 200

    // MARK: 配置

    /// 每帧先对一下这首歌、视口和封面色；变了才重来。
    func configure(
        songKey: String,
        world: ImmersiveTheaterWorld,
        size: CGSize,
        primary: ImmersiveTheaterRGB,
        secondary: ImmersiveTheaterRGB,
        pixelWidth: Int,
        amplitude: Double
    ) {
        self.size = size
        self.amplitude = amplitude
        if songKey != self.songKey {
            startSong(songKey)
        }
        let restyled = world != self.world || primary != self.primary || secondary != self.secondary
            || pixelWidth != self.pixelWidth
        self.world = world
        self.primary = primary
        self.secondary = secondary
        self.pixelWidth = pixelWidth
        if restyled, let shot {
            // 转屏、换封面色：当前镜头按新的视口、颜色重画一张，到了用笔刷擦过去。
            prepare(shot, immediate: true, at: lastTime ?? 0)
        }
    }

    private func startSong(_ key: String) {
        songKey = key
        seed = ImmersiveRandom.seed(for: key)
        members = ImmersiveTheaterCast.plan(seed: seed)
        performers = members.map { ImmersiveTheaterPerformer(member: $0, seed: seed) }
        conductor = ImmersiveTheaterConductor(peak: hasAdvanced ? conductor.peak : nil)
        director = ImmersiveTheaterShotDirector(seed: seed)
        tracker = ImmersiveBeatTracker()
        particles.removeAll()
        shot = nil
        pending = nil
        transition = nil
        warmedUp = false
        elapsedAnchor = nil
        inkKey = nil
        cachedInk = nil
        lastActors = []
        for member in members {
            if let cached = ImmersiveTheaterPuppetLibrary.cached(member.character) {
                puppets[member.character] = cached
            } else {
                let character = member.character
                Task { [weak self] in
                    let puppet = await ImmersiveTheaterPuppetLibrary.load(character)
                    guard let self, let puppet else { return }
                    self.puppets[character] = puppet
                    self.signals.revision &+= 1
                }
            }
        }
    }

    /// 没给播放进度时按上一次的进度加上走过的时间推。
    func playbackTime(provided: TimeInterval?, elapsed: TimeInterval, time: TimeInterval, isPlaying: Bool) -> TimeInterval {
        if let provided { return provided }
        if elapsedAnchor?.elapsed != elapsed { elapsedAnchor = (elapsed, time) }
        guard isPlaying, let anchor = elapsedAnchor else { return elapsed }
        return anchor.elapsed + max(0, time - anchor.time)
    }

    // MARK: 一帧

    func frame(
        time now: TimeInterval,
        running: Bool,
        isPlaying: Bool,
        playbackTime: TimeInterval,
        levels: [CGFloat],
        lyric: ImmersiveTheaterLyricCue?,
        hasLyrics: Bool,
        firstLyricStart: TimeInterval?,
        duration: TimeInterval,
        pokes: ImmersiveTheaterPokeChannel?,
        acceptsPokes: Bool
    ) -> ImmersiveTheaterFrame {
        let start = origin ?? now
        origin = start
        let time = now - start
        if running {
            let dt = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 1.0 / 30
            lastTime = time
            hasAdvanced = true
            step(
                time: time,
                dt: dt,
                isPlaying: isPlaying,
                playbackTime: playbackTime,
                levels: levels,
                lyric: lyric,
                hasLyrics: hasLyrics,
                firstLyricStart: firstLyricStart,
                duration: duration,
                pokes: pokes
            )
        } else {
            lastTime = nil
            if !hasAdvanced, !warmedUp {
                warmUp(time: time, playbackTime: playbackTime, lyric: lyric, hasLyrics: hasLyrics)
            }
            if shot == nil {
                cutIfNeeded(time: time, playbackTime: playbackTime, lyric: lyric, hasLyrics: hasLyrics)
            }
            // 纸偶可能是刚读进来的：停着的画面也按现在的姿势重排一遍。
            lastActors = actorFrames()
        }
        let frame = makeFrame(time: lastTime ?? time)
        publishTargets(to: pokes, accepting: running && acceptsPokes)
        return frame
    }

    private func step(
        time: Double,
        dt: Double,
        isPlaying: Bool,
        playbackTime: TimeInterval,
        levels: [CGFloat],
        lyric: ImmersiveTheaterLyricCue?,
        hasLyrics: Bool,
        firstLyricStart: TimeInterval?,
        duration: TimeInterval,
        pokes: ImmersiveTheaterPokeChannel?
    ) {
        let features: ImmersiveAudioFeatures? = levels.isEmpty || !isPlaying
            ? nil
            : tracker.update(levels: levels.map { Double($0) }, at: time)
        state = conductor.update(ImmersiveTheaterInput(
            time: time,
            playbackTime: playbackTime,
            isPlaying: isPlaying,
            features: features,
            lyric: lyric,
            hasLyrics: hasLyrics,
            firstLyricStart: firstLyricStart,
            duration: duration
        ))
        cutIfNeeded(time: time, playbackTime: playbackTime, lyric: lyric, hasLyrics: hasLyrics)
        // 背景还在画：等一会儿，三秒还没好就先用旧背景换镜头，画好了再擦过去。
        if let pending, time - pending.since > 3 {
            activate(pending.shot, backdrop: backdrop, immediate: pending.immediate, at: time)
            self.pending = nil
        }

        reactGlobally(time: time, dt: dt)
        let moonOnLeft: Bool? = backdrop.flatMap { current in
            current.layout.template == .night ? current.layout.orb.map { $0.x < world.centerX } : nil
        }
        consumePokes(pokes, time: time)
        var spawns: [(Int, ImmersiveTheaterSpawn)] = []
        for index in performers.indices {
            let made = performers[index].perform(state, time: time, dt: dt, moonOnLeft: moonOnLeft)
            for spawn in made { spawns.append((index, spawn)) }
        }
        lastActors = actorFrames()
        for (index, spawn) in spawns {
            emit(spawn, from: index, time: time)
        }
        aimCamera(time: time)
        camera.update(dt: dt, time: time)
        updateParticles(dt: dt)
        flash *= pow(0.86, dt * 30)
    }

    /// 停着的画面（设置页预览、减弱动态效果）：按「正在唱、心情不错」摆一个姿势，弹簧先走一秒半到位。
    private func warmUp(time: Double, playbackTime: TimeInterval, lyric: ImmersiveTheaterLyricCue?, hasLyrics: Bool) {
        warmedUp = true
        var pose = ImmersiveTheaterState()
        pose.groove = .mid
        pose.mood = .happy
        pose.timbre = .vocal
        pose.mouth = 0.55
        pose.roles = ImmersiveTheaterRoles(drum: true, cast: false, donkey: .metronome)
        for step in 0..<45 {
            pose.beatIndex = step / 15
            pose.beatPhase = Double(step % 15) / 15 * 0.35
            for index in performers.indices {
                _ = performers[index].perform(pose, time: time + Double(step) / 30, dt: 1.0 / 30, moonOnLeft: nil)
            }
        }
        state = pose
        cutIfNeeded(time: time, playbackTime: playbackTime, lyric: lyric, hasLyrics: hasLyrics)
        lastActors = actorFrames()
        let framing = framingTarget(time: time)
        camera.reset(x: framing.x, y: framing.y, z: framing.z)
        particles.removeAll()
    }

    // MARK: 镜头与背景

    private func cutIfNeeded(time: Double, playbackTime: TimeInterval, lyric: ImmersiveTheaterLyricCue?, hasLyrics: Bool) {
        guard let cut = director.update(
            playbackTime: playbackTime,
            lyric: lyric,
            hasLyrics: hasLyrics,
            beatIndex: state.beatIndex,
            isBeat: state.events.beat,
            isStable: state.stability > 0.3 && state.hasSpectrum
        ) else { return }
        prepare(cut.shot, immediate: cut.immediate || shot == nil, at: time)
        prefetch(after: cut.shot)
    }

    private func spec(for shot: ImmersiveTheaterShot) -> ImmersiveTheaterBackdropSpec {
        ImmersiveTheaterBackdropSpec(
            template: shot.template,
            variant: shot.variant,
            seed: seed,
            world: world,
            primary: primary,
            secondary: secondary,
            pixelWidth: pixelWidth
        )
    }

    private func prepare(_ next: ImmersiveTheaterShot, immediate: Bool, at time: Double) {
        let wanted = spec(for: next)
        if let ready = ImmersiveTheaterBackdropCache.cached(wanted) {
            pending = nil
            activate(next, backdrop: ready, immediate: immediate, at: time)
            return
        }
        pending = (next, wanted.key, immediate, time)
        request(wanted)
    }

    /// 下一个镜头先在后台画着（没有歌词时只能猜：按镜头序号往后排一个）。
    private func prefetch(after current: ImmersiveTheaterShot) {
        let next = director.planner.shot(index: current.index + 1, lyricText: nil, previous: current)
        request(spec(for: next))
    }

    private func request(_ spec: ImmersiveTheaterBackdropSpec) {
        guard ImmersiveTheaterBackdropCache.cached(spec) == nil, requested.insert(spec.key).inserted else { return }
        Task { [weak self] in
            let painted = await ImmersiveTheaterBackdropCache.paint(spec)
            guard let self else { return }
            self.requested.remove(spec.key)
            self.backdropArrived(painted)
        }
    }

    private func backdropArrived(_ painted: ImmersiveTheaterBackdrop?) {
        guard let painted else { return }
        let time = lastTime ?? 0
        if let pending, pending.key == painted.key {
            self.pending = nil
            activate(pending.shot, backdrop: painted, immediate: pending.immediate, at: time)
        } else if let shot, spec(for: shot).key == painted.key, backdrop?.key != painted.key {
            // 等不及先用了旧背景的镜头，画好了用笔刷擦过去。
            if let old = backdrop, hasAdvanced {
                transition = (ImmersiveTheaterTransition.brush, time, old, CGPoint(x: size.width / 2, y: size.height * 0.4), Int(random.unit() * 1_000_000))
            }
            backdrop = painted
            inkKey = nil
        }
        signals.revision &+= 1
    }

    private func activate(_ next: ImmersiveTheaterShot, backdrop ready: ImmersiveTheaterBackdrop?, immediate: Bool, at time: Double) {
        let first = shot == nil
        shot = next
        shotStart = time
        if let ready {
            if let old = backdrop, !first, hasAdvanced, old.key != ready.key {
                let kind: ImmersiveTheaterTransition = immediate ? .brush : next.transition
                transition = (kind, time, old, leadHeadOnScreen(), Int(random.unit() * 1_000_000))
            }
            backdrop = ready
        }
        inkKey = nil
        let framing = framingTarget(time: time)
        if first || immediate || !hasAdvanced {
            camera.reset(x: framing.x, y: framing.y, z: framing.z)
        } else {
            camera.aim(x: framing.x, y: framing.y, z: framing.z)
        }
        let light = (ready ?? backdrop)?.layout.template.isLight ?? next.template.isLight
        if light != lastLight {
            lastLight = light
            let signals = signals
            // 不在视图求值的当口改观察的值。
            Task { @MainActor in signals.isLightShot = light }
        }
    }

    /// 景别给的镜头位置：镜头里慢慢推近、左右缓缓摇；高潮推近并往主唱那边靠。
    private func framingTarget(time: Double) -> (x: Double, y: Double, z: Double) {
        let framing = shot?.framing ?? .wide
        let unit = world.width / 1600
        let age = max(0, time - shotStart)
        var zoom = framing.zoom * (1 + 0.05 * min(age / 14, 1))
        var x = world.centerX + framing.offsetX * unit + 30 * unit * sin(age * 0.12 + Double(shot?.index ?? 0))
        var y = world.height / 2 + framing.offsetY
        if state.arc == .climax {
            zoom *= 1.12
            x += (world.centerX - x) * 0.6
            y += ((world.floor - 302) - y) * 0.6
        } else if state.arc == .quiet {
            zoom *= 1.04
        }
        if framing.zoom > 1.1 { y -= 40 }
        return (x, y, zoom)
    }

    private func aimCamera(time: Double) {
        let target = framingTarget(time: time)
        camera.aim(x: target.x, y: target.y, z: target.z)
    }

    private func leadHeadOnScreen() -> CGPoint {
        guard let lead = lastActors.first(where: { $0.member.character == .yuanyin }) else {
            return CGPoint(x: size.width / 2, y: size.height * 0.4)
        }
        let head = lead.bones.indices.contains(lead.puppet.bone(named: "head"))
            ? lead.bones[lead.puppet.bone(named: "head")]
            : .identity
        return CGPoint(x: 800, y: 600).applying(head.concatenating(lead.viewTransform))
    }

    // MARK: 全场反应与粒子

    private func reactGlobally(time: Double, dt: Double) {
        guard state.playback == .playing else { return }
        let events = state.events
        let palette = currentPalette
        let unit = world.width / 1600
        if events.lowOnset {
            camera.impulse((state.bass ? 6 : 1.6) * (0.4 + events.lowStrength) * amplitude)
            camera.punch = max(camera.punch, (state.arc == .climax ? 0.025 : 0.008) * amplitude)
            if state.bass {
                for index in performers.indices {
                    let kicksDust = random.unit() < 0.6
                    if kicksDust { emit(.dust(count: 2), from: index, time: time) }
                }
            }
        }
        if state.arcEnter, state.arc == .climax { climaxBurst(palette: palette) }
        if state.arc == .climax, events.beat, state.beatIndex % 4 == 0 {
            burstConfetti(x: world.centerX + (random.unit() - 0.5) * 900 * unit, y: -40, count: 14, palette: palette, power: 0.4)
        }
        guard let layout = backdrop?.layout else { return }
        switch layout.template {
        case .flower:
            if random.unit() < dt * (2 + 6 * state.intensity) {
                add(ImmersiveTheaterParticle(
                    kind: .petal, x: random.unit() * world.width * 1.1 - 0.05 * world.width, y: -30,
                    vx: 40 + random.unit() * 60, vy: 60 + random.unit() * 60, life: 9, size: 0.8 + random.unit() * 0.8,
                    rotation: random.unit() * 2 * Double.pi, spin: (random.unit() - 0.5) * 3,
                    color: palette.flowers[Int(random.unit() * 4) % max(palette.flowers.count, 1)], seed: Int(random.unit() * 1000)
                ))
            }
        case .rain:
            if events.onset, !layout.puddles.isEmpty {
                let puddle = layout.puddles[Int(random.unit() * Double(layout.puddles.count)) % layout.puddles.count]
                add(ImmersiveTheaterParticle(
                    kind: .ripple, x: puddle.x + (random.unit() - 0.5) * puddle.rx, y: puddle.y,
                    life: 0.9, size: 1 + random.unit(), color: ImmersiveTheaterRGB(hex: 0xD6E6FF)
                ))
            }
        case .night:
            if events.highOnset, random.unit() < 0.05 {
                add(ImmersiveTheaterParticle(
                    kind: .meteor, x: random.unit() * world.width * 0.9, y: random.unit() * world.horizon * 0.3,
                    vx: 700, vy: 260, life: 0.8, color: palette.star
                ))
            }
            if state.mood == .tender, random.unit() < dt * 2 {
                add(ImmersiveTheaterParticle(
                    kind: .orb, x: random.unit() * world.width, y: world.floor - 320 + random.unit() * 300,
                    vx: (random.unit() - 0.5) * 20, vy: -10, life: 3, size: 0.35, color: palette.glow
                ))
            }
        }
    }

    private func climaxBurst(palette: ImmersiveTheaterScenePalette) {
        burstConfetti(x: world.centerX, y: world.floor - 400, count: 90, palette: palette, power: 1.1)
        let leadIndex = performers.firstIndex(where: { $0.character == .yuanyin })
        let head = actorPoint(index: leadIndex, bone: "head", CGPoint(x: 800, y: 300))
            ?? CGPoint(x: world.centerX, y: world.floor - 400)
        for index in 0..<9 {
            let angle = Double(index) / 9 * 2 * Double.pi + random.unit() * 0.4
            let speed = 220 + random.unit() * 260
            add(ImmersiveTheaterParticle(
                kind: .star, x: Double(head.x), y: Double(head.y), vx: cos(angle) * speed, vy: sin(angle) * speed,
                gravity: 120, drag: 2.2, life: 1.3 + random.unit() * 0.5, size: 0.8 + random.unit() * 0.8,
                rotation: random.unit(), spin: (random.unit() - 0.5) * 4, color: palette.accent(index), seed: index
            ))
        }
        camera.punch = 0.07 * amplitude
        switch backdrop?.layout.template {
        case .rain:
            flash = 0.7
            flashColor = ImmersiveTheaterRGB(1, 1, 1)
        case .night:
            for index in 0..<2 {
                add(ImmersiveTheaterParticle(
                    kind: .meteor, x: world.width * (0.12 + random.unit() * 0.4), y: 40 + Double(index) * 60,
                    vx: 800, vy: 300, life: 0.9, color: palette.star
                ))
            }
        default:
            break
        }
    }

    private func burstConfetti(x: Double, y: Double, count: Int, palette: ImmersiveTheaterScenePalette, power: Double) {
        for index in 0..<count {
            let angle = -Double.pi / 2 + (random.unit() - 0.5) * 2.2
            let speed = (300 + random.unit() * 520) * power
            add(ImmersiveTheaterParticle(
                kind: .confetti, x: x, y: y, vx: cos(angle) * speed, vy: sin(angle) * speed,
                gravity: 520, drag: 1.6, life: 2.2 + random.unit(), size: 0.8 + random.unit() * 0.8,
                rotation: random.unit() * 2 * Double.pi, spin: (random.unit() - 0.5) * 12,
                color: palette.accent(index), seed: Int(random.unit() * 1000)
            ))
        }
    }

    private func add(_ particle: ImmersiveTheaterParticle) {
        if particles.count >= Self.particleLimit {
            particles.removeFirst(particles.count - Self.particleLimit + 1)
        }
        particles.append(particle)
    }

    private func updateParticles(dt: Double) {
        guard !particles.isEmpty else { return }
        var kept: [ImmersiveTheaterParticle] = []
        kept.reserveCapacity(particles.count)
        for var particle in particles {
            particle.age += dt
            guard particle.age <= particle.life else { continue }
            let damping = exp(-particle.drag * dt)
            particle.vx *= damping
            particle.vy = particle.vy * damping + particle.gravity * dt
            switch particle.kind {
            case .petal, .confetti:
                particle.vx += sin(particle.age * 3 + Double(particle.seed)) * 40 * dt
            default:
                break
            }
            particle.x += particle.vx * dt
            particle.y += particle.vy * dt
            particle.rotation += particle.spin * dt
            kept.append(particle)
        }
        particles = kept
    }

    /// 某个角色身上某根骨骼上的一点（母版坐标）在世界里的位置。
    private func actorPoint(index: Int?, bone: String, _ point: CGPoint) -> CGPoint? {
        guard let index, index < performers.count else { return nil }
        let character = performers[index].character
        guard let figure = lastActors.first(where: { $0.member.character == character }) else { return nil }
        let boneIndex = figure.puppet.bone(named: bone)
        let boneTransform = figure.bones.indices.contains(boneIndex) ? figure.bones[boneIndex] : .identity
        return point.applying(boneTransform.concatenating(figure.worldTransform))
    }

    private func emit(_ spawn: ImmersiveTheaterSpawn, from index: Int, time: Double) {
        guard index < performers.count else { return }
        let palette = currentPalette
        let character = performers[index].character
        let puppet = puppets[character]
        let headTop = puppet?.anchor("headTop") ?? CGPoint(x: 800, y: 120)
        let ink = palette.ink
        switch spawn {
        case .note:
            guard let hand = actorPoint(index: index, bone: "handR", CGPoint(x: 1052, y: 1200))
                ?? actorPoint(index: index, bone: "armR", CGPoint(x: 1052, y: 1200)) else { return }
            add(ImmersiveTheaterParticle(
                kind: .note, x: Double(hand.x), y: Double(hand.y), vx: 40 + random.unit() * 40, vy: -120,
                life: 1.4, size: 1, rotation: (random.unit() - 0.5) * 0.4, color: ink, seed: Int(random.unit() * 1000)
            ))
        case .heart:
            guard let point = actorPoint(index: index, bone: "head", CGPoint(x: headTop.x + 200, y: headTop.y + 120)) else { return }
            add(ImmersiveTheaterParticle(
                kind: .heart, x: Double(point.x), y: Double(point.y), vx: (random.unit() - 0.5) * 40, vy: -90 - random.unit() * 40,
                life: 2.2, size: 0.9 + random.unit() * 0.6,
                color: random.unit() < 0.5 ? ImmersiveTheaterRGB(hex: 0xFF6F91) : ImmersiveTheaterRGB(hex: 0xFF9AB0),
                seed: Int(random.unit() * 1000)
            ))
        case let .snore(size):
            guard let point = actorPoint(index: index, bone: "head", CGPoint(x: headTop.x + 260, y: headTop.y + 160)) else { return }
            add(ImmersiveTheaterParticle(
                kind: .text("Z"), x: Double(point.x), y: Double(point.y), vx: 30, vy: -55, life: 2.4,
                size: 30 * size, rotation: -0.2, color: ink, grows: true
            ))
        case .question:
            guard let point = actorPoint(index: index, bone: "head", CGPoint(x: headTop.x + 120, y: headTop.y - 40)) else { return }
            add(ImmersiveTheaterParticle(
                kind: .text("?"), x: Double(point.x), y: Double(point.y), vy: -20, life: 1.6, size: 54, rotation: 0.15, color: ink
            ))
        case .sweat:
            for drop in 0..<3 {
                guard let point = actorPoint(index: index, bone: "head", CGPoint(x: 1150, y: 380)) else { return }
                add(ImmersiveTheaterParticle(
                    kind: .drop, x: Double(point.x), y: Double(point.y), vx: 120 + Double(drop) * 60, vy: -160 + Double(drop) * 30,
                    gravity: 700, life: 0.9, size: 1 + Double(drop) * 0.2, color: ImmersiveTheaterRGB(hex: 0x9FD8FF)
                ))
            }
        case .puff:
            let mouth = puppet?.anchor("mouthPt") ?? CGPoint(x: 800, y: 900)
            guard let point = actorPoint(index: index, bone: "head", mouth) else { return }
            for drop in 0..<3 {
                add(ImmersiveTheaterParticle(
                    kind: .dust, x: Double(point.x) + 10, y: Double(point.y), vx: 60 + Double(drop) * 30, vy: -10 + Double(drop) * 8,
                    drag: 2, life: 0.9, size: 1 + Double(drop) * 0.5
                ))
            }
        case let .dust(count):
            let member = performers[index].member
            let slot = world.position(of: member.slot)
            let shift = performers[index].pose.shadowShift * slot.scale
            for puff in 0..<count {
                let offset = Double(puff) - Double(count - 1) / 2
                add(ImmersiveTheaterParticle(
                    kind: .dust, x: slot.x + shift + offset * 50 * slot.scale / 0.27, y: slot.y - 4,
                    vx: offset * 70, vy: -30, drag: 3, life: 0.7, size: 1.2
                ))
            }
        case .tear:
            let from = puppet?.tearFrom.first ?? CGPoint(x: 640, y: 760)
            guard let point = actorPoint(index: index, bone: "head", CGPoint(x: from.x, y: from.y + 150)) else { return }
            add(ImmersiveTheaterParticle(
                kind: .drop, x: Double(point.x), y: Double(point.y), vy: 40, gravity: 600, life: 0.8, size: 0.8,
                color: ImmersiveTheaterRGB(hex: 0x7CC4F2)
            ))
        case let .potionFlash(strength):
            guard let point = actorPoint(index: index, bone: "potion", CGPoint(x: 1060, y: 1290)) else { return }
            let count = 3 + Int(4 * strength)
            for spark in 0..<count {
                let angle = random.unit() * 2 * Double.pi
                let speed = 80 + random.unit() * 200 * strength
                add(ImmersiveTheaterParticle(
                    kind: spark % 2 == 1 ? .orb : .spark, x: Double(point.x), y: Double(point.y),
                    vx: cos(angle) * speed, vy: sin(angle) * speed - 60, drag: 1.5, life: 0.9 + random.unit() * 0.5,
                    size: 0.8 + strength, color: palette.accent(spark)
                ))
            }
            flash = max(flash, 0.22 * strength)
            flashColor = palette.accent(2)
        case .greeting:
            guard let point = actorPoint(index: index, bone: "head", CGPoint(x: headTop.x, y: headTop.y - 60)) else { return }
            add(ImmersiveTheaterParticle(
                kind: .text(String(localized: "immersive_theater_greeting")), x: Double(point.x) + 40, y: Double(point.y),
                vy: -30, life: 1.4, size: 44, color: ink
            ))
        }
    }

    private func consumePokes(_ channel: ImmersiveTheaterPokeChannel?, time: Double) {
        guard let channel, !channel.pending.isEmpty else { return }
        let pokes = channel.pending
        channel.pending.removeAll()
        for character in pokes {
            guard let index = performers.firstIndex(where: { $0.character == character }) else { continue }
            let kind = performers[index].receivePoke(at: time)
            if kind == .greet {
                emit(.greeting, from: index, time: time)
            } else {
                for _ in 0..<3 { emit(.heart, from: index, time: time) }
            }
        }
    }

    private func publishTargets(to channel: ImmersiveTheaterPokeChannel?, accepting: Bool) {
        guard let channel else { return }
        channel.isAccepting = accepting
        guard accepting else {
            channel.targets = []
            return
        }
        // 前排先判：挡在前面的角色先被点到。
        channel.targets = lastActors.reversed().map { figure in
            let shapes = figure.puppet.hitParts.compactMap { item -> ImmersiveTheaterPokeChannel.Shape? in
                guard let sprite = figure.puppet.sprites[item.part], figure.bones.indices.contains(item.bone) else { return nil }
                let transform = figure.bones[item.bone].concatenating(figure.viewTransform)
                return ImmersiveTheaterPokeChannel.Shape(inverse: transform.inverted(), rect: sprite.rect)
            }
            return ImmersiveTheaterPokeChannel.Target(character: figure.member.character, shapes: shapes)
        }
    }

    // MARK: 出帧

    private var currentPalette: ImmersiveTheaterScenePalette {
        backdrop?.palette ?? ImmersiveTheaterScenePalette(
            template: shot?.template ?? .night,
            primary: primary,
            secondary: secondary
        )
    }

    private func actorFrames() -> [ImmersiveTheaterActorFrame] {
        let foreground = camera.matrix(world: world, scale: world.scale(for: size), parallax: 1)
        var frames: [ImmersiveTheaterActorFrame] = []
        for performer in performers {
            guard let puppet = puppets[performer.character] else { continue }
            let slot = world.position(of: performer.member.slot)
            var worldTransform = CGAffineTransform(translationX: slot.x, y: slot.y)
            worldTransform = ImmersiveTheaterPuppet.mul(worldTransform, CGAffineTransform(scaleX: slot.scale, y: slot.scale))
            worldTransform = ImmersiveTheaterPuppet.mul(worldTransform, CGAffineTransform(translationX: -800, y: -1460))
            frames.append(ImmersiveTheaterActorFrame(
                puppet: puppet,
                member: performer.member,
                worldTransform: worldTransform,
                viewTransform: ImmersiveTheaterPuppet.mul(foreground, worldTransform),
                bones: puppet.evaluate(performer.pose),
                pose: performer.pose,
                slot: slot
            ))
        }
        return frames
    }

    private func makeFrame(time: Double) -> ImmersiveTheaterFrame {
        let scale = world.scale(for: size)
        let foreground = camera.matrix(world: world, scale: scale, parallax: 1)
        let background = camera.matrix(world: world, scale: scale, parallax: 0.7)
        // 弹簧和骨骼都按这一帧的镜头重算一遍视口变换（镜头在 step 的最后才走）。
        let actors = lastActors.map { figure in
            ImmersiveTheaterActorFrame(
                puppet: figure.puppet,
                member: figure.member,
                worldTransform: figure.worldTransform,
                viewTransform: ImmersiveTheaterPuppet.mul(foreground, figure.worldTransform),
                bones: figure.bones,
                pose: figure.pose,
                slot: figure.slot
            )
        }
        let boil = Int((time * 12).rounded(.down))
        var transitionFrame: ImmersiveTheaterTransitionFrame?
        if let transition {
            let progress = (time - transition.start) / transition.kind.duration
            if progress >= 1 || progress < 0 {
                self.transition = nil
            } else {
                transitionFrame = ImmersiveTheaterTransitionFrame(
                    kind: transition.kind,
                    progress: progress,
                    old: transition.old,
                    focus: transition.focus,
                    seed: transition.seed
                )
            }
        }
        let palette = currentPalette
        return ImmersiveTheaterFrame(
            size: size,
            world: world,
            palette: palette,
            backdrop: backdrop,
            background: background,
            foreground: foreground,
            ink: backInk(time: time, boil: boil, palette: palette),
            transition: transitionFrame,
            actors: actors,
            particles: particles,
            flash: flash,
            flashColor: flashColor,
            time: time,
            boil: boil,
            beatPosition: state.beatPosition,
            beatPulse: state.beatPulse,
            high: state.high,
            intensity: state.intensity,
            speedLines: performers.first(where: { $0.character == .yuanyin })?.pose.props.speedLines ?? 0
        )
    }

    /// 背景上的墨线：一秒十二次换一种抖法，同一次里不重算。
    private func backInk(time: Double, boil: Int, palette: ImmersiveTheaterScenePalette) -> ImmersiveTheaterInkSheet? {
        guard let backdrop else { return nil }
        let key = "\(backdrop.key)|\(boil)"
        if key == inkKey, let cachedInk { return cachedInk }
        let sheet = ImmersiveTheaterInk.backSheet(
            layout: backdrop.layout,
            palette: palette,
            boil: boil,
            time: time,
            beatPulse: state.beatPulse,
            beatIndex: state.beatIndex,
            highOnset: state.events.highOnset
        )
        inkKey = key
        cachedInk = sheet
        return sheet
    }
}
