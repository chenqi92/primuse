import Foundation
import PrimuseKit

/// Built-in OAuth credentials for cloud drive platforms.
/// For platforms where we have official developer credentials,
/// users can connect without providing their own client_id.
enum BuiltInCloudCredentials {

    // MARK: - Baidu Pan (百度网盘)
    // Registered at: pan.baidu.com/union
    // Client credentials are injected at build time via xcconfig so they don't
    // live in tracked source files.
    private static let baiduClientIdKey = "PrimuseBaiduClientID"
    private static let baiduClientSecretKey = "PrimuseBaiduClientSecret"
    private static let dropboxClientIdKey = "PrimuseDropboxClientID"
    private static let dropboxClientSecretKey = "PrimuseDropboxClientSecret"
    private static let googleClientIdKey = "PrimuseGoogleClientID"
    private static let oneDriveClientIdKey = "PrimuseOneDriveClientID"

    // MARK: - Query

    /// Returns built-in credentials for a given source type, if available.
    static func credentials(for type: MusicSourceType) -> (clientId: String, clientSecret: String?)? {
        switch type {
        case .baiduPan:
            guard let clientId = stringValue(forInfoDictionaryKey: baiduClientIdKey) else {
                return nil
            }
            return (
                clientId,
                stringValue(forInfoDictionaryKey: baiduClientSecretKey)
            )
        case .dropbox:
            guard let clientId = stringValue(forInfoDictionaryKey: dropboxClientIdKey) else {
                return nil
            }
            return (
                clientId,
                stringValue(forInfoDictionaryKey: dropboxClientSecretKey)
            )
        case .googleDrive:
            guard let clientId = stringValue(forInfoDictionaryKey: googleClientIdKey) else {
                return nil
            }
            return (clientId, nil)
        case .oneDrive:
            guard let clientId = stringValue(forInfoDictionaryKey: oneDriveClientIdKey) else {
                return nil
            }
            return (clientId, nil)
        // Add more as you register:
        default:
            return nil
        }
    }

    /// Whether a source type has built-in credentials (no user setup needed).
    static func hasBuiltIn(for type: MusicSourceType) -> Bool {
        credentials(for: type) != nil
    }

    private static func stringValue(forInfoDictionaryKey key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
