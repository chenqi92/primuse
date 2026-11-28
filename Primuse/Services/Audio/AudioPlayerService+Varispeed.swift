import AVFoundation
import Foundation
import Observation
import PrimuseKit

extension AudioPlayerService {
    /// Whether Varispeed is currently active for the playing item.
    var isVarispeedEffective: Bool {
        VarispeedPolicy.isEffective(
            mode: playbackSettings.speedPitchMode,
            isSpokenWord: currentItemIsSpokenWord,
            isLiveRadio: isLiveRadio,
            outputAllowsEffects: playbackSettings.outputMode == .effects,
            isKaraokePracticeActive: karaokePracticeRate != nil
        )
    }

    func isVarispeedEffective(for song: Song?) -> Bool {
        let isSpokenWord = song.map { SpokenWordStore.shared.isSpokenWord($0) } ?? false
        return VarispeedPolicy.isEffective(
            mode: playbackSettings.speedPitchMode,
            isSpokenWord: isSpokenWord,
            isLiveRadio: isLiveRadio,
            outputAllowsEffects: outputMode(for: song) == .effects,
            isKaraokePracticeActive: karaokePracticeRate != nil
        )
    }

    var varispeedAvailability: PlaybackPitchPolicy.Availability {
        VarispeedPolicy.availability(
            isSpokenWord: currentItemIsSpokenWord,
            isLiveRadio: isLiveRadio,
            isAppleMusic: isAppleMusicMode,
            isCasting: castingRenderer != nil,
            isHighFidelityOutput: outputMode(for: currentSong) == .highFidelity
        )
    }

    /// 同步当前 playbackRate、Varispeed 模式与升降调到 engine. 设置变化或新歌开播都会调它。
    /// 音频图按内容、Varispeed 与升降调选择算法; 视频播客的纯音频流由 AVPlayer 自己变速。
    func applyPlaybackRate() {
        let varispeedActive = isVarispeedEffective
        let requestedRate = requestedPlaybackRate
        let requestedPitch = varispeedActive ? 0 : requestedPitchSemitones
        if isSystemAudioPlaybackActive,
           (!systemAudioUsesNativePodcastStream && abs(requestedRate - 1) >= 0.001)
               || requestedPitch != 0
               || (varispeedActive && VarispeedPolicy.isActiveRate(requestedRate)),
           let id = playID {
            Task { @MainActor [weak self] in
                await self?.fallbackSystemAudioToPCM(playID: id, error: nil)
            }
            return
        }
        audioEngine.applyPlaybackRate(
            requestedRate,
            userPitchCents: PlaybackPitchPolicy.cents(forSemitones: requestedPitch),
            isSpokenWord: currentItemIsSpokenWord,
            varispeedEnabled: varispeedActive
        )
        // 视频管线自己变速(升降调/Varispeed 走 PCM 引擎,和以前一样不管)。
        if isMusicVideoPlaybackActive || systemAudioUsesNativePodcastStream,
           let player = activeSystemMediaPlayer {
            player.defaultRate = requestedRate
            if player.rate != 0 { player.rate = requestedRate }
        }
    }

    /// 变速变调单元和音乐触感的取样混音器只在打开时串进效果图。开关一变就按当前位置重建一次图
    /// (和换输出模式同一条路),没在放、没法当场重建时等下次建图生效。
    func syncEffectsGraphExtras() {
        audioEngine.graphIncludesVarispeedUnit = playbackSettings.speedPitchMode == .varispeed
        #if os(iOS)
        audioEngine.graphIncludesHapticsTap = playbackSettings.musicHapticsEnabled && MusicHapticsEngine.isHardwareSupported
        #endif
        guard audioEngine.effectsGraphExtrasNeedRebuild, !isAppleMusicMode, !isCastingMode,
              canRebuildOutputPipelineForSettingsChange else { return }
        seek(to: currentTime, startPlaying: isPlaying)
    }

    /// 单独跟踪 playbackRate(连同升降调与 Varispeed), 别和 spatial observer 合并 — 不然改速度时会
    /// 顺带触发 spatial node 的 sourceMode / renderingAlgorithm 重设, 在
    /// engine 运行中可能导致音频 glitch / player 卡顿。
    func observePlaybackRate() {
        withObservationTracking {
            _ = playbackSettings.playbackRate
            _ = playbackSettings.spokenWordPlaybackRate
            _ = playbackSettings.pitchSemitones
            _ = playbackSettings.speedPitchMode
            _ = playbackSettings.varispeedRate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncEffectsGraphExtras()
                self.applyPlaybackRate()
                // 系统侧的进度按发布的速度往前推,换了速度要立刻重发,锁屏和车机的进度条才不会
                // 越走越偏(按书记的速度在 `setSpokenWordRate` 里已经重发)。没在放就不碰,
                // 免得把空快照当成「清掉正在播放」。
                if self.currentSong != nil {
                    self.updateNowPlayingInfo()
                    #if os(iOS)
                    self.publishWidgetLyricsIfNeeded()
                    #endif
                }
                self.observePlaybackRate()
            }
        }
    }
}
