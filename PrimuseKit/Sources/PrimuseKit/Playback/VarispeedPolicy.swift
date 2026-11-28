import Foundation

/// How playback speed and musical pitch are controlled for music tracks (#494).
///
/// - `.independent`: Speed (`AVAudioUnitTimePitch` / `AUiPodTimeOther`) and key shift
///   (`pitchSemitones`) adjust separately without affecting each other.
/// - `.varispeed`: Speed and pitch move together via `AVAudioUnitVarispeed`, matching
///   tape/vinyl/turntable playback where `rate = 2^(semitones / 12)`.
public enum PlaybackSpeedPitchMode: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case independent
    case varispeed

    public var id: String { rawValue }
}

/// Pure math, clamping, presets, availability, and formatting for Varispeed
/// (linked speed & pitch playback, #494).
public enum VarispeedPolicy {
    /// Safe hardware/DSP rate bounds matching ±1 octave (-12...+12 semitones).
    public static let rateRange: ClosedRange<Float> = 0.5...2.0
    public static let defaultRate: Float = 1.0

    /// Percentage change relative to 1.0x: -50% (0.5x) to +100% (2.0x).
    public static let percentChangeRange: ClosedRange<Double> = -50.0...100.0

    /// Musical semitone range corresponding exactly to 0.5x...2.0x.
    public static let semitoneRange: ClosedRange<Int> = -12...12
    public static let semitoneChoices: [Int] = Array(semitoneRange)

    /// Minimum deviation from 1.0x considered active so floating-point noise at unity bypasses DSP.
    public static let unityTolerance: Float = 0.0005

    /// Common speed-aligned Varispeed presets (e.g. Slowed 75%, Nightcore 125%).
    public struct SpeedPreset: Equatable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Sendable {
            case slowed
            case original
            case nightcore
            case plain
        }

        public let id: String
        public let speedPercent: Int
        public let rate: Float
        public let kind: Kind

        public var percentChange: Double {
            Double(speedPercent - 100)
        }

        public init(speedPercent: Int, kind: Kind = .plain) {
            self.id = "speed_\(speedPercent)"
            self.speedPercent = speedPercent
            self.rate = VarispeedPolicy.rate(forSpeedPercent: Double(speedPercent))
            self.kind = kind
        }
    }

    /// Semitone-aligned Varispeed presets (-12...+12 semitones with exact rate and % delta).
    public struct PitchPreset: Equatable, Sendable, Identifiable {
        public var id: Int { semitones }
        public let semitones: Int
        public let rate: Float
        public let percentChange: Double

        public init(semitones: Int) {
            let clamped = min(max(semitones, VarispeedPolicy.semitoneRange.lowerBound), VarispeedPolicy.semitoneRange.upperBound)
            self.semitones = clamped
            self.rate = VarispeedPolicy.rate(forSemitones: clamped)
            self.percentChange = VarispeedPolicy.percentChange(forRate: self.rate)
        }
    }

    public static let speedPresets: [SpeedPreset] = [
        SpeedPreset(speedPercent: 75, kind: .slowed),
        SpeedPreset(speedPercent: 85),
        SpeedPreset(speedPercent: 90),
        SpeedPreset(speedPercent: 100, kind: .original),
        SpeedPreset(speedPercent: 110),
        SpeedPreset(speedPercent: 125, kind: .nightcore),
        SpeedPreset(speedPercent: 150),
    ]

    public static let pitchPresets: [PitchPreset] = semitoneChoices.map(PitchPreset.init(semitones:))

    // MARK: - Clamping

    public static func clampedRate(_ rate: Float) -> Float {
        guard rate.isFinite else { return defaultRate }
        return min(rateRange.upperBound, max(rateRange.lowerBound, rate))
    }

    public static func clampedRate(_ rate: Double) -> Double {
        guard rate.isFinite else { return Double(defaultRate) }
        return min(Double(rateRange.upperBound), max(Double(rateRange.lowerBound), rate))
    }

    public static func clampedPercentChange(_ percentChange: Double) -> Double {
        guard percentChange.isFinite else { return 0 }
        return min(percentChangeRange.upperBound, max(percentChangeRange.lowerBound, percentChange))
    }

    public static func clampedSemitones(_ semitones: Int) -> Int {
        min(semitoneRange.upperBound, max(semitoneRange.lowerBound, semitones))
    }

    public static func isActiveRate(_ rate: Float) -> Bool {
        abs(clampedRate(rate) - defaultRate) >= unityTolerance
    }

    // MARK: - Percent <-> Rate Math

    /// Converts a relative percentage change (e.g. +25 -> 1.25x, -25 -> 0.75x, +5.95 -> 1.0595x)
    /// into a clamped playback rate.
    public static func rate(forPercentChange percentChange: Double) -> Float {
        let clamped = clampedPercentChange(percentChange)
        return clampedRate(Float(1.0 + clamped / 100.0))
    }

    /// Relative percentage change for a rate (e.g. 1.25x -> +25.0, 0.75x -> -25.0).
    public static func percentChange(forRate rate: Float) -> Double {
        (Double(clampedRate(rate)) - 1.0) * 100.0
    }

    /// Absolute speed percentage for a rate (e.g. 1.25x -> 125.0, 0.75x -> 75.0, 1.0x -> 100.0).
    public static func speedPercent(forRate rate: Float) -> Double {
        Double(clampedRate(rate)) * 100.0
    }

    /// Converts an absolute speed percentage (e.g. 125 -> 1.25x, 75 -> 0.75x) into a clamped rate.
    public static func rate(forSpeedPercent speedPercent: Double) -> Float {
        guard speedPercent.isFinite else { return defaultRate }
        return clampedRate(Float(speedPercent / 100.0))
    }

    // MARK: - Semitone <-> Rate Math

    /// Exact equal-temperament rate for a target pitch shift in semitones: `2^(semitones / 12)`.
    /// +1 semitone ≈ 1.059463 (+5.95%), -1 semitone ≈ 0.943874 (-5.61%), ±12 semitones = 2.0x / 0.5x.
    public static func rate(forSemitones semitones: Double) -> Float {
        guard semitones.isFinite else { return defaultRate }
        return clampedRate(Float(pow(2.0, semitones / 12.0)))
    }

    public static func rate(forSemitones semitones: Int) -> Float {
        rate(forSemitones: Double(clampedSemitones(semitones)))
    }

    /// Exact resulting pitch shift in semitones for a given Varispeed rate: `12 * log2(rate)`.
    public static func semitones(forRate rate: Float) -> Double {
        12.0 * log2(Double(clampedRate(rate)))
    }

    /// Exact resulting pitch shift in cents for a given Varispeed rate: `1200 * log2(rate)`.
    public static func cents(forRate rate: Float) -> Double {
        1200.0 * log2(Double(clampedRate(rate)))
    }

    /// Returns the integer semitone if `rate` lies within `toleranceCents` of that semitone.
    public static func nearestSemitone(forRate rate: Float, toleranceCents: Double = 4.0) -> Int? {
        let exact = semitones(forRate: rate)
        let rounded = Int(exact.rounded())
        guard semitoneRange.contains(rounded) else { return nil }
        let deltaCents = abs(exact - Double(rounded)) * 100.0
        return deltaCents <= toleranceCents ? rounded : nil
    }

    /// Returns the matching speed preset if `rate` is within tolerance of one.
    public static func matchingSpeedPreset(forRate rate: Float, tolerance: Float = 0.002) -> SpeedPreset? {
        let clamped = clampedRate(rate)
        return speedPresets.first { abs($0.rate - clamped) <= tolerance }
    }

    // MARK: - Availability & Effective Rate

    /// Varispeed follows the same DSP availability rules as independent pitch shifting:
    /// music tracks on the local PCM effects graph only; spoken word and live radio keep their own rules.
    public static func availability(
        isSpokenWord: Bool,
        isLiveRadio: Bool,
        isAppleMusic: Bool,
        isCasting: Bool,
        isHighFidelityOutput: Bool
    ) -> PlaybackPitchPolicy.Availability {
        PlaybackPitchPolicy.availability(
            isSpokenWord: isSpokenWord,
            isLiveRadio: isLiveRadio,
            isAppleMusic: isAppleMusic,
            isCasting: isCasting,
            isHighFidelityOutput: isHighFidelityOutput
        )
    }

    /// True when the audio graph should route playback through `AVAudioUnitVarispeed`
    /// instead of pitch-preserving time stretching.
    public static func isEffective(
        mode: PlaybackSpeedPitchMode,
        isSpokenWord: Bool,
        isLiveRadio: Bool,
        outputAllowsEffects: Bool,
        isKaraokePracticeActive: Bool = false
    ) -> Bool {
        mode == .varispeed
            && outputAllowsEffects
            && !isSpokenWord
            && !isLiveRadio
            && !isKaraokePracticeActive
    }

    /// Canonical playback clock rate used for progress interpolation, lyrics sync,
    /// NowPlayingInfo, CarPlay, widgets, and gapless scheduling.
    public static func effectiveClockRate(
        mode: PlaybackSpeedPitchMode,
        independentMusicRate: Float,
        varispeedRate: Float,
        isSpokenWord: Bool,
        spokenWordRate: Float,
        isLiveRadio: Bool,
        outputAllowsEffects: Bool,
        karaokePracticeRate: Float? = nil
    ) -> Float {
        if let practice = karaokePracticeRate, outputAllowsEffects {
            return clampedRate(practice)
        }
        if isSpokenWord {
            return SpokenWordPlaybackRatePolicy.clamped(spokenWordRate)
        }
        guard outputAllowsEffects, !isLiveRadio else { return defaultRate }
        switch mode {
        case .independent:
            return clampedRate(independentMusicRate)
        case .varispeed:
            return clampedRate(varispeedRate)
        }
    }

    // MARK: - Formatting

    /// Signed percentage change label, e.g. `"0%"`, `"+5.95%"`, `"-5.61%"`, `"+25%"`, `"-25%"`.
    public static func signedPercentLabel(forRate rate: Float) -> String {
        let pct = percentChange(forRate: rate)
        if abs(pct) < 0.005 { return "0%" }
        let roundedInt = pct.rounded()
        if abs(pct - roundedInt) < 0.01 {
            return String(format: "%+.0f%%", roundedInt)
        }
        let roundedTenth = (pct * 10).rounded() / 10
        if abs(pct - roundedTenth) < 0.005 {
            return String(format: "%+.1f%%", roundedTenth)
        }
        return String(format: "%+.2f%%", pct)
    }

    /// Absolute speed percentage label, e.g. `"100%"`, `"125%"`, `"75%"`, `"105.95%"`.
    public static func speedPercentLabel(forRate rate: Float) -> String {
        let pct = speedPercent(forRate: rate)
        let roundedInt = pct.rounded()
        if abs(pct - roundedInt) < 0.01 {
            return String(format: "%.0f%%", roundedInt)
        }
        let roundedTenth = (pct * 10).rounded() / 10
        if abs(pct - roundedTenth) < 0.005 {
            return String(format: "%.1f%%", roundedTenth)
        }
        return String(format: "%.2f%%", pct)
    }

    /// Signed semitone shift value, or `nil` at 0 semitones.
    /// Integer semitones render without decimals (`"+1"`, `"-3"`); intermediate values show 1 decimal (`"+3.9"`).
    public static func signedSemitoneValue(forRate rate: Float) -> String? {
        let st = semitones(forRate: rate)
        if abs(st) < 0.04 { return nil }
        let nearest = st.rounded()
        if abs(st - nearest) < 0.04 {
            return String(format: "%+.0f", nearest)
        }
        return String(format: "%+.1f", st)
    }
}
