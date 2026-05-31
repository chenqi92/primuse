import Foundation
import Security

/// Manages OAuth tokens for cloud drive sources, storing securely in Keychain.
/// Tokens are written as iCloud-synchronizable keychain items so they roam across
/// the user's devices alongside the source list.
actor CloudTokenManager {
    private let sourceID: String
    private static let serviceName = "com.welape.primuse.cloud"

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
        guard let data = keychainRead(key: "cloud_tokens_\(sourceID)"),
              let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else {
            plog("☁️ Keychain getTokens MISS sourceID=\(sourceID)")
            return nil
        }
        plog("☁️ Keychain getTokens HIT sourceID=\(sourceID) accessTokenLen=\(tokens.accessToken.count) hasRefresh=\(tokens.refreshToken != nil)")
        return tokens
    }

    func saveTokens(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let ok = keychainWrite(key: "cloud_tokens_\(sourceID)", data: data)
        plog("☁️ Keychain saveTokens sourceID=\(sourceID) bytes=\(data.count) ok=\(ok)")
        if !ok {
            // Fallback: try writing as a local-only (non-synchronizable) item.
            // Sandboxed macOS apps without an explicit keychain-access-group
            // can fail on synchronizable adds with errSecMissingEntitlement.
            let okLocal = keychainWriteLocal(key: "cloud_tokens_\(sourceID)", data: data)
            plog("☁️ Keychain saveTokens FALLBACK local-only sourceID=\(sourceID) ok=\(okLocal)")
        }
    }

    func deleteTokens() {
        keychainDelete(key: "cloud_tokens_\(sourceID)")
    }

    func getAccessToken() -> String? {
        getTokens()?.accessToken
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: Self.synchronizableLookupValue,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Returns true on success, false otherwise. Logs the underlying
    /// `OSStatus` so failures (most often `errSecMissingEntitlement` /
    /// -34018 on a sandboxed macOS app trying to write a synchronizable
    /// item) are visible during diagnosis.
    @discardableResult
    private func keychainWrite(key: String, data: Data) -> Bool {
        keychainDelete(key: key) // Remove existing (both sync and non-sync variants)
        let synchronizable = CloudSyncChannel.usesSynchronizableKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.serviceName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
        return Self.addKeychainItem(query, synchronizable: synchronizable, key: key)
    }

    @discardableResult
    private func keychainWriteLocal(key: String, data: Data) -> Bool {
        keychainDelete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.serviceName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        return Self.addKeychainItem(query, synchronizable: false, key: key)
    }

    private func keychainDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.serviceName,
            kSecAttrSynchronizable as String: Self.synchronizableLookupValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Re-write any pre-iCloud (non-synchronizable) cloud-token entries as synchronizable.
    /// Idempotent — safe to call on every launch.
    nonisolated static func migrateLegacyEntriesToICloud() {
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

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: serviceName,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: serviceName,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            ]
            _ = addKeychainItem(addQuery, synchronizable: true, key: account)
        }
    }

    @discardableResult
    private nonisolated static func addKeychainItem(_ query: [String: Any], synchronizable: Bool, key: String) -> Bool {
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return true }

        if synchronizable {
            var localQuery = query
            localQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            let fallbackStatus = SecItemAdd(localQuery as CFDictionary, nil)
            if fallbackStatus == errSecSuccess {
                plog("🔐 Cloud token sync write failed (\(status)) for key=\(key.prefix(24))…; saved local-only fallback")
            } else {
                plog("⚠️ Cloud token write failed for key=\(key.prefix(24))… syncStatus=\(status) localStatus=\(fallbackStatus)")
            }
            return fallbackStatus == errSecSuccess
        } else {
            plog("⚠️ Cloud token local write failed for key=\(key.prefix(24))… status=\(status)")
            return false
        }
    }

    private nonisolated static var synchronizableLookupValue: Any {
        if CloudSyncChannel.usesSynchronizableKeychain() {
            return kSecAttrSynchronizableAny
        }
        return kCFBooleanFalse as Any
    }
}
