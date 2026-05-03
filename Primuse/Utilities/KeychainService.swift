import Foundation
import Security
import PrimuseKit

enum KeychainService {
    /// In-memory mirror of every password seen in this app session — written
    /// eagerly on `setPassword` (before keychain) and read first on
    /// `getPassword`. Two reasons:
    ///
    /// 1. macOS 26 sandbox keychain occasionally surfaces transient -34018 /
    ///    -25300 errors even after a successful write. Without a memory
    ///    fallback a freshly-typed password silently disappears between
    ///    "Save" and "Connect" → user sees 400 with no clue why.
    /// 2. Avoids hitting the keychain on the hot connect path for repeated
    ///    `connector(for:)` calls within a single session.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var memoryCache: [String: String] = [:]

    private static func cacheRead(_ account: String) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return memoryCache[account]
    }

    private static func cacheWrite(_ password: String?, for account: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let password { memoryCache[account] = password }
        else { memoryCache.removeValue(forKey: account) }
    }

    static func setPassword(_ password: String, for account: String) {
        // Cache eagerly — this guarantees the just-typed password survives
        // even if every keychain write below silently fails.
        cacheWrite(password, for: account)

        let data = Data(password.utf8)

        // Delete any existing entry (both synchronizable and non-synchronizable variants).
        deletePassword(for: account)
        // The delete above also wipes our cache; restore it.
        cacheWrite(password, for: account)

        // 优先尝试 synchronizable(走 iCloud Keychain),失败回退到本地 keychain。
        // 沙盒 macOS 在用户没开 iCloud Keychain 时,synchronizable 写入会
        // 返回 errSecParam/errSecMissingEntitlement,之前没有诊断 + 回退,
        // 表现就是「密码看似保存了但下次读出来是空」→ 永远 400。
        let preferSync = CloudSyncChannel.isEnabled(.credentials)

        var status = errSecParam
        if preferSync {
            status = addItem(account: account, data: data, synchronizable: true)
            if status != errSecSuccess {
                plog("⚠️ Keychain setPassword (sync) status=\(status) — falling back to local")
            }
        }
        if status != errSecSuccess {
            status = addItem(account: account, data: data, synchronizable: false)
            if status != errSecSuccess {
                plog("⚠️ Keychain setPassword (local) status=\(status) account=\(account)")
            }
        }
    }

    private static func addItem(account: String, data: Data, synchronizable: Bool) -> OSStatus {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func getPassword(for account: String) -> String? {
        // 1) Memory cache — populated by setPassword in this session.
        if let cached = cacheRead(account) {
            plog("🔑 Keychain getPassword HIT (memory) account=\(account) len=\(cached.count)")
            return cached
        }

        // 2) Keychain fallback — covers passwords saved in a previous session.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            plog("🔑 Keychain getPassword MISS status=\(status) account=\(account)")
            return nil
        }

        let pw = String(data: data, encoding: .utf8)
        if let pw {
            // Promote to memory cache so subsequent reads skip the keychain.
            cacheWrite(pw, for: account)
        }
        plog("🔑 Keychain getPassword HIT (keychain) account=\(account) len=\(pw?.count ?? 0)")
        return pw
    }

    static func deletePassword(for account: String) {
        cacheWrite(nil, for: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Re-write any pre-iCloud (non-synchronizable) entries as synchronizable so they
    /// sync forward to other devices. Idempotent — safe to call on every launch.
    static func migrateLegacyEntriesToICloud() {
        let copyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
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
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { continue }

            // Delete the local-only copy and re-add as synchronizable.
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: PrimuseConstants.keychainServiceName,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            setPassword(password, for: account)
        }
    }
}
