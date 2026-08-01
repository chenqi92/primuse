import Foundation
import Security
import PrimuseKit

enum KeychainService {
    enum PasswordLookupResult: Equatable {
        case found(String)
        case notFound
        case temporarilyUnavailable(OSStatus)

        var password: String? {
            guard case .found(let password) = self else { return nil }
            return password
        }
    }

    /// In-memory mirror of credentials that were successfully persisted and
    /// then read in this app session. Two reasons:
    ///
    /// 1. macOS 26 sandbox keychain occasionally surfaces transient -34018 /
    ///    -25300 errors after an earlier successful write. Keeping that durable
    ///    value in memory prevents a later read glitch from turning into an
    ///    empty-password login during the same session.
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

    /// Persists a credential without destroying the last known-good value.
    ///
    /// The target Keychain variant is updated/added first. Only after that
    /// succeeds do we remove the other synchronizable variant and publish the
    /// new value to the in-memory cache. Callers can therefore keep the UI open
    /// when persistence genuinely fails instead of reporting a successful save.
    @discardableResult
    static func setPassword(_ password: String, for account: String) -> Bool {
        let data = Data(password.utf8)

        // The `credentials` channel toggle decides whether new writes go to
        // iCloud Keychain (synchronizable) or stay local. Past entries already
        // on iCloud Keychain stay there — that's a system-level decision the
        // user has to revisit in iOS Settings.
        let synchronizable = CloudSyncChannel.usesSynchronizableKeychain()
            && Self.supportsSynchronizableKeychainAttributes
        let primaryStatus = persistPasswordItem(
            data,
            account: account,
            synchronizable: synchronizable
        )

        var persistedSynchronizable = synchronizable
        var finalStatus = primaryStatus

        // iCloud Keychain can be temporarily unavailable even when the local
        // Keychain is healthy. Preserve the historical local-only fallback,
        // but apply the same update-before-cleanup ordering.
        if primaryStatus != errSecSuccess, synchronizable {
            let localStatus = persistPasswordItem(
                data,
                account: account,
                synchronizable: false
            )
            finalStatus = localStatus
            if localStatus == errSecSuccess {
                persistedSynchronizable = false
                plog("🔐 Keychain sync write failed (\(primaryStatus)) for account=\(account.prefix(8))…; saved local-only fallback")
            } else {
                plog("⚠️ Keychain write failed for account=\(account.prefix(8))… syncStatus=\(primaryStatus) localStatus=\(localStatus)")
            }
        }

        #if DEBUG && targetEnvironment(simulator)
        // Unsigned QA builds can lack an application-identifier entitlement.
        // Persisting real credentials in UserDefaults would expose them as
        // plaintext, so the fallback is available only for explicitly opted-in
        // fake QA credentials. Normal simulator runs fail closed.
        if finalStatus == errSecMissingEntitlement {
            guard simulatorPlaintextFallbackEnabled else {
                purgeSimulatorPlaintextFallback()
                plog("⚠️ Keychain unavailable (-34018); plaintext simulator credential fallback is disabled")
                return false
            }
            let stored = simulatorFallbackWrite(password, for: account)
            if stored {
                cacheWrite(password, for: account)
                plog("🔐 Keychain unavailable (-34018); saved explicitly enabled fake QA credential for account=\(account.prefix(8))…")
            } else {
                plog("⚠️ Simulator credential fallback write failed for account=\(account.prefix(8))…")
            }
            return stored
        }
        #endif

        guard finalStatus == errSecSuccess else {
            if !synchronizable {
                plog("⚠️ Keychain local write failed for account=\(account.prefix(8))… status=\(finalStatus)")
            }
            return false
        }

        // Now that the new value is durable, remove only the obsolete variant.
        if Self.supportsSynchronizableKeychainAttributes {
            let cleanupStatus = deletePasswordVariant(
                for: account,
                synchronizable: !persistedSynchronizable
            )
            if cleanupStatus != errSecSuccess && cleanupStatus != errSecItemNotFound {
                plog("⚠️ Keychain obsolete-variant cleanup failed for account=\(account.prefix(8))… status=\(cleanupStatus)")
                // Reads prefer the local copy. If the new durable target is the
                // synchronizable item, make the undeletable local copy match it
                // before claiming success; otherwise a relaunch could surface
                // the stale password.
                if persistedSynchronizable {
                    let mirrorStatus = persistPasswordItem(
                        data,
                        account: account,
                        synchronizable: false
                    )
                    guard mirrorStatus == errSecSuccess else {
                        plog("⚠️ Keychain local mirror update failed for account=\(account.prefix(8))… status=\(mirrorStatus)")
                        return false
                    }
                }
            }
        }

        cacheWrite(password, for: account)
        return true
    }

    static func getPassword(for account: String) -> String? {
        passwordLookup(for: account).password
    }

    /// Keeps "no saved credential" separate from a temporarily unreadable
    /// Keychain (for example before the first device unlock). Authentication
    /// callers must not turn the latter into an empty-password login attempt.
    static func passwordLookup(for account: String) -> PasswordLookupResult {
        // 1) Memory cache — populated by setPassword in this session.
        if let cached = cacheRead(account) {
            plog("🔑 Keychain getPassword HIT (memory) account=\(account.prefix(8))…")
            return .found(cached)
        }

        // 2) Keychain fallback — covers passwords saved in a previous session.
        // Match BOTH variants (`kSecAttrSynchronizableAny`) and return every hit
        // so we can pick deterministically: a local (non-synchronizable) entry
        // is the most-recently-written copy whenever the `credentials` channel
        // was toggled off, so it must win over a possibly-stale synchronizable
        // copy left over from when the channel was on.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if Self.supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        #if DEBUG && targetEnvironment(simulator)
        if status == errSecMissingEntitlement, !simulatorPlaintextFallbackEnabled {
            purgeSimulatorPlaintextFallback()
            plog("🔑 Keychain temporarily unavailable; plaintext simulator credential fallback is disabled")
            return .temporarilyUnavailable(status)
        }
        if status == errSecMissingEntitlement,
           let password = simulatorFallbackRead(for: account) {
            cacheWrite(password, for: account)
            plog("🔑 Keychain getPassword HIT (simulator fallback) account=\(account.prefix(8))…")
            return .found(password)
        }
        if status == errSecMissingEntitlement {
            plog("🔑 Keychain getPassword MISS (simulator fallback) account=\(account.prefix(8))…")
            return .notFound
        }
        #endif

        guard status == errSecSuccess else {
            plog("🔑 Keychain getPassword MISS status=\(status) account=\(account.prefix(8))…")
            return status == errSecItemNotFound
                ? .notFound
                : .temporarilyUnavailable(status)
        }

        let items: [[String: Any]]
        if let matches = result as? [[String: Any]] {
            items = matches
        } else if let match = result as? [String: Any] {
            items = [match]
        } else {
            plog("🔑 Keychain getPassword unreadable result account=\(account.prefix(8))…")
            return .temporarilyUnavailable(errSecDecode)
        }

        // Prefer the local (non-synchronizable) entry; fall back to any match.
        let chosen = items.first(where: { ($0[kSecAttrSynchronizable as String] as? Bool) == false })
            ?? items.first
        guard let data = chosen?[kSecValueData as String] as? Data else {
            plog("🔑 Keychain getPassword MISS status=\(status) account=\(account.prefix(8))…")
            return .temporarilyUnavailable(errSecDecode)
        }

        guard let pw = String(data: data, encoding: .utf8) else {
            plog("🔑 Keychain getPassword decode failed account=\(account.prefix(8))…")
            return .temporarilyUnavailable(errSecDecode)
        }
        // Promote to memory cache so subsequent reads skip the keychain.
        cacheWrite(pw, for: account)
        plog("🔑 Keychain getPassword HIT (keychain) account=\(account.prefix(8))…")
        return .found(pw)
    }

    static func deletePassword(for account: String) {
        cacheWrite(nil, for: account)
        #if DEBUG && targetEnvironment(simulator)
        simulatorFallbackDelete(for: account)
        #endif
        // Always sweep BOTH synchronizable and non-synchronizable variants with
        // `kSecAttrSynchronizableAny`, regardless of the current `credentials`
        // channel state. If we honored the channel toggle here, turning the
        // channel off would leave a stale synchronizable entry behind: a later
        // password change would only touch the local copy while the old
        // synchronizable copy keeps syncing the expired password to other
        // devices (and can resurface via `getPassword`'s Any-match).
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
        ]
        if Self.supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        SecItemDelete(query as CFDictionary)
    }

    private static func persistPasswordItem(
        _ data: Data,
        account: String,
        synchronizable: Bool
    ) -> OSStatus {
        var identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
        ]
        if supportsSynchronizableKeychainAttributes {
            identity[kSecAttrSynchronizable as String] = synchronizable
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }
        guard updateStatus == errSecItemNotFound else {
            return updateStatus
        }

        var addQuery = identity
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another caller may have inserted the same item between update
            // and add. Retrying update keeps the operation race-safe.
            return SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        }
        return addStatus
    }

    private static func deletePasswordVariant(
        for account: String,
        synchronizable: Bool
    ) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
        ]
        if supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = synchronizable
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        }
        return SecItemDelete(query as CFDictionary)
    }

    #if DEBUG && targetEnvironment(simulator)
    private static let simulatorFallbackDefaultsKey =
        "\(PrimuseConstants.keychainServiceName).simulatorCredentialFallback"

    /// This unsafe storage exists solely for deterministic UI automation with
    /// fake credentials in unsigned Debug simulator builds. It cannot be
    /// enabled persistently from app settings.
    private static var simulatorPlaintextFallbackEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "PRIMUSE_QA_ALLOW_PLAINTEXT_CREDENTIAL_FALLBACK"
        ] == "1"
    }

    private static func purgeSimulatorPlaintextFallback() {
        UserDefaults.standard.removeObject(forKey: simulatorFallbackDefaultsKey)
    }

    private static func simulatorFallbackRead(for account: String) -> String? {
        let values = UserDefaults.standard.dictionary(forKey: simulatorFallbackDefaultsKey)
            as? [String: String]
        return values?[account]
    }

    private static func simulatorFallbackWrite(_ password: String, for account: String) -> Bool {
        var values = UserDefaults.standard.dictionary(forKey: simulatorFallbackDefaultsKey)
            as? [String: String] ?? [:]
        values[account] = password
        UserDefaults.standard.set(values, forKey: simulatorFallbackDefaultsKey)
        return simulatorFallbackRead(for: account) == password
    }

    private static func simulatorFallbackDelete(for account: String) {
        var values = UserDefaults.standard.dictionary(forKey: simulatorFallbackDefaultsKey)
            as? [String: String] ?? [:]
        guard values.removeValue(forKey: account) != nil else { return }
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: simulatorFallbackDefaultsKey)
        } else {
            UserDefaults.standard.set(values, forKey: simulatorFallbackDefaultsKey)
        }
    }
    #endif

    /// Re-write any pre-iCloud (non-synchronizable) entries as synchronizable so they
    /// sync forward to other devices. Idempotent — safe to call on every launch.
    static func migrateLegacyEntriesToICloud() {
        #if targetEnvironment(simulator)
        // Simulator apps are ad-hoc signed without the synchronizable-keychain
        // entitlement. Local generic-password items still work as long as the
        // synchronizable attribute is omitted entirely.
        return
        #else
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

            // setPassword writes the synchronizable value first, then removes
            // the local variant only after persistence succeeds.
            setPassword(password, for: account)
        }
        #endif
    }

    private static var supportsSynchronizableKeychainAttributes: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}
