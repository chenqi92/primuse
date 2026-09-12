import AVFoundation
import Foundation
import Observation
import XCTest
#if !PRIMUSE_AUDIO_VOLUME_SMOKE
@testable import Primuse
#endif

final class AudioEngineVolumeTests: XCTestCase {
    @MainActor
    func testVolumeChangesBeforePlaybackPreparesAnAudioGraph() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            XCTAssertNil(engine.outputFormat)

            for volume: Float in [0.216, 0.73, 0, 1] {
                engine.volume = volume
                XCTAssertEqual(engine.volume, volume, accuracy: 0.0001)
                XCTAssertEqual(defaults.float(forKey: "primuse_volume"), volume, accuracy: 0.0001)
                XCTAssertNil(engine.outputFormat)
                XCTAssertNil(engine.effectsMainMixer)
            }
        }
    }

    @MainActor
    func testVolumeChangeInvalidatesObservationWithoutAnAudioGraph() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            let changed = expectation(description: "Visible volume changes")
            withObservationTracking {
                _ = engine.volume
            } onChange: {
                changed.fulfill()
            }

            engine.volume = 0.35

            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.1), .completed)
            XCTAssertEqual(engine.volume, 0.35, accuracy: 0.0001)
            XCTAssertNil(engine.outputFormat)
        }
    }

    @MainActor
    func testContinuousChangesPublishImmediatelyAndSaveOnlyTheFinalValue() throws {
        try withDefaults { defaults in
            defaults.set(Float(0.27), forKey: "primuse_volume")
            let engine = AudioEngine(volumeDefaults: defaults)
            let changed = expectation(description: "Volume updates during tracking")
            withObservationTracking {
                _ = engine.volume
            } onChange: {
                changed.fulfill()
            }

            for step in 0...300 {
                let volume = Float(step) / 300
                engine.setVolume(volume, persist: false)
                XCTAssertEqual(engine.volume, volume, accuracy: 0.0001)
                XCTAssertEqual(defaults.float(forKey: "primuse_volume"), 0.27, accuracy: 0.0001)
            }

            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.1), .completed)
            engine.persistVolume()
            XCTAssertEqual(defaults.float(forKey: "primuse_volume"), 1)
            XCTAssertNil(engine.outputFormat)
        }
    }

    @MainActor
    func testRepeatedValuesDoNotInvalidateVolumeObservation() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            engine.volume = 1
            let changed = expectation(description: "Unchanged volume does not redraw")
            changed.isInverted = true
            withObservationTracking {
                _ = engine.volume
            } onChange: {
                changed.fulfill()
            }

            for value: Float in [1, 1, 2, .nan, .infinity] {
                engine.volume = value
            }

            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.02), .completed)
        }
    }

    @MainActor
    func testOutOfRangeAndNonfiniteValuesDoNotCorruptVolume() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            engine.volume = 0.4
            for invalid: Float in [.nan, .infinity, -.infinity] {
                engine.volume = invalid
                XCTAssertEqual(engine.volume, 0.4, accuracy: 0.0001)
                XCTAssertEqual(defaults.float(forKey: "primuse_volume"), 0.4, accuracy: 0.0001)
            }
            engine.volume = 2
            XCTAssertEqual(engine.volume, 1)
            engine.volume = -1
            XCTAssertEqual(engine.volume, 0)
        }
    }

    #if os(macOS)
    @MainActor
    func testTrackingChangesMixerBeforeSavingAndSurvivesGraphRebuild() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            engine.volume = 0.3
            try engine.configure(outputMode: .effects)
            engine.setVolume(0.72, persist: false)

            XCTAssertEqual(try XCTUnwrap(engine.effectsMainMixer).outputVolume, 0.72, accuracy: 0.0001)
            XCTAssertEqual(defaults.float(forKey: "primuse_volume"), 0.3, accuracy: 0.0001)
            engine.markHardwareConfigurationChanged()
            try engine.configure(outputMode: .effects)
            XCTAssertEqual(try XCTUnwrap(engine.effectsMainMixer).outputVolume, 0.72, accuracy: 0.0001)

            engine.persistVolume()
            XCTAssertEqual(AudioEngine(volumeDefaults: defaults).volume, 0.72, accuracy: 0.0001)
        }
    }

    @MainActor
    func testRestoresSavedVolumeBeforePlaybackStarts() throws {
        try withDefaults { defaults in
            defaults.set(Float(0.27), forKey: "primuse_volume")
            let engine = AudioEngine(volumeDefaults: defaults)
            XCTAssertEqual(engine.volume, 0.27, accuracy: 0.0001)
            XCTAssertNil(engine.outputFormat)

            engine.volume = 0.63
            let restored = AudioEngine(volumeDefaults: defaults)
            XCTAssertEqual(restored.volume, 0.63, accuracy: 0.0001)
            XCTAssertNil(restored.outputFormat)
        }
    }

    @MainActor
    func testGraphSetupAndHardwareRebuildApplyRequestedVolume() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            engine.volume = 0.32
            try engine.configure(outputMode: .effects)
            let originalMixer = try XCTUnwrap(engine.effectsMainMixer)
            XCTAssertEqual(originalMixer.outputVolume, 0.32, accuracy: 0.0001)

            engine.volume = 0.58
            XCTAssertEqual(originalMixer.outputVolume, 0.58, accuracy: 0.0001)
            engine.markHardwareConfigurationChanged()
            try engine.configure(outputMode: .effects)

            let rebuiltMixer = try XCTUnwrap(engine.effectsMainMixer)
            XCTAssertFalse(rebuiltMixer === originalMixer)
            XCTAssertEqual(rebuiltMixer.outputVolume, 0.58, accuracy: 0.0001)
            XCTAssertEqual(engine.volume, 0.58, accuracy: 0.0001)
        }
    }

    @MainActor
    func testHighFidelityKeepsUnityAndRestoresEffectsVolume() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            engine.volume = 0.43
            try engine.configure(outputMode: .highFidelity)
            XCTAssertEqual(engine.volume, 1)
            XCTAssertNil(engine.effectsMainMixer)
            // 直通图没有混音器,频谱 tap 改挂在主播放节点上,否则声音响应画面永远静止。
            XCTAssertTrue(engine.visualizerTapNode is AVAudioPlayerNode)

            try engine.configure(outputMode: .effects)
            XCTAssertEqual(engine.volume, 0.43, accuracy: 0.0001)
            let mixer = try XCTUnwrap(engine.effectsMainMixer)
            XCTAssertEqual(mixer.outputVolume, 0.43, accuracy: 0.0001)
            XCTAssertTrue(engine.visualizerTapNode === mixer)
        }
    }
    #endif

    #if os(iOS)
    @MainActor
    func testSystemVolumeMigrationKeepsApplicationGainAtUnity() throws {
        try withDefaults { defaults in
            defaults.set(Float(0.2), forKey: "primuse_volume")
            let engine = AudioEngine(volumeDefaults: defaults)
            XCTAssertEqual(engine.volume, 1)
            engine.volume = 0.4

            engine.restoreVolume()

            XCTAssertEqual(engine.volume, 1)
            XCTAssertNil(defaults.object(forKey: "primuse_volume"))
            XCTAssertNil(engine.outputFormat)
        }
    }
    #endif

    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "audio-engine-volume-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
