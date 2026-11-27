#if canImport(AVFAudio) && !os(watchOS)
import AVFAudio
import AudioToolbox
import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback time stretching", .serialized)
struct PlaybackTimePitchProcessorTests {
    @Test("Content and key changes select one processor without multiplying playback rates")
    func routing() throws {
        let processor = PlaybackTimePitchProcessor(spectralOverlap: 16)
        let timeDomain = try #require(processor.timeDomainNode)
        processor.apply(rate: 1.5)
        #expect(processor.algorithm == .timeDomain)
        #expect(!timeDomain.bypass && processor.spectralNode.bypass)
        #expect(processor.spectralNode.rate == 1)
        processor.apply(rate: 1.5, pitchCents: 300)
        #expect(processor.algorithm == .spectral)
        #expect(timeDomain.bypass && !processor.spectralNode.bypass)
        #expect(processor.spectralNode.rate == 1.5)
        #expect(processor.spectralNode.pitch == 300)
        processor.apply(rate: 0.75)
        #expect(processor.algorithm == .spectral)
        processor.apply(rate: 0.75, isSpokenWord: true)
        #expect(processor.algorithm == .timeDomain)
        processor.apply(rate: 1)
        #expect(timeDomain.bypass && processor.spectralNode.bypass)
        #expect(processor.spectralNode.pitch == 0)
        #expect(processor.spectralNode.overlap == 16)
    }

    @Test("An unavailable time-domain unit retains working spectral speed and pitch")
    func fallbackAndInvalidInput() {
        let processor = PlaybackTimePitchProcessor(timeDomainNode: nil)
        processor.apply(rate: 1.5, isSpokenWord: true)
        #expect(processor.algorithm == .spectral)
        #expect(processor.spectralNode.rate == 1.5)
        processor.apply(rate: .nan, pitchCents: .infinity)
        #expect(processor.algorithm == .bypass)
        processor.apply(rate: 10, pitchCents: -3000)
        #expect(processor.spectralNode.rate == 2)
        #expect(processor.spectralNode.pitch == -2400)
    }

    @Test("Rendered speech-speed output has the requested duration and retains pitch",
          arguments: [Float(0.5), 1.25, 1.5, 2])
    func renderedRate(_ rate: Float) throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        fixture.processor.apply(rate: rate, isSpokenWord: true)
        let output = try fixture.render(seconds: 2 / Double(rate) + 0.3)
        let audible = output.indices.filter { abs(output[$0]) > 0.01 }
        let first = try #require(audible.first)
        let last = try #require(audible.last)
        let duration = Double(last - first) / fixture.sampleRate
        #expect(abs(duration - 2 / Double(rate)) < 0.12)
        let middle = Array(output[Int(fixture.sampleRate * 0.3)..<Int(fixture.sampleRate * 0.7)])
        #expect(abs(frequency(middle, sampleRate: fixture.sampleRate) - 220) < 4)
    }

    @Test("Unity and accelerated playback preserve channels across sample rates",
          arguments: [(44_100.0, UInt32(1)), (48_000.0, 2), (96_000.0, 6)])
    func unity(_ format: (Double, UInt32)) throws {
        let fixture = try Fixture(sampleRate: format.0, channels: format.1)
        defer { fixture.stop() }
        let output = try fixture.render(seconds: 0.2)
        let error = zip(output, fixture.input).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 0.00001)
        fixture.processor.apply(rate: 1.25)
        _ = try fixture.render(seconds: 0.2)
        let accelerated = try fixture.render(seconds: 0.4)
        #expect(abs(frequency(accelerated, sampleRate: fixture.sampleRate) - 220) < 4)
    }

    @Test("Switching between speed and key shift preserves pitch, clock and reset behavior")
    func liveChangesAndReset() throws {
        let fixture = try Fixture(toneSeconds: 8)
        defer { fixture.stop() }
        fixture.processor.apply(rate: 1.5)
        _ = try fixture.render(seconds: 0.3)
        let clockBefore = try fixture.playerSeconds()
        _ = try fixture.render(seconds: 0.4)
        let clockAfter = try fixture.playerSeconds()
        #expect(abs((clockAfter - clockBefore) - 0.6) < 0.06)

        fixture.processor.apply(rate: 1.5, pitchCents: 300)
        _ = try fixture.render(seconds: 0.25)
        let pitched = try fixture.render(seconds: 0.4)
        #expect(abs(frequency(pitched, sampleRate: fixture.sampleRate) - 220 * pow(2, 3.0 / 12)) < 4)
        fixture.processor.apply(rate: 1.5)
        _ = try fixture.render(seconds: 0.25)
        let restored = try fixture.render(seconds: 0.4)
        #expect(abs(frequency(restored, sampleRate: fixture.sampleRate) - 220) < 4)

        fixture.engine.pause()
        fixture.player.stop()
        fixture.processor.reset()
        try fixture.scheduleSilence()
        try fixture.engine.start()
        // crash-pattern: allow audio-player-node-play 离线渲染夹具，引擎刚启动成功、节点在夹具初始化时已接好
        fixture.player.play()
        let silence = try fixture.render(seconds: 0.3)
        #expect(silence.allSatisfy { abs($0) < 0.00001 })
    }

    private func frequency(_ samples: [Float], sampleRate: Double) -> Double {
        let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        return Double(crossings) * sampleRate / Double(samples.count)
    }

    private final class Fixture {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let processor = PlaybackTimePitchProcessor()
        let format: AVAudioFormat
        let sampleRate: Double
        let input: [Float]

        init(sampleRate: Double = 48_000, channels: UInt32 = 2, toneSeconds: Double = 2) throws {
            self.sampleRate = sampleRate
            if channels == 6 {
                let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
                format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
            } else {
                format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
            }
            input = (0..<Int(sampleRate * toneSeconds)).map { Float(0.2 * sin(2 * .pi * 220 * Double($0) / sampleRate)) }
            engine.attach(player)
            if let timeDomain = processor.timeDomainNode {
                engine.attach(timeDomain)
            }
            engine.attach(processor.spectralNode)
            // crash-pattern: allow avaudioengine-connect 离线渲染夹具，整条链路统一用本夹具的标准格式
            engine.connect(player, to: processor.inputNode, format: format)
            if let timeDomain = processor.timeDomainNode {
                // crash-pattern: allow avaudioengine-connect 同上，沿用夹具的标准格式
                engine.connect(timeDomain, to: processor.spectralNode, format: format)
            }
            // crash-pattern: allow avaudioengine-connect 同上，沿用夹具的标准格式
            engine.connect(processor.spectralNode, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            // crash-pattern: allow avaudioengine-connect 离线渲染已按同一格式开启
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count)))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<Int(channels) {
                input.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: input.count) }
            }
            player.scheduleBuffer(buffer)
            try scheduleSilence()
            try engine.start()
            // crash-pattern: allow audio-player-node-play 离线渲染夹具，引擎刚启动成功、节点已接好
            player.play()
        }

        func scheduleSilence() throws {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData![channel].update(repeating: 0, count: Int(buffer.frameLength))
            }
            player.scheduleBuffer(buffer)
        }

        func render(seconds: Double) throws -> [Float] {
            let frames = Int(seconds * sampleRate)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            var output: [Float] = []
            var retries = 0
            while output.count < frames {
                let status = try engine.renderOffline(AVAudioFrameCount(min(1024, frames - output.count)), to: buffer)
                if status == .cannotDoInCurrentContext {
                    retries += 1
                    try #require(retries < 100)
                    continue
                }
                try #require(status == .success)
                try #require(buffer.frameLength > 0)
                let data = try #require(buffer.floatChannelData)
                output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
                for channel in 1..<Int(format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        try #require(abs(data[channel][frame] - data[0][frame]) < 0.00001)
                    }
                }
            }
            let finite = output.allSatisfy { $0.isFinite }
            #expect(finite)
            return output
        }

        func playerSeconds() throws -> Double {
            let renderTime = try #require(player.lastRenderTime)
            let time = try #require(player.playerTime(forNodeTime: renderTime))
            return Double(time.sampleTime) / time.sampleRate
        }

        func stop() {
            player.stop()
            engine.stop()
        }
    }
}
#endif
