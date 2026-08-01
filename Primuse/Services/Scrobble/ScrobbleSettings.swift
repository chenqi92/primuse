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

/// Last.fm 需要 3 个 Keychain 字段才能完整工作 (Last.fm 协议要求 client
/// 端持有 api_key + api_secret 才能签 api_sig, 不像 ListenBrainz 一个 token
/// 就够)。这里把读写集中, 让 Settings UI 和 ScrobbleService 共用一套
/// 帐户命名, 避免散落各处拼字符串。
enum LastFmCredentialsStore {
    enum CredentialsResolution {
        case ready(apiKey: String, apiSecret: String, sessionKey: String)
        case notConfigured
        case unavailable
    }

    private static let apiKeyAccount = "scrobble.lastFm.apiKey"
    private static let apiSecretAccount = "scrobble.lastFm.apiSecret"
    private static let sessionKeyAccount = ScrobbleProviderID.lastFm.keychainAccount
    private static let pendingAuthTokenKey = "primuse.scrobble.lastFm.pendingAuthToken"

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return KeychainService.deletePassword(for: apiKeyAccount)
        } else {
            return KeychainService.setPassword(trimmed, for: apiKeyAccount)
        }
    }

    @discardableResult
    static func saveAPISecret(_ secret: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return KeychainService.deletePassword(for: apiSecretAccount)
        } else {
            return KeychainService.setPassword(trimmed, for: apiSecretAccount)
        }
    }

    @discardableResult
    static func saveSessionKey(_ session: String) -> Bool {
        if session.isEmpty {
            return KeychainService.deletePassword(for: sessionKeyAccount)
        } else {
            return KeychainService.setPassword(session, for: sessionKeyAccount)
        }
    }

    static func apiKeyLookup() -> KeychainService.PasswordLookupResult {
        KeychainService.passwordLookup(for: apiKeyAccount)
    }

    static func apiSecretLookup() -> KeychainService.PasswordLookupResult {
        KeychainService.passwordLookup(for: apiSecretAccount)
    }

    static func sessionKeyLookup() -> KeychainService.PasswordLookupResult {
        KeychainService.passwordLookup(for: sessionKeyAccount)
    }

    static func loadAPIKey() -> String { KeychainService.getPassword(for: apiKeyAccount) ?? "" }
    static func loadAPISecret() -> String { KeychainService.getPassword(for: apiSecretAccount) ?? "" }
    static func loadSessionKey() -> String { KeychainService.getPassword(for: sessionKeyAccount) ?? "" }

    static func savePendingAuthToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingAuthTokenKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: pendingAuthTokenKey)
        }
    }

    static func loadPendingAuthToken() -> String? {
        guard let token = UserDefaults.standard.string(forKey: pendingAuthTokenKey),
              !token.isEmpty else { return nil }
        return token
    }

    /// 实际使用的 API key — 用户在 Settings 高级里粘了自己的就用自己的,
    /// 没粘就 fallback 到 build-time default (`Secrets.local.xcconfig`)。
    /// 让发行构建可配置默认 key, 同时保留「我想用自己的 application 配额」的逃生口。
    static func effectiveAPIKey() -> String {
        switch ScrobbleCredentialAvailabilityPolicy.resolveValue(
            apiKeyLookup(),
            fallback: AppSecrets.lastFmAPIKey
        ) {
        case .ready(let value): return value
        case .notConfigured, .unavailable: return ""
        }
    }

    static func effectiveAPISecret() -> String {
        switch ScrobbleCredentialAvailabilityPolicy.resolveValue(
            apiSecretLookup(),
            fallback: AppSecrets.lastFmAPISecret
        ) {
        case .ready(let value): return value
        case .notConfigured, .unavailable: return ""
        }
    }

    /// app 是否内置了可用的 default key (空字符串 = 没内置, UI 要让
    /// 用户必须粘自己的 key 才能登录)。
    static var hasDefaultKeys: Bool {
        !AppSecrets.lastFmAPIKey.isEmpty && !AppSecrets.lastFmAPISecret.isEmpty
    }

    /// 用户是否在使用自己的 application key (而不是 app 内置的 default)。
    /// UI 用来切换「显示高级覆盖区」的初始展开态。
    static var usingCustomKeys: Bool {
        !loadAPIKey().isEmpty || !loadAPISecret().isEmpty
    }

    /// 完整登录态 = effective key/secret 都有 + sessionKey 已拿到。
    /// 注意是 effective —— 用户没粘自己 key 时也算 connected (用 default)。
    static func isConnected() -> Bool {
        if case .ready = resolveProviderCredentials() { return true }
        return false
    }

    static func resolveProviderCredentials() -> CredentialsResolution {
        let apiKey = ScrobbleCredentialAvailabilityPolicy.resolveValue(
            apiKeyLookup(),
            fallback: AppSecrets.lastFmAPIKey
        )
        let apiSecret = ScrobbleCredentialAvailabilityPolicy.resolveValue(
            apiSecretLookup(),
            fallback: AppSecrets.lastFmAPISecret
        )
        let sessionKey = ScrobbleCredentialAvailabilityPolicy.resolveValue(sessionKeyLookup())

        switch ScrobbleCredentialAvailabilityPolicy.resolveProvider([
            apiKey,
            apiSecret,
            sessionKey,
        ]) {
        case .ready:
            guard case .ready(let resolvedAPIKey) = apiKey,
                  case .ready(let resolvedAPISecret) = apiSecret,
                  case .ready(let resolvedSessionKey) = sessionKey else {
                return .notConfigured
            }
            return .ready(
                apiKey: resolvedAPIKey,
                apiSecret: resolvedAPISecret,
                sessionKey: resolvedSessionKey
            )
        case .notConfigured:
            return .notConfigured
        case .unavailable:
            return .unavailable
        }
    }

    /// Sign-out — 只清 sessionKey 不清 apiKey/apiSecret, 让用户能直接
    /// 重新走 web auth 不用再粘一次 key。
    @discardableResult
    static func signOut() -> Bool {
        guard KeychainService.deletePassword(for: sessionKeyAccount) else {
            return false
        }
        savePendingAuthToken(nil)
        return true
    }
}
