#if os(tvOS)
import AVFoundation
import Foundation
import SFBAudioEngine

/// tvOS 上用 SFBAudioEngine 解码 + 播放【AVPlayer 解不了的格式】(APE/WavPack/DSD/OGG Vorbis/
/// WMA 等)。SFBAudioEngine 的 `AudioPlayer` 自带这些解码器,经 AVAudioEngine 输出。
/// 由 `TVAudioEngine` 在遇到非原生格式时下载到本地文件后交给本引擎(与 AVPlayer 路径并列)。
final class TVSFBEngine: NSObject, @unchecked Sendable {
    typealias Generation = UInt64

    private var player = AudioPlayer()
    private var delegateProxy: DelegateProxy?
    private var nextGeneration: Generation = 0

    var onEnded: (@MainActor (Generation) -> Void)?
    var onStateChange: (@MainActor (Generation) -> Void)?
    var onFailure: (@MainActor (Generation, String) -> Void)?

    override init() {
        super.init()
    }

    @discardableResult
    func play(url: URL) throws -> Generation {
        invalidateCurrentPlayer()
        nextGeneration &+= 1
        let generation = nextGeneration
        let player = AudioPlayer()
        let proxy = DelegateProxy(owner: self, generation: generation)
        player.delegate = proxy
        self.player = player
        delegateProxy = proxy
        do {
            try player.play(url)
            return generation
        } catch {
            player.delegate = nil
            delegateProxy = nil
            throw error
        }
    }
    @discardableResult
    func resume() -> Bool { player.resume() }
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

        init(owner: TVSFBEngine, generation: Generation) {
            self.owner = owner
            self.generation = generation
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
