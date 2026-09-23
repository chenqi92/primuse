import Foundation

/// Describes how an interactive cloud authorization should treat an existing
/// browser sign-in. The choice is intentionally separate from token storage:
/// every MusicSource still owns its own Keychain records.
public enum CloudOAuthLoginIntent: Sendable, Equatable {
    case standard
    case useSignedInAccount
    case differentAccount
}

public enum CloudOAuthAccountSelectionPolicy {
    /// A different-account flow must not inherit Safari's authentication
    /// cookies when the platform can provide a private authentication session.
    public static func prefersEphemeralSession(for intent: CloudOAuthLoginIntent) -> Bool {
        intent == .differentAccount
    }

    /// Provider-supported authorization parameters. Providers that do not
    /// document an account-selection parameter rely on the ephemeral session
    /// on iOS and on their own account switcher on macOS.
    public static func authorizationParameters(
        provider: MusicSourceType,
        intent: CloudOAuthLoginIntent
    ) -> [String: String] {
        var parameters: [String: String] = [:]

        if provider == .googleDrive {
            parameters["access_type"] = "offline"
            parameters["include_granted_scopes"] = "true"
        }

        switch (provider, intent) {
        case (.baiduPan, .differentAccount):
            parameters["force_login"] = "1"
        case (.googleDrive, .useSignedInAccount):
            parameters["prompt"] = "consent"
        case (.googleDrive, .differentAccount):
            parameters["prompt"] = "select_account consent"
        case (.oneDrive, .differentAccount):
            parameters["prompt"] = "select_account"
        case (.dropbox, .differentAccount):
            parameters["force_reauthentication"] = "true"
            parameters["force_reapprove"] = "true"
        case (.aliyunDrive, .differentAccount):
            parameters["prompt"] = "login"
        default:
            break
        }

        return parameters
    }

    /// Applies provider parameters without allowing duplicate query keys.
    /// Keeping this merge pure makes the exact outgoing OAuth request
    /// independently testable from the browser session.
    public static func applyingAuthorizationParameters(
        to queryItems: [URLQueryItem],
        provider: MusicSourceType,
        intent: CloudOAuthLoginIntent
    ) -> [URLQueryItem] {
        var result = queryItems
        let parameters = authorizationParameters(provider: provider, intent: intent)
        for name in parameters.keys.sorted() {
            result.removeAll { $0.name == name }
            result.append(URLQueryItem(name: name, value: parameters[name]))
        }
        return result
    }
}

/// Keeps the Keychain namespace explicitly tied to a mount UUID. Two sources
/// of the same provider must never resolve to the same token or app-secret key.
public enum CloudCredentialStorageKeyPolicy {
    public static func tokenKey(sourceID: String) -> String {
        "cloud_tokens_\(sourceID)"
    }

    public static func appCredentialsKey(sourceID: String) -> String {
        "cloud_creds_\(sourceID)"
    }
}

/// 同一个云盘账号名下有多份挂载(旧版本每走一次 OAuth 就新建一份 `MusicSource`)时，
/// 迁移只留一份(keeper)，其余软删除、歌曲改指向 keeper。哪一份留下必须在每台设备
/// 上算出同一个答案，否则两台设备各留一份、各删对方留下的那份，最后一份都不剩。
///
/// 因此只按 `id` 字典序取最小，别的字段都不能用：
/// - `lastScannedAt` 不进 CloudKit 载荷(`SyncableSource` 会抹掉)，每台设备各有各的值；
/// - `modifiedAt` 会被迁移自己(写 `cloudAccountID`)和任何编辑抬高，一台设备写完、
///   另一台再算答案就变了；
/// - `cloudAccountID`「谁已经被选过」也是会变、会晚到的状态：一边看到它已挂上账号、
///   另一边还没收到，两边就会选出不同的一份；
/// - `id` 是建源时生成的 UUID 字符串，随载荷同步、之后永不改变。
///
/// 收敛论证(两台设备各自看到的成员集合可以不同)：互删要求各自删掉对方留下的那份，
/// 也就是各自都看得见对方的 keeper。对方的 keeper 是对方视野里 id 最小的，我方看得见
/// 它，我方 keeper 的 id 就不大于它；对称地，对方 keeper 的 id 也不大于我方的 —— 两者
/// 只能是同一份，而 keeper 自己从不会被删。被删掉的成员随墓碑同步到别处后不再参与
/// 分组，后跑的设备只会看到更少的候选，不会再做出不同的选择。
public enum CloudAccountMountKeeperPolicy {
    /// 结果与输入顺序无关；空输入返回 nil。
    public static func keeperID(among mountIDs: [String]) -> String? {
        mountIDs.min()
    }
}

/// Delays OAuth token and connection-stage credential writes until interactive
/// authorization has succeeded. A cancellation or provider error exits before
/// the commit closure, preserving every existing source credential.
public enum CloudOAuthCredentialTransaction {
    @discardableResult
    @MainActor
    public static func authorizeThenCommit<Value>(
        authorize: () async throws -> Value,
        commit: (Value) async throws -> Void
    ) async throws -> Value {
        let authorizedValue = try await authorize()
        try Task.checkCancellation()
        try await commit(authorizedValue)
        return authorizedValue
    }
}
