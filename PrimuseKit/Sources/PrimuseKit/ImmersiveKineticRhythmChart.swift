import Foundation

/// 「动态歌词」里跟着谱面走的场景：下落轨道（`ImmersiveKineticScene.noteHighway`，节奏大师那样四条轨道往下落）、
/// 光剑劈方块（`saberSlash`），和弹珠落音（`marbleDrop`，球落在哪根音条上、哪儿是一段长坡都看谱面）。音符提前
/// `leadTime` 秒放上轨道，到点时被自动打掉——像有人在玩，每一下都打中。
///
/// 音符从两处来：节拍钟预报的拍子（听得出稳定的鼓点时，副歌里再加反拍），和歌词每个字开唱的时刻（逐字歌词用自己的
/// 时间，逐行歌词按字数摊开）。音游里的长音也一样：唱得长的字是一段长音，鼓点稀、声音拖得长的段落里小节头是长音。
/// 一个音符放上去以后时刻和长短都不再改：拍子后来又校准了，轨道上的音符也不会跳。长音占着它那只手（左两条轨道
/// 归左手、右两条归右手）直到放开，这期间这只手不再来别的音符。
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

    /// 歌词里一个字：开唱的时刻和唱多久（不知道唱多久时为 0）。
    public struct Cue: Equatable, Sendable {
        public var start: TimeInterval
        public var duration: TimeInterval

        public init(start: TimeInterval, duration: TimeInterval = 0) {
            self.start = start
            self.duration = duration
        }
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
        /// 长音拖多久；0 是一下就打掉的。
        public var duration: TimeInterval = 0

        public var isHold: Bool { duration > 0 }
        /// 打完（长音放开）的时刻。
        public var end: TimeInterval { time + duration }
    }

    public static let laneCount = 4
    public static let rowCount = 3
    /// 音符提前多久放上轨道（也就是从远处走到判定线要多久）。
    public static let leadTime: TimeInterval = 1.5
    /// 打掉以后还留多久：爆开、碎块飞散。
    public static let afterglow: TimeInterval = 0.7
    /// 两个音符至少隔多久（同一时刻的双押除外）：再密就成了一串分不清的点。
    public static let minimumSpacing: TimeInterval = 0.15
    /// 唱多久以上的字算长音。
    public static let holdThreshold: TimeInterval = 0.55
    /// 长音最长拖多久。
    static let maximumHold: TimeInterval = 3
    /// 长音放开到这只手的下一个音符之间至少留多久。
    static let holdRelease: TimeInterval = 0.15
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

    /// 走一帧：放进 `leadTime` 以内新冒出来的拍子与字头，收掉打完很久的。`cues` 是台上几句歌词的字，`climax` 是
    /// 进副歌的程度（0…1），`sparse` 是这一阵鼓点稀、声音拖得长（这时小节头是长音），`time` 是播放时间。
    public mutating func update(
        clock: ImmersiveBeatClock,
        cues: [Cue],
        climax: Double,
        sparse: Bool = false,
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
        notes.removeAll { $0.end < time - Self.afterglow }

        let earliest = time + Self.latestPlacement
        let horizon = time + Self.leadTime
        var candidates: [Candidate] = cues
            .filter { $0.start.isFinite && $0.start >= earliest && $0.start <= horizon }
            .map { cue in
                Candidate(
                    time: cue.start,
                    strength: 0.6,
                    source: .lyric,
                    chord: false,
                    duration: cue.duration >= Self.holdThreshold ? min(cue.duration, Self.maximumHold) : 0
                )
            }
        let busy = climax > 0.5
        for beat in clock.beats(from: earliest - clock.period / 2, through: horizon) {
            let index = Int((clock.position(at: beat) ?? 0).rounded())
            let downbeat = ((index % 4) + 4) % 4 == 0
            if beat >= earliest {
                candidates.append(Candidate(
                    time: beat,
                    strength: downbeat ? 1 : 0.8,
                    source: .beat,
                    chord: downbeat && busy,
                    duration: downbeat && sparse ? min(clock.period * 2, Self.maximumHold) : 0
                ))
            }
            // 副歌里反拍也上一个，更密。
            let offbeat = beat + clock.period / 2
            if busy, offbeat >= earliest, offbeat <= horizon {
                candidates.append(Candidate(time: offbeat, strength: 0.5, source: .beat, chord: false, duration: 0))
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
        var duration: TimeInterval
    }

    private mutating func place(_ candidate: Candidate, at now: TimeInterval) {
        let previous = notes.last { $0.time < candidate.time }
        let gap = previous.map { candidate.time - $0.end } ?? 1
        let preferred = nextLane(after: previous?.lane ?? lastLane, gap: gap)
        guard let slot = freeLane(preferred: preferred, time: candidate.time, duration: candidate.duration) else { return }
        let (lane, duration) = slot
        lastLane = lane
        // 长音放在最下面一行：光轨从剑那儿一路延到远处，看得出有多长（放在视线那么高时几乎是一个点）。
        let row = duration > 0 ? 0 : nextRow(source: candidate.source)
        insert(note(time: candidate.time, lane: lane, row: row, duration: duration, candidate: candidate, at: now))
        // 双押：另一只手在另一边同时来一下。
        if candidate.chord {
            let side = lane < Self.laneCount / 2 ? Self.laneCount / 2 : 0
            let other = side + min(Int(random.unit() * Double(Self.laneCount / 2)), Self.laneCount / 2 - 1)
            if handIsFree(Self.hand(of: other), from: candidate.time, to: candidate.time) {
                insert(note(time: candidate.time, lane: other, row: row, duration: 0, candidate: candidate, at: now))
            }
        }
    }

    /// 先试 `preferred`，再按离它由近到远试别的轨道：这只手要空着，同一条轨道上紧挨着的不连打。长音放不下时
    /// 缩短到这只手的下一个音符前面，短到不够长音就当一下打掉的；哪条都放不下返回 nil。
    private func freeLane(preferred: Int, time: TimeInterval, duration: TimeInterval) -> (Int, TimeInterval)? {
        let order = (0..<Self.laneCount).sorted { abs($0 - preferred) < abs($1 - preferred) }
        for lane in order {
            let hand = Self.hand(of: lane)
            guard handIsFree(hand, from: time, to: time),
                  !notes.contains(where: { $0.lane == lane && abs($0.time - time) < 0.3 }) else { continue }
            guard duration > 0 else { return (lane, 0) }
            // 这只手后面已经排着的音符：长音得在它前面放开。
            let nextOnHand = notes.filter { $0.hand == hand && $0.time > time }.map(\.time).min()
            let room = nextOnHand.map { $0 - time - Self.holdRelease } ?? duration
            let length = min(duration, room)
            return (lane, length >= Self.holdThreshold ? length : 0)
        }
        return nil
    }

    /// 这只手在 `start`…`end` 之间没有按着长音、也没有挨得太近的音符。
    private func handIsFree(_ hand: Int, from start: TimeInterval, to end: TimeInterval) -> Bool {
        !notes.contains { note in
            note.hand == hand
                && note.time - Self.minimumSpacing < end
                && note.end + (note.isHold ? Self.holdRelease : Self.minimumSpacing) > start
                && (note.isHold || abs(note.time - start) < Self.minimumSpacing)
        }
    }

    static func hand(of lane: Int) -> Int { lane < laneCount / 2 ? 0 : 1 }

    private mutating func note(
        time: TimeInterval,
        lane: Int,
        row: Int,
        duration: TimeInterval,
        candidate: Candidate,
        at now: TimeInterval
    ) -> Note {
        let hand = Self.hand(of: lane)
        let previousCut = notes.last { $0.time < time && $0.hand == hand }?.cut
        return Note(
            time: time,
            lane: lane,
            row: row,
            hand: hand,
            cut: nextCut(after: previousCut, hand: hand),
            strength: candidate.strength,
            source: candidate.source,
            placed: now,
            duration: duration
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
    /// 按着长音时剑尖在光轨上绕的小圈有多大、一秒绕几圈。
    static let holdCircle = 0.035
    static let holdCircleRate = 1.6

    /// 第 `hand` 只手的光剑此刻指着哪儿（打的那个平面上，x 向右、y 向上）：每一刀在该打的时刻劈过方块中心，
    /// 沿着方块上的箭头方向；长音时剑尖迎上去抵住光轨，一路贴着它画小圈，放开时顺着箭头一甩。两刀之间从上一刀
    /// 收住的地方顺到下一刀起手的地方。不挥的时候手微微晃着，像人握着剑在等；离挥剑越近晃得越少，挥的那一下不晃。
    public func aim(hand: Int, at time: TimeInterval) -> (x: Double, y: Double) {
        let mine = notes.filter { $0.hand == hand }
        let base = swingAim(mine, hand: hand, at: time)
        var calm = Double.infinity
        for note in mine {
            let distance = time < note.time ? note.time - time : max(time - note.end, 0)
            calm = min(calm, max(distance - Self.swingHalf, 0))
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
        // 一刀起手、收手各用多久：相邻两刀离得近时缩短，不会挥到一半就去挥下一刀。
        func half(_ index: Int) -> TimeInterval {
            var value = Self.swingHalf
            if index > 0 { value = min(value, (mine[index].time - mine[index - 1].end) / 2) }
            if index + 1 < mine.count { value = min(value, (mine[index + 1].time - mine[index].end) / 2) }
            return max(value, 0.02)
        }
        func start(_ index: Int) -> (x: Double, y: Double) {
            swingPoint(mine[index], fraction: mine[index].isHold ? -0.6 : -1)
        }
        func end(_ index: Int) -> (x: Double, y: Double) {
            swingPoint(mine[index], fraction: 1)
        }
        guard let next = mine.indices.first(where: { mine[$0].end + half($0) > time }) else {
            // 最后一刀挥完了：慢慢垂回去。
            let last = mine.count - 1
            let since = time - (mine[last].end + half(last))
            return blend(end(last), rest, Self.smoothstep(since / Self.restDelay))
        }
        let note = mine[next]
        let window = half(next)
        let swingStart = note.time - window
        if time >= swingStart {
            guard note.isHold else {
                // 正在挥这一刀：缓入缓出，劈过方块中心的那一刻最快。
                let progress = (time - swingStart) / (2 * window)
                return swingPoint(note, fraction: 2 * Self.easeInOutCubic(progress) - 1)
            }
            let center = swingPoint(note, fraction: 0)
            if time < note.time {
                // 迎上去抵住光轨的头。
                return blend(start(next), center, Self.easeOutCubic((time - swingStart) / window))
            }
            if time < note.end {
                // 按着：剑尖贴着光轨画小圈，起止都从圆心慢慢张开、收拢，不会跳。
                let held = time - note.time
                let opening = Self.smoothstep(held / 0.2) * Self.smoothstep((note.end - time) / 0.2)
                let angle = held * Self.holdCircleRate * 2 * .pi
                return (
                    center.x + Self.holdCircle * opening * sin(angle),
                    center.y + Self.holdCircle * opening * (1 - cos(angle)) * 0.5
                )
            }
            // 放开：顺着箭头甩出去。
            return blend(center, end(next), Self.easeInCubic((time - note.end) / window))
        }
        // 两刀之间：从上一刀收住的地方（或垂手的姿势）顺到这一刀起手的地方。
        let from: (x: Double, y: Double)
        let fromTime: TimeInterval
        if next > 0 {
            from = end(next - 1)
            fromTime = mine[next - 1].end + half(next - 1)
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
        let visible = notes.suffix((Self.propsCapacity - Self.notesOffset) / Self.noteStride)
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
            // 这只手此刻是不是按着长音：剑和光轨相接的地方一直冒火星。
            props[10][hand + 2] = notes.contains { $0.hand == hand && $0.isHold && time >= $0.time && time < $0.end } ? 1 : 0
        }
        for (offset, note) in visible.enumerated() {
            let cube = Self.cubePosition(lane: note.lane, row: note.row)
            let base = Self.notesOffset + offset * Self.noteStride
            props[base] = SIMD4(Float(cube.x), Float(cube.y), Float(note.time - time), Float(note.strength))
            // 轨道号的小数部分是这个音符自己的随机数（火星往哪儿溅）：按该打的时刻算，每帧都一样。着色器里不能拿
            // 「放上去多久」加「还有多久」现凑——两个数各自转成 float，和每帧差一点点，算出来的火星会一帧一跳。
            let salt = (note.time * 7.31).truncatingRemainder(dividingBy: 1)
            props[base + 1] = SIMD4(
                Float(Double(note.lane) + 0.5 * abs(salt)),
                Float(note.hand + 2 * note.source.rawValue),
                Float(note.cut.rawValue),
                Float(time - note.placed)
            )
            props[base + 2] = SIMD4(Float(note.duration), 0, 0, 0)
        }
        return props
    }

    public static let propsCapacity = 128
    static let notesOffset = 16
    /// 每个音符占几个 float4。
    static let noteStride = 3
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

    static func easeOutCubic(_ value: Double) -> Double {
        let inverse = 1 - min(max(value, 0), 1)
        return 1 - inverse * inverse * inverse
    }

    static func easeInCubic(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * x
    }
}
