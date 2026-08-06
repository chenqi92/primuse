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

public enum LyricPlaybackPositionPolicy {
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
}
