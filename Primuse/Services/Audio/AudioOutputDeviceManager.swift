#if os(macOS)
import Foundation
import CoreAudio
import AudioToolbox
import Observation

/// 枚举 Core Audio 当前可用的输出设备(内置扬声器、蓝牙耳机、HomePod /
/// Apple TV 等 AirPlay 接收器),让 Primuse 把自己的音频输出指到任意一个
/// 而不影响系统默认。靠 `kAudioHardwarePropertyDevices` 列设备,用
/// `kAudioDevicePropertyTransportType` 区分类型(AirPlay / 蓝牙 / 内置)。
@MainActor
@Observable
final class AudioOutputDeviceManager {
    struct Device: Identifiable, Equatable, Hashable {
        let id: AudioDeviceID
        let name: String
        let isAirPlay: Bool
        let isBluetooth: Bool
        let isBuiltIn: Bool

        var symbolName: String {
            if isAirPlay { return "airplayaudio" }
            if isBluetooth { return "headphones" }
            if isBuiltIn { return "hifispeaker" }
            return "speaker.wave.2"
        }
    }

    private(set) var devices: [Device] = []
    /// 系统默认输出设备 ID，作为「跟随系统」选项的回退目标。
    private(set) var systemDefaultID: AudioDeviceID?

    init() {
        refresh()
        installListener()
    }

    /// 重新枚举一遍(用户接入/拔出蓝牙耳机时由 listener 触发)。
    func refresh() {
        devices = enumerateOutputDevices()
        systemDefaultID = readSystemDefaultDeviceID()
    }

    // MARK: - Enumeration

    private func enumerateOutputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }

        return ids.compactMap { id -> Device? in
            // 只保留有 output stream 的设备(过滤 mic / aggregate input)。
            guard hasOutputStreams(deviceID: id) else { return nil }
            let name = readString(id: id, selector: kAudioObjectPropertyName) ?? "Device \(id)"
            let transport = readUInt32(id: id, selector: kAudioDevicePropertyTransportType) ?? 0
            return Device(
                id: id,
                name: name,
                isAirPlay: transport == kAudioDeviceTransportTypeAirPlay,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth ||
                             transport == kAudioDeviceTransportTypeBluetoothLE,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
            )
        }
    }

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private func readSystemDefaultDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr ? id : nil
    }

    // MARK: - Property helpers

    private func readString(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let result = cfStr?.takeRetainedValue() else { return nil }
        return result as String
    }

    private func readUInt32(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    // MARK: - Listener

    /// 设备列表 / 系统默认设备变化时自动 refresh,不用调用方主动轮询。
    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
}
#endif
