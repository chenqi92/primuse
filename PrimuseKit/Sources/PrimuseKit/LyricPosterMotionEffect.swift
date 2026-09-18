import Foundation

/// 实况照片里画面"怎么动"。逐句浮现是所有动态海报的底子，这里选的是
/// 叠在它上面的那层动静。
public struct LyricPosterMotionEffectID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension LyricPosterMotionEffectID {
    /// 只有逐句浮现，画面其余部分不动。
    static let none = LyricPosterMotionEffectID("none")
    /// 歌词整体轻微上下浮动。
    static let floatingLyrics = LyricPosterMotionEffectID("floating_lyrics")
    /// 封面缓慢推近。
    static let artworkZoom = LyricPosterMotionEffectID("artwork_zoom")
    /// 光点粒子自下而上飘散。
    static let particles = LyricPosterMotionEffectID("particles")
    /// 底部声波随时间起伏。
    static let waveform = LyricPosterMotionEffectID("waveform")
}

public struct LyricPosterMotionEffectSpec: Hashable, Sendable, Identifiable {
    public let id: LyricPosterMotionEffectID
    public let nameKey: String
    public let symbolName: String
    /// 没有封面就没有可推近的东西，这类动效直接不出现在选择器里。
    public let requiresArtwork: Bool
    public let order: Int

    public init(
        id: LyricPosterMotionEffectID,
        nameKey: String,
        symbolName: String,
        requiresArtwork: Bool = false,
        order: Int
    ) {
        self.id = id
        self.nameKey = nameKey
        self.symbolName = symbolName
        self.requiresArtwork = requiresArtwork
        self.order = order
    }
}

public enum LyricPosterMotionEffectCatalog {
    public static let all: [LyricPosterMotionEffectSpec] = [
        LyricPosterMotionEffectSpec(
            id: .none,
            nameKey: "lyric_poster_effect_none",
            symbolName: "nosign",
            order: 0
        ),
        LyricPosterMotionEffectSpec(
            id: .floatingLyrics,
            nameKey: "lyric_poster_effect_floating",
            symbolName: "arrow.up.and.down",
            order: 1
        ),
        LyricPosterMotionEffectSpec(
            id: .artworkZoom,
            nameKey: "lyric_poster_effect_zoom",
            symbolName: "arrow.up.left.and.arrow.down.right",
            requiresArtwork: true,
            order: 2
        ),
        LyricPosterMotionEffectSpec(
            id: .particles,
            nameKey: "lyric_poster_effect_particles",
            symbolName: "sparkles",
            order: 3
        ),
        LyricPosterMotionEffectSpec(
            id: .waveform,
            nameKey: "lyric_poster_effect_waveform",
            symbolName: "waveform",
            order: 4
        ),
    ]

    public static func available(hasArtwork: Bool) -> [LyricPosterMotionEffectSpec] {
        all.filter { hasArtwork || !$0.requiresArtwork }.sorted { $0.order < $1.order }
    }

    public static func spec(for id: LyricPosterMotionEffectID) -> LyricPosterMotionEffectSpec {
        all.first { $0.id == id } ?? all[0]
    }

    /// 存下来的偏好换一首没封面的歌就可能失效，这时退回"不动"而不是
    /// 让画面里出现一个推不动的空框。
    public static func resolved(
        preferred: LyricPosterMotionEffectID?,
        hasArtwork: Bool
    ) -> LyricPosterMotionEffectSpec {
        let usable = available(hasArtwork: hasArtwork)
        if let preferred, let match = usable.first(where: { $0.id == preferred }) {
            return match
        }
        return usable.first ?? all[0]
    }
}

/// 一颗粒子在某一帧的状态，坐标是画布的比例（0…1）。
public struct LyricPosterParticle: Hashable, Sendable {
    public let x: Double
    public let y: Double
    /// 相对基准直径的倍数。
    public let size: Double
    public let opacity: Double

    public init(x: Double, y: Double, size: Double, opacity: Double) {
        self.x = x
        self.y = y
        self.size = size
        self.opacity = opacity
    }
}

/// 动效的运动本身。
///
/// 每个函数都是时间的纯函数，不留状态 —— 导出时是一帧一帧独立渲染的，
/// 任何"上一帧加一点"的写法都会让导出的动画和预览对不上。
public enum LyricPosterMotionPhysics {
    /// 歌词浮动：返回 -1…1，渲染层乘上自己的振幅。
    public static func floatOffset(lineIndex: Int, at time: TimeInterval) -> Double {
        // 每行错开相位，整段歌词就不会像一整块板子上下平移。
        let phase = Double(lineIndex) * 0.9
        return sin(time * 1.7 + phase)
    }

    /// 封面推近：1 → 1 + amount，线性推到底再停住。
    public static func artworkZoom(
        at time: TimeInterval,
        duration: TimeInterval,
        amount: Double = 0.09
    ) -> Double {
        guard duration > 0 else { return 1 }
        let progress = min(max(time / duration, 0), 1)
        return 1 + amount * progress
    }

    /// 第 `index` 颗粒子在 `time` 的状态。
    public static func particle(
        index: Int,
        at time: TimeInterval,
        duration: TimeInterval
    ) -> LyricPosterParticle {
        let seedX = noise(index &* 3 &+ 11)
        let seedSpeed = noise(index &* 7 &+ 23)
        let seedSize = noise(index &* 13 &+ 37)
        let seedPhase = noise(index &* 17 &+ 51)

        // 每颗粒子跑完全程的时间在 0.7…1.6 个时长之间，快慢错开。
        let travel = duration > 0 ? duration * (0.7 + seedSpeed * 0.9) : 1
        let progress = ((time / travel) + seedPhase).truncatingRemainder(dividingBy: 1)
        // 自下而上。
        let y = 1 - progress
        // 边飘边横向摆一点，纯直线上升像下雨倒放。
        let drift = sin(progress * 6.0 + seedPhase * 6.28) * 0.04
        let x = min(max(seedX + drift, 0), 1)
        // 两端淡入淡出，粒子不会在画面边缘突然出现或消失。
        let opacity = sin(progress * .pi)
        let size = 0.5 + seedSize * 0.9
        return LyricPosterParticle(x: x, y: y, size: size, opacity: opacity)
    }

    /// 第 `index` 根声波柱的高度，0…1。
    public static func waveformBar(index: Int, count: Int, at time: TimeInterval) -> Double {
        guard count > 0 else { return 0 }
        let position = count > 1 ? Double(index) / Double(count - 1) : 0.5
        // 中间高两边低，像一段被窗函数包住的波形。
        let envelope = 0.35 + 0.65 * sin(position * .pi)
        let wave = sin(time * 5.2 + Double(index) * 0.55)
        let secondary = sin(time * 2.7 + Double(index) * 0.21)
        let combined = (wave * 0.6 + secondary * 0.4 + 1) / 2
        return min(max(combined * envelope, 0.05), 1)
    }

    /// 固定种子的伪随机，0…1。粒子的分布必须每次都一样，否则同一段动画
    /// 每次导出都不同。
    private static func noise(_ seed: Int) -> Double {
        var value = UInt64(bitPattern: Int64(seed &* 2_654_435_761 &+ 1))
        value ^= value >> 33
        value = value &* 0xff51_afd7_ed55_8ccd
        value ^= value >> 29
        value = value &* 0xc4ce_b9fe_1a85_ec53
        value ^= value >> 32
        return Double(value % 100_000) / 100_000
    }
}
