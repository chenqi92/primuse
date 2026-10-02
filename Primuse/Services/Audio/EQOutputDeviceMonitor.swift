import AVFoundation
import Foundation
import PrimuseKit
#if os(macOS)
import CoreAudio
#endif

extension Notification.Name {
    /// Mac 上用户在输出选择器里换了 Primuse 自己的输出设备(或改回跟随系统)。
    static let primuseAudioOutputSelectionDidChange = Notification.Name("primuseAudioOutputSelectionDidChange")
}

/// 盯着当前的音频输出设备,换了就回调;均衡器据此换上绑定的预设。
/// iOS 读音频会话的路由,Mac 读 Primuse 实际在用的 Core Audio 设备
/// (跟随系统时是系统默认输出,钉了设备时是钉的那台)。
@MainActor
final class EQOutputDeviceMonitor {
    private let onChange: @MainActor (EQOutputDevice?) -> Void
    private(set) var currentDevice: EQOutputDevice?

    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    #if os(macOS)
    private let resolveDeviceID: @MainActor () -> AudioDeviceID?
    nonisolated(unsafe) private var hardwareListeners: [(block: AudioObjectPropertyListenerBlock, address: AudioObjectPropertyAddress)] = []
    #endif

    #if os(macOS)
    init(
        resolveDeviceID: @escaping @MainActor () -> AudioDeviceID?,
        onChange: @escaping @MainActor (EQOutputDevice?) -> Void
    ) {
        self.resolveDeviceID = resolveDeviceID
        self.onChange = onChange
        currentDevice = Self.readDevice(resolveDeviceID())
        installObservers()
    }
    #else
    init(onChange: @escaping @MainActor (EQOutputDevice?) -> Void) {
        self.onChange = onChange
        currentDevice = Self.readDevice()
        installObservers()
    }
    #endif

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        #if os(macOS)
        for listener in hardwareListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener.block
            )
        }
        #endif
    }

    /// 重新读一次输出设备;身份没变(只是同一台设备的路由抖动)就不回调。
    func refresh() {
        #if os(macOS)
        let device = Self.readDevice(resolveDeviceID())
        #else
        let device = Self.readDevice()
        #endif
        guard device != currentDevice else { return }
        currentDevice = device
        onChange(device)
    }

    private func installObservers() {
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        #elseif os(macOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: .primuseAudioOutputSelectionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
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
                hardwareListeners.append((block: block, address: address))
            }
        }
        #endif
    }

    #if os(iOS)
    private static func readDevice() -> EQOutputDevice? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        let kind = kind(of: port.portType)
        if kind == .builtInSpeaker {
            return EQOutputDevice(id: EQOutputDevice.builtInID, name: port.portName, kind: kind)
        }
        let uid = port.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = uid.isEmpty ? "\(port.portType.rawValue)|\(port.portName)" : uid
        return EQOutputDevice(id: id, name: port.portName, kind: kind)
    }

    private static func kind(of port: AVAudioSession.Port) -> EQOutputDevice.Kind {
        switch port {
        case .builtInSpeaker, .builtInReceiver: return .builtInSpeaker
        case .headphones, .lineOut: return .headphones
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return .bluetooth
        case .usbAudio: return .usb
        case .airPlay: return .airPlay
        case .carAudio: return .carAudio
        case .HDMI, .displayPort: return .hdmi
        default: return .other
        }
    }
    #elseif os(macOS)
    private static func readDevice(_ deviceID: AudioDeviceID?) -> EQOutputDevice? {
        guard let deviceID, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        let name = readString(deviceID, selector: kAudioObjectPropertyName) ?? ""
        // 设备 UID 跨重启不变;AudioDeviceID 每次插拔都可能换。
        guard let uid = readString(deviceID, selector: kAudioDevicePropertyDeviceUID),
              !uid.isEmpty else { return nil }
        return EQOutputDevice(id: uid, name: name, kind: kind(transport: readTransport(deviceID)))
    }

    private static func kind(transport: UInt32) -> EQOutputDevice.Kind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtInSpeaker
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
        default: return .other
        }
    }

    private static func readString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func readTransport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }
    #else
    private static func readDevice() -> EQOutputDevice? { nil }
    #endif
}
