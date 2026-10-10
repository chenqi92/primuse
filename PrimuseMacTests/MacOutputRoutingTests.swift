import AVFoundation
import CoreAudio
import XCTest
@testable import Primuse

@MainActor
final class MacOutputRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "mac-output-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func makeEngine() -> AudioEngine {
        AudioEngine(volumeDefaults: defaults, outputDefaults: defaults)
    }

    private func devices() throws -> [AudioOutputDeviceManager.Device] {
        let devices = AudioOutputDeviceManager().devices
        guard !devices.isEmpty else { throw XCTSkip("No Core Audio output is connected") }
        return devices
    }

    func testPrivateAggregateCannotBeSelectedOrRestored() throws {
        let output = try XCTUnwrap(try devices().first)
        let outputUID = try XCTUnwrap(AudioOutputDeviceManager.deviceUID(for: output.id))
        let uid = "primuse-private-output-test-\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Primuse private output test",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceIsPrivateKey: 1
        ]
        var aggregateID = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        XCTAssertEqual(status, noErr)
        guard status == noErr else { return }
        defer { XCTAssertEqual(AudioHardwareDestroyAggregateDevice(aggregateID), noErr) }
        XCTAssertFalse(AudioOutputDeviceManager().devices.contains { $0.id == aggregateID })
        XCTAssertNil(AudioOutputDeviceManager.deviceID(forUID: uid))
        let engine = makeEngine()
        defer { engine.stop() }
        XCTAssertThrowsError(try engine.setOutputDevice(deviceID: aggregateID))
        XCTAssertTrue(engine.followsSystemOutput)
    }

    func testEveryConnectedOutputRestoresBeforePlaybackAndAcrossGraphRebuilds() async throws {
        let initialDefault = AudioOutputDeviceManager().systemDefaultID
        for device in try devices() {
            let previous = try autoreleasepool {
                let engine = makeEngine()
                defer { engine.stop() }
                try engine.setOutputDevice(deviceID: device.id)
                let uid = try XCTUnwrap(AudioOutputDeviceManager.deviceUID(for: device.id))
                XCTAssertEqual(defaults.string(forKey: "primuse_output_device_uid"), uid)
                return RetiringGraph(engine.engineForVisualizer)
            }
            try await waitForGraphRelease(previous)
            try autoreleasepool {
                let restored = makeEngine()
                defer { restored.stop() }
                XCTAssertNil(restored.outputFormat)
                XCTAssertFalse(restored.followsSystemOutput)
                XCTAssertEqual(restored.selectedOutputDeviceID, device.id)
                XCTAssertEqual(restored.effectiveOutputDeviceID, device.id)
                restored.setVolume(0.23)
                for mode in [AudioOutputMode.effects, .highFidelity, .effects] {
                    print("Restore graph: \(device.name), mode=\(mode)")
                    try restored.configure(outputMode: mode)
                    XCTAssertEqual(restored.currentOutputDeviceID, device.id, device.name)
                    restored.markHardwareConfigurationChanged()
                    try restored.configure(outputMode: mode)
                    XCTAssertEqual(restored.currentOutputDeviceID, device.id, device.name)
                    XCTAssertEqual(restored.userVolume, 0.23, accuracy: 0.0001)
                }
            }
        }
        XCTAssertEqual(AudioOutputDeviceManager().systemDefaultID, initialDefault)
    }

    func testSwitchingOutputsDoesNotRebuildOnThePreviousDevice() async throws {
        let outputs = try devices()
        guard outputs.count >= 2 else { throw XCTSkip("Two outputs required for switching") }
        let engine = makeEngine()
        defer { engine.stop() }
        for mode in [AudioOutputMode.effects, .highFidelity] {
            for device in outputs + outputs.reversed() {
                try engine.setOutputDevice(deviceID: device.id)
                try engine.configure(outputMode: mode)
                try Self.startSilence(engine)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(engine.selectedOutputDeviceID, device.id)
                XCTAssertEqual(engine.currentOutputDeviceID, device.id, device.name)
                XCTAssertTrue(engine.isActuallyPlaying, device.name)
                engine.setVolume(0.31, persist: false)
                XCTAssertTrue(engine.applicationGainIsAvailable, device.name)
                XCTAssertEqual(engine.volume, 0.31, accuracy: 0.0001)
                if mode == .effects {
                    XCTAssertEqual(try XCTUnwrap(engine.effectsMainMixer).outputVolume, 0.31, accuracy: 0.0001)
                } else {
                    XCTAssertEqual(try readGain(engine), 0.31, accuracy: 0.0001)
                }
                print("Output switch: \(device.name), mode=\(mode), actual=\(String(describing: engine.currentOutputDeviceID))")
            }
        }
    }

    func testUnavailableDeviceFallsBackWithoutOverwritingSavedUID() throws {
        defaults.set(false, forKey: "primuse_output_follows_system")
        defaults.set("disconnected-\(UUID().uuidString)", forKey: "primuse_output_device_uid")
        let engine = makeEngine()
        defer { engine.stop() }
        let saved = engine.selectedOutputDeviceUID
        XCTAssertFalse(engine.followsSystemOutput)
        XCTAssertNil(engine.selectedOutputDeviceID)
        let system = try XCTUnwrap(AudioOutputDeviceManager().systemDefaultID)
        XCTAssertEqual(engine.effectiveOutputDeviceID, system)
        try engine.configure(outputMode: .effects)
        XCTAssertEqual(engine.currentOutputDeviceID, system)
        XCTAssertEqual(engine.selectedOutputDeviceUID, saved)
        XCTAssertEqual(makeEngine().selectedOutputDeviceUID, saved)
    }

    func testConfigurationRecoverySettlesOnEveryPinnedOutput() async throws {
        let engine = makeEngine()
        defer { engine.stop() }
        let recovery = ConfigurationRecoveryObservation()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak engine] notification in
            let graph = AudioEngineGraphRegistry.shared.token(forNotificationObject: notification.object)
            Task { @MainActor in
                guard let engine, recovery.isActive,
                      engine.ownsConfigurationChange(from: graph) else { return }
                recovery.count += 1
                guard recovery.count <= 4 else { return }
                engine.stopPlayback()
                engine.markHardwareConfigurationChanged()
                do {
                    try engine.configure(outputMode: recovery.mode)
                    try Self.startSilence(engine)
                } catch {
                    XCTFail("Configuration recovery failed: \(error)")
                }
            }
        }
        defer {
            recovery.isActive = false
            NotificationCenter.default.removeObserver(observer)
        }
        for mode in [AudioOutputMode.effects, .highFidelity] {
            recovery.mode = mode
            for device in try devices() {
                recovery.count = 0
                try engine.setOutputDevice(deviceID: device.id)
                try engine.configure(outputMode: mode)
                try Self.startSilence(engine)
                let configuredGraph = try XCTUnwrap(engine.engineForVisualizer)
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange,
                                                object: configuredGraph)
                try await Task.sleep(for: .seconds(2))
                let settledCount = recovery.count
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(recovery.count, settledCount, "Configuration notifications must settle")
                XCTAssertLessThanOrEqual(recovery.count, 4, "Recovery loop on \(device.name), \(mode)")
                XCTAssertTrue(engine.engineForVisualizer === configuredGraph,
                              "An unchanged hardware format should keep the configured graph")
                XCTAssertTrue(engine.isActuallyPlaying, device.name)
                XCTAssertEqual(engine.currentOutputDeviceID, device.id)
                print("Configuration recovery settled: \(device.name), mode=\(mode), notifications=\(recovery.count)")
            }
        }
    }

    @MainActor
    private final class ConfigurationRecoveryObservation {
        var count = 0
        var isActive = true
        var mode = AudioOutputMode.effects
    }

    func testOutputChangeRequestsRecoveryOnTheNewGraphEvenWhenPaused() async throws {
        let outputs = try devices()
        guard outputs.count >= 2 else { throw XCTSkip("Two outputs required for switching") }
        let engine = makeEngine()
        defer { engine.stop() }
        try engine.setOutputDevice(deviceID: outputs[0].id)
        try engine.configure(outputMode: .highFidelity)
        try Self.startSilence(engine)
        let previousGraph = try XCTUnwrap(engine.engineForVisualizer)
        let previousID = ObjectIdentifier(previousGraph)
        let recovery = expectation(forNotification: .AVAudioEngineConfigurationChange,
                                   object: nil) { notification in
            guard let graph = notification.object as? AVAudioEngine else { return false }
            return ObjectIdentifier(graph) != previousID
        }

        try engine.setOutputDevice(deviceID: outputs[1].id)

        XCTAssertFalse(previousGraph.isRunning)
        XCTAssertEqual(engine.currentOutputDeviceID, outputs[1].id)
        XCTAssertEqual(engine.selectedOutputDeviceID, outputs[1].id)
        await fulfillment(of: [recovery], timeout: 2)
        try engine.configure(outputMode: .highFidelity)
        try Self.startSilence(engine)
        XCTAssertTrue(engine.isActuallyPlaying)
        XCTAssertEqual(engine.currentOutputDeviceID, outputs[1].id)

        engine.stopPlayback()
        let pausedGraphID = ObjectIdentifier(try XCTUnwrap(engine.engineForVisualizer))
        let pausedRecovery = expectation(forNotification: .AVAudioEngineConfigurationChange,
                                         object: nil) { notification in
            guard let graph = notification.object as? AVAudioEngine else { return false }
            return ObjectIdentifier(graph) != pausedGraphID
        }
        try engine.setOutputDevice(deviceID: outputs[0].id)
        XCTAssertFalse(engine.isActuallyPlaying)
        XCTAssertEqual(engine.currentOutputDeviceID, outputs[0].id)
        await fulfillment(of: [pausedRecovery], timeout: 2)
    }

    func testDeviceRefreshRestoresPinnedRouteAfterHALFallback() throws {
        let outputs = try devices()
        guard outputs.count >= 2 else { throw XCTSkip("Two outputs required for fallback") }
        let engine = makeEngine()
        defer { engine.stop() }
        try engine.setOutputDevice(deviceID: outputs[0].id)
        try engine.configure(outputMode: .highFidelity)
        let savedUID = engine.selectedOutputDeviceUID
        let unit = try XCTUnwrap(engine.engineForVisualizer?.outputNode.audioUnit)
        var fallbackID = outputs[1].id
        XCTAssertEqual(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &fallbackID, UInt32(MemoryLayout<AudioDeviceID>.size)), noErr)
        XCTAssertEqual(engine.currentOutputDeviceID, fallbackID)

        engine.refreshOutputRouting()
        try engine.configure(outputMode: .highFidelity)

        XCTAssertEqual(engine.currentOutputDeviceID, outputs[0].id)
        XCTAssertEqual(engine.selectedOutputDeviceUID, savedUID)
        XCTAssertEqual(makeEngine().selectedOutputDeviceID, outputs[0].id)
    }

    func testFailedSelectionKeepsTheExistingPreference() throws {
        let device = try XCTUnwrap(try devices().first)
        let engine = makeEngine()
        defer { engine.stop() }
        try engine.setOutputDevice(deviceID: device.id)
        XCTAssertThrowsError(try engine.setOutputDevice(deviceID: AudioDeviceID.max))
        XCTAssertFalse(engine.followsSystemOutput)
        XCTAssertEqual(engine.selectedOutputDeviceID, device.id)
        XCTAssertEqual(makeEngine().selectedOutputDeviceID, device.id)
    }

    func testFollowSystemClearsPinnedSelectionAndSurvivesRestart() async throws {
        let device = try XCTUnwrap(try devices().first)
        let previous = try autoreleasepool {
            let engine = makeEngine()
            defer { engine.stop() }
            try engine.setOutputDevice(deviceID: device.id)
            try engine.followSystemOutput()
            XCTAssertTrue(engine.followsSystemOutput)
            XCTAssertNil(engine.selectedOutputDeviceID)
            XCTAssertNil(defaults.string(forKey: "primuse_output_device_uid"))
            return RetiringGraph(engine.engineForVisualizer)
        }
        try await waitForGraphRelease(previous)
        let restored = makeEngine()
        defer { restored.stop() }
        XCTAssertTrue(restored.followsSystemOutput)
        try restored.configure(outputMode: .highFidelity)
        XCTAssertEqual(restored.currentOutputDeviceID, AudioOutputDeviceManager().systemDefaultID)
    }

    func testLegacyFlagWithoutDeviceDoesNotPretendADeviceWasRestored() {
        defaults.set(false, forKey: "primuse_output_follows_system")
        let engine = makeEngine()
        XCTAssertTrue(engine.followsSystemOutput)
        XCTAssertNil(engine.selectedOutputDeviceID)
    }

    func testExclusiveColdStartFollowingSystemOutput() async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_TEST_EXCLUSIVE_OUTPUT"] == "1" else {
            throw XCTSkip("Exclusive hardware validation is opt-in")
        }
        let manager = AudioOutputDeviceManager()
        let originalDefault = try XCTUnwrap(manager.systemDefaultID)
        let output = try XCTUnwrap(manager.devices.first { $0.id == originalDefault })
        guard !output.isAirPlay, !output.isBluetooth, hogOwner(originalDefault) == -1 else {
            throw XCTSkip("A free wired output is required")
        }
        let engine = makeEngine()
        defer {
            engine.stop()
            engine.releaseExclusiveOutput(restoringFormats: true)
            restoreSystemDefault(originalDefault)
        }
        XCTAssertNil(engine.engineForVisualizer)
        XCTAssertTrue(engine.followsSystemOutput)
        engine.prepareExclusiveOutput(requested: true, graphMode: .highFidelity)
        XCTAssertEqual(hogOwner(originalDefault), getpid())
        if manager.devices.count == 1 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            manager.refresh()
            while manager.systemDefaultID != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                manager.refresh()
            }
            XCTAssertNil(manager.systemDefaultID)
        }
        try engine.configure(outputMode: .highFidelity)
        try Self.startSilence(engine)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(engine.isActuallyPlaying)
        XCTAssertEqual(engine.currentOutputDeviceID, originalDefault)
        XCTAssertGreaterThan(try XCTUnwrap(engine.currentTime), 0)
    }

    func testExclusivePlaybackSwitchRestartAndIdleReleaseOnConnectedOutputs() async throws {
        guard ProcessInfo.processInfo.environment["PRIMUSE_TEST_EXCLUSIVE_OUTPUT"] == "1" else {
            throw XCTSkip("Exclusive hardware validation is opt-in")
        }
        let originalDefault = AudioOutputDeviceManager().systemDefaultID
        defer { restoreSystemDefault(originalDefault) }
        let outputs = try devices().filter { !$0.isAirPlay && !$0.isBluetooth }
        var engine = makeEngine()
        defer {
            engine.stop()
            engine.releaseExclusiveOutput(restoringFormats: true)
        }
        var exclusiveCount = 0
        for device in outputs + outputs.reversed() {
            try engine.setOutputDevice(deviceID: device.id)
            engine.prepareExclusiveOutput(requested: true, graphMode: .highFidelity)
            try engine.configure(outputMode: .highFidelity)
            try Self.startSilence(engine)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(engine.currentOutputDeviceID, device.id, device.name)
            XCTAssertEqual(engine.effectiveOutputDeviceID, device.id, device.name)
            XCTAssertTrue(engine.isActuallyPlaying, device.name)
            if case .exclusive = engine.exclusiveOutputStatus {
                exclusiveCount += 1
                XCTAssertEqual(hogOwner(device.id), getpid())
            }
            for gain: Float in [0.21, 0.68, 0] {
                engine.setVolume(gain)
                XCTAssertTrue(engine.applicationGainIsAvailable, device.name)
                XCTAssertEqual(try readGain(engine), gain, accuracy: 0.0001, device.name)
            }
            engine.stop()
            engine.releaseExclusiveOutput(restoringFormats: true)
            XCTAssertNotEqual(hogOwner(device.id), getpid())

            // A relaunch has no surviving output unit from the old process.
            let previous = RetiringGraph(engine.engineForVisualizer)
            autoreleasepool { engine = makeEngine() }
            try await waitForGraphRelease(previous)
            XCTAssertEqual(engine.selectedOutputDeviceID, device.id)
            print("Exclusive restore: \(device.name)")
            engine.prepareExclusiveOutput(requested: true, graphMode: .highFidelity)
            try engine.configure(outputMode: .highFidelity)
            try Self.startSilence(engine)
            XCTAssertEqual(engine.currentOutputDeviceID, device.id)
            engine.stopPlayback()
            // The release task and test continuation share the main actor with
            // the host app's startup work; wait for completion within a bound.
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while engine.exclusiveOutputStatus != .inactive, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNotEqual(hogOwner(device.id), getpid())
            XCTAssertEqual(engine.exclusiveOutputStatus, .inactive)
        }
        for device in outputs + outputs.reversed() {
            try engine.setOutputDevice(deviceID: device.id)
            engine.prepareExclusiveOutput(requested: true, graphMode: .highFidelity)
            try engine.configure(outputMode: .highFidelity)
            try Self.startSilence(engine)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(engine.isActuallyPlaying, device.name)
            XCTAssertEqual(engine.currentOutputDeviceID, device.id, device.name)
            XCTAssertEqual(engine.selectedOutputDeviceID, device.id)
            print("Exclusive live switch: \(device.name), actual=\(String(describing: engine.currentOutputDeviceID)), owner=\(String(describing: hogOwner(device.id)))")
        }
        engine.stop()
        engine.releaseExclusiveOutput(restoringFormats: true)
        defaults.set(false, forKey: "primuse_output_follows_system")
        defaults.set("disconnected-\(UUID().uuidString)", forKey: "primuse_output_device_uid")
        let previous = RetiringGraph(engine.engineForVisualizer)
        autoreleasepool { engine = makeEngine() }
        try await waitForGraphRelease(previous)
        let fallback = engine
        defer {
            fallback.stop()
            fallback.releaseExclusiveOutput(restoringFormats: true)
        }
        let fallbackDevice = try XCTUnwrap(fallback.effectiveOutputDeviceID)
        let savedUID = fallback.selectedOutputDeviceUID
        fallback.prepareExclusiveOutput(requested: true, graphMode: .highFidelity)
        for _ in 0..<2 {
            fallback.markHardwareConfigurationChanged()
            try fallback.configure(outputMode: .highFidelity)
            XCTAssertEqual(fallback.currentOutputDeviceID, fallbackDevice)
            try Self.startSilence(fallback)
            XCTAssertEqual(fallback.currentOutputDeviceID, fallbackDevice)
            XCTAssertEqual(fallback.selectedOutputDeviceUID, savedUID)
        }
        XCTAssertGreaterThan(exclusiveCount, 0, "At least one real device must accept hog mode")
    }

    private final class RetiringGraph {
        weak var engine: AVAudioEngine?
        init(_ engine: AVAudioEngine?) { self.engine = engine }
    }

    private func waitForGraphRelease(_ previous: RetiringGraph,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        // 配置通知会暂时持有发送者；重启模拟必须等它们处理完、旧输出单元释放。
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while previous.engine != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try XCTUnwrap(previous.engine == nil ? true : nil,
                         "The previous output graph must be released before simulating a relaunch",
                         file: file, line: line)
    }

    private static func startSilence(_ engine: AudioEngine) throws {
        let format = try XCTUnwrap(engine.outputFormat)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                  frameCapacity: AVAudioFrameCount(format.sampleRate * 4)))
        buffer.frameLength = buffer.frameCapacity
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
        }
        engine.scheduleBuffer(buffer)
        XCTAssertTrue(engine.play())
    }

    private func readGain(_ engine: AudioEngine) throws -> Float {
        let unit = try XCTUnwrap(engine.engineForVisualizer?.outputNode.audioUnit)
        var gain: Float = -1
        XCTAssertEqual(AudioUnitGetParameter(unit, 14, kAudioUnitScope_Global, 0, &gain), noErr)
        return gain
    }

    private func hogOwner(_ deviceID: AudioDeviceID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var owner: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &owner) == noErr ? owner : nil
    }

    private func restoreSystemDefault(_ deviceID: AudioDeviceID?) {
        guard var id = deviceID, AudioOutputDeviceManager().systemDefaultID != id else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        XCTAssertEqual(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id), noErr)
    }
}

@MainActor
final class MacMaterialPreferenceTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "mac-material-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testDisabledAutomaticDetectionSurvivesReopeningAndRelaunch() throws {
        try withDefaults { defaults in
            let preferences = MacUIPreferences(defaults: defaults, operatingSystemMajorVersion: 26)
            XCTAssertTrue(preferences.autoDetectMaterial)
            preferences.autoDetectMaterial = false
            for _ in 0..<3 {
                let reopened = MacUIPreferences(defaults: defaults, operatingSystemMajorVersion: 15)
                XCTAssertFalse(reopened.autoDetectMaterial)
                XCTAssertEqual(reopened.appearance, .glass)
            }
        }
    }

    func testAutomaticMaterialUsesTheCurrentOSAtLaunch() throws {
        try withDefaults { defaults in
            let old = MacUIPreferences(defaults: defaults, operatingSystemMajorVersion: 15)
            XCTAssertEqual(old.appearance, .classic)
            old.autoDetectMaterial = true
            let upgraded = MacUIPreferences(defaults: defaults, operatingSystemMajorVersion: 26)
            XCTAssertTrue(upgraded.autoDetectMaterial)
            XCTAssertEqual(upgraded.appearance, .glass)
        }
    }

    func testManualChoiceTurnsOffDetectionAndSurvivesOSUpgrade() throws {
        try withDefaults { defaults in
            let preferences = MacUIPreferences(defaults: defaults, operatingSystemMajorVersion: 26)
            preferences.selectAppearance(.classic)
            let reopened = MacUIPreferences(defaults: defaults, operatingSystemMajorVersion: 27)
            XCTAssertFalse(reopened.autoDetectMaterial)
            XCTAssertEqual(reopened.appearance, .classic)
            reopened.autoDetectMaterial = true
            XCTAssertEqual(reopened.appearance, .glass)
            XCTAssertTrue(MacUIPreferences(defaults: defaults).autoDetectMaterial)
        }
    }

    func testLegacyManualMaterialIsPreserved() throws {
        try withDefaults { defaults in
            defaults.set("classic", forKey: "pm.mac.appearance")
            let preferences = MacUIPreferences(defaults: defaults, operatingSystemMajorVersion: 26)
            XCTAssertFalse(preferences.autoDetectMaterial)
            XCTAssertEqual(preferences.appearance, .classic)
        }
    }
}
