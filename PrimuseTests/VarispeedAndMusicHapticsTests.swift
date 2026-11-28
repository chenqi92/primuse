import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class VarispeedAndMusicHapticsTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "com.primuse.tests.varispeed-haptics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLegacyPlaybackSettingsDecodeDefaultsForVarispeedAndMusicHaptics() throws {
        // Minimal payload predating #494 and #469 must decode without error and preserve defaults.
        let legacyJSON = Data("""
        {
            "playbackRate": 1.25,
            "pitchSemitones": 2
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.playbackRate, 1.25, accuracy: 0.0001)
        XCTAssertEqual(decoded.pitchSemitones, 2)
        XCTAssertEqual(decoded.speedPitchMode, .independent)
        XCTAssertEqual(decoded.varispeedRate, 1.0, accuracy: 0.0001)
        XCTAssertFalse(decoded.musicHapticsEnabled)
        XCTAssertEqual(decoded.musicHapticsIntensity, MusicHapticsConfiguration.defaultIntensity, accuracy: 0.0001)
        XCTAssertEqual(decoded.musicHapticsStyle, .balanced)
    }

    func testPlaybackSettingsStoreSynchronizesModeAndCanonicalClockRate() {
        let defaults = makeIsolatedDefaults()
        let store = PlaybackSettingsStore(defaults: defaults, cloudSync: .shared)

        // Independent mode starts at 1.0x
        XCTAssertEqual(store.speedPitchMode, .independent)
        store.playbackRate = 1.5
        XCTAssertEqual(store.playbackRate, 1.5, accuracy: 0.0001)

        // Setting Varispeed by semitones (+1 st ≈ +5.95%) switches mode and updates canonical playbackRate
        store.setVarispeed(semitones: 1)
        XCTAssertEqual(store.speedPitchMode, .varispeed)
        XCTAssertEqual(store.varispeedRate, VarispeedPolicy.rate(forSemitones: 1), accuracy: 0.0001)
        XCTAssertEqual(store.playbackRate, store.varispeedRate, accuracy: 0.0001)

        // Setting Varispeed by speed preset (Nightcore 125%) updates both rates
        store.setVarispeed(speedPercent: 125)
        XCTAssertEqual(store.varispeedRate, 1.25, accuracy: 0.0001)
        XCTAssertEqual(store.playbackRate, 1.25, accuracy: 0.0001)

        // Switching back to independent restores previous independent speed (1.5x) while retaining varispeedRate (1.25x)
        store.setSpeedPitchMode(.independent)
        XCTAssertEqual(store.playbackRate, 1.5, accuracy: 0.0001)
        XCTAssertEqual(store.varispeedRate, 1.25, accuracy: 0.0001)

        // Switching back to varispeed restores Nightcore 1.25x
        store.setSpeedPitchMode(.varispeed)
        XCTAssertEqual(store.playbackRate, 1.25, accuracy: 0.0001)

        // Reset restores 1.0x
        store.resetVarispeed()
        XCTAssertEqual(store.varispeedRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(store.playbackRate, 1.0, accuracy: 0.0001)
    }

    func testMusicHapticsEnabledIsDeviceLocalInCloudKVSMerge() {
        var local = PlaybackSettings()
        local.musicHapticsEnabled = true
        var remote = PlaybackSettings()
        remote.musicHapticsEnabled = false
        remote.speedPitchMode = .varispeed
        remote.varispeedRate = 1.25

        let merged = PlaybackSettings.deviceLocalFields.merge(remote: remote, local: local)
        // Device-local haptics toggle stays true; musical varispeed syncs from remote.
        XCTAssertTrue(merged.settings.musicHapticsEnabled)
        XCTAssertTrue(merged.keptFields.contains("musicHapticsEnabled"))
        XCTAssertEqual(merged.settings.speedPitchMode, .varispeed)
        XCTAssertEqual(merged.settings.varispeedRate, 1.25, accuracy: 0.0001)
    }

    func testIndependentSpeedSurvivesRelaunchWhileVarispeedIsOn() {
        let defaults = makeIsolatedDefaults()
        let store = PlaybackSettingsStore(defaults: defaults, cloudSync: .shared)
        store.playbackRate = 1.5
        store.setVarispeed(speedPercent: 125)

        let relaunched = PlaybackSettingsStore(defaults: defaults, cloudSync: .shared)
        XCTAssertEqual(relaunched.speedPitchMode, .varispeed)
        XCTAssertEqual(relaunched.playbackRate, 1.25, accuracy: 0.0001)
        relaunched.setSpeedPitchMode(.independent)
        XCTAssertEqual(relaunched.playbackRate, 1.5, accuracy: 0.0001)
        XCTAssertEqual(relaunched.varispeedRate, 1.25, accuracy: 0.0001)
    }

    /// A bypassed `AVAudioUnitVarispeed` still delays the signal (47 frames at 48 kHz), so the
    /// default effects graph must not carry it, nor the haptics tap mixer, until the user turns
    /// the feature on.
    func testEffectsGraphGainsVarispeedAndHapticsNodesOnlyAfterTheyAreTurnedOn() throws {
        let engine = AudioEngine()
        try engine.configure(outputMode: .effects)
        defer { engine.stop() }
        let spectral = try XCTUnwrap(engine.timePitchProcessor?.spectralNode)
        let graph = try XCTUnwrap(engine.engine)
        XCTAssertNil(engine.varispeedNode)
        XCTAssertNil(engine.hapticsTapNode)
        XCTAssertTrue(graph.outputConnectionPoints(for: spectral, outputBus: 0).first?.node === graph.mainMixerNode)
        XCTAssertFalse(engine.effectsGraphExtrasNeedRebuild)

        // Varispeed requested before the graph has its unit: keep the speed by time stretching.
        engine.applyPlaybackRate(0.75, userPitchCents: 0, isSpokenWord: false, varispeedEnabled: true)
        XCTAssertFalse(engine.isVarispeedActive)
        XCTAssertEqual(spectral.rate, 0.75, accuracy: 0.0001)

        engine.graphIncludesVarispeedUnit = true
        #if os(iOS)
        engine.graphIncludesHapticsTap = true
        #endif
        XCTAssertTrue(engine.effectsGraphExtrasNeedRebuild)
        try engine.configure(outputMode: .effects)
        let rebuilt = try XCTUnwrap(engine.engine)
        let varispeed = try XCTUnwrap(engine.varispeedNode)
        XCTAssertFalse(engine.effectsGraphExtrasNeedRebuild)
        XCTAssertTrue(engine.isVarispeedActive)
        XCTAssertEqual(varispeed.rate, 0.75, accuracy: 0.0001)
        XCTAssertEqual(engine.timePitchProcessor?.spectralNode.rate ?? -1, 1.0, accuracy: 0.0001)
        #if os(iOS)
        let tap = try XCTUnwrap(engine.hapticsTapNode)
        XCTAssertTrue(rebuilt.outputConnectionPoints(for: varispeed, outputBus: 0).first?.node === tap)
        XCTAssertTrue(rebuilt.outputConnectionPoints(for: tap, outputBus: 0).first?.node === rebuilt.mainMixerNode)
        #else
        XCTAssertTrue(rebuilt.outputConnectionPoints(for: varispeed, outputBus: 0).first?.node === rebuilt.mainMixerNode)
        #endif

        // Turning both off again restores the plain graph on the next build.
        engine.graphIncludesVarispeedUnit = false
        #if os(iOS)
        engine.graphIncludesHapticsTap = false
        #endif
        try engine.configure(outputMode: .effects)
        XCTAssertNil(engine.varispeedNode)
        XCTAssertNil(engine.hapticsTapNode)
    }

    func testAudioEngineEnforcesMutualExclusionBetweenVarispeedAndTimePitch() throws {
        let engine = AudioEngine()
        engine.graphIncludesVarispeedUnit = true
        try engine.setUp()
        defer { engine.stop() }

        // Independent mode: varispeed must stay bypassed at 1.0x
        engine.applyPlaybackRate(1.25, userPitchCents: 200, isSpokenWord: false, varispeedEnabled: false)
        XCTAssertTrue(engine.varispeedNode?.bypass == true)
        XCTAssertEqual(engine.varispeedNode?.rate ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertFalse(engine.isVarispeedActive)

        // Varispeed mode: varispeed active at 1.25x, spectral timePitch rate reset to 1.0x
        engine.applyPlaybackRate(1.25, userPitchCents: 0, isSpokenWord: false, varispeedEnabled: true)
        XCTAssertFalse(engine.varispeedNode?.bypass ?? true)
        XCTAssertEqual(engine.varispeedNode?.rate ?? -1, 1.25, accuracy: 0.0001)
        XCTAssertEqual(engine.timePitchProcessor?.spectralNode.rate ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertTrue(engine.isVarispeedActive)

        // Spoken word always bypasses varispeed even if varispeedEnabled is passed as true
        engine.applyPlaybackRate(1.5, userPitchCents: 0, isSpokenWord: true, varispeedEnabled: true)
        XCTAssertTrue(engine.varispeedNode?.bypass == true)
        XCTAssertEqual(engine.varispeedNode?.rate ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertFalse(engine.isVarispeedActive)
    }
}
