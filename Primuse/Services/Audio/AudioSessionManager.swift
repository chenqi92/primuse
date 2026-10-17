import AVFoundation
import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

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
    /// 第二个参数是发出通知的那张输出图的编号；别的引擎或已经换掉的图发的为 nil。
    var onConfigurationChange: ((Date, AudioEngineGraphToken?) -> Void)?

    private var isConfigured = false
    /// 卡拉OK麦克风开着时会话要能录音; 其余时候一律回到长音频播放。
    private(set) var isMicrophoneCaptureActive = false
    /// 用户打开了「与其他 App 同时播放」。
    private(set) var mixesWithOthersRequested = false
    /// CarPlay 连着时不混音: 混音的会话当不了系统的「正在播放」App, 车机上就没有
    /// 播放页, 方向盘键也到不了这里。
    private(set) var isCarPlayActive = false
    private var mixesWithOthers: Bool { mixesWithOthersRequested && !isCarPlayActive }
    /// 后台被系统拒绝独占, 眼下用可混音的会话在放(见 `PlaybackSessionBackgroundActivationPolicy`)。
    private(set) var isBackgroundMixingFallbackActive = false
    private var exclusiveRestoreTask: Task<Void, Never>?

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
            if isBackgroundMixingFallbackActive {
                endBackgroundMixingFallback()
                plog("🔊 Audio session back to exclusive playback reason=activation")
            }
        } catch {
            if activateBackgroundMixingFallback(session, after: error) { return }
            plog("Failed to activate audio session: \(error)")
            throw PlaybackAudioSessionFailure(error)
        }
    }

    /// 后台被拒绝独占('!int')时改用可混音激活, 这首歌先接上。成功返回 true。
    private func activateBackgroundMixingFallback(_ session: AVAudioSession, after error: Error) -> Bool {
        guard PlaybackSessionBackgroundActivationPolicy.shouldRetryAsMixable(
            failureCode: (error as NSError).code,
            fallbackIsActive: isBackgroundMixingFallbackActive,
            capturesMicrophone: isMicrophoneCaptureActive,
            alreadyMixable: mixesWithOthers
        ) else { return false }
        do {
            try configurePlaybackSession(session, mixable: true)
            try session.setActive(true)
        } catch let fallbackError {
            plog("Failed to activate mixable audio session after \(error): \(fallbackError)")
            return false
        }
        if !isBackgroundMixingFallbackActive {
            isBackgroundMixingFallbackActive = true
            plog("🔊 Exclusive audio session refused in background; playing as mixable until it can be restored: \(error)")
        }
        // 这首起播后再试一次切回独占: 已经在出声的会话也许能改类别。
        exclusiveRestoreTask?.cancel()
        exclusiveRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.restoreExclusivePlaybackIfNeeded(reason: "after-mixable-start")
        }
        return true
    }

    /// 靠可混音在放的时候找机会切回独占, 锁屏和耳机按键才重新控制得到 Primuse。
    func restoreExclusivePlaybackIfNeeded(reason: String) {
        guard isBackgroundMixingFallbackActive else { return }
        let session = AVAudioSession.sharedInstance()
        guard PlaybackSessionBackgroundActivationPolicy.shouldAttemptExclusiveRestore(
            fallbackIsActive: isBackgroundMixingFallbackActive,
            otherAudioIsPlaying: session.isOtherAudioPlaying
        ) else { return }
        let signpost = PrimuseSignposts.hitch.beginInterval("player.sessionActivate")
        defer { PrimuseSignposts.hitch.endInterval("player.sessionActivate", signpost) }
        do {
            try configurePlaybackSession(session)
            try session.setActive(true)
            endBackgroundMixingFallback()
            plog("🔊 Audio session back to exclusive playback reason=\(reason)")
        } catch {
            plog("Exclusive audio session still refused reason=\(reason): \(error)")
            // 类别可能已经改成独占而激活没成, 改回可混音让正在放的歌接着放。
            do {
                try configurePlaybackSession(session, mixable: true)
                try session.setActive(true)
            } catch {
                plog("Failed to keep mixable audio session: \(error)")
            }
        }
    }

    private func endBackgroundMixingFallback() {
        isBackgroundMixingFallbackActive = false
        exclusiveRestoreTask?.cancel()
        exclusiveRestoreTask = nil
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

        // 后台靠可混音接上的歌, 回到前台就能切回独占。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive(_:)),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// 混音偏好或 CarPlay 状态变了。会话已经配过类别时当场换掉: 激活着就立刻按新类别
    /// 与别的 App 共处, 没激活时只改类别, 不去打断别人。
    func setMixingPreference(requested: Bool, carPlayActive: Bool) {
        let wasMixing = mixesWithOthers
        mixesWithOthersRequested = requested
        isCarPlayActive = carPlayActive
        guard isConfigured, mixesWithOthers != wasMixing else { return }
        plog("🔊 Audio session mixWithOthers=\(mixesWithOthers) requested=\(requested) carPlay=\(carPlayActive)")
        do {
            try configurePlaybackSession(AVAudioSession.sharedInstance())
            // 用户自己要混音了, 不再是临时的。
            if mixesWithOthers { endBackgroundMixingFallback() }
        } catch {
            plog("Failed to switch audio session mixing: \(error)")
        }
    }

    /// `mixable` 不传时按用户设置与 CarPlay 状态; 后台被拒独占时临时传 true。
    private func configurePlaybackSession(_ session: AVAudioSession, mixable: Bool? = nil) throws {
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
        } else if mixable ?? mixesWithOthers {
            // 长音频路由策略不许带任何选项(SDK 头文件: Allowed options: None),
            // 要混音只能退回默认策略。
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .default,
                options: [.mixWithOthers]
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
            return
        }
        leaveBackgroundMixingFallback()
    }

    /// 会话已经不在激活状态(主动停用或被系统中断)时收掉临时混音, 类别改回独占:
    /// 视频播放器之类自己激活会话时不该带着它, 回到前台也不必再去唤醒闲着的会话。
    private func leaveBackgroundMixingFallback() {
        guard isBackgroundMixingFallbackActive else { return }
        endBackgroundMixingFallback()
        do {
            try configurePlaybackSession(AVAudioSession.sharedInstance())
        } catch {
            plog("Failed to restore exclusive audio session category: \(error)")
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

    /// Identifies the current output route, so what one route did with a
    /// preferred sample rate is not assumed of the next.
    var outputRouteKey: String {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portType.rawValue)#\($0.uid)" }
            .joined(separator: "|")
    }

    var outputRouteIsBuiltIn: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
        }
    }

    /// Foreground interruption recovery must never activate Primuse's
    /// non-mixable playback session while another app is still producing audio.
    /// 混音时本来就和别的 App 一起出声, 它们在响不妨碍恢复。
    var otherAudioIsPlaying: Bool {
        guard !mixesWithOthers else { return false }
        return AVAudioSession.sharedInstance().isOtherAudioPlaying
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
                self.leaveBackgroundMixingFallback()
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

    @objc private nonisolated func handleApplicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.restoreExclusivePlaybackIfNeeded(reason: "foreground")
        }
    }

    @objc private nonisolated func handleConfigurationChange(_ notification: Notification) {
        // NSNotificationCenter 用 selector 在 AVAudioEngine 的 engine 队列(非主线程)
        // 调本方法; @MainActor 方法入口的 executor 断言会 trap(iOS 26 默认 fatal)。
        // 标 nonisolated 让入口任意线程, 内部 Task 再 hop 回主线程访问 @MainActor 状态。
        let eventTime = Date()
        // 发出时引擎可能正在释放，只能在这里当场换成编号，不能把引擎带进 Task。
        let graph = AudioEngineGraphRegistry.shared.token(forNotificationObject: notification.object)
        Task { @MainActor [weak self] in
            plog("🔧 Audio engine configuration changed")
            self?.onConfigurationChange?(eventTime, graph)
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
    func restoreExclusivePlaybackIfNeeded(reason: String) {}
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
        // 发出时引擎可能正在释放，只能在这里当场换成编号，不能把引擎带进 Task。
        let graph = AudioEngineGraphRegistry.shared.token(forNotificationObject: notification.object)
        Task { @MainActor [weak self] in
            plog("🔧 Audio engine configuration changed")
            self?.onConfigurationChange?(eventTime, graph)
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
    /// Mac 上各个 App 本来就同时出声。
    func setMixingPreference(requested: Bool, carPlayActive: Bool) {}
#endif
}
