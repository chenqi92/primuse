import Foundation

/// 一台输出设备在均衡器眼里的身份。换输出时靠 `id` 找它绑定的预设,
/// `name` 只用来在设置里认出它(每次连上都会刷新成系统给的最新名字)。
public struct EQOutputDevice: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case builtInSpeaker
        case headphones
        case bluetooth
        case usb
        case airPlay
        case carAudio
        case hdmi
        case other
    }

    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// iPhone 的扬声器与听筒是同一台设备的两个出口,合成一个身份。
    public static let builtInID = "builtin"
}

/// 某台输出设备连上时自动换上的预设。
public struct EQDevicePresetBinding: Codable, Hashable, Sendable, Identifiable {
    public var device: EQOutputDevice
    public var presetID: String

    public var id: String { device.id }

    public init(device: EQOutputDevice, presetID: String) {
        self.device = device
        self.presetID = presetID
    }
}

/// 用户自己存的命名预设、按设备的绑定,以及自动切换要记住的状态,整份存成一个 JSON。
public struct EQPresetLibrary: Codable, Equatable, Sendable {
    public var userPresets: [EQPreset]
    public var bindings: [EQDevicePresetBinding]
    /// 当前曲线是在一台绑定了预设的设备上换上(或选中)的:离开这台设备时要换回 `unboundPresetID`。
    public var currentBelongsToBoundDevice: Bool
    /// 没绑定预设的设备上用的预设:用户在这类设备上最后一次自己选的,
    /// 或者自动切走之前正在用的那个。
    public var unboundPresetID: String?

    public init(
        userPresets: [EQPreset] = [],
        bindings: [EQDevicePresetBinding] = [],
        currentBelongsToBoundDevice: Bool = false,
        unboundPresetID: String? = nil
    ) {
        self.userPresets = userPresets
        self.bindings = bindings
        self.currentBelongsToBoundDevice = currentBelongsToBoundDevice
        self.unboundPresetID = unboundPresetID
    }

    public static let storageKey = "eq.presetLibrary.v1"
    public static let userPresetIDPrefix = "user."
    public static let maximumNameLength = 40
    public static let maximumUserPresets = 50

    public static func decode(_ data: Data?) -> EQPresetLibrary {
        guard let data,
              var library = try? JSONDecoder().decode(EQPresetLibrary.self, from: data) else {
            return EQPresetLibrary()
        }
        library.userPresets = library.userPresets.filter {
            $0.id.hasPrefix(userPresetIDPrefix) && $0.bands.count == PrimuseConstants.eqBandCount
        }
        let ids = Set(library.userPresets.map(\.id))
        library.bindings = library.bindings.filter { isBindable($0.presetID, userPresetIDs: ids) }
        return library
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public func binding(for deviceID: String?) -> EQDevicePresetBinding? {
        guard let deviceID else { return nil }
        return bindings.first { $0.device.id == deviceID }
    }

    public func userPreset(id: String) -> EQPreset? {
        userPresets.first { $0.id == id }
    }

    /// 能绑到设备上的预设:内置的和用户存的。「自定义」会随拖动变,不能绑。
    public static func isBindable(_ presetID: String, userPresetIDs: Set<String>) -> Bool {
        EQPreset.builtInPresets.contains { $0.id == presetID } || userPresetIDs.contains(presetID)
    }

    // MARK: - Names

    /// 去掉首尾空白、把连续空白压成一个,超长截断;空名返回 nil。
    public static func normalizedName(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumNameLength))
    }

    /// 新预设的默认名:`format` 里带一个 %d(如「我的预设 %d」),取第一个没被占用的编号。
    public func suggestedName(format: String) -> String {
        let taken = Set(userPresets.map { $0.name.lowercased() })
        var index = userPresets.count + 1
        while taken.contains(String(format: format, index).lowercased()) {
            index += 1
        }
        return String(format: format, index)
    }

    // MARK: - Editing

    /// 用 `bands` 存一个新的命名预设,返回它;名字为空或数量到上限时返回 nil。
    public mutating func addPreset(named rawName: String, bands: [Float], id: String = UUID().uuidString) -> EQPreset? {
        guard let name = Self.normalizedName(rawName),
              bands.count == PrimuseConstants.eqBandCount,
              userPresets.count < Self.maximumUserPresets else { return nil }
        let preset = EQPreset(id: Self.userPresetIDPrefix + id, name: name, bands: bands, isBuiltIn: false)
        userPresets.append(preset)
        return preset
    }

    @discardableResult
    public mutating func renamePreset(id: String, to rawName: String) -> Bool {
        guard let name = Self.normalizedName(rawName),
              let index = userPresets.firstIndex(where: { $0.id == id }) else { return false }
        userPresets[index].name = name
        return true
    }

    @discardableResult
    public mutating func updatePreset(id: String, bands: [Float]) -> Bool {
        guard bands.count == PrimuseConstants.eqBandCount,
              let index = userPresets.firstIndex(where: { $0.id == id }) else { return false }
        userPresets[index].bands = bands
        return true
    }

    /// 删掉预设,连同绑到它上的设备和对它的记忆。
    public mutating func removePreset(id: String) {
        userPresets.removeAll { $0.id == id }
        bindings.removeAll { $0.presetID == id }
        if unboundPresetID == id { unboundPresetID = nil }
    }

    /// 绑定(或改绑)一台设备;`presetID` 为 nil 时取消绑定。
    public mutating func setBinding(device: EQOutputDevice, presetID: String?) {
        bindings.removeAll { $0.device.id == device.id }
        guard let presetID,
              Self.isBindable(presetID, userPresetIDs: Set(userPresets.map(\.id))) else { return }
        bindings.append(EQDevicePresetBinding(device: device, presetID: presetID))
    }

    /// 已绑定的设备再次连上时,名字跟着系统改(比如用户改了蓝牙耳机的名字)。
    @discardableResult
    public mutating func refreshName(of device: EQOutputDevice) -> Bool {
        guard let index = bindings.firstIndex(where: { $0.device.id == device.id }),
              bindings[index].device != device else { return false }
        bindings[index].device = device
        return true
    }
}

/// 换输出设备时均衡器换不换、换成哪个。
///
/// - 换到绑定了预设的设备:换上那个预设;如果之前用的是「没绑定设备」上的曲线,先记下它。
/// - 换到没绑定的设备:当前曲线是跟着上一台绑定设备来的,就换回记下的那条;
///   是用户在没绑定的设备上自己选的,就不动。
/// - 用户自己选预设或拖动频段:在没绑定的设备上,这就是以后没绑定设备要用的曲线;
///   在绑定的设备上只是临时改一下,离开这台设备照样换回去,绑定本身不变。
public enum EQDevicePresetSwitchPolicy {
    /// 输出换到 `device` 后要换上的预设 id;nil 表示不动。会更新 `library` 里的切换记忆。
    public static func presetIDAfterRouteChange(
        to device: EQOutputDevice?,
        currentPresetID: String,
        library: inout EQPresetLibrary
    ) -> String? {
        guard let device else { return nil }
        if let binding = library.binding(for: device.id) {
            if !library.currentBelongsToBoundDevice {
                library.unboundPresetID = currentPresetID
            }
            library.currentBelongsToBoundDevice = true
            return binding.presetID == currentPresetID ? nil : binding.presetID
        }
        guard library.currentBelongsToBoundDevice else { return nil }
        library.currentBelongsToBoundDevice = false
        let restored = library.unboundPresetID ?? EQPreset.flat.id
        return restored == currentPresetID ? nil : restored
    }

    /// 用户自己选了预设(拖动频段算选了「自定义」)。
    public static func userSelected(
        presetID: String,
        on device: EQOutputDevice?,
        library: inout EQPresetLibrary
    ) {
        if library.binding(for: device?.id) != nil {
            library.currentBelongsToBoundDevice = true
        } else {
            library.currentBelongsToBoundDevice = false
            library.unboundPresetID = presetID
        }
    }

    /// 在设置里给当前设备绑定或改绑预设:立刻换上那个预设,返回它的 id。
    /// 取消绑定时曲线不动,它从此算作没绑定设备上的曲线。
    public static func bindingChanged(
        for device: EQOutputDevice,
        to presetID: String?,
        currentPresetID: String,
        library: inout EQPresetLibrary
    ) -> String? {
        let wasBound = library.currentBelongsToBoundDevice
        library.setBinding(device: device, presetID: presetID)
        guard let binding = library.binding(for: device.id) else {
            library.currentBelongsToBoundDevice = false
            library.unboundPresetID = currentPresetID
            return nil
        }
        if !wasBound {
            library.unboundPresetID = currentPresetID
        }
        library.currentBelongsToBoundDevice = true
        return binding.presetID == currentPresetID ? nil : binding.presetID
    }
}
