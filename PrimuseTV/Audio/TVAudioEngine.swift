#if os(tvOS)
import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// tvOS 真实音频播放引擎 —— AVPlayer + AVAudioSession + Now Playing Info / 遥控中心。
/// 只播纯 https 流(由 PrimuseKit 的 StreamResolver 解析得到的 URL)。
@MainActor
@Observable
final class TVAudioEngine {
    enum Status: Equatable { case idle, loading, playing, paused, failed(String) }

    private(set) var status: Status = .idle
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    /// 一曲播完回调(队列推进用;Phase 1 可空)。
    var onEnded: (() -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObs: NSKeyValueObservation?
    private var sessionConfigured = false
    private var resourceLoader: TVStreamResourceLoader?   // 自定义播放头时强引用(delegate 弱持有)

    private var npTitle = ""
    private var npArtist = ""
    private var npAlbum = ""

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        addPeriodicObserver()
        setupRemoteCommands()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnded() }
        }
    }

    // 注:引擎随 app 生命周期存在(TVStore 持有,单例式),观察者用 [weak self]
    // 无循环引用;不写 deinit 清理(Swift 6 deinit 无法访问 MainActor 隔离属性)。

    // MARK: 音频会话(这一步才会真正出声)

    func configureAudioSession() {
        guard !sessionConfigured else { return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default)
            try s.setActive(true)
            sessionConfigured = true
        } catch {
            NSLog("TVAudioEngine: audio session error %@", String(describing: error))
        }
    }

    // MARK: 载入 / 传输

    func load(url: URL, headers: [String: String] = [:], fileExtension: String? = nil,
              title: String, artist: String, album: String, duration: Double) {
        configureAudioSession()
        npTitle = title; npArtist = artist; npAlbum = album
        self.duration = duration
        currentTime = 0
        status = .loading
        let item: AVPlayerItem
        // 所有 http(s) 流都走 resource loader:它能接受自签证书(个人 NAS)、带自定义头
        // (UA/Bearer)、按 Range 取数支持 seek。裸 AVPlayerItem(url:) 对自签证书会
        // 直接「Cannot Open」。file:// 等非网络 scheme 才直连。
        if (url.scheme == "https" || url.scheme == "http"),
           let masked = TVStreamResourceLoader.maskedURL(from: url) {
            let loader = TVStreamResourceLoader(realURL: url, headers: headers, fileExtension: fileExtension)
            let asset = AVURLAsset(url: masked)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "tv.resourceloader"))
            resourceLoader = loader
            item = AVPlayerItem(asset: asset)
        } else {
            resourceLoader = nil
            item = AVPlayerItem(url: url)
        }
        plog("📺 TV engine.load host=\(url.host ?? "?") scheme=\(url.scheme ?? "?") headers=\(headers.count) dur=\(duration)")
        itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                switch item.status {
                case .readyToPlay:
                    plog("📺 TV engine: item readyToPlay dur=\(item.duration.seconds)")
                case .failed:
                    let msg = item.error?.localizedDescription ?? "播放失败"
                    plog("📺 TV engine: item FAILED — \(msg)")
                    self?.status = .failed(msg)
                    self?.isPlaying = false
                default: break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        updateNowPlayingInfo()
    }

    func play() {
        configureAudioSession()
        player.play()
        isPlaying = true
        status = .playing
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        status = .paused
        updateNowPlayingInfo()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        status = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateNowPlayingInfo() }
        }
    }

    func seekToFraction(_ f: Double) {
        guard duration > 0 else { return }
        seek(to: duration * max(0, min(1, f)))
    }

    func skip(by delta: Double) { seek(to: currentTime + delta) }

    // MARK: 内部

    private func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if time.seconds.isFinite { self.currentTime = time.seconds }
                self.isPlaying = (self.player.timeControlStatus == .playing)
                if self.duration <= 0, let item = self.player.currentItem {
                    let d = item.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                }
                if let item = self.player.currentItem, item.status == .failed {
                    self.status = .failed(item.error?.localizedDescription ?? "播放失败")
                    self.isPlaying = false
                }
            }
        }
    }

    private func handleEnded() {
        isPlaying = false
        currentTime = duration
        status = .paused
        onEnded?()
    }

    // MARK: Now Playing Info / 遥控

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle,
            MPMediaItemPropertyArtist: npArtist,
            MPMediaItemPropertyAlbumTitle: npAlbum,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }; return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }; return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: e.positionTime) }; return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: 10) }; return .success
        }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(by: -10) }; return .success
        }
    }

    // MARK: DEBUG 冒烟测试 — 用公开 mp3 证明引擎真出声(模拟器可验,不靠听)

    #if DEBUG
    func runSmokeTest(viaLoader: Bool = false) {
        guard let url = URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3") else { return }
        load(url: url, headers: viaLoader ? ["X-Primuse-Test": "1"] : [:],
             title: "Smoke Test", artist: "Primuse", album: "", duration: 0)
        play()
        Task { @MainActor in
            var passed = false
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if player.timeControlStatus == .playing, currentTime > 0.4 { passed = true; break }
            }
            let msg = passed
                ? "AUDIO_SMOKE_PASS t=\(String(format: "%.2f", currentTime))"
                : "AUDIO_SMOKE_FAIL tc=\(player.timeControlStatus.rawValue) t=\(String(format: "%.2f", currentTime)) status=\(status)"
            Self.writeSmokeResult(msg)
        }
    }

    private static func writeSmokeResult(_ msg: String) {
        NSLog("%@", msg)
        if let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? msg.write(to: dir.appendingPathComponent("audio_smoke_result.txt"),
                           atomically: true, encoding: .utf8)
        }
    }
    #endif
}
#endif
