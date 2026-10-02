import Foundation
import Testing
@testable import PrimuseKit

struct EQPresetLibraryTests {
    private let speaker = EQOutputDevice(id: EQOutputDevice.builtInID, name: "iPhone", kind: .builtInSpeaker)
    private let buds = EQOutputDevice(id: "AA:BB-tacl", name: "Buds", kind: .bluetooth)
    private let dac = EQOutputDevice(id: "usb:dac", name: "DAC", kind: .usb)
    private let curve: [Float] = [1, 2, 3, 4, 5, 4, 3, 2, 1, 0]

    @Test func namesAreTrimmedCollapsedAndCapped() {
        #expect(EQPresetLibrary.normalizedName("  My \n  Buds  ") == "My Buds")
        #expect(EQPresetLibrary.normalizedName("   ") == nil)
        let long = String(repeating: "很", count: 60)
        #expect(EQPresetLibrary.normalizedName(long)?.count == EQPresetLibrary.maximumNameLength)
    }

    @Test func suggestedNameSkipsTakenNumbers() {
        var library = EQPresetLibrary()
        #expect(library.suggestedName(format: "Preset %d") == "Preset 1")
        _ = library.addPreset(named: "Preset 2", bands: curve, id: "a")
        #expect(library.suggestedName(format: "Preset %d") == "Preset 3")
        _ = library.addPreset(named: "preset 3", bands: curve, id: "b")
        #expect(library.suggestedName(format: "Preset %d") == "Preset 4")
    }

    @Test func addRenameUpdateAndRemove() {
        var library = EQPresetLibrary()
        let added = library.addPreset(named: " Car ", bands: curve, id: "x")
        #expect(added?.id == "user.x")
        #expect(added?.name == "Car")
        #expect(library.addPreset(named: "", bands: curve) == nil)
        #expect(library.addPreset(named: "Bad", bands: [1, 2]) == nil)

        let renamed = library.renamePreset(id: "user.x", to: "Truck")
        let blankRename = library.renamePreset(id: "user.x", to: "  ")
        #expect(renamed)
        #expect(!blankRename)
        #expect(library.userPreset(id: "user.x")?.name == "Truck")

        let flat = Array(repeating: Float(0), count: 10)
        let updated = library.updatePreset(id: "user.x", bands: flat)
        #expect(updated)
        #expect(library.userPreset(id: "user.x")?.bands == flat)

        library.setBinding(device: buds, presetID: "user.x")
        library.unboundPresetID = "user.x"
        library.removePreset(id: "user.x")
        #expect(library.userPresets.isEmpty)
        #expect(library.bindings.isEmpty)
        #expect(library.unboundPresetID == nil)
    }

    @Test func customAndUnknownPresetsCannotBeBound() {
        var library = EQPresetLibrary()
        library.setBinding(device: buds, presetID: EQPreset.customID)
        library.setBinding(device: dac, presetID: "user.missing")
        #expect(library.bindings.isEmpty)
        library.setBinding(device: buds, presetID: "bass")
        library.setBinding(device: buds, presetID: "rock")
        #expect(library.bindings.count == 1)
        #expect(library.binding(for: buds.id)?.presetID == "rock")
        library.setBinding(device: buds, presetID: nil)
        #expect(library.bindings.isEmpty)
    }

    @Test func roundTripDropsBrokenEntries() throws {
        var library = EQPresetLibrary()
        _ = library.addPreset(named: "Mine", bands: curve, id: "m")
        library.setBinding(device: dac, presetID: "user.m")
        library.setBinding(device: buds, presetID: "jazz")
        library.currentBelongsToBoundDevice = true
        library.unboundPresetID = "vocal"
        let decoded = EQPresetLibrary.decode(library.encoded())
        #expect(decoded == library)

        var broken = library
        broken.userPresets.append(EQPreset(id: "no-prefix", name: "X", bands: curve))
        broken.userPresets.append(EQPreset(id: "user.short", name: "Y", bands: [1]))
        broken.bindings.append(EQDevicePresetBinding(device: speaker, presetID: "user.short"))
        let cleaned = EQPresetLibrary.decode(broken.encoded())
        #expect(cleaned.userPresets.map(\.id) == ["user.m"])
        #expect(cleaned.bindings.map(\.presetID) == ["user.m", "jazz"])
        #expect(EQPresetLibrary.decode(nil) == EQPresetLibrary())
        #expect(EQPresetLibrary.decode(Data("garbage".utf8)) == EQPresetLibrary())
    }

    @Test func boundDeviceSwitchesAndLeavingRestoresThePreviousCurve() {
        var library = EQPresetLibrary()
        library.setBinding(device: buds, presetID: "bass")

        // 一开始在扬声器上,用户用的是「人声」。
        EQDevicePresetSwitchPolicy.userSelected(presetID: "vocal", on: speaker, library: &library)
        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: speaker, currentPresetID: "vocal", library: &library) == nil)

        let onBuds = EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: buds, currentPresetID: "vocal", library: &library)
        #expect(onBuds == "bass")
        #expect(library.unboundPresetID == "vocal")
        #expect(library.currentBelongsToBoundDevice)

        let back = EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: speaker, currentPresetID: "bass", library: &library)
        #expect(back == "vocal")
        #expect(!library.currentBelongsToBoundDevice)
    }

    @Test func movingBetweenBoundDevicesKeepsTheUnboundMemory() {
        var library = EQPresetLibrary()
        library.setBinding(device: buds, presetID: "bass")
        library.setBinding(device: dac, presetID: "classical")
        EQDevicePresetSwitchPolicy.userSelected(presetID: "rock", on: speaker, library: &library)

        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: buds, currentPresetID: "rock", library: &library) == "bass")
        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: dac, currentPresetID: "bass", library: &library) == "classical")
        #expect(library.unboundPresetID == "rock")
        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: speaker, currentPresetID: "classical", library: &library) == "rock")
    }

    @Test func manualPickOnABoundDeviceIsTemporary() {
        var library = EQPresetLibrary()
        library.setBinding(device: buds, presetID: "bass")
        EQDevicePresetSwitchPolicy.userSelected(presetID: "flat", on: speaker, library: &library)
        _ = EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: buds, currentPresetID: "flat", library: &library)

        EQDevicePresetSwitchPolicy.userSelected(presetID: EQPreset.customID, on: buds, library: &library)
        #expect(library.binding(for: buds.id)?.presetID == "bass")
        #expect(library.unboundPresetID == "flat")
        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: speaker, currentPresetID: EQPreset.customID, library: &library) == "flat")
        // 再连回去照样是绑定的预设。
        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: buds, currentPresetID: "flat", library: &library) == "bass")
    }

    @Test func unboundDevicesLeaveAManualChoiceAlone() {
        var library = EQPresetLibrary()
        library.setBinding(device: buds, presetID: "bass")
        EQDevicePresetSwitchPolicy.userSelected(presetID: "jazz", on: speaker, library: &library)
        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: dac, currentPresetID: "jazz", library: &library) == nil)
        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: nil, currentPresetID: "jazz", library: &library) == nil)
    }

    @Test func leavingWithoutAMemoryFallsBackToFlat() {
        var library = EQPresetLibrary(currentBelongsToBoundDevice: true)
        #expect(EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: speaker, currentPresetID: "rock", library: &library) == "flat")
    }

    @Test func bindingTheCurrentDeviceAppliesAtOnceAndUnbindingKeepsTheCurve() {
        var library = EQPresetLibrary()
        EQDevicePresetSwitchPolicy.userSelected(presetID: "vocal", on: dac, library: &library)

        let applied = EQDevicePresetSwitchPolicy.bindingChanged(
            for: dac, to: "classical", currentPresetID: "vocal", library: &library)
        #expect(applied == "classical")
        #expect(library.unboundPresetID == "vocal")
        #expect(library.currentBelongsToBoundDevice)

        let rebound = EQDevicePresetSwitchPolicy.bindingChanged(
            for: dac, to: "rock", currentPresetID: "classical", library: &library)
        #expect(rebound == "rock")
        #expect(library.unboundPresetID == "vocal")

        let unbound = EQDevicePresetSwitchPolicy.bindingChanged(
            for: dac, to: nil, currentPresetID: "rock", library: &library)
        #expect(unbound == nil)
        #expect(!library.currentBelongsToBoundDevice)
        #expect(library.unboundPresetID == "rock")
        #expect(library.bindings.isEmpty)
    }

    @Test func reconnectingRefreshesTheRememberedName() {
        var library = EQPresetLibrary()
        library.setBinding(device: buds, presetID: "bass")
        var renamed = buds
        renamed.name = "Chen's Buds"
        let first = library.refreshName(of: renamed)
        let again = library.refreshName(of: renamed)
        let unbound = library.refreshName(of: dac)
        #expect(first)
        #expect(!again)
        #expect(!unbound)
        #expect(library.binding(for: buds.id)?.device.name == "Chen's Buds")
    }
}
