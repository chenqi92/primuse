import AVFoundation
import Foundation
import PrimuseKit

@MainActor
@Observable
final class EqualizerService {
    private let audioEngine: AudioEngine
    private let defaults: UserDefaults
    @ObservationIgnored private var suppressPersist = false

    var currentPreset: EQPreset = .flat
    var isEnabled = false {
        didSet {
            guard !suppressPersist else { return }
            if oldValue != isEnabled { reconcileCalibration() }
            updateBypass()
            persist()
        }
    }
    private var outputMode: AudioOutputMode
    var calibrationAvailable: Bool { isEnabled && outputMode == .effects }
    var bands: [Float] = Array(repeating: 0, count: PrimuseConstants.eqBandCount)

    /// 有频段提升时整体压低的量(dB,≤ 0),关着时为 0。
    private(set) var preampDB: Float = 0

    /// 均衡器页要说明「整体调低了多少 dB」时的正数;压得太少不值一提时为 nil。
    var headroomLoweredDB: Float? {
        preampDB <= -0.1 ? -preampDB : nil
    }

    /// 用户手动拖出的曲线,持久化;预设里"自定义"项展示并可一键还原它。
    private(set) var customBands: [Float] = Array(repeating: 0, count: PrimuseConstants.eqBandCount)

    /// 用户存的命名预设、按输出设备的绑定与自动切换的记忆。
    private(set) var library = EQPresetLibrary()
    /// 现在正在输出的设备;读不到(或平台不支持)时为 nil。
    private(set) var currentOutputDevice: EQOutputDevice?

    @ObservationIgnored private var outputMonitor: EQOutputDeviceMonitor?

    @ObservationIgnored private weak var appliedNode: AVAudioUnitEffect?
    @ObservationIgnored private var appliedConfiguration: EQRenderConfiguration?
    private(set) var unsupportedSampleRate = false

    struct DeviceSuggestion: Identifiable, Equatable {
        let id = UUID()
        let device: EQOutputDevice
        let presetID: String?
    }
    private(set) var deviceSuggestion: DeviceSuggestion?

    init(audioEngine: AudioEngine, defaults: UserDefaults = .standard, tracksOutputDevices: Bool = true,
         outputMode: AudioOutputMode = .effects) {
        self.audioEngine = audioEngine
        self.defaults = defaults
        self.outputMode = outputMode
        load()
        updatePreampDB()
        if tracksOutputDevices { startOutputDeviceTracking() }
    }

    /// 当前自定义曲线对应的预设,供 UI 卡片展示/应用。
    var customPreset: EQPreset {
        EQPreset(id: EQPreset.customID, name: "Custom", bands: customBands, parametric: library.customParametric)
    }

    var userPresets: [EQPreset] { library.userPresets }

    /// 快捷菜单只列手动预设和已使用的校准;完整型号库通过搜索选择。
    var bindablePresets: [EQPreset] {
        var ids = Set(library.bindings.map(\.presetID).filter { $0.hasPrefix("autoeq.") })
        if currentPreset.id.hasPrefix("autoeq.") { ids.insert(currentPreset.id) }
        let calibrations = ids.compactMap { EQCalibrationCatalog.entry(withID: $0)?.preset }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return EQPreset.builtInPresets + calibrations + library.userPresets
    }

    /// 当前设备绑定的预设 id;没绑定为 nil。
    var currentDeviceBinding: EQDevicePresetBinding? {
        library.binding(for: currentOutputDevice?.id)
    }

    var currentDeviceDisplayPresetID: String? {
        deviceSuggestion?.presetID ?? currentDeviceBinding?.presetID
    }

    /// 设置里要列出的设备:当前设备在前,再是其它绑定过的设备。
    var bindingRows: [EQDevicePresetBinding] {
        library.bindings.filter { $0.device.id != currentOutputDevice?.id }
    }

    func preset(withID id: String) -> EQPreset? {
        if id == EQPreset.customID { return customPreset }
        if id == currentPreset.id { return currentPreset }
        return EQPreset.builtInPreset(withID: id) ?? library.userPreset(id: id)
    }

    func applyPreset(_ preset: EQPreset) {
        guard preset.isValid else { return }
        deviceSuggestion = nil
        EQDevicePresetSwitchPolicy.userSelected(
            presetID: preset.id,
            on: currentOutputDevice,
            library: &library
        )
        setCurve(preset)
    }

    func setBand(_ index: Int, gain: Float) {
        guard index >= 0, index < PrimuseConstants.eqBandCount else { return }
        deviceSuggestion = nil
        let clampedGain = clamp(gain)
        bands[index] = clampedGain
        library.customParametric = nil
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
        curveDidChange()
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

    private func storeCurve(_ curve: EQPreset, named name: String) -> EQPreset? {
        if let peq = curve.parametric { return library.addPreset(named: name, parametric: peq) }
        return library.addPreset(named: name, bands: curve.bands)
    }

    /// 把当前曲线存成一个命名预设并选中它。
    @discardableResult
    func saveCurrentCurve(named name: String) -> EQPreset? {
        guard let preset = storeCurve(currentPreset, named: name) else { return nil }
        applyPreset(preset)
        return preset
    }

    func saveHeadphoneCurve(_ curve: EQPreset, named name: String) -> EQPreset? {
        guard let preset = storeCurve(curve, named: name) else { return nil }
        addHeadphonePreset(preset.id)
        return preset
    }

    func addHeadphonePreset(_ id: String) {
        library.addHeadphonePreset(id: id)
        persist()
    }

    func removeHeadphonePreset(_ id: String) {
        library.removeHeadphonePreset(id: id)
        persist()
    }

    func selectHeadphonePreset(_ id: String) {
        guard calibrationAvailable, library.headphonePresetIDs?.contains(id) == true,
              let preset = preset(withID: id) else { return }
        chooseCalibration(preset, for: currentOutputDevice?.id)
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
        guard library.updatePreset(id: id, curve: currentPreset),
              let updated = library.userPreset(id: id) else { return }
        applyPreset(updated)
    }

    /// 删掉预设;正在用它时曲线不变,改记成「自定义」。
    func deletePreset(id: String) {
        let wasCurrent = currentPreset.id == id
        if deviceSuggestion?.presetID == id { deviceSuggestion = nil }
        library.removePreset(id: id)
        if wasCurrent {
            library.customParametric = currentPreset.parametric
            customBands = bands
            currentPreset = customPreset
        }
        persist()
    }

    // MARK: - Output devices

    /// 给当前设备绑定预设(nil = 不自动切换),并立刻换上。
    func bindCurrentDevice(to presetID: String?) {
        guard let device = currentOutputDevice else { return }
        deviceSuggestion = nil
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

    func outputDeviceDidChange(_ device: EQOutputDevice?) {
        let changed = device?.id != currentOutputDevice?.id
        currentOutputDevice = device
        if let device, library.refreshName(of: device) { persist() }
        if changed { reconcileCalibration() }
    }

    func setCalibrationOutputMode(_ mode: AudioOutputMode) {
        guard mode != outputMode else { return }
        outputMode = mode
        reconcileCalibration()
    }

    private func reconcileCalibration() {
        deviceSuggestion = nil
        guard calibrationAvailable, let device = currentOutputDevice else { return }
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
        guard device.kind != .builtInSpeaker,
              library.automaticSwitchDisabledDeviceIDs?.contains(device.id) != true else { return }
        let binding = library.binding(for: device.id)
        // The old “no calibration” action saved a flat binding. Keep its sound without prompting.
        guard binding?.presetID != EQPreset.flat.id else { return }
        let suggested = binding.flatMap { preset(withID: $0.presetID) }
            ?? EQCalibrationCatalog.automaticPreset(for: device)
        if let suggested {
            // An unconfirmed recommendation is transient; route-away still restores the previous curve.
            if !library.currentBelongsToBoundDevice {
                library.unboundPresetID = currentPreset.id
                library.currentBelongsToBoundDevice = true
            }
            setCurve(suggested)
        } else if currentPreset.parametric != nil {
            setCurve(.flat)
        }
        deviceSuggestion = DeviceSuggestion(device: device, presetID: suggested?.id)
        plog("EQ calibration prompt kind=\(device.kind.rawValue) matched=\(suggested != nil)")
    }

    func acceptDeviceSuggestion(_ id: UUID) {
        guard calibrationAvailable, let suggestion = deviceSuggestion, suggestion.id == id,
              currentOutputDevice?.id == suggestion.device.id else { return }
        if let presetID = suggestion.presetID { bindCurrentDevice(to: presetID) }
        deviceSuggestion = nil
    }

    func chooseCalibration(_ preset: EQPreset, for deviceID: String?) {
        guard calibrationAvailable, preset.isValid, deviceID == currentOutputDevice?.id else { return }
        if deviceID != nil { bindCurrentDevice(to: preset.id) }
        else { applyPreset(preset) }
    }

    func declineCalibration(for deviceID: String?) {
        guard calibrationAvailable, deviceID == currentOutputDevice?.id else { return }
        var manualPreset = currentPreset
        if manualPreset.parametric != nil {
            manualPreset = .flat
            if library.currentBelongsToBoundDevice, let id = library.unboundPresetID,
               let previous = preset(withID: id), previous.parametric == nil {
                manualPreset = previous
            }
        }
        if let device = currentOutputDevice { library.setBinding(device: device, presetID: nil) }
        applyPreset(manualPreset)
    }

    @discardableResult
    func importCalibration(name: String, text: String) throws -> EQPreset {
        let peq = try EqualizerAPOParser.parse(text)
        guard let preset = library.addPreset(named: name, parametric: peq) else {
            throw CalibrationLibraryError.cannotSave
        }
        persist()
        return preset
    }

    enum CalibrationLibraryError: Error { case cannotSave }

    // MARK: - Player menu

    /// 播放器「更多」里均衡器子菜单的「关闭」项。预设 id 是内置名、`user.` 前缀或
    /// `custom`,撞不上它。
    static let menuOffID = "off"

    /// 子菜单勾着的那一项:关着是「关闭」,开着是正在用的预设。
    var menuSelectionID: String {
        isEnabled ? currentPreset.id : Self.menuOffID
    }

    /// 菜单行上显示的当前值。
    var menuSelectionTitle: String {
        isEnabled ? currentPreset.localizedName : String(localized: "eq_menu_off")
    }

    /// 子菜单里的预设,与均衡器页的卡片同序:内置、自己存的、自定义。自定义曲线没拖过
    /// (全平,和「平坦」是同一条线)又没在用时不列。
    var menuPresets: [EQPreset] {
        let showsCustom = currentPreset.isCustom || library.customParametric != nil || customBands.contains { $0 != 0 }
        let calibration = currentPreset.id.hasPrefix("autoeq.") ? [currentPreset] : []
        return EQPreset.builtInPresets + calibration + library.userPresets + (showsCustom ? [customPreset] : [])
    }

    /// 从子菜单选一项。「关闭」只关开关,曲线留着,再打开还是它;选预设顺手打开均衡器,
    /// 不然选了听不出变化。
    func selectFromMenu(_ id: String) {
        guard id != Self.menuOffID else {
            setEnabled(false)
            return
        }
        guard let preset = preset(withID: id) else { return }
        let wasDisabled = !isEnabled
        if wasDisabled { setEnabled(true) }
        if currentPreset.id != id || wasDisabled {
            applyPreset(preset)
        }
    }

    // MARK: - Engine

    /// 换上一条曲线;不改自动切换的记忆。
    private func setCurve(_ preset: EQPreset) {
        currentPreset = preset
        bands = preset.parametric == nil ? preset.bands : Array(repeating: 0, count: PrimuseConstants.eqBandCount)
        if preset.isCustom { customBands = bands; library.customParametric = preset.parametric }
        curveDidChange()
        persist()
    }

    func applySettings() {
        updatePreampDB()
        guard let node = audioEngine.eqNode,
              let unit = node.auAudioUnit as? ParametricEqualizerUnit else { return }
        let configuration = renderConfiguration ?? .flat
        guard node !== appliedNode || appliedConfiguration != configuration else { return }
        unit.mailbox.publish(configuration)
        appliedNode = node
        appliedConfiguration = configuration
    }

    private func clamp(_ gain: Float) -> Float {
        gain.isFinite ? min(max(gain, PrimuseConstants.eqMinGain), PrimuseConstants.eqMaxGain) : 0
    }

    private func updateBypass() { curveDidChange() }

    private var graphSampleRate: Double { audioEngine.outputFormat?.sampleRate ?? 48_000 }

    @ObservationIgnored private var renderConfiguration: EQRenderConfiguration?
    @ObservationIgnored private var compiledPreset: EQPreset?
    @ObservationIgnored private var compiledRate: Double = 0
    @ObservationIgnored private var compiledEnabled = false

    private func updatePreampDB() {
        guard compiledPreset != currentPreset || compiledRate != graphSampleRate || compiledEnabled != isEnabled else { return }
        compiledPreset = currentPreset
        compiledRate = graphSampleRate
        compiledEnabled = isEnabled
        renderConfiguration = EQRenderConfiguration.make(preset: currentPreset, sampleRate: graphSampleRate, enabled: isEnabled)
        unsupportedSampleRate = renderConfiguration == nil
        preampDB = Float(renderConfiguration?.preampDB ?? 0)
    }

    private func curveDidChange() { applySettings() }

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
        guard !suppressPersist else { return }
        defaults.set(bands.map(Double.init), forKey: Keys.bands)
        defaults.set(customBands.map(Double.init), forKey: Keys.customBands)
        defaults.set(currentPreset.id, forKey: Keys.presetId)
        defaults.set(isEnabled, forKey: Keys.enabled)
        defaults.set(library.encoded(), forKey: EQPresetLibrary.storageKey)
    }

    func reloadAfterOfflineImport() {
        deviceSuggestion = nil
        currentPreset = .flat
        bands = Array(repeating: 0, count: PrimuseConstants.eqBandCount)
        customBands = bands
        load()
        reconcileCalibration()
        applySettings()
    }

    private func load() {
        suppressPersist = true
        defer { suppressPersist = false }
        let count = PrimuseConstants.eqBandCount
        library = EQPresetLibrary.decode(defaults.data(forKey: EQPresetLibrary.storageKey))

        if let saved = (defaults.array(forKey: Keys.customBands) as? [Double])?.map(Float.init),
           saved.count == count {
            customBands = saved
        }

        let savedBands = (defaults.array(forKey: Keys.bands) as? [Double])?.map(Float.init)
        let presetId = defaults.string(forKey: Keys.presetId)

        if presetId == EQPreset.customID, library.customParametric != nil {
            currentPreset = customPreset
            bands = Array(repeating: 0, count: count)
        } else if presetId == EQPreset.customID, let b = savedBands, b.count == count {
            bands = b
            currentPreset = .custom(bands: b)
            customBands = b
        } else if let presetId,
                  let preset = EQPreset.builtInPreset(withID: presetId)
                    ?? library.userPreset(id: presetId) {
            currentPreset = preset
            bands = preset.parametric == nil ? preset.bands : Array(repeating: 0, count: count)
        }

        let legacyDefault = library.hasMigratedEnabledPreference != true && presetId == EQPreset.flat.id
            && library.userPresets.isEmpty && library.customParametric == nil && !customBands.contains { $0 != 0 }
            && !library.bindings.contains { $0.presetID != EQPreset.flat.id }
            && (library.unboundPresetID == nil || library.unboundPresetID == EQPreset.flat.id)
        isEnabled = defaults.bool(forKey: Keys.enabled) && !legacyDefault
        library.hasMigratedEnabledPreference = true
    }
}
