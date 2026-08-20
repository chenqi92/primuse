import Foundation
import PrimuseKit
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

    enum LookupResult<Value: Sendable>: Sendable {
        case found(Value)
        case notFound
        case temporarilyUnavailable(OSStatus)
        case failed(OSStatus)

        var value: Value? {
            guard case .found(let value) = self else { return nil }
            return value
        }
    }

    // MARK: - Public API

    private var tokenKey: String {
        CloudCredentialStorageKeyPolicy.tokenKey(sourceID: sourceID)
    }

    private var appCredentialsKey: String {
        CloudCredentialStorageKeyPolicy.appCredentialsKey(sourceID: sourceID)
    }

    func lookupTokens() -> LookupResult<Tokens> {
        if let volatileTokens { return .found(volatileTokens) }
        switch keychainRead(key: tokenKey) {
        case .found(let data):
            guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else {
                plog("⛔ Keychain token decode failed sourceID=\(sourceID.prefix(8))…")
                return .failed(errSecDecode)
            }
            plog("☁️ Keychain getTokens HIT sourceID=\(sourceID.prefix(8))… hasRefresh=\(tokens.refreshToken != nil)")
            return .found(tokens)
        case .notFound:
            plog("☁️ Keychain getTokens MISS sourceID=\(sourceID.prefix(8))…")
            return .notFound
        case .temporarilyUnavailable(let status):
            plog("⏳ Keychain tokens temporarily unavailable sourceID=\(sourceID.prefix(8))… status=\(status)")
            return .temporarilyUnavailable(status)
        case .failed(let status):
            plog("⛔ Keychain token read failed sourceID=\(sourceID.prefix(8))… status=\(status)")
            return .failed(status)
        }
    }

    func getTokens() -> Tokens? {
        lookupTokens().value
    }

    func requireTokens() throws -> Tokens {
        switch lookupTokens() {
        case .found(let tokens): return tokens
        case .notFound: throw CloudDriveError.notAuthenticated
        case .temporarilyUnavailable(let status):
            throw CloudDriveError.credentialTemporarilyUnavailable(status)
        case .failed(let status):
            throw CloudDriveError.credentialReadFailed(status)
        }
    }

    @discardableResult
    func saveTokens(_ tokens: Tokens) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let primary = keychainWrite(key: tokenKey, data: data)
        plog("☁️ Keychain saveTokens sourceID=\(sourceID.prefix(8))… ok=\(primary.safe)")
        let persisted: Bool
        if primary.safe {
            persisted = true
        } else if !primary.targetStored {
            // Fallback: try writing as a local-only (non-synchronizable) item.
            // Sandboxed macOS apps without an explicit keychain-access-group
            // can fail on synchronizable adds with errSecMissingEntitlement.
            let okLocal = keychainWriteLocal(key: tokenKey, data: data)
            plog("☁️ Keychain saveTokens FALLBACK local-only sourceID=\(sourceID.prefix(8))… ok=\(okLocal)")
            persisted = okLocal
        } else {
            // The fresh target value is already durable. A cleanup/mirror
            // failure must not trigger the local fallback because that path
            // would delete the newly written synchronizable rotation.
            persisted = false
        }
        volatileTokens = persisted ? nil : tokens
        return persisted
    }

    @discardableResult
    func deleteTokens() -> Bool {
        let deleted = Self.keychainDelete(key: tokenKey)
        if deleted { volatileTokens = nil }
        return deleted
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

    private let refreshCoordinator = PersistedTaskDeduplicator<Tokens>()

    /// 并发去重的 token 刷新 —— proactive(getToken 本地过期) 与 reactive(服务端 401)
    /// 两条路径共享同一个 in-flight 任务, 只发一次刷新。refresh_token 轮换型 provider
    /// (阿里云/OneDrive/Google/Dropbox/115) 第一路刷新成功后旧 token 即失效, 多路并发
    /// 各自刷新会 invalid_grant 把账号踢下线。独立 coordinator actor 原子地安装并
    /// 共享包含持久化的完整任务。
    func refreshDeduped(
        _ trigger: RefreshTrigger,
        refresh: @Sendable @escaping (Tokens) async throws -> Tokens
    ) async throws -> Tokens {
        var current = try requireTokens()

        // A rotating provider can invalidate the old refresh token as soon as
        // the remote refresh succeeds. If the subsequent Keychain write fails,
        // saveTokens keeps the fresh pair in memory. Retry that durable write
        // before deciding whether another remote refresh is needed; otherwise
        // an unexpired in-memory access token would bypass persistence forever
        // and the next process launch would fall back to the invalid old pair.
        if let pending = volatileTokens {
            plog("☁️ Retrying pending token persistence sourceID=\(sourceID.prefix(8))…")
            current = try await refreshCoordinator.retryPersistence(
                of: pending,
                persist: { [weak self] tokens in
                    guard let self, await self.saveTokens(tokens) else {
                        throw CloudDriveError.tokenPersistenceFailed
                    }
                }
            )
        }

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
        // Persistence is part of the shared task. A follower must not return a
        // rotated token while the creator is still saving it, or miss a save
        // failure that the creator reports to its own caller.
        let refreshInput = current
        return try await refreshCoordinator.run(
            operation: { try await refresh(refreshInput) },
            persist: { [weak self] refreshed in
                guard let self, await self.saveTokens(refreshed) else {
                    // saveTokens keeps the rotated token in memory so later
                    // requests do not fall back to the now-invalid old token.
                    throw CloudDriveError.tokenPersistenceFailed
                }
            }
        )
    }

    // MARK: - App Credentials (user-provided client_id/secret)

    struct AppCredentials: Codable, Sendable {
        var clientId: String
        var clientSecret: String?
    }

    func lookupAppCredentials() -> LookupResult<AppCredentials> {
        switch keychainRead(key: appCredentialsKey) {
        case .found(let data):
            guard let credentials = try? JSONDecoder().decode(AppCredentials.self, from: data) else {
                plog("⛔ Keychain app credential decode failed sourceID=\(sourceID.prefix(8))…")
                return .failed(errSecDecode)
            }
            return .found(credentials)
        case .notFound:
            return .notFound
        case .temporarilyUnavailable(let status):
            plog("⏳ Keychain app credentials temporarily unavailable sourceID=\(sourceID.prefix(8))… status=\(status)")
            return .temporarilyUnavailable(status)
        case .failed(let status):
            plog("⛔ Keychain app credential read failed sourceID=\(sourceID.prefix(8))… status=\(status)")
            return .failed(status)
        }
    }

    func getAppCredentials() -> AppCredentials? {
        lookupAppCredentials().value
    }

    func requireAppCredentials() throws -> AppCredentials {
        switch lookupAppCredentials() {
        case .found(let credentials): return credentials
        case .notFound: throw CloudDriveError.notAuthenticated
        case .temporarilyUnavailable(let status):
            throw CloudDriveError.credentialTemporarilyUnavailable(status)
        case .failed(let status):
            throw CloudDriveError.credentialReadFailed(status)
        }
    }

    @discardableResult
    func saveAppCredentials(_ creds: AppCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(creds) else { return false }
        let primary = keychainWrite(key: appCredentialsKey, data: data)
        if primary.safe { return true }
        guard !primary.targetStored else { return false }
        // 与 saveTokens 一致:沙盒 macOS 在没开 iCloud Keychain 时
        // synchronizable 写会 errSecMissingEntitlement,回退本地。
        return keychainWriteLocal(key: appCredentialsKey, data: data)
    }

    @discardableResult
    func deleteAppCredentials() -> Bool {
        Self.keychainDelete(key: appCredentialsKey)
    }

    /// Used by source tombstone pruning, where deletion must finish before the
    /// row is removed so a Keychain failure still has a retry target.
    nonisolated static func deleteStoredCredentials(for sourceID: String) -> Bool {
        let tokensDeleted = keychainDelete(
            key: CloudCredentialStorageKeyPolicy.tokenKey(sourceID: sourceID)
        )
        let appCredentialsDeleted = keychainDelete(
            key: CloudCredentialStorageKeyPolicy.appCredentialsKey(sourceID: sourceID)
        )
        return tokensDeleted && appCredentialsDeleted
    }

    // MARK: - Keychain helpers

    private func keychainRead(key: String) -> LookupResult<Data> {
        guard Self.supportsSynchronizableKeychainAttributes else {
            return keychainRead(key: key, synchronizable: false)
        }

        let preferredSynchronizable = CloudSyncChannel.usesSynchronizableKeychain()
        let preferred = keychainRead(key: key, synchronizable: preferredSynchronizable)
        switch preferred {
        case .found:
            return preferred
        case .temporarilyUnavailable:
            // A fallback variant may be an obsolete refresh token left behind
            // by a failed cleanup. Do not use it while the authoritative
            // variant is merely locked/unavailable.
            return preferred
        case .failed(let status)
            where status != errSecMissingEntitlement || !preferredSynchronizable:
            return preferred
        case .failed, .notFound:
            break
        }

        // Missing synchronizable entitlement is the expected reason for the
        // local-only macOS fallback. A genuine miss may likewise use the other
        // variant; every other preferred-variant error was returned above.
        let fallback = keychainRead(key: key, synchronizable: !preferredSynchronizable)
        switch fallback {
        case .found:
            return fallback
        case .failed:
            return fallback
        case .temporarilyUnavailable:
            return fallback
        case .notFound:
            return fallback
        }
    }

    private func keychainRead(key: String, synchronizable: Bool) -> LookupResult<Data> {
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
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .temporarilyUnavailable(status)
        default:
            return .failed(status)
        }
    }

    private struct KeychainWriteOutcome {
        let targetStored: Bool
        let safe: Bool
    }

    private func keychainWrite(key: String, data: Data) -> KeychainWriteOutcome {
        let synchronizable = CloudSyncChannel.usesSynchronizableKeychain()
            && Self.supportsSynchronizableKeychainAttributes
        let success = Self.upsertKeychainItem(key: key, data: data, synchronizable: synchronizable)
        guard success else {
            return KeychainWriteOutcome(targetStored: false, safe: false)
        }
        guard Self.supportsSynchronizableKeychainAttributes else {
            return KeychainWriteOutcome(targetStored: true, safe: true)
        }
        return KeychainWriteOutcome(
            targetStored: true,
            safe: Self.removeOrMirrorObsoleteItem(
                key: key,
                synchronizable: !synchronizable,
                targetData: data
            )
        )
    }

    @discardableResult
    private func keychainWriteLocal(key: String, data: Data) -> Bool {
        let success = Self.upsertKeychainItem(key: key, data: data, synchronizable: false)
        guard success else { return false }
        guard Self.supportsSynchronizableKeychainAttributes else { return true }
        return Self.removeOrMirrorObsoleteItem(
            key: key,
            synchronizable: true,
            targetData: data
        )
    }

    @discardableResult
    private nonisolated static func keychainDelete(key: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Self.serviceName,
        ]
        if Self.supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            plog("⚠️ Cloud credential delete failed key=\(key.prefix(24))… status=\(status)")
            return false
        }
        return true
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
        guard status == errSecSuccess else { return }
        let items: [[String: Any]]
        if let matches = result as? [[String: Any]] {
            items = matches
        } else if let match = result as? [String: Any] {
            items = [match]
        } else {
            return
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }

            let localModifiedAt = item[kSecAttrModificationDate as String] as? Date
            let synchronizable = readKeychainRecord(key: account, synchronizable: true)
            let targetData: Data

            switch synchronizable {
            case .found(let record):
                if record.data == data {
                    targetData = record.data
                } else if CloudCredentialVariantPolicy.shouldReplaceSynchronizableValue(
                    localModifiedAt: localModifiedAt,
                    synchronizableModifiedAt: record.modifiedAt
                ) {
                    guard upsertKeychainItem(key: account, data: data, synchronizable: true),
                          keychainItemMatches(key: account, data: data, synchronizable: true) else {
                        plog("⚠️ Cloud token migration retained local item after sync write failure key=\(account.prefix(24))…")
                        continue
                    }
                    targetData = data
                } else {
                    // The synchronizable item is newer (or the ordering is
                    // ambiguous), so the legacy/local copy must never replace
                    // a rotated refresh token.
                    targetData = record.data
                }
            case .notFound:
                guard upsertKeychainItem(key: account, data: data, synchronizable: true),
                      keychainItemMatches(key: account, data: data, synchronizable: true) else {
                    plog("⚠️ Cloud token migration retained local item after sync write failure key=\(account.prefix(24))…")
                    continue
                }
                targetData = data
            case .temporarilyUnavailable(let status), .failed(let status):
                plog("⚠️ Cloud token migration deferred while sync item is unavailable key=\(account.prefix(24))… status=\(status)")
                continue
            }

            guard removeOrMirrorObsoleteItem(
                key: account,
                synchronizable: false,
                targetData: targetData
            ) else {
                plog("⚠️ Cloud token migration could not reconcile local item key=\(account.prefix(24))…")
                continue
            }
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

    private struct KeychainRecord: Sendable {
        let data: Data
        let modifiedAt: Date?
    }

    private nonisolated static func readKeychainRecord(
        key: String,
        synchronizable: Bool
    ) -> LookupResult<KeychainRecord> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if supportsSynchronizableKeychainAttributes {
            query[kSecAttrSynchronizable as String] = synchronizable
                ? kCFBooleanTrue as Any
                : kCFBooleanFalse as Any
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let item = result as? [String: Any],
                  let data = item[kSecValueData as String] as? Data else {
                return .failed(errSecDecode)
            }
            return .found(KeychainRecord(
                data: data,
                modifiedAt: item[kSecAttrModificationDate as String] as? Date
            ))
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .temporarilyUnavailable(status)
        default:
            return .failed(status)
        }
    }

    private nonisolated static func keychainItemMatches(
        key: String,
        data: Data,
        synchronizable: Bool
    ) -> Bool {
        guard case .found(let record) = readKeychainRecord(
            key: key,
            synchronizable: synchronizable
        ) else {
            return false
        }
        return record.data == data
    }

    private nonisolated static func removeOrMirrorObsoleteItem(
        key: String,
        synchronizable: Bool,
        targetData: Data
    ) -> Bool {
        let deleteStatus = deleteKeychainItem(key: key, synchronizable: synchronizable)
        let removed = deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound
        // A synchronizable item cannot override the local fallback while the
        // process lacks its entitlement. If that entitlement later becomes
        // available, launch migration reconciles both variants by modification
        // date before connectors read credentials.
        let inaccessible = synchronizable && deleteStatus == errSecMissingEntitlement
        var mirrored = false

        if !removed && !inaccessible {
            plog("⚠️ Cloud token obsolete-variant cleanup failed key=\(key.prefix(24))… sync=\(synchronizable) status=\(deleteStatus)")
            mirrored = upsertKeychainItem(
                key: key,
                data: targetData,
                synchronizable: synchronizable
            ) && keychainItemMatches(
                key: key,
                data: targetData,
                synchronizable: synchronizable
            )
            if !mirrored {
                plog("⚠️ Cloud token obsolete-variant mirror failed key=\(key.prefix(24))… sync=\(synchronizable)")
            }
        }

        return CloudCredentialVariantPolicy.isWriteSafe(
            targetStored: true,
            obsoleteVariantRemoved: removed,
            obsoleteVariantMatchesTarget: mirrored,
            obsoleteVariantCannotOverrideTarget: inaccessible
        )
    }

    @discardableResult
    private nonisolated static func deleteKeychainItem(
        key: String,
        synchronizable: Bool
    ) -> OSStatus {
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
        return SecItemDelete(query as CFDictionary)
    }

    private nonisolated static var supportsSynchronizableKeychainAttributes: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}
