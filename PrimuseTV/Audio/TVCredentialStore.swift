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
    /// 凭据来源链:① 用户在 **TV 本地手动输入** 的凭据(最高优先,跨设备 session 不通用时
    /// 直接在 TV 登录)② 经 CloudKit 加密同步下来的凭据包 ③ 可同步 iCloud 钥匙串(兜底)。
    /// 中继类型还会附上 iPhone 中继端点(放 extra,供 RelayStreamResolver 拼 URL)。
    static func credential(for source: MusicSource, bundle: CredentialBundle?) -> SourceCredential {
        var cred: SourceCredential
        if source.authType == .none {
            // 显式访客模式优先级最高：即便 TV 本地、凭据包或同步钥匙串里还留有
            // 旧密码，也不能把它重新附加到匿名 SMB/WebDAV/FTP 请求上。
            cred = SourceCredential()
        } else if let local = loadLocalCredential(sourceID: source.id), !local.password.isEmpty {
            // 本地输入优先:用户在 TV 上为该源亲手登录过,胜过同步过来的(可能不通用的)凭据。
            cred = SourceCredential(username: local.username.isEmpty ? source.username : local.username,
                                    password: local.password)
        } else if let entry = bundle?.entries[source.id], !entry.isEmpty {
            cred = entry.toCredential(defaultUsername: source.username)
        } else {
            cred = SourceCredential(username: source.username, password: keychainPassword(account: source.id))
        }
        if let relay = bundle?.relay, RelayStreamResolver.relayTypes.contains(source.type) {
            cred.extra["relay_host"] = relay.host
            cred.extra["relay_port"] = String(relay.port)
            cred.extra["relay_token"] = relay.token
        }
        return cred
    }

    // MARK: - TV 本地手动输入凭据(本地钥匙串,不同步)
    //
    // 存在 **本地(non-synchronizable)钥匙串** 的独立 account 命名空间下,与同步读取
    // (上面的 keychainPassword)彻底隔离:既不会被 iCloud 覆盖,也总能压过 bundle。
    // 用户名 + 密码打包成一个 JSON blob 存一条目。

    private static func localAccount(_ sourceID: String) -> String { "tv-local-cred." + sourceID }

    private struct LocalCred: Codable { var u: String; var p: String }

    static func saveLocalCredential(sourceID: String, username: String, password: String) {
        let account = localAccount(sourceID)
        guard let data = try? JSONEncoder().encode(LocalCred(u: username, p: password)) else { return }
        // 先删后加,保证覆盖。
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadLocalCredential(sourceID: String) -> (username: String, password: String)? {
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
        return (cred.u, cred.p)
    }

    static func clearLocalCredential(sourceID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: localAccount(sourceID),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
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

    static func savePairedBundle(_ bundle: CredentialBundle) {
        guard let data = try? bundle.jsonData() else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PrimuseConstants.keychainServiceName,
            kSecAttrAccount as String: pairedBundleAccount,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
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
