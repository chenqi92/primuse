import Foundation

/// Brings the original vocal back while the singer has gone quiet in the
/// middle of their own line, and hands the line back as soon as they sing.
///
/// Fed with each microphone reading (`observe`) and asked for the current
/// level on every render-settings update (`advance`). Times are song times
/// of the voice as sung; a jump backwards (a seek) starts over.
public struct KaraokeVocalAssistPolicy: Sendable {
    /// Continuous silence inside a line before the original comes back.
    public var engageAfter: TimeInterval = 1.2
    /// Fade in of the original vocal, gentle so it reads as a prompt.
    public var fadeIn: TimeInterval = 0.5
    /// Fade out once the singer is back, quick so they are not doubled.
    public var fadeOut: TimeInterval = 0.12
    /// How much of the removed vocal returns at full assist.
    public var depth: Double = 0.8
    /// A "voice" this soon after the original returns, on the original's
    /// own pitch, is the speaker leaking into the microphone.
    public var bleedWindow: TimeInterval = 0.4
    public var bleedTolerance: Double = 0.6
    /// Leaks tolerated before assist gives up for the rest of the song.
    public var bleedLimit = 2

    public private(set) var isEngaged = false
    /// Assist stopped itself because the microphone hears the playback.
    public private(set) var isSuppressed = false
    public private(set) var level: Double = 0

    private var silentSince: TimeInterval?
    private var engagedAt: TimeInterval?
    private var lastObserved: TimeInterval?
    private var lastAdvanced: TimeInterval?
    private var bleeds = 0

    public init() {}

    /// Starts over for a new song.
    public mutating func reset() {
        resetTiming()
        isSuppressed = false
        bleeds = 0
    }

    private mutating func resetTiming() {
        isEngaged = false
        level = 0
        silentSince = nil
        engagedAt = nil
        lastObserved = nil
        lastAdvanced = nil
    }

    /// One microphone reading.
    /// - Parameters:
    ///   - time: song time the reading was sung at.
    ///   - inOwnLine: the singer's own line is being sung at `time`.
    ///   - sung: the singer's pitch (MIDI), nil while they are silent.
    ///   - reference: the original vocal's pitch at `time`, if known.
    public mutating func observe(time: TimeInterval, inOwnLine: Bool, sung: Double?, reference: Double?) {
        if let last = lastObserved, time < last - 0.5 { resetTiming() }
        lastObserved = time
        guard !isSuppressed else { return }

        if let sung {
            if isEngaged, let engagedAt, time - engagedAt < bleedWindow,
               let reference, abs(sung - reference) <= bleedTolerance {
                bleeds += 1
                if bleeds >= bleedLimit {
                    isSuppressed = true
                    disengage()
                    return
                }
            }
            disengage()
            return
        }
        guard inOwnLine else {
            disengage()
            return
        }
        let since = silentSince ?? time
        silentSince = since
        if !isEngaged, time - since >= engageAfter {
            isEngaged = true
            engagedAt = time
        }
    }

    /// Lets the original go again, e.g. when the microphone is turned off.
    public mutating func standDown() {
        disengage()
    }

    /// Whether the user's own line is being sung at `time`.
    public static func isOwnLine(windows: [KaraokeLineWindow], part: KaraokePart, at time: TimeInterval) -> Bool {
        guard let index = KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: time) else { return false }
        return part.includes(windows[index].voice)
    }

    private mutating func disengage() {
        isEngaged = false
        engagedAt = nil
        silentSince = nil
    }

    /// Moves the fade to `time` and returns the factor for the vocal
    /// reduction: 1 keeps the user's setting, lower lets the original back.
    public mutating func advance(to time: TimeInterval) -> Double {
        let elapsed: TimeInterval
        if let last = lastAdvanced, time >= last {
            elapsed = min(time - last, 0.25)
        } else {
            elapsed = 0
        }
        lastAdvanced = time
        let target: Double = isEngaged && !isSuppressed ? 1 : 0
        if target > level {
            level = min(target, level + elapsed / fadeIn)
        } else if target < level {
            level = max(target, level - elapsed / fadeOut)
        }
        return 1 - depth * level
    }
}
