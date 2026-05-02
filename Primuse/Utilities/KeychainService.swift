import Foundation
import Security
import PrimuseKit

enum KeychainService {
    static func setPassword(_ password: String, for account: String) {
        let data = Data(password.utf8)

        // Delete any existing entry (both synchronizable and non-synchronizable variants).
        deletePassword(for: account)

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
            // -25300 = item not found,这是正常情况(从未保存过),不打日志。
            // 其他状态码代表权限/参数问题,值得记录。
            if status != errSecItemNotFound {
                plog("⚠️ Keychain getPassword status=\(status) account=\(account)")
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for account: String) {
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
