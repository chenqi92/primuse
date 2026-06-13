#if os(tvOS)
import AVFoundation
import Foundation
import SFBAudioEngine

/// tvOS 上用 SFBAudioEngine 解码 + 播放【AVPlayer 解不了的格式】(APE/WavPack/DSD/OGG Vorbis/
/// WMA 等)。SFBAudioEngine 的 `AudioPlayer` 自带这些解码器,经 AVAudioEngine 输出。
/// 由 `TVAudioEngine` 在遇到非原生格式时下载到本地文件后交给本引擎(与 AVPlayer 路径并列)。
final class TVSFBEngine: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    private let player = AudioPlayer()

    var onEnded: (@MainActor () -> Void)?
    var onStateChange: (@MainActor () -> Void)?

    override init() {
        super.init()
        player.delegate = self
    }

    func play(url: URL) throws { try player.play(url) }
    func resume() { _ = player.resume() }
    func pause() { _ = player.pause() }
    func stop() { player.stop() }
    func seek(_ time: Double) { _ = player.seek(time: time) }

    var isPlaying: Bool { player.isPlaying }
    var currentTime: Double { player.currentTime ?? 0 }
    var duration: Double { player.totalTime ?? 0 }

    // MARK: AudioPlayer.Delegate(回调在 SFB 内部线程,跳主线程)

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        if let cb = onEnded { Task { @MainActor in cb() } }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        if let cb = onStateChange { Task { @MainActor in cb() } }
    }
}
#endif
