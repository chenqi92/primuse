import AVFoundation
import Foundation

@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    /// Called when an interruption begins — UI should show "paused" state
    var onInterruptionBegan: (() -> Void)?
    /// Called when an interruption ends and the system suggests resuming
    var onInterruptionEndedShouldResume: (() -> Void)?
    /// Called when the audio engine's hardware configuration changes (route change, etc.)
    var onConfigurationChange: (() -> Void)?

    private init() {}

    func configureForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }

        // Observe interruptions (phone calls, other apps playing audio, Siri, alarms)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )

        // Observe audio engine configuration changes (route changes, hardware changes)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    func deactivate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }

    // MARK: - Interruption Handling

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        Task { @MainActor in
            switch type {
            case .began:
                // Another app took audio focus. Sync UI to paused state.
                print("🔇 Audio interruption began")
                onInterruptionBegan?()

            case .ended:
                // Interruption ended. Check if we should auto-resume.
                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

                if options.contains(.shouldResume) {
                    print("🔊 Audio interruption ended — shouldResume")
                    onInterruptionEndedShouldResume?()
                } else {
                    print("🔊 Audio interruption ended — should NOT resume")
                }

            @unknown default:
                break
            }
        }
    }

    @objc private func handleConfigurationChange(_ notification: Notification) {
        Task { @MainActor in
            print("🔧 Audio engine configuration changed")
            onConfigurationChange?()
        }
    }
}
