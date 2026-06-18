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

        // The `credentials` channel toggle decides whether new writes go to
        // iCloud Keychain (synchronizable) or stay local. Past entries already
        // on iCloud Keychain stay there — that's a system-level decision the
        // user has to revisit in iOS Settings.
        let synchronizable = CloudSyncChannel.usesSynchronizableKeychain()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
        addPasswordItem(addQuery, synchronizable: synchronizable, account: account)
    }

    static func getPassword(for account: String) -> String? {
        // 1) Memory cache — populated by setPassword in this session.
        if let cached = cacheRead(account) {
            plog("🔑 Keychain getPassword HIT (memory) account=\(account.prefix(8))…")
            return cached
        }

        // 2) Keychain fallback — covers passwords saved in a previous session.
        // Match BOTH variants (`kSecAttrSynchronizableAny`) and return every hit
        // so we can pick deterministically: a local (non-synchronizable) entry
        // is the most-recently-written copy whenever the `credentials` channel
        // was toggled off, so it must win over a possibly-stale synchronizable
        // copy left over from when the channel was on.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            plog("🔑 Keychain getPassword MISS status=\(status) account=\(account.prefix(8))…")
            return nil
        }

        // Prefer the local (non-synchronizable) entry; fall back to any match.
        let chosen = items.first(where: { ($0[kSecAttrSynchronizable as String] as? Bool) == false })
            ?? items.first
        guard let data = chosen?[kSecValueData as String] as? Data else {
            plog("🔑 Keychain getPassword MISS status=\(status) account=\(account.prefix(8))…")
            return nil
        }

        let pw = String(data: data, encoding: .utf8)
        if let pw {
            // Promote to memory cache so subsequent reads skip the keychain.
            cacheWrite(pw, for: account)
        }
        plog("🔑 Keychain getPassword HIT (keychain) account=\(account.prefix(8))…")
        return pw
    }

    static func deletePassword(for account: String) {
        cacheWrite(nil, for: account)
        // Always sweep BOTH synchronizable and non-synchronizable variants with
        // `kSecAttrSynchronizableAny`, regardless of the current `credentials`
        // channel state. If we honored the channel toggle here, turning the
        // channel off would leave a stale synchronizable entry behind: a later
        // password change would only touch the local copy while the old
        // synchronizable copy keeps syncing the expired password to other
        // devices (and can resurface via `getPassword`'s Any-match).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func addPasswordItem(_ query: [String: Any], synchronizable: Bool, account: String) {
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess { return }

        if synchronizable {
            var localQuery = query
            localQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            let fallbackStatus = SecItemAdd(localQuery as CFDictionary, nil)
            if fallbackStatus == errSecSuccess {
                plog("🔐 Keychain sync write failed (\(status)) for account=\(account.prefix(8))…; saved local-only fallback")
            } else {
                plog("⚠️ Keychain write failed for account=\(account.prefix(8))… syncStatus=\(status) localStatus=\(fallbackStatus)")
            }
        } else {
            plog("⚠️ Keychain local write failed for account=\(account.prefix(8))… status=\(status)")
        }
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
