import Foundation

/// The key shift next to playback speed (#332): music moves up or down in
/// semitones while keeping its tempo, the way karaoke apps offer it.
///
/// It is stored apart from the karaoke stage's own key shift. Both end on the
/// one time-pitch unit of the effects graph, which is written their sum, so
/// neither overwrites the other: the stage writes its shift on every tick and
/// zero when it closes.
public enum PlaybackPitchPolicy {
    /// The same steps as the karaoke stage; further out a voice audibly smears.
    public static var range: ClosedRange<Int> { KaraokeKeyShiftPolicy.range }

    /// Every choice, lowest first, the way the speed list runs.
    public static var choices: [Int] { Array(range) }

    /// What `AVAudioUnitTimePitch.pitch` accepts, in cents.
    public static let unitCentsRange: ClosedRange<Float> = -2400...2400

    public static func clamped(_ semitones: Int) -> Int {
        KaraokeKeyShiftPolicy.clamped(semitones)
    }

    public static func cents(forSemitones semitones: Int) -> Float {
        KaraokeKeyShiftPolicy.cents(forSemitones: semitones)
    }

    /// The key shift the engine should apply for what is playing. Spoken
    /// word and live radio keep their own voice; an output without the
    /// time-pitch unit (high-fidelity direct) cannot shift at all.
    public static func effectiveSemitones(
        _ semitones: Int,
        isSpokenWord: Bool,
        isLiveRadio: Bool,
        outputAllowsPitch: Bool
    ) -> Int {
        guard outputAllowsPitch, !isSpokenWord, !isLiveRadio else { return 0 }
        return clamped(semitones)
    }

    /// The key the listener hears with the karaoke stage open: the stage's
    /// shift sits on top of the global one. The stage shows this, and the
    /// scoring reference (taken before the time-pitch unit) moves by it.
    public static func combinedSemitones(user: Int, karaoke: Int) -> Int {
        clamped(user) + KaraokeKeyShiftPolicy.clamped(karaoke)
    }

    /// The value written to the time-pitch unit.
    public static func combinedCents(userCents: Float, karaokeCents: Float) -> Float {
        let user = userCents.isFinite ? userCents : 0
        let karaoke = karaokeCents.isFinite ? karaokeCents : 0
        return min(unitCentsRange.upperBound, max(unitCentsRange.lowerBound, user + karaoke))
    }

    /// "+2" / "-3". The original key has no number; the interface writes its
    /// localized name instead.
    public static func signedLabel(_ semitones: Int) -> String? {
        let value = clamped(semitones)
        guard value != 0 else { return nil }
        return String(format: "%+d", value)
    }

    /// Why the key shift cannot be heard on what is playing now.
    public enum Availability: Equatable, Sendable {
        case available
        /// Spoken word and live radio keep their voice; the entry is not
        /// offered there at all.
        case notOffered
        /// Apple Music plays through the system player.
        case appleMusic
        /// Audio leaves the device before the local graph.
        case casting
        /// The bit-perfect graph has no time-pitch unit.
        case highFidelity

        /// Unavailable for a reason the listener can change (or at least
        /// should be told about), so the entry stays visible and explains.
        public var explainsOnTap: Bool {
            switch self {
            case .appleMusic, .casting, .highFidelity: true
            case .available, .notOffered: false
            }
        }
    }

    public static func availability(
        isSpokenWord: Bool,
        isLiveRadio: Bool,
        isAppleMusic: Bool,
        isCasting: Bool,
        isHighFidelityOutput: Bool
    ) -> Availability {
        if isSpokenWord || isLiveRadio { return .notOffered }
        if isAppleMusic { return .appleMusic }
        if isCasting { return .casting }
        if isHighFidelityOutput { return .highFidelity }
        return .available
    }
}
