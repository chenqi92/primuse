import Foundation
import PrimuseKit

/// Scrobble 用户设置 (持久化到 UserDefaults, token 走 Keychain 单独存)。
/// 同时跟 CloudKit KVS 同步, 让多设备共享 enable/provider 选择。
@MainActor
@Observable
final class ScrobbleSettingsStore {
    static let shared = ScrobbleSettingsStore()

    private static let userDefaultsKey = "primuse.scrobble.settings.v1"

    /// 启用 scrobble 整体开关。关闭时所有 provider 不工作, token 不删。
    var isEnabled: Bool {
        didSet { persist(); ScrobbleSettingsStore.notifyChanged() }
    }

    /// 启用了哪些 provider。多选 — 用户可以同时同步到 Last.fm + ListenBrainz。
    var enabledProviders: Set<ScrobbleProviderID> {
        didSet { persist(); ScrobbleSettingsStore.notifyChanged() }
    }

    /// Now Playing (实时显示当前播放) — 不计入 listening history。
    var sendNowPlaying: Bool {
        didSet { persist(); ScrobbleSettingsStore.notifyChanged() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            self.isEnabled = decoded.isEnabled
            self.enabledProviders = Set(decoded.enabledProviders.compactMap(ScrobbleProviderID.init(rawValue:)))
            self.sendNowPlaying = decoded.sendNowPlaying
        } else {
            self.isEnabled = false
            self.enabledProviders = []
            self.sendNowPlaying = true
        }
    }

    private func persist() {
        let p = Persisted(
            isEnabled: isEnabled,
            enabledProviders: enabledProviders.map(\.rawValue),
            sendNowPlaying: sendNowPlaying
        )
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    private static func notifyChanged() {
        NotificationCenter.default.post(name: .scrobbleSettingsChanged, object: nil)
    }

    private struct Persisted: Codable {
        let isEnabled: Bool
        let enabledProviders: [String]
        let sendNowPlaying: Bool
    }
}

extension Notification.Name {
    static let scrobbleSettingsChanged = Notification.Name("primuse.scrobble.settingsChanged")
}

/// Scrobble provider 的稳定标识 — 用于 settings 持久化 + Keychain account 命名。
public enum ScrobbleProviderID: String, Codable, Sendable, CaseIterable {
    case listenBrainz
    case lastFm

    public var displayName: String {
        switch self {
        case .listenBrainz: return "ListenBrainz"
        case .lastFm: return "Last.fm"
        }
    }

    /// 用于 Keychain 存 token / sessionKey 的 account 字段。
    var keychainAccount: String { "scrobble.\(rawValue)" }
}
