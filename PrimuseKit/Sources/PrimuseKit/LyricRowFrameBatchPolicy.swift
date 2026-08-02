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
    /// Returns the lyric row that should be active at the supplied playback
    /// time. Parsed lyric lines are expected to be ordered by timestamp.
    public static func activeLineIndex(
        in lyrics: [LyricLine],
        at playbackTime: TimeInterval,
        lookahead: TimeInterval = 0
    ) -> Int? {
        guard !lyrics.isEmpty else { return nil }

        let target = playbackTime + lookahead
        var lower = 0
        var upper = lyrics.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lyrics[middle].timestamp <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }
}
