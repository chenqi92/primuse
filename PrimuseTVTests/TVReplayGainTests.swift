#if os(tvOS)
import AVFoundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVReplayGainTests: XCTestCase {
    func testTapAmplifiesAndRampsWithoutChangingOtherChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
        buffer.frameLength = 2400
        func fill() {
            for frame in 0..<2400 {
                buffer.floatChannelData![0][frame] = 0.1
                buffer.floatChannelData![1][frame] = -0.1
            }
        }
        let renderer = TVReplayGainRenderer()
        renderer.setGain(2)
        renderer.configure(format.streamDescription.pointee)
        fill()
        renderer.process(buffer.mutableAudioBufferList, frames: 2400)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.2, accuracy: 0.001)
        XCTAssertEqual(buffer.floatChannelData![1][2399], -0.2, accuracy: 0.001)
        renderer.setGain(0.5)
        fill()
        renderer.process(buffer.mutableAudioBufferList, frames: 2400)
        XCTAssertGreaterThan(buffer.floatChannelData![0][0], 0.19)
        XCTAssertEqual(buffer.floatChannelData![0][2399], 0.05, accuracy: 0.001)
    }

    @MainActor func testTVSettingsPersistAndClampPreamp() throws {
        let name = "replaygain-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TVReplayGainSettings(defaults: defaults)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.mode, .automatic)
        settings.enabled = true
        settings.mode = .album
        settings.preampDB = 25
        let restored = TVReplayGainSettings(defaults: defaults)
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.mode, .album)
        XCTAssertEqual(restored.preampDB, 12)
    }
}
#endif
