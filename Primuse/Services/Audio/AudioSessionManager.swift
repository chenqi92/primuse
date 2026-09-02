import AVFoundation
import Foundation

@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()

    /// Called when an interruption begins — UI should show "paused" state
    var onInterruptionBegan: ((Date) -> Void)?
    /// Called whenever an interruption ends, carrying the system resume grant.
    /// Delivering denied endings is required so stale resume intent can be
    /// cleared instead of being revived by a later lifecycle callback.
    var onInterruptionEnded: ((Bool) -> Void)?
    /// Called when the audio engine's hardware configuration changes (route change, etc.)
    var onConfigurationChange: ((Date) -> Void)?

    private var isConfigured = false

    private init() {}

#if os(iOS)

    @discardableResult
    func activatePlaybackSession(reacquiringLocalRouteFocus: Bool = false) -> Bool {
        let session = AVAudioSession.sharedInstance()
        if reacquiringLocalRouteFocus {
            do {
                // While long-form audio is routed to AirPlay, another app may
                // keep owning the phone's output. Returning to the built-in
                // route does not reactivate an already-active session, so make
                // the non-mixable playback category arbitrate again. The
                // caller stops every local render object before requesting
                // this transition; do not notify the other app during the
                // intentionally brief inactive interval.
                try session.setActive(false)
            } catch {
                plog("Failed to release audio session before local route recovery: \(error)")
                return false
            }
        }
        do {
            try configurePlaybackSession(session)
            try session.setActive(true)
            return true
        } catch {
            plog("Failed to activate audio session: \(error)")
            return false
        }
    }

    /// Sets the playback category and installs lifecycle observers without
    /// activating the session. Safe to call during app startup.
    func prepareForPlayback() {
        let session = AVAudioSession.sharedInstance()
        guard !isConfigured else { return }
        isConfigured = true

        // Configure the app's playback intent at launch, but do not activate the
        // session until playback actually starts. Activating this non-mixable
        // category while idle would interrupt audio from other apps.
        do {
            try configurePlaybackSession(session)
        } catch {
            plog("Failed to configure audio session: \(error)")
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

    private func configurePlaybackSession(_ session: AVAudioSession) throws {
        // Long-form audio lets AirPlay own this app's route independently from
        // the device's default output, so other apps can keep using the phone.
        // It deliberately stays non-mixable on the selected route.
        try session.setCategory(
            .playback,
            mode: .default,
            policy: .longFormAudio,
            options: []
        )
    }

    /// 提示系统把硬件输出 sample rate 切到目标值, 避免 CoreAudio 重采样
    /// (44.1 → 48 这种)。仅 hint, 系统可能拒绝。返回实际生效的 SR (失败
    /// 时返回当前值)。Hz 单位。0 / 不合理值会被忽略。
    @discardableResult
    func setPreferredSampleRate(_ targetHz: Double) -> Double {
        let session = AVAudioSession.sharedInstance()
        guard targetHz >= 8000, targetHz <= 384_000 else {
            return session.sampleRate
        }
        do {
            try session.setPreferredSampleRate(targetHz)
        } catch {
            plog("setPreferredSampleRate(\(targetHz)) failed: \(error)")
        }
        return session.sampleRate
    }

    func deactivate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            plog("Failed to deactivate audio session: \(error)")
        }
    }

    /// 当前输出是否为蓝牙 HFP(通话档)。其他 app 抢占麦克风(微信长按说话、
    /// 语音备忘录等)时系统会把蓝牙从 A2DP 切到 HFP; 此时激活本 app 的
    /// 非混音播放会话会把对方刚开始的录音打断。
    var outputRouteIsBluetoothHFP: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .bluetoothHFP }
    }

    /// 当前输出是否仍在蓝牙设备上(任意 profile)。
    var outputRouteIsBluetooth: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .bluetoothA2DP
                || $0.portType == .bluetoothHFP
                || $0.portType == .bluetoothLE
        }
    }

    var outputRouteIsBuiltIn: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
        }
    }

    /// Foreground interruption recovery must never activate Primuse's
    /// non-mixable playback session while another app is still producing audio.
    var otherAudioIsPlaying: Bool {
        AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    // MARK: - Interruption Handling

    @objc private nonisolated func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        // 中断通知同样可能在非主线程 selector 回调(同 handleConfigurationChange),
        // 标 nonisolated 避免入口 executor 断言。在 hop 外把 Sendable 值提取好,
        // 避免把非 Sendable 的 userInfo 捕获进 Task。
        let shouldResume: Bool = {
            guard type == .ended else { return false }
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            return AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
        }()
        let eventTime = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                // Another app took audio focus. Sync UI to paused state.
                plog("🔇 Audio interruption began")
                self.onInterruptionBegan?(eventTime)

            case .ended:
                // Always forward the ending. The player owns user intent and
                // generation checks; `.shouldResume` alone is not authorization.
                if shouldResume {
                    plog("🔊 Audio interruption ended — shouldResume")
                } else {
                    plog("🔊 Audio interruption ended — should NOT resume")
                }
                self.onInterruptionEnded?(shouldResume)

            @unknown default:
                break
            }
        }
    }

    @objc private nonisolated func handleConfigurationChange(_ notification: Notification) {
        // NSNotificationCenter 用 selector 在 AVAudioEngine 的 engine 队列(非主线程)
        // 调本方法; @MainActor 方法入口的 executor 断言会 trap(iOS 26 默认 fatal)。
        // 标 nonisolated 让入口任意线程, 内部 Task 再 hop 回主线程访问 @MainActor 状态。
        let eventTime = Date()
        Task { @MainActor [weak self] in
            plog("🔧 Audio engine configuration changed")
            self?.onConfigurationChange?(eventTime)
        }
    }

#else
    // macOS has no AVAudioSession — Core Audio routes/interruptions don't
    // need explicit setup. These no-op stubs let the iOS-shaped call sites
    // stay platform-agnostic.
    @discardableResult
    func activatePlaybackSession(reacquiringLocalRouteFocus: Bool = false) -> Bool { true }
    func prepareForPlayback() {}
    func deactivate() {}
    var outputRouteIsBluetoothHFP: Bool { false }
    var outputRouteIsBluetooth: Bool { false }
    var outputRouteIsBuiltIn: Bool { false }
    var otherAudioIsPlaying: Bool { false }
#endif
}
