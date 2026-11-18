import AVFoundation
import CoreMotion
import Foundation
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
