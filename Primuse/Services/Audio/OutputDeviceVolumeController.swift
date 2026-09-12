#if os(macOS)
import CoreAudio
import Foundation
import PrimuseKit

/// 输出设备硬件音量的读、写与监听。
///
/// 高保真直通模式刻意不在音频数据上施加任何增益 —— 那正是这个模式存在的理由。
/// 但「不能改数据」不等于「不能调音量」：把音量交给输出设备的硬件音量，
/// 既保住了 bit-perfect，用户又能在应用里调节，这也是应用一直在提示的
/// 「请使用系统音量调节」真正应该被兑现的方式。
///
/// 任何一步失败都只是让 `isControllable` 变成 `false`，界面退回原来的
/// 「禁用 + 说明」状态 —— 最坏情况与改动前一致，不会更糟。
@MainActor
@Observable
final class OutputDeviceVolumeController {
    /// 音量条散布在底栏、迷你播放器、菜单栏和沉浸式播放页，
    /// 它们观察的必须是同一份设备状态，否则监听会重复注册。
    static let shared = OutputDeviceVolumeController()

    /// 当前设备的硬件音量。`nil` 表示还没读到，或这台设备不提供。
    private(set) var volume: Float?
    /// 这台设备是否允许写入硬件音量。部分 USB DAC 只有物理旋钮，就是 `false`。
    private(set) var isControllable = false

    /// 播放图正在使用的设备。用户在应用里选了特定输出设备时由播放层告知，
    /// 未告知则跟随系统默认设备。
    var preferredDeviceID: AudioDeviceID? {
        didSet {
            guard preferredDeviceID != oldValue else { return }
            rebind()
        }
    }

    private var boundDeviceID: AudioDeviceID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var isStarted = false

    // MARK: - 生命周期

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeDefaultDeviceChanges()
        rebind()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        unbindDevice()
        removeDefaultDeviceObserver()
        volume = nil
        isControllable = false
    }

    deinit {
        // 监听块持有 self，必须在释放前摘掉，否则 CoreAudio 会回调到已释放对象。
        MainActor.assumeIsolated {
            unbindDevice()
            removeDefaultDeviceObserver()
        }
    }

    // MARK: - 读写

    /// 写入硬件音量。超出范围的值会被夹紧；设备不可写时是空操作。
    func setVolume(_ value: Float) {
        guard isControllable, value.isFinite, let deviceID = boundDeviceID else { return }
        let clamped = min(1, max(0, value))
        guard let channels = writableVolumeElements(deviceID: deviceID) else { return }

        var wroteAny = false
        for element in channels {
            var scalar = Float32(clamped)
            var address = Self.volumeAddress(element: element)
            let status = AudioObjectSetPropertyData(
                deviceID, &address, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &scalar
            )
            if status == noErr { wroteAny = true }
        }
        // 硬件音量常有量化台阶(某些 DAC 只有 16 级)，写完立刻回读，
        // 让界面显示设备真正接受的值而不是我们请求的值。
        if wroteAny { refresh() }
    }

    /// 重新读取当前设备的音量与可控性。
    func refresh() {
        guard let deviceID = boundDeviceID else {
            volume = nil
            isControllable = false
            return
        }
        let elements = writableVolumeElements(deviceID: deviceID)
        isControllable = elements?.isEmpty == false
        volume = Self.readVolume(deviceID: deviceID)
    }

    // MARK: - 设备绑定

    private func rebind() {
        unbindDevice()
        let deviceID = preferredDeviceID ?? Self.systemDefaultOutputDeviceID()
        boundDeviceID = deviceID
        guard let deviceID else {
            volume = nil
            isControllable = false
            return
        }
        observeVolumeChanges(deviceID: deviceID)
        refresh()
    }

    private func unbindDevice() {
        if let deviceID = boundDeviceID, let listener = volumeListener {
            for element in Self.candidateElements {
                var address = Self.volumeAddress(element: element)
                AudioObjectRemovePropertyListenerBlock(
                    deviceID, &address, DispatchQueue.main, listener
                )
            }
        }
        volumeListener = nil
        boundDeviceID = nil
    }

    /// 设备的硬件音量可能被系统音量键、菜单栏或别的应用改动，
    /// 不监听的话应用里的滑块会和真实音量脱节。
    private func observeVolumeChanges(deviceID: AudioDeviceID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        volumeListener = listener
        for element in Self.candidateElements {
            var address = Self.volumeAddress(element: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            AudioObjectAddPropertyListenerBlock(
                deviceID, &address, DispatchQueue.main, listener
            )
        }
    }

    private func observeDefaultDeviceChanges() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.preferredDeviceID == nil else { return }
                self.rebind()
            }
        }
        defaultDeviceListener = listener
        var address = Self.defaultOutputDeviceAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
    }

    private func removeDefaultDeviceObserver() {
        guard let listener = defaultDeviceListener else { return }
        var address = Self.defaultOutputDeviceAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        defaultDeviceListener = nil
    }

    // MARK: - CoreAudio 细节

    /// 先试主元素(0)，它代表整设备音量；设备只暴露分声道音量时退回前若干声道。
    private static let candidateElements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain, 1, 2,
    ]

    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volumeAddress(
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    /// 可写的音量元素。主元素可写就只用它，否则收集可写的分声道。
    private func writableVolumeElements(
        deviceID: AudioDeviceID
    ) -> [AudioObjectPropertyElement]? {
        var mainAddress = Self.volumeAddress(element: kAudioObjectPropertyElementMain)
        if Self.isSettable(deviceID: deviceID, address: &mainAddress) {
            return [kAudioObjectPropertyElementMain]
        }
        let channels = Self.candidateElements
            .filter { $0 != kAudioObjectPropertyElementMain }
            .filter { element in
                var address = Self.volumeAddress(element: element)
                return Self.isSettable(deviceID: deviceID, address: &address)
            }
        return channels.isEmpty ? nil : channels
    }

    private static func isSettable(
        deviceID: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) -> Bool {
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        return status == noErr && settable.boolValue
    }

    /// 读音量。分声道设备取各声道最大值 —— 那才是听感上的响度上限。
    private static func readVolume(deviceID: AudioDeviceID) -> Float? {
        var values: [Float] = []
        for element in candidateElements {
            var address = volumeAddress(element: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var scalar = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, &scalar
            )
            guard status == noErr, scalar.isFinite else { continue }
            if element == kAudioObjectPropertyElementMain {
                return min(1, max(0, Float(scalar)))
            }
            values.append(Float(scalar))
        }
        guard let loudest = values.max() else { return nil }
        return min(1, max(0, loudest))
    }

    private static func systemDefaultOutputDeviceID() -> AudioDeviceID? {
        var address = defaultOutputDeviceAddress
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr && id != AudioDeviceID(kAudioObjectUnknown) ? id : nil
    }
}
#endif
