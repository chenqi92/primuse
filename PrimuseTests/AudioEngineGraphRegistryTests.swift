import AVFoundation
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
