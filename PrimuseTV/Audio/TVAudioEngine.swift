#if os(tvOS)
import AVFoundation
import Foundation
import MediaPlayer
import Observation
import PrimuseKit

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
    private(set) var isVideoMode = false
    var displayPlayer: AVPlayer { player }

    /// 一曲播完回调(队列推进用;Phase 1 可空)。
    var onEnded: (() -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObs: NSKeyValueObservation?
    private var sessionCategoryConfigured = false
    private var sessionIsActive = false
    private var resourceLoader: TVStreamResourceLoader?   // 自定义播放头时强引用(delegate 弱持有)
    private var protocolLoader: TVProtocolResourceLoader?  // 协议直连(SMB/NFS/FTP/SFTP)时强引用

    // 非原生格式(APE/WavPack/DSD 等 AVPlayer 解不了的)走 SFBAudioEngine。两引擎并列,
    // usingSFB 决定 play/pause/seek/时间读取走哪一个。
    @ObservationIgnored private lazy var sfb: TVSFBEngine = {
        let e = TVSFBEngine()
        e.onEnded = { [weak self] in self?.handleEnded() }
        e.onStateChange = { [weak self] in self?.syncFromSFB() }
        return e
    }()
    private var usingSFB = false
    @ObservationIgnored private var sfbTimer: Timer?

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

    // MARK: 音频会话(真正播放时才激活)

    private func activateAudioSession() {
        do {
            let s = AVAudioSession.sharedInstance()
            if !sessionCategoryConfigured {
                try s.setCategory(.playback, mode: .default)
                sessionCategoryConfigured = true
            }
            try s.setActive(true)
            sessionIsActive = true
        } catch {
            plog("TVAudioEngine: audio session error \(error)")
        }
    }

    private func deactivateAudioSession() {
        guard sessionIsActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            sessionIsActive = false
        } catch {
            plog("TVAudioEngine: audio session deactivation error \(error)")
        }
    }

    // MARK: 载入 / 传输

    func load(url: URL, headers: [String: String] = [:], fileExtension: String? = nil,
              title: String, artist: String, album: String, duration: Double) {
        load(url: url, headers: headers, fileExtension: fileExtension,
             title: title, artist: artist, album: album, duration: duration, isVideo: false)
    }

    func load(url: URL, headers: [String: String] = [:], fileExtension: String? = nil,
              title: String, artist: String, album: String, duration: Double, isVideo: Bool) {
        resetSFBIfNeeded()
        isVideoMode = isVideo
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
            protocolLoader = nil
            item = AVPlayerItem(asset: asset)
        } else {
            resourceLoader = nil
            protocolLoader = nil
            item = AVPlayerItem(url: url)
        }
        plog("📺 TV engine.load host=\(url.host ?? "?") scheme=\(url.scheme ?? "?") headers=\(headers.count) dur=\(duration)")
        finishLoad(item: item)
    }

    /// 协议直连(SMB / NFS / FTP / SFTP):用 ByteRangeReader 经 AVAssetResourceLoaderDelegate
    /// 把原生协议字节流喂给 AVPlayer,不经 iPhone 中继。
    func load(reader: ByteRangeReader, fileExtension: String?,
              title: String, artist: String, album: String, duration: Double) {
        load(reader: reader, fileExtension: fileExtension,
             title: title, artist: artist, album: album, duration: duration, isVideo: false)
    }

    func load(reader: ByteRangeReader, fileExtension: String?,
              title: String, artist: String, album: String, duration: Double, isVideo: Bool) {
        resetSFBIfNeeded()
        isVideoMode = isVideo
        npTitle = title; npArtist = artist; npAlbum = album
        self.duration = duration
        currentTime = 0
        status = .loading
        guard let url = TVProtocolResourceLoader.makeURL() else {
            status = .failed(PMString("ext.tv.playback.cannotBuildURL")); return
        }
        let loader = TVProtocolResourceLoader(reader: reader, fileExtension: fileExtension)
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "tv.protoloader"))
        protocolLoader = loader
        resourceLoader = nil
        plog("📺 TV engine.load(reader) ext=\(fileExtension ?? "?") dur=\(duration)")
        finishLoad(item: AVPlayerItem(asset: asset))
    }

    /// 挂 KVO 状态观察 + 上播放器 + 刷新 Now Playing。两条 load 路径共用。
    private func finishLoad(item: AVPlayerItem) {
        itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            // KVO 回调在属性变更线程上同步执行,AVFoundation 不保证主线程投递(.failed 尤其常落后台队列),
            // 故显式跳主线程,不能用 assumeIsolated 假设隔离。
            let status = item.status
            let errorMessage = item.error?.localizedDescription
            let itemDuration = item.duration.seconds
            Task { @MainActor in
                switch status {
                case .readyToPlay:
                    plog("📺 TV engine: item readyToPlay dur=\(itemDuration)")
                case .failed:
                    let msg = errorMessage ?? PMString("ext.tv.playback.failed")
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

    /// 非原生格式:用 SFBAudioEngine 解码播放已下载到本地的文件(AVPlayer 解不了的格式)。
    func loadDecoded(fileURL: URL, title: String, artist: String, album: String, duration: Double) {
        activateAudioSession()
        isVideoMode = false
        // 让 AVPlayer 静音让位。
        player.replaceCurrentItem(with: nil)
        resourceLoader = nil
        protocolLoader = nil
        npTitle = title; npArtist = artist; npAlbum = album
        self.duration = duration
        currentTime = 0
        status = .loading
        usingSFB = true
        startSFBPolling()
        do {
            try sfb.play(url: fileURL)
            isPlaying = true
            status = .playing
            plog("📺 TV engine.loadDecoded(SFB) \(fileURL.lastPathComponent) dur=\(duration)")
        } catch {
            usingSFB = false
            stopSFBPolling()
            status = .failed(error.localizedDescription)
            plog("📺 TV engine: SFB decode FAILED — \(error.localizedDescription)")
        }
        updateNowPlayingInfo()
    }

    func play() {
        activateAudioSession()
        if usingSFB { sfb.resume() } else { player.play() }
        isPlaying = true
        status = .playing
        updateNowPlayingInfo()
    }

    func pause() {
        if usingSFB { sfb.pause() } else { player.pause() }
        isPlaying = false
        status = .paused
        updateNowPlayingInfo()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func stop() {
        if usingSFB { sfb.stop(); usingSFB = false; stopSFBPolling() }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isVideoMode = false
        isPlaying = false
        currentTime = 0
        status = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        currentTime = target
        if usingSFB {
            sfb.seek(target)
            updateNowPlayingInfo()
            return
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            // seek completion 回调走 AVPlayer 内部串行队列,不保证主线程,显式跳主线程而非 assumeIsolated。
            Task { @MainActor in self?.updateNowPlayingInfo() }
        }
    }

    // MARK: SFB(非原生格式)引擎切换 / 状态镜像

    /// 切回 AVPlayer 路径前,确保 SFB 引擎停掉、轮询取消。
    private func resetSFBIfNeeded() {
        if usingSFB { sfb.stop(); usingSFB = false; stopSFBPolling() }
    }

    /// SFB 无 AVPlayer 的 periodicTimeObserver,用定时器把 currentTime/duration/isPlaying 镜像进
    /// @Observable 属性,供正在播放页进度与传输键读取。
    private func startSFBPolling() {
        stopSFBPolling()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFromSFB() }
        }
        RunLoop.main.add(t, forMode: .common)
        sfbTimer = t
    }

    private func stopSFBPolling() {
        sfbTimer?.invalidate()
        sfbTimer = nil
    }

    private func syncFromSFB() {
        guard usingSFB else { return }
        let t = sfb.currentTime
        if t.isFinite { currentTime = t }
        if duration <= 0, sfb.duration > 0 { duration = sfb.duration }
        isPlaying = sfb.isPlaying
        updateNowPlayingInfo()
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
                    self.status = .failed(item.error?.localizedDescription ?? PMString("ext.tv.playback.failed"))
                    self.isPlaying = false
                }
            }
        }
    }

    private func handleEnded() {
        plog("📺 TV engine: didPlayToEnd → advance")
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
        info[MPNowPlayingInfoPropertyMediaType] = isVideoMode
            ? MPNowPlayingInfoMediaType.video.rawValue
            : MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 10) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -10) }
            return .success
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
        plog(msg)
        if let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? msg.write(to: dir.appendingPathComponent("audio_smoke_result.txt"),
                           atomically: true, encoding: .utf8)
        }
    }
    #endif
}
#endif
