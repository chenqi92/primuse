import AVFoundation
import Foundation

/// Lifecycle events emitted by `AudioEngine` so `MusicHapticsEngine` stays locked to
/// local playback transitions without polling.
enum AudioEngineHapticsEvent: Sendable {
    case graphReady
    case graphTeardown
    case started
    case paused
    case discontinuity
    case rateChanged
}

extension AudioEngine {
    /// Dedicated tap node for iOS Music Haptics.
    ///
    /// In `.effects` mode this returns a unity-gain post-varispeed mixer node right before
    /// `mainMixerNode`, so Music Haptics receives EQ/effects/varispeed-processed audio with
    /// zero tap conflict against `AudioVisualizerService` (`mainMixerNode`) or karaoke recording
    /// (`timePitchProcessor.spectralNode`). The mixer is only in the graph while Music Haptics
    /// is turned on (`graphIncludesHapticsTap`); listeners who never turn it on keep the old graph.
    ///
    /// High-fidelity direct bypass avoids inserting any mixer; DoP carriers are never analyzed.
    var hapticsTapNode: AVAudioNode? {
        #if os(iOS)
        if outputMode == .effects {
            return hapticsTapMixer
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Underlying `AVAudioEngine` for installing/removing the haptics tap.
    var engineForMusicHaptics: AVAudioEngine? {
        engine
    }

    func notifyMusicHapticsLifecycle(_ event: AudioEngineHapticsEvent) {
        onMusicHapticsLifecycleEvent?(event)
    }
}
