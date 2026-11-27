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

/// How long each song of a medley plays.
public enum MedleySliceLength: Hashable, Sendable {
    /// As long as the song's highlight lasts.
    case automatic
    /// The same number of seconds for every song.
    case fixed(Int)
}

/// Chooses which slice of each song a medley ("串烧") plays and how long
/// neighbouring slices overlap.
///
/// The slice aims at the part people recognise a song by: its highlight
/// (`MedleyHighlight`, the chorus) when one has been found. Played at its own
/// length, the slice reaches a little before the chorus and a little past it,
/// so the crossfade blends the lead-in and the tail-off rather than the
/// chorus itself. Without a highlight it falls back to a third of the way in,
/// or the structure-analysis section nearest that point. A song too short to
/// cut is played whole.
public enum MedleySegmentPolicy {
    public static let allowedSegmentLengths = [10, 20, 30, 45, 60, 90]
    public static let defaultSegmentLength = 10
    /// The settings value meaning "as long as the highlight": the picker's
    /// first choice, ahead of the fixed lengths.
    public static let automaticSegmentChoice = 0
    public static let segmentChoices = [automaticSegmentChoice] + allowedSegmentLengths
    /// Played when a song's highlight is not known yet.
    public static let automaticFallbackLength = 30
    /// A highlight shorter than this is not trusted.
    public static let minimumHighlightLength: TimeInterval = 6

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

    public static func sliceLength(automatic: Bool, seconds: Int) -> MedleySliceLength {
        automatic ? .automatic : .fixed(clampedSegmentLength(seconds))
    }

    /// The slice to play, or nil when the song should be skipped.
    ///
    /// - Parameters:
    ///   - highlight: the song's chorus, when it has been found.
    ///   - leadsIn: false for the opening slice of a medley, which starts
    ///     right on the chorus instead of fading in ahead of it.
    public static func segment(
        duration: TimeInterval,
        length: MedleySliceLength,
        highlight: MedleyHighlight?,
        sectionStarts: [TimeInterval] = [],
        leadsIn: Bool = true
    ) -> MedleySegment? {
        guard duration.isFinite else { return nil }
        let usable = highlight.flatMap { usableHighlight($0, duration: duration) }
        switch length {
        case .fixed(let seconds):
            let length = TimeInterval(clampedSegmentLength(seconds))
            guard let usable, duration > length + wholeSongSlack else {
                return segment(duration: duration, segmentLength: seconds, sectionStarts: sectionStarts)
            }
            let lead = leadsIn ? overlap(segmentLength: length) : 0
            let start = min(max(0, usable.start - lead), duration - length)
            return MedleySegment(start: start, end: start + length)
        case .automatic:
            let fallback = TimeInterval(automaticFallbackLength)
            guard duration > 0 else { return MedleySegment(start: 0, end: fallback) }
            guard duration > fallback + wholeSongSlack else {
                return MedleySegment(start: 0, end: duration)
            }
            guard let usable else {
                return segment(duration: duration, segmentLength: automaticFallbackLength, sectionStarts: sectionStarts)
            }
            let margin = overlap(segmentLength: usable.length)
            let start = max(0, usable.start - (leadsIn ? margin : 0))
            let end = min(duration, usable.end + margin)
            return MedleySegment(start: start, end: end)
        }
    }

    /// The slice for a song the listener gave a playback range: exactly that range.
    public static func segment(playbackRange: AppliedSongPlaybackRange) -> MedleySegment? {
        guard playbackRange.length >= SongPlaybackRangePolicy.minimumLength else { return nil }
        return MedleySegment(start: playbackRange.start, end: playbackRange.end)
    }

    static func usableHighlight(_ highlight: MedleyHighlight, duration: TimeInterval) -> MedleyHighlight? {
        guard highlight.start.isFinite, highlight.end.isFinite,
              highlight.start >= 0,
              duration <= 0 || highlight.end <= duration + 0.5,
              highlight.length >= minimumHighlightLength else { return nil }
        var clamped = highlight
        if duration > 0 { clamped.end = min(clamped.end, duration) }
        return clamped
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

/// Whether starting a medley should first say it will use mobile data. A medley
/// downloads the next songs whole so each slice can blend into the next, which
/// on a metered connection costs far more than playing the same slices plainly.
public enum MedleyDataUsagePolicy {
    /// Set once the listener chose "don't ask again".
    public static let promptDisabledKey = "primuse.medley.meteredDataPromptDisabled"
    /// Only the opening of the medley is looked at; by the time later songs are
    /// fetched the listener has already agreed.
    public static let inspectedSongCount = 60

    public static func shouldConfirm(
        networkIsDetermined: Bool,
        isOnUnmeteredNetwork: Bool,
        promptDisabled: Bool,
        hasSongToDownload: Bool
    ) -> Bool {
        networkIsDetermined && !isOnUnmeteredNetwork && !promptDisabled && hasSongToDownload
    }
}
