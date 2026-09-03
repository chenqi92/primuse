#if os(tvOS)
import Accelerate
import AVFoundation
import Foundation
import MediaPlayer
import MediaToolbox
import Observation
import os.lock
import PrimuseKit

private enum TVSpectrumConfiguration {
    static let bandCount = 32
}

enum TVPlaybackInput: CaseIterable, Equatable, Sendable {
    case direction
    case focusChanged
    case menu
    case modalDismissed
    case systemPlay
    case systemPause
    case systemToggle
}

enum TVPlaybackRoutingAction: Equatable, Sendable {
    case none
    case resume
    case pause
    case toggle
}

enum TVPlaybackCommandOwner: Equatable, Sendable {
    case swiftUIForeground
    case mediaRemoteCommandCenter
}

enum TVPlaybackCommandRoutingPolicy {
    static let foregroundOwner: TVPlaybackCommandOwner = .swiftUIForeground
    static let externalOwner: TVPlaybackCommandOwner = .mediaRemoteCommandCenter

    static func action(for input: TVPlaybackInput) -> TVPlaybackRoutingAction {
        switch input {
        case .systemPlay: return .resume
        case .systemPause: return .pause
        case .systemToggle: return .toggle
        case .direction, .focusChanged, .menu, .modalDismissed: return .none
        }
    }
}

/// tvOS 真实音频播放引擎 —— AVPlayer + AVAudioSession + Now Playing Info / 遥控中心。
/// 只播纯 https 流(由 PrimuseKit 的 StreamResolver 解析得到的 URL)。
@MainActor
@Observable
final class TVAudioEngine {
    enum Status: Equatable { case idle, loading, playing, paused, failed(String) }

    private(set) var status: Status = .idle
    private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying, spectrumAnalysisEnabled else { return }
            if isPlaying {
                startSpectrumPolling()
            } else {
                suspendSpectrumPolling()
            }
        }
    }
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isVideoMode = false
    private(set) var isLiveStream = false
    /// 32 个真实频段，供环形声谱与实时波形直接观察。没有采样时始终为零。
    private(set) var spectrumLevels: [Float] = Array(
        repeating: 0,
        count: TVSpectrumConfiguration.bandCount
    )
    var displayPlayer: AVPlayer { player }

    /// 一曲播完回调(队列推进用;Phase 1 可空)。
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onLiveMetadata: ((String) -> Void)?
    var onRemotePlay: (() -> Void)?
    var onRemotePause: (() -> Void)?
    var onRemoteTogglePlayPause: (() -> Void)?
    var onRemotePreviousTrack: (() -> Void)?
    var onRemoteNextTrack: (() -> Void)?

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
    @ObservationIgnored private let spectrumPipeline = TVRealtimeSpectrumPipeline(capacity: 1024)
    @ObservationIgnored private var spectrumTimer: Timer?
    @ObservationIgnored private var processingTap: MTAudioProcessingTap?
    @ObservationIgnored private weak var tappedMixer: AVAudioMixerNode?
    @ObservationIgnored private var spectrumTask: Task<Void, Never>?
    @ObservationIgnored private var spectrumSetupTask: Task<Void, Never>?
    @ObservationIgnored private var spectrumAnalysisEnabled = false
    @ObservationIgnored private var remotePreviousTrackCommandEnabled = false
    @ObservationIgnored private var remoteNextTrackCommandEnabled = false

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
                try s.setSupportsMultichannelContent(true)
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
        disableRemoteTransportCommands()
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
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "radio_live_error_output"
                            )
                        ]
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
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "radio_live_error_no_frames"
                            )
                        ]
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
        item.allowedAudioSpatializationFormats = .multichannel
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
        if spectrumAnalysisEnabled {
            installAVPlayerSpectrumTap(on: item, expectedItemID: observedItemID)
        }
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
            if spectrumAnalysisEnabled { installSFBSpectrumTap() }
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

    @discardableResult
    func play() -> Bool {
        activateAudioSession()
        if isLiveStream, player.currentItem == nil, !usingLivePCM, let liveRequest {
            startLiveRadio(liveRequest)
            return true
        }
        if usingSFB {
            guard sfb.isPlaying || sfb.resume() else {
                isPlaying = false
                status = .paused
                updateNowPlayingInfo()
                return false
            }
        } else {
            guard player.currentItem != nil else {
                isPlaying = false
                status = .paused
                updateNowPlayingInfo()
                return false
            }
            player.play()
        }
        isPlaying = true
        status = .playing
        if isLiveStream, liveStartedAt == nil { liveStartedAt = Date() }
        updateNowPlayingInfo()
        return true
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
            resetSpectrumLevels()
            currentTime = 0
            status = .paused
            updateNowPlayingInfo()
            return
        }
        if usingSFB { sfb.pause() } else { player.pause() }
        isPlaying = false
        resetSpectrumLevels()
        status = .paused
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func setRemoteTrackCommandAvailability(previous: Bool, next: Bool) {
        remotePreviousTrackCommandEnabled = previous
        remoteNextTrackCommandEnabled = next
        let commands = MPRemoteCommandCenter.shared()
        commands.previousTrackCommand.isEnabled = previous
        commands.nextTrackCommand.isEnabled = next
    }

    var hasPreparedAudio: Bool {
        usingSFB || player.currentItem != nil
    }

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
        disableRemoteTransportCommands()
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

    // MARK: 实时频谱

    /// Only spectrum-backed immersive themes opt into PCM taps and FFT work.
    /// Other screens no longer receive an invisible 25Hz observable update.
    func setSpectrumAnalysisEnabled(_ enabled: Bool) {
        guard spectrumAnalysisEnabled != enabled else { return }
        spectrumAnalysisEnabled = enabled
        if enabled {
            installCurrentSpectrumSource()
        } else {
            clearSpectrumSource()
        }
    }

    private func installCurrentSpectrumSource() {
        guard spectrumAnalysisEnabled else { return }
        if usingSFB {
            installSFBSpectrumTap()
        } else if usingLivePCM {
            installMixerSpectrumTap(on: livePCMEngine.mainMixerNode)
        } else if let item = player.currentItem, let activeItemID {
            installAVPlayerSpectrumTap(on: item, expectedItemID: activeItemID)
        }
    }

    /// AVPlayer 的解码结果通过 MTAudioProcessingTap 读取。它只旁路复制 PCM，
    /// 不改变声音，也不使用与音乐无关的合成动画。
    private func installAVPlayerSpectrumTap(
        on item: AVPlayerItem,
        expectedItemID: ObjectIdentifier
    ) {
        guard spectrumAnalysisEnabled else { return }
        spectrumSetupTask?.cancel()
        spectrumSetupTask = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                guard !Task.isCancelled,
                      let self,
                      self.spectrumAnalysisEnabled,
                      self.activeItemID == expectedItemID,
                      let track = tracks.first,
                      let tap = TVAudioProcessingTapFactory.make(pipeline: self.spectrumPipeline) else {
                    return
                }

                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                item.audioMix = mix
                self.processingTap = tap
                self.startSpectrumPolling()
            } catch {
                // 部分直播流没有可枚举的 AVAssetTrack；这时保持零频谱，绝不伪造数据。
                plog("TVAudioEngine: spectrum track unavailable — \(error.localizedDescription)")
            }
        }
    }

    private func installSFBSpectrumTap() {
        guard spectrumAnalysisEnabled else { return }
        sfb.modifyProcessingGraph { [weak self] engine in
            self?.installMixerSpectrumTap(on: engine.mainMixerNode)
        }
    }

    private func installMixerSpectrumTap(on mixer: AVAudioMixerNode) {
        guard spectrumAnalysisEnabled else { return }
        if tappedMixer === mixer {
            startSpectrumPolling()
            return
        }
        if let tappedMixer { tappedMixer.removeTap(onBus: 0) }
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            return
        }
        TVMixerSpectrumTap.install(
            on: mixer,
            bufferSize: AVAudioFrameCount(spectrumPipeline.capacity),
            format: format,
            pipeline: spectrumPipeline
        )
        tappedMixer = mixer
        startSpectrumPolling()
    }

    private func startSpectrumPolling() {
        guard spectrumAnalysisEnabled, isPlaying, spectrumTask == nil else { return }
        let pipeline = spectrumPipeline
        spectrumTask = Task.detached(priority: .userInitiated) { [weak self, pipeline] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { break }
                guard let next = pipeline.analyzeIfReady(
                    bandCount: TVSpectrumConfiguration.bandCount
                ) else { continue }
                await MainActor.run { [weak self] in
                    guard let self, self.spectrumAnalysisEnabled, self.isPlaying else { return }
                    self.spectrumLevels = next
                }
            }
        }
    }

    private func suspendSpectrumPolling() {
        spectrumTask?.cancel()
        spectrumTask = nil
        resetSpectrumLevels()
    }

    private func clearSpectrumSource() {
        spectrumSetupTask?.cancel()
        spectrumSetupTask = nil
        spectrumTask?.cancel()
        spectrumTask = nil
        if let tappedMixer {
            tappedMixer.removeTap(onBus: 0)
        }
        tappedMixer = nil
        player.currentItem?.audioMix = nil
        processingTap = nil
        spectrumPipeline.reset()
        resetSpectrumLevels()
    }

    private func resetSpectrumLevels() {
        guard spectrumLevels.contains(where: { $0 != 0 }) else { return }
        spectrumLevels = Array(repeating: 0, count: TVSpectrumConfiguration.bandCount)
    }

    // MARK: SFB(非原生格式)引擎切换 / 状态镜像

    /// 切回 AVPlayer 路径前,确保 SFB 引擎停掉、轮询取消。
    private func resetSFBIfNeeded() {
        clearSpectrumSource()
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
        if spectrumAnalysisEnabled {
            installMixerSpectrumTap(on: livePCMEngine.mainMixerNode)
        }
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
        let hasCurrentItem = isLiveStream ? liveRequest != nil : hasPreparedAudio
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: hasCurrentItem,
            isPlaying: isPlaying,
            isLoading: status == .loading,
            preferredPlaybackRate: 1
        )
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: npTitle,
            MPMediaItemPropertyArtist: npArtist,
            MPMediaItemPropertyAlbumTitle: npAlbum,
            MPNowPlayingInfoPropertyPlaybackRate: projection.playbackRate,
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
        commands.playCommand.isEnabled = projection.playCommandEnabled
        commands.pauseCommand.isEnabled = projection.pauseCommandEnabled
        commands.togglePlayPauseCommand.isEnabled = hasCurrentItem && (status != .loading || isLiveStream)
        commands.changePlaybackPositionCommand.isEnabled = !isLiveStream
        commands.skipForwardCommand.isEnabled = !isLiveStream
        commands.skipBackwardCommand.isEnabled = !isLiveStream
        commands.previousTrackCommand.isEnabled = remotePreviousTrackCommandEnabled
        commands.nextTrackCommand.isEnabled = remoteNextTrackCommandEnabled
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.removeTarget(nil)
        c.changePlaybackPositionCommand.removeTarget(nil)
        c.skipForwardCommand.removeTarget(nil)
        c.skipBackwardCommand.removeTarget(nil)
        c.previousTrackCommand.removeTarget(nil)
        c.nextTrackCommand.removeTarget(nil)
        c.playCommand.isEnabled = false
        c.pauseCommand.isEnabled = false
        c.togglePlayPauseCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
        c.nextTrackCommand.isEnabled = false
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.handleRemotePlaybackInput(.systemPlay)
            }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.handleRemotePlaybackInput(.systemPause)
            }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.handleRemotePlaybackInput(.systemToggle)
            }
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
        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self,
                  self.remotePreviousTrackCommandEnabled,
                  let onRemotePreviousTrack = self.onRemotePreviousTrack else {
                return .noSuchContent
            }
            Task { @MainActor in onRemotePreviousTrack() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self,
                  self.remoteNextTrackCommandEnabled,
                  let onRemoteNextTrack = self.onRemoteNextTrack else {
                return .noSuchContent
            }
            Task { @MainActor in onRemoteNextTrack() }
            return .success
        }
    }

    private func handleRemotePlaybackInput(_ input: TVPlaybackInput) {
        switch TVPlaybackCommandRoutingPolicy.action(for: input) {
        case .resume:
            if let onRemotePlay { onRemotePlay() } else { play() }
        case .pause:
            if let onRemotePause { onRemotePause() } else { pause() }
        case .toggle:
            if let onRemoteTogglePlayPause {
                onRemoteTogglePlayPause()
            } else {
                togglePlayPause()
            }
        case .none:
            break
        }
    }

    private func disableRemoteTransportCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = false
        commands.pauseCommand.isEnabled = false
        commands.togglePlayPauseCommand.isEnabled = false
        commands.changePlaybackPositionCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        commands.nextTrackCommand.isEnabled = false
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

/// 音频实时线程只把第一个声道复制进固定缓冲；FFT 始终在后台轮询任务执行。
private final class TVRealtimeSpectrumPipeline: @unchecked Sendable {
    let capacity: Int

    private var samples: [Float]
    private var analysisSamples: [Float]
    private var hasFreshSamples = false
    private var sampleLock = os_unfair_lock_s()
    private var analysisLock = os_unfair_lock_s()
    private var formatLock = os_unfair_lock_s()
    private var acceptsFloat32 = false
    private var sampleStride = 1
    private let analyzer: TVSpectrumFFTAnalyzer

    init(capacity: Int) {
        self.capacity = capacity
        self.samples = Array(repeating: 0, count: capacity)
        self.analysisSamples = Array(repeating: 0, count: capacity)
        self.analyzer = TVSpectrumFFTAnalyzer(
            log2n: Int(log2(Double(capacity))),
            bandCount: TVSpectrumConfiguration.bandCount
        )
    }

    func configure(format: AudioStreamBasicDescription) {
        os_unfair_lock_lock(&formatLock)
        acceptsFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
        sampleStride = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            ? 1
            : max(Int(format.mChannelsPerFrame), 1)
        os_unfair_lock_unlock(&formatLock)
    }

    func fill(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData else { return }
        fill(pointer: channel[0], frameCount: Int(buffer.frameLength), stride: 1)
    }

    func fill(from buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        os_unfair_lock_lock(&formatLock)
        let supported = acceptsFloat32
        let stride = sampleStride
        os_unfair_lock_unlock(&formatLock)
        guard supported, frameCount > 0 else { return }

        let list = UnsafeMutableAudioBufferListPointer(buffers)
        guard let first = list.first, let data = first.mData else { return }
        let availableFrames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(stride, 1)
        let frames = min(frameCount, availableFrames)
        guard frames > 0 else { return }
        fill(
            pointer: data.assumingMemoryBound(to: Float.self),
            frameCount: frames,
            stride: stride
        )
    }

    private func fill(pointer: UnsafePointer<Float>, frameCount: Int, stride: Int) {
        let frames = min(frameCount, capacity)
        guard frames > 0, os_unfair_lock_trylock(&sampleLock) else { return }
        samples.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            if stride == 1 {
                memcpy(base, pointer, frames * MemoryLayout<Float>.size)
            } else {
                for index in 0..<frames {
                    base[index] = pointer[index * stride]
                }
            }
            if frames < capacity {
                memset(
                    base.advanced(by: frames),
                    0,
                    (capacity - frames) * MemoryLayout<Float>.size
                )
            }
        }
        hasFreshSamples = true
        os_unfair_lock_unlock(&sampleLock)
    }

    func analyzeIfReady(bandCount: Int) -> [Float]? {
        os_unfair_lock_lock(&analysisLock)
        defer { os_unfair_lock_unlock(&analysisLock) }
        os_unfair_lock_lock(&sampleLock)
        guard hasFreshSamples else {
            os_unfair_lock_unlock(&sampleLock)
            return nil
        }
        hasFreshSamples = false
        swap(&samples, &analysisSamples)
        os_unfair_lock_unlock(&sampleLock)
        return analyzer.bandLevels(samples: analysisSamples, bandCount: bandCount)
    }

    func reset() {
        os_unfair_lock_lock(&sampleLock)
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            memset(base, 0, buffer.count * MemoryLayout<Float>.size)
        }
        hasFreshSamples = false
        os_unfair_lock_unlock(&sampleLock)
        os_unfair_lock_lock(&formatLock)
        acceptsFloat32 = false
        sampleStride = 1
        os_unfair_lock_unlock(&formatLock)
    }
}

private enum TVMixerSpectrumTap {
    static func install(
        on node: AVAudioMixerNode,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        pipeline: TVRealtimeSpectrumPipeline
    ) {
        node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            pipeline.fill(from: buffer)
        }
    }
}

private enum TVAudioProcessingTapFactory {
    static func make(pipeline: TVRealtimeSpectrumPipeline) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(pipeline).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: nil,
            prepare: { tap, _, processingFormat in
                let pipeline = Unmanaged<TVRealtimeSpectrumPipeline>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                pipeline.configure(format: processingFormat.pointee)
            },
            unprepare: nil,
            process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    frameCount,
                    bufferList,
                    flagsOut,
                    nil,
                    frameCountOut
                )
                guard status == noErr, frameCountOut.pointee > 0 else { return }
                let pipeline = Unmanaged<TVRealtimeSpectrumPipeline>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                pipeline.fill(from: bufferList, frameCount: frameCountOut.pointee)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        return status == noErr ? tap : nil
    }
}

private final class TVSpectrumFFTAnalyzer: @unchecked Sendable {
    private let n: Int
    private var window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var roots: [Float]
    private var bands: [Float]
    private var spectrallySmoothed: [Float]
    private var temporallySmoothed: [Float]

    init(log2n: Int, bandCount: Int) {
        n = 1 << log2n
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        self.window = window
        fft = vDSP.FFT(
            log2n: vDSP_Length(log2n),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        )
        windowed = Array(repeating: 0, count: n)
        real = Array(repeating: 0, count: n / 2)
        imaginary = Array(repeating: 0, count: n / 2)
        magnitudes = Array(repeating: 0, count: n / 2)
        roots = Array(repeating: 0, count: n / 2)
        bands = Array(repeating: 0, count: bandCount)
        spectrallySmoothed = Array(repeating: 0, count: bandCount)
        temporallySmoothed = Array(repeating: 0, count: bandCount)
    }

    func bandLevels(samples: [Float], bandCount: Int) -> [Float] {
        guard samples.count >= n, let fft, bandCount > 0 else {
            return Array(repeating: 0, count: max(bandCount, 0))
        }
        if bands.count != bandCount {
            bands = Array(repeating: 0, count: bandCount)
            spectrallySmoothed = Array(repeating: 0, count: bandCount)
            temporallySmoothed = Array(repeating: 0, count: bandCount)
        }

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        windowed.withUnsafeBytes { bytes in
            guard let source = bytes.bindMemory(to: DSPComplex.self).baseAddress else { return }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imaginaryBuffer.baseAddress!
                    )
                    vDSP_ctoz(source, 2, &split, 1, vDSP_Length(n / 2))
                }
            }
        }

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                fft.forward(input: split, output: &split)
            }
        }

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        var rootCount = Int32(n / 2)
        vvsqrtf(&roots, magnitudes, &rootCount)
        var fftScale = Float(2) / Float(n)
        roots.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            vDSP_vsmul(
                baseAddress,
                1,
                &fftScale,
                baseAddress,
                1,
                vDSP_Length(n / 2)
            )
        }

        let binCount = n / 2
        let minimumBin = 2
        let logarithmicMinimum = log(Float(minimumBin))
        let logarithmicMaximum = log(Float(binCount - 1))
        let step = (logarithmicMaximum - logarithmicMinimum) / Float(bandCount)

        for band in 0..<bandCount {
            let lower = Int(exp(logarithmicMinimum + Float(band) * step))
            let upper = min(
                max(lower + 1, Int(exp(logarithmicMinimum + Float(band + 1) * step))),
                binCount
            )
            var sum: Float = 0
            for index in lower..<upper { sum += roots[index] }
            let average = sum / Float(max(1, upper - lower))
            let decibels = 20 * log10f(max(1e-7, average))
            let normalized = min(max((decibels + 72) / 64, 0), 1)
            bands[band] = normalized < 0.035 ? 0 : powf(normalized, 0.72)
        }

        if bandCount > 2 {
            spectrallySmoothed[0] = bands[0]
            spectrallySmoothed[bandCount - 1] = bands[bandCount - 1]
            for index in 1..<(bandCount - 1) {
                spectrallySmoothed[index] = bands[index - 1] * 0.18
                    + bands[index] * 0.64
                    + bands[index + 1] * 0.18
            }
        } else {
            for index in 0..<bandCount { spectrallySmoothed[index] = bands[index] }
        }

        for index in 0..<bandCount {
            let old = temporallySmoothed[index]
            let target = spectrallySmoothed[index]
            let blend: Float = target >= old ? 0.72 : 0.18
            temporallySmoothed[index] = old + (target - old) * blend
        }

        // Force one tiny 32-float output copy. Every FFT work buffer above is
        // retained and reused; the audio callback never participates in COW.
        return temporallySmoothed.withUnsafeBufferPointer { Array($0) }
    }
}
#endif
