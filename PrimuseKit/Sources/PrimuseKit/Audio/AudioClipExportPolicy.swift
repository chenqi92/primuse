import Foundation

/// Rules for writing one stretch of a song to its own audio file ("铃声与导出"):
/// how long a ringtone may be, the window that is actually written, the fades,
/// the output format and the file name. Times are on the song's own timeline,
/// like `SongPlaybackRange`.
public enum AudioClipExportPolicy {
    public enum Purpose: Sendable {
        /// Handed to the share sheet's "Use as Ringtone" (iOS 26 and later).
        case ringtone
        /// Any stretch, saved or shared as an audio file.
        case clip
    }

    /// The share sheet's "Use as Ringtone" refuses audio longer than this.
    public static let ringtoneMaximumLength: TimeInterval = 30
    /// A ringtone is written a little short of the limit: the encoder's
    /// padding makes a file of exactly 30 seconds measure slightly longer.
    static let ringtoneSafetyMargin: TimeInterval = 0.2
    /// An exported clip is at most this long, so a CUE image's whole timeline
    /// is never written by accident.
    public static let clipMaximumLength: TimeInterval = 20 * 60
    public static let minimumLength: TimeInterval = SongPlaybackRangePolicy.minimumLength
    /// Lengths this close to the ringtone limit count as within it.
    static let lengthTolerance: TimeInterval = 0.05

    /// The window written for `purpose`, kept inside the song; nil when what
    /// is left is shorter than `minimumLength`. A ringtone keeps its start and
    /// is cut to the limit.
    public static func exportedWindow(
        start: TimeInterval,
        end: TimeInterval,
        songDuration: TimeInterval,
        purpose: Purpose
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard start.isFinite, end.isFinite, songDuration.isFinite, songDuration > 0 else { return nil }
        let clampedStart = min(max(0, start), songDuration)
        var clampedEnd = min(max(clampedStart, end), songDuration)
        switch purpose {
        case .ringtone:
            clampedEnd = min(clampedEnd, clampedStart + ringtoneMaximumLength - ringtoneSafetyMargin)
        case .clip:
            clampedEnd = min(clampedEnd, clampedStart + clipMaximumLength)
        }
        guard clampedEnd - clampedStart >= minimumLength - lengthTolerance else { return nil }
        return (clampedStart, clampedEnd)
    }

    /// True when a ringtone made from a stretch `length` long keeps only its
    /// first `ringtoneMaximumLength` seconds.
    public static func ringtoneIsShortened(length: TimeInterval) -> Bool {
        length.isFinite && length > ringtoneMaximumLength + lengthTolerance
    }

    /// The stretch to select from a found highlight ("高潮"): its own start
    /// and end, at tenths of a second, inside the song and at least
    /// `minimumLength` long. `maximumLength` keeps the start and cuts the end,
    /// a ringtone should open on the chorus.
    public static func range(
        highlightStart: TimeInterval,
        highlightEnd: TimeInterval,
        songDuration: TimeInterval,
        maximumLength: TimeInterval? = nil
    ) -> SongPlaybackRange? {
        guard highlightStart.isFinite, highlightEnd.isFinite,
              songDuration.isFinite, songDuration >= minimumLength else { return nil }
        func tenths(_ value: TimeInterval) -> TimeInterval { (value * 10).rounded() / 10 }
        var start = min(max(0, tenths(highlightStart)), songDuration)
        var end = min(tenths(highlightEnd), songDuration)
        if let maximumLength, maximumLength.isFinite, maximumLength >= minimumLength {
            end = min(end, start + maximumLength)
        }
        if end - start < minimumLength {
            end = min(songDuration, start + minimumLength)
            start = max(0, end - minimumLength)
        }
        return SongPlaybackRange(start: start, end: end, isEnabled: true)
    }

    // MARK: - Fades

    public struct Fades: Equatable, Sendable {
        public var fadeIn: TimeInterval
        public var fadeOut: TimeInterval

        public init(fadeIn: TimeInterval, fadeOut: TimeInterval) {
            self.fadeIn = fadeIn
            self.fadeOut = fadeOut
        }

        public static let off = Fades(fadeIn: 0, fadeOut: 0)
    }

    static let maximumFadeIn: TimeInterval = 1
    static let maximumFadeOut: TimeInterval = 2

    /// A short rise and a longer fall, so a ringtone that repeats does not
    /// click at the seam; short clips get proportionally shorter fades.
    public static func fades(forLength length: TimeInterval) -> Fades {
        guard length.isFinite, length > 0 else { return .off }
        return Fades(fadeIn: min(maximumFadeIn, length * 0.1), fadeOut: min(maximumFadeOut, length * 0.15))
    }

    /// The level at `offset` seconds into a clip `length` long: an
    /// equal-power rise and fall at the ends, 1 in between.
    public static func gain(at offset: TimeInterval, length: TimeInterval, fades: Fades) -> Float {
        guard offset.isFinite, length.isFinite, length > 0 else { return 1 }
        var level = 1.0
        if fades.fadeIn > 0, offset < fades.fadeIn {
            level = min(level, sin(max(0, offset) / fades.fadeIn * .pi / 2))
        }
        let remaining = length - offset
        if fades.fadeOut > 0, remaining < fades.fadeOut {
            level = min(level, sin(max(0, remaining) / fades.fadeOut * .pi / 2))
        }
        return Float(level)
    }

    // MARK: - Output

    /// AAC at a sample rate the encoder takes, from the same family as the
    /// source; mono stays mono and everything else becomes stereo.
    public static func outputSampleRate(sourceSampleRate: Double) -> Double {
        OfflineDownloadQualityPolicy.encoderSampleRate(sourceSampleRate: sourceSampleRate)
    }

    public static func outputChannelCount(sourceChannelCount: Int) -> Int {
        sourceChannelCount == 1 ? 1 : 2
    }

    /// Bit rates tried in turn, per stereo pair; the encoder refuses some
    /// rates at some sample rates (a 22 kHz mono source tops out far lower).
    public static func bitRateCandidates(channelCount: Int) -> [Int] {
        let stereo = [256_000, 192_000, 160_000, 128_000, 96_000, 64_000]
        return channelCount <= 1 ? stereo.map { $0 / 2 } : stereo
    }

    /// The written length matches the window to within a few hundredths of
    /// a second plus the encoder's frame.
    public static func writtenLengthIsComplete(expected: TimeInterval, actual: TimeInterval) -> Bool {
        guard expected.isFinite, expected > 0, actual.isFinite, actual > 0 else { return false }
        return abs(actual - expected) <= max(0.1, expected * 0.01)
    }

    static let maximumFileNameLength = 80

    /// "Title - Artist.m4a" without characters the file systems or the share
    /// targets refuse; the name the ringtone gets in Settings.
    public static func fileName(title: String, artist: String?, fileExtension: String = "m4a") -> String {
        func cleaned(_ text: String) -> String {
            let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
                .union(.newlines)
            var scalars = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                scalars.append(forbidden.contains(scalar) ? " " : scalar)
            }
            return String(scalars)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        var base = cleaned(title)
        if let artist {
            let cleanedArtist = cleaned(artist)
            if !cleanedArtist.isEmpty, !base.isEmpty { base += " - " + cleanedArtist }
        }
        if base.count > maximumFileNameLength {
            base = String(base.prefix(maximumFileNameLength)).trimmingCharacters(in: .whitespaces)
        }
        if base.isEmpty { base = "Primuse" }
        return base + "." + fileExtension
    }
}
