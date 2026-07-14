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

    private var isConfigured = false

    private init() {}

#if os(iOS)

    @discardableResult
    func activatePlaybackSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            return true
        } catch {
            plog("Failed to activate audio session: \(error)")
            return false
        }
    }

    func configureForPlayback() {
        let session = AVAudioSession.sharedInstance()
        _ = activatePlaybackSession()

        guard !isConfigured else { return }
        isConfigured = true

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
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                // Another app took audio focus. Sync UI to paused state.
                plog("🔇 Audio interruption began")
                self.onInterruptionBegan?()

            case .ended:
                // Interruption ended. Check if we should auto-resume.
                if shouldResume {
                    plog("🔊 Audio interruption ended — shouldResume")
                    _ = self.activatePlaybackSession()
                    self.onInterruptionEndedShouldResume?()
                } else {
                    plog("🔊 Audio interruption ended — should NOT resume")
                }

            @unknown default:
                break
            }
        }
    }

    @objc private nonisolated func handleConfigurationChange(_ notification: Notification) {
        // NSNotificationCenter 用 selector 在 AVAudioEngine 的 engine 队列(非主线程)
        // 调本方法; @MainActor 方法入口的 executor 断言会 trap(iOS 26 默认 fatal)。
        // 标 nonisolated 让入口任意线程, 内部 Task 再 hop 回主线程访问 @MainActor 状态。
        Task { @MainActor [weak self] in
            plog("🔧 Audio engine configuration changed")
            self?.onConfigurationChange?()
        }
    }

#else
    // macOS has no AVAudioSession — Core Audio routes/interruptions don't
    // need explicit setup. These no-op stubs let the iOS-shaped call sites
    // stay platform-agnostic.
    @discardableResult
    func activatePlaybackSession() -> Bool { true }
    func configureForPlayback() {}
    func deactivate() {}
#endif
}
