import AVFoundation
import XCTest
import PrimuseKit
@testable import Primuse

final class AudioCalibrationTests: XCTestCase {
    @MainActor private func withService(_ body: (EqualizerService, UserDefaults, AudioEngine) throws -> Void) throws {
        let suite = "eq-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AudioEngine(volumeDefaults: defaults, outputDefaults: defaults)
        let service = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
        try body(service, defaults, engine)
    }

    @MainActor func testRecommendationAcceptsOnlyCurrentRouteAndRestoresPreviousCurve() throws {
        try withService { service, _, _ in
            service.applyPreset(.jazz)
            let sony = EQOutputDevice(id: "sony", name: "WH-1000XM5", kind: .bluetooth)
            service.outputDeviceDidChange(sony)
            let first = try XCTUnwrap(service.deviceSuggestion)
            XCTAssertTrue(service.currentPreset.id.hasPrefix("autoeq."))
            XCTAssertNil(service.currentDeviceBinding)
            service.outputDeviceDidChange(sony)
            XCTAssertEqual(service.currentPreset.id, first.presetID)
            XCTAssertEqual(service.deviceSuggestion?.id, first.id)
            service.outputDeviceDidChange(EQOutputDevice(id: "builtin", name: "Speaker", kind: .builtInSpeaker))
            service.acceptDeviceSuggestion(first.id)
            XCTAssertEqual(service.currentPreset.id, EQPreset.jazz.id)
            XCTAssertNil(service.library.binding(for: sony.id))
            service.outputDeviceDidChange(sony)
            service.acceptDeviceSuggestion(try XCTUnwrap(service.deviceSuggestion).id)
            XCTAssertEqual(service.currentDeviceBinding?.presetID, service.currentPreset.id)
        }
    }

    @MainActor func testUnknownDACNeverGuessesAndManualChoiceSurvivesRestart() throws {
        try withService { service, defaults, engine in
            let dac = EQOutputDevice(id: "dac", name: "USB Audio", kind: .usb)
            service.outputDeviceDidChange(dac)
            XCTAssertNil(service.deviceSuggestion?.presetID)
            let preset = try service.importCalibration(name: "Living room", text: "Preamp: -7 dB\nFilter: ON LSC Fc 90 Hz Gain 3 dB Q 0.7")
            service.chooseCalibration(preset, for: dac.id)
            XCTAssertNil(service.deviceSuggestion)
            XCTAssertEqual(service.currentDeviceBinding?.presetID, preset.id)
            service.outputDeviceDidChange(EQOutputDevice(id: "builtin", name: "Speaker", kind: .builtInSpeaker))
            XCTAssertEqual(service.currentPreset.id, EQPreset.flat.id)
            service.outputDeviceDidChange(dac)
            let restored = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            restored.outputDeviceDidChange(dac)
            XCTAssertEqual(restored.currentPreset.parametric, preset.parametric)
            restored.deletePreset(id: preset.id)
            XCTAssertEqual(restored.currentPreset.parametric, preset.parametric)
            let afterDelete = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            XCTAssertEqual(afterDelete.currentPreset.parametric, preset.parametric)
        }
    }

    @MainActor func testManualOverrideAndStaleChooserCannotRebindDevice() throws {
        try withService { service, _, _ in
            let sony = EQOutputDevice(id: "sony", name: "WH-1000XM5", kind: .bluetooth)
            service.outputDeviceDidChange(sony)
            let old = try XCTUnwrap(service.deviceSuggestion)
            service.applyPreset(.bass)
            service.acceptDeviceSuggestion(old.id)
            XCTAssertEqual(service.currentPreset.id, "bass")
            XCTAssertNil(service.currentDeviceBinding)
            service.outputDeviceDidChange(EQOutputDevice(id: "dac", name: "DAC", kind: .usb))
            service.chooseCalibration(.flat, for: sony.id)
            XCTAssertNil(service.library.binding(for: "dac"))
            service.applyPreset(.bass)
            let saved = try XCTUnwrap(service.saveCurrentCurve(named: "Bass copy"))
            service.deletePreset(id: saved.id)
            XCTAssertEqual(service.currentPreset.bands, EQPreset.bass.bands)
        }
    }

    @MainActor func testDisablingAutomaticSwitchSuppressesFutureRecommendations() throws {
        try withService { service, defaults, engine in
            let device = EQOutputDevice(id: "sony", name: "WH-1000XM5", kind: .bluetooth)
            service.outputDeviceDidChange(device)
            service.bindCurrentDevice(to: nil)
            XCTAssertNil(service.deviceSuggestion)
            let restored = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            restored.outputDeviceDidChange(device)
            XCTAssertNil(restored.deviceSuggestion)
            XCTAssertNil(restored.currentDeviceBinding)
        }
    }

    @MainActor func testExpandedCatalogKeepsDeviceMenusSmallAndRestoresSelectedProfile() throws {
        try withService { service, defaults, engine in
            XCTAssertEqual(service.bindablePresets.count, EQPreset.builtInPresets.count)
            let profile = try XCTUnwrap(EQCalibrationCatalog.search("HD800S oratory1990").first {
                $0.name == "Sennheiser HD 800 S" && $0.recommended
            })
            let dac = EQOutputDevice(id: "dac", name: "USB Audio", kind: .usb)
            service.outputDeviceDidChange(dac)
            service.chooseCalibration(profile.preset, for: dac.id)
            XCTAssertEqual(service.bindablePresets.count, EQPreset.builtInPresets.count + 1)
            XCTAssertEqual(service.bindablePresets.filter { $0.parametric != nil }.map(\.id), [profile.id])
            let restored = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            restored.outputDeviceDidChange(dac)
            XCTAssertEqual(restored.currentPreset.id, profile.id)
            XCTAssertEqual(restored.currentDeviceBinding?.presetID, profile.id)
        }
    }

    @MainActor func testAudioUnitRendersOfflineWithExpectedPeakAndNoChannelLeak() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let node = ParametricEqualizerUnit.makeNode()
        let unit = try XCTUnwrap(node.auAudioUnit as? ParametricEqualizerUnit)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let config = EQRenderConfiguration(filters: [EQBiquad(filter: PEQFilter(kind: .peak, frequency: 3000, gain: -6, q: 2), sampleRate: 48_000)], preampDB: -3)
        unit.mailbox.publish(config)
        engine.attach(player); engine.attach(node)
        engine.connect(player, to: node, format: format)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
        input.frameLength = 8192
        for i in 0..<8192 {
            input.floatChannelData![0][i] = Float(0.8 * sin(2 * Double.pi * 3000 * Double(i) / 48_000))
            input.floatChannelData![1][i] = 0
        }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        try engine.start()
        defer { player.stop(); engine.stop(); engine.disableManualRenderingMode() }
        player.scheduleBuffer(input)
        player.play()
        var peak: Float = 0
        for block in 0..<24 {
            XCTAssertEqual(try engine.renderOffline(256, to: output), .success)
            if block > 8 {
                for i in 0..<Int(output.frameLength) {
                    peak = max(peak, abs(output.floatChannelData![0][i]))
                    XCTAssertEqual(output.floatChannelData![1][i], 0)
                }
            }
        }
        XCTAssertEqual(peak, Float(0.8 * pow(10, -9.0 / 20)), accuracy: 0.001)
    }
}
