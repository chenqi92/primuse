import Foundation
import Observation
import PrimuseKit

extension AudioPlayerService {
    /// True when current playback runs through the local PCM effects graph and can drive Music Haptics.
    var canRunMusicHaptics: Bool {
        #if os(iOS)
        isPlaying
            && !isLoading
            && !isAppleMusicMode
            && !isCastingMode
            && !isLiveRadio
            && !isSystemMediaPlaybackActive
            && !audioEngine.usesDSDCarrier
            && audioEngine.outputMode == .effects
        #else
        false
        #endif
    }

    func configureMusicHaptics() {
        musicHapticsEngine.attach(to: audioEngine)
        musicHapticsEngine.updateConfiguration(playbackSettings.musicHapticsConfiguration)
        syncMusicHapticsState()
        observeMusicHapticsSettings()
    }

    func syncMusicHapticsState() {
        musicHapticsEngine.setPlaybackEligible(canRunMusicHaptics)
    }

    func notifyMusicHapticsTrackChanged() {
        musicHapticsEngine.handleDiscontinuity()
        syncMusicHapticsState()
    }

    private func observeMusicHapticsSettings() {
        withObservationTracking {
            _ = playbackSettings.musicHapticsEnabled
            _ = playbackSettings.musicHapticsIntensity
            _ = playbackSettings.musicHapticsStyle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.musicHapticsEngine.updateConfiguration(self.playbackSettings.musicHapticsConfiguration)
                self.syncMusicHapticsState()
                self.syncEffectsGraphExtras()
                self.observeMusicHapticsSettings()
            }
        }
    }
}
