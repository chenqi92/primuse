import Foundation
import Security
import PrimuseKit

enum KeychainService {
    typealias PasswordLookupResult = NetworkCredentialPolicy.LookupResult

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
        if !simulatorPlaintextFallbackEnabled {
            purgeSimulatorPlaintextFallback()
            if finalStatus == errSecMissingEntitlement {
                plog("⚠️ Keychain unavailable (-34018); plaintext simulator credential fallback is disabled")
                return false
            }
        } else {
            // Simulator installs can move between signed and unsigned builds.
            // Keep the explicitly enabled QA fallback synchronized so a later
            // entitlement transition cannot revive an older fake credential.
            let fallbackWriteOutcome: SimulatorCredentialWriteOutcome
            switch finalStatus {
            case errSecSuccess:
                fallbackWriteOutcome = .primarySucceeded
            case errSecMissingEntitlement:
                fallbackWriteOutcome = .missingEntitlement
            default:
                fallbackWriteOutcome = .otherFailure
            }
            let fallbackMutation = SimulatorCredentialFallbackPolicy.mutation(
                after: fallbackWriteOutcome
            )
            guard applySimulatorFallbackMutation(
                fallbackMutation,
                password: password,
                for: account
            ) else {
                plog("⚠️ Simulator credential fallback write failed for account=\(account.prefix(8))…")
                return false
            }
            if finalStatus == errSecMissingEntitlement {
                cacheWrite(password, for: account)
                plog("🔐 Keychain unavailable (-34018); saved explicitly enabled fake QA credential for account=\(account.prefix(8))…")
                return true
            }
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

    /// Persists secrets that must never be synchronized to another device.
    /// AI API keys use this path because a provider profile may describe a
    /// private endpoint whose credential must remain device-local.
    @discardableResult
    static func setLocalOnlyPassword(_ password: String, for account: String) -> Bool {
        let status = persistPasswordItem(
            Data(password.utf8),
            account: account,
            synchronizable: false,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        guard status == errSecSuccess else {
            plog("⚠️ Local-only Keychain write failed account=\(account.prefix(12))… status=\(status)")
            return false
        }

        if Self.supportsSynchronizableKeychainAttributes {
            let cleanupStatus = deletePasswordVariant(for: account, synchronizable: true)
            guard cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound else {
                plog("⚠️ Local-only Keychain cleanup failed account=\(account.prefix(12))… status=\(cleanupStatus)")
                return false
            }
        }
        cacheWrite(password, for: account)
        return true
    }

    static func localOnlyPasswordLookup(for account: String) -> PasswordLookupResult {
        if let cached = cacheRead(account) {
            return .found(cached)
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if Self.supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            switch status {
            case errSecItemNotFound:
                return .notFound
            case errSecInteractionNotAllowed, errSecNotAvailable, errSecMissingEntitlement:
                return .temporarilyUnavailable(status)
            default:
                return .failed(status)
            }
        }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return .failed(errSecDecode)
        }
        cacheWrite(password, for: account)
        return .found(password)
    }

    /// Resolves a source credential without collapsing Keychain failures into
    /// an empty secret. Anonymous/non-credential sources intentionally receive
    /// an empty value; every other read error must stop before network auth.
    static func connectorCredential(for source: MusicSource) -> NetworkCredentialPolicy.ConnectorResolution {
        guard source.type.requiresCredentials, source.authType != .none else {
            return .ready("")
        }
        return NetworkCredentialPolicy.resolveForConnector(passwordLookup(for: source.id))
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
        let fallbackEnabled = simulatorPlaintextFallbackEnabled
        if !fallbackEnabled {
            purgeSimulatorPlaintextFallback()
            if status == errSecMissingEntitlement {
                plog("🔑 Keychain temporarily unavailable; plaintext simulator credential fallback is disabled")
                return .temporarilyUnavailable(status)
            }
        }
        let fallbackPassword = fallbackEnabled ? simulatorFallbackRead(for: account) : nil
        let primaryRead: SimulatorCredentialPrimaryRead
        switch status {
        case errSecSuccess:
            primaryRead = .found
        case errSecItemNotFound:
            primaryRead = .itemNotFound
        case errSecMissingEntitlement:
            primaryRead = .missingEntitlement
        default:
            primaryRead = .unavailable
        }
        if SimulatorCredentialFallbackPolicy.readSource(
            primary: primaryRead,
            fallbackExists: fallbackPassword != nil
        ) == .fallback,
           let password = fallbackPassword {
            cacheWrite(password, for: account)
            plog("🔑 Keychain getPassword HIT (simulator fallback) primaryStatus=\(status) account=\(account.prefix(8))…")
            return .found(password)
        }
        if status == errSecMissingEntitlement {
            plog("🔑 Keychain getPassword MISS (simulator fallback) account=\(account.prefix(8))…")
            return .temporarilyUnavailable(status)
        }
        #endif

        guard status == errSecSuccess else {
            plog("🔑 Keychain getPassword MISS status=\(status) account=\(account.prefix(8))…")
            switch status {
            case errSecItemNotFound:
                return .notFound
            case errSecInteractionNotAllowed, errSecNotAvailable:
                return .temporarilyUnavailable(status)
            default:
                return .failed(status)
            }
        }

        let items: [[String: Any]]
        if let matches = result as? [[String: Any]] {
            items = matches
        } else if let match = result as? [String: Any] {
            items = [match]
        } else {
            plog("🔑 Keychain getPassword unreadable result account=\(account.prefix(8))…")
            return .failed(errSecDecode)
        }

        // Prefer the local (non-synchronizable) entry; fall back to any match.
        let chosen = items.first(where: { ($0[kSecAttrSynchronizable as String] as? Bool) == false })
            ?? items.first
        guard let data = chosen?[kSecValueData as String] as? Data else {
            plog("🔑 Keychain getPassword MISS status=\(status) account=\(account.prefix(8))…")
            return .failed(errSecDecode)
        }

        guard let pw = String(data: data, encoding: .utf8) else {
            plog("🔑 Keychain getPassword decode failed account=\(account.prefix(8))…")
            return .failed(errSecDecode)
        }
        // Promote to memory cache so subsequent reads skip the keychain.
        cacheWrite(pw, for: account)
        plog("🔑 Keychain getPassword HIT (keychain) account=\(account.prefix(8))…")
        return .found(pw)
    }

    @discardableResult
    static func deletePassword(for account: String) -> Bool {
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
        let status = SecItemDelete(query as CFDictionary)
        #if DEBUG && targetEnvironment(simulator)
        if status == errSecMissingEntitlement {
            let deletedFallback = applySimulatorFallbackMutation(
                SimulatorCredentialFallbackPolicy.mutation(after: .explicitDelete),
                password: nil,
                for: account
            )
            if deletedFallback { cacheWrite(nil, for: account) }
            return deletedFallback
        }
        #endif

        guard status == errSecSuccess || status == errSecItemNotFound else {
            plog("⚠️ Keychain delete failed for account=\(account.prefix(8))… status=\(status)")
            return false
        }
        #if DEBUG && targetEnvironment(simulator)
        guard applySimulatorFallbackMutation(
            SimulatorCredentialFallbackPolicy.mutation(after: .explicitDelete),
            password: nil,
            for: account
        ) else { return false }
        #endif
        cacheWrite(nil, for: account)
        return true
    }

    private static func persistPasswordItem(
        _ data: Data,
        account: String,
        synchronizable: Bool,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlock
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
            kSecAttrAccessible as String: accessible,
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

    private static func simulatorFallbackDelete(for account: String) -> Bool {
        var values = UserDefaults.standard.dictionary(forKey: simulatorFallbackDefaultsKey)
            as? [String: String] ?? [:]
        guard values.removeValue(forKey: account) != nil else { return true }
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: simulatorFallbackDefaultsKey)
        } else {
            UserDefaults.standard.set(values, forKey: simulatorFallbackDefaultsKey)
        }
        let stored = UserDefaults.standard.dictionary(forKey: simulatorFallbackDefaultsKey)
            as? [String: String]
        return stored?[account] == nil
    }

    private static func applySimulatorFallbackMutation(
        _ mutation: SimulatorCredentialFallbackMutation,
        password: String?,
        for account: String
    ) -> Bool {
        switch mutation {
        case .replace:
            guard let password else { return false }
            return simulatorFallbackWrite(password, for: account)
        case .preserve:
            return true
        case .remove:
            return simulatorFallbackDelete(for: account)
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
