import Foundation

/// A note or syllable start found in a vocal track.
public struct KaraokeOnset: Equatable, Sendable {
    public var time: TimeInterval
    /// Normalised peak height, roughly 0...1.
    public var strength: Double

    public init(time: TimeInterval, strength: Double) {
        self.time = time
        self.strength = strength
    }

    public init(_ onset: SingingOnset) {
        self.time = onset.time
        self.strength = onset.strength
    }
}

/// Finds syllable onsets in a vocal track using the unified multi-feature
/// singing onset detector (vibrato-suppressed SuperFlux, Log-Mel timbre shifts
/// and YIN pitch transitions with local adaptive thresholding).
public enum KaraokeOnsetDetector {
    public static let fftSize = 1_024
    public static let hopSize = 256

    public static func onsets(in samples: [Float], sampleRate: Double) -> [KaraokeOnset] {
        VocalAcousticProfile.analyze(samples: samples, sampleRate: sampleRate)
            .onsets
            .map(KaraokeOnset.init)
    }

    static func onsetTime(frame: Int, hop: Int, fftSize: Int, sampleRate: Double) -> TimeInterval {
        (Double(frame * hop) + Double(fftSize) * 0.5) / sampleRate
    }
}

/// Places the words of a line-timed lyric row on the vocal's syllable onsets
/// using the unified beam-pruned 2nd-order pairwise tempo-smooth aligner.
public enum KaraokeWordTimingPolicy {
    public static let minimumUnitDuration: TimeInterval = 0.055

    /// Word-timed copy of `line` using `onsets` (any order, song seconds),
    /// or nil when the row is already word-timed or has nothing to place.
    public static func timedLine(
        _ line: LyricLine,
        window: KaraokeLineWindow,
        onsets: [KaraokeOnset]
    ) -> LyricLine? {
        let singingOnsets = onsets.map { SingingOnset(time: $0.time, strength: $0.strength) }
        return AudioWordTimingAligner.alignLine(line, window: window, onsets: singingOnsets)
    }
}
