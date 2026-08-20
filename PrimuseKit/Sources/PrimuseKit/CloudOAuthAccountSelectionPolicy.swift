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
            parameters["trigger_onepick"] = "true"
            parameters["allow_folder_selection"] = "true"
            parameters["allow_multiple"] = "true"
        }

        switch (provider, intent) {
        case (.baiduPan, .differentAccount):
            parameters["force_login"] = "1"
        case (.googleDrive, .standard), (.googleDrive, .useSignedInAccount):
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
