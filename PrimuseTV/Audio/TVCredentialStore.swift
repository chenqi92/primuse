#if os(tvOS)
import Foundation
import PrimuseKit
import Security

/// tvOS 凭据读取。
///
/// Phase 1:用户名取自同步过来的 `MusicSource.username`,密码从**可同步 iCloud 钥匙串**
/// 按 sourceID 读取(与 iOS `KeychainService` 同一 service + account 约定;同一 Apple ID
/// 且开启 iCloud 钥匙串时,手机写入的密码会同步到 TV)。
///
/// 链式设计:钥匙串 →(Phase 2)CloudKit 加密凭据包 →(Phase 2)设备配对缓存。
/// Phase 1 只接第一环;后续环加入时本方法签名不变。
enum TVCredentialStore {
    /// 与 iOS/macOS `CloudTokenManager.Tokens` 保持同一 Codable 结构和
    /// Keychain namespace，使同一 App ID 下的 iCloud Keychain 能直接漫游 OAuth 凭据。
    private struct OAuthTokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var tokenType: String?
        var extra: [String: String]?
    }

    private struct OAuthAppCredentials: Codable {
        var clientId: String
        var clientSecret: String?
    }

    private enum KeychainDataLookup {
        case found(Data)
        case notFound
        case temporarilyUnavailable
        case failed(OSStatus)
    }

    private static let cloudCredentialService = "com.welape.primuse.cloud"

    /// 凭据来源链:① 用户在 **TV 本地手动输入** 的凭据(最高优先,跨设备 session 不通用时
    /// 直接在 TV 登录)② 经 CloudKit 加密同步下来的凭据包 ③ 可同步 iCloud 钥匙串(兜底)。
    /// 中继类型还会附上 iPhone 中继端点(放 extra,供 RelayStreamResolver 拼 URL)。
    static func credential(for source: MusicSource, bundle: CredentialBundle?) -> SourceCredential {
        var cred: SourceCredential
        let local = loadLocalCredential(sourceID: source.id)
        let entry = bundle?.entries[source.id]
        if source.authType == .none {
            // 显式访客模式优先级最高：即便 TV 本地、凭据包或同步钥匙串里还留有
            // 旧密码，也不能把它重新附加到匿名 SMB/WebDAV/FTP 请求上。
            cred = SourceCredential()
        } else if source.type == .fnMusic {
            // A username-only bundle entry must not hide a password available
            // from the synchronized Keychain. Merge fields independently.
            cred = entry?.toCredential(defaultUsername: source.username)
                ?? SourceCredential(username: source.username)
            if let local, !local.password.isEmpty {
                cred.username = local.username.isEmpty ? source.username : local.username
                cred.password = local.password
            } else if let bundledPassword = entry?.password, !bundledPassword.isEmpty {
                cred.username = source.username ?? entry?.username
                cred.password = bundledPassword
            } else {
                cred.username = source.username ?? entry?.username
                cred.password = keychainPassword(account: source.id)
            }
        } else if let local, !local.password.isEmpty {
            // 本地输入优先:用户在 TV 上为该源亲手登录过,胜过同步过来的(可能不通用的)凭据。
            cred = SourceCredential(username: local.username.isEmpty ? source.username : local.username,
                                    password: local.password)
        } else if let entry, !entry.isEmpty {
            cred = entry.toCredential(defaultUsername: source.username)
        } else {
            cred = SourceCredential(username: source.username, password: keychainPassword(account: source.id))
        }
        if source.type.isCloudDrive,
           let oauth = oauthCredentialFromKeychain(sourceID: source.id) {
            if oauth.token?.isEmpty == false { cred.token = oauth.token }
            if oauth.refreshToken?.isEmpty == false { cred.refreshToken = oauth.refreshToken }
            if oauth.clientID?.isEmpty == false { cred.clientID = oauth.clientID }
            if oauth.clientSecret?.isEmpty == false { cred.clientSecret = oauth.clientSecret }
            for (key, value) in oauth.extra where !value.isEmpty {
                cred.extra[key] = value
            }
        }
        if source.type == .fnMusic,
           cred.extra[FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey]?.isEmpty != false {
            let accessCode = local?.accessCode
                ?? keychainPassword(
                    account: FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: source.id)
                )
            if let accessCode, !accessCode.isEmpty {
                cred.extra[FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey] = accessCode
            }
        }
        if let relay = bundle?.relay, RelayStreamResolver.relayTypes.contains(source.type) {
            cred.extra["relay_host"] = relay.host
            cred.extra["relay_port"] = String(relay.port)
            cred.extra["relay_token"] = relay.token
        }
        return cred
    }

    /// 是否已有 CloudTokenManager 格式的 OAuth 凭据。成功刷新后优先更新同一条
    /// synchronizable 记录；若当前设备暂时无法写 iCloud Keychain，则安全回退本地项。
    static func hasSynchronizableOAuthCredential(sourceID: String) -> Bool {
        guard case .found(let data) = lookupCloudKeychain(
            account: CloudCredentialStorageKeyPolicy.tokenKey(sourceID: sourceID),
            synchronizable: true
        ),
        let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else {
            return false
        }
        return !tokens.accessToken.isEmpty || tokens.refreshToken?.isEmpty == false
    }

    @discardableResult
    static func saveOAuthRefresh(
        sourceID: String,
        refresh: CloudCredentialRefresh,
        synchronizable: Bool
    ) -> Bool {
        guard let accessToken = refresh.credential.token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else { return false }
        let existing = oauthTokensFromKeychain(sourceID: sourceID)
        var extra = existing?.extra ?? [:]
        for (key, value) in refresh.credential.extra where !value.isEmpty {
            extra[key] = value
        }
        let tokens = OAuthTokens(
            accessToken: accessToken,
            refreshToken: refresh.credential.refreshToken?.isEmpty == false
                ? refresh.credential.refreshToken
                : existing?.refreshToken,
            expiresAt: refresh.expiresAt ?? existing?.expiresAt,
            tokenType: refresh.tokenType ?? existing?.tokenType,
            extra: extra.isEmpty ? nil : extra
        )
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        let account = CloudCredentialStorageKeyPolicy.tokenKey(sourceID: sourceID)
        if synchronizable,
           upsertCloudKeychain(data: data, account: account, synchronizable: true) {
            // 查询时同步项本来就优先；删除过期本地副本可避免后续 entitlement
            // 异常时回退到已经失效的轮换 token。
            deleteCloudKeychain(account: account, synchronizable: false)
            return true
        }
        return upsertCloudKeychain(data: data, account: account, synchronizable: false)
    }

    private static func oauthCredentialFromKeychain(sourceID: String) -> SourceCredential? {
        let tokens = oauthTokensFromKeychain(sourceID: sourceID)
        let appCredentials: OAuthAppCredentials? = cloudKeychainData(
            account: CloudCredentialStorageKeyPolicy.appCredentialsKey(sourceID: sourceID)
        ).flatMap { try? JSONDecoder().decode(OAuthAppCredentials.self, from: $0) }
        guard tokens != nil || appCredentials != nil else { return nil }
        return SourceCredential(
            token: tokens?.accessToken,
            refreshToken: tokens?.refreshToken,
            clientID: appCredentials?.clientId,
            clientSecret: appCredentials?.clientSecret,
            extra: tokens?.extra ?? [:]
        )
    }

    private static func oauthTokensFromKeychain(sourceID: String) -> OAuthTokens? {
        cloudKeychainData(
            account: CloudCredentialStorageKeyPolicy.tokenKey(sourceID: sourceID)
        ).flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }
    }

    /// 同步项为权威值；只有确实不存在或本机不支持 synchronizable 属性时才读本地回退。
    private static func cloudKeychainData(account: String) -> Data? {
        switch lookupCloudKeychain(account: account, synchronizable: true) {
        case .found(let data):
            return data
        case .temporarilyUnavailable:
            return nil
        case .failed(let status) where status != errSecMissingEntitlement:
            return nil
        case .notFound, .failed:
            break
        }
        guard case .found(let data) = lookupCloudKeychain(
            account: account,
            synchronizable: false
        ) else { return nil }
        return data
    }

    private static func lookupCloudKeychain(
        account: String,
        synchronizable: Bool
    ) -> KeychainDataLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudCredentialService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .temporarilyUnavailable
        default:
            return .failed(status)
        }
    }

    private static func upsertCloudKeychain(
        data: Data,
        account: String,
        synchronizable: Bool
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudCredentialService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
        ]
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let inserted = SecItemAdd(add as CFDictionary, nil)
        if inserted == errSecSuccess { return true }
        if inserted == errSecDuplicateItem {
            return SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return false
    }

    @discardableResult
    private static func deleteCloudKeychain(account: String, synchronizable: Bool) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudCredentialService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: (synchronizable ? kCFBooleanTrue : kCFBooleanFalse) as Any,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - TV 本地手动输入凭据(本地钥匙串,不同步)
    //
    // 存在 **本地(non-synchronizable)钥匙串** 的独立 account 命名空间下,与同步读取
    // (上面的 keychainPassword)彻底隔离:既不会被 iCloud 覆盖,也总能压过 bundle。
    // 用户名 + 密码打包成一个 JSON blob 存一条目。

    private static func localAccount(_ sourceID: String) -> String { "tv-local-cred." + sourceID }

    private struct LocalCred: Codable {
        var u: String
        var p: String
        var a: String?
    }

    @discardableResult
    static func saveLocalCredential(
        sourceID: String,
        username: String,
        password: String,
        accessCode: String? = nil
    ) -> Bool {
        let account = localAccount(sourceID)
        let preservedAccessCode = accessCode
            ?? loadLocalCredential(sourceID: sourceID)?.accessCode
        guard let data = try? JSONEncoder().encode(
            LocalCred(u: username, p: password, a: preservedAccessCode)
        ) else {
            return false
        }
        return upsert(data: data, account: account)
    }

    static func loadLocalCredential(
        sourceID: String
    ) -> (username: String, password: String, accessCode: String?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: localAccount(sourceID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let cred = try? JSONDecoder().decode(LocalCred.self, from: data) else {
            return nil
        }
        return (cred.u, cred.p, cred.a)
    }

    @discardableResult
    static func clearLocalCredential(sourceID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: localAccount(sourceID),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func hasLocalCredential(sourceID: String) -> Bool {
        if let c = loadLocalCredential(sourceID: sourceID), !c.password.isEmpty { return true }
        return false
    }

    /// 是否能从同步 iCloud 钥匙串读到该源密码(供 UI 判断「有无可用凭据」)。
    static func hasSyncedPassword(sourceID: String) -> Bool {
        keychainPassword(account: sourceID) != nil
    }

    // MARK: - 局域网直传凭据包(本地钥匙串,跨重启保留)
    //
    // LAN 扫码直传(`primuse://pair`)绕开 iCloud,收到的整包凭据存这里,使「不同
    // Apple ID」的 TV 在重启后(CloudKit 兜底取不到时)仍有凭据可播。整包 JSON 存
    // 一条非同步钥匙串项,与同步读取彻底隔离。

    private static let pairedBundleAccount = "tv-paired-bundle"

    @discardableResult
    static func savePairedBundle(_ bundle: CredentialBundle) -> Bool {
        guard CredentialBundlePolicy.writeAction(for: bundle) == .saveRecord else {
            return clearPairedBundle()
        }
        guard let data = try? bundle.jsonData() else { return false }
        return upsert(data: data, account: pairedBundleAccount)
    }

    /// 先尝试原地更新，只有条目不存在时才新增。写入失败不会删除旧值，避免
    /// 临时 Keychain 错误把数小时前仍可用的密码一并清掉。
    private static func upsert(data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        // 极小概率下另一个写入者在 update 与 add 之间创建了条目；重试更新即可。
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func clearPairedBundle() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: pairedBundleAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func loadPairedBundle() -> CredentialBundle? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: pairedBundleAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return CredentialBundle.decode(data)
    }

    /// service = `PrimuseConstants.keychainServiceName`,account = sourceID。
    /// `kSecAttrSynchronizableAny` 同时匹配本地项与 iCloud 钥匙串项。
    private static func keychainPassword(account: String) -> String? {
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
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
#endif
