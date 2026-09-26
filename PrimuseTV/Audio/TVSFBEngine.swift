#if os(tvOS)
import AVFoundation
import Foundation
import PrimuseKit
import SFBAudioEngine

/// tvOS 上播放【AVPlayer 解不了的格式】,统一经 SFBAudioEngine 的 `AudioPlayer`(AVAudioEngine)输出。
/// APE/WavPack/DSD/OGG 等用 SFBAudioEngine 自带的解码器;它没有解码器的 WMA/DTS/TrueHD/ATRAC/TAK 等
/// 由 `TVFFmpegPCMDecoder` 把 FFmpeg 解出的 PCM 交给同一个播放器,暂停、跳转、进度、频谱都走同一条路。
/// 由 `TVAudioEngine` 在遇到非原生格式时下载到本地文件后交给本引擎(与 AVPlayer 路径并列)。
final class TVSFBEngine: NSObject, @unchecked Sendable {
    typealias Generation = UInt64

    private var player = AudioPlayer()
    private var delegateProxy: DelegateProxy?
    private var nextGeneration: Generation = 0
    private var mixVolume: Float = 1
    /// 听书语速。每个 `AudioPlayer` 在源节点与主混音之间挂一个变速单元;1× 时旁路,
    /// 音乐(APE、DSD 等也走这条路)不经过任何处理。
    private var playbackRate: Float = 1
    private var timePitch: AVAudioUnitTimePitch?

    func setPlaybackRate(_ rate: Float) {
        let clamped = rate.isFinite ? min(2, max(0.5, rate)) : 1
        playbackRate = clamped
        guard let timePitch else { return }
        player.modifyProcessingGraph { _ in
            timePitch.rate = clamped
            timePitch.bypass = abs(clamped - 1) < 0.001
        }
    }

    /// 把变速单元插进 `sourceNode → mainMixerNode` 这一段(SFBAudioEngine 允许改动的唯一一段)。
    /// 之后源格式变化时,SFBAudioEngine 会经代理的 `reconfigureProcessingGraph` 回来问该接到哪个节点。
    private func insertTimePitch(into player: AudioPlayer) -> AVAudioUnitTimePitch {
        let unit = AVAudioUnitTimePitch()
        unit.rate = playbackRate
        unit.bypass = abs(playbackRate - 1) < 0.001
        let source = player.sourceNode
        player.modifyProcessingGraph { engine in
            let format = source.outputFormat(forBus: 0)
            engine.attach(unit)
            engine.disconnectNodeOutput(source)
            engine.connect(source, to: unit, format: format)
            engine.connect(unit, to: engine.mainMixerNode, format: format)
        }
        return unit
    }

    func setMixVolume(_ volume: Float) {
        mixVolume = min(1, max(0, volume))
        let gain = mixVolume
        player.modifyProcessingGraph { $0.mainMixerNode.outputVolume = gain }
    }

    var onEnded: (@MainActor (Generation) -> Void)?
    var onStateChange: (@MainActor (Generation) -> Void)?
    var onFailure: (@MainActor (Generation, String) -> Void)?

    override init() {
        super.init()
    }

    @discardableResult
    func play(url: URL, decoder: TVLocalDecoder) throws -> Generation {
        invalidateCurrentPlayer()
        nextGeneration &+= 1
        let generation = nextGeneration
        let player = AudioPlayer()
        let unit = insertTimePitch(into: player)
        let proxy = DelegateProxy(owner: self, generation: generation, timePitch: unit)
        player.delegate = proxy
        self.player = player
        timePitch = unit
        delegateProxy = proxy
        let gain = mixVolume
        player.modifyProcessingGraph { $0.mainMixerNode.outputVolume = gain }
        do {
            switch decoder {
            case .ffmpeg:
                try player.play(TVFFmpegPCMDecoder(url: url))
            case .sfbAudioEngine:
                do {
                    if AudioFormat.from(fileExtension: url.pathExtension)?.isTrackerModule == true {
                        // SFB's content sniffing hands `.s3m`/`.it` to the
                        // wrong decoder; DUMB has to be named.
                        try player.play(AudioDecoder(url: url, decoderName: .module))
                    } else {
                        try player.play(url)
                    }
                } catch {
                    // 与 iOS 一致:FFmpeg 兜底扩展名标错、SFBAudioEngine 认不出的文件。
                    guard let fallback = try? TVFFmpegPCMDecoder(url: url) else { throw error }
                    try player.play(fallback)
                }
            }
            return generation
        } catch {
            player.delegate = nil
            delegateProxy = nil
            throw error
        }
    }
    @discardableResult
    func resume() -> Bool {
        // Deactivating AVAudioSession can stop the graph while preserving its
        // decoder. resume() requires a running graph; play() also restarts it.
        do {
            try player.play()
            return true
        } catch {
            plog("TV decoded playback resume failed: \(error.localizedDescription)")
            return false
        }
    }
    func pause() { _ = player.pause() }
    func stop() { invalidateCurrentPlayer() }
    func seek(_ time: Double) { _ = player.seek(time: time) }

    /// 在 SFBAudioEngine 自己的 AVAudioEngine 图上安全挂接/移除只读频谱 tap。
    func modifyProcessingGraph(_ block: @escaping (AVAudioEngine) -> Void) {
        player.modifyProcessingGraph(block)
    }

    var isPlaying: Bool { player.isPlaying }
    var currentTime: Double { player.currentTime ?? 0 }
    var duration: Double { player.totalTime ?? 0 }

    private func invalidateCurrentPlayer() {
        // Detach the weak delegate before stopping. SFBAudioEngine can enqueue a
        // final state/end callback during teardown; that callback must never be
        // attributed to the next file loaded into this wrapper.
        player.delegate = nil
        delegateProxy = nil
        player.stop()
    }

    private final class DelegateProxy: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
        weak var owner: TVSFBEngine?
        let generation: Generation
        let timePitch: AVAudioUnitTimePitch

        init(owner: TVSFBEngine, generation: Generation, timePitch: AVAudioUnitTimePitch) {
            self.owner = owner
            self.generation = generation
            self.timePitch = timePitch
        }

        /// 源格式变了(换了解码器、采样率或声道数):变速单元照旧接在源节点后面,
        /// 按新格式重接到主混音。
        func audioPlayer(
            _ audioPlayer: AudioPlayer,
            reconfigureProcessingGraph engine: AVAudioEngine,
            with format: AVAudioFormat
        ) -> AVAudioNode {
            engine.disconnectNodeOutput(timePitch)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            return timePitch
        }

        func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
            guard let callback = owner?.onEnded else { return }
            let callbackGeneration = generation
            Task { @MainActor in callback(callbackGeneration) }
        }

        func audioPlayer(
            _ audioPlayer: AudioPlayer,
            playbackStateChanged playbackState: AudioPlayer.PlaybackState
        ) {
            guard let callback = owner?.onStateChange else { return }
            let callbackGeneration = generation
            Task { @MainActor in callback(callbackGeneration) }
        }

        func audioPlayer(
            _ audioPlayer: AudioPlayer,
            decodingAborted decoder: any PCMDecoding,
            error: any Error,
            framesRendered: AVAudioFramePosition
        ) {
            guard let callback = owner?.onFailure else { return }
            let callbackGeneration = generation
            let message = error.localizedDescription
            Task { @MainActor in callback(callbackGeneration, message) }
        }

        func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: any Error) {
            guard let callback = owner?.onFailure else { return }
            let callbackGeneration = generation
            let message = error.localizedDescription
            Task { @MainActor in callback(callbackGeneration, message) }
        }
    }
}
#endif
