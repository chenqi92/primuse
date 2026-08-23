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

public enum LyricPlaybackPositionPolicy {
    public enum ScrollTarget: Equatable, Sendable {
        case line(Int)
        case interlude(afterLine: Int)
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
    /// time. Parsed lyric lines are expected to be ordered by timestamp.
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
        return max(0, lower - 1)
    }

    /// Keeps the semantic active row unchanged during a long instrumental
    /// break while allowing a lyrics surface to move to a dedicated interlude
    /// marker. Line-level lyrics have no explicit end time, so their visible
    /// singing window is conservatively estimated before the break begins.
    public static func scrollTarget(
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0,
        lineLevelEstimatedDuration: TimeInterval = 3.5,
        interludeActivationDelay: TimeInterval = 6,
        minimumInterludeDuration: TimeInterval = 12
    ) -> ScrollTarget? {
        guard let activeIndex = activeLineIndex(
            in: lyrics,
            at: playbackTime,
            lookahead: lookahead
        ) else { return nil }
        guard let window = interludeWindow(
            afterLine: activeIndex,
            in: lyrics,
            lineLevelEstimatedDuration: lineLevelEstimatedDuration,
            interludeActivationDelay: interludeActivationDelay,
            minimumInterludeDuration: minimumInterludeDuration
        ) else {
            return .line(activeIndex)
        }

        let targetTime = playbackTime + max(0, lookahead)
        guard targetTime >= window.activation,
              targetTime < window.nextLineStart else {
            return .line(activeIndex)
        }
        return .interlude(afterLine: activeIndex)
    }

    public static func hasLongInterlude(
        afterLine index: Int,
        in lyrics: [LyricLine],
        lineLevelEstimatedDuration: TimeInterval = 3.5,
        minimumInterludeDuration: TimeInterval = 12
    ) -> Bool {
        interludeWindow(
            afterLine: index,
            in: lyrics,
            lineLevelEstimatedDuration: lineLevelEstimatedDuration,
            interludeActivationDelay: 0,
            minimumInterludeDuration: minimumInterludeDuration
        ) != nil
    }

    private static func interludeWindow(
        afterLine index: Int,
        in lyrics: [LyricLine],
        lineLevelEstimatedDuration: TimeInterval,
        interludeActivationDelay: TimeInterval,
        minimumInterludeDuration: TimeInterval
    ) -> (activation: TimeInterval, nextLineStart: TimeInterval)? {
        guard lyrics.indices.contains(index),
              lyrics.indices.contains(index + 1) else { return nil }

        let line = lyrics[index]
        let nextLineStart = lyrics[index + 1].timestamp
        let fallbackEnd = line.timestamp + max(0, lineLevelEstimatedDuration)
        let explicitEnd = line.endTime.flatMap { $0.isFinite ? $0 : nil }
        let estimatedEnd = max(line.timestamp, explicitEnd ?? fallbackEnd)
        let duration = nextLineStart - estimatedEnd
        guard estimatedEnd.isFinite,
              nextLineStart.isFinite,
              duration >= max(0, minimumInterludeDuration) else { return nil }

        return (
            activation: estimatedEnd + max(0, interludeActivationDelay),
            nextLineStart: nextLineStart
        )
    }
}
