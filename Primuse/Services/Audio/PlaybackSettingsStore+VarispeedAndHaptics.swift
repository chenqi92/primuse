import Foundation
import PrimuseKit

extension PlaybackSettingsStore {
    /// Current Varispeed relative percentage change (`-50% ... +100%`).
    var varispeedPercentChange: Double {
        VarispeedPolicy.percentChange(forRate: varispeedRate)
    }

    /// Current Varispeed absolute speed percentage (`50% ... 200%`).
    var varispeedSpeedPercent: Double {
        VarispeedPolicy.speedPercent(forRate: varispeedRate)
    }

    /// Current Varispeed resulting pitch shift in semitones (`-12 ... +12`).
    var varispeedSemitones: Double {
        VarispeedPolicy.semitones(forRate: varispeedRate)
    }

    /// Whether the active music speed/pitch configuration deviates from normal (1.0× / 0 st).
    var hasCustomMusicSpeedOrPitch: Bool {
        switch speedPitchMode {
        case .independent:
            abs(playbackRate - 1.0) >= 0.001 || pitchSemitones != 0
        case .varispeed:
            VarispeedPolicy.isActiveRate(varispeedRate)
        }
    }

    /// Current Music Haptics configuration snapshot for `MusicHapticsEngine`.
    var musicHapticsConfiguration: MusicHapticsConfiguration {
        MusicHapticsConfiguration(
            isEnabled: musicHapticsEnabled,
            intensity: musicHapticsIntensity,
            style: musicHapticsStyle
        )
    }

    /// Switches between independent Speed/Pitch and linked Varispeed mode,
    /// preserving each mode's speed while keeping `playbackRate` synchronized
    /// as the canonical music clock rate.
    func setSpeedPitchMode(_ mode: PlaybackSpeedPitchMode) {
        guard speedPitchMode != mode else { return }
        speedPitchMode = mode
    }

    /// Adjusts Varispeed by relative percentage change (e.g. `+5.95`, `+25`, `-25`).
    func setVarispeed(percentChange: Double) {
        let rate = VarispeedPolicy.rate(forPercentChange: percentChange)
        applyVarispeedRate(rate)
    }

    /// Adjusts Varispeed to align exactly with a target pitch shift in semitones (`-12 ... +12`).
    func setVarispeed(semitones: Int) {
        let rate = VarispeedPolicy.rate(forSemitones: semitones)
        applyVarispeedRate(rate)
    }

    /// Adjusts Varispeed to align with an absolute speed percentage (e.g. `75` Slowed, `125` Nightcore).
    func setVarispeed(speedPercent: Double) {
        let rate = VarispeedPolicy.rate(forSpeedPercent: speedPercent)
        applyVarispeedRate(rate)
    }

    /// Resets Varispeed back to 0% / 1.0×.
    func resetVarispeed() {
        applyVarispeedRate(VarispeedPolicy.defaultRate)
    }

    /// Resets the currently active music speed/pitch mode back to normal.
    func resetActiveSpeedAndPitch() {
        suppressPersist = true
        switch speedPitchMode {
        case .independent:
            playbackRate = 1.0
            savedIndependentPlaybackRate = 1.0
            pitchSemitones = 0
        case .varispeed:
            varispeedRate = VarispeedPolicy.defaultRate
            playbackRate = VarispeedPolicy.defaultRate
        }
        suppressPersist = false
        persist()
    }

    private func applyVarispeedRate(_ rate: Float) {
        let clamped = VarispeedPolicy.clampedRate(rate)
        suppressPersist = true
        if speedPitchMode != .varispeed {
            savedIndependentPlaybackRate = playbackRate
            speedPitchMode = .varispeed
        }
        varispeedRate = clamped
        playbackRate = clamped
        suppressPersist = false
        persist()
    }

    // MARK: - Property Observer Helpers (called from PlaybackSettingsStore.swift)

    func handlePlaybackRateChanged() {
        let clamped = VarispeedPolicy.clampedRate(playbackRate)
        if clamped != playbackRate {
            playbackRate = clamped
            return
        }
        guard !suppressPersist else { return }
        suppressPersist = true
        if speedPitchMode == .varispeed {
            varispeedRate = clamped
        } else {
            savedIndependentPlaybackRate = clamped
        }
        suppressPersist = false
        persist()
    }

    func handleSpeedPitchModeChanged(from oldValue: PlaybackSpeedPitchMode) {
        guard !suppressPersist else { return }
        guard speedPitchMode != oldValue else {
            persist()
            return
        }
        suppressPersist = true
        switch speedPitchMode {
        case .varispeed:
            savedIndependentPlaybackRate = playbackRate
            playbackRate = VarispeedPolicy.clampedRate(varispeedRate)
        case .independent:
            varispeedRate = playbackRate
            playbackRate = VarispeedPolicy.clampedRate(savedIndependentPlaybackRate)
        }
        suppressPersist = false
        persist()
    }

    func handleVarispeedRateChanged() {
        let clamped = VarispeedPolicy.clampedRate(varispeedRate)
        if clamped != varispeedRate {
            varispeedRate = clamped
            return
        }
        guard !suppressPersist else { return }
        if speedPitchMode == .varispeed {
            suppressPersist = true
            playbackRate = clamped
            suppressPersist = false
        }
        persist()
    }

    func handleMusicHapticsIntensityChanged() {
        let clamped = MusicHapticsConfiguration.clampedIntensity(musicHapticsIntensity)
        if clamped != musicHapticsIntensity {
            musicHapticsIntensity = clamped
            return
        }
        persist()
    }
}
