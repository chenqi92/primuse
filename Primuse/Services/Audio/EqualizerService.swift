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

    /// 均衡器节点上这一刻的频段增益与开关,过渡期间落后于 `bands` / `isEnabled`。
    @ObservationIgnored private var appliedGains: [Float]?
    @ObservationIgnored private var appliedEnabled = true
    /// 上面的值写在哪个节点上;图重建后换了新节点,频段全是 0。
    @ObservationIgnored private weak var appliedNode: AVAudioUnitEQ?
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var transitionID = 0

    init(audioEngine: AudioEngine, defaults: UserDefaults = .standard) {
        self.audioEngine = audioEngine
        self.defaults = defaults
        load()
        updatePreampDB()
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
        curveDidChange()
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
        let showsCustom = currentPreset.isCustom || customBands.contains { $0 != 0 }
        return EQPreset.builtInPresets + library.userPresets + (showsCustom ? [customPreset] : [])
    }

    /// 从子菜单选一项。「关闭」只关开关,曲线留着,再打开还是它;选预设顺手打开均衡器,
    /// 不然选了听不出变化。
    func selectFromMenu(_ id: String) {
        guard id != Self.menuOffID else {
            setEnabled(false)
            return
        }
        guard let preset = preset(withID: id) else { return }
        if currentPreset.id != id {
            applyPreset(preset)
        }
        if !isEnabled {
            setEnabled(true)
        }
    }

    // MARK: - Engine

    /// 换上一条曲线;不改自动切换的记忆。
    private func setCurve(_ preset: EQPreset) {
        currentPreset = preset
        bands = preset.bands
        if preset.isCustom { customBands = preset.bands }
        curveDidChange()
        persist()
    }

    /// AudioEngine.setUp() 会把所有频段增益清零,启动后需回填持久化的曲线与开关。
    /// 新建的图还没出声,整条直接写;同一个节点上再调就照常走过渡。
    func applySettings() {
        guard let eqNode = audioEngine.eqNode else { return }
        guard eqNode !== appliedNode else {
            curveDidChange()
            return
        }
        cancelTransition()
        updatePreampDB()
        let gains = bands.map { clamp($0) }
        write(gains: gains, enabled: isEnabled, to: eqNode)
        audioEngine.equalizerPreampGain = Self.linearGain(preampDB)
    }

    private func clamp(_ gain: Float) -> Float {
        min(max(gain, PrimuseConstants.eqMinGain), PrimuseConstants.eqMaxGain)
    }

    private func updateBypass() {
        curveDidChange()
    }

    // MARK: Headroom

    /// 关着时响应视为平直。
    private static func response(gains: [Float], enabled: Bool) -> [Float] {
        enabled ? gains : Array(repeating: 0, count: gains.count)
    }

    private static func linearGain(_ decibels: Float) -> Float {
        Float(pow(10, Double(decibels) / 20))
    }

    private var graphSampleRate: Double {
        audioEngine.outputFormat?.sampleRate ?? 48_000
    }

    /// 按整条曲线的最高点压低整体增益,提升的频段不再把响的歌推过满刻度。
    private func updatePreampDB() {
        let preamp = EqualizerHeadroomPolicy.preampDB(
            bandGainsDB: Self.response(gains: bands.map { clamp($0) }, enabled: isEnabled),
            frequencies: PrimuseConstants.eqBandFrequencies,
            bandwidthOctaves: PrimuseConstants.eqDefaultBandwidth,
            sampleRate: graphSampleRate
        )
        if preampDB != preamp { preampDB = preamp }
    }

    /// 关掉时把频段增益平滑降到 0,不用旁通:旁通是硬切,重新接上时滤波器状态对不上,
    /// 全 +12 关了再开会冲到 +28 dBFS。0 dB 的参数型频段本身就是直通。
    private func write(gains: [Float], enabled: Bool, to eqNode: AVAudioUnitEQ) {
        for (index, gain) in gains.enumerated() where index < eqNode.bands.count {
            eqNode.bands[index].gain = enabled ? gain : 0
            eqNode.bands[index].bypass = false
        }
        appliedGains = gains
        appliedEnabled = enabled
        appliedNode = eqNode
    }

    private var curveIsApplied: Bool {
        audioEngine.eqNode === appliedNode
            && appliedGains == bands.map { clamp($0) }
            && appliedEnabled == isEnabled
    }

    /// 曲线或开关变了:界面上的数马上更新,声音按「先压低 → 改频段 → 放回」过渡,
    /// 不然改动中途近满幅的歌会短暂冲过 0 dBFS(见 `EqualizerHeadroomPolicy`)。
    /// 正在过渡时由它接着处理新的曲线,拖滑块时不会来回抬压。
    private func curveDidChange() {
        updatePreampDB()
        guard audioEngine.eqNode != nil, transitionTask == nil, !curveIsApplied else { return }
        transitionID &+= 1
        let id = transitionID
        transitionTask = Task { [weak self] in
            await self?.runTransition(id: id)
        }
    }

    private func cancelTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        transitionID &+= 1
    }

    private func runTransition(id: Int) async {
        defer { if transitionID == id { transitionTask = nil } }
        // 这一轮过渡中出现过的曲线的上包络;整体增益按它压住,直到曲线停下来。
        var ceiling: [Float]?
        var quietSince = ContinuousClock.now
        while !Task.isCancelled, let eqNode = audioEngine.eqNode {
            if eqNode !== appliedNode {
                // 没经过 applySettings 的新图:频段全是 0、没有旁通、整体增益是 1。
                appliedGains = Array(repeating: 0, count: bands.count)
                appliedEnabled = true
                appliedNode = eqNode
                ceiling = nil
            }
            let gains = bands.map { clamp($0) }
            let enabled = isEnabled
            if gains != appliedGains || enabled != appliedEnabled {
                let applied = Self.response(gains: appliedGains ?? gains, enabled: appliedEnabled)
                let next = EqualizerHeadroomPolicy.ceiling(
                    ceiling ?? applied,
                    Self.response(gains: gains, enabled: enabled)
                )
                ceiling = next
                let hold = Self.linearGain(EqualizerHeadroomPolicy.transitionPreampDB(
                    ceilingBandGainsDB: next,
                    frequencies: PrimuseConstants.eqBandFrequencies,
                    bandwidthOctaves: PrimuseConstants.eqDefaultBandwidth,
                    sampleRate: graphSampleRate
                ))
                if audioEngine.equalizerPreampGain > hold + 1e-6 {
                    audioEngine.equalizerPreampGain = hold
                    let delay = EqualizerHeadroomPolicy.lowerSettleDelay(
                        ioBufferDuration: audioEngine.outputIOBufferDuration
                    )
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, audioEngine.eqNode === eqNode else { return }
                }
                // 写的是压低前取的那条曲线,它一定在上包络里;等待期间又改的下一轮再处理。
                write(gains: gains, enabled: enabled, to: eqNode)
                quietSince = .now
            } else if ceiling == nil {
                return
            } else if quietSince.duration(to: .now) >= .seconds(EqualizerHeadroomPolicy.releaseDelay) {
                audioEngine.equalizerPreampGain = Self.linearGain(preampDB)
                return
            }
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, audioEngine.eqNode === eqNode else { return }
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
