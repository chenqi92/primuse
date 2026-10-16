import Foundation

/// 全屏效果里当前句的逐字动效：唱到哪个字，哪个字就被一道浪尖托起 —— 字从起笔方向亮起，
/// 同时浮起、略微放大、带一圈主题色的光；唱完后半秒内落回原位、光散去，只留下唱过的亮色。
/// 整句看起来是一道浪从句首推到句尾，浪尖始终落在正在唱的那个字上。
///
/// 和播放页歌词的逐字效果不同：那边唱过的字一直浮着、整句唱完才一起落回；这里只有浪尖附近的
/// 几个字是起来的，大字号铺满屏幕时一整句都浮着会显得乱。
///
/// 另外两处细节：
/// - **长音**：一个字唱得越久，浪尖越高、越亮（拖长的那一声在画面上「撑」起来）；
/// - **预备**：下一个字开唱前的一小段先微微提亮，给视线一个落点，快歌里不至于追不上。
///
/// 这里只算每个字此刻的状态，绘制交给界面；所有输出都是 0…1 或相对字号的比例，便于测。
public enum ImmersiveSyllableCrestPolicy {
    /// 浪尖升到最高用的时长。很短的字（快歌、Rap）来不及升满，浪就低一些，不会一闪一闪。
    public static let crestAttack: TimeInterval = 0.10
    /// 字唱完后浪尖落回、光散去用的时长。
    public static let crestRelease: TimeInterval = 0.5
    /// 开唱前多久开始提亮。
    public static let anticipationLead: TimeInterval = 0.22
    /// 唱满多久以后算长音开始加成、到多久加满。
    public static let holdOnset: TimeInterval = 0.6
    public static let holdFull: TimeInterval = 1.8

    /// 浪尖的上浮高度（相对字号），以及长音最多再加多少。
    public static let liftRatio = 0.085
    public static let holdLiftRatio = 0.045
    /// 浪尖的放大比例，以及长音最多再加多少。每个字绕自己的中心放大会挤占字间空隙，所以给得很少。
    public static let swell = 0.035
    public static let holdSwell = 0.035
    /// 光最亮时的半径（相对字号）。
    public static let glowRadiusRatio = 0.22
    /// 没唱到的字的不透明度，以及预备提亮最多加到多少。
    public static let restingOpacity = 0.4
    public static let anticipationOpacityBoost = 0.18

    /// 一个字此刻的状态。
    public struct Appearance: Equatable, Sendable {
        /// 字内从起笔方向亮起的比例。
        public var fill: Double
        /// 浪尖强度：上浮、放大、光都按它缩放。
        public var crest: Double
        /// 长音加成。
        public var hold: Double
        /// 开唱前的预备提亮。
        public var anticipation: Double

        public init(fill: Double, crest: Double, hold: Double, anticipation: Double) {
            self.fill = fill
            self.crest = crest
            self.hold = hold
            self.anticipation = anticipation
        }

        public static let resting = Appearance(fill: 0, crest: 0, hold: 0, anticipation: 0)

        /// 上浮高度，相对字号（向上为正）。
        public var lift: Double {
            (ImmersiveSyllableCrestPolicy.liftRatio + ImmersiveSyllableCrestPolicy.holdLiftRatio * hold) * crest
        }

        /// 放大倍数。
        public var scale: Double {
            1 + (ImmersiveSyllableCrestPolicy.swell + ImmersiveSyllableCrestPolicy.holdSwell * hold) * crest
        }

        /// 光的强度。长音的光更足。
        public var glow: Double {
            crest * (0.6 + 0.4 * hold)
        }

        /// 还没亮起那部分的不透明度。
        public var restingOpacity: Double {
            ImmersiveSyllableCrestPolicy.restingOpacity
                + ImmersiveSyllableCrestPolicy.anticipationOpacityBoost * anticipation
        }
    }

    /// 一句里每个字此刻的状态。字的结束时间按播放页同一套规则推断（只记了开始时间的格式）。
    public static func appearances(
        for syllables: [LyricSyllable],
        at time: TimeInterval
    ) -> [Appearance] {
        syllables.indices.map { index in
            let syllable = syllables[index]
            let nextStart = syllables.indices.contains(index + 1) ? syllables[index + 1].start : nil
            let end = LyricSyllablePlaybackTimingPolicy.effectiveEnd(
                for: syllable,
                nextSyllableStart: nextStart
            )
            return appearance(start: syllable.start, end: end, at: time)
        }
    }

    /// 一个字（`start` 到 `end`）在 `time` 时的状态。
    public static func appearance(
        start: TimeInterval,
        end: TimeInterval,
        at time: TimeInterval
    ) -> Appearance {
        guard start.isFinite, end.isFinite, time.isFinite else { return .resting }
        let duration = max(end - start, 0)

        if time < start {
            let ahead = start - time
            guard ahead < anticipationLead else { return .resting }
            return Appearance(fill: 0, crest: 0, hold: 0, anticipation: 1 - ahead / anticipationLead)
        }

        let fill: Double
        if duration <= 0 || time >= end {
            fill = 1
        } else {
            let progress = (time - start) / duration
            fill = 1 - (1 - progress) * (1 - progress)
        }

        let sung = min(time, max(end, start)) - start
        let peak = easeOutCubic(min(1, sung / crestAttack))
        let hold = smoothstep(min(1, max(0, (sung - holdOnset) / (holdFull - holdOnset))))

        guard time >= end else {
            return Appearance(fill: fill, crest: peak, hold: hold, anticipation: 0)
        }
        let released = (time - end) / crestRelease
        guard released < 1 else {
            return Appearance(fill: 1, crest: 0, hold: hold, anticipation: 0)
        }
        return Appearance(fill: 1, crest: peak * (1 - smoothstep(released)), hold: hold, anticipation: 0)
    }

    /// 浪尖、光最多会画出字框多远（相对字号）。绘制区域按它留边，免得被裁掉。
    public static var maximumOverhangRatio: Double {
        max(liftRatio + holdLiftRatio, glowRadiusRatio) * 2
    }

    private static func easeOutCubic(_ value: Double) -> Double {
        let inverse = 1 - value
        return 1 - inverse * inverse * inverse
    }

    private static func smoothstep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}
