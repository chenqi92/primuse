import AVFoundation
import Foundation
import PrimuseKit

@MainActor
@Observable
final class EqualizerService {
    private let audioEngine: AudioEngine
    private let defaults: UserDefaults

    var currentPreset: EQPreset = .flat
    var isEnabled: Bool = true {
        didSet { updateBypass(); persist() }
    }
    var bands: [Float] = Array(repeating: 0, count: PrimuseConstants.eqBandCount)

    /// 用户手动拖出的曲线,持久化;预设里"自定义"项展示并可一键还原它。
    private(set) var customBands: [Float] = Array(repeating: 0, count: PrimuseConstants.eqBandCount)

    /// 用户存的命名预设、按输出设备的绑定与自动切换的记忆。
    private(set) var library = EQPresetLibrary()
    /// 现在正在输出的设备;读不到(或平台不支持)时为 nil。
    private(set) var currentOutputDevice: EQOutputDevice?

    @ObservationIgnored private var outputMonitor: EQOutputDeviceMonitor?

    init(audioEngine: AudioEngine, defaults: UserDefaults = .standard) {
        self.audioEngine = audioEngine
        self.defaults = defaults
        load()
        startOutputDeviceTracking()
    }

    /// 当前自定义曲线对应的预设,供 UI 卡片展示/应用。
    var customPreset: EQPreset { .custom(bands: customBands) }

    var userPresets: [EQPreset] { library.userPresets }

    /// 能绑到设备上的预设:内置的在前,用户存的在后。
    var bindablePresets: [EQPreset] { EQPreset.builtInPresets + library.userPresets }

    /// 当前设备绑定的预设 id;没绑定为 nil。
    var currentDeviceBinding: EQDevicePresetBinding? {
        library.binding(for: currentOutputDevice?.id)
    }

    /// 设置里要列出的设备:当前设备在前,再是其它绑定过的设备。
    var bindingRows: [EQDevicePresetBinding] {
        library.bindings.filter { $0.device.id != currentOutputDevice?.id }
    }

    func preset(withID id: String) -> EQPreset? {
        if id == EQPreset.customID { return customPreset }
        return EQPreset.builtInPresets.first { $0.id == id } ?? library.userPreset(id: id)
    }

    func applyPreset(_ preset: EQPreset) {
        guard preset.bands.count == PrimuseConstants.eqBandCount else { return }
        EQDevicePresetSwitchPolicy.userSelected(
            presetID: preset.id,
            on: currentOutputDevice,
            library: &library
        )
        setCurve(preset)
    }

    func setBand(_ index: Int, gain: Float) {
        guard index >= 0, index < PrimuseConstants.eqBandCount else { return }
        let clampedGain = clamp(gain)
        bands[index] = clampedGain
        audioEngine.eqNode?.bands[index].gain = clampedGain
        // 手动拖动即进入"自定义",实时记录整条曲线
        if !currentPreset.isCustom {
            EQDevicePresetSwitchPolicy.userSelected(
                presetID: EQPreset.customID,
                on: currentOutputDevice,
                library: &library
            )
        }
        currentPreset = .custom(bands: bands)
        customBands = bands
        persist()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func reset() {
        applyPreset(.flat)
    }

    // MARK: - Named presets

    /// 新预设的默认名,如「我的预设 1」。
    var suggestedPresetName: String {
        library.suggestedName(format: String(localized: "eq_user_preset_default_name_format"))
    }

    var canAddPreset: Bool {
        library.userPresets.count < EQPresetLibrary.maximumUserPresets
    }

    /// 把当前曲线存成一个命名预设并选中它。
    @discardableResult
    func saveCurrentCurve(named name: String) -> EQPreset? {
        guard let preset = library.addPreset(named: name, bands: bands) else { return nil }
        applyPreset(preset)
        return preset
    }

    func renamePreset(id: String, to name: String) {
        guard library.renamePreset(id: id, to: name) else { return }
        if currentPreset.id == id, let renamed = library.userPreset(id: id) {
            currentPreset = renamed
        }
        persist()
    }

    /// 用当前曲线覆盖一个已存的预设,并选中它。
    func overwritePreset(id: String) {
        guard library.updatePreset(id: id, bands: bands),
              let updated = library.userPreset(id: id) else { return }
        applyPreset(updated)
    }

    /// 删掉预设;正在用它时曲线不变,改记成「自定义」。
    func deletePreset(id: String) {
        let wasCurrent = currentPreset.id == id
        library.removePreset(id: id)
        if wasCurrent {
            currentPreset = .custom(bands: bands)
            customBands = bands
        }
        persist()
    }

    // MARK: - Output devices

    /// 给当前设备绑定预设(nil = 不自动切换),并立刻换上。
    func bindCurrentDevice(to presetID: String?) {
        guard let device = currentOutputDevice else { return }
        let next = EQDevicePresetSwitchPolicy.bindingChanged(
            for: device,
            to: presetID,
            currentPresetID: currentPreset.id,
            library: &library
        )
        if let next, let preset = preset(withID: next) {
            setCurve(preset)
        } else {
            persist()
        }
    }

    /// 改绑或解绑一台现在没连着的设备。
    func setBinding(for device: EQOutputDevice, presetID: String?) {
        if device.id == currentOutputDevice?.id {
            bindCurrentDevice(to: presetID)
            return
        }
        library.setBinding(device: device, presetID: presetID)
        persist()
    }

    private func startOutputDeviceTracking() {
        #if os(iOS)
        outputMonitor = EQOutputDeviceMonitor { [weak self] device in
            self?.outputDeviceDidChange(device)
        }
        #elseif os(macOS)
        outputMonitor = EQOutputDeviceMonitor(
            resolveDeviceID: { [weak self] in self?.audioEngine.effectiveOutputDeviceID },
            onChange: { [weak self] device in self?.outputDeviceDidChange(device) }
        )
        #endif
        // 上次退出时连的设备可能已经换了:启动时按现在的设备对一遍。
        outputDeviceDidChange(outputMonitor?.currentDevice)
    }

    private func outputDeviceDidChange(_ device: EQOutputDevice?) {
        currentOutputDevice = device
        guard let device else { return }
        library.refreshName(of: device)
        let next = EQDevicePresetSwitchPolicy.presetIDAfterRouteChange(
            to: device,
            currentPresetID: currentPreset.id,
            library: &library
        )
        if let next, let preset = preset(withID: next) {
            plog("🎚️ EQ preset follows output device kind=\(device.kind.rawValue) preset=\(next)")
            setCurve(preset)
        } else {
            persist()
        }
    }

    // MARK: - Engine

    /// 换上一条曲线;不改自动切换的记忆。
    private func setCurve(_ preset: EQPreset) {
        currentPreset = preset
        bands = preset.bands
        if preset.isCustom { customBands = preset.bands }
        for (index, gain) in bands.enumerated() {
            audioEngine.eqNode?.bands[index].gain = clamp(gain)
        }
        persist()
    }

    /// AudioEngine.setUp() 会把所有频段增益清零,启动后需回填持久化的曲线与开关。
    func applySettings() {
        guard let eqNode = audioEngine.eqNode else { return }
        for (index, gain) in bands.enumerated() where index < eqNode.bands.count {
            eqNode.bands[index].gain = clamp(gain)
            eqNode.bands[index].bypass = !isEnabled
        }
    }

    private func clamp(_ gain: Float) -> Float {
        min(max(gain, PrimuseConstants.eqMinGain), PrimuseConstants.eqMaxGain)
    }

    private func updateBypass() {
        guard let eqNode = audioEngine.eqNode else { return }
        for band in eqNode.bands {
            band.bypass = !isEnabled
        }
    }

    var bandFrequencyLabels: [String] {
        PrimuseConstants.eqBandFrequencies.map { freq in
            if freq >= 1000 {
                return "\(Int(freq / 1000))K"
            }
            return "\(Int(freq))"
        }
    }

    // MARK: - Persistence

    private enum Keys {
        static let enabled = "eq.enabled"
        static let bands = "eq.bands"
        static let customBands = "eq.customBands"
        static let presetId = "eq.presetId"
    }

    private func persist() {
        defaults.set(bands.map(Double.init), forKey: Keys.bands)
        defaults.set(customBands.map(Double.init), forKey: Keys.customBands)
        defaults.set(currentPreset.id, forKey: Keys.presetId)
        defaults.set(isEnabled, forKey: Keys.enabled)
        defaults.set(library.encoded(), forKey: EQPresetLibrary.storageKey)
    }

    private func load() {
        let count = PrimuseConstants.eqBandCount
        library = EQPresetLibrary.decode(defaults.data(forKey: EQPresetLibrary.storageKey))

        if let saved = (defaults.array(forKey: Keys.customBands) as? [Double])?.map(Float.init),
           saved.count == count {
            customBands = saved
        }

        let savedBands = (defaults.array(forKey: Keys.bands) as? [Double])?.map(Float.init)
        let presetId = defaults.string(forKey: Keys.presetId)

        if presetId == EQPreset.customID, let b = savedBands, b.count == count {
            bands = b
            currentPreset = .custom(bands: b)
            customBands = b
        } else if let presetId,
                  let preset = EQPreset.builtInPresets.first(where: { $0.id == presetId })
                    ?? library.userPreset(id: presetId) {
            currentPreset = preset
            bands = preset.bands
        }

        if defaults.object(forKey: Keys.enabled) != nil {
            isEnabled = defaults.bool(forKey: Keys.enabled)
        }
    }
}
