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
        let nominalSampleRate: Double?

        var symbolName: String {
            if isAirPlay { return "airplayaudio" }
            if isBluetooth { return "headphones" }
            if isBuiltIn { return "hifispeaker" }
            return "speaker.wave.2"
        }

        var typeLabel: String {
            if isAirPlay { return "AirPlay" }
            if isBluetooth { return "Bluetooth" }
            if isBuiltIn { return String(localized: "audio_output_type_builtin") }
            return "Core Audio"
        }

        var sampleRateText: String? {
            guard let nominalSampleRate, nominalSampleRate > 0 else { return nil }
            let khz = nominalSampleRate / 1_000
            if khz.rounded() == khz {
                return "\(Int(khz)) kHz"
            }
            return String(format: "%.1f kHz", khz)
        }

        var subtitle: String {
            [typeLabel, sampleRateText].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private(set) var devices: [Device] = []
    /// 系统默认输出设备 ID，作为「跟随系统」选项的回退目标。
    private(set) var systemDefaultID: AudioDeviceID?
    @ObservationIgnored var onDevicesChanged: (() -> Void)?

    /// 已注册的监听 (block + address)，deinit 时逐个注销，避免随视图反复创建而泄漏。
    /// 仅在 @MainActor 的 init/installListener 写入、deinit 读取一次，无并发访问。
    /// 监听句柄不是 UI 状态，不应让 Observation 宏生成隔离的 backing storage；
    /// 显式忽略后，nonisolated(unsafe) 只用于允许 deinit 注销这些系统监听。
    @ObservationIgnored
    nonisolated(unsafe) private var registeredListeners: [(block: AudioObjectPropertyListenerBlock, address: AudioObjectPropertyAddress)] = []

    init() {
        refresh()
        installListener()
    }

    deinit {
        for listener in registeredListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener.block
            )
        }
    }

    /// 重新枚举一遍(用户接入/拔出蓝牙耳机时由 listener 触发)。
    func refresh() {
        devices = enumerateOutputDevices()
        systemDefaultID = readSystemDefaultDeviceID()
    }

    // MARK: - Enumeration

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        readString(id: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &id
            )
        }
        guard status == noErr, id != kAudioObjectUnknown,
              isSelectableOutput(deviceID: id) else { return nil }
        return id
    }

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
            guard Self.isSelectableOutput(deviceID: id) else { return nil }
            let name = Self.readString(id: id, selector: kAudioObjectPropertyName)
                ?? String(
                    format: String(localized: "audio_output_device_fallback %@"),
                    String(id)
                )
            let transport = Self.readUInt32(id: id, selector: kAudioDevicePropertyTransportType) ?? 0
            let nominalSampleRate = readDouble(id: id, selector: kAudioDevicePropertyNominalSampleRate)
            return Device(
                id: id,
                name: name,
                isAirPlay: transport == kAudioDeviceTransportTypeAirPlay,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth ||
                             transport == kAudioDeviceTransportTypeBluetoothLE,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                nominalSampleRate: nominalSampleRate
            )
        }
    }

    private static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    private static func isSelectableOutput(deviceID: AudioDeviceID) -> Bool {
        guard hasOutputStreams(deviceID: deviceID),
              (readUInt32(id: deviceID, selector: kAudioDevicePropertyIsHidden) ?? 0) == 0 else { return false }
        guard readUInt32(id: deviceID, selector: kAudioDevicePropertyTransportType)
                == kAudioDeviceTransportTypeAggregate else { return true }

        // AVAudioEngine 的默认路由也会出现在本进程的设备列表中，但它的私有
        // 聚合设备随音频图销毁，不能作为用户的持久输出选择。
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var composition: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let status = withUnsafeMutablePointer(to: &composition) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let result = composition?.takeRetainedValue() else { return false }
        let values = result as NSDictionary
        return (values[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue != true
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
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    // MARK: - Property helpers

    private static func readString(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
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

    private static func readUInt32(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
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

    private func readDouble(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    // MARK: - Listener

    /// 设备列表 / 系统默认设备变化时自动 refresh,不用调用方主动轮询。
    private func installListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.onDevicesChanged?()
            }
        }

        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
            if status == noErr {
                registeredListeners.append((block: block, address: address))
            }
        }
    }
}
#endif
