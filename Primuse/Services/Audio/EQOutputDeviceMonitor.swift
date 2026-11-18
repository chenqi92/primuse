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
    nonisolated(unsafe) private var hardwareListeners: [(objectID: AudioObjectID, block: AudioObjectPropertyListenerBlock, address: AudioObjectPropertyAddress)] = []
    private var observedDeviceID: AudioDeviceID?
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
                listener.objectID,
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
        let deviceID = resolveDeviceID()
        observeDevice(deviceID)
        let device = Self.readDevice(deviceID)
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
            queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
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
                hardwareListeners.append((objectID: AudioObjectID(kAudioObjectSystemObject), block: block, address: address))
            }
        }
        observeDevice(resolveDeviceID())
        #endif
    }

    #if os(iOS)
    private static func readDevice() -> EQOutputDevice? {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["PRIMUSE_EQ_TEST_USB_OUTPUT"] {
            return EQOutputDevice(id: "test.usb." + name, name: name, kind: .usb)
        }
        #endif
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
        var kind = kind(transport: readTransport(deviceID))
        if kind == .builtInSpeaker, hasHeadphoneOutput(deviceID) { kind = .headphones }
        // Some Macs share a device UID between the internal speakers and the analog jack.
        return EQOutputDevice(id: kind == .headphones ? uid + "|headphones" : uid, name: name, kind: kind)
    }

    private func observeDevice(_ deviceID: AudioDeviceID?) {
        guard deviceID != observedDeviceID else { return }
        for listener in hardwareListeners where listener.objectID != AudioObjectID(kAudioObjectSystemObject) {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, .main, listener.block)
        }
        hardwareListeners.removeAll { $0.objectID != AudioObjectID(kAudioObjectSystemObject) }
        observedDeviceID = deviceID
        guard let deviceID, deviceID != kAudioObjectUnknown else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        for selector in [kAudioDevicePropertyJackIsConnected, kAudioDevicePropertyDataSource, kAudioDevicePropertyStreams] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            if AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block) == noErr {
                hardwareListeners.append((objectID: deviceID, block: block, address: address))
            }
        }
    }

    private static func hasHeadphoneOutput(_ deviceID: AudioDeviceID) -> Bool {
        if readUInt32(deviceID, selector: kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeOutput) == 1 {
            return true
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        let status = streams.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr && streams.contains {
            readUInt32($0, selector: kAudioStreamPropertyTerminalType) == kAudioStreamTerminalTypeHeadphones
        }
    }

    private static func readUInt32(_ id: AudioObjectID, selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
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
