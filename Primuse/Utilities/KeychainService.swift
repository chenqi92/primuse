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
        // 本机为这个源保存过密码, 就不再当它「密码还在路上」。
        RemoteSourceArrivalLedger.forget(sourceID: account)

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
                plog("🔐 Keychain sync write failed (\(primaryStatus)) for item=\(account.prefix(8))…; saved local-only fallback")
            } else {
                plog("⚠️ Keychain write failed for item=\(account.prefix(8))… syncStatus=\(primaryStatus) localStatus=\(localStatus)")
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
                plog("⚠️ Simulator credential fallback write failed for item=\(account.prefix(8))…")
                return false
            }
            if finalStatus == errSecMissingEntitlement {
                cacheWrite(password, for: account)
                plog("🔐 Keychain unavailable (-34018); saved explicitly enabled fake QA credential for item=\(account.prefix(8))…")
                return true
            }
        }
        #endif

        guard finalStatus == errSecSuccess else {
            if !synchronizable {
                plog("⚠️ Keychain local write failed for item=\(account.prefix(8))… status=\(finalStatus)")
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
                plog("⚠️ Keychain obsolete-variant cleanup failed for item=\(account.prefix(8))… status=\(cleanupStatus)")
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
                        plog("⚠️ Keychain local mirror update failed for item=\(account.prefix(8))… status=\(mirrorStatus)")
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
    ///
    /// 除了 `…ThisDeviceOnly` 可访问性，还给条目打上本机标记（见
    /// `deviceOnlyItemMarker`）：启动时的 iCloud 迁移只查「非同步项」，得靠这
    /// 两个信号才认得出哪些是刻意留在本机的，否则中继安装凭据、自建分享令牌
    /// 会被整个推到同一 Apple ID 的所有设备上。标记不参与条目身份，所以本文件
    /// 的查询、删除路径和旧的未打标记项都不受影响。
    @discardableResult
    static func setLocalOnlyPassword(_ password: String, for account: String) -> Bool {
        let status = persistPasswordItem(
            Data(password.utf8),
            account: account,
            synchronizable: false,
            deviceOnly: true
        )
        guard status == errSecSuccess else {
            plog("⚠️ Local-only Keychain write failed item=\(account.prefix(12))… status=\(status)")
            return false
        }

        if Self.supportsSynchronizableKeychainAttributes {
            let cleanupStatus = deletePasswordVariant(for: account, synchronizable: true)
            guard cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound else {
                plog("⚠️ Local-only Keychain cleanup failed item=\(account.prefix(12))… status=\(cleanupStatus)")
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
        let lookup = passwordLookup(for: source.id)
        // 源记录经 CloudKit 先到、密码经 iCloud 钥匙串后到的那几分钟, 本机查不到
        // 这条密码。以前当成空密码去登录, NAS 记一次失败还可能锁号; 现在按「凭据
        // 暂不可用」处理, 扫描与播放延后重试。窗口过了仍没有, 才按没有密码处理。
        if case .notFound = lookup,
           CloudSyncChannel.isEnabled(.credentials),
           MusicSourceCloudSyncPolicy.isEligible(source),
           !(source.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           RemoteSourceArrivalLedger.isAwaitingSyncedCredential(sourceID: source.id) {
            return .temporarilyUnavailable(errSecItemNotFound)
        }
        return NetworkCredentialPolicy.resolveForConnector(lookup)
    }

    /// Keeps "no saved credential" separate from a temporarily unreadable
    /// Keychain (for example before the first device unlock). Authentication
    /// callers must not turn the latter into an empty-password login attempt.
    static func passwordLookup(for account: String) -> PasswordLookupResult {
        // 1) Memory cache — populated by setPassword in this session.
        if let cached = cacheRead(account) {
            plog("🔑 Keychain getPassword HIT (memory) item=\(account.prefix(8))…")
            return .found(cached)
        }

        let (status, result) = passwordLookupResult(
            for: account,
            supportsSynchronizableAttributes: Self.supportsSynchronizableKeychainAttributes
        ) { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }

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
            plog("🔑 Keychain getPassword HIT (simulator fallback) primaryStatus=\(status) item=\(account.prefix(8))…")
            return .found(password)
        }
        if status == errSecMissingEntitlement {
            plog("🔑 Keychain getPassword MISS (simulator fallback) item=\(account.prefix(8))…")
            return .temporarilyUnavailable(status)
        }
        #endif

        guard status == errSecSuccess else {
            plog("🔑 Keychain getPassword MISS status=\(status) item=\(account.prefix(8))…")
            switch status {
            case errSecItemNotFound:
                return .notFound
            case errSecInteractionNotAllowed, errSecNotAvailable:
                return .temporarilyUnavailable(status)
            default:
                return .failed(status)
            }
        }

        guard let data = result as? Data else {
            plog("🔑 Keychain getPassword unreadable result item=\(account.prefix(8))…")
            return .failed(errSecDecode)
        }

        guard let pw = String(data: data, encoding: .utf8) else {
            plog("🔑 Keychain getPassword decode failed item=\(account.prefix(8))…")
            return .failed(errSecDecode)
        }
        // Promote to memory cache so subsequent reads skip the keychain.
        cacheWrite(pw, for: account)
        plog("🔑 Keychain getPassword HIT (keychain) item=\(account.prefix(8))…")
        return .found(pw)
    }

    /// Password data requires a single match on macOS. Query the local copy
    /// first so an older synchronized key cannot replace it after a read error.
    static func passwordLookupResult(
        for account: String,
        supportsSynchronizableAttributes: Bool,
        copyMatching: ([String: Any]) -> (OSStatus, AnyObject?)
    ) -> (OSStatus, AnyObject?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if supportsSynchronizableAttributes {
            query[kSecAttrSynchronizable as String] = false
        }
        let localResult = copyMatching(query)
        guard localResult.0 == errSecItemNotFound,
              supportsSynchronizableAttributes else { return localResult }
        query[kSecAttrSynchronizable as String] = true
        return copyMatching(query)
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
            plog("⚠️ Keychain delete failed for item=\(account.prefix(8))… status=\(status)")
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

    /// 记录条目走的是哪条写入路径的标记，写在 `kSecAttrGeneric`（钥匙串留给应用
    /// 自定义的属性，iOS 数据保护钥匙串和 macOS 登录钥匙串都会原样保存并随属性
    /// 一起返回）。需要它是因为 macOS 登录钥匙串不保存 `kSecAttrAccessible`，迁移
    /// 在 Mac 上认不出 `…ThisDeviceOnly`。普通写入也写一个明确的值而不是不写：
    /// 同一账号若曾走过本机路径、后来改走同步路径，旧标记必须被覆盖掉，否则会
    /// 一直挡住迁移。用非空值而不是空 Data，是不想赌两种钥匙串对空属性的处理。
    private static let deviceOnlyItemMarker = Data("primuse.device-only".utf8)
    private static let syncAllowedItemMarker = Data("primuse.sync-allowed".utf8)

    /// `kSecAttrAccessible` 里表示「不出设备」的取值。只列未废弃的三种；应用
    /// 自己只写 AfterFirstUnlockThisDeviceOnly，其余两种是为了别的写入方也能被认出。
    private static let deviceOnlyAccessibilityValues: Set<String> = [
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String,
    ]

    /// 从 `SecItemCopyMatching` 带回的属性判断该项是否以「仅本机」方式落盘。
    /// 两个信号任一命中即算：可访问性是系统层面的事实（iOS 上一定有），标记是
    /// 应用自己的记号（Mac 上唯一可用）。改这里前先确认 `persistPasswordItem`
    /// 的普通写入仍会把两者都覆盖回非本机值。
    private static func isDeviceOnlyItem(_ attributes: [String: Any]) -> Bool {
        if let accessible = attributes[kSecAttrAccessible as String] as? String,
           deviceOnlyAccessibilityValues.contains(accessible) {
            return true
        }
        return (attributes[kSecAttrGeneric as String] as? Data) == deviceOnlyItemMarker
    }

    private static func persistPasswordItem(
        _ data: Data,
        account: String,
        synchronizable: Bool,
        deviceOnly: Bool = false
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

        // 可访问性与本机标记总是成对写入：本机项两者都置上，普通项两者都写回
        // 非本机值，这样 SecItemUpdate 原地更新一个旧的本机项时不会留下半个信号。
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: deviceOnly
                ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                : kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrGeneric as String: deviceOnly ? deviceOnlyItemMarker : syncAllowedItemMarker,
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

        var keptDeviceOnlyCount = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { continue }

            // 「非同步」不等于「待迁移」：setLocalOnlyPassword 写下的项（中继安装
            // 凭据、自建分享令牌）刻意不出设备，迁走会把秘密推到同一 Apple ID 的
            // 所有设备，而且本机副本被删后本机读取路径再也找不到它。只有
            // e1424418 之前按本机方式存下的 AI 密钥才随服务商配置补迁进 iCloud。
            guard AICredentialStoragePolicy.isEligibleForICloudMigration(
                account: account,
                storedDeviceOnly: isDeviceOnlyItem(item)
            ) else {
                keptDeviceOnlyCount += 1
                continue
            }

            // setPassword writes the synchronizable value first, then removes
            // the local variant only after persistence succeeds.
            setPassword(password, for: account)
        }
        if keptDeviceOnlyCount > 0 {
            plog("🔐 Keychain migration kept \(keptDeviceOnlyCount) device-only item(s) local")
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
