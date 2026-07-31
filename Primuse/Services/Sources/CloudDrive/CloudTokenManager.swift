import Foundation
import Security

/// Manages OAuth tokens for cloud drive sources, storing securely in Keychain.
/// Tokens are written as iCloud-synchronizable keychain items so they roam across
/// the user's devices alongside the source list.
actor CloudTokenManager {
    private let sourceID: String
    private static let serviceName = "com.welape.primuse.cloud"
    private var volatileTokens: Tokens?

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    struct Tokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var tokenType: String?
        var extra: [String: String]?  // e.g. drive_id for AliDrive

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt.addingTimeInterval(-300)  // 5 min before expiry
        }
    }

    // MARK: - Public API

    func getTokens() -> Tokens? {
        if let volatileTokens { return volatileTokens }
        guard let data = keychainRead(key: "cloud_tokens_\(sourceID)"),
              let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else {
            plog("☁️ Keychain getTokens MISS sourceID=\(sourceID.prefix(8))…")
            return nil
        }
        plog("☁️ Keychain getTokens HIT sourceID=\(sourceID.prefix(8))… hasRefresh=\(tokens.refreshToken != nil)")
        return tokens
    }

    @discardableResult
    func saveTokens(_ tokens: Tokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let ok = keychainWrite(key: "cloud_tokens_\(sourceID)", data: data)
        plog("☁️ Keychain saveTokens sourceID=\(sourceID.prefix(8))… ok=\(ok)")
        let persisted: Bool
        if ok {
            persisted = true
        } else {
            // Fallback: try writing as a local-only (non-synchronizable) item.
            // Sandboxed macOS apps without an explicit keychain-access-group
            // can fail on synchronizable adds with errSecMissingEntitlement.
            let okLocal = keychainWriteLocal(key: "cloud_tokens_\(sourceID)", data: data)
            plog("☁️ Keychain saveTokens FALLBACK local-only sourceID=\(sourceID.prefix(8))… ok=\(okLocal)")
            persisted = okLocal
        }
        volatileTokens = persisted ? nil : tokens
        return persisted
    }

    func deleteTokens() {
        volatileTokens = nil
        keychainDelete(key: "cloud_tokens_\(sourceID)")
    }

    func getAccessToken() -> String? {
        getTokens()?.accessToken
    }

    // MARK: - Deduplicated refresh

    /// 刷新触发条件。
    enum RefreshTrigger: Sendable {
        case ifExpired               // proactive: 本地标记过期才刷
        case ifMatches(String)       // reactive(401): 仅当当前 token 仍是被拒的那个才刷
        case force                   // 无条件刷新
    }

    private var refreshTask: Task<Tokens, Error>?

    /// 并发去重的 token 刷新 —— proactive(getToken 本地过期) 与 reactive(服务端 401)
    /// 两条路径共享同一个 in-flight 任务, 只发一次刷新。refresh_token 轮换型 provider
    /// (阿里云/OneDrive/Google/Dropbox/115) 第一路刷新成功后旧 token 即失效, 多路并发
    /// 各自刷新会 invalid_grant 把账号踢下线。actor 串行化保证 check-then-set 原子:
    /// 从读 refreshTask 到写入新 task 之间(getTokens 是同步调用)无挂起点。
    func refreshDeduped(
        _ trigger: RefreshTrigger,
        refresh: @Sendable @escaping (Tokens) async throws -> Tokens
    ) async throws -> Tokens {
        guard let current = getTokens() else { throw CloudDriveError.notAuthenticated }
        // 是否真的需要刷新: 若别的并发刷新已把 token 换掉(reactive)或它已不过期
        // (proactive), 直接返回最新 token —— 不刷新、也不等可能正在进行的无关刷新,
        // 避免一个失败的并发刷新连累本来 token 还有效的调用方。
        let needsRefresh: Bool
        switch trigger {
        case .ifExpired: needsRefresh = current.isExpired
        case .ifMatches(let rejected): needsRefresh = current.accessToken == rejected
        case .force: needsRefresh = true
        }
        guard needsRefresh else { return current }
        // 需要刷新: 有 in-flight 就共享其结果, 否则新建。从这里到 refreshTask = task
        // 之间(getTokens 同步)无挂起点, actor 串行化保证 check-then-set 原子。
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let task = Task<Tokens, Error> { try await refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        guard saveTokens(refreshed) else {
            // Keep the rotated token in memory so later requests in this
            // process do not fall back to the now-invalid previous token.
            throw CloudDriveError.tokenPersistenceFailed
        }
        return refreshed
    }

    // MARK: - App Credentials (user-provided client_id/secret)

    struct AppCredentials: Codable, Sendable {
        var clientId: String
        var clientSecret: String?
    }

    func getAppCredentials() -> AppCredentials? {
        guard let data = keychainRead(key: "cloud_creds_\(sourceID)"),
              let creds = try? JSONDecoder().decode(AppCredentials.self, from: data) else {
            return nil
        }
        return creds
    }

    func saveAppCredentials(_ creds: AppCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        let ok = keychainWrite(key: "cloud_creds_\(sourceID)", data: data)
        if !ok {
            // 与 saveTokens 一致:沙盒 macOS 在没开 iCloud Keychain 时
            // synchronizable 写会 errSecMissingEntitlement,回退本地。
            keychainWriteLocal(key: "cloud_creds_\(sourceID)", data: data)
        }
    }

    func deleteAppCredentials() {
        keychainDelete(key: "cloud_creds_\(sourceID)")
    }

    // MARK: - Keychain helpers

    private func keychainRead(key: String) -> Data? {
        let synchronizable = CloudSyncChannel.usesSynchronizableKeychain()
            && Self.supportsSynchronizableKeychainAttributes
        if synchronizable, let data = keychainRead(key: key, synchronizable: true) {
            return data
        }
        return keychainRead(key: key, synchronizable: false)
    }

    private func keychainRead(key: String, synchronizable: Bool) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if Self.supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = synchronizable
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private func keychainWrite(key: String, data: Data) -> Bool {
        let synchronizable = CloudSyncChannel.usesSynchronizableKeychain()
            && Self.supportsSynchronizableKeychainAttributes
        let success = Self.upsertKeychainItem(key: key, data: data, synchronizable: synchronizable)
        if success, Self.supportsSynchronizableKeychainAttributes {
            Self.deleteKeychainItem(key: key, synchronizable: !synchronizable)
        }
        return success
    }

    @discardableResult
    private func keychainWriteLocal(key: String, data: Data) -> Bool {
        let success = Self.upsertKeychainItem(key: key, data: data, synchronizable: false)
        if success, Self.supportsSynchronizableKeychainAttributes {
            Self.deleteKeychainItem(key: key, synchronizable: true)
        }
        return success
    }

    private func keychainDelete(key: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.serviceName,
        ]
        if Self.supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = Self.synchronizableLookupValue
        }
        SecItemDelete(query as CFDictionary)
    }

    /// Re-write any pre-iCloud (non-synchronizable) cloud-token entries as synchronizable.
    /// Idempotent — safe to call on every launch.
    nonisolated static func migrateLegacyEntriesToICloud() {
        #if targetEnvironment(simulator)
        return
        #else
        let copyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(copyQuery as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }

            guard upsertKeychainItem(key: account, data: data, synchronizable: true),
                  readKeychainItem(key: account, synchronizable: true) == data else {
                plog("⚠️ Cloud token migration retained local item after sync write failure key=\(account.prefix(24))…")
                continue
            }
            deleteKeychainItem(key: account, synchronizable: false)
        }
        #endif
    }

    @discardableResult
    private nonisolated static func upsertKeychainItem(
        key: String,
        data: Data,
        synchronizable: Bool
    ) -> Bool {
        var lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
        ]
        if supportsSynchronizableKeychainAttributes {
            lookup[kSecAttrSynchronizable as String] = synchronizable
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        }
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            plog("⚠️ Cloud token update failed key=\(key.prefix(24))… sync=\(synchronizable) status=\(updateStatus)")
            return false
        }

        var add = lookup
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        plog("⚠️ Cloud token add failed key=\(key.prefix(24))… sync=\(synchronizable) status=\(addStatus)")
        return false
    }

    private nonisolated static func readKeychainItem(key: String, synchronizable: Bool) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = synchronizable
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private nonisolated static func deleteKeychainItem(key: String, synchronizable: Bool) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
        ]
        if supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = synchronizable
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        }
        SecItemDelete(query as CFDictionary)
    }

    private nonisolated static var synchronizableLookupValue: Any {
        if CloudSyncChannel.usesSynchronizableKeychain() {
            return kSecAttrSynchronizableAny
        }
        return kCFBooleanFalse as Any
    }

    private nonisolated static var supportsSynchronizableKeychainAttributes: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}
