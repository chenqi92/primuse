#if os(macOS)
import CryptoKit
import Foundation
import LocalAuthentication
import PrimuseKit
import Security

/// New items live in the data protection keychain. Only an exact local miss can
/// consult the old login keychain; a service-wide query never reads legacy secrets.
final class MacCredentialKeychain: @unchecked Sendable {
    typealias Query = [String: Any]
    typealias Match = (OSStatus, CFTypeRef?)
    static let shared = MacCredentialKeychain()
    @TaskLocal static var interactiveAccount: String?
    @TaskLocal static var modernMigration = false
    private static let legacyAccess = LegacyAccessGate()

    private final class LegacyAccessGate: @unchecked Sendable {
        let condition = NSCondition()
        var busy = false
        var askingUser = false

        func acquire(interactive: Bool) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            while busy {
                if askingUser && !interactive { return false }
                condition.wait()
            }
            busy = true
            askingUser = interactive
            return true
        }

        func release() {
            condition.lock()
            busy = false
            askingUser = false
            condition.broadcast()
            condition.unlock()
        }
    }

    private func protected(_ query: Query) -> Query {
        var query = query
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    enum Operation {
        case read, add, update(Query), delete
    }

    // Local protected credentials are always checked. Most cloud sources have no
    // login-keychain item at all; avoid a legacy search for every API request.
    private let missingLoginTokens = NSCache<NSString, NSNumber>()
    private let defaults: UserDefaults
    private let perform: (Operation, Query) -> Match

    init(defaults: UserDefaults = .standard, perform: @escaping (Operation, Query) -> Match = systemOperation) {
        self.defaults = defaults
        self.perform = perform
        missingLoginTokens.countLimit = 256
    }

    static func systemOperation(_ operation: Operation, _ query: Query) -> Match {
        switch operation {
        case .read:
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        case .add: return (SecItemAdd(query as CFDictionary, nil), nil)
        case .update(let values): return (SecItemUpdate(query as CFDictionary, values as CFDictionary), nil)
        case .delete: return (SecItemDelete(query as CFDictionary), nil)
        }
    }

    private func match(_ query: Query) -> Match { perform(.read, query) }

    // A one-time grant can permit reading an item but leave deletion disallowed.
    // Remember only its identity so it cannot shadow a newer synchronized value.
    private func retirementKey(_ query: Query) -> String? {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return nil }
        let digest = SHA256.hash(data: Data((service + "\u{0}" + account).utf8))
        return "primuse.keychain.retiredLoginItem." + Data(digest).base64EncodedString()
    }

    private func isLocal(_ query: Query) -> Bool {
        query[kSecAttrAccount as String] is String && query[kSecAttrSynchronizable as String] as? Bool == false
    }

    /// The file-based API's interaction setting is process-wide. Serialize its
    /// brief silent operations and restore the previous setting on every exit.
    /// Background work must not wait behind a user's open authorization dialog.
    private func withLegacyAccess(interactive: Bool = false, _ work: () -> Match) -> Match {
        guard Self.legacyAccess.acquire(interactive: interactive) else { return (errSecInteractionNotAllowed, nil) }
        defer { Self.legacyAccess.release() }
        return interactive ? work() : withoutLegacyUI(work)
    }

    private func withoutLegacyUI(_ work: () -> Match) -> Match {
        var wasAllowed = DarwinBoolean(false)
        let previous = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard previous == errSecSuccess else { return (previous, nil) }
        if !wasAllowed.boolValue { return work() }
        let status = SecKeychainSetUserInteractionAllowed(false)
        guard status == errSecSuccess else { return (status, nil) }
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return work()
    }

    private func legacyIdentity(_ query: Query) -> Query? {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return nil }
        var list: CFArray?
        guard SecKeychainCopySearchList(&list) == errSecSuccess, let list else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecMatchSearchList as String: list]
    }

    func copy(_ query: Query, deviceOnly: Bool = false) -> Match {
        let current = match(protected(query))
        guard !Self.modernMigration, isLocal(query), current.0 == errSecItemNotFound || current.0 == errSecMissingEntitlement else { return current }
        guard let retired = retirementKey(query), !defaults.bool(forKey: retired) else { return current }
        let account = query[kSecAttrAccount as String] as? String
        let interactive = Self.interactiveAccount != nil && Self.interactiveAccount == account
        return withLegacyAccess(interactive: interactive) {
            if interactive || defaults.bool(forKey: retired) {
                let latest = match(protected(query))
                if latest.0 != errSecItemNotFound && latest.0 != errSecMissingEntitlement || defaults.bool(forKey: retired) {
                    return latest
                }
            }
            guard var legacy = legacyIdentity(query) else { return (errSecNotAvailable, nil) }
            legacy[kSecMatchLimit as String] = kSecMatchLimitOne
            legacy[kSecReturnData as String] = true
            legacy[kSecReturnAttributes as String] = true
            legacy[kSecReturnPersistentRef as String] = true
            let old = match(legacy)
            if old.0 == errSecItemNotFound, current.0 == errSecItemNotFound {
                // Another reader may have moved the item while we waited for the gate.
                return match(protected(query))
            }
            guard old.0 == errSecSuccess, let item = old.1 as? Query,
                  let data = item[kSecValueData as String] as? Data else {
                return (Self.readStatus(old.0 == errSecSuccess ? errSecDecode : old.0), nil)
            }

            // An unsigned installation can still use its existing login item.
            // Never remove a legacy item until the new value is durably readable.
            if current.0 != errSecMissingEntitlement {
                var identity = query
                for key in [kSecReturnData, kSecReturnAttributes, kSecMatchLimit] { identity.removeValue(forKey: key as String) }
                var add = identity
                add[kSecValueData as String] = data
                let marker = item[kSecAttrGeneric as String] as? Data
                let onlyHere = deviceOnly || KeychainService.isDeviceOnlyItem(item)
                    || SourceCloudSyncOptOutRegistry.isOptedOut(account: account ?? "")
                if onlyHere { add[kSecAttrGeneric as String] = KeychainService.deviceOnlyItemMarker }
                else { add[kSecAttrGeneric as String] = marker }
                let previousAccess = item[kSecAttrAccessible as String] as? String
                if onlyHere {
                    if previousAccess == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String {
                        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
                    } else if previousAccess == kSecAttrAccessibleWhenUnlocked as String || previousAccess == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String {
                        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                    } else {
                        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    }
                } else {
                    add[kSecAttrAccessible as String] = previousAccess ?? kSecAttrAccessibleAfterFirstUnlock as String
                }
                if identity[kSecAttrService as String] as? String == CloudTokenManager.serviceName,
                   let date = item[kSecAttrModificationDate as String] as? Date {
                    add[kSecAttrGeneric as String] = Self.tokenDateMarker(date)
                }
                let inserted = perform(.add, protected(add)).0
                if inserted == errSecSuccess || inserted == errSecDuplicateItem {
                    var verify = identity
                    verify[kSecReturnData as String] = true
                    verify[kSecMatchLimit as String] = kSecMatchLimitOne
                    let (status, stored) = match(protected(verify))
                    if status == errSecSuccess, let stored = stored as? Data {
                        guard stored == data || inserted == errSecDuplicateItem else { return (errSecDecode, nil) }
                        defaults.set(true, forKey: retired)
                        if stored == data, let reference = item[kSecValuePersistentRef as String] as? Data {
                            var exact: Query = [kSecValuePersistentRef as String: reference]
                            exact[kSecMatchSearchList as String] = legacy[kSecMatchSearchList as String]
                            let (deleted, _) = withoutLegacyUI { perform(.delete, exact) }
                            if deleted == errSecSuccess || deleted == errSecItemNotFound { defaults.removeObject(forKey: retired) }
                        }
                        return match(protected(query))
                    }
                }
            }
            return (errSecSuccess, query[kSecReturnAttributes as String] as? Bool == true ? item as NSDictionary : data as NSData)
        }
    }

    /// Compare dates without reading the login item's secret. In particular,
    /// an obsolete protected token must not block an already rotated iCloud token.
    func localTokenIsNewer(account: String, than synchronizedDate: Date?) -> Bool {
        guard let synchronizedDate else { return false }
        let query: Query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: CloudTokenManager.serviceName,
                            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
                            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true]
        var (status, attributes) = match(protected(query))
        if status == errSecItemNotFound, let retired = retirementKey(query), !defaults.bool(forKey: retired) {
            let now = ProcessInfo.processInfo.systemUptime
            if let until = missingLoginTokens.object(forKey: account as NSString), until.doubleValue > now { return false }
            (status, attributes) = withLegacyAccess {
                guard var old = legacyIdentity(query) else { return (errSecNotAvailable, nil) }
                old[kSecMatchLimit as String] = kSecMatchLimitOne
                old[kSecReturnAttributes as String] = true
                return match(old)
            }
            if status == errSecItemNotFound { missingLoginTokens.setObject(NSNumber(value: now + 30), forKey: account as NSString) }
        }
        guard status == errSecSuccess, let item = attributes as? Query else { return false }
        return CloudCredentialVariantPolicy.shouldReplaceSynchronizableValue(
            localModifiedAt: Self.originalTokenDate(item) ?? item[kSecAttrModificationDate as String] as? Date,
            synchronizableModifiedAt: synchronizedDate
        )
    }

    func localDataForMigration(service: String, account: String) -> Data? {
        let query: Query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
                            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true]
        let (status, item) = match(protected(query))
        return status == errSecSuccess ? item as? Data : nil
    }

    /// Promotion is insert-only: a password already changed on another Mac
    /// must never be overwritten by a local upgrade.
    func promotePassword(_ data: Data, account: String) {
        let local: Query = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: PrimuseConstants.keychainServiceName,
                            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        var sync = local
        sync[kSecAttrSynchronizable as String] = true
        var add = sync
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecValueData as String] = data
        let inserted = perform(.add, protected(add)).0
        guard inserted == errSecSuccess || inserted == errSecDuplicateItem else { return }
        var check = sync
        check[kSecReturnData as String] = true
        check[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, value) = match(protected(check))
        guard status == errSecSuccess, value as? Data == data,
              localDataForMigration(service: PrimuseConstants.keychainServiceName, account: account) == data else { return }
        _ = perform(.delete, protected(local))
    }

    private static func readStatus(_ status: OSStatus) -> OSStatus {
        switch status {
        case errSecAuthFailed, errSecUserCanceled: return errSecInteractionNotAllowed
        default: return status
        }
    }

    /// Only the source the user just opened may ask for its old login item.
    /// Check silently first. A missing, locked or already upgraded item has no
    /// reason to open an authorization dialog.
    @concurrent
    static func prepareUserConnection(_ source: MusicSource) async -> Bool {
        if source.type.requiresOAuth {
            let manager = CloudTokenManager(sourceID: source.id)
            var recovered = false
            if case .temporarilyUnavailable(errSecInteractionNotAllowed) = await manager.lookupTokens() {
                let key = CloudCredentialStorageKeyPolicy.tokenKey(sourceID: source.id)
                let result = await $interactiveAccount.withValue(key) { await manager.lookupTokens() }
                guard case .found = result else { return false }
                recovered = true
            }
            if case .temporarilyUnavailable(errSecInteractionNotAllowed) = await manager.lookupAppCredentials() {
                let key = CloudCredentialStorageKeyPolicy.appCredentialsKey(sourceID: source.id)
                let result = await $interactiveAccount.withValue(key) { await manager.lookupAppCredentials() }
                if case .found = result { recovered = true }
            }
            return recovered
        }
        guard source.type.requiresCredentials, source.authType != .none else { return false }
        var accounts = [source.id]
        if source.type == .fnMusic { accounts.append(FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: source.id)) }
        if source.type != .fnMusic, let binding = source.fnConnectGateway {
            switch binding.scope {
            case .dedicated:
                accounts.append(FnConnectGatewayProtocol.sourceCredentialAccount(sourceID: source.id))
            case .shared:
                accounts.append(FnConnectGatewayProtocol.sharedCredentialAccount(fnID: binding.fnID))
            }
        }
        if source.type == .plex { accounts.append(PlexAccountAPI.accountTokenKeychainAccount(sourceID: source.id)) }
        var recovered = false
        for account in accounts {
            guard !Task.isCancelled else { break }
            if case .temporarilyUnavailable(errSecInteractionNotAllowed) = KeychainService.passwordLookup(for: account) {
                let result = $interactiveAccount.withValue(account) { KeychainService.passwordLookup(for: account) }
                guard case .found = result else { break }
                recovered = true
            }
        }
        return recovered
    }

    private static let tokenDatePrefix = "primuse.legacy-token-date:"
    private static func tokenDateMarker(_ date: Date) -> Data {
        Data((tokenDatePrefix + String(date.timeIntervalSince1970)).utf8)
    }

    static func originalTokenDate(_ item: Query) -> Date? {
        guard let marker = item[kSecAttrGeneric as String] as? Data,
              let text = String(data: marker, encoding: .utf8), text.hasPrefix(tokenDatePrefix),
              let seconds = Double(text.dropFirst(tokenDatePrefix.count)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func update(_ query: Query, _ values: Query) -> OSStatus {
        let current = perform(.update(values), protected(query)).0
        guard !Self.modernMigration, current == errSecMissingEntitlement, isLocal(query) else { return current }
        return withLegacyAccess {
            guard let identity = legacyIdentity(query) else { return (errSecNotAvailable, nil) }
            return perform(.update(values), identity)
        }.0
    }

    func add(_ query: Query) -> OSStatus {
        let current = perform(.add, protected(query)).0
        guard !Self.modernMigration, current == errSecMissingEntitlement, isLocal(query) else { return current }
        return withLegacyAccess {
            var legacy = query
            legacy.removeValue(forKey: kSecAttrSynchronizable as String)
            var destination: SecKeychain?
            let status = SecKeychainCopyDefault(&destination)
            guard status == errSecSuccess, let destination else { return (status, nil) }
            legacy[kSecUseKeychain as String] = destination
            let inserted = perform(.add, legacy)
            if inserted.0 == errSecSuccess, let account = query[kSecAttrAccount as String] as? String {
                missingLoginTokens.removeObject(forKey: account as NSString)
            }
            return inserted
        }.0
    }

    func delete(_ query: Query) -> OSStatus {
        guard query[kSecAttrAccount as String] is String else { return errSecParam }
        if Self.modernMigration || query[kSecAttrSynchronizable as String] as? Bool == true {
            return perform(.delete, protected(query)).0
        }
        return withLegacyAccess {
            guard let old = legacyIdentity(query) else { return (errSecNotAvailable, nil) }
            let legacyStatus = perform(.delete, old).0
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else { return (legacyStatus, nil) }
            let status = perform(.delete, protected(query)).0
            if status == errSecSuccess || status == errSecItemNotFound, let retired = retirementKey(query) { defaults.removeObject(forKey: retired) }
            if isLocal(query), status == errSecMissingEntitlement { return (legacyStatus, nil) }
            return (status, nil)
        }.0
    }
}
#endif
