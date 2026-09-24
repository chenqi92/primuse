import AVFoundation
import Foundation
import PrimuseKit

/// Retain the sender until the queued callback has been handled. An identifier
/// alone can be reused after the old graph is deallocated. The engine is never
/// read or mutated across actors here; only its identity is inspected.
private struct AudioEngineNotificationSource: @unchecked Sendable {
    let engine: AVAudioEngine?
    var identifier: ObjectIdentifier? { engine.map(ObjectIdentifier.init) }
}

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
    var onConfigurationChange: ((Date, ObjectIdentifier?) -> Void)?

    private var isConfigured = false
    /// 卡拉OK麦克风开着时会话要能录音; 其余时候一律回到长音频播放。
    private(set) var isMicrophoneCaptureActive = false

    private init() {}

#if os(iOS)

    @discardableResult
    func activatePlaybackSession(reacquiringLocalRouteFocus: Bool = false) -> Bool {
        do {
            try requirePlaybackSession(reacquiringLocalRouteFocus: reacquiringLocalRouteFocus)
            return true
        } catch {
            return false
        }
    }

    func requirePlaybackSession(reacquiringLocalRouteFocus: Bool = false) throws {
        // setActive 是同步的跨进程调用, 蓝牙 / AirPlay 路由下可能耗时很久,
        // 而它跑在主 actor 上。先标出区间, 设备上才能把卡顿归因到会话激活。
        let signpost = PrimuseSignposts.hitch.beginInterval("player.sessionActivate")
        defer { PrimuseSignposts.hitch.endInterval("player.sessionActivate", signpost) }
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
                throw PlaybackAudioSessionFailure(error)
            }
        }
        do {
            try configurePlaybackSession(session)
            try session.setActive(true)
        } catch {
            plog("Failed to activate audio session: \(error)")
            throw PlaybackAudioSessionFailure(error)
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
        if isMicrophoneCaptureActive {
            // 卡拉OK麦克风: longFormAudio 只能配 .playback。A2DP 让蓝牙耳机保持
            // 高音质输出、麦克风走机身; 不加的话系统会切到通话音质的 HFP。
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                policy: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]
            )
        } else {
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
        }
        // Let Control Center and compatible AirPods know this Now Playing app
        // can supply genuine multichannel presentations through AVPlayer.
        try session.setSupportsMultichannelContent(true)
    }

    /// 切换卡拉OK麦克风所需的会话类别。播放图会收到一次配置变更。
    func setMicrophoneCaptureActive(_ active: Bool) throws {
        guard isMicrophoneCaptureActive != active else { return }
        isMicrophoneCaptureActive = active
        do {
            try requirePlaybackSession()
        } catch {
            // 回到能播放的类别, 不让一次失败把播放也带挂。
            isMicrophoneCaptureActive = false
            if active { try? requirePlaybackSession() }
            throw error
        }
    }

    /// 输出是否适合耳返: 有线/USB 耳机才行。蓝牙延迟太大, 外放会啸叫。
    var outputRouteSupportsMicrophoneMonitoring: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .headphones
                || $0.portType == .usbAudio
                || $0.portType == .lineOut
        }
    }

    /// 提示系统把硬件输出 sample rate 切到目标值, 避免 CoreAudio 重采样
    /// (44.1 → 48 这种)。仅 hint, 系统可能拒绝。返回实际生效的 SR (失败
    /// 时返回当前值)。Hz 单位。0 / 不合理值会被忽略。
    @discardableResult
    func setPreferredSampleRate(_ targetHz: Double) -> Double {
        // 硬件采样率协商同样是同步 IPC, 与会话激活分开计量。
        let signpost = PrimuseSignposts.hitch.beginInterval("player.hardwareRate")
        defer { PrimuseSignposts.hitch.endInterval("player.hardwareRate", signpost) }
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
        // .notifyOthersOnDeactivation 会让系统通知其他 app, 停止路径上的这次
        // 同步调用同样可能拖住主 actor。
        let signpost = PrimuseSignposts.hitch.beginInterval("player.sessionDeactivate")
        defer { PrimuseSignposts.hitch.endInterval("player.sessionDeactivate", signpost) }
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

    /// Bluetooth and AirPlay devices negotiate their own transport clock.
    /// The app should render at the rate they report instead of repeatedly
    /// requesting a new hardware rate for each track.
    var outputRouteIsSystemManagedWireless: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .airPlay
                || $0.portType == .bluetoothA2DP
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
        let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt
        let outputTypes = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }.joined(separator: ",")
        let eventTime = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                plog("🔇 Audio interruption began reason=\(reasonValue.map(String.init) ?? "nil") outputs=[\(outputTypes)]")
                self.onInterruptionBegan?(eventTime)

            case .ended:
                // Always forward the ending. The player owns user intent and
                // generation checks; `.shouldResume` alone is not authorization.
                if shouldResume {
                    plog("🔊 Audio interruption ended — shouldResume outputs=[\(outputTypes)]")
                } else {
                    plog("🔊 Audio interruption ended — should NOT resume outputs=[\(outputTypes)]")
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
        let source = AudioEngineNotificationSource(engine: notification.object as? AVAudioEngine)
        Task { @MainActor [weak self] in
            plog("🔧 Audio engine configuration changed")
            self?.onConfigurationChange?(eventTime, source.identifier)
        }
    }

#else
    // macOS has no AVAudioSession, but AVAudioEngine still stops and
    // uninitializes itself when the output device changes sample rate or
    // channel layout. Observe that event so the player can rebuild the graph
    // after the hardware has settled.
    @discardableResult
    func activatePlaybackSession(reacquiringLocalRouteFocus: Bool = false) -> Bool { true }
    func requirePlaybackSession(reacquiringLocalRouteFocus: Bool = false) throws {}
    func prepareForPlayback() {
        guard !isConfigured else { return }
        isConfigured = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    @objc private nonisolated func handleConfigurationChange(_ notification: Notification) {
        let eventTime = Date()
        let source = AudioEngineNotificationSource(engine: notification.object as? AVAudioEngine)
        Task { @MainActor [weak self] in
            plog("🔧 Audio engine configuration changed")
            self?.onConfigurationChange?(eventTime, source.identifier)
        }
    }

    func deactivate() {}
    /// Mac 不用切会话类别, 只记状态。
    func setMicrophoneCaptureActive(_ active: Bool) throws {
        isMicrophoneCaptureActive = active
    }
    /// Mac 分不清外放和耳机, 耳返由用户自己决定开不开。
    var outputRouteSupportsMicrophoneMonitoring: Bool { true }
    var outputRouteIsBluetoothHFP: Bool { false }
    var outputRouteIsBluetooth: Bool { false }
    var outputRouteIsSystemManagedWireless: Bool { false }
    var outputRouteIsBuiltIn: Bool { false }
    var otherAudioIsPlaying: Bool { false }
#endif
}
