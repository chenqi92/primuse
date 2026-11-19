import AVFoundation
import XCTest
import PrimuseKit
@testable import Primuse

final class AudioCalibrationTests: XCTestCase {
    @MainActor private func withService(enabled: Bool = true, prompts: Bool = false, _ body: (EqualizerService, UserDefaults, AudioEngine) throws -> Void) throws {
        let suite = "eq-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = AudioEngine(volumeDefaults: defaults, outputDefaults: defaults)
        let service = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
        if prompts { service.promptsOnHeadphoneChange = true }
        if enabled { service.setEnabled(true) }
        try body(service, defaults, engine)
    }

    @MainActor func testPromptDefaultsOffAndBoundPresetsStillFollowHeadphones() throws {
        try withService(enabled: false) { service, _, _ in
            let headphones = EQOutputDevice(id: "phones", name: "Headphones", kind: .headphones)
            let speaker = EQOutputDevice(id: "builtin", name: "Speaker", kind: .builtInSpeaker)
            service.outputDeviceDidChange(headphones)
            service.setEnabled(true)
            XCTAssertFalse(service.promptsOnHeadphoneChange)
            XCTAssertNil(service.deviceSuggestion)
            service.chooseCalibration(.bass, for: headphones.id)
            service.outputDeviceDidChange(speaker)
            XCTAssertNil(service.deviceSuggestion)
            XCTAssertEqual(service.currentPreset.id, EQPreset.flat.id)
            service.outputDeviceDidChange(headphones)
            XCTAssertNil(service.deviceSuggestion)
            XCTAssertEqual(service.currentPreset.id, EQPreset.bass.id)
        }
    }

    @MainActor func testPromptPreferenceSurvivesRelaunchAndFollowsHeadphoneChanges() throws {
        try withService { service, defaults, engine in
            let speaker = EQOutputDevice(id: "builtin", name: "Speaker", kind: .builtInSpeaker)
            let wired = EQOutputDevice(id: "jack", name: "Headphones", kind: .headphones)
            let wireless = EQOutputDevice(id: "sony", name: "WH-1000XM5", kind: .bluetooth)
            service.promptsOnHeadphoneChange = true
            let reopened = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            reopened.outputDeviceDidChange(speaker)
            XCTAssertNil(reopened.deviceSuggestion)
            reopened.outputDeviceDidChange(wired)
            XCTAssertEqual(reopened.deviceSuggestion?.device, wired)
            reopened.outputDeviceDidChange(wireless)
            let matched = try XCTUnwrap(reopened.deviceSuggestion)
            XCTAssertEqual(matched.device, wireless)
            XCTAssertNotNil(matched.presetID)
            reopened.outputDeviceDidChange(nil)
            reopened.outputDeviceDidChange(speaker)
            let unplugged = try XCTUnwrap(reopened.deviceSuggestion)
            XCTAssertEqual(unplugged.device, speaker)
            reopened.outputDeviceDidChange(speaker)
            XCTAssertEqual(reopened.deviceSuggestion?.id, unplugged.id)
            reopened.outputDeviceDidChange(wireless)
            let pending = try XCTUnwrap(reopened.deviceSuggestion)
            reopened.promptsOnHeadphoneChange = false
            XCTAssertNil(reopened.deviceSuggestion)
            reopened.acceptDeviceSuggestion(pending.id)
            XCTAssertNil(reopened.currentDeviceBinding)
            reopened.outputDeviceDidChange(speaker)
            XCTAssertNil(reopened.deviceSuggestion)
            service.reloadAfterOfflineImport()
            XCTAssertFalse(service.promptsOnHeadphoneChange)
        }
    }

    @MainActor func testEQOffSkipsRoutesAndStaleChoicesUntilExplicitlyEnabled() throws {
        try withService(enabled: false, prompts: true) { service, defaults, engine in
            let dac = EQOutputDevice(id: "dac", name: "DTC480", kind: .usb)
            let headphones = EQOutputDevice(id: "sony", name: "WH-1000XM5", kind: .bluetooth)
            XCTAssertFalse(service.isEnabled)
            service.outputDeviceDidChange(dac)
            XCTAssertNil(service.deviceSuggestion)
            service.chooseCalibration(.bass, for: dac.id)
            XCTAssertFalse(service.isEnabled)
            XCTAssertNil(service.currentDeviceBinding)
            service.setEnabled(true)
            let prompt = try XCTUnwrap(service.deviceSuggestion)
            service.chooseCalibration(.jazz, for: dac.id)
            service.setEnabled(false)
            service.acceptDeviceSuggestion(prompt.id)
            service.outputDeviceDidChange(headphones)
            XCTAssertEqual(service.currentOutputDevice, headphones)
            XCTAssertNil(service.deviceSuggestion)
            XCTAssertEqual(service.currentPreset.id, EQPreset.jazz.id)
            let restored = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            restored.outputDeviceDidChange(dac)
            XCTAssertFalse(restored.isEnabled)
            XCTAssertNil(restored.deviceSuggestion)
            restored.setEnabled(true)
            XCTAssertEqual(restored.currentDeviceBinding?.presetID, EQPreset.jazz.id)
            XCTAssertEqual(restored.currentPreset.id, EQPreset.jazz.id)
        }
    }

    @MainActor func testDecliningARecommendationRestoresManualEQAndPersistsByDevice() throws {
        try withService(prompts: true) { service, defaults, engine in
            let sony = EQOutputDevice(id: "sony", name: "WH-1000XM5", kind: .bluetooth)
            let dac = EQOutputDevice(id: "dac", name: "DTC480", kind: .usb)
            service.applyPreset(.jazz)
            service.outputDeviceDidChange(sony)
            let prompt = try XCTUnwrap(service.deviceSuggestion)
            service.declineCalibration(for: sony.id)
            service.acceptDeviceSuggestion(prompt.id)
            XCTAssertTrue(service.isEnabled)
            XCTAssertEqual(service.currentPreset.id, EQPreset.jazz.id)
            XCTAssertNil(service.currentDeviceBinding)
            let restored = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            restored.outputDeviceDidChange(sony)
            XCTAssertNil(restored.deviceSuggestion)
            XCTAssertEqual(restored.currentPreset.id, EQPreset.jazz.id)
            restored.outputDeviceDidChange(dac)
            restored.declineCalibration(for: sony.id)
            XCTAssertEqual(restored.deviceSuggestion?.device.id, dac.id)
            restored.outputDeviceDidChange(sony)
            XCTAssertNil(restored.deviceSuggestion)
            let preset = try XCTUnwrap(EQCalibrationCatalog.automaticPreset(for: sony))
            restored.chooseCalibration(preset, for: sony.id)
            XCTAssertEqual(restored.currentDeviceBinding?.presetID, preset.id)
        }
    }

    @MainActor func testHighFidelitySkipsCalibrationWhilePausedAndAfterRestart() throws {
        try withService(prompts: true) { service, defaults, engine in
            let sony = EQOutputDevice(id: "sony", name: "WH-1000XM5", kind: .bluetooth)
            service.setCalibrationOutputMode(.highFidelity)
            service.outputDeviceDidChange(sony)
            XCTAssertNil(service.deviceSuggestion)
            XCTAssertEqual(service.currentPreset.id, EQPreset.flat.id)
            let restored = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false, outputMode: .highFidelity)
            restored.outputDeviceDidChange(sony)
            XCTAssertNil(restored.deviceSuggestion)
            restored.setCalibrationOutputMode(.effects)
            let prompt = try XCTUnwrap(restored.deviceSuggestion)
            restored.setCalibrationOutputMode(.highFidelity)
            restored.acceptDeviceSuggestion(prompt.id)
            restored.chooseCalibration(.jazz, for: sony.id)
            XCTAssertNil(restored.deviceSuggestion)
            XCTAssertNil(restored.currentDeviceBinding)
        }
    }

    @MainActor func testLegacyDefaultAndNoCalibrationBindingStayQuietAfterUpgrade() throws {
        try withService(enabled: false, prompts: true) { _, defaults, engine in
            let dac = EQOutputDevice(id: "dac", name: "DTC480", kind: .usb)
            var old = EQPresetLibrary()
            old.setBinding(device: dac, presetID: EQPreset.flat.id)
            defaults.set(old.encoded(), forKey: EQPresetLibrary.storageKey)
            defaults.set(true, forKey: "eq.enabled")
            defaults.set(EQPreset.flat.id, forKey: "eq.presetId")
            let upgraded = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            upgraded.outputDeviceDidChange(dac)
            XCTAssertFalse(upgraded.isEnabled)
            XCTAssertNil(upgraded.deviceSuggestion)
            upgraded.setEnabled(true)
            XCTAssertNil(upgraded.deviceSuggestion)
            let reopened = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            reopened.outputDeviceDidChange(dac)
            XCTAssertTrue(reopened.isEnabled)
            XCTAssertEqual(reopened.currentDeviceBinding?.presetID, EQPreset.flat.id)
            XCTAssertNil(reopened.deviceSuggestion)
            defaults.set(old.encoded(), forKey: EQPresetLibrary.storageKey)
            defaults.set(EQPreset.jazz.id, forKey: "eq.presetId")
            let customized = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            XCTAssertTrue(customized.isEnabled)
            XCTAssertEqual(customized.currentPreset.id, EQPreset.jazz.id)
        }
    }

    @MainActor func testRecommendationAcceptsOnlyCurrentRouteAndRestoresPreviousCurve() throws {
        try withService(prompts: true) { service, _, _ in
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
        try withService(prompts: true) { service, _, _ in
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
        try withService(prompts: true) { service, defaults, engine in
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

    @MainActor func testHeadphonePresetsSwitchOnOneDACAndKeepIndependentCurves() throws {
        try withService { service, defaults, engine in
            let dac = EQOutputDevice(id: "dac", name: "DTC480", kind: .usb)
            service.outputDeviceDidChange(dac)
            service.setBand(2, gain: 3)
            let curveToSave = service.currentPreset
            service.setBand(2, gain: -5)
            let manual = try XCTUnwrap(service.saveHeadphoneCurve(curveToSave, named: "Studio headphones"))
            let model = try XCTUnwrap(EQCalibrationCatalog.entry(withID: "autoeq.catalog.1b67e5d54423f50cae480b56"))
            service.addHeadphonePreset(model.id)
            service.addHeadphonePreset(model.id)
            XCTAssertEqual(service.library.headphonePresetIDs, [manual.id, model.id])
            XCTAssertNil(service.currentDeviceBinding)
            XCTAssertEqual(service.currentPreset.id, EQPreset.customID)
            service.selectHeadphonePreset(manual.id)
            XCTAssertEqual(service.bands[2], 3)
            XCTAssertEqual(service.currentDeviceBinding?.presetID, manual.id)
            service.selectHeadphonePreset(model.id)
            XCTAssertEqual(service.currentDeviceBinding?.presetID, model.id)
            XCTAssertEqual(service.currentPreset.parametric, model.preset.parametric)
            let reopened = EqualizerService(audioEngine: engine, defaults: defaults, tracksOutputDevices: false)
            reopened.outputDeviceDidChange(dac)
            XCTAssertEqual(reopened.library.headphonePresetIDs, [manual.id, model.id])
            XCTAssertEqual(reopened.currentPreset.id, model.id)
            reopened.setEnabled(false)
            reopened.selectHeadphonePreset(manual.id)
            XCTAssertEqual(reopened.currentDeviceBinding?.presetID, model.id)
            XCTAssertFalse(reopened.isEnabled)
            reopened.removeHeadphonePreset(model.id)
            XCTAssertEqual(reopened.currentDeviceBinding?.presetID, model.id)
            reopened.deletePreset(id: manual.id)
            XCTAssertEqual(reopened.library.headphonePresetIDs, [])
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
        // crash-pattern: allow avaudioengine-connect 离线渲染图，两端都用上面构造的 48 kHz 双声道标准格式。
        engine.connect(player, to: node, format: format)
        // crash-pattern: allow avaudioengine-connect 同上，离线图里接到主混音，格式一致。
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
        // crash-pattern: allow audio-player-node-play 离线图已连好且 engine.start() 已成功，没有设备路由变化。
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
