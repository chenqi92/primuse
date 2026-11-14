import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke sing-along (#377)")
struct KaraokeSingAlongPolicyTests {
    private typealias Policy = KaraokeSingAlongPolicy

    // MARK: 原唱音量

    @Test("Levels map to decibels, not linear steps, and keep their stored names")
    func levelMapping() {
        #expect(KaraokeSingAlongLevel.instrumental.vocalGain == 0)
        #expect(KaraokeSingAlongLevel.instrumental.reduction == 1)
        #expect(abs(KaraokeSingAlongLevel.faint.vocalGain - 0.1) < 1e-9)
        #expect(abs(KaraokeSingAlongLevel.soft.vocalGain - pow(10, -0.5)) < 1e-9)
        #expect(abs(KaraokeSingAlongLevel.faint.reduction - 0.9) < 1e-9)
        // 一档比一档留得多。
        let gains = KaraokeSingAlongLevel.allCases.map(\.vocalGain)
        #expect(gains == gains.sorted())
        // 写进偏好的名字发布后不能改。
        #expect(KaraokeSingAlongLevel.allCases.map(\.rawValue) == ["instrumental", "faint", "soft"])
        #expect(KaraokeSingAlongLevel(stored: "soft") == .soft)
        #expect(KaraokeSingAlongLevel(stored: "louder") == .defaultValue)
        #expect(KaraokeSingAlongLevel(stored: nil) == .defaultValue)
    }

    // MARK: 能不能用

    @Test("Availability names the first reason that keeps the original playing")
    func availability() {
        func resolve(
            hasSong: Bool = true,
            spoken: Bool = false,
            appleMusic: Bool = false,
            casting: Bool = false,
            highFidelity: Bool = false,
            spatial: Bool = false,
            system: Bool = false,
            medley: Bool = false
        ) -> KaraokeSingAlongAvailability {
            KaraokeSingAlongAvailability.resolve(
                hasSong: hasSong,
                isSpokenWordOrRadio: spoken,
                isAppleMusic: appleMusic,
                isCasting: casting,
                isHighFidelityOutput: highFidelity,
                isSpatialAudio: spatial,
                isSystemPlayback: system,
                isMedley: medley
            )
        }
        #expect(resolve() == .available)
        #expect(resolve(hasSong: false) == .notApplicable)
        // 有声书、电台不提示,哪怕同时在投放。
        #expect(resolve(spoken: true, casting: true) == .notApplicable)
        #expect(resolve(appleMusic: true, highFidelity: true) == .appleMusic)
        #expect(resolve(casting: true, highFidelity: true) == .casting)
        #expect(resolve(highFidelity: true, medley: true) == .highFidelityOutput)
        #expect(resolve(system: true) == .unsupportedPlayback)
        #expect(resolve(medley: true) == .unsupportedPlayback)
        #expect(resolve(spatial: true) == .spatialAudio)
        // 高保真直通里没有空间音频,先说高保真(能一键切走)。
        #expect(resolve(highFidelity: true, spatial: true) == .highFidelityOutput)
    }

    // MARK: 开关与模型

    @Test("Turning on fetches the model; a deleted model turns it off; launch needs the model on device")
    func enablingAndModel() {
        #expect(!Policy.canEnable(model: .unsupportedSystem))
        #expect(Policy.canEnable(model: .notDownloaded))
        #expect(Policy.downloadsModelOnEnable(.notDownloaded))
        #expect(Policy.downloadsModelOnEnable(.failed))
        #expect(!Policy.downloadsModelOnEnable(.ready))
        #expect(!Policy.downloadsModelOnEnable(.downloading(0.4)))

        #expect(Policy.staysEnabledAtLaunch(model: .ready))
        #expect(!Policy.staysEnabledAtLaunch(model: .notDownloaded))
        #expect(!Policy.staysEnabledAtLaunch(model: .unsupportedSystem))

        #expect(Policy.turnsOff(model: .notDownloaded))
        #expect(!Policy.turnsOff(model: .downloading(0)))
        #expect(!Policy.turnsOff(model: .failed))
        #expect(!Policy.turnsOff(model: .ready))
    }

    @Test("The stem is wanted only when on, not yielding to karaoke, playable here, with the model ready")
    func wantsStem() {
        #expect(Policy.wantsStem(isEnabled: true, isKaraokeActive: false, availability: .available, model: .ready))
        #expect(!Policy.wantsStem(isEnabled: false, isKaraokeActive: false, availability: .available, model: .ready))
        #expect(!Policy.wantsStem(isEnabled: true, isKaraokeActive: true, availability: .available, model: .ready))
        #expect(!Policy.wantsStem(isEnabled: true, isKaraokeActive: false, availability: .casting, model: .ready))
        #expect(!Policy.wantsStem(isEnabled: true, isKaraokeActive: false, availability: .available, model: .downloading(1)))
    }

    @Test("A failed song is retried once by itself")
    func separationRequests() {
        #expect(Policy.separationRequest(for: .idle, alreadyRetried: false) == .start)
        #expect(Policy.separationRequest(for: .idle, alreadyRetried: true) == .start)
        #expect(Policy.separationRequest(for: .failed, alreadyRetried: false) == .retry)
        #expect(Policy.separationRequest(for: .failed, alreadyRetried: true) == .skip)
        for status: KaraokeSingAlongSongStatus in [.preparing, .separating(0.3), .ready, .unsupported] {
            #expect(Policy.separationRequest(for: status, alreadyRetried: false) == .skip)
        }
    }

    // MARK: 状态

    private func phase(
        enabled: Bool = true,
        karaoke: Bool = false,
        availability: KaraokeSingAlongAvailability = .available,
        model: KaraokeSingAlongModelStatus = .ready,
        song: KaraokeSingAlongSongStatus? = .idle,
        hold: KaraokeSingAlongHold? = nil,
        loaded: Bool = false,
        locked: Bool = false
    ) -> KaraokeSingAlongPhase {
        Policy.phase(
            isEnabled: enabled,
            isKaraokeActive: karaoke,
            availability: availability,
            model: model,
            song: song,
            hold: hold,
            isStemLoaded: loaded,
            isStemLocked: locked
        )
    }

    @Test("Off, karaoke and the model come before the song")
    func phaseOrder() {
        #expect(phase(enabled: false, karaoke: true) == .off)
        #expect(phase(karaoke: true, model: .failed) == .yieldingToKaraoke)
        #expect(phase(availability: .appleMusic, model: .downloading(0.25)) == .downloadingModel(0.25))
        #expect(phase(model: .notDownloaded) == .downloadingModel(0))
        #expect(phase(model: .failed) == .modelFailed)
        #expect(phase(model: .unsupportedSystem) == .unavailable(.unsupportedSystem))
        #expect(phase(availability: .notApplicable) == .idle)
        #expect(phase(availability: .highFidelityOutput, loaded: true, locked: true) == .unavailable(.highFidelityOutput))
    }

    @Test("A song walks from preparing through aligning to active; the original plays until then")
    func songTransitions() {
        let steps: [KaraokeSingAlongPhase] = [
            phase(song: .idle),
            phase(song: .preparing, hold: .background),
            phase(song: .separating(0.4), hold: .cooling),
            phase(song: .ready),
            phase(song: .ready, loaded: true),
            phase(song: .ready, loaded: true, locked: true),
        ]
        #expect(steps == [
            .preparing(progress: nil, hold: nil),
            .preparing(progress: nil, hold: .background),
            .preparing(progress: 0.4, hold: .cooling),
            .preparing(progress: 1, hold: nil),
            .aligning,
            .active,
        ])
        let openingPlaysOriginal = steps.prefix(4).allSatisfy { $0.playsOriginal }
        #expect(openingPlaysOriginal)
        #expect(!KaraokeSingAlongPhase.aligning.playsOriginal)
        #expect(!KaraokeSingAlongPhase.active.playsOriginal)
        #expect(phase(song: .unsupported) == .songUnsupported)
        #expect(phase(song: .failed) == .songFailed)
        #expect(KaraokeSingAlongPhase.songFailed.playsOriginal)
        // 换到一首别的歌:人声轨卸了,又从准备开始。
        #expect(phase(song: nil) == .preparing(progress: nil, hold: nil))
        #expect(!KaraokeSingAlongPhase.off.playsOriginal)
        #expect(!KaraokeSingAlongPhase.yieldingToKaraoke.playsOriginal)
    }

    @Test("Menus see the phase without its progress, so a rising percentage does not rebuild them")
    func coarsePhase() {
        #expect(KaraokeSingAlongPhase.downloadingModel(0.3).withoutProgress == .downloadingModel(0))
        #expect(KaraokeSingAlongPhase.preparing(progress: 0.2, hold: nil).withoutProgress
            == KaraokeSingAlongPhase.preparing(progress: 0.7, hold: nil).withoutProgress)
        #expect(KaraokeSingAlongPhase.preparing(progress: nil, hold: .cooling).withoutProgress
            == .preparing(progress: nil, hold: .cooling))
        #expect(KaraokeSingAlongPhase.preparing(progress: 1, hold: nil).withoutProgress
            == .preparing(progress: 1, hold: nil))
        #expect(KaraokeSingAlongPhase.preparing(progress: 0.5, hold: nil).withoutProgress
            != KaraokeSingAlongPhase.preparing(progress: nil, hold: nil).withoutProgress)
        #expect(KaraokeSingAlongPhase.unavailable(.casting).withoutProgress == .unavailable(.casting))
        #expect(KaraokeSingAlongPhase.active.withoutProgress == .active)
    }

    @Test("Upcoming songs are separated ahead only in the foreground, cool and not in Low Power Mode")
    func prefetch() {
        func prefetches(
            _ current: KaraokeSingAlongPhase,
            foreground: Bool = true,
            lowPower: Bool = false,
            hot: Bool = false
        ) -> Bool {
            Policy.prefetchesUpcoming(current: current, isForeground: foreground, isLowPowerMode: lowPower, isHot: hot)
        }
        #expect(prefetches(.active))
        #expect(prefetches(.aligning))
        #expect(prefetches(.songUnsupported))
        #expect(prefetches(.unavailable(.appleMusic)))
        #expect(!prefetches(.active, foreground: false))
        #expect(!prefetches(.active, lowPower: true))
        #expect(!prefetches(.active, hot: true))
        // 这首还在分离时不和它抢模型。
        #expect(!prefetches(.preparing(progress: 0.5, hold: nil)))
        // 投放、高保真时接下来的歌也用不上。
        #expect(!prefetches(.unavailable(.casting)))
        #expect(!prefetches(.unavailable(.highFidelityOutput)))
        #expect(!prefetches(.unavailable(.spatialAudio)))
        #expect(!prefetches(.off))
        #expect(!prefetches(.yieldingToKaraoke))
    }

    @Test("Alignment is fast until locked and the gain is known, then only rechecked")
    func alignmentCadence() {
        #expect(Policy.alignmentInterval(isLocked: false, needsGainEstimate: false) == .milliseconds(250))
        #expect(Policy.alignmentInterval(isLocked: true, needsGainEstimate: true) == .milliseconds(250))
        #expect(Policy.alignmentInterval(isLocked: true, needsGainEstimate: false) == .seconds(2))
    }

    // MARK: 人声轨的音量比例

    /// 一段「人声」(断续的两个正弦)与一段与它无关的「伴奏」。
    private func signals(count: Int) -> (vocal: [Float], accompaniment: [Float]) {
        var vocal = [Float](repeating: 0, count: count)
        var accompaniment = [Float](repeating: 0, count: count)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        for index in 0..<count {
            let t = Double(index) / 44_100
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 3 * t)
            vocal[index] = Float(0.2 * envelope * (sin(2 * .pi * 220 * t) + 0.5 * sin(2 * .pi * 440 * t)))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int64(bitPattern: seed >> 11) % 1000) / 1000
            accompaniment[index] = Float(0.3 * sin(2 * .pi * 97 * t) + 0.05 * noise)
        }
        return (vocal, accompaniment)
    }

    @Test("The least-squares gain recovers how much the playback was scaled before the remover")
    func gainRecoversPlaybackScale() {
        let window = 8_192
        let lead = 2_000
        let (vocal, accompaniment) = signals(count: window + 2 * lead)
        for scale in [0.5, 1.0, 1.4] {
            // 播放信号 = 缩放后的(人声 + 伴奏),从人声轨第 lead 个样本起。
            let live = (0..<window).map { Float(scale) * (vocal[lead + $0] + accompaniment[lead + $0]) }
            let gain = KaraokeStemAligner.gain(live: live, excerpt: vocal, excerptStart: 0, stemIndex: lead)
            #expect(gain != nil)
            if let gain { #expect(abs(gain - scale) / scale < 0.1) }
        }
    }

    @Test("No gain from a silent stem or a window outside the excerpt")
    func gainRejectsMeaninglessWindows() {
        let silent = [Float](repeating: 0, count: 10_000)
        let live = [Float](repeating: 0.1, count: 4_096)
        #expect(KaraokeStemAligner.gain(live: live, excerpt: silent, excerptStart: 0, stemIndex: 0) == nil)
        let (vocal, _) = signals(count: 5_000)
        #expect(KaraokeStemAligner.gain(live: live, excerpt: vocal, excerptStart: 0, stemIndex: 2_000) == nil)
        #expect(KaraokeStemAligner.gain(live: live, excerpt: vocal, excerptStart: 100, stemIndex: 50) == nil)
        #expect(KaraokeStemAligner.gain(live: [], excerpt: vocal, excerptStart: 0, stemIndex: 0) == nil)
    }

    @Test("The gain estimate settles on the median and ignores outliers")
    func gainEstimator() {
        var estimator = KaraokeStemGainEstimator()
        estimator.record(0.5)
        estimator.record(0.52)
        #expect(!estimator.isSettled)
        #expect(estimator.scale == 1)
        estimator.record(9)   // 超出范围,不算
        estimator.record(0.48)
        #expect(estimator.isSettled)
        #expect(abs(estimator.scale - 0.5) < 1e-9)
        // 一次被带偏的估计挪不动中位数。
        estimator.record(1.6)
        #expect(abs(estimator.scale - 0.51) < 1e-9)
        // 只留最近几次。
        for _ in 0..<KaraokeStemGainEstimator.window { estimator.record(0.7) }
        #expect(abs(estimator.scale - 0.7) < 1e-9)
        estimator.reset()
        #expect(!estimator.isSettled)
        #expect(estimator.scale == 1)
    }
}
