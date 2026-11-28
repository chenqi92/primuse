import AVFoundation
import Foundation
import PrimuseKit

extension AudioEngine {
    // MARK: - Playback Rate & Varispeed

    /// True when the local effects graph is currently stretching time and pitch together via `AVAudioUnitVarispeed`.
    var isVarispeedActive: Bool {
        outputMode == .effects && varispeedEnabled && varispeedNode != nil && VarispeedPolicy.isActiveRate(playbackRate)
    }

    /// The built effects graph does not carry the optional nodes the settings now ask for
    /// (`graphIncludesVarispeedUnit` / `graphIncludesHapticsTap`); `configure` rebuilds it.
    var effectsGraphExtrasNeedRebuild: Bool {
        guard isSetUp, outputMode == .effects else { return false }
        #if os(iOS)
        if (hapticsTapMixer != nil) != graphIncludesHapticsTap { return true }
        #endif
        return (varispeedNode != nil) != graphIncludesVarispeedUnit
    }

    /// Simultaneously updates playback rate, content type, user key shift, and Varispeed mode
    /// so `PlaybackTimePitchProcessor` and `AVAudioUnitVarispeed` never multiply rates.
    func applyPlaybackRate(
        _ rate: Float,
        userPitchCents: Float = 0,
        isSpokenWord: Bool = false,
        varispeedEnabled: Bool = false
    ) {
        let previousRate = playbackRate
        let previousVarispeed = self.varispeedEnabled
        playbackRate = VarispeedPolicy.clampedRate(rate)
        self.userPitchCents = userPitchCents
        playbackIsSpokenWord = isSpokenWord
        self.varispeedEnabled = varispeedEnabled && !isSpokenWord
        applyPitchToGraph()
        if abs(previousRate - playbackRate) >= VarispeedPolicy.unityTolerance || previousVarispeed != self.varispeedEnabled {
            notifyMusicHapticsLifecycle(.rateChanged)
        }
    }

    // MARK: - Karaoke

    /// 效果图里有没有挂上人声消除单元(高保真直通图没有)。
    var supportsKaraokeVocalReduction: Bool {
        outputMode == .effects && karaokeVocalNode != nil
    }

    /// 升降调只作用在播放图上; 麦克风走自己的引擎, 不会被一起变调。
    func applyKaraokePitch(cents: Float) {
        karaokePitchCents = cents
        applyPitchToGraph()
    }

    /// 播放速度旁的整体升降调。有声内容、电台由调用方传 0。
    func applyUserPitch(cents: Float) {
        userPitchCents = cents
        applyPitchToGraph()
    }

    var combinedPitchCents: Float {
        PlaybackPitchPolicy.combinedCents(userCents: userPitchCents, karaokeCents: karaokePitchCents)
    }

    /// Enforces mutual exclusion between pitch-preserving time stretching (`PlaybackTimePitchProcessor`)
    /// and linked speed/pitch stretching (`AVAudioUnitVarispeed`) so rates never multiply.
    func applyPitchToGraph() {
        guard outputMode == .effects else { return }
        let safeRate = VarispeedPolicy.clampedRate(playbackRate)

        // Until the graph is rebuilt with the varispeed unit, keep the requested speed through
        // time stretching so the clock rate published for progress and lyrics stays true.
        if varispeedEnabled && !playbackIsSpokenWord, let varispeed = varispeedNode {
            // Keep timePitchProcessor at 1.0x rate (only applying karaoke stage key shift if active).
            timePitchProcessor?.apply(
                rate: 1.0,
                pitchCents: karaokePitchCents,
                isSpokenWord: false
            )
            if VarispeedPolicy.isActiveRate(safeRate) {
                if varispeed.bypass {
                    varispeed.reset()
                }
                varispeed.rate = safeRate
                varispeed.bypass = false
            } else {
                varispeed.rate = 1.0
                varispeed.bypass = true
            }
        } else {
            // Disable varispeed first so rates can never multiply across the handoff.
            if let varispeed = varispeedNode {
                varispeed.rate = 1.0
                varispeed.bypass = true
            }
            timePitchProcessor?.apply(
                rate: safeRate,
                pitchCents: combinedPitchCents,
                isSpokenWord: playbackIsSpokenWord
            )
        }
    }

    /// 渲染 → 扬声器的延迟, 录音对齐人声时要补上。
    var outputPresentationLatency: TimeInterval {
        engine?.outputNode.presentationLatency ?? 0
    }

    /// 录音时抓伴奏: 变调之后、主音量之前, 所以录下来的电平不跟音量滑块走。
    /// 可视化已经占了 mainMixer 的 tap, 同一个总线只能挂一个。
    var karaokeRecordingTapNode: AVAudioNode? {
        outputMode == .effects ? timePitchProcessor?.spectralNode : nil
    }
}
