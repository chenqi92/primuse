import AVFoundation
import Foundation
import Observation
import XCTest
#if !PRIMUSE_AUDIO_VOLUME_SMOKE
@testable import Primuse
#endif

final class AudioEngineVolumeTests: XCTestCase {
    @MainActor
    func testRejectedDSDStartupRebuildsPCMWithoutKeepingCarrierState() throws {
        try withDefaults { defaults in
            var attempts = 0
            let engine = AudioEngine(volumeDefaults: defaults, outputDefaults: defaults, startGraph: { _ in
                attempts += 1
                if attempts == 1 {
                    throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
                }
            })
            defer { engine.stop() }
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))

            XCTAssertFalse(try engine.prepareDSDCarrier(format))
            XCTAssertEqual(attempts, 1)
            XCTAssertFalse(engine.usesDSDCarrier)
            XCTAssertFalse(engine.isSetUp)
            XCTAssertNil(engine.outputFormat)

            try engine.configure(outputMode: .highFidelity, directSourceFormat: format)
            try engine.start()
            XCTAssertEqual(attempts, 2)
            XCTAssertFalse(engine.usesDSDCarrier)
            XCTAssertEqual(engine.outputFormat, format)
            XCTAssertNil(engine.effectsMainMixer)

            XCTAssertTrue(try engine.prepareDSDCarrier(format))
            XCTAssertEqual(attempts, 3, "A later usable route must still be able to prepare DoP")
            XCTAssertTrue(engine.usesDSDCarrier)
        }
    }

    @MainActor
    func testCancelledDSDStartupDoesNotBecomePCMFallback() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults, outputDefaults: defaults, startGraph: { _ in
                throw CancellationError()
            })
            defer { engine.stop() }
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            XCTAssertThrowsError(try engine.prepareDSDCarrier(format)) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertFalse(engine.usesDSDCarrier)
            XCTAssertFalse(engine.isSetUp)
            XCTAssertNil(engine.outputFormat)
        }
    }

    #if os(iOS)
    @MainActor
    func testRejectedDoPConnectionLeavesPCMUsable() throws {
        try withDefaults { defaults in
            var starts = 0
            let engine = AudioEngine(volumeDefaults: defaults, outputDefaults: defaults, startGraph: { _ in
                starts += 1
            }, connectDirectOutput: { graph, player, format in
                if format.commonFormat == .otherFormat {
                    throw NSError(domain: NSOSStatusErrorDomain, code: -10868)
                }
                try AudioEngine.connect(player, to: graph.outputNode, format: format, in: graph)
            })
            defer { engine.stop() }
            var description = AudioStreamBasicDescription(
                mSampleRate: 176_400,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                    | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian,
                mBytesPerPacket: 3, mFramesPerPacket: 1, mBytesPerFrame: 3,
                mChannelsPerFrame: 2, mBitsPerChannel: 24, mReserved: 0
            )
            let carrier = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
            XCTAssertFalse(try engine.prepareDSDCarrier(carrier))
            XCTAssertEqual(starts, 0, "Rejected connections must not reach startup")
            XCTAssertFalse(engine.usesDSDCarrier)
            XCTAssertNil(engine.outputFormat)
            let pcm = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            try engine.configure(outputMode: .highFidelity, directSourceFormat: pcm)
            try engine.start()
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(engine.outputFormat, pcm)
            XCTAssertFalse(engine.usesDSDCarrier)
        }
    }
    #endif

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
    func testHighFidelityAppliesApplicationGainAndRestoresEffectsVolume() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            engine.volume = 0.43
            try engine.configure(outputMode: .highFidelity)
            XCTAssertNil(engine.effectsMainMixer)
            // 直通图没有混音器,频谱 tap 改挂在主播放节点上,否则声音响应画面永远静止。
            XCTAssertTrue(engine.visualizerTapNode is AVAudioPlayerNode)
            XCTAssertFalse(engine.usesDSDCarrier)
            // 直通 PCM 的增益走输出单元的应用级音量。这台机器上写得进去就该显示
            // 用户设定值,写不进去时控件会退回禁用,显示满格才诚实。
            if engine.applicationGainIsAvailable {
                XCTAssertEqual(engine.volume, 0.43, accuracy: 0.0001)
            } else {
                XCTAssertEqual(engine.volume, 1)
            }

            try engine.configure(outputMode: .effects)
            XCTAssertEqual(engine.volume, 0.43, accuracy: 0.0001)
            let mixer = try XCTUnwrap(engine.effectsMainMixer)
            XCTAssertEqual(mixer.outputVolume, 0.43, accuracy: 0.0001)
            XCTAssertTrue(engine.visualizerTapNode === mixer)
        }
    }

    @MainActor
    func testDSDCarrierGraphStaysAtUnityGain() throws {
        try withDefaults { defaults in
            let engine = AudioEngine(volumeDefaults: defaults)
            engine.volume = 0.43
            let carrier = try XCTUnwrap(
                AVAudioFormat(standardFormatWithSampleRate: 176_400, channels: 2)
            )
            try engine.configure(
                outputMode: .highFidelity,
                directSourceFormat: carrier,
                isDSDCarrier: true
            )
            // DSD 的样本里装的是 1bit 码流,乘任何系数都会变成噪声。
            XCTAssertTrue(engine.usesDSDCarrier)
            XCTAssertFalse(engine.applicationGainIsAvailable)
            XCTAssertEqual(engine.volume, 1)

            // 用户音量本身没丢,换回能加增益的图就该原样回来。
            try engine.configure(outputMode: .effects)
            XCTAssertFalse(engine.usesDSDCarrier)
            XCTAssertEqual(engine.volume, 0.43, accuracy: 0.0001)
        }
    }
    #endif

    #if os(iOS)
    @MainActor
    func testApplicationGainStaysAtUnityUntilAppVolumeIsEnabled() throws {
        try withDefaults { defaults in
            defaults.set(Float(0.2), forKey: "primuse_volume")
            let engine = AudioEngine(volumeDefaults: defaults)
            XCTAssertEqual(engine.volume, 1)
            engine.volume = 0.4

            engine.restoreVolume()

            XCTAssertEqual(engine.volume, 1)
            XCTAssertNil(engine.outputFormat)

            // 打开「应用内音量」接着用存着的值,重建图时保持;关掉回到单位增益,存着的值留到下次打开。
            XCTAssertEqual(try XCTUnwrap(engine.setApplicationVolumeEnabled(true)), 0.4, accuracy: 0.0001)
            XCTAssertEqual(engine.volume, 0.4, accuracy: 0.0001)
            XCTAssertNil(engine.setApplicationVolumeEnabled(true))
            engine.restoreVolume()
            XCTAssertEqual(engine.userVolume, 0.4, accuracy: 0.0001)

            XCTAssertEqual(engine.setApplicationVolumeEnabled(false), 1)
            XCTAssertEqual(engine.userVolume, 1)
            XCTAssertEqual(defaults.float(forKey: "primuse_volume"), 0.4, accuracy: 0.0001)
            engine.restoreVolume()
            XCTAssertEqual(engine.userVolume, 1)
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
