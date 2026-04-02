import Foundation
import Security

/// Manages OAuth tokens for cloud drive sources, storing securely in Keychain.
actor CloudTokenManager {
    private let sourceID: String

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

    // MARK: - Public API

    func getTokens() -> Tokens? {
        guard let data = keychainRead(key: "cloud_tokens_\(sourceID)"),
              let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else {
            return nil
        }
        return tokens
    }

    func saveTokens(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        keychainWrite(key: "cloud_tokens_\(sourceID)", data: data)
    }

    func deleteTokens() {
        keychainDelete(key: "cloud_tokens_\(sourceID)")
    }

    func getAccessToken() -> String? {
        getTokens()?.accessToken
    }

    // MARK: - App Credentials (user-provided client_id/secret)

    struct AppCredentials: Codable, Sendable {
        var clientId: String
        var clientSecret: String?
    }

    func getAppCredentials() -> AppCredentials? {
        guard let data = keychainRead(key: "cloud_creds_\(sourceID)"),
              let creds = try? JSONDecoder().decode(AppCredentials.self, from: data) else {
            return nil
        }
        return creds
    }

    func saveAppCredentials(_ creds: AppCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        keychainWrite(key: "cloud_creds_\(sourceID)", data: data)
    }

    // MARK: - Keychain helpers

    private func keychainRead(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.welape.primuse.cloud",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func keychainWrite(key: String, data: Data) {
        keychainDelete(key: key) // Remove existing
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.welape.primuse.cloud",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.welape.primuse.cloud",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
