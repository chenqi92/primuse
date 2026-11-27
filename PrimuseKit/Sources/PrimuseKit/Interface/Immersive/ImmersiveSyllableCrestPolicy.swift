import Foundation

/// 全屏效果里当前句的逐字动效：唱到哪个字，哪个字就被一道浪尖托起 —— 字从起笔方向亮起，
/// 同时浮起、略微放大、带一圈主题色的光；唱完后半秒内落回原位、光散去，只留下唱过的亮色。
/// 整句看起来是一道浪从句首推到句尾，浪尖始终落在正在唱的那个字上。
///
/// 和播放页歌词的逐字效果不同：那边唱过的字一直浮着、整句唱完才一起落回；这里只有浪尖附近的
/// 几个字是起来的，大字号铺满屏幕时一整句都浮着会显得乱。
///
/// 另外一处细节：**预备**：下一个字开唱前的一小段先微微提亮，给视线一个落点，快歌里不至于追不上。
///
/// 浪尖的高低、亮度对每个字都一样，不看这个字唱多久（以前有「长音更高更亮」的加成，已去掉）：
/// 「按字的演唱时长分两种显示」是 US12592007B2 独立权利要求里的一项，见 `LyricSyllableEmphasisPolicy.glow`。
///
/// 这里只算每个字此刻的状态，绘制交给界面；所有输出都是 0…1 或相对字号的比例，便于测。
public enum ImmersiveSyllableCrestPolicy {
    /// 浪尖升到最高用的时长。按开唱后过了多久算，不按这个字唱到哪儿为止：很短的字唱完了浪尖照样升满再落回。
    public static let crestAttack: TimeInterval = 0.10
    /// 字唱完后浪尖落回、光散去用的时长。
    public static let crestRelease: TimeInterval = 0.5
    /// 开唱前多久开始提亮。
    public static let anticipationLead: TimeInterval = 0.22
    /// 浪尖的上浮高度（相对字号）。
    public static let liftRatio = 0.085
    /// 浪尖的放大比例。每个字绕自己的中心放大会挤占字间空隙，所以给得很少。
    public static let swell = 0.035
    /// 浪尖最高时光的强度。
    public static let glowStrength = 0.75
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
        /// 开唱前的预备提亮。
        public var anticipation: Double

        public init(fill: Double, crest: Double, anticipation: Double) {
            self.fill = fill
            self.crest = crest
            self.anticipation = anticipation
        }

        public static let resting = Appearance(fill: 0, crest: 0, anticipation: 0)

        /// 上浮高度，相对字号（向上为正）。
        public var lift: Double {
            ImmersiveSyllableCrestPolicy.liftRatio * crest
        }

        /// 放大倍数。
        public var scale: Double {
            1 + ImmersiveSyllableCrestPolicy.swell * crest
        }

        /// 光的强度。
        public var glow: Double {
            crest * ImmersiveSyllableCrestPolicy.glowStrength
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
            return Appearance(fill: 0, crest: 0, anticipation: 1 - ahead / anticipationLead)
        }

        let fill: Double
        if duration <= 0 || time >= end {
            fill = 1
        } else {
            let progress = (time - start) / duration
            fill = 1 - (1 - progress) * (1 - progress)
        }

        // 按开唱后过了多久升浪尖，不在字的结尾处截住：截住的话越短的字浪越低，又成了按时长分档。
        let peak = easeOutCubic(min(1, (time - start) / crestAttack))

        guard time >= end else {
            return Appearance(fill: fill, crest: peak, anticipation: 0)
        }
        let released = (time - end) / crestRelease
        guard released < 1 else {
            return Appearance(fill: 1, crest: 0, anticipation: 0)
        }
        return Appearance(fill: 1, crest: peak * (1 - smoothstep(released)), anticipation: 0)
    }

    /// 浪尖、光最多会画出字框多远（相对字号）。绘制区域按它留边，免得被裁掉。
    public static var maximumOverhangRatio: Double {
        max(liftRatio, glowRadiusRatio) * 2
    }

    private static func easeOutCubic(_ value: Double) -> Double {
        let inverse = 1 - value
        return 1 - inverse * inverse * inverse
    }

    private static func smoothstep(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }
}
