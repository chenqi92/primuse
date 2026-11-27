import Foundation

// 「水彩小剧场」的导演层：一个镜头配一句歌词（隔不到 3 秒的合并），没有歌词时每 8 小节（32 拍）换一次，
// 拍子不稳时每 16 秒。歌词里有月、夜、雨、花这些字就挑对应的场景，否则按种子轮换；景别和转场也按种子挑。

/// 三个场景模板。
public enum ImmersiveTheaterTemplate: String, CaseIterable, Sendable {
    /// 夜空：月亮、星星、山丘。
    case night
    /// 雨夜：街灯、雨丝、水洼。
    case rain
    /// 花田：太阳、花、飘落的花瓣。
    case flower

    /// 画面整体是亮的（花田）：歌词换深色字、浅色水彩带。
    public var isLight: Bool { self == .flower }
}

/// 景别：放大多少、镜头中心往哪偏（按 1600×900 的舞台单位，宽画面以外按比例换算）。
public enum ImmersiveTheaterFraming: String, CaseIterable, Sendable {
    case wide
    case lead
    case low
    case sideLeft
    case sideRight

    public var zoom: Double {
        switch self {
        case .wide: 1.0
        case .lead: 1.24
        case .low: 1.08
        case .sideLeft, .sideRight: 1.18
        }
    }

    public var offsetX: Double {
        switch self {
        case .sideLeft: -260
        case .sideRight: 260
        default: 0
        }
    }

    public var offsetY: Double {
        switch self {
        case .wide: 0
        case .lead: 40
        case .low: -50
        case .sideLeft, .sideRight: 30
        }
    }
}

/// 换镜头的转场：笔刷擦过去，或者圆形收拢再张开。
public enum ImmersiveTheaterTransition: String, CaseIterable, Sendable {
    case brush
    case iris

    public var duration: TimeInterval { self == .iris ? 1.0 : 0.9 }
}

/// 一个镜头。
public struct ImmersiveTheaterShot: Equatable, Sendable {
    /// 这首歌里的第几个镜头。
    public var index: Int
    public var template: ImmersiveTheaterTemplate
    /// 同一个场景的两种画法，连着两次同一个场景时换另一种。
    public var variant: Int
    public var framing: ImmersiveTheaterFraming
    public var transition: ImmersiveTheaterTransition
    /// 按歌词里的关键词挑的场景。
    public var chosenByLyric: Bool

    public init(
        index: Int,
        template: ImmersiveTheaterTemplate,
        variant: Int,
        framing: ImmersiveTheaterFraming,
        transition: ImmersiveTheaterTransition,
        chosenByLyric: Bool
    ) {
        self.index = index
        self.template = template
        self.variant = variant
        self.framing = framing
        self.transition = transition
        self.chosenByLyric = chosenByLyric
    }
}

/// 每个镜头怎么拍：只看种子、第几个镜头、这句歌词和上一个镜头，同样的输入每次一样。
public struct ImmersiveTheaterShotPlanner: Sendable {
    public let seed: UInt64
    /// 没有关键词时三个场景的轮换顺序（按种子洗过）。
    public let rotation: [ImmersiveTheaterTemplate]

    public init(seed: UInt64) {
        self.seed = seed
        var random = ImmersiveRandom(seed: seed ^ 0x5CE1_E5CE_1E5C_E1E5)
        var templates = ImmersiveTheaterTemplate.allCases
        ImmersiveTheaterCast.shuffle(&templates, random: &random)
        rotation = templates
    }

    public func shot(index: Int, lyricText: String?, previous: ImmersiveTheaterShot?) -> ImmersiveTheaterShot {
        var random = ImmersiveRandom(seed: seed ^ (UInt64(truncatingIfNeeded: index + 1) &* 0x9E37_79B9_7F4A_7C15))
        let byWord = lyricText.flatMap { ImmersiveTheaterKeywords.template(in: $0) }
        var template: ImmersiveTheaterTemplate
        if let byWord {
            template = byWord
        } else {
            let count = rotation.count
            template = rotation[((index % count) + count) % count]
            if let previous, previous.template == template {
                template = rotation[(((index + 1) % count) + count) % count]
            }
        }
        var variant = Int(random.unit() * 2) % 2
        if let previous, previous.template == template, previous.variant == variant {
            variant = 1 - variant
        }
        let framings: [ImmersiveTheaterFraming] = [.wide, .wide, .lead, .low, .sideLeft, .sideRight]
        let pick = min(Int(random.unit() * Double(framings.count)), framings.count - 1)
        let framing: ImmersiveTheaterFraming = index == 0 ? ImmersiveTheaterFraming.wide : framings[pick]
        let transition: ImmersiveTheaterTransition = random.unit() < 0.6 ? .brush : .iris
        return ImmersiveTheaterShot(
            index: index,
            template: template,
            variant: variant,
            framing: framing,
            transition: transition,
            chosenByLyric: byWord != nil
        )
    }
}

/// 一次换镜头。`immediate` 时直接换（第一个镜头、拖了进度），不走转场。
public struct ImmersiveTheaterCut: Equatable, Sendable {
    public var shot: ImmersiveTheaterShot
    public var immediate: Bool

    public init(shot: ImmersiveTheaterShot, immediate: Bool) {
        self.shot = shot
        self.immediate = immediate
    }
}

/// 什么时候换镜头。每首歌一份。
public struct ImmersiveTheaterShotDirector: Sendable {
    /// 两句歌词隔不到这么久，就并在同一个镜头里。
    public static let minimumLyricShot: TimeInterval = 3
    /// 没有歌词时，拍子稳就每这么多拍换一次。
    public static let beatsPerShot = 32
    /// 拍子不稳时每这么多秒换一次。
    public static let secondsPerShot: TimeInterval = 16

    public let planner: ImmersiveTheaterShotPlanner
    public private(set) var current: ImmersiveTheaterShot?
    private var lastCutTime: TimeInterval = 0
    private var lastPlaybackTime: TimeInterval?
    private var lastLyricID: Int?
    private var beatsAtCut = 0

    public init(seed: UInt64) {
        planner = ImmersiveTheaterShotPlanner(seed: seed)
    }

    /// 走一帧，要换镜头时返回这次换成什么。
    public mutating func update(
        playbackTime t: TimeInterval,
        lyric: ImmersiveTheaterLyricCue?,
        hasLyrics: Bool,
        beatIndex: Int,
        isBeat: Bool,
        isStable: Bool
    ) -> ImmersiveTheaterCut? {
        defer { lastPlaybackTime = t }
        let lyricText = lyric.flatMap { cue -> String? in
            let trimmed = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let current else {
            return cut(index: 0, text: lyricText, lyricID: lyric?.id, at: t, beatIndex: beatIndex, immediate: true)
        }
        // 拖了进度：直接换到新镜头，不走转场。
        if let lastPlaybackTime, t < lastPlaybackTime - 1 || t > lastPlaybackTime + 3 {
            return cut(index: current.index + 1, text: lyricText, lyricID: lyric?.id, at: t, beatIndex: beatIndex, immediate: true)
        }
        if hasLyrics {
            guard let lyric, lyricText != nil, lyric.id != lastLyricID else { return nil }
            // 换句了：离上一次换镜头不到 3 秒就并进这个镜头。
            guard t - lastCutTime >= Self.minimumLyricShot else {
                lastLyricID = lyric.id
                return nil
            }
            return cut(index: current.index + 1, text: lyricText, lyricID: lyric.id, at: t, beatIndex: beatIndex, immediate: false)
        }
        let byBeats = isStable && beatIndex - beatsAtCut >= Self.beatsPerShot && isBeat
        let byTime = !isStable && t - lastCutTime > Self.secondsPerShot
        guard byBeats || byTime else { return nil }
        return cut(index: current.index + 1, text: nil, lyricID: nil, at: t, beatIndex: beatIndex, immediate: false)
    }

    private mutating func cut(
        index: Int,
        text: String?,
        lyricID: Int?,
        at t: TimeInterval,
        beatIndex: Int,
        immediate: Bool
    ) -> ImmersiveTheaterCut {
        let shot = planner.shot(index: index, lyricText: text, previous: current)
        current = shot
        lastCutTime = t
        lastLyricID = lyricID
        beatsAtCut = beatIndex
        return ImmersiveTheaterCut(shot: shot, immediate: immediate)
    }
}
