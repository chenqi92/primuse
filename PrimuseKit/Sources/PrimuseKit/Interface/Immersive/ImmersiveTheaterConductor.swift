import Foundation

// 「水彩小剧场」的判定层：把每一帧的音频摘要（`ImmersiveAudioFeatures`）、歌词和播放状态读成六层状态——
// 速度律动、能量走向、音色段落、情绪、歌词意象、播放情境——再加上角色分工。表演层
// （`ImmersiveTheaterPerformer`）按这些状态给角色定姿势，导演层（`ImmersiveTheaterShotDirector`）按歌词与拍子换镜头。
//
// 阈值照网页原型（CFG）。原型自己做了整曲预扫和人声频段分析，App 里只拿得到舞台已有的频谱摘要，缺的量这样近似：
// - 能量的分贝：频谱条是把 -72…-8 dB 压到 0…1 再取 0.72 次方，这里反算回去（`decibels(fromLevel:)`）。
// - 本曲的响度分位：用摘要里按最近 40 秒排的 `intensity`；「最响过多少」用一路缓慢回落的峰值代替整曲 95 分位。
// - 人声度：中段（军鼓、人声）的电平加中段起音的密度；有歌词时按歌词时间轴加权，和原型一样。
// - 拍速：`beatsPerSecond` 折在 78…156 拍之间，按低中段起音的实际密度判断真实拍速是它的一半还是两倍。

// MARK: - 状态

/// 速度律动：决定身体的基本动作。
public enum ImmersiveTheaterGroove: String, CaseIterable, Sendable {
    /// 慢歌：闭眼两拍一摆。
    case slow
    /// 中速：每拍点头、脚尖点地。
    case mid
    /// 快歌：每拍起跳、甩头。
    case fast
    /// 节奏不稳：跟着起音扭。
    case unsteady
    /// 几乎没有拍子：离地漂浮。
    case float
}

/// 能量走向：盖过律动的大动作。
public enum ImmersiveTheaterArc: String, CaseIterable, Sendable {
    case normal
    /// 安静的前奏（和曲终渐弱）：打盹。
    case intro
    /// 渐强：蹲下蓄力。
    case build
    /// 高潮：起跳、撒彩纸。
    case climax
    /// 突然安静：定格张望。
    case quiet
    /// 高潮刚过：擦汗。
    case cooldown
}

/// 音色段落。
public enum ImmersiveTheaterTimbre: String, Sendable {
    /// 有人在唱：猿音跟唱。
    case vocal
    /// 器乐段：空气吉他、小黑打鼓。
    case instrumental
    case none
}

public enum ImmersiveTheaterMood: String, CaseIterable, Sendable {
    case neutral
    case happy
    case sad
    case tender
}

/// 当前这句歌词里的意象。
public enum ImmersiveTheaterImagery: String, CaseIterable, Sendable {
    case rain
    case tears
    case love
    case moon
}

/// 播放情境：暂停时角色停下来看镜头，久了打呼。
public enum ImmersiveTheaterPlayback: String, Sendable {
    case playing
    case look
    case snore
}

/// 小火驴这一刻做什么。
public enum ImmersiveTheaterDonkeyRole: String, Sendable {
    /// 躺着叼胡萝卜（慢歌、伤感）。
    case lie
    /// 拉磨转圈（快歌、高潮）。
    case mill
    /// 当节拍器（其余）。
    case metronome
}

public struct ImmersiveTheaterRoles: Equatable, Sendable {
    /// 小黑打鼓。
    public var drum = false
    /// 阿酒挥药瓶放光。
    public var cast = false
    public var donkey = ImmersiveTheaterDonkeyRole.metronome

    public init(drum: Bool = false, cast: Bool = false, donkey: ImmersiveTheaterDonkeyRole = .metronome) {
        self.drum = drum
        self.cast = cast
        self.donkey = donkey
    }
}

/// 这一帧发生的事：拍子、起音（全频、低频、高频）。
public struct ImmersiveTheaterEvents: Equatable, Sendable {
    public var beat = false
    public var onset = false
    public var lowOnset = false
    public var highOnset = false
    public var lowStrength = 0.0

    public init() {}
}

/// 一句歌词：舞台给的当前句。`id` 在同一首歌里稳定，换句时变。
public struct ImmersiveTheaterLyricCue: Equatable, Sendable {
    public var id: Int
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval?

    public init(id: Int, text: String, start: TimeInterval, end: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }

    /// 这句此刻还在唱：没给结束时间时按开头后 8 秒算。
    public func isActive(at time: TimeInterval) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, time >= start - 0.05 else { return false }
        return time < (end ?? start + 8)
    }
}

/// 判定层每帧的输入。
public struct ImmersiveTheaterInput: Sendable {
    /// 动画时钟（暂停时照走），表情、闲置动作用它。
    public var time: TimeInterval
    /// 播放进度。拍子、歌词、换镜头用它。
    public var playbackTime: TimeInterval
    public var isPlaying: Bool
    /// 这一帧的频谱摘要；读不到频谱（Apple Music、电台）时为 nil。
    public var features: ImmersiveAudioFeatures?
    public var lyric: ImmersiveTheaterLyricCue?
    /// 这首歌有逐行歌词。
    public var hasLyrics: Bool
    /// 第一句歌词从哪开始：前奏在这之前结束。
    public var firstLyricStart: TimeInterval?
    /// 整首多长，0 是不知道。
    public var duration: TimeInterval

    public init(
        time: TimeInterval,
        playbackTime: TimeInterval,
        isPlaying: Bool,
        features: ImmersiveAudioFeatures?,
        lyric: ImmersiveTheaterLyricCue? = nil,
        hasLyrics: Bool = false,
        firstLyricStart: TimeInterval? = nil,
        duration: TimeInterval = 0
    ) {
        self.time = time
        self.playbackTime = playbackTime
        self.isPlaying = isPlaying
        self.features = features
        self.lyric = lyric
        self.hasLyrics = hasLyrics
        self.firstLyricStart = firstLyricStart
        self.duration = duration
    }
}

/// 判定层每帧的输出。表演层只读它。
public struct ImmersiveTheaterState: Equatable, Sendable {
    public var groove = ImmersiveTheaterGroove.mid
    public var arc = ImmersiveTheaterArc.normal
    /// 进入当前能量走向多久了（播放进度秒）。
    public var arcTime = 0.0
    /// 这一帧刚进入当前能量走向。
    public var arcEnter = false
    /// 蓄力进度 0…1（6 秒蓄满）。
    public var buildProgress = 0.0
    /// 低音重。
    public var bass = false
    /// 低频包络 0…1：起得快、落得慢。
    public var lowEnvelope = 0.0
    public var timbre = ImmersiveTheaterTimbre.none
    /// 猿音的嘴张多大 0…1。
    public var mouth = 0.0
    /// 低沉的元音：圆嘴。
    public var mouthRound = false
    public var mood = ImmersiveTheaterMood.neutral
    public var imagery: ImmersiveTheaterImagery?
    public var playback = ImmersiveTheaterPlayback.playing
    /// 暂停了多久（动画时钟秒）。
    public var pausedFor = 0.0
    public var roles = ImmersiveTheaterRoles()
    public var events = ImmersiveTheaterEvents()
    /// 第几拍与拍内相位（0 正落在拍上）。
    public var beatIndex = 0
    public var beatPhase = 0.0
    /// 一拍几秒。
    public var beatPeriod = 0.6
    public var beatsPerMinute = 100.0
    /// 拍子有多稳 0…1。
    public var stability = 0.0
    /// 这一刻在这首歌里有多响 0…1。
    public var intensity = 0.0
    /// 高频 0…1（星星闪、路灯闪）。
    public var high = 0.0
    /// 低、中、高三段起音的余辉，起音那一刻是 1。
    public var onsetPulse: [Double] = [0, 0, 0]
    /// 读得到频谱。
    public var hasSpectrum = false

    public init() {}

    public var beatPosition: Double { Double(beatIndex) + beatPhase }
    /// 拍点那一下的包络：拍上是 1，往后很快落下去。
    public var beatPulse: Double { exp(-beatPhase * 4) }
    public var isPaused: Bool { playback != .playing }
}

// MARK: - 阈值

/// 原型 CFG 里的数（能量都按分贝算，见文件头的近似）。
public enum ImmersiveTheaterThresholds {
    public static let climaxShare = 0.85
    public static let climaxHold: TimeInterval = 1.5
    public static let climaxHoldAfterBuild: TimeInterval = 0.35
    public static let climaxExitShare = 0.7
    public static let climaxExitHold: TimeInterval = 1.5
    /// 高潮还要离这首歌最响过的地方不远（分贝）。
    public static let climaxNearPeak = 6.0
    public static let buildSlope = 0.6
    public static let buildRise = 0.8
    public static let buildHold: TimeInterval = 1.0
    public static let buildMaxStep = 3.0
    public static let buildExitSlope = 0.2
    public static let buildDuration: TimeInterval = 6
    public static let quietDrop = 12.0
    public static let quietHold: TimeInterval = 0.25
    /// 突然安静之前得够响：离最响过的地方不超过这么多分贝。
    public static let quietFromPeak = 12.0
    public static let quietMax: TimeInterval = 3.0
    /// 前奏：比最响过的地方低这么多分贝才算安静。
    public static let introBelowPeak = 14.0
    /// 前奏里能量比开头最安静时高出这么多分贝、持续 `introExitHold`，前奏就结束了。
    public static let introExitRise = 8.0
    public static let introExitHold: TimeInterval = 1.5
    /// 再长的前奏过了这么久也不算前奏了。
    public static let introLongest: TimeInterval = 40
    public static let endingWindow: TimeInterval = 6
    public static let endingBelowPeak = 12.0
    public static let cooldownDuration: TimeInterval = 3.5
    public static let bpmSlow = 88.0
    public static let bpmFast = 125.0
    public static let bpmHysteresis = 4.0
    public static let grooveHold: TimeInterval = 2
    public static let stableUnsteady = 0.42
    public static let stableFloat = 0.18
    public static let floatOnsetRate = 1.2
    public static let vocalOn = 0.55
    public static let vocalOff = 0.42
    public static let bassLow = 0.72
    public static let moodHold: TimeInterval = 5
    public static let happy = (bpm: 105.0, bright: 0.45, intensity: 0.35)
    public static let sad = (bpm: 96.0, bright: 0.42, intensity: 0.85)
    public static let tender = (bpm: 108.0, bright: 0.42, intensity: 0.85)
    public static let electronic = (bright: 0.6, stable: 0.6, high: 0.5)
    /// 暂停后看镜头多久开始打呼。
    public static let snoreAfter: TimeInterval = 6
    /// 读不到频谱时按这个拍速走。
    public static let fallbackBeatsPerMinute = 100.0
    /// 第一次见到的歌还不知道多响，先当它最响过这么多分贝。
    public static let initialPeak = -30.0
}

// MARK: - 判定

/// 逐帧把输入读成 `ImmersiveTheaterState`。值类型，每首歌一份；换歌时可以带上上一首的响度参照。
public struct ImmersiveTheaterConductor: Sendable {
    private typealias T = ImmersiveTheaterThresholds

    private var state = ImmersiveTheaterState()
    private var lastTime: TimeInterval?
    private var lastPlaybackTime: TimeInterval?

    // 能量（分贝）
    private var eS = -60.0
    private var eFast = -60.0
    private var eSlow = -60.0
    private var eM = -60.0
    private var primed = false
    /// 最响过的地方（1 秒平滑后的能量），缓慢回落。
    public private(set) var peak = T.initialPeak
    private var intensityM = 0.5
    private var slopeRing: [Double] = []
    private var slopeAccumulator = 0.0
    private var slope = 0.0
    private var rise = 0.0
    private var maxStep = 0.0

    // 频段与起音
    private var lowN = 0.0
    private var midN = 0.0
    private var highN = 0.0
    private var lowSlow = 0.0
    private var midSlow = 0.0
    private var bright = 0.4
    private var brightLongTerm = 0.4
    private var intensityLongTerm = 0.4
    private var onsetRate = 0.0
    private var pulseRate = 0.0
    private var syllableRate = 0.0
    private var vocalness = 0.0
    private var vocalEnvelope = 0.0
    private var singing = false
    private var bassRun = 0.0
    private var electronicLevel = 0.0
    private var electronic = false

    // 拍子
    private var beatClock = ImmersiveBeatClock()
    private var tempoHistory: [Double] = []
    private var tempoSince = 0.0
    private var beatsPerMinute = T.fallbackBeatsPerMinute
    private var beatPosition = 0.0
    private var lastBeatIndex: Int?

    // 能量走向
    private var arcSince = 0.0
    private var introOver = false
    private var introFloor: Double?
    private var introRiseRun = 0.0
    private var climaxRun = 0.0
    private var exitRun = 0.0
    private var buildRun = 0.0
    private var buildExitRun = 0.0
    private var buildStart = 0.0
    private var lastBuildEnd = -Double.infinity
    private var quietStart = 0.0
    private var quietRun = 0.0
    private var previousSlow = -60.0
    private var lastArc = ImmersiveTheaterArc.normal

    // 情绪、律动、暂停
    private var mood = ImmersiveTheaterMood.neutral
    private var moodSince = -Double.infinity
    private var moodAccumulator = 0.0
    private var groove = ImmersiveTheaterGroove.mid
    private var pendingGroove: ImmersiveTheaterGroove?
    private var pendingSince = 0.0
    private var pausedAt: TimeInterval?

    public init(peak: Double? = nil) {
        if let peak, peak.isFinite { self.peak = peak }
    }

    public var current: ImmersiveTheaterState { state }

    /// 分贝的近似：频谱条把 -72…-8 dB 线性压到 0…1 再取 0.72 次方，这里倒过来。
    public static func decibels(fromLevel level: Double) -> Double {
        let clamped = min(max(level.isFinite ? level : 0, 0), 1)
        return 64 * pow(clamped, 1 / 0.72) - 72
    }

    /// 从这一帧的输入推出下一份状态。
    public mutating func update(_ input: ImmersiveTheaterInput) -> ImmersiveTheaterState {
        let dt = lastTime.map { min(max(input.time - $0, 0), 0.25) } ?? 0
        lastTime = input.time
        let t = input.playbackTime
        // 拖了进度或换了一段（进度跳开两秒以上）：能量走向从头判。
        if let lastPlaybackTime, input.isPlaying, abs(t - lastPlaybackTime) > 2 + dt {
            resetArc(at: t, firstLyricStart: input.firstLyricStart)
        } else if self.lastPlaybackTime == nil {
            resetArc(at: t, firstLyricStart: input.firstLyricStart)
        }
        let playbackDelta = lastPlaybackTime.map { min(max(t - $0, 0), 0.25) } ?? 0
        lastPlaybackTime = t

        var events = ImmersiveTheaterEvents()
        let features = input.isPlaying ? input.features : nil
        let hasSpectrum = features.map { summary in
            summary.energy > 0.02 || summary.registerLevels.contains { level in level > 0.001 }
        } ?? false
        let lyricActive = input.lyric?.isActive(at: t) ?? false

        if let features, hasSpectrum {
            feed(features, dt: dt, playbackTime: t, hasLyrics: input.hasLyrics, lyricActive: lyricActive, events: &events)
        } else if input.isPlaying {
            // 读不到频谱：有歌词时当作在唱，别的量慢慢回到中间。
            singing = lyricActive
            vocalness += ((lyricActive ? 0.7 : 0) - vocalness) * Self.follow(dt, tau: 0.25)
            state.intensity += (0.45 - state.intensity) * Self.follow(dt, tau: 1)
            state.high = 0.3
            for index in state.onsetPulse.indices { state.onsetPulse[index] *= exp(-dt / 0.12) }
        }
        state.hasSpectrum = hasSpectrum

        advanceBeat(
            playbackTime: t,
            playbackDelta: playbackDelta,
            isPlaying: input.isPlaying,
            hasSpectrum: hasSpectrum,
            events: &events
        )
        if input.isPlaying {
            updateArc(at: t, dt: playbackDelta, input: input)
            updateMood(dt: playbackDelta, playbackTime: t)
        }
        resolve(input: input, lyricActive: lyricActive, hasSpectrum: hasSpectrum, dt: dt, events: events)
        return state
    }

    // MARK: 频谱 → 特征

    private mutating func feed(
        _ features: ImmersiveAudioFeatures,
        dt: TimeInterval,
        playbackTime t: TimeInterval,
        hasLyrics: Bool,
        lyricActive: Bool,
        events: inout ImmersiveTheaterEvents
    ) {
        let eDb = Self.decibels(fromLevel: features.energy)
        if !primed {
            primed = true
            eS = eDb
            eFast = eDb
            eSlow = eDb
            eM = eDb
            previousSlow = eDb
        }
        eS = Self.ema(eS, eDb, dt, 0.35)
        eFast = Self.ema(eFast, eDb, dt, 0.08)
        eSlow = Self.ema(eSlow, eDb, dt, 2.5)
        eM = Self.ema(eM, eDb, dt, 1.0)
        peak = max(eM, peak - dt * 0.15)
        state.intensity = min(max(features.intensity, 0), 1)
        intensityM = Self.ema(intensityM, state.intensity, dt, 1.0)

        let registers = features.registerIntensity
        let levels = features.registerLevels
        lowN = Self.ema(lowN, registers.count > 0 ? registers[0] : 0, dt, 0.08)
        midN = Self.ema(midN, registers.count > 1 ? registers[1] : 0, dt, 0.08)
        highN = Self.ema(highN, registers.count > 2 ? registers[2] : 0, dt, 0.08)
        state.high = highN
        let lowLevel = levels.count > 0 ? levels[0] : 0
        let midLevel = levels.count > 1 ? levels[1] : 0
        lowSlow = Self.ema(lowSlow, lowLevel, dt, 2)
        midSlow = Self.ema(midSlow, midLevel, dt, 1.5)

        let onsets = features.onsets
        let low = onsets.count > 0 ? onsets[0] : 0
        let mid = onsets.count > 1 ? onsets[1] : 0
        let highOnset = onsets.count > 2 ? onsets[2] : 0
        events.lowOnset = low > 0
        events.onset = low > 0 || mid > 0
        events.highOnset = highOnset > 0
        events.lowStrength = low
        // 低频包络：起得快、落得慢；鼓点那一下顶满。
        let lowTarget = max(min(max((lowLevel - lowSlow + 0.08) / 0.2, 0), 1), low > 0 ? 1 : 0)
        state.lowEnvelope = Self.ema(state.lowEnvelope, lowTarget, dt, lowTarget > state.lowEnvelope ? 0.015 : 0.12)

        let rate = dt > 0 ? 1 / dt : 0
        onsetRate = Self.ema(onsetRate, events.onset ? rate : 0, dt, 4)
        pulseRate = Self.ema(pulseRate, (low > 0 || mid > 0) ? rate : 0, dt, 6)
        syllableRate = Self.ema(syllableRate, mid > 0 ? rate : 0, dt, 1.5)
        let pulses = [low, mid, highOnset]
        for index in 0..<3 {
            state.onsetPulse[index] = pulses[index] > 0 ? 1 : state.onsetPulse[index] * exp(-dt / 0.12)
        }

        // 亮度：频谱重心在对数频率轴上的位置，0.30 以下算暗、0.55 以上算亮。
        bright = min(max((features.centroid - 0.30) / 0.25, 0), 1)
        brightLongTerm = Self.ema(brightLongTerm, bright, dt, 6)
        intensityLongTerm = Self.ema(intensityLongTerm, state.intensity, dt, 6)

        // 能量 2.5 秒的走势：每 0.1 秒记一个 1 秒平滑的能量。
        slopeAccumulator += dt
        if slopeAccumulator >= 0.1 {
            slopeAccumulator = min(slopeAccumulator - 0.1, 0.1)
            slopeRing.insert(eM, at: 0)
            if slopeRing.count > 25 { slopeRing.removeLast(slopeRing.count - 25) }
            updateSlope()
        }

        // 人声度：中段够响、字头够密；有歌词时按这一句在不在唱加权。
        let syllables = min(max((syllableRate - 1.0) / 3.0, 0), 1)
        var raw = min(max((midN - 0.25) / 0.5, 0), 1) * (0.25 + 0.75 * syllables)
        if hasLyrics {
            raw = lyricActive ? min(max(raw, 0.45) * 1.25, 1) : raw * 0.45
        }
        vocalness = Self.ema(vocalness, raw, dt, 0.25)
        if !singing, vocalness > T.vocalOn, state.intensity > 0.12 {
            singing = true
        } else if singing, vocalness < T.vocalOff || state.intensity < 0.06 {
            singing = false
        }
        let midOpen = min(max((midLevel - midSlow + 0.06) / 0.16, 0), 1) + (mid > 0 ? 0.35 : 0)
        vocalEnvelope = Self.ema(vocalEnvelope, min(midOpen, 1), dt, midOpen > vocalEnvelope ? 0.03 : 0.09)
        let mouthTarget = singing ? min(max((vocalEnvelope - 0.25) / 0.55, 0), 1) : 0
        state.mouth = Self.ema(state.mouth, mouthTarget, dt, 0.03)
        state.mouthRound = singing && features.brightnessShift < -0.25 && state.mouth > 0.35

        // 低音重：低频排位高，并且低段明显比中段响，持续一秒左右。
        let bassNow = lowN > T.bassLow && lowLevel - midLevel > 0.06
        bassRun = min(max(bassRun + (bassNow ? dt : -dt), 0), 1.5)
        if !state.bass, bassRun > 1 {
            state.bass = true
        } else if state.bass, bassRun < 0.3 {
            state.bass = false
        }

        // 拍速：节拍钟跟着鼓点走；拍速折在 78…156 之间，按起音的实际密度认真实的那一档。
        beatClock.update(
            beat: features.beat,
            beatsPerSecond: features.beatsPerSecond,
            steadiness: features.steadiness,
            at: t
        )
        tempoSince += dt
        if tempoSince >= 0.2, let folded = features.beatsPerSecond, folded > 0 {
            tempoSince = 0
            let ratio = pulseRate / folded
            var bpm = folded * 60
            if ratio > 1.6, bpm * 2 <= 200 {
                bpm *= 2
            } else if ratio < 0.6, bpm / 2 >= 50 {
                bpm /= 2
            }
            tempoHistory.append(bpm)
            if tempoHistory.count > 15 { tempoHistory.removeFirst(tempoHistory.count - 15) }
            let sorted = tempoHistory.sorted()
            beatsPerMinute = sorted[sorted.count / 2]
        }
        let confidence = min(max(beatClock.confidence / 0.6, 0), 1)
        state.stability = min(max(features.steadiness, 0), 1) * confidence

        let elecNow = brightLongTerm > T.electronic.bright && state.stability > T.electronic.stable
            && highN > T.electronic.high && beatsPerMinute >= 110 && beatsPerMinute <= 150
        electronicLevel = Self.ema(electronicLevel, elecNow ? 1 : 0, dt, 2.5)
        if !electronic, electronicLevel > 0.7 {
            electronic = true
        } else if electronic, electronicLevel < 0.35 {
            electronic = false
        }
    }

    private mutating func updateSlope() {
        let count = slopeRing.count
        guard count >= 10 else { return }
        var sumX = 0.0
        var sumY = 0.0
        var sumXY = 0.0
        var sumXX = 0.0
        for (index, value) in slopeRing.enumerated() {
            let x = -Double(index) * 0.1
            sumX += x
            sumY += value
            sumXY += x * value
            sumXX += x * x
        }
        let n = Double(count)
        slope = (n * sumXY - sumX * sumY) / (n * sumXX - sumX * sumX + 1e-9)
        // 半秒一步有几成在往上走：渐强是一步步涨上去的，段落突变只有一大步。
        var up = 0.0
        var steps = 0.0
        var largest = 0.0
        var index = 0
        while index + 5 < count {
            steps += 1
            let step = slopeRing[index] - slopeRing[index + 5]
            if step > 0.25 { up += 1 }
            largest = max(largest, step)
            index += 1
        }
        rise = steps > 0 ? up / steps : 0
        maxStep = largest
    }

    // MARK: 拍子

    private mutating func advanceBeat(
        playbackTime t: TimeInterval,
        playbackDelta: TimeInterval,
        isPlaying: Bool,
        hasSpectrum: Bool,
        events: inout ImmersiveTheaterEvents
    ) {
        let bpm = hasSpectrum ? beatsPerMinute : T.fallbackBeatsPerMinute
        let period = 60 / max(bpm, 30)
        if hasSpectrum, beatClock.isLocked, let clock = beatClock.position(at: t), beatClock.period > 0.05 {
            // 节拍钟的一拍是折过的那一档；真实拍速是它的一半或两倍时按比例换算。
            let scale = (60 / beatClock.period) > 0 ? bpm / (60 / beatClock.period) : 1
            let target = clock * scale
            // 差得不多就慢慢靠过去，差太多（刚对上拍子、拖了进度）直接跳过去。
            let predicted = beatPosition + (isPlaying ? playbackDelta / period : 0)
            if abs(target - predicted) > 0.5 {
                beatPosition = target
                lastBeatIndex = Int(target.rounded(.down))
            } else {
                beatPosition = predicted + (target - predicted) * 0.35
            }
        } else if isPlaying {
            beatPosition += playbackDelta / period
        }
        let index = Int(beatPosition.rounded(.down))
        if let lastBeatIndex, index > lastBeatIndex, isPlaying {
            events.beat = true
        }
        lastBeatIndex = index
        state.beatIndex = index
        state.beatPhase = min(max(beatPosition - Double(index), 0), 1)
        state.beatPeriod = period
        state.beatsPerMinute = bpm
    }

    // MARK: 能量走向

    private mutating func resetArc(at t: TimeInterval, firstLyricStart: TimeInterval?) {
        arcSince = t
        state.arc = .normal
        // 从中途打开（或拖到中间）时不再从前奏判起。
        let introEnd = firstLyricStart ?? 4
        introOver = t > max(introEnd, 4) + 0.5
        introFloor = nil
        introRiseRun = 0
        climaxRun = 0
        exitRun = 0
        buildRun = 0
        buildExitRun = 0
        quietRun = 0
        lastBuildEnd = -Double.infinity
        slopeRing.removeAll()
        slope = 0
        rise = 0
        maxStep = 0
        previousSlow = eSlow
    }

    private mutating func setArc(_ arc: ImmersiveTheaterArc, at t: TimeInterval) {
        guard state.arc != arc else { return }
        state.arc = arc
        arcSince = t
    }

    private mutating func updateArc(at t: TimeInterval, dt: TimeInterval, input: ImmersiveTheaterInput) {
        guard state.hasSpectrum else {
            // 没有频谱时只认前奏：第一句歌词之前打盹。
            if let first = input.firstLyricStart, t < first - 0.5, !introOver {
                setArc(.intro, at: t)
            } else {
                introOver = true
                if state.arc != .normal { setArc(.normal, at: t) }
            }
            return
        }
        // 前奏：唱起来了、过了第一句的时间、能量比开头最静时高出一截，或者前奏太长了，都算结束。
        if !introOver {
            introFloor = min(introFloor ?? eS, eS)
            if let floor = introFloor, eS - floor > T.introExitRise {
                introRiseRun += dt
            } else {
                introRiseRun = 0
            }
            if introRiseRun > T.introExitHold || singing || t > T.introLongest {
                introOver = true
            }
            if let first = input.firstLyricStart, t > first + 0.5 {
                introOver = true
            }
        }
        let ending = input.duration > 0 && input.duration - t < T.endingWindow && eS < peak - T.endingBelowPeak

        // 突然安静：快能量比慢能量低了一大截，并且之前够响。
        let dropNow = previousSlow - eFast > T.quietDrop && previousSlow > peak - T.quietFromPeak
        quietRun = dropNow ? quietRun + dt : 0
        let dropped = quietRun > T.quietHold && state.arc != .cooldown
        if !dropNow || quietRun <= T.quietHold {
            previousSlow = eSlow
        }
        if state.arc == .quiet {
            let elapsed = t - quietStart
            if elapsed > T.quietMax || (elapsed > 0.6 && eFast > eSlow - 5) {
                // 安静段落长过定格那几秒：以眼下的电平重新当参照，不会每三秒又定格一次。
                previousSlow = eSlow
                quietRun = 0
                setArc(.normal, at: t)
            }
            return
        }
        if dropped, state.arc != .intro {
            quietStart = t
            setArc(.quiet, at: t)
            return
        }

        // 高潮：这首歌里排在前一成半，并且离最响过的地方不远。
        let loudNow = intensityM > T.climaxShare && eM > peak - T.climaxNearPeak
        climaxRun = loudNow ? climaxRun + dt : 0
        if state.arc == .climax {
            if intensityM < T.climaxExitShare || eM < peak - T.climaxNearPeak - 4 {
                exitRun += dt
            } else {
                exitRun = 0
            }
            if exitRun > T.climaxExitHold {
                exitRun = 0
                setArc(.cooldown, at: t)
            }
            return
        }
        let hold = (t - lastBuildEnd < 2 || state.arc == .build) ? T.climaxHoldAfterBuild : T.climaxHold
        if climaxRun > hold, introOver || state.arc == .build {
            if state.arc == .build { lastBuildEnd = t }
            setArc(.climax, at: t)
            return
        }

        // 渐强：2.5 秒里一步步往上涨，没有一大步的突变。
        if slope > T.buildSlope, rise > T.buildRise, maxStep < T.buildMaxStep, state.intensity > 0.15 {
            buildRun += dt
        } else {
            buildRun = max(0, buildRun - dt)
        }
        if state.arc == .build {
            state.buildProgress = min(max((t - buildStart) / T.buildDuration, 0), 1)
            if slope < T.buildExitSlope || rise < 0.4 {
                buildExitRun += dt
            } else {
                buildExitRun = 0
            }
            if buildExitRun > 0.8 {
                lastBuildEnd = t
                setArc(.normal, at: t)
            }
            return
        }
        if buildRun > T.buildHold, introOver {
            buildStart = t
            buildExitRun = 0
            state.buildProgress = 0
            setArc(.build, at: t)
            return
        }
        if state.arc == .cooldown {
            if t - arcSince > T.cooldownDuration { setArc(.normal, at: t) }
            return
        }
        let quietIntro = !introOver && eS < peak - T.introBelowPeak
        if quietIntro || ending {
            setArc(.intro, at: t)
            return
        }
        if state.arc == .intro { setArc(.normal, at: t) }
    }

    // MARK: 情绪

    private mutating func updateMood(dt: TimeInterval, playbackTime t: TimeInterval) {
        guard state.hasSpectrum else { return }
        moodAccumulator += dt
        guard moodAccumulator >= 0.5 else { return }
        moodAccumulator = 0
        let candidate = Self.classifyMood(
            beatsPerMinute: state.stability > 0.25 ? beatsPerMinute : 80,
            brightness: brightLongTerm,
            intensity: intensityLongTerm
        )
        if candidate != mood, t - moodSince > T.moodHold {
            mood = candidate
            moodSince = t
        }
    }

    /// 原型的情绪划分：快、亮、够响是欢快；慢、暗是伤感；慢、亮、不太响是温柔。
    public static func classifyMood(beatsPerMinute bpm: Double, brightness: Double, intensity: Double) -> ImmersiveTheaterMood {
        if bpm >= T.happy.bpm, brightness >= T.happy.bright, intensity >= T.happy.intensity { return .happy }
        if bpm < T.sad.bpm, brightness < T.sad.bright, intensity < T.sad.intensity { return .sad }
        if bpm < T.tender.bpm, brightness >= T.tender.bright, intensity < T.tender.intensity { return .tender }
        return .neutral
    }

    // MARK: 律动

    /// 原型的速度分档：没拍子就漂浮，拍子乱就扭，其余按拍速分慢、中、快，分界处带回差。
    public static func groove(
        current: ImmersiveTheaterGroove,
        beatsPerMinute bpm: Double,
        stability: Double,
        onsetRate: Double,
        intensity: Double,
        isLocked: Bool
    ) -> ImmersiveTheaterGroove {
        if (stability < T.stableFloat && onsetRate < T.floatOnsetRate) || (intensity < 0.25 && !isLocked) {
            return .float
        }
        if stability < T.stableUnsteady { return .unsteady }
        let slowEdge = current == .slow ? T.bpmSlow + T.bpmHysteresis : T.bpmSlow
        let fastEdge = current == .fast ? T.bpmFast - T.bpmHysteresis : T.bpmFast
        if bpm < slowEdge { return .slow }
        if bpm >= fastEdge { return .fast }
        return .mid
    }

    private mutating func autoGroove(at time: TimeInterval, hasSpectrum: Bool) -> ImmersiveTheaterGroove {
        let candidate: ImmersiveTheaterGroove = hasSpectrum
            ? Self.groove(
                current: groove,
                beatsPerMinute: beatsPerMinute,
                stability: state.stability,
                onsetRate: onsetRate,
                intensity: state.intensity,
                isLocked: beatClock.isLocked
            )
            : .mid
        if candidate != groove {
            if pendingGroove != candidate {
                pendingGroove = candidate
                pendingSince = time
            } else if time - pendingSince > T.grooveHold {
                groove = candidate
                pendingGroove = nil
            }
        } else {
            pendingGroove = nil
        }
        return groove
    }

    // MARK: 汇总

    private mutating func resolve(
        input: ImmersiveTheaterInput,
        lyricActive: Bool,
        hasSpectrum: Bool,
        dt: TimeInterval,
        events: ImmersiveTheaterEvents
    ) {
        let t = input.playbackTime
        state.events = events
        state.groove = autoGroove(at: input.time, hasSpectrum: hasSpectrum)
        state.arcTime = max(0, t - arcSince)
        state.arcEnter = state.arc != lastArc
        lastArc = state.arc

        // 音色：在唱就是人声；够响、拍子稳就是器乐段。
        if singing || (!hasSpectrum && lyricActive) {
            state.timbre = .vocal
        } else if state.intensity > 0.3, state.stability > 0.3 {
            state.timbre = .instrumental
        } else {
            state.timbre = .none
        }
        if state.timbre == .vocal, !hasSpectrum {
            // 读不到人声的包络：按音节的快慢一开一合。
            let syllable = 0.5 + 0.5 * sin(input.time * 9.5)
            state.mouth = min(max(syllable * (0.6 + 0.4 * sin(input.time * 1.7)), 0), 1)
            state.mouthRound = sin(input.time * 1.3) > 0.7
        } else if !hasSpectrum {
            state.mouth *= exp(-dt / 0.05)
            state.mouthRound = false
        }
        state.mood = hasSpectrum ? mood : .neutral

        // 歌词意象：这一句还在唱时按关键词。
        if let lyric = input.lyric, lyricActive {
            state.imagery = ImmersiveTheaterKeywords.imagery(in: lyric.text)
        } else {
            state.imagery = nil
        }

        // 播放情境。
        if input.isPlaying {
            pausedAt = nil
            state.playback = .playing
            state.pausedFor = 0
        } else {
            let since = pausedAt ?? input.time
            pausedAt = since
            state.pausedFor = max(0, input.time - since)
            state.playback = state.pausedFor < T.snoreAfter ? .look : .snore
        }

        // 角色分工。
        let paused = state.playback != .playing
        let rock = state.beatsPerMinute >= 120 && state.intensity > 0.5 && state.stability > 0.5 && highN > 0.4
        state.roles.drum = !paused
            && (state.timbre == .instrumental || state.groove == .fast || rock || state.arc == .climax)
        state.roles.cast = !paused && (electronic || state.arc == .climax)
        let calm = state.groove == .slow || state.groove == .float
            || ((state.mood == .sad || state.mood == .tender) && state.intensity < 0.4)
        if calm, state.arc != .climax {
            state.roles.donkey = .lie
        } else if state.groove == .fast || (state.arc == .climax && state.beatsPerMinute >= 110) {
            state.roles.donkey = .mill
        } else {
            state.roles.donkey = .metronome
        }
    }

    // MARK: 工具

    /// 时间常数 `tau` 的指数平滑。
    static func ema(_ previous: Double, _ value: Double, _ dt: TimeInterval, _ tau: TimeInterval) -> Double {
        previous + (value - previous) * follow(dt, tau: tau)
    }

    static func follow(_ dt: TimeInterval, tau: TimeInterval) -> Double {
        guard dt > 0 else { return 0 }
        return 1 - exp(-dt / max(tau, 1e-4))
    }
}

// MARK: - 关键词

/// 歌词里的关键词：选镜头和意象都按它。中文按字，英文按词（`star` 不算 `start`）。
public enum ImmersiveTheaterKeywords {
    /// 英文只认整词（可带复数），避免 star→start、cry→crystal 这类误判。
    static let exactWords: Set<String> = ["star", "tear", "cry", "sun"]

    static let sceneWords: [(ImmersiveTheaterTemplate, [String])] = [
        (.night, ["月", "夜", "星", "moon", "night", "star"]),
        (.rain, ["雨", "泪", "rain", "tear"]),
        (.flower, ["花", "春", "夏", "阳", "sun", "flower", "summer", "spring"]),
    ]

    static let imageryWords: [(ImmersiveTheaterImagery, [String])] = [
        (.tears, ["泪", "哭", "tear", "cry", "cries", "crying"]),
        (.rain, ["雨", "rain"]),
        (.love, ["爱", "喜欢", "love"]),
        (.moon, ["月", "夜", "星", "moon", "night", "star"]),
    ]

    /// 这句歌词该配哪个镜头；没有关键词时为 nil。
    public static func template(in text: String) -> ImmersiveTheaterTemplate? {
        first(in: text, table: sceneWords)
    }

    /// 这句歌词里的意象；没有时为 nil。
    public static func imagery(in text: String) -> ImmersiveTheaterImagery? {
        first(in: text, table: imageryWords)
    }

    private static func first<Value>(in text: String, table: [(Value, [String])]) -> Value? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return nil }
        for (value, words) in table where words.contains(where: { word in Self.contains(lowered, word: word) }) {
            return value
        }
        return nil
    }

    static func contains(_ text: String, word: String) -> Bool {
        guard word.unicodeScalars.allSatisfy(\.isASCII) else { return text.contains(word) }
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            if before.map({ !$0.isLetter }) ?? true {
                if !exactWords.contains(word) { return true }
                let rest = text[range.upperBound...].prefix { $0.isLetter }
                if rest.isEmpty || rest == "s" || rest == "es" { return true }
            }
            searchStart = range.upperBound
        }
        return false
    }
}

// MARK: - 角色与站位

public enum ImmersiveTheaterCharacter: String, CaseIterable, Sendable {
    /// 猿音：主唱，永远在中间。
    case yuanyin
    /// 小黑：鼓手、伴舞。
    case xiaohei
    /// 阿酒：施法打光。
    case ajiu
    /// 小火驴：节拍器、客串。
    case xiaohuolv
}

/// 四个站位：中间主唱、左右两侧、后排。
public enum ImmersiveTheaterSlot: String, CaseIterable, Sendable {
    case lead
    case left
    case right
    case back

    /// 前后：0 后排，2 最前。
    public var depth: Int {
        switch self {
        case .lead: 2
        case .left, .right: 1
        case .back: 0
        }
    }

    /// 在画面左半边（-1）、中间（0）还是右半边（1）。
    public var side: Double {
        switch self {
        case .lead: 0
        case .left: -1
        case .right, .back: 1
        }
    }
}

public enum ImmersiveTheaterPersonality: String, Sendable {
    /// 活泼：动作幅度 ×1.2。
    case lively
    /// 慵懒：动作幅度 ×0.72。
    case lazy

    public var amplitude: Double { self == .lively ? 1.2 : 0.72 }
}

/// 这首歌谁在场、站哪、什么性子。按歌名定种子，同一首每次都一样。
public enum ImmersiveTheaterCast {
    public struct Member: Equatable, Sendable {
        public var character: ImmersiveTheaterCharacter
        public var slot: ImmersiveTheaterSlot
        public var personality: ImmersiveTheaterPersonality
        /// 0…1，错开各自的小动作。
        public var phase: Double

        public init(
            character: ImmersiveTheaterCharacter,
            slot: ImmersiveTheaterSlot,
            personality: ImmersiveTheaterPersonality,
            phase: Double
        ) {
            self.character = character
            self.slot = slot
            self.personality = personality
            self.phase = phase
        }
    }

    /// 猿音总在场、站中间；另外三位按种子洗牌，来 1–3 位，站左、右、后排。返回的顺序是由后往前画的顺序。
    public static func plan(seed: UInt64) -> [Member] {
        var random = ImmersiveRandom(seed: seed ^ 0xC0FF_EE00_7EA7_E2A5)
        var others: [ImmersiveTheaterCharacter] = [.xiaohei, .ajiu, .xiaohuolv]
        shuffle(&others, random: &random)
        let count = 1 + Int(random.unit() * 3)
        var sides: [ImmersiveTheaterSlot] = [.left, .right]
        shuffle(&sides, random: &random)
        let slots = sides + [.back]
        var members: [Member] = []
        for character in ImmersiveTheaterCharacter.allCases {
            let lively = random.unit() < (character == .yuanyin ? 0.7 : 0.55)
            let slot: ImmersiveTheaterSlot
            if character == .yuanyin {
                slot = .lead
            } else if let index = others.firstIndex(of: character), index < min(count, 3) {
                slot = slots[index]
            } else {
                continue
            }
            var phaseRandom = ImmersiveRandom(seed: seed ^ ImmersiveRandom.seed(for: character.rawValue))
            members.append(Member(
                character: character,
                slot: slot,
                personality: lively ? .lively : .lazy,
                phase: phaseRandom.unit()
            ))
        }
        return members.sorted { lhs, rhs in
            if lhs.slot.depth != rhs.slot.depth { return lhs.slot.depth < rhs.slot.depth }
            return lhs.slot.side < rhs.slot.side
        }
    }

    static func shuffle<Element>(_ values: inout [Element], random: inout ImmersiveRandom) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, to: 0, by: -1) {
            let other = min(Int(random.unit() * Double(index + 1)), index)
            values.swapAt(index, other)
        }
    }
}
