import Foundation

/// 「动态歌词」里两个音游场景的谱面：下落轨道（`ImmersiveKineticScene.noteHighway`，节奏大师那样四条轨道往下落）
/// 和光剑劈方块（`saberSlash`）。音符提前 `leadTime` 秒放上轨道，到点时被自动打掉——像有人在玩，每一下都打中。
///
/// 音符从两处来：节拍钟预报的拍子（听得出稳定的鼓点时，副歌里再加反拍），和歌词每个字开唱的时刻（逐字歌词用自己的
/// 时间，逐行歌词按字数摊开）。一个音符放上去以后时刻不再改：拍子后来又校准了，轨道上的音符也不会跳。
public struct ImmersiveKineticRhythmChart: Sendable {
    public enum Source: Int, Sendable {
        /// 预报的拍子。
        case beat
        /// 歌词的字头。
        case lyric
    }

    /// 光剑从哪个方向劈（画面上，y 向下）。
    public enum Cut: Int, CaseIterable, Sendable {
        case down
        case up
        case left
        case right
        case downLeft
        case downRight
        case upLeft
        case upRight

        /// 劈的方向，单位向量，y 向下。
        public var vector: (x: Double, y: Double) {
            let diagonal = 0.5.squareRoot()
            switch self {
            case .down: return (0, 1)
            case .up: return (0, -1)
            case .left: return (-1, 0)
            case .right: return (1, 0)
            case .downLeft: return (-diagonal, diagonal)
            case .downRight: return (diagonal, diagonal)
            case .upLeft: return (-diagonal, -diagonal)
            case .upRight: return (diagonal, -diagonal)
            }
        }

        /// 往下劈（含斜下）：同一只手下一刀往上，挥起来才顺。
        var isDownward: Bool { vector.y > 0.1 }
    }

    public struct Note: Equatable, Sendable {
        /// 该打的时刻（播放时间）。
        public var time: TimeInterval
        /// 第几条轨道 / 第几列，0 在最左。
        public var lane: Int
        /// 光剑：第几行，0 最低。
        public var row: Int
        /// 光剑：0 左手（专辑主色），1 右手（辅色）。
        public var hand: Int
        public var cut: Cut
        public var strength: Double
        public var source: Source
        /// 放上轨道的时刻：晚知道的音符从半路淡入。
        public var placed: TimeInterval
    }

    public static let laneCount = 4
    public static let rowCount = 3
    /// 音符提前多久放上轨道（也就是从远处走到判定线要多久）。
    public static let leadTime: TimeInterval = 1.5
    /// 打掉以后还留多久：爆开、碎块飞散。
    public static let afterglow: TimeInterval = 0.7
    /// 两个音符至少隔多久（同一时刻的双押除外）：再密就成了一串分不清的点。
    public static let minimumSpacing: TimeInterval = 0.15
    /// 离该打的时刻不到这么久才知道的音符不放：一冒出来就被打掉，像凭空闪一下。
    static let latestPlacement: TimeInterval = 0.35
    static let capacity = 44

    public private(set) var notes: [Note] = []
    /// 这一轮（从开始或上次拖进度起）打掉了多少个：连击越多轨道越亮。
    public private(set) var hitCount = 0
    private var random: ImmersiveRandom
    private var lastTime: TimeInterval?
    private var lastLane = 1

    public init(seed: UInt64) {
        random = ImmersiveRandom(seed: seed ^ 0x5EED_C0DE_0000_0001)
    }

    /// 走一帧：放进 `leadTime` 以内新冒出来的拍子与字头，收掉打完很久的。`cues` 是台上几句歌词每个字开唱的时刻，
    /// `climax` 是进副歌的程度（0…1），`time` 是播放时间。
    public mutating func update(
        clock: ImmersiveBeatClock,
        cues: [TimeInterval],
        climax: Double,
        at time: TimeInterval
    ) {
        guard time.isFinite else { return }
        if let lastTime, time < lastTime - 0.05 || time - lastTime > 1.5 {
            notes.removeAll()
            hitCount = 0
        } else if let lastTime {
            hitCount += notes.filter { $0.time > lastTime && $0.time <= time }.count
        }
        lastTime = time
        notes.removeAll { $0.time < time - Self.afterglow }

        let earliest = time + Self.latestPlacement
        let horizon = time + Self.leadTime
        var candidates: [Candidate] = cues
            .filter { $0.isFinite && $0 >= earliest && $0 <= horizon }
            .map { Candidate(time: $0, strength: 0.6, source: .lyric, chord: false) }
        let busy = climax > 0.5
        for beat in clock.beats(from: earliest - clock.period / 2, through: horizon) {
            let index = Int((clock.position(at: beat) ?? 0).rounded())
            let downbeat = ((index % 4) + 4) % 4 == 0
            if beat >= earliest {
                candidates.append(Candidate(time: beat, strength: downbeat ? 1 : 0.8, source: .beat, chord: downbeat && busy))
            }
            // 副歌里反拍也上一个，更密。
            let offbeat = beat + clock.period / 2
            if busy, offbeat >= earliest, offbeat <= horizon {
                candidates.append(Candidate(time: offbeat, strength: 0.5, source: .beat, chord: false))
            }
        }
        // 拍子先占位，字头补在拍子之间：两个离得太近时留拍子上的那个，轨道上的节奏更整齐。
        candidates.sort { ($0.source == .beat ? 0 : 1, $0.time) < ($1.source == .beat ? 0 : 1, $1.time) }
        for candidate in candidates
        where !notes.contains(where: { abs($0.time - candidate.time) < Self.minimumSpacing }) {
            place(candidate, at: time)
        }
        if notes.count > Self.capacity {
            notes.removeFirst(notes.count - Self.capacity)
        }
    }

    private struct Candidate {
        var time: TimeInterval
        var strength: Double
        var source: Source
        var chord: Bool
    }

    private mutating func place(_ candidate: Candidate, at now: TimeInterval) {
        let previous = notes.last { $0.time < candidate.time }
        let gap = previous.map { candidate.time - $0.time } ?? 1
        let lane = nextLane(after: previous?.lane ?? lastLane, gap: gap)
        lastLane = lane
        let row = nextRow(source: candidate.source)
        insert(note(time: candidate.time, lane: lane, row: row, candidate: candidate, at: now))
        // 双押：另一只手在另一边同时来一下。
        if candidate.chord {
            let side = lane < Self.laneCount / 2 ? Self.laneCount / 2 : 0
            let other = side + min(Int(random.unit() * Double(Self.laneCount / 2)), Self.laneCount / 2 - 1)
            insert(note(time: candidate.time, lane: other, row: row, candidate: candidate, at: now))
        }
    }

    private mutating func note(time: TimeInterval, lane: Int, row: Int, candidate: Candidate, at now: TimeInterval) -> Note {
        let hand = lane < Self.laneCount / 2 ? 0 : 1
        let previousCut = notes.last { $0.time < time && $0.hand == hand }?.cut
        return Note(
            time: time,
            lane: lane,
            row: row,
            hand: hand,
            cut: nextCut(after: previousCut, hand: hand),
            strength: candidate.strength,
            source: candidate.source,
            placed: now
        )
    }

    private mutating func insert(_ note: Note) {
        let index = notes.firstIndex { $0.time > note.time } ?? notes.endIndex
        notes.insert(note, at: index)
    }

    /// 下一个音符落在哪条轨道：快的连打左右挪一两格，慢的可以跳远；不连着落在同一条上。
    private mutating func nextLane(after previous: Int, gap: TimeInterval) -> Int {
        let steps = gap < 0.3 ? [-1, 1, -1, 1, -2, 2] : [-2, -1, 1, 2, -3, 3, -1, 1]
        var lane = previous + steps[min(Int(random.unit() * Double(steps.count)), steps.count - 1)]
        let last = Self.laneCount - 1
        if lane < 0 { lane = -lane }
        if lane > last { lane = 2 * last - lane }
        lane = min(max(lane, 0), last)
        return lane == previous ? (previous == 0 ? 1 : previous - 1) : lane
    }

    /// 拍子多在最下面一行，歌词的字在中间、偶尔最上面。
    private mutating func nextRow(source: Source) -> Int {
        let roll = random.unit()
        switch source {
        case .beat: return roll < 0.7 ? 0 : 1
        case .lyric: return roll < 0.7 ? 1 : 2
        }
    }

    /// 同一只手一刀往下、一刀往上来回挥；三成斜着劈，斜向朝这只手的外侧。
    private mutating func nextCut(after previous: Cut?, hand: Int) -> Cut {
        let downward = !(previous?.isDownward ?? false)
        let diagonal = random.unit() < 0.3
        switch (downward, diagonal, hand) {
        case (true, false, _): return .down
        case (false, false, _): return .up
        case (true, true, 0): return .downLeft
        case (true, true, _): return .downRight
        case (false, true, 0): return .upLeft
        case (false, true, _): return .upRight
        }
    }

    // MARK: - 光剑

    /// 方块的位置（打的那一刻所在的平面上，x 向右、y 向上，视线高度为 0）：四列三行都在视线以下，劈的地方落在
    /// 画面下半截，不压着正中的歌词。着色器里的握把位置（`saberHilt`）按这套尺度写。
    public static func cubePosition(lane: Int, row: Int) -> (x: Double, y: Double) {
        ((Double(lane) - Double(laneCount - 1) / 2) * 0.3, -0.5 + Double(row) * 0.22)
    }

    /// 光剑不挥时停在哪儿：两手垂在下方两侧。
    public static func restingAim(hand: Int) -> (x: Double, y: Double) {
        (hand == 0 ? -0.36 : 0.36, -0.82)
    }

    /// 一刀从方块前多远挥起、挥过方块后多远收住。
    static let swingReach = 0.3
    /// 一刀挥多久的一半：正好在该打的时刻劈过方块中心，那一下最快。
    static let swingHalf: TimeInterval = 0.11
    /// 没有要劈的方块时，多久回到垂手的姿势。
    static let restDelay: TimeInterval = 0.45

    /// 第 `hand` 只手的光剑此刻指着哪儿（打的那个平面上，x 向右、y 向上）：每一刀在该打的时刻劈过方块中心，
    /// 沿着方块上的箭头方向；两刀之间从上一刀收住的地方顺到下一刀起手的地方。不挥的时候手微微晃着，像人握着剑
    /// 在等；离挥剑越近晃得越少，挥的那一下不晃。
    public func aim(hand: Int, at time: TimeInterval) -> (x: Double, y: Double) {
        let mine = notes.filter { $0.hand == hand }
        let base = swingAim(mine, hand: hand, at: time)
        var calm = Double.infinity
        for note in mine {
            calm = min(calm, max(abs(time - note.time) - Self.swingHalf, 0))
        }
        let sway = Self.smoothstep(calm / Self.restDelay)
        let phase = Double(hand) * 1.7
        return (
            base.x + Self.idleSway * sway * sin(time * 2.3 + phase),
            base.y + Self.idleSway * 0.8 * sway * sin(time * 1.9 + phase * 0.6)
        )
    }

    /// 不挥剑时手晃的幅度。
    static let idleSway = 0.025

    private func swingAim(_ mine: [Note], hand: Int, at time: TimeInterval) -> (x: Double, y: Double) {
        let rest = Self.restingAim(hand: hand)
        guard !mine.isEmpty else { return rest }
        // 一刀的时间窗：相邻两刀离得近时缩短，不会挥到一半就去挥下一刀。
        func half(_ index: Int) -> TimeInterval {
            var value = Self.swingHalf
            if index > 0 { value = min(value, (mine[index].time - mine[index - 1].time) / 2) }
            if index + 1 < mine.count { value = min(value, (mine[index + 1].time - mine[index].time) / 2) }
            return max(value, 0.02)
        }
        func start(_ index: Int) -> (x: Double, y: Double) {
            swingPoint(mine[index], fraction: -1)
        }
        func end(_ index: Int) -> (x: Double, y: Double) {
            swingPoint(mine[index], fraction: 1)
        }
        guard let next = mine.indices.first(where: { mine[$0].time + half($0) > time }) else {
            // 最后一刀挥完了：慢慢垂回去。
            let last = mine.count - 1
            let since = time - (mine[last].time + half(last))
            return blend(end(last), rest, Self.smoothstep(since / Self.restDelay))
        }
        let window = half(next)
        let swingStart = mine[next].time - window
        if time >= swingStart {
            // 正在挥这一刀：缓入缓出，劈过方块中心的那一刻最快。
            let progress = (time - swingStart) / (2 * window)
            return swingPoint(mine[next], fraction: 2 * Self.easeInOutCubic(progress) - 1)
        }
        // 两刀之间：从上一刀收住的地方（或垂手的姿势）顺到这一刀起手的地方。
        let from: (x: Double, y: Double)
        let fromTime: TimeInterval
        if next > 0 {
            from = end(next - 1)
            fromTime = mine[next - 1].time + half(next - 1)
        } else {
            from = rest
            fromTime = swingStart - Self.restDelay
        }
        let travel = max(swingStart - fromTime, 0.001)
        let settled = Self.smoothstep((time - fromTime) / travel)
        // 隔得久时先垂下来歇一会儿，快到了再抬起来。
        if next > 0, travel > 2 * Self.restDelay {
            let down = Self.smoothstep((time - fromTime) / Self.restDelay)
            let up = Self.smoothstep((time - (swingStart - Self.restDelay)) / Self.restDelay)
            return blend(blend(from, rest, down), start(next), up)
        }
        return blend(from, start(next), settled)
    }

    /// 一刀上的一点：`fraction` -1 是起手，0 是方块中心，1 是收住。
    private func swingPoint(_ note: Note, fraction: Double) -> (x: Double, y: Double) {
        let center = Self.cubePosition(lane: note.lane, row: note.row)
        let direction = note.cut.vector
        // 画面上 y 向下，这里 y 向上。
        return (
            center.x + direction.x * Self.swingReach * fraction,
            center.y - direction.y * Self.swingReach * fraction
        )
    }

    private func blend(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double), _ t: Double) -> (x: Double, y: Double) {
        (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }

    // MARK: - 交给着色器

    /// 交给着色器的数据，float4 一组，格式见 `ImmersiveKineticShaderSource` 里音游那两个场景的说明。
    /// `time` 是播放时间，`clock` 给出轨道上的拍线，`climax` 是进副歌的程度。
    public func packed(clock: ImmersiveBeatClock, climax: Double, at time: TimeInterval) -> [SIMD4<Float>] {
        var props = [SIMD4<Float>](repeating: .zero, count: Self.propsCapacity)
        let position = clock.position(at: time)
        let measure = position.map { value in value - 4 * (value / 4).rounded(.down) } ?? -1
        let visible = notes.suffix((Self.propsCapacity - Self.notesOffset) / 2)
        props[0] = SIMD4(Float(measure), Float(clock.period), Float(clock.confidence), Float(visible.count))
        props[1] = SIMD4(Float(Self.leadTime), Float(climax), Float(hitCount), 0)
        for hand in 0..<2 {
            var speed = 0.0
            var points: [(x: Double, y: Double)] = []
            for step in 0..<Self.trailSamples {
                points.append(aim(hand: hand, at: time - Double(step) * Self.trailStep))
            }
            if points.count > 1 {
                speed = hypot(points[0].x - points[1].x, points[0].y - points[1].y) / Self.trailStep
            }
            for pair in 0..<(Self.trailSamples / 2) {
                let a = points[pair * 2]
                let b = points[pair * 2 + 1]
                props[2 + hand * (Self.trailSamples / 2) + pair] = SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y))
            }
            props[10][hand] = Float(speed)
        }
        for (offset, note) in visible.enumerated() {
            let cube = Self.cubePosition(lane: note.lane, row: note.row)
            props[Self.notesOffset + offset * 2] = SIMD4(
                Float(cube.x),
                Float(cube.y),
                Float(note.time - time),
                Float(note.strength)
            )
            // 轨道号的小数部分是这个音符自己的随机数（火星往哪儿溅）：按该打的时刻算，每帧都一样。着色器里不能拿
            // 「放上去多久」加「还有多久」现凑——两个数各自转成 float，和每帧差一点点，算出来的火星会一帧一跳。
            let salt = (note.time * 7.31).truncatingRemainder(dividingBy: 1)
            props[Self.notesOffset + offset * 2 + 1] = SIMD4(
                Float(Double(note.lane) + 0.5 * abs(salt)),
                Float(note.hand + 2 * note.source.rawValue),
                Float(note.cut.rawValue),
                Float(time - note.placed)
            )
        }
        return props
    }

    public static let propsCapacity = 128
    static let notesOffset = 16
    static let trailSamples = 8
    /// 光剑拖尾相邻两个采样隔多久。
    static let trailStep: TimeInterval = 0.014

    // MARK: - 曲线

    static func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func easeInOutCubic(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}
