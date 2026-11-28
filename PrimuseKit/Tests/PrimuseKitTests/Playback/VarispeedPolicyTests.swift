import Foundation
import Testing
@testable import PrimuseKit
#if canImport(AVFAudio) && !os(watchOS)
import AVFAudio
#endif

@Suite("Varispeed Policy")
struct VarispeedPolicyTests {
    @Test("Percent change converts symmetrically to playback rate within clamped bounds")
    func percentConversions() {
        #expect(abs(VarispeedPolicy.rate(forPercentChange: 0) - 1.0) < 0.0001)
        #expect(abs(VarispeedPolicy.rate(forPercentChange: 25) - 1.25) < 0.0001)
        #expect(abs(VarispeedPolicy.rate(forPercentChange: -25) - 0.75) < 0.0001)
        #expect(abs(VarispeedPolicy.rate(forPercentChange: 5.95) - 1.0595) < 0.0001)
        #expect(abs(VarispeedPolicy.rate(forPercentChange: 100) - 2.0) < 0.0001)
        #expect(abs(VarispeedPolicy.rate(forPercentChange: -50) - 0.5) < 0.0001)

        // Clamping & non-finite safety
        #expect(VarispeedPolicy.rate(forPercentChange: 250) == 2.0)
        #expect(VarispeedPolicy.rate(forPercentChange: -90) == 0.5)
        #expect(VarispeedPolicy.rate(forPercentChange: .nan) == 1.0)
        #expect(VarispeedPolicy.rate(forPercentChange: .infinity) == 1.0)

        // Inverse conversions
        #expect(abs(VarispeedPolicy.percentChange(forRate: 1.25) - 25.0) < 0.001)
        #expect(abs(VarispeedPolicy.percentChange(forRate: 0.75) - (-25.0)) < 0.001)
        #expect(abs(VarispeedPolicy.speedPercent(forRate: 1.25) - 125.0) < 0.001)
        #expect(abs(VarispeedPolicy.rate(forSpeedPercent: 75.0) - 0.75) < 0.0001)
        #expect(abs(VarispeedPolicy.rate(forSpeedPercent: 125.0) - 1.25) < 0.0001)
    }

    @Test("Semitone alignment obeys equal temperament (2^(n/12)) including +1 st ≈ +5.95%")
    func semitoneAlignment() {
        let plusOne = VarispeedPolicy.rate(forSemitones: 1)
        #expect(abs(plusOne - 1.0594631) < 0.0001)
        #expect(abs(VarispeedPolicy.percentChange(forRate: plusOne) - 5.9463) < 0.01)
        #expect(VarispeedPolicy.signedPercentLabel(forRate: plusOne) == "+5.95%")
        #expect(VarispeedPolicy.nearestSemitone(forRate: plusOne) == 1)
        #expect(VarispeedPolicy.nearestSemitone(forRate: VarispeedPolicy.rate(forPercentChange: 5.95)) == 1)

        let minusOne = VarispeedPolicy.rate(forSemitones: -1)
        #expect(abs(minusOne - 0.9438743) < 0.0001)
        #expect(abs(VarispeedPolicy.percentChange(forRate: minusOne) - (-5.6126)) < 0.01)
        #expect(VarispeedPolicy.signedPercentLabel(forRate: minusOne) == "-5.61%")
        #expect(VarispeedPolicy.nearestSemitone(forRate: minusOne) == -1)

        #expect(abs(VarispeedPolicy.rate(forSemitones: 12) - 2.0) < 0.0001)
        #expect(abs(VarispeedPolicy.rate(forSemitones: -12) - 0.5) < 0.0001)
        #expect(VarispeedPolicy.rate(forSemitones: 0) == 1.0)
        #expect(abs(VarispeedPolicy.semitones(forRate: 1.25) - 3.8631) < 0.01)
        #expect(abs(VarispeedPolicy.semitones(forRate: 0.75) - (-4.9804)) < 0.01)
        #expect(abs(VarispeedPolicy.cents(forRate: 2.0) - 1200.0) < 0.01)

        // Nightcore (125%) is ~+3.86 st, not an integer semitone
        #expect(VarispeedPolicy.nearestSemitone(forRate: 1.25) == nil)
    }

    @Test("Speed presets include Slowed 75%, Original 100%, and Nightcore 125%")
    func presetsAndLabels() {
        let slowed = VarispeedPolicy.speedPresets.first { $0.kind == .slowed }
        let nightcore = VarispeedPolicy.speedPresets.first { $0.kind == .nightcore }
        let original = VarispeedPolicy.speedPresets.first { $0.kind == .original }
        #expect(slowed?.speedPercent == 75)
        #expect(slowed?.rate == 0.75)
        #expect(nightcore?.speedPercent == 125)
        #expect(nightcore?.rate == 1.25)
        #expect(original?.speedPercent == 100)
        #expect(original?.rate == 1.0)
        #expect(VarispeedPolicy.matchingSpeedPreset(forRate: 1.25)?.kind == .nightcore)
        #expect(VarispeedPolicy.matchingSpeedPreset(forRate: 0.75)?.kind == .slowed)

        #expect(VarispeedPolicy.pitchPresets.count == 25) // -12...+12
        #expect(VarispeedPolicy.signedPercentLabel(forRate: 1.0) == "0%")
        #expect(VarispeedPolicy.signedPercentLabel(forRate: 1.25) == "+25%")
        #expect(VarispeedPolicy.signedPercentLabel(forRate: 0.75) == "-25%")
        #expect(VarispeedPolicy.speedPercentLabel(forRate: 1.25) == "125%")
        #expect(VarispeedPolicy.signedSemitoneValue(forRate: 1.0) == nil)
        #expect(VarispeedPolicy.signedSemitoneValue(forRate: VarispeedPolicy.rate(forSemitones: 2)) == "+2")
        #expect(VarispeedPolicy.signedSemitoneValue(forRate: 1.25) == "+3.9")
    }

    @Test("Availability and effective clock rate respect spoken word, high fidelity, radio, and karaoke")
    func availabilityAndClockRate() {
        #expect(VarispeedPolicy.availability(isSpokenWord: false, isLiveRadio: false, isAppleMusic: false, isCasting: false, isHighFidelityOutput: false) == .available)
        #expect(VarispeedPolicy.availability(isSpokenWord: true, isLiveRadio: false, isAppleMusic: false, isCasting: false, isHighFidelityOutput: false) == .notOffered)
        #expect(VarispeedPolicy.availability(isSpokenWord: false, isLiveRadio: true, isAppleMusic: false, isCasting: false, isHighFidelityOutput: false) == .notOffered)
        #expect(VarispeedPolicy.availability(isSpokenWord: false, isLiveRadio: false, isAppleMusic: true, isCasting: false, isHighFidelityOutput: false) == .appleMusic)
        #expect(VarispeedPolicy.availability(isSpokenWord: false, isLiveRadio: false, isAppleMusic: false, isCasting: true, isHighFidelityOutput: false) == .casting)
        #expect(VarispeedPolicy.availability(isSpokenWord: false, isLiveRadio: false, isAppleMusic: false, isCasting: false, isHighFidelityOutput: true) == .highFidelity)

        #expect(VarispeedPolicy.isEffective(mode: .varispeed, isSpokenWord: false, isLiveRadio: false, outputAllowsEffects: true))
        #expect(!VarispeedPolicy.isEffective(mode: .independent, isSpokenWord: false, isLiveRadio: false, outputAllowsEffects: true))
        #expect(!VarispeedPolicy.isEffective(mode: .varispeed, isSpokenWord: true, isLiveRadio: false, outputAllowsEffects: true))
        #expect(!VarispeedPolicy.isEffective(mode: .varispeed, isSpokenWord: false, isLiveRadio: true, outputAllowsEffects: true))
        #expect(!VarispeedPolicy.isEffective(mode: .varispeed, isSpokenWord: false, isLiveRadio: false, outputAllowsEffects: false))
        #expect(!VarispeedPolicy.isEffective(mode: .varispeed, isSpokenWord: false, isLiveRadio: false, outputAllowsEffects: true, isKaraokePracticeActive: true))

        // Clock rate stays in sync across modes
        #expect(abs(VarispeedPolicy.effectiveClockRate(
            mode: .varispeed,
            independentMusicRate: 1.0,
            varispeedRate: 1.25,
            isSpokenWord: false,
            spokenWordRate: 1.5,
            isLiveRadio: false,
            outputAllowsEffects: true
        ) - 1.25) < 0.0001)

        // Spoken word ignores music varispeed
        #expect(abs(VarispeedPolicy.effectiveClockRate(
            mode: .varispeed,
            independentMusicRate: 1.0,
            varispeedRate: 1.25,
            isSpokenWord: true,
            spokenWordRate: 1.5,
            isLiveRadio: false,
            outputAllowsEffects: true
        ) - 1.5) < 0.0001)

        // High-fidelity direct bypass forces 1.0x for music
        #expect(VarispeedPolicy.effectiveClockRate(
            mode: .varispeed,
            independentMusicRate: 1.25,
            varispeedRate: 1.25,
            isSpokenWord: false,
            spokenWordRate: 1.5,
            isLiveRadio: false,
            outputAllowsEffects: false
        ) == 1.0)
    }

    #if canImport(AVFAudio) && !os(watchOS)
    @Test("AVAudioUnitVarispeed shifts pitch and advances player clock together in offline render")
    func offlineVarispeedRenderShiftsPitchAndClock() throws {
        let sampleRate = 48_000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        let rate = VarispeedPolicy.rate(forSemitones: 1) // +5.95%, +1 semitone
        varispeed.rate = rate
        varispeed.bypass = false

        engine.attach(player)
        engine.attach(varispeed)
        // crash-pattern: allow avaudioengine-connect Offline rendering test fixture using uniform standard format
        engine.connect(player, to: varispeed, format: format)
        // crash-pattern: allow avaudioengine-connect Offline rendering test fixture using uniform standard format
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        // crash-pattern: allow avaudioengine-connect Offline rendering test fixture using uniform standard format
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)

        let totalFrames = Int(sampleRate * 3.0)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)))
        buffer.frameLength = buffer.frameCapacity
        let baseFrequency = 220.0
        for i in 0..<totalFrames {
            let value = Float(0.25 * sin(2.0 * .pi * baseFrequency * Double(i) / sampleRate))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        player.scheduleBuffer(buffer)
        try engine.start()
        // crash-pattern: allow audio-player-node-play Offline rendering test fixture after engine start
        player.play()
        defer {
            player.stop()
            engine.stop()
        }

        func render(seconds: Double) throws -> [Float] {
            let needed = Int(seconds * sampleRate)
            let scratch = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            var out: [Float] = []
            out.reserveCapacity(needed)
            while out.count < needed {
                let status = try engine.renderOffline(AVAudioFrameCount(min(1024, needed - out.count)), to: scratch)
                if status == .cannotDoInCurrentContext { continue }
                try #require(status == .success)
                let data = try #require(scratch.floatChannelData)
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(scratch.frameLength)))
            }
            return out
        }

        _ = try render(seconds: 0.2)
        let startNodeTime = try #require(player.lastRenderTime)
        let startPlayerTime = try #require(player.playerTime(forNodeTime: startNodeTime))
        let rendered = try render(seconds: 0.5)
        let endNodeTime = try #require(player.lastRenderTime)
        let endPlayerTime = try #require(player.playerTime(forNodeTime: endNodeTime))

        // Verify linked frequency shift: 220 Hz * 2^(1/12) ≈ 233.08 Hz
        let crossings = zip(rendered, rendered.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let measuredFreq = Double(crossings) * sampleRate / Double(rendered.count)
        let expectedFreq = baseFrequency * Double(rate)
        #expect(abs(measuredFreq - expectedFreq) < 3.0)

        // Verify player clock advanced by 0.5s * rate
        let playerDelta = Double(endPlayerTime.sampleTime - startPlayerTime.sampleTime) / sampleRate
        #expect(abs(playerDelta - 0.5 * Double(rate)) < 0.05)
    }
    #endif
}
