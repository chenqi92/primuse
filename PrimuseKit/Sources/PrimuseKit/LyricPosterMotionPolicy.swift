import Foundation

/// When one lyric row is sung, expressed on the poster's own timeline where
/// zero is the first exported frame.
public struct LyricPosterMotionWindow: Hashable, Sendable {
    public let lineID: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(lineID: String, start: TimeInterval, end: TimeInterval) {
        self.lineID = lineID
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(end - start, 0) }

    public func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return time >= start ? 1 : 0 }
        return min(max((time - start) / duration, 0), 1)
    }
}

/// The full timeline for a motion poster: how long it runs, which frame the
/// still half of the Live Photo comes from, and when each row lights up.
public struct LyricPosterMotionPlan: Hashable, Sendable {
    public let duration: TimeInterval
    public let frameRate: Int
    public let windows: [LyricPosterMotionWindow]
    /// Frame the Live Photo shows when it is not being played. It sits at the
    /// moment the passage is fully revealed, so the still and the motion agree.
    public let stillFrameIndex: Int

    public init(
        duration: TimeInterval,
        frameRate: Int,
        windows: [LyricPosterMotionWindow],
        stillFrameIndex: Int
    ) {
        self.duration = duration
        self.frameRate = frameRate
        self.windows = windows
        self.stillFrameIndex = stillFrameIndex
    }

    public var frameCount: Int {
        max(1, Int((duration * Double(frameRate)).rounded()))
    }

    public func time(ofFrame index: Int) -> TimeInterval {
        guard frameRate > 0 else { return 0 }
        return Double(index) / Double(frameRate)
    }

    public var stillFrameTime: TimeInterval { time(ofFrame: stillFrameIndex) }

    /// Index of the row being sung at `time`, or nil before the first row.
    public func activeIndex(at time: TimeInterval) -> Int? {
        var active: Int?
        for (index, window) in windows.enumerated() where window.start <= time {
            active = index
        }
        return active
    }

    /// 0…1 within the active row, used for the karaoke wipe.
    public func activeProgress(at time: TimeInterval) -> Double {
        guard let index = activeIndex(at: time) else { return 0 }
        return windows[index].progress(at: time)
    }

    /// 0…1 reveal for one row, including rows that have already been sung.
    public func reveal(ofLineAt index: Int, at time: TimeInterval) -> Double {
        guard windows.indices.contains(index) else { return 1 }
        return windows[index].progress(at: time)
    }
}

/// Builds a Live Photo-length timeline out of the selected passage.
///
/// The timeline is always rebuilt rather than reused from playback: the
/// selection may span a minute of a song, while the exported motion has to be
/// short enough that iOS keeps it pairable as a Live Photo.
public enum LyricPosterMotionPolicy {
    public static let frameRate = 30
    /// iOS plays roughly three seconds of a Live Photo; a longer paired video
    /// is accepted but its tail is never seen, so posters stay inside a range
    /// that actually plays back.
    public static let minimumDuration: TimeInterval = 2.4
    public static let maximumDuration: TimeInterval = 5.6
    /// Still moment before the first row appears.
    public static let leadIn: TimeInterval = 0.28
    /// Held tail after the last row completes, so the passage can be read.
    public static let tail: TimeInterval = 0.9

    public static func plan(
        for content: LyricPosterContent,
        frameRate: Int = frameRate
    ) -> LyricPosterMotionPlan {
        let rate = max(frameRate, 1)
        guard !content.lines.isEmpty else {
            return LyricPosterMotionPlan(
                duration: minimumDuration,
                frameRate: rate,
                windows: [],
                stillFrameIndex: 0
            )
        }

        let spans = content.isSynchronized
            ? synchronizedSpans(of: content)
            : evenSpans(of: content)
        let body = spans.last?.end ?? 0
        let rawDuration = leadIn + body + tail
        let duration = min(max(rawDuration, minimumDuration), maximumDuration)
        // Compress rather than clip when the passage is long: every row must
        // still get its moment inside the exported clip.
        let usableBody = max(duration - leadIn - tail, 0.2)
        let scale = body > 0 ? min(1, usableBody / body) : 1

        let windows = zip(content.lines, spans).map { line, span in
            LyricPosterMotionWindow(
                lineID: line.id,
                start: leadIn + span.start * scale,
                end: leadIn + span.end * scale
            )
        }

        let revealed = windows.last?.end ?? duration
        // Hold the still a beat after the last row lands, clamped inside the
        // clip so the paired still always has a matching frame.
        let stillTime = min(revealed + 0.25, max(duration - 1.0 / Double(rate), 0))
        let stillFrameIndex = max(0, Int((stillTime * Double(rate)).rounded()))

        return LyricPosterMotionPlan(
            duration: duration,
            frameRate: rate,
            windows: windows,
            stillFrameIndex: stillFrameIndex
        )
    }

    private struct Span {
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Relative timing taken from the song, with each row's dwell clamped so a
    /// long instrumental gap between two selected lines does not eat the clip.
    private static func synchronizedSpans(of content: LyricPosterContent) -> [Span] {
        let lines = content.lines
        var spans: [Span] = []
        var cursor: TimeInterval = 0
        for (index, line) in lines.enumerated() {
            let nextStart = index + 1 < lines.count ? lines[index + 1].timestamp : nil
            let sungEnd = line.endTimestamp ?? nextStart ?? (line.timestamp + 2.4)
            let rawDwell = max(sungEnd - line.timestamp, 0.35)
            let dwell = min(rawDwell, 2.6)
            let rawGap = (nextStart ?? sungEnd) - sungEnd
            let gap = min(max(rawGap, 0), 0.6)
            spans.append(Span(start: cursor, end: cursor + dwell))
            cursor += dwell + gap
        }
        return spans
    }

    private static func evenSpans(of content: LyricPosterContent) -> [Span] {
        let count = content.lines.count
        let dwell: TimeInterval = count <= 2 ? 1.4 : count <= 4 ? 1.0 : 0.7
        return (0..<count).map { index in
            Span(start: Double(index) * dwell, end: Double(index) * dwell + dwell)
        }
    }
}
