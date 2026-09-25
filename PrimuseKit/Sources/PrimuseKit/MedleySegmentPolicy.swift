import Foundation

/// The part of one song a medley plays.
public struct MedleySegment: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var length: TimeInterval { end - start }
}

/// Chooses which slice of each song a medley ("串烧") plays and how long
/// neighbouring slices overlap.
///
/// The slice aims at the part people recognise a song by. Without analysis
/// that is usually the first chorus, a third of the way in; when structure
/// analysis has marked section starts, the section nearest that point is
/// used instead so the slice begins on a musical boundary rather than
/// mid-phrase. A song too short to cut is played whole.
public enum MedleySegmentPolicy {
    public static let allowedSegmentLengths = [20, 30, 45, 60, 90]
    public static let defaultSegmentLength = 45

    /// Where in the song the slice aims to start, as a fraction of its length.
    static let targetFraction = 0.33
    /// Never start inside the intro: the first seconds are rarely the hook.
    static let minimumStart: TimeInterval = 10
    /// Leave room before the end so the slice does not run into the outro.
    static let endMargin: TimeInterval = 8
    /// A song this much longer than the slice is played whole instead.
    static let wholeSongSlack: TimeInterval = 20

    public static func clampedSegmentLength(_ seconds: Int) -> Int {
        allowedSegmentLengths.min {
            abs($0 - seconds) < abs($1 - seconds)
                || (abs($0 - seconds) == abs($1 - seconds) && $0 < $1)
        } ?? defaultSegmentLength
    }

    /// The slice to play, or nil when the song should be skipped (it has no
    /// usable audio at all).
    ///
    /// - Parameters:
    ///   - duration: the song's length; 0 or less when unknown.
    ///   - segmentLength: the requested slice length in seconds.
    ///   - sectionStarts: structure boundaries from analysis, if any.
    public static func segment(
        duration: TimeInterval,
        segmentLength: Int,
        sectionStarts: [TimeInterval] = []
    ) -> MedleySegment? {
        let length = TimeInterval(clampedSegmentLength(segmentLength))
        guard duration.isFinite else { return nil }
        // Unknown length: play the opening slice rather than guess a middle
        // that may not exist.
        guard duration > 0 else { return MedleySegment(start: 0, end: length) }
        guard duration > length + wholeSongSlack else {
            return MedleySegment(start: 0, end: duration)
        }

        let latestStart = max(minimumStart, duration - length - endMargin)
        let target = min(max(duration * targetFraction, minimumStart), latestStart)

        let candidates = sectionStarts.filter {
            $0.isFinite && $0 >= minimumStart && $0 <= latestStart
        }
        let start: TimeInterval
        if let nearest = candidates.min(by: { abs($0 - target) < abs($1 - target) }),
           abs(nearest - target) <= length {
            start = nearest
        } else {
            start = target.rounded()
        }
        return MedleySegment(start: start, end: min(duration, start + length))
    }

    /// Overlap between neighbouring slices: long enough to hear as a blend,
    /// never more than a quarter of the slice so each song is still heard on
    /// its own.
    public static func overlap(segmentLength: TimeInterval) -> TimeInterval {
        guard segmentLength.isFinite, segmentLength > 0 else { return 0 }
        return min(4, max(1, segmentLength / 4))
    }

    /// How long before the blend the next slice starts being prepared. A slice
    /// begins mid-file, so a remote song first has to open and seek there;
    /// doing that only when the blend is due left a gap, or a hard cut, on
    /// every slow source. The decoded opening is then held until the blend.
    public static func preparationLead(segmentLength: TimeInterval) -> TimeInterval {
        guard segmentLength.isFinite, segmentLength > 0 else { return 0 }
        return min(12, segmentLength * 0.3)
    }
}
