import Foundation
import Observation
import PrimuseKit

/// 播放页背景的设置。来源、轮播方式与间隔走 `CloudKVSSync`（同一个 Apple ID 的
/// iPhone、Mac、Apple TV 跟着变）；自选图片的列表只在本机，图片本身也不同步。
@MainActor
@Observable
final class PlayerBackdropSettingsStore {
    static let shared = PlayerBackdropSettingsStore()

    private(set) var settings: PlayerBackdropSettings
    /// 本机自选图片，按添加顺序。只记文件确实还在的。
    private(set) var customImageIDs: [String]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let syncsWithCloud: Bool

    init(defaults: UserDefaults = .standard, registersWithCloud: Bool = true) {
        self.defaults = defaults
        syncsWithCloud = registersWithCloud
        settings = PlayerBackdropSettings.decode(defaults.data(forKey: PlayerBackdropSettings.storageKey))
        customImageIDs = Self.loadCustomImageIDs(from: defaults)
        guard registersWithCloud else { return }
        CloudKVSSync.shared.register(key: PlayerBackdropSettings.storageKey) { [weak self] in
            self?.reloadSyncedSettings()
        }
        #if DEBUG
        applyDebugLaunchOverrides()
        #endif
    }

    var hasCustomImages: Bool { !customImageIDs.isEmpty }

    /// 实际生效的来源（选了「我的图片」而本机没有图片时是封面取色）。
    var effectiveSource: PlayerBackdropSource {
        settings.effectiveSource(hasCustomImages: hasCustomImages)
    }

    func update(_ change: (inout PlayerBackdropSettings) -> Void) {
        var next = settings
        change(&next)
        next.intervalSeconds = PlayerBackdropSettings.normalizedInterval(next.intervalSeconds)
        guard next != settings else { return }
        settings = next
        defaults.set(next.encodedData(), forKey: PlayerBackdropSettings.storageKey)
        if syncsWithCloud {
            CloudKVSSync.shared.markChanged(key: PlayerBackdropSettings.storageKey)
        }
    }

    func appendCustomImages(_ ids: [String]) {
        setCustomImageIDs(customImageIDs + ids)
    }

    /// 移出列表的图片同时删掉文件（图片只为播放背景存在）。
    func removeCustomImage(_ id: String) {
        guard customImageIDs.contains(id) else { return }
        setCustomImageIDs(customImageIDs.filter { $0 != id })
        PlayerBackdropImageStore.remove(id: id)
    }

    func moveCustomImages(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = customImageIDs
        let moving = source.sorted().map { ids[$0] }
        for index in source.sorted(by: >) { ids.remove(at: index) }
        let insertion = destination - source.filter { $0 < destination }.count
        ids.insert(contentsOf: moving, at: min(max(insertion, 0), ids.count))
        setCustomImageIDs(ids)
    }

    /// 整份替换本机列表（Apple TV 收到扫码直传的图片时用）。不在新列表里的旧图片删掉。
    func replaceCustomImages(with ids: [String]) {
        let next = PlayerBackdropSettings.sanitizedCustomImageIDs(ids)
            .filter(PlayerBackdropImageStore.exists(id:))
        let removed = Set(customImageIDs).subtracting(next)
        setCustomImageIDs(next)
        for id in removed { PlayerBackdropImageStore.remove(id: id) }
    }

    /// 图片文件被清掉（换机恢复、手动清理）时把列表跟着收拢。
    func pruneMissingCustomImages() {
        let present = customImageIDs.filter(PlayerBackdropImageStore.exists(id:))
        if present != customImageIDs { setCustomImageIDs(present) }
    }

    private func setCustomImageIDs(_ ids: [String]) {
        let next = PlayerBackdropSettings.sanitizedCustomImageIDs(ids)
        guard next != customImageIDs else { return }
        customImageIDs = next
        defaults.set(next, forKey: PlayerBackdropSettings.customImagesStorageKey)
    }

    private func reloadSyncedSettings() {
        let next = PlayerBackdropSettings.decode(defaults.data(forKey: PlayerBackdropSettings.storageKey))
        if next != settings { settings = next }
    }

    #if DEBUG
    /// 编译机无人值守截图：`PRIMUSE_DEBUG_BACKDROP=<来源>[:perSong|:timed:<秒>]`（来源取
    /// `PlayerBackdropSource` 的原始值），`PRIMUSE_DEBUG_BACKDROP_IMAGES=<目录>` 把目录里的
    /// 图片导入成本机自选图片（相对路径按 Documents 算）。
    private func applyDebugLaunchOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["PRIMUSE_DEBUG_BACKDROP"], !raw.isEmpty {
            let parts = raw.split(separator: ":").map(String.init)
            if let source = PlayerBackdropSource(rawValue: parts[0]) {
                update {
                    $0.source = source
                    if parts.count > 1, let rotation = PlayerBackdropRotation(rawValue: parts[1]) {
                        $0.rotation = rotation
                    }
                    if parts.count > 2, let seconds = Int(parts[2]) { $0.intervalSeconds = seconds }
                }
                plog("🧪 Player backdrop debug override \(raw)")
            }
        }
        guard let rawDirectory = env["PRIMUSE_DEBUG_BACKDROP_IMAGES"], !rawDirectory.isEmpty else { return }
        let directory = rawDirectory.hasPrefix("/")
            ? URL(fileURLWithPath: rawDirectory, isDirectory: true)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(rawDirectory, isDirectory: true)
        Task { [weak self] in
            let ids = await Task.detached(priority: .utility) { () -> [String] in
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                )) ?? []
                return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return PlayerBackdropImageStore.importImage(data, maxPixel: 2_880)
                }
            }.value
            self?.replaceCustomImages(with: ids)
            plog("🧪 Player backdrop debug images imported=\(ids.count)")
        }
    }
    #endif

    private static func loadCustomImageIDs(from defaults: UserDefaults) -> [String] {
        let stored = defaults.stringArray(forKey: PlayerBackdropSettings.customImagesStorageKey) ?? []
        return PlayerBackdropSettings.sanitizedCustomImageIDs(stored)
            .filter(PlayerBackdropImageStore.exists(id:))
    }
}
