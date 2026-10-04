#if os(macOS)
import AppKit
import CoreAudio
import Foundation
import PrimuseKit

/// 「独占输出设备」此刻的结果，给设置页、播放页和输出设备面板显示。
enum ExclusiveOutputStatus: Equatable {
    /// 没开、不在高保真直通，或这一刻没在出声。
    case inactive
    /// Primuse 正独占这台输出设备；bitDepth 是设备此刻的整数物理位深，读不到时为 nil。
    case exclusive(deviceName: String?, bitDepth: Int?)
    /// 别的 App 正独占这台设备，按共享方式输出。
    case heldByOtherApp(name: String?)
    /// AirPlay、蓝牙这类输出或不支持独占的设备，按共享方式输出。
    case unsupported
    /// 系统拒绝了独占请求，按共享方式输出。
    case failed

    /// 没能独占时的原因；没开或正常独占时为 nil。
    var fallbackDescription: String? {
        switch self {
        case .inactive, .exclusive:
            nil
        case .heldByOtherApp(let name?):
            String(format: String(localized: "exclusive_output_held_by_app %@"), name)
        case .heldByOtherApp(nil):
            String(localized: "exclusive_output_held_by_other_app")
        case .unsupported:
            String(localized: "exclusive_output_unsupported")
        case .failed:
            String(localized: "exclusive_output_failed")
        }
    }

    /// 播放页规格行末尾的短标记。
    var nowPlayingLabel: String? {
        switch self {
        case .inactive: nil
        case .exclusive: String(localized: "exclusive_output_active")
        case .heldByOtherApp, .unsupported, .failed: String(localized: "exclusive_output_shared")
        }
    }

    /// 输出设备面板底部那一行。跟随系统输出时系统默认会被挪到别的设备上，
    /// 所以要写出独占的是哪台。
    var pickerDescription: String? {
        switch self {
        case .exclusive(let name?, let bitDepth?):
            String(
                format: String(localized: "exclusive_output_active_device_bit_depth %@ %lld"),
                name, bitDepth
            )
        case .exclusive(let name?, nil):
            String(format: String(localized: "exclusive_output_active_device %@"), name)
        case .exclusive(nil, let bitDepth?):
            String(format: String(localized: "exclusive_output_active_bit_depth %lld"), bitDepth)
        case .exclusive(nil, nil):
            String(localized: "exclusive_output_active_detail")
        case .inactive, .heldByOtherApp, .unsupported, .failed:
            fallbackDescription
        }
    }
}

/// Core Audio 的 hog mode 与输出流物理格式。只在主线程上用。
///
/// 独占跟着出声走：开始出声前拿下，暂停或停止一会儿后放掉，别的 App 在暂停时
/// 照常能用这台设备。改过物理位深的设备记下原来的格式，关掉独占、换设备、
/// 退出时改回去；只有设备还停在我们设的格式上才改回，用户自己在「音频 MIDI
/// 设置」里改过的不动。
@MainActor
final class ExclusiveOutputDeviceController {
    private(set) var heldDeviceID: AudioDeviceID?

    private struct FormatOverride {
        let streamID: AudioStreamID
        let original: AudioStreamBasicDescription
        var applied: AudioStreamBasicDescription
    }

    private var formatOverrides: [AudioDeviceID: FormatOverride] = [:]

    // MARK: - Hog mode

    func claim(deviceID: AudioDeviceID, isSystemManagedWireless: Bool) -> ExclusiveOutputStatus {
        if let held = heldDeviceID, held != deviceID { release() }
        let currentPID = getpid()
        guard let ownerPID = Self.hogModeOwner(deviceID: deviceID) else { return .unsupported }
        let owner = ExclusiveOutputOwner(hogModePID: ownerPID, currentPID: currentPID)
        switch ExclusiveOutputClaimPolicy.decision(
            owner: owner,
            isSettable: Self.hogModeIsSettable(deviceID: deviceID),
            isSystemManagedWireless: isSystemManagedWireless
        ) {
        case .alreadyHeld:
            heldDeviceID = deviceID
            return .exclusive(
                deviceName: Self.deviceName(deviceID: deviceID),
                bitDepth: physicalBitDepth(deviceID: deviceID)
            )
        case .unsupported:
            return .unsupported
        case .heldByOther(let pid):
            return .heldByOtherApp(name: Self.applicationName(pid: pid))
        case .claim:
            // 写入的值被忽略：没人独占时写一次就归本进程。
            var value = currentPID
            var address = Self.hogModeAddress
            let status = AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &value
            )
            let newOwner = Self.hogModeOwner(deviceID: deviceID)
                .map { ExclusiveOutputOwner(hogModePID: $0, currentPID: currentPID) }
            guard status == noErr, newOwner == .thisProcess else {
                plog("⚠️ Exclusive output refused device=\(deviceID) status=\(status) owner=\(String(describing: newOwner))")
                if case .otherProcess(let pid)? = newOwner {
                    return .heldByOtherApp(name: Self.applicationName(pid: pid))
                }
                return .failed
            }
            heldDeviceID = deviceID
            plog("🎧 Exclusive output claimed device=\(deviceID)")
            return .exclusive(
                deviceName: Self.deviceName(deviceID: deviceID),
                bitDepth: physicalBitDepth(deviceID: deviceID)
            )
        }
    }

    func release() {
        guard let deviceID = heldDeviceID else { return }
        heldDeviceID = nil
        guard Self.deviceIsAlive(deviceID),
              let ownerPID = Self.hogModeOwner(deviceID: deviceID) else { return }
        let owner = ExclusiveOutputOwner(hogModePID: ownerPID, currentPID: getpid())
        // 同一个属性写一次是拿、再写一次是放：不是自己占着就绝不能写。
        guard ExclusiveOutputClaimPolicy.shouldWriteToRelease(owner: owner) else { return }
        var value = pid_t(-1)
        var address = Self.hogModeAddress
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<pid_t>.size), &value
        )
        plog("🎧 Exclusive output released device=\(deviceID) status=\(status)")
    }

    // MARK: - Physical bit depth

    /// 把设备的物理格式换成与目标位深最接近的整数格式，采样率与声道数不变。
    /// 返回设备此刻的整数物理位深。
    func matchPhysicalBitDepth(_ targetBitDepth: Int, deviceID: AudioDeviceID) async -> Int? {
        guard let streamID = Self.firstOutputStream(deviceID: deviceID),
              let current = Self.physicalFormat(streamID: streamID) else { return nil }
        let available = Self.availablePhysicalFormats(streamID: streamID)
        let candidates = available.map { ranged in
            PhysicalOutputBitDepthPolicy.Candidate(
                bitsPerChannel: Int(ranged.mFormat.mBitsPerChannel),
                channelCount: Int(ranged.mFormat.mChannelsPerFrame),
                isLinearPCM: ranged.mFormat.mFormatID == kAudioFormatLinearPCM,
                isFloat: ranged.mFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                isMixable: ranged.mFormat.mFormatFlags & kAudioFormatFlagIsNonMixable == 0,
                minimumSampleRate: ranged.mSampleRateRange.mMinimum,
                maximumSampleRate: ranged.mSampleRateRange.mMaximum
            )
        }
        guard let index = PhysicalOutputBitDepthPolicy.select(
            from: candidates,
            sampleRate: current.mSampleRate,
            channelCount: Int(current.mChannelsPerFrame),
            targetBitDepth: targetBitDepth
        ) else {
            return Self.integerBitDepth(current)
        }
        var chosen = available[index].mFormat
        chosen.mSampleRate = current.mSampleRate
        guard !Self.sameLayout(chosen, current, ignoringSampleRate: false),
              Self.physicalFormatIsSettable(streamID: streamID) else {
            return Self.integerBitDepth(current)
        }
        var address = Self.physicalFormatAddress
        let status = AudioObjectSetPropertyData(
            streamID, &address, 0, nil,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &chosen
        )
        guard status == noErr else {
            plog("⚠️ Exclusive output bit depth rejected device=\(deviceID) target=\(targetBitDepth) status=\(status)")
            return Self.integerBitDepth(current)
        }
        if var override = formatOverrides[deviceID], override.streamID == streamID {
            override.applied = chosen
            formatOverrides[deviceID] = override
        } else {
            formatOverrides[deviceID] = FormatOverride(
                streamID: streamID, original: current, applied: chosen
            )
        }
        // 物理格式在 HAL 里异步生效：回读到新值再去配图，最多等半秒。
        for _ in 0..<25 {
            if let now = Self.physicalFormat(streamID: streamID),
               Self.sameLayout(now, chosen, ignoringSampleRate: false) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let settled = Self.physicalFormat(streamID: streamID)
        plog("🎧 Exclusive output bit depth device=\(deviceID) target=\(targetBitDepth) from=\(current.mBitsPerChannel) to=\(settled?.mBitsPerChannel ?? 0)")
        return settled.flatMap(Self.integerBitDepth)
    }

    /// 把改过位深的设备改回原来的格式。设备已经被别人改成别的格式时不动。
    func restorePhysicalFormats() {
        let overrides = formatOverrides
        formatOverrides.removeAll()
        for (deviceID, override) in overrides {
            guard Self.deviceIsAlive(deviceID),
                  let now = Self.physicalFormat(streamID: override.streamID),
                  Self.sameLayout(now, override.applied, ignoringSampleRate: true) else { continue }
            // 采样率保持现状，只把位深这类排法换回去。
            var restored = override.original
            restored.mSampleRate = now.mSampleRate
            let isAvailable = Self.availablePhysicalFormats(streamID: override.streamID).contains { ranged in
                Self.sameLayout(ranged.mFormat, restored, ignoringSampleRate: true)
                    && ((ranged.mSampleRateRange.mMinimum == 0 && ranged.mSampleRateRange.mMaximum == 0)
                        || (restored.mSampleRate >= ranged.mSampleRateRange.mMinimum - 1
                            && restored.mSampleRate <= ranged.mSampleRateRange.mMaximum + 1))
            }
            guard isAvailable else { continue }
            var address = Self.physicalFormatAddress
            let status = AudioObjectSetPropertyData(
                override.streamID, &address, 0, nil,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &restored
            )
            plog("🎧 Exclusive output restored bit depth device=\(deviceID) to=\(restored.mBitsPerChannel) status=\(status)")
        }
    }

    func physicalBitDepth(deviceID: AudioDeviceID) -> Int? {
        guard let streamID = Self.firstOutputStream(deviceID: deviceID),
              let format = Self.physicalFormat(streamID: streamID) else { return nil }
        return Self.integerBitDepth(format)
    }

    // MARK: - Core Audio helpers

    private static var hogModeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var physicalFormatAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func hogModeOwner(deviceID: AudioDeviceID) -> pid_t? {
        var address = hogModeAddress
        var owner = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &owner)
        return status == noErr ? owner : nil
    }

    private static func hogModeIsSettable(deviceID: AudioDeviceID) -> Bool {
        var address = hogModeAddress
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr
            && settable.boolValue
    }

    private static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr
            && alive != 0
    }

    private static func firstOutputStream(deviceID: AudioDeviceID) -> AudioStreamID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioStreamID>.size else { return nil }
        var streams = [AudioStreamID](
            repeating: 0,
            count: Int(dataSize) / MemoryLayout<AudioStreamID>.size
        )
        let status = streams.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bytes.baseAddress!)
        }
        return status == noErr ? streams.first : nil
    }

    private static func physicalFormat(streamID: AudioStreamID) -> AudioStreamBasicDescription? {
        var address = physicalFormatAddress
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    private static func physicalFormatIsSettable(streamID: AudioStreamID) -> Bool {
        var address = physicalFormatAddress
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(streamID, &address, &settable) == noErr
            && settable.boolValue
    }

    private static func availablePhysicalFormats(
        streamID: AudioStreamID
    ) -> [AudioStreamRangedDescription] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioStreamRangedDescription>.size else { return [] }
        var formats = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(),
            count: Int(dataSize) / MemoryLayout<AudioStreamRangedDescription>.size
        )
        let status = formats.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, bytes.baseAddress!)
        }
        return status == noErr ? formats : []
    }

    private static func sameLayout(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription,
        ignoringSampleRate: Bool
    ) -> Bool {
        lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && (ignoringSampleRate || abs(lhs.mSampleRate - rhs.mSampleRate) < 1)
    }

    /// 浮点物理格式(内置扬声器常见)不报位深：32bit 浮点不是用户在意的那个数。
    private static func integerBitDepth(_ format: AudioStreamBasicDescription) -> Int? {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              format.mBitsPerChannel > 0 else { return nil }
        return Int(format.mBitsPerChannel)
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = name?.takeRetainedValue() as String?,
              !value.isEmpty else { return nil }
        return value
    }

    private static func applicationName(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
#endif
