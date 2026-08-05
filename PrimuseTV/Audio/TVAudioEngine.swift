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
    private(set) var isLiveStream = false
    var displayPlayer: AVPlayer { player }

    /// 一曲播完回调(队列推进用;Phase 1 可空)。
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onLiveMetadata: ((String) -> Void)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObs: NSKeyValueObservation?
    private var sessionCategoryConfigured = false
    private var sessionIsActive = false
    private var resourceLoader: TVStreamResourceLoader?   // 自定义播放头时强引用(delegate 弱持有)
    private var protocolLoader: TVProtocolResourceLoader?  // 协议直连(SMB/NFS/FTP/SFTP)时强引用
    private var activeItemID: ObjectIdentifier?
    private var liveMetadataOutput: AVPlayerItemMetadataOutput?
    private var liveMetadataReceiver: TVLiveMetadataReceiver?
    private var liveStartedAt: Date?

    private struct LiveRequest: Sendable {
        let url: URL
        let title: String
        let subtitle: String
        let format: String
        let streamFormat: RadioStreamFormat
    }
    private var liveRequest: LiveRequest?

    // 非原生格式(APE/WavPack/DSD 等 AVPlayer 解不了的)走 SFBAudioEngine。两引擎并列,
    // usingSFB 决定 play/pause/seek/时间读取走哪一个。
    @ObservationIgnored private lazy var sfb: TVSFBEngine = {
        let e = TVSFBEngine()
        e.onEnded = { [weak self] in self?.handleEnded() }
        e.onStateChange = { [weak self] in self?.syncFromSFB() }
        e.onFailure = { [weak self] message in self?.handleSFBFailure(message) }
        return e
    }()
    private var usingSFB = false
    @ObservationIgnored private var sfbTimer: Timer?
    @ObservationIgnored private var decodedTemporaryFileURL: URL?
    @ObservationIgnored private var radioLiveStreamSource: RadioLiveStreamSource?
    @ObservationIgnored private var radioLiveStreamTask: Task<Void, Never>?
    @ObservationIgnored private let radioFLACDecoder = RadioFLACAudioDecoder()
    @ObservationIgnored private let livePCMEngine = AVAudioEngine()
    @ObservationIgnored private let livePCMNode = AVAudioPlayerNode()
    @ObservationIgnored private var livePCMNodeAttached = false
    @ObservationIgnored private var usingLivePCM = false
    @ObservationIgnored private var livePCMBufferGate: TVLivePCMBufferGate?
    @ObservationIgnored private var livePCMTimer: Timer?
    @ObservationIgnored private var decodedRadioURLs: Set<String> = []
    @ObservationIgnored private var rejectedDecodedRadioURLs: Set<String> = []
    @ObservationIgnored private var liveDidAttemptDecodedFallback = false
    @ObservationIgnored private var liveDecodedFallbackNeedsValidation = false

    private var npTitle = ""
    private var npArtist = ""
    private var npAlbum = ""

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        addPeriodicObserver()
        setupRemoteCommands()
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

    /// Synchronously detaches the previous track before an asynchronous resolver
    /// starts. Keeping the audio session active avoids an avoidable route handoff
    /// between adjacent queue items, while all track-specific state is cleared.
    func prepareForSelection(startAt seconds: Double) {
        clearLiveState()
        resetSFBIfNeeded()
        itemStatusObs?.invalidate()
        itemStatusObs = nil
        removeEndObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        activeItemID = nil
        resourceLoader = nil
        protocolLoader = nil
        isVideoMode = false
        isPlaying = false
        currentTime = seconds.isFinite ? max(0, seconds) : 0
        duration = 0
        status = .loading
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func load(url: URL, headers: [String: String] = [:], fileExtension: String? = nil,
              title: String, artist: String, album: String, duration: Double) {
        load(url: url, headers: headers, fileExtension: fileExtension,
             title: title, artist: artist, album: album, duration: duration, isVideo: false)
    }

    func load(url: URL, headers: [String: String] = [:], fileExtension: String? = nil,
              title: String, artist: String, album: String, duration: Double, isVideo: Bool) {
        clearLiveState()
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

    func loadLiveRadio(
        url: URL,
        title: String,
        subtitle: String,
        format: String,
        streamFormat: RadioStreamFormat
    ) {
        let request = LiveRequest(
            url: url,
            title: title,
            subtitle: subtitle,
            format: format,
            streamFormat: streamFormat
        )
        let urlKey = url.absoluteString
        let knownDecoded = streamFormat == .flac
            || RadioStreamFormat.inferred(from: url) == .flac
            || decodedRadioURLs.contains(urlKey)
        liveDidAttemptDecodedFallback = knownDecoded || rejectedDecodedRadioURLs.contains(urlKey)
        liveDecodedFallbackNeedsValidation = false
        liveRequest = request
        startLiveRadio(request)
    }

    private func startLiveRadio(_ request: LiveRequest) {
        resetSFBIfNeeded()
        itemStatusObs?.invalidate()
        itemStatusObs = nil
        removeEndObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        activeItemID = nil
        resourceLoader = nil
        protocolLoader = nil
        isVideoMode = false
        isLiveStream = true
        npTitle = request.title
        npArtist = request.subtitle
        npAlbum = request.format
        duration = 0
        currentTime = 0
        isPlaying = false
        status = .loading
        liveStartedAt = nil

        if request.streamFormat == .flac
            || RadioStreamFormat.inferred(from: request.url) == .flac
            || decodedRadioURLs.contains(request.url.absoluteString) {
            startDecodedLiveRadio(request)
            return
        }

        let item = AVPlayerItem(url: request.url)
        item.preferredForwardBufferDuration = 3
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        let receiver = TVLiveMetadataReceiver { [weak self] title in
            Task { @MainActor [weak self] in
                guard let self, self.isLiveStream else { return }
                self.npArtist = title
                self.onLiveMetadata?(title)
                self.updateNowPlayingInfo()
            }
        }
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(receiver, queue: .main)
        item.add(output)
        liveMetadataReceiver = receiver
        liveMetadataOutput = output
        finishLoad(item: item)
        play()
    }

    private func startDecodedLiveRadio(_ request: LiveRequest) {
        activateAudioSession()
        let source = RadioLiveStreamSource(url: request.url) { [weak self] title in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isLiveStream,
                      self.liveRequest?.url == request.url,
                      self.radioLiveStreamSource != nil else { return }
                self.npArtist = title
                self.onLiveMetadata?(title)
                self.updateNowPlayingInfo()
            }
        }
        radioLiveStreamSource = source
        radioLiveStreamTask = Task { @MainActor [weak self, source] in
            guard let self else { return }
            do {
                let prepared = try await source.prepare()
                guard !Task.isCancelled,
                      self.isLiveStream,
                      self.radioLiveStreamSource === source else { return }
                guard let outputFormat = AVAudioFormat(
                    standardFormatWithSampleRate: 44_100,
                    channels: 2
                ) else {
                    throw NSError(
                        domain: "com.welape.yuanyin.tv-radio",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to configure live audio output."]
                    )
                }
                let stream = self.radioFLACDecoder.decode(
                    from: source,
                    prepared: prepared,
                    outputFormat: outputFormat
                )
                var iterator = stream.makeAsyncIterator()
                guard let firstBuffer = try await iterator.next() else {
                    throw NSError(
                        domain: "com.welape.yuanyin.tv-radio",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The radio stream returned no audio frames."]
                    )
                }
                guard !Task.isCancelled,
                      self.isLiveStream,
                      self.radioLiveStreamSource === source else { return }

                try self.configureLivePCM(format: outputFormat)
                let gate = TVLivePCMBufferGate(limit: 6)
                self.livePCMBufferGate = gate
                await gate.acquire()
                self.scheduleLivePCM(firstBuffer, gate: gate)
                self.livePCMNode.play()
                self.decodedRadioURLs.insert(request.url.absoluteString)
                self.rejectedDecodedRadioURLs.remove(request.url.absoluteString)
                self.liveDecodedFallbackNeedsValidation = false
                self.isPlaying = true
                self.status = .playing
                self.liveStartedAt = Date()
                self.startLivePCMPolling()
                self.updateNowPlayingInfo()

                while let buffer = try await iterator.next() {
                    await gate.acquire()
                    guard !Task.isCancelled,
                          self.isLiveStream,
                          self.radioLiveStreamSource === source,
                          self.usingLivePCM else { return }
                    self.scheduleLivePCM(buffer, gate: gate)
                }
                guard !Task.isCancelled,
                      self.isLiveStream,
                      self.radioLiveStreamSource === source else { return }
                self.handleSFBFailure(PMString("ext.tv.playback.failed"))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.isLiveStream,
                      self.radioLiveStreamSource === source else { return }
                self.handleSFBFailure(error.localizedDescription)
            }
        }
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
        clearLiveState()
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
        removeEndObserver()
        let observedItemID = ObjectIdentifier(item)
        activeItemID = observedItemID
        itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            // KVO 回调在属性变更线程上同步执行,AVFoundation 不保证主线程投递(.failed 尤其常落后台队列),
            // 故显式跳主线程,不能用 assumeIsolated 假设隔离。
            let status = item.status
            let errorMessage = item.error?.localizedDescription
            let itemDuration = item.duration.seconds
            Task { @MainActor in
                guard let self, self.activeItemID == observedItemID else { return }
                switch status {
                case .readyToPlay:
                    plog("📺 TV engine: item readyToPlay dur=\(itemDuration)")
                case .failed:
                    let msg = errorMessage ?? PMString("ext.tv.playback.failed")
                    plog("📺 TV engine: item FAILED — \(msg)")
                    if self.beginDecodedLiveRadioFallbackIfNeeded() {
                        return
                    }
                    self.status = .failed(msg)
                    self.isPlaying = false
                    self.onFailure?(msg)
                default: break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let endedItem = notification.object as? AVPlayerItem else { return }
            let endedItemID = ObjectIdentifier(endedItem)
            MainActor.assumeIsolated {
                self?.handleAVPlayerItemEnded(endedItemID: endedItemID)
            }
        }
        updateNowPlayingInfo()
    }

    /// 非原生格式:用 SFBAudioEngine 解码播放已下载到本地的文件(AVPlayer 解不了的格式)。
    func loadDecoded(fileURL: URL, title: String, artist: String, album: String, duration: Double) {
        clearLiveState()
        resetSFBIfNeeded()
        activateAudioSession()
        isVideoMode = false
        // 让 AVPlayer 静音让位。
        removeEndObserver()
        player.replaceCurrentItem(with: nil)
        activeItemID = nil
        resourceLoader = nil
        protocolLoader = nil
        npTitle = title; npArtist = artist; npAlbum = album
        self.duration = duration
        currentTime = 0
        status = .loading
        decodedTemporaryFileURL = fileURL
        usingSFB = true
        startSFBPolling()
        do {
            try sfb.play(url: fileURL)
            isPlaying = true
            status = .playing
            plog("📺 TV engine.loadDecoded(SFB) \(fileURL.lastPathComponent) dur=\(duration)")
        } catch {
            sfb.stop()
            usingSFB = false
            stopSFBPolling()
            removeDecodedTemporaryFile()
            status = .failed(error.localizedDescription)
            plog("📺 TV engine: SFB decode FAILED — \(error.localizedDescription)")
        }
        updateNowPlayingInfo()
    }

    func play() {
        activateAudioSession()
        if isLiveStream, player.currentItem == nil, !usingLivePCM, let liveRequest {
            startLiveRadio(liveRequest)
            return
        }
        if usingSFB {
            sfb.resume()
        } else {
            guard player.currentItem != nil else {
                isPlaying = false
                return
            }
            player.play()
        }
        isPlaying = true
        status = .playing
        if isLiveStream, liveStartedAt == nil { liveStartedAt = Date() }
        updateNowPlayingInfo()
    }

    func pause() {
        if isLiveStream {
            removeEndObserver()
            if usingSFB || usingLivePCM {
                resetSFBIfNeeded()
            } else {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            activeItemID = nil
            liveMetadataOutput = nil
            liveMetadataReceiver = nil
            liveStartedAt = nil
            isPlaying = false
            currentTime = 0
            status = .paused
            updateNowPlayingInfo()
            return
        }
        if usingSFB { sfb.pause() } else { player.pause() }
        isPlaying = false
        status = .paused
        updateNowPlayingInfo()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func stop() {
        resetSFBIfNeeded()
        removeEndObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        activeItemID = nil
        isVideoMode = false
        clearLiveState()
        isPlaying = false
        currentTime = 0
        status = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
    }

    func seek(to seconds: Double) {
        guard !isLiveStream else { return }
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
        radioLiveStreamTask?.cancel()
        radioLiveStreamTask = nil
        radioLiveStreamSource?.cancel()
        radioLiveStreamSource = nil
        livePCMBufferGate?.cancel()
        livePCMBufferGate = nil
        stopLivePCMPolling()
        if usingLivePCM {
            livePCMNode.stop()
            livePCMEngine.stop()
            livePCMEngine.reset()
            usingLivePCM = false
        }
        if usingSFB { sfb.stop(); usingSFB = false; stopSFBPolling() }
        removeDecodedTemporaryFile()
    }

    private func configureLivePCM(format: AVAudioFormat) throws {
        livePCMNode.stop()
        livePCMEngine.stop()
        livePCMEngine.reset()
        if !livePCMNodeAttached {
            livePCMEngine.attach(livePCMNode)
            livePCMNodeAttached = true
        }
        livePCMEngine.disconnectNodeOutput(livePCMNode)
        livePCMEngine.connect(livePCMNode, to: livePCMEngine.mainMixerNode, format: format)
        livePCMEngine.prepare()
        try livePCMEngine.start()
        usingLivePCM = true
    }

    private func scheduleLivePCM(
        _ buffer: AVAudioPCMBuffer,
        gate: TVLivePCMBufferGate
    ) {
        livePCMNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataConsumed
        ) { _ in gate.release() }
    }

    private func startLivePCMPolling() {
        stopLivePCMPolling()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.usingLivePCM else { return }
                if let startedAt = self.liveStartedAt {
                    self.currentTime = max(0, Date().timeIntervalSince(startedAt))
                }
                self.isPlaying = self.livePCMNode.isPlaying
                self.updateNowPlayingInfo()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        livePCMTimer = timer
    }

    private func stopLivePCMPolling() {
        livePCMTimer?.invalidate()
        livePCMTimer = nil
    }

    private func removeDecodedTemporaryFile() {
        guard let fileURL = decodedTemporaryFileURL else { return }
        decodedTemporaryFileURL = nil
        do {
            try TVDecodedTemporaryFilePolicy.removeIfManaged(
                fileURL,
                in: FileManager.default.temporaryDirectory
            )
        } catch {
            plog("📺 TV engine: temporary decode cleanup failed — \(error.localizedDescription)")
        }
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
        if isLiveStream, let liveStartedAt {
            currentTime = max(0, Date().timeIntervalSince(liveStartedAt))
        } else {
            let t = sfb.currentTime
            if t.isFinite { currentTime = t }
            if duration <= 0, sfb.duration > 0 { duration = sfb.duration }
        }
        isPlaying = sfb.isPlaying
        updateNowPlayingInfo()
    }

    private func handleSFBFailure(_ message: String) {
        guard usingSFB || radioLiveStreamSource != nil else { return }
        if radioLiveStreamSource != nil,
           liveDecodedFallbackNeedsValidation,
           let url = liveRequest?.url {
            rejectedDecodedRadioURLs.insert(url.absoluteString)
            liveDecodedFallbackNeedsValidation = false
        }
        resetSFBIfNeeded()
        isPlaying = false
        status = .failed(message)
        onFailure?(message)
        updateNowPlayingInfo()
    }

    func seekToFraction(_ f: Double) {
        guard !isLiveStream, duration > 0 else { return }
        seek(to: duration * max(0, min(1, f)))
    }

    func skip(by delta: Double) {
        guard !isLiveStream else { return }
        seek(to: currentTime + delta)
    }

    // MARK: 内部

    private func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let item = self.player.currentItem else { return }
                if self.isLiveStream {
                    if let startedAt = self.liveStartedAt,
                       self.player.timeControlStatus == .playing {
                        self.currentTime = max(0, Date().timeIntervalSince(startedAt))
                    }
                } else if time.seconds.isFinite {
                    self.currentTime = time.seconds
                }
                self.isPlaying = (self.player.timeControlStatus == .playing)
                if !self.isLiveStream, self.duration <= 0 {
                    let d = item.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                }
                if item.status == .failed {
                    self.status = .failed(item.error?.localizedDescription ?? PMString("ext.tv.playback.failed"))
                    self.isPlaying = false
                }
            }
        }
    }

    private func removeEndObserver() {
        guard let endObserver else { return }
        NotificationCenter.default.removeObserver(endObserver)
        self.endObserver = nil
    }

    private func handleAVPlayerItemEnded(endedItemID: ObjectIdentifier) {
        guard PlaybackEndIdentityPolicy.shouldAdvance(
            endedItemID: endedItemID,
            activeItemID: activeItemID,
            currentItemID: player.currentItem.map(ObjectIdentifier.init)
        ) else {
            plog("📺 TV engine: ignored stale didPlayToEnd notification")
            return
        }
        // Make the accepted end transition single-shot before advancing the
        // queue. A repeat/new selection installs a fresh item-bound observer.
        removeEndObserver()
        activeItemID = nil
        handleEnded()
    }

    private func handleEnded() {
        plog("📺 TV engine: didPlayToEnd → advance")
        if usingSFB {
            resetSFBIfNeeded()
        }
        isPlaying = false
        if !isLiveStream { currentTime = duration }
        status = .paused
        onEnded?()
    }

    // MARK: Now Playing Info / 遥控

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle,
            MPMediaItemPropertyArtist: npArtist,
            MPMediaItemPropertyAlbumTitle: npAlbum,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if isLiveStream {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        }
        info[MPNowPlayingInfoPropertyMediaType] = isVideoMode
            ? MPNowPlayingInfoMediaType.video.rawValue
            : MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let commands = MPRemoteCommandCenter.shared()
        commands.changePlaybackPositionCommand.isEnabled = !isLiveStream
        commands.skipForwardCommand.isEnabled = !isLiveStream
        commands.skipBackwardCommand.isEnabled = !isLiveStream
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
            guard self?.isLiveStream != true else { return .commandFailed }
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

    private func clearLiveState() {
        radioLiveStreamTask?.cancel()
        radioLiveStreamTask = nil
        radioLiveStreamSource?.cancel()
        radioLiveStreamSource = nil
        isLiveStream = false
        liveRequest = nil
        liveStartedAt = nil
        liveMetadataOutput = nil
        liveMetadataReceiver = nil
        liveDidAttemptDecodedFallback = false
        liveDecodedFallbackNeedsValidation = false
    }

    private func beginDecodedLiveRadioFallbackIfNeeded() -> Bool {
        guard isLiveStream,
              let request = liveRequest,
              !liveDidAttemptDecodedFallback,
              request.streamFormat == .automatic,
              RadioStreamFormat.inferred(from: request.url) == .automatic,
              !rejectedDecodedRadioURLs.contains(request.url.absoluteString) else {
            return false
        }
        liveDidAttemptDecodedFallback = true
        liveDecodedFallbackNeedsValidation = true
        itemStatusObs?.invalidate()
        itemStatusObs = nil
        removeEndObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        activeItemID = nil
        liveMetadataOutput = nil
        liveMetadataReceiver = nil
        status = .loading
        startDecodedLiveRadio(request)
        return true
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

private actor TVLivePCMBufferGate {
    private let limit: Int
    private var inFlight = 0
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        guard !cancelled else { return }
        if inFlight < limit {
            inFlight += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    nonisolated func release() {
        Task { await signal() }
    }

    nonisolated func cancel() {
        Task { await cancelAll() }
    }

    private func signal() {
        guard !cancelled else { return }
        if waiters.isEmpty {
            inFlight = max(0, inFlight - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func cancelAll() {
        cancelled = true
        inFlight = 0
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private struct TVMetadataItemBox: @unchecked Sendable {
    let item: AVMetadataItem
}

private final class TVLiveMetadataReceiver: NSObject, AVPlayerItemMetadataOutputPushDelegate, @unchecked Sendable {
    private let onTitle: @Sendable (String) -> Void

    init(onTitle: @escaping @Sendable (String) -> Void) {
        self.onTitle = onTitle
    }

    nonisolated func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        let titleItems = groups.flatMap(\.items).compactMap { item -> TVMetadataItemBox? in
            let key = (item.key.map { String(describing: $0) } ?? "").lowercased()
            let commonKey = item.commonKey?.rawValue.lowercased() ?? ""
            guard key.contains("title") || key.contains("streamtitle") || commonKey == "title" else {
                return nil
            }
            return TVMetadataItemBox(item: item)
        }
        guard !titleItems.isEmpty else { return }
        Task { [onTitle] in
            for itemBox in titleItems.reversed() {
                guard let rawValue = try? await itemBox.item.load(.stringValue) else { continue }
                let title = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                onTitle(title)
                return
            }
        }
    }
}
#endif
