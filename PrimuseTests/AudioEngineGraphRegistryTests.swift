import AVFoundation
import CoreMotion
import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 配置变化通知只认编号，不持有发出通知的引擎（1.11.3(99) Mac 闪退）。
final class AudioEngineGraphRegistryTests: XCTestCase {
    func testNotificationObjectMapsToTheRegisteredGraphOnly() {
        let registry = AudioEngineGraphRegistry()
        let engine = AVAudioEngine()
        let token = registry.register(engine)

        XCTAssertEqual(registry.token(forNotificationObject: engine), token)
        XCTAssertNil(registry.token(forNotificationObject: AVAudioEngine()))
        XCTAssertNil(registry.token(forNotificationObject: "not an engine"))
        XCTAssertNil(registry.token(forNotificationObject: nil))
    }

    func testReplacedGraphNoLongerMatchesAndTokensAreNeverReused() {
        let registry = AudioEngineGraphRegistry()
        let engine = AVAudioEngine()
        let first = registry.register(engine)
        registry.unregister(engine)
        XCTAssertNil(registry.token(forNotificationObject: engine))

        // 同一个对象（等同于新图分到旧地址）重新登记也是新编号，旧通知认不上。
        let second = registry.register(engine)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(registry.token(forNotificationObject: engine), second)
    }

    func testNotificationTokenDoesNotRetainTheEngine() {
        let registry = AudioEngineGraphRegistry()
        weak var released: AVAudioEngine?
        var token: AudioEngineGraphToken?
        autoreleasepool {
            let engine = AVAudioEngine()
            released = engine
            _ = registry.register(engine)
            token = registry.token(forNotificationObject: engine)
            registry.unregister(engine)
        }
        XCTAssertNotNil(token)
        XCTAssertNil(released)
    }
}

@MainActor
final class SpatialHeadTrackingTests: XCTestCase {
    func testRepeatedPlaybackSetupIssuesOnlyOnePendingHeadphoneRequest() throws {
        let motion = PendingHeadphoneMotionManager()
        let engine = AudioEngine(makeHeadphoneMotionManager: { motion })
        defer { engine.stop() }

        engine.configureSpatialAudio(enabled: true, headTrackingEnabled: true)
        try engine.start()
        XCTAssertEqual(motion.starts, 0, "Preparing the graph must not start a sensor subscription")
        XCTAssertTrue(engine.play())
        for _ in 0..<3 {
            engine.configureSpatialAudio(enabled: true, headTrackingEnabled: true)
            try engine.start()
        }
        XCTAssertEqual(motion.starts, 1, "The headphones have not acknowledged the first request yet")
        engine.stop()
        engine.stop()
        XCTAssertEqual(motion.stops, 1)
    }

    func testLateCallbackAfterPauseCannotCancelTheResumedSubscription() throws {
        let first = PendingHeadphoneMotionManager()
        let second = PendingHeadphoneMotionManager()
        var managers = [first, second].makeIterator()
        let engine = AudioEngine(makeHeadphoneMotionManager: { managers.next() })
        defer { engine.stop() }

        engine.configureSpatialAudio(enabled: true, headTrackingEnabled: true)
        try engine.start()
        XCTAssertTrue(engine.play())
        XCTAssertEqual(first.starts, 1)
        engine.pause()
        XCTAssertEqual(first.stops, 1)
        XCTAssertTrue(engine.resume())
        XCTAssertEqual(second.starts, 1)

        first.reportError()
        XCTAssertEqual(second.stops, 0)
        second.reportError()
        XCTAssertEqual(second.stops, 1)
        XCTAssertTrue(engine.isActuallyPlaying)
    }

    func testAudioRendersWhenMotionIsUnavailableAndSurvivesRouteChanges() async throws {
        let motion = PendingHeadphoneMotionManager()
        var permittedManager: PendingHeadphoneMotionManager?
        let engine = AudioEngine(makeHeadphoneMotionManager: { permittedManager })
        defer { engine.stop() }
        engine.configureSpatialAudio(enabled: true, headTrackingEnabled: true)
        try engine.start()

        let format = try XCTUnwrap(engine.outputFormat)
        let frames = AVAudioFrameCount(format.sampleRate / 4)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let samples = channel.mData { memset(samples, 0, Int(channel.mDataByteSize)) }
        }
        let played = expectation(description: "Audio reached the output")
        XCTAssertNotNil(engine.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            played.fulfill()
        })
        XCTAssertTrue(engine.play())
        XCTAssertEqual(motion.starts, 0)

        func routeChanged() {
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                                            object: AVAudioSession.sharedInstance())
        }
        permittedManager = motion
        motion.available = false
        routeChanged()
        XCTAssertEqual(motion.starts, 0)
        motion.available = true
        routeChanged()
        routeChanged()
        XCTAssertEqual(motion.starts, 1)
        motion.available = false
        routeChanged()
        XCTAssertEqual(motion.stops, 1)
        XCTAssertTrue(engine.spatialAudioEnabled)
        await fulfillment(of: [played], timeout: 5)
    }

    func testFailedGraphStartupAndDisabledTrackingNeverRequestMotion() throws {
        var requests = 0
        let failing = AudioEngine(startGraph: { _ in throw CocoaError(.featureUnsupported) },
                                  makeHeadphoneMotionManager: { requests += 1; return nil })
        defer { failing.stop() }
        failing.configureSpatialAudio(enabled: true, headTrackingEnabled: true)
        XCTAssertThrowsError(try failing.start())
        XCTAssertEqual(requests, 0)

        let engine = AudioEngine(makeHeadphoneMotionManager: { requests += 1; return nil })
        defer { engine.stop() }
        engine.configureSpatialAudio(enabled: true, headTrackingEnabled: false)
        try engine.start()
        XCTAssertTrue(engine.play())
        XCTAssertEqual(requests, 0)
    }
}

private final class PendingHeadphoneMotionManager: CMHeadphoneMotionManager {
    var available = true
    var starts = 0
    var stops = 0
    private var handler: CMHeadphoneMotionManager.DeviceMotionHandler?
    override var isDeviceMotionAvailable: Bool { available }
    override var isDeviceMotionActive: Bool { false }

    override func startDeviceMotionUpdates(
        to queue: OperationQueue,
        withHandler handler: @escaping CMHeadphoneMotionManager.DeviceMotionHandler
    ) {
        starts += 1
        self.handler = handler
    }

    override func stopDeviceMotionUpdates() {
        stops += 1
    }

    func reportError() {
        handler?(nil, NSError(domain: CMErrorDomain, code: Int(CMErrorNotAvailable.rawValue)))
    }
}

/// 智能速度(REQ-174):解码流最后一站缩短停顿,节点登记处把拿掉的帧记到节点时间线上。
final class SmartSpeedPlaybackTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func makeFormat() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
    }

    /// 一段段拼起来再按 `chunk` 帧切块:正数秒是说话(-20 dBFS 正弦),负数秒是停顿(-80 dBFS 底噪)。
    private func makeBuffers(_ segments: [Double], chunk: Int = 4_096) throws -> [AVAudioPCMBuffer] {
        var samples: [Float] = []
        for segment in segments {
            let count = Int(abs(segment) * sampleRate)
            if segment > 0 {
                samples += (0..<count).map { Float(0.1 * sin(2 * Double.pi * 220 * Double($0) / sampleRate)) }
            } else {
                samples += (0..<count).map { $0.isMultiple(of: 2) ? Float(0.0001) : Float(-0.0001) }
            }
        }
        let format = try makeFormat()
        var buffers: [AVAudioPCMBuffer] = []
        var position = 0
        while position < samples.count {
            let count = min(chunk, samples.count - position)
            let capacity = try XCTUnwrap(AVAudioFrameCount(exactly: count))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
            buffer.frameLength = capacity
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<count { channels[channel][frame] = samples[position + frame] }
            }
            buffers.append(buffer)
            position += count
        }
        return buffers
    }

    private func stream(_ buffers: [AVAudioPCMBuffer]) -> AudioBufferStream {
        AudioBufferStreamFactory.make { continuation in
            let task = Task {
                do {
                    for buffer in buffers { try await continuation.send(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func leftChannel(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        buffers.flatMap { buffer -> [Float] in
            guard let data = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
    }

    private func collect(_ stream: AudioBufferStream) async throws -> [AVAudioPCMBuffer] {
        var output: [AVAudioPCMBuffer] = []
        for try await buffer in stream { output.append(buffer) }
        return output
    }

    func testStreamShortensLongPausesAndKeepsSpeechIntact() async throws {
        let input = try makeBuffers([1, -3, 1])
        let inputFrames = input.reduce(0) { $0 + Int($1.frameLength) }
        let output = try await collect(
            SmartSpeedStream.shorteningPauses(stream(input), registry: PlayerNodeRegistry())
        )
        let outputFrames = output.reduce(0) { $0 + Int($1.frameLength) }
        // 3 秒的停顿只剩不到 1 秒,两段说话一帧不少。
        XCTAssertLessThan(outputFrames, inputFrames - Int(2 * sampleRate))
        XCTAssertGreaterThan(outputFrames, Int(2 * sampleRate))
        let format = try makeFormat()
        XCTAssertTrue(output.allSatisfy { $0.format == format })
        let speech = Int(sampleRate)
        XCTAssertEqual(Array(leftChannel(output).prefix(speech)), Array(leftChannel(input).prefix(speech)))
        XCTAssertEqual(Array(leftChannel(output).suffix(speech)), Array(leftChannel(input).suffix(speech)))
    }

    func testPassthroughFramesAreNotProcessed() async throws {
        let input = try makeBuffers([-3, 1])
        let inputFrames = input.reduce(0) { $0 + Int($1.frameLength) }
        let output = try await collect(
            SmartSpeedStream.shorteningPauses(
                stream(input),
                passthroughFrames: Int64(3 * sampleRate),
                registry: PlayerNodeRegistry()
            )
        )
        XCTAssertEqual(output.reduce(0) { $0 + Int($1.frameLength) }, inputFrames)
        XCTAssertEqual(leftChannel(output), leftChannel(input))
    }

    @MainActor
    func testRegistryPlacesCutsOnTheNodeTimeline() throws {
        let format = try makeFormat()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        try AudioEngine.connect(player, to: engine.mainMixerNode, format: format, in: engine)
        let registry = PlayerNodeRegistry()
        registry.attach(player, to: .primary)
        defer {
            registry.attach(nil, to: .primary)
            player.reset()
            engine.detach(player)
        }

        let buffers = try makeBuffers([-1], chunk: 1_000).prefix(3)
        XCTAssertEqual(buffers.count, 3)
        let first = buffers[buffers.startIndex]
        let second = buffers[buffers.startIndex + 1]
        let plain = buffers[buffers.startIndex + 2]
        registry.annotateSmartSpeedCuts([SmartSpeedCut(frameOffset: 100, removedFrames: 500)], for: first)
        registry.annotateSmartSpeedCuts([SmartSpeedCut(frameOffset: 0, removedFrames: 40)], for: second)
        XCTAssertNotNil(registry.schedule(first, on: .primary))
        XCTAssertNotNil(registry.schedule(second, on: .primary))
        XCTAssertNotNil(registry.schedule(plain, on: .primary))

        XCTAssertEqual(registry.smartSpeedRemovedFrames(on: .primary, from: 0, through: 99), 0)
        XCTAssertEqual(registry.smartSpeedRemovedFrames(on: .primary, from: 0, through: 100), 500)
        XCTAssertEqual(registry.smartSpeedRemovedFrames(on: .primary, from: 0, through: 2_999), 540)
        // 无缝接续的下一首从第 1000 帧起,只算它自己的接缝。
        XCTAssertEqual(registry.smartSpeedRemovedFrames(on: .primary, from: 1_000, through: 2_999), 40)

        registry.swapRoles()
        XCTAssertEqual(registry.smartSpeedRemovedFrames(on: .crossfade, from: 0, through: 2_999), 540)
        XCTAssertEqual(registry.smartSpeedRemovedFrames(on: .primary, from: 0, through: 2_999), 0)
        registry.resetTimeline(for: .crossfade)
        XCTAssertEqual(registry.smartSpeedRemovedFrames(on: .crossfade, from: 0, through: 2_999), 0)
    }
}
