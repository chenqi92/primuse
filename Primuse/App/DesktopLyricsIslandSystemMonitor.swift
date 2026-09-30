#if os(macOS)
import AppKit
import CoreAudio
import AudioToolbox
import IOKit.ps
import PrimuseKit

/// 盯着系统的输出设备、音量和电源，变化时交给歌词岛临时显示一下。
///
/// 只读不写：换设备、调音量都是用户在系统里做的，这里只负责把结果亮出来。
/// 监听的是系统默认输出设备 —— 插上 AirPods、插耳机线、切到外接音箱都会改它；
/// Primuse 自己在 App 里另选的输出设备不在这里管。
@MainActor
final class DesktopLyricsIslandSystemMonitor {
    typealias Handler = (DesktopLyricsIslandActivity) -> Void

    private typealias Listener = (
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        block: AudioObjectPropertyListenerBlock
    )

    /// 内建输出的数据源 'hdpn' = 耳机孔插着耳机（Intel 机型走这条，Apple 芯片会
    /// 另起一台 External Headphones 设备）。
    private static let headphoneDataSource: UInt32 = 0x6864_706E

    private var handler: Handler?
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var outputDeviceID: AudioDeviceID = 0
    private var lastOutputChange = Date.distantPast
    private var lastVolume: (level: Float, muted: Bool)?
    private var powerSource: CFRunLoopSource?
    private var lastOnAC: Bool?

    var isRunning: Bool { handler != nil }

    func start(_ handler: @escaping Handler) {
        guard self.handler == nil else {
            self.handler = handler
            return
        }
        self.handler = handler
        outputDeviceID = Self.defaultOutputDevice()
        bindDeviceListeners(to: outputDeviceID)
        lastVolume = Self.volume(of: outputDeviceID)
        addListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            into: &systemListeners
        ) { monitor in
            monitor.defaultOutputDidChange()
        }
        startPowerMonitoring()
    }

    func stop() {
        handler = nil
        removeListeners(&systemListeners)
        removeListeners(&deviceListeners)
        outputDeviceID = 0
        lastVolume = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        lastOnAC = nil
    }

    // MARK: - Output device

    private func defaultOutputDidChange() {
        let id = Self.defaultOutputDevice()
        guard id != 0, id != outputDeviceID else { return }
        outputDeviceID = id
        bindDeviceListeners(to: id)
        lastOutputChange = Date()
        lastVolume = Self.volume(of: id)
        handler?(outputActivity(for: id))
    }

    /// 同一台内建设备在扬声器和耳机孔之间切换时，默认设备不变，只有数据源变。
    private func dataSourceDidChange() {
        guard outputDeviceID != 0 else { return }
        lastOutputChange = Date()
        lastVolume = Self.volume(of: outputDeviceID)
        handler?(outputActivity(for: outputDeviceID))
    }

    private func outputActivity(for id: AudioDeviceID) -> DesktopLyricsIslandActivity {
        let name = Self.string(id, kAudioObjectPropertyName) ?? ""
        let transport = Self.uint32(id, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        let dataSource = Self.uint32(id, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        return DesktopLyricsIslandActivity(
            kind: .output,
            symbol: DesktopLyricsIslandActivityPolicy.outputSymbol(
                kind: Self.outputKind(transport),
                name: name,
                isHeadphoneJack: dataSource == Self.headphoneDataSource
            ),
            caption: String(localized: "desktop_lyrics_island_output"),
            title: name,
            level: nil,
            trailing: nil,
            tint: .neutral
        )
    }

    private static func outputKind(_ transport: UInt32) -> DesktopLyricsIslandOutputKind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        default: return .other
        }
    }

    // MARK: - Volume

    private func volumeDidChange() {
        guard let current = Self.volume(of: outputDeviceID) else { return }
        let previous = lastVolume
        lastVolume = current
        // 刚换设备时新设备的音量会跟着报一次，那不是用户在调。
        guard Date().timeIntervalSince(lastOutputChange)
                >= DesktopLyricsIslandActivityPolicy.volumeQuietAfterOutputChange else { return }
        if let previous,
           previous.muted == current.muted,
           abs(previous.level - current.level) < 0.005 { return }
        let level = Double(current.level)
        let captionKey: String.LocalizationValue = current.muted ? "desktop_lyrics_island_muted" : "desktop_lyrics_island_volume"
        handler?(DesktopLyricsIslandActivity(
            kind: .volume,
            symbol: DesktopLyricsIslandActivityPolicy.volumeSymbol(level: level, muted: current.muted),
            caption: String(localized: captionKey),
            title: "",
            level: current.muted ? 0 : level,
            trailing: current.muted ? nil : level.formatted(.percent.precision(.fractionLength(0))),
            tint: .neutral
        ))
    }

    /// 读不到主音量的设备（部分 HDMI / USB 设备没有软件音量）返回 nil，这时
    /// 调音量本来也没有反应，岛上就什么都不显示。
    private static func volume(of id: AudioDeviceID) -> (level: Float, muted: Bool)? {
        guard id != 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &level) == noErr else { return nil }
        let muted = (uint32(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) ?? 0) != 0
        return (min(max(level, 0), 1), muted)
    }

    // MARK: - Listeners

    private func bindDeviceListeners(to id: AudioDeviceID) {
        removeListeners(&deviceListeners)
        guard id != 0 else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            addListener(object: id, selector: selector, scope: kAudioDevicePropertyScopeOutput, into: &deviceListeners) { monitor in
                monitor.volumeDidChange()
            }
        }
        addListener(object: id, selector: kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, into: &deviceListeners) { monitor in
            monitor.dataSourceDidChange()
        }
    }

    private func addListener(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        into listeners: inout [Listener],
        action: @escaping @MainActor (DesktopLyricsIslandSystemMonitor) -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return }
        // 回调挂在主队列上，所以可以直接当 MainActor 用。
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.handler != nil else { return }
                action(self)
            }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return }
        listeners.append((object, address, block))
    }

    private func removeListeners(_ listeners: inout [Listener]) {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
        }
        listeners.removeAll()
    }

    // MARK: - Power

    private func startPowerMonitoring() {
        guard powerSource == nil else { return }
        lastOnAC = Self.powerState()?.onAC
        // 台式机没有内置电池，读不到就不挂监听。
        guard lastOnAC != nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<DesktopLyricsIslandSystemMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.powerDidChange() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    /// 电源信息每隔一阵就会刷新一次电量，只有接上 / 拔掉电源才值得上岛。
    private func powerDidChange() {
        guard handler != nil, let power = Self.powerState() else { return }
        let previous = lastOnAC
        lastOnAC = power.onAC
        guard let previous, previous != power.onAC else { return }
        let caption: String
        let tint: DesktopLyricsIslandActivity.Tint
        if power.onAC {
            let key: String.LocalizationValue = power.charging ? "desktop_lyrics_island_charging" : "desktop_lyrics_island_power_connected"
            caption = String(localized: key)
            tint = .charging
        } else {
            caption = String(localized: "desktop_lyrics_island_on_battery")
            tint = power.level <= DesktopLyricsIslandActivityPolicy.lowBatteryLevel ? .warning : .neutral
        }
        handler?(DesktopLyricsIslandActivity(
            kind: .power,
            symbol: DesktopLyricsIslandActivityPolicy.batterySymbol(level: power.level, charging: power.onAC),
            caption: caption,
            title: power.level.formatted(.percent.precision(.fractionLength(0))),
            level: nil,
            trailing: nil,
            tint: tint
        ))
    }

    private static func powerState() -> (onAC: Bool, level: Double, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let level = min(max(Double(current) / Double(maximum), 0), 1)
            return (providing == kIOPSACPowerValue, level, charging)
        }
        return nil
    }

    // MARK: - Core Audio helpers

    private static func defaultOutputDevice() -> AudioDeviceID {
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
        return status == noErr ? id : 0
    }

    private static func uint32(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
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
        guard status == noErr, let result = value?.takeRetainedValue() else { return nil }
        return result as String
    }
}
#endif
