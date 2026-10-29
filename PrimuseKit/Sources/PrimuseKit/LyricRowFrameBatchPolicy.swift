import Foundation

public enum LyricRowFrameBatchPolicy {
    public static func merging<Frame>(
        id: String,
        frame: Frame,
        into current: [String: Frame],
        retaining validIDs: Set<String>
    ) -> [String: Frame] {
        var next = current.filter { validIDs.contains($0.key) }
        guard validIDs.contains(id) else { return next }
        next[id] = frame
        return next
    }
}

public enum LyricRowLayoutPolicy {
    /// Returns the stable, unscaled text width that keeps a render-layer scale
    /// inside the lyric viewport. Reserving this width for every row also keeps
    /// line wrapping unchanged when playback emphasis moves between rows.
    public static func unscaledContentWidth(
        viewportWidth: Double,
        horizontalPadding: Double,
        maximumVisualScale: Double
    ) -> Double {
        let viewport = viewportWidth.isFinite ? max(0, viewportWidth) : 0
        let padding = horizontalPadding.isFinite ? max(0, horizontalPadding) : 0
        let scale = maximumVisualScale.isFinite ? max(1, maximumVisualScale) : 1
        return max(0, viewport - padding * 2) / scale
    }
}

public enum LyricDepthEffectPolicy {
    private static let radiusStep = 1.25
    private static let maximumRadius = 5.0
    private static let passedLineDepthOffset = 1

    /// Keeps the upcoming lyric readable while pushing already-sung rows one
    /// depth step farther away. The linear progression gives every takeover a
    /// visible focus change, then caps the cost for distant rows.
    public static func blurRadius(
        forRow rowIndex: Int,
        activeRow activeIndex: Int,
        isEnabled: Bool,
        isSynchronized: Bool
    ) -> Double {
        guard isEnabled,
              isSynchronized,
              rowIndex >= 0,
              activeIndex >= 0,
              rowIndex != activeIndex else { return 0 }

        let distance = abs(rowIndex - activeIndex)
        let depth = distance + (rowIndex < activeIndex ? passedLineDepthOffset : 0)
        return min(maximumRadius, Double(depth) * radiusStep)
    }
}

/// 歌词「层叠弹性」滚动：换句时不再整份歌词一起平移，而是每一行各自像弹簧一样跟上来 ——
/// 唱过的几句和当前句先走，往下的每一行比上一行晚一点出发，读起来是一行接一行地落位；
/// 离当前句越远越淡（虚化沿用 `LyricDepthEffectPolicy`）。
///
/// 这里只算每一行晚多久出发、淡到几成、这一次换句该不该走层叠；位移由界面做。强调只看行与
/// 当前句隔了几行，不看哪个字唱多久。
public enum LyricCascadeMotionPolicy {
    /// 当前句往下，每一行比上一行晚出发多久。
    public static let rowDelayStep: TimeInterval = 0.045
    /// 最多晚几行：再往下的行和这一行同时出发，长歌词底下不会拖出一长串尾巴。
    public static let maximumDelayedRows = 8
    /// 每一行跟上来用的弹簧（SwiftUI `spring(response:dampingFraction:)` 的两个参数）：
    /// 只过冲一点，约半秒落稳。
    public static let springResponse: Double = 0.58
    public static let springDampingFraction: Double = 0.82
    /// 两次层叠至少隔多久。上一次还没落稳又换句（快歌、Rap）时这一次照旧整体平滑滚动，
    /// 免得还在路上的行被拽回去重来。
    public static let minimumInterval: TimeInterval = 0.9
    /// 一次滚动超过视口这么多（拖动进度条、跳到很远的一句）就不走层叠，直接整体滚过去。
    public static let maximumViewportFraction = 0.75
    /// 离当前句每远一行淡多少，以及最淡淡到几成。当前句与上下相邻的一行不淡。
    public static let depthOpacityStep = 0.14
    public static let minimumDepthOpacity = 0.4

    /// 这一行晚多久出发。当前句和它上面（唱过的）几行不等。
    public static func delay(forRow row: Int, activeRow: Int) -> TimeInterval {
        guard activeRow >= 0 else { return 0 }
        let distance = row - activeRow
        guard distance > 0 else { return 0 }
        return Double(min(distance, maximumDelayedRows)) * rowDelayStep
    }

    /// 这一行在原有明暗上再乘多少。没有当前句（前奏、没同步）时都是 1。
    public static func depthOpacity(forRow row: Int, activeRow: Int) -> Double {
        guard activeRow >= 0, row >= 0 else { return 1 }
        let distance = abs(row - activeRow)
        guard distance > 1 else { return 1 }
        return max(minimumDepthOpacity, 1 - depthOpacityStep * Double(distance - 1))
    }

    /// 这次换句走不走层叠。
    /// - Parameters:
    ///   - scrollDistance: 这次要滚多远（内容偏移的差，往上滚为正）。
    ///   - viewportHeight: 歌词视口的高度。
    ///   - sinceLastCascade: 离上一次层叠过了多久。
    public static func shouldCascade(
        scrollDistance: Double,
        viewportHeight: Double,
        sinceLastCascade: TimeInterval
    ) -> Bool {
        guard scrollDistance.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return false }
        let distance = abs(scrollDistance)
        return distance >= 1
            && distance <= viewportHeight * maximumViewportFraction
            && sinceLastCascade >= minimumInterval
    }
}

/// 换句时的缩放脉冲。范围固定，排版可以提前留足空间，不随动画重新折行。
public enum LyricPulseMotionPolicy {
    public static let duration: TimeInterval = 0.72
    public static let maximumScale = 1.10
    public static let minimumScale = 0.975

    public static func scale(at progress: Double, isEnabled: Bool = true) -> Double {
        guard isEnabled, progress.isFinite, progress > 0, progress < 1 else { return 1 }
        let start: Double
        let end: Double
        let fraction: Double
        if progress < 0.28 {
            start = 1
            end = maximumScale
            fraction = progress / 0.28
        } else if progress < 0.65 {
            start = maximumScale
            end = minimumScale
            fraction = (progress - 0.28) / 0.37
        } else {
            start = minimumScale
            end = 1
            fraction = (progress - 0.65) / 0.35
        }
        let eased = fraction * fraction * (3 - 2 * fraction)
        return start + (end - start) * eased
    }
}

public enum LyricPlaybackPositionPolicy {
    public enum ScrollTarget: Equatable, Sendable {
        case line(Int)
        case interlude(afterLine: Int)
        /// 第一句之前的前奏。
        case intro
    }

    public static func shouldFollowPlayback(in lyrics: [LyricLine]) -> Bool {
        shouldFollowPlayback(in: lyrics, isSynchronized: \.isSynchronized)
    }

    public static func shouldFollowPlayback<Element>(
        in lyrics: [Element],
        isSynchronized: (Element) -> Bool
    ) -> Bool {
        !lyrics.isEmpty && lyrics.allSatisfy(isSynchronized)
    }

    /// Returns the lyric row that should be active at the supplied playback
    /// time, or `nil` while playback is still before the first timestamp.
    /// Parsed lyric lines are expected to be ordered by timestamp.
    ///
    /// 同一个时间戳上留了好几行时（没能配对的双语 LRC、多声部叠唱）高亮落在
    /// 这一组的第一行：唱的是原文，注音和译文写在它后面。
    public static func activeLineIndex(
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0
    ) -> Int? {
        activeLineIndex(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead,
            timestamp: \.timestamp
        )
    }

    public static func activeLineIndex<Element>(
        in lyrics: [Element],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        timestamp: (Element) -> TimeInterval
    ) -> Int? {
        guard !lyrics.isEmpty else { return nil }

        let target = playbackTime + lookahead
        var lower = 0
        var upper = lyrics.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timestamp(lyrics[middle]) <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        var index = lower - 1
        let activeTimestamp = timestamp(lyrics[index])
        while index > 0,
              abs(activeTimestamp - timestamp(lyrics[index - 1])) <= sameRowTolerance {
            index -= 1
        }
        return index
    }

    /// 同一句的几行来自同一个 `[mm:ss.xx]`，解析出来本应完全相等；留一点余量
    /// 是为了写成 `[00:12.00]` 和 `[00:12.001]` 这种手抄的文件。与
    /// `LyricBilingualPairingPolicy` 判定同一簇用的余量一致。
    static let sameRowTolerance: TimeInterval = 0.002

    /// Companion rows share the source timestamp and must not end its word
    /// sweep. Only a later timestamp group can take over the highlight.
    public static func wordLevelDeactivationTime(
        in lyrics: [LyricLine],
        afterLine index: Int,
        lookahead: TimeInterval = 0
    ) -> TimeInterval? {
        guard lyrics.indices.contains(index) else { return nil }
        let currentStart = lyrics[index].timestamp
        guard let next = lyrics.dropFirst(index + 1).first(where: {
            $0.timestamp - currentStart > sameRowTolerance
        }) else { return nil }
        return max(currentStart, next.timestamp - max(0, lookahead))
    }

    /// 间奏判定用的几个时长。逐字歌词(或带结束时间的行、标出间奏的空行)知道人声什么时候停,
    /// 门槛可以低;普通 LRC 只有每句的开始时间,唱完的时刻是估出来的,门槛放低会把句间换气也当成间奏。
    public struct InterludeTiming: Equatable, Sendable {
        /// 没有结束时间的一句按唱这么久估算。
        public var lineLevelEstimatedDuration: TimeInterval
        /// 估出来的结束到下一句至少空这么久才算间奏。
        public var lineLevelMinimumGap: TimeInterval
        /// 估出来的结束之后再等这么久才出现提示,免得一句还没唱完就换成点。
        public var lineLevelActivationDelay: TimeInterval
        /// 知道人声结束时间时,空这么久就算间奏。
        public var timedMinimumGap: TimeInterval
        /// 人声停下后隔这么久出现提示,让上一句先淡出。
        public var timedActivationDelay: TimeInterval
        /// 第一句前空这么久才算前奏。第一句的开始时间在哪种格式里都可靠。
        public var minimumIntro: TimeInterval
        /// 下一句开始前这么久进入「快要唱了」的心跳。
        public var anticipation: TimeInterval

        public init(
            lineLevelEstimatedDuration: TimeInterval = 3.5,
            lineLevelMinimumGap: TimeInterval = 12,
            lineLevelActivationDelay: TimeInterval = 6,
            timedMinimumGap: TimeInterval = 4,
            timedActivationDelay: TimeInterval = 0.6,
            minimumIntro: TimeInterval = 5,
            anticipation: TimeInterval = 0.8
        ) {
            self.lineLevelEstimatedDuration = lineLevelEstimatedDuration
            self.lineLevelMinimumGap = lineLevelMinimumGap
            self.lineLevelActivationDelay = lineLevelActivationDelay
            self.timedMinimumGap = timedMinimumGap
            self.timedActivationDelay = timedActivationDelay
            self.minimumIntro = minimumIntro
            self.anticipation = anticipation
        }

        public static let standard = InterludeTiming()
    }

    /// 一段间奏(或前奏)的时间窗。
    public struct InterludeWindow: Equatable, Sendable {
        /// 跟在哪一句后面;nil 表示第一句之前的前奏。
        public let afterLine: Int?
        /// 人声停下的时刻(前奏是 0)。
        public let vocalsEnd: TimeInterval
        /// 提示出现的时刻。
        public let activation: TimeInterval
        /// 下一句开始的时刻。
        public let nextLineStart: TimeInterval

        public init(
            afterLine: Int?,
            vocalsEnd: TimeInterval,
            activation: TimeInterval,
            nextLineStart: TimeInterval
        ) {
            self.afterLine = afterLine
            self.vocalsEnd = vocalsEnd
            self.activation = activation
            self.nextLineStart = nextLineStart
        }
    }

    /// 提示点此刻走到哪:从出现到下一句开始走了多少(0…1),以及离下一句开始还有几秒。
    public struct InterludePhase: Equatable, Sendable {
        public let progress: Double
        public let secondsUntilNextLine: TimeInterval

        public init(progress: Double, secondsUntilNextLine: TimeInterval) {
            self.progress = progress
            self.secondsUntilNextLine = secondsUntilNextLine
        }

        public static let idle = InterludePhase(progress: 0, secondsUntilNextLine: .infinity)
    }

    /// Keeps the semantic active row unchanged during a long instrumental
    /// break while allowing a lyrics surface to move to a dedicated interlude
    /// marker. Line-level lyrics have no explicit end time, so their visible
    /// singing window is conservatively estimated before the break begins.
    /// 第一句之前的前奏够长时返回 `.intro`。
    public static func scrollTarget(
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        timing: InterludeTiming = .standard
    ) -> ScrollTarget? {
        scrollTarget(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead,
            timing: timing,
            timestamp: \.timestamp,
            vocalEnd: vocalEnd(of:),
            isBlank: isBlankLine
        )
    }

    /// 自己存歌词行的界面(电视)用的同一份判定:每一行的开始时间、人声唱到什么时候
    /// (`vocalEnd(lineEnd:backgroundEnds:)`)、是不是空行(`isInterludeBlank(text:hasBackground:)`)
    /// 由调用方取,门槛与时刻和 `LyricLine` 那一份完全相同。
    public static func scrollTarget<Element>(
        in lyrics: [Element],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        timing: InterludeTiming = .standard,
        timestamp: (Element) -> TimeInterval,
        vocalEnd: (Element) -> TimeInterval?,
        isBlank: (Element) -> Bool
    ) -> ScrollTarget? {
        guard let window = activeInterlude(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead,
            timing: timing,
            timestamp: timestamp,
            vocalEnd: vocalEnd,
            isBlank: isBlank
        ) else {
            return activeLineIndex(
                in: lyrics,
                at: playbackTime,
                lookahead: lookahead,
                timestamp: timestamp
            ).map { .line($0) }
        }
        guard let afterLine = window.afterLine else { return .intro }
        return .interlude(afterLine: afterLine)
    }

    /// 此刻正在显示提示的那段间奏或前奏;没有就是 nil。时间窗和 `scrollTarget` 是同一个。
    public static func activeInterlude(
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        timing: InterludeTiming = .standard
    ) -> InterludeWindow? {
        activeInterlude(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead,
            timing: timing,
            timestamp: \.timestamp,
            vocalEnd: vocalEnd(of:),
            isBlank: isBlankLine
        )
    }

    /// 见 `scrollTarget(in:at:lookahead:timing:timestamp:vocalEnd:isBlank:)`。
    public static func activeInterlude<Element>(
        in lyrics: [Element],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        timing: InterludeTiming = .standard,
        timestamp: (Element) -> TimeInterval,
        vocalEnd: (Element) -> TimeInterval?,
        isBlank: (Element) -> Bool
    ) -> InterludeWindow? {
        guard playbackTime.isFinite else { return nil }
        let targetTime = playbackTime + max(0, lookahead)
        let window: InterludeWindow?
        if let activeIndex = activeLineIndex(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead,
            timestamp: timestamp
        ), !isLeadingBlank(activeIndex, in: lyrics, isBlank: isBlank) {
            window = interludeWindow(
                afterLine: activeIndex,
                in: lyrics,
                timing: timing,
                timestamp: timestamp,
                vocalEnd: vocalEnd,
                isBlank: isBlank
            )
        } else {
            // 第一句之前(包括开头那几个空时间标签)都算前奏。
            window = introWindow(in: lyrics, timing: timing, timestamp: timestamp, isBlank: isBlank)
        }
        guard let window,
              targetTime >= window.activation,
              targetTime < window.nextLineStart else { return nil }
        return window
    }

    public static func hasLongInterlude(
        afterLine index: Int,
        in lyrics: [LyricLine],
        timing: InterludeTiming = .standard
    ) -> Bool {
        interludeWindow(afterLine: index, in: lyrics, timing: timing) != nil
    }

    /// 第一句前有没有够长的前奏。
    public static func hasIntro(
        in lyrics: [LyricLine],
        timing: InterludeTiming = .standard
    ) -> Bool {
        introWindow(in: lyrics, timing: timing) != nil
    }

    /// 间奏提示点从出现到下一句开始走了多少(0…1)。时间窗和 `scrollTarget` 一致;之前为 0、之后为 1。
    /// 这一句后面没有长间奏时为 nil。
    public static func interludeProgress(
        afterLine index: Int,
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        timing: InterludeTiming = .standard
    ) -> Double? {
        interludeWindow(afterLine: index, in: lyrics, timing: timing)
            .map { phase(of: $0, at: playbackTime).progress }
    }

    /// 这段间奏此刻的进度与离下一句还有几秒。`lookahead` 与滚动用的一致时,
    /// 心跳正好在提示点让位给下一句的那一刻停下。
    public static func phase(
        of window: InterludeWindow,
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0
    ) -> InterludePhase {
        guard playbackTime.isFinite else { return .idle }
        let targetTime = playbackTime + max(0, lookahead)
        let span = window.nextLineStart - window.activation
        let progress: Double
        if span > 0 {
            progress = min(max((targetTime - window.activation) / span, 0), 1)
        } else {
            progress = targetTime >= window.nextLineStart ? 1 : 0
        }
        return InterludePhase(
            progress: progress,
            secondsUntilNextLine: max(window.nextLineStart - targetTime, 0)
        )
    }

    /// 间奏三个点各亮到多少(0…1):按进度依次点亮,第一个在前三分之一里亮满,依此类推。
    public static func interludeDotLevels(progress: Double, count: Int = 3) -> [Double] {
        let p = min(max(progress.isFinite ? progress : 0, 0), 1) * Double(count)
        return (0..<count).map { min(max(p - Double($0), 0), 1) }
    }

    /// 下一句开始前那一小段的心跳:两下一大一小的脉冲,只在 `timing.anticipation` 秒内,
    /// 下一句开始(`secondsUntilNextLine` 为 0)时已经回到 1。之外一律是 1,所以绝不会在开唱后才跳。
    public static func interludeHeartbeatScale(
        secondsUntilNextLine: TimeInterval,
        timing: InterludeTiming = .standard
    ) -> Double {
        let window = timing.anticipation
        guard window > 0,
              secondsUntilNextLine.isFinite,
              secondsUntilNextLine > 0,
              secondsUntilNextLine <= window else { return 1 }
        let u = 1 - secondsUntilNextLine / window
        func pulse(_ center: Double, _ width: Double) -> Double {
            let d = (u - center) / width
            return exp(-d * d)
        }
        let beat = 0.16 * pulse(0.3, 0.085) + 0.11 * pulse(0.62, 0.085)
        // 尾端收成 0,开唱那一刻不留残余的放大。
        let tail = min(max((1 - u) / 0.12, 0), 1)
        return 1 + beat * tail
    }

    /// 某一句后面那段间奏的时间窗;不够长(或后面没有下一句)时为 nil。
    public static func interludeWindow(
        afterLine index: Int,
        in lyrics: [LyricLine],
        timing: InterludeTiming = .standard
    ) -> InterludeWindow? {
        interludeWindow(
            afterLine: index,
            in: lyrics,
            timing: timing,
            timestamp: \.timestamp,
            vocalEnd: vocalEnd(of:),
            isBlank: isBlankLine
        )
    }

    /// 见 `scrollTarget(in:at:lookahead:timing:timestamp:vocalEnd:isBlank:)`。
    public static func interludeWindow<Element>(
        afterLine index: Int,
        in lyrics: [Element],
        timing: InterludeTiming = .standard,
        timestamp: (Element) -> TimeInterval,
        vocalEnd: (Element) -> TimeInterval?,
        isBlank: (Element) -> Bool
    ) -> InterludeWindow? {
        guard lyrics.indices.contains(index) else { return nil }

        let lineStart = timestamp(lyrics[index])
        // 开头那几个空时间标签属于前奏(见 `introWindow`)。
        guard lineStart.isFinite, !isLeadingBlank(index, in: lyrics, isBlank: isBlank) else { return nil }
        // 同一时间戳上的兄弟行(注音、译文、另一个声部)不是「下一句」,
        // 拿它们当下一句会把每一段间奏的时长算成 0。它们的结束时间算进这一句。
        var groupEnd = index
        while groupEnd + 1 < lyrics.count,
              timestamp(lyrics[groupEnd + 1]) - lineStart <= sameRowTolerance {
            groupEnd += 1
        }
        guard groupEnd + 1 < lyrics.count else { return nil }
        let nextLineStart = timestamp(lyrics[groupEnd + 1])
        guard nextLineStart.isFinite else { return nil }

        let group = lyrics[index...groupEnd]
        let groupIsBlank = group.allSatisfy(isBlank)
        let explicitEnds = group.compactMap(vocalEnd).filter(\.isFinite)
        let vocalsEnd: TimeInterval
        let minimumGap: TimeInterval
        let activationDelay: TimeInterval
        if groupIsBlank {
            // 在间奏开头打的空行:这一刻人声已经停了。.lrc 里的空时间标签解析时就丢掉了,
            // 那种歌走不到这里,按估算的门槛算。
            vocalsEnd = lineStart
            minimumGap = timing.timedMinimumGap
            activationDelay = timing.timedActivationDelay
        } else if let explicitEnd = explicitEnds.max() {
            vocalsEnd = max(lineStart, explicitEnd)
            minimumGap = timing.timedMinimumGap
            activationDelay = timing.timedActivationDelay
        } else {
            vocalsEnd = lineStart + max(0, timing.lineLevelEstimatedDuration)
            minimumGap = timing.lineLevelMinimumGap
            activationDelay = timing.lineLevelActivationDelay
        }
        guard vocalsEnd.isFinite,
              nextLineStart - vocalsEnd >= max(0, minimumGap) else { return nil }

        return InterludeWindow(
            afterLine: index,
            vocalsEnd: vocalsEnd,
            activation: vocalsEnd + max(0, activationDelay),
            nextLineStart: nextLineStart
        )
    }

    /// 第一句之前的前奏;第一句来得早时为 nil。
    public static func introWindow(
        in lyrics: [LyricLine],
        timing: InterludeTiming = .standard
    ) -> InterludeWindow? {
        introWindow(in: lyrics, timing: timing, timestamp: \.timestamp, isBlank: isBlankLine)
    }

    /// 见 `scrollTarget(in:at:lookahead:timing:timestamp:vocalEnd:isBlank:)`。
    public static func introWindow<Element>(
        in lyrics: [Element],
        timing: InterludeTiming = .standard,
        timestamp: (Element) -> TimeInterval,
        isBlank: (Element) -> Bool
    ) -> InterludeWindow? {
        guard let first = lyrics.first(where: { !isBlank($0) }) else { return nil }
        let firstStart = timestamp(first)
        guard firstStart.isFinite,
              firstStart >= max(0, timing.minimumIntro) else { return nil }
        return InterludeWindow(
            afterLine: nil,
            vocalsEnd: 0,
            activation: 0,
            nextLineStart: firstStart
        )
    }

    /// 没有字也没有和声的行:标出间奏的空行。
    public static func isInterludeBlank(text: String, hasBackground: Bool) -> Bool {
        !hasBackground && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 一句人声唱到什么时候:这一行的结束时间(行末与最后一个字取较晚者),以及和声里最晚的那个。
    /// 都不知道时为 nil,按普通 LRC 估算。
    public static func vocalEnd(
        lineEnd: TimeInterval?,
        backgroundEnds: [TimeInterval?]
    ) -> TimeInterval? {
        ([lineEnd] + backgroundEnds)
            .compactMap { $0 }
            .filter(\.isFinite)
            .max()
    }

    private static func isBlankLine(_ line: LyricLine) -> Bool {
        isInterludeBlank(text: line.text, hasBackground: line.background?.isEmpty == false)
    }

    /// 第一句之前的空行。
    private static func isLeadingBlank<Element>(
        _ index: Int,
        in lyrics: [Element],
        isBlank: (Element) -> Bool
    ) -> Bool {
        isBlank(lyrics[index]) && lyrics[..<index].allSatisfy(isBlank)
    }

    private static func vocalEnd(of line: LyricLine) -> TimeInterval? {
        vocalEnd(lineEnd: line.endTime, backgroundEnds: (line.background ?? []).map(\.endTime))
    }
}

/// 播放页歌名下那一行歌词(竖屏封面模式、手机横屏左栏)此刻放什么:前奏里轮换的几句提示、
/// 正在唱的那一句、间奏标签,或下一句开唱前跳动的三个点。全部由播放时间推出来,
/// 拖动、暂停、倍速之后直接重算,不靠计时器接力。
public enum NowPlayingLyricPreviewPolicy {
    /// 前奏里依次出现的提示。第一条和最后一条固定,中间轮换。
    public enum IntroMessage: CaseIterable, Equatable, Sendable {
        case starting
        case settingTheMood
        case musicTakesOver
        case almostThere
        case vocalsIncoming
    }

    public enum Display: Equatable, Sendable {
        /// 什么都不放:没有时间轴、前奏太短、句间普通的空行。
        case empty
        case line(Int)
        case intro(IntroMessage)
        case instrumental
        /// 下一句马上开始;带着这段的时间窗,视图按它算心跳。
        case anticipation(LyricPlaybackPositionPolicy.InterludeWindow)
    }

    public struct Resolution: Equatable, Sendable {
        public let display: Display
        /// 之后最早可能变的播放时刻;不知道就是 nil(照常轮询)。
        public let nextChange: TimeInterval?

        public init(display: Display, nextChange: TimeInterval?) {
            self.display = display
            self.nextChange = nextChange
        }
    }

    /// 每条前奏提示停留的时长。
    public static let introMessageInterval: TimeInterval = 2.8

    public static func resolve(
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        showsInterludes: Bool = true,
        timing: LyricPlaybackPositionPolicy.InterludeTiming = .standard
    ) -> Resolution {
        guard playbackTime.isFinite,
              lyrics.contains(where: \.isSynchronized) else {
            return Resolution(display: .empty, nextChange: nil)
        }
        let lookahead = max(0, lookahead)
        let target = playbackTime + lookahead

        if showsInterludes,
           let window = LyricPlaybackPositionPolicy.activeInterlude(
               in: lyrics,
               at: playbackTime,
               lookahead: lookahead,
               timing: timing
           ) {
            let anticipationStart = window.nextLineStart - max(0, timing.anticipation)
            if target >= anticipationStart {
                return Resolution(
                    display: .anticipation(window),
                    nextChange: window.nextLineStart - lookahead
                )
            }
            guard window.afterLine == nil else {
                return Resolution(display: .instrumental, nextChange: anticipationStart - lookahead)
            }
            let slot = introMessage(
                elapsed: target - window.activation,
                span: anticipationStart - window.activation
            )
            return Resolution(
                display: .intro(slot.message),
                nextChange: min(window.activation + slot.end, anticipationStart) - lookahead
            )
        }

        let activeIndex = LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead
        )
        // 下一组时间戳开始的时刻(它到了就换行)。
        let nextGroupStart: TimeInterval? = {
            let current = activeIndex.map { lyrics[$0].timestamp } ?? -.infinity
            return lyrics.first(where: { $0.timestamp > current + 0.002 && $0.timestamp > target })?.timestamp
        }()
        var nextChange = nextGroupStart.map { $0 - lookahead }
        if showsInterludes {
            let upcoming: LyricPlaybackPositionPolicy.InterludeWindow?
            if let activeIndex {
                upcoming = LyricPlaybackPositionPolicy.interludeWindow(afterLine: activeIndex, in: lyrics, timing: timing)
            } else {
                upcoming = LyricPlaybackPositionPolicy.introWindow(in: lyrics, timing: timing)
            }
            if let upcoming, upcoming.activation > target {
                nextChange = min(nextChange ?? .infinity, upcoming.activation - lookahead)
            }
        }

        guard let activeIndex,
              !lyrics[activeIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 第一句还没唱(前奏不够长、或关掉了间奏提示),或者停在句间的空行上:都不提前露出下一句。
            return Resolution(display: .empty, nextChange: nextChange)
        }
        return Resolution(display: .line(activeIndex), nextChange: nextChange)
    }

    /// 前奏的第几条提示,以及这一条在前奏里什么时候结束(相对提示开始)。`span` 是提示能占的总时长
    /// (到心跳开始为止)。前奏短就少放几条;最后一条总是「人声快来了」,倒数第二条是「快到了」。
    public static func introMessage(
        elapsed: TimeInterval,
        span: TimeInterval
    ) -> (message: IntroMessage, end: TimeInterval) {
        let interval = introMessageInterval
        let slots = max(1, Int((max(span, 0) / interval).rounded(.down)))
        let raw = elapsed.isFinite ? Int((max(elapsed, 0) / interval).rounded(.down)) : 0
        let slot = min(raw, slots - 1)
        let end = slot == slots - 1 ? max(span, 0) : Double(slot + 1) * interval
        let message: IntroMessage
        if slot == 0 {
            message = .starting
        } else if slot == slots - 1 {
            message = .vocalsIncoming
        } else if slot == slots - 2, slots >= 4 {
            message = .almostThere
        } else {
            message = (slot - 1).isMultiple(of: 2) ? .settingTheMood : .musicTakesOver
        }
        return (message, end)
    }
}

// MARK: - 多行

extension NowPlayingLyricPreviewPolicy {
    /// 多行时这一格里的那句是唱过的、正在唱的,还是还没到的。
    public enum LineRole: Equatable, Sendable {
        case past
        case current
        case upcoming
    }

    /// 多行时每一格放什么。
    public enum Row: Equatable, Sendable {
        case line(Int, LineRole)
        /// 放 `Display` 自己:前奏提示、间奏标签、心跳点;`.empty` 时这一格空着。
        case status
        /// 前面或后面已经没有句子可放。
        case blank
    }

    /// 正在唱的那一句(或提示)排在第几格:两行以内排第一格;三行起上面留一句唱过的,
    /// 行数再多,每多三行往上多留一句。
    public static func anchorRow(rowCount: Int) -> Int {
        rowCount <= 2 ? 0 : max(1, (rowCount - 1) / 3)
    }

    /// 多行(「封面下的歌词」选了两行以上)时每一格放什么。正在唱的那一句停在 `anchorRow` 那一格,
    /// 上面是唱过的、下面是接下来的;同一个时间戳的几行(没配成对的译文、合唱)一起算正在唱。
    /// 前奏、间奏与句间空行里那一格换成 `Display` 自己,上下照样是唱过的和接下来的,
    /// 换句时整列往上走一格。一行时和单行的显示一模一样。
    public static func rows(
        for display: Display,
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        rowCount: Int
    ) -> [Row] {
        let count = max(1, rowCount)
        guard count > 1 else {
            if case .line(let index) = display { return [.line(index, .current)] }
            return [.status]
        }
        let shown = lyrics.indices.filter {
            lyrics[$0].isSynchronized
                && lyrics[$0].timestamp.isFinite
                && !lyrics[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let past: [Int]
        let current: [Row]
        let upcoming: [Int]
        if case .line(let index) = display, lyrics.indices.contains(index) {
            let start = lyrics[index].timestamp
            let tolerance = LyricPlaybackPositionPolicy.sameRowTolerance
            past = shown.filter { lyrics[$0].timestamp < start - tolerance }
            let group = shown.filter { abs(lyrics[$0].timestamp - start) <= tolerance }
            current = (group.isEmpty ? [index] : group).map { .line($0, .current) }
            upcoming = shown.filter { lyrics[$0].timestamp > start + tolerance }
        } else {
            let target = playbackTime.isFinite ? playbackTime + max(0, lookahead) : -.infinity
            past = shown.filter { lyrics[$0].timestamp <= target }
            current = [.status]
            upcoming = shown.filter { lyrics[$0].timestamp > target }
        }
        let anchor = anchorRow(rowCount: count)
        let above = past.suffix(anchor).map { Row.line($0, .past) }
        var rows = Array(repeating: Row.blank, count: anchor - above.count) + above + current
            + upcoming.map { Row.line($0, .upcoming) }
        if rows.count > count {
            rows.removeLast(rows.count - count)
        } else if rows.count < count {
            rows += Array(repeating: Row.blank, count: count - rows.count)
        }
        return rows
    }
}

public struct NowPlayingLyricsMetadataPresentation: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let lyricLineID: String?

    public init(title: String, artist: String, lyricLineID: String?) {
        self.title = title
        self.artist = artist
        self.lyricLineID = lyricLineID
    }
}

public enum NowPlayingLyricsMetadataPolicy {
    /// Lines that can drive a lock-screen/now-playing update.
    ///
    /// The result only depends on the lyric document, so callers that refresh
    /// on a timer should filter once per song instead of once per tick.
    public static func synchronizedLines(_ lyrics: [LyricLine]) -> [LyricLine] {
        lyrics.filter {
            $0.isSynchronized
                && $0.timestamp.isFinite
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func presentation(
        canonicalTitle: String,
        artistName: String?,
        lyrics: [LyricLine],
        playbackTime: TimeInterval,
        isEnabled: Bool,
        isLiveStream: Bool,
        prefersStableTitle: Bool = false
    ) -> NowPlayingLyricsMetadataPresentation {
        presentation(
            canonicalTitle: canonicalTitle,
            artistName: artistName,
            synchronizedLyrics: synchronizedLines(lyrics),
            playbackTime: playbackTime,
            isEnabled: isEnabled,
            isLiveStream: isLiveStream,
            prefersStableTitle: prefersStableTitle
        )
    }

    /// Variant for callers that already hold `synchronizedLines(_:)` output.
    public static func presentation(
        canonicalTitle: String,
        artistName: String?,
        synchronizedLyrics: [LyricLine],
        playbackTime: TimeInterval,
        isEnabled: Bool,
        isLiveStream: Bool,
        prefersStableTitle: Bool = false
    ) -> NowPlayingLyricsMetadataPresentation {
        let title = canonicalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canonical = NowPlayingLyricsMetadataPresentation(
            title: title,
            artist: artist,
            lyricLineID: nil
        )

        guard isEnabled,
              !isLiveStream,
              playbackTime.isFinite,
              playbackTime >= 0 else { return canonical }

        guard let firstLine = synchronizedLyrics.first,
              playbackTime >= firstLine.timestamp,
              let activeIndex = LyricPlaybackPositionPolicy.activeLineIndex(
                in: synchronizedLyrics,
                at: playbackTime
              ) else { return canonical }

        let line = synchronizedLyrics[activeIndex]
        if prefersStableTitle {
            // CarPlay throttles title changes within the same content item.
            // Keep its track identity stable and advance lyrics in the subtitle.
            return NowPlayingLyricsMetadataPresentation(
                title: title,
                artist: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
                lyricLineID: line.id
            )
        }
        let secondary = [title, artist].filter { !$0.isEmpty }.joined(separator: " · ")
        return NowPlayingLyricsMetadataPresentation(
            title: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: secondary,
            lyricLineID: line.id
        )
    }
}

public enum NowPlayingLyricsLoadRetryPolicy {
    // Keep transient recovery bounded: a cache write notification or foreground
    // transition can trigger another load without repeatedly scraping a song that
    // genuinely has no lyrics.
    private static let retryDelays: [TimeInterval] = [2, 10]

    public static func delay(
        afterEmptyResultCount emptyResultCount: Int,
        hasDemand: Bool,
        isLiveStream: Bool
    ) -> TimeInterval? {
        guard hasDemand,
              !isLiveStream,
              emptyResultCount > 0,
              retryDelays.indices.contains(emptyResultCount - 1) else { return nil }
        return retryDelays[emptyResultCount - 1]
    }
}
