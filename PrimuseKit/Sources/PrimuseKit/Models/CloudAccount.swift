import CryptoKit
import Foundation
import GRDB

/// Represents an OAuth-identified cloud-drive account (Baidu / Aliyun /
/// Dropbox / OneDrive / Google Drive). One CloudAccount can back multiple
/// `MusicSource` mounts — re-connecting the same Baidu account from the
/// same device, or adding two scan roots under the same Dropbox account,
/// share a single CloudAccount entity rather than spawning duplicates
/// (which is how the previous "5 Baidu sources for one account" bug
/// happened).
///
/// `id` is derived deterministically from `(provider, accountUID)` via
/// `deriveID(...)`. Same account on different devices → same id, so
/// CloudKit naturally dedups instead of throwing OpLockFailed on every
/// sync push.
public struct CloudAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// Which OAuth provider issued the identity. Limited to types in
    /// `MusicSourceType.isCloudDrive`.
    public var provider: MusicSourceType
    /// Provider-issued stable user identifier — e.g. Baidu `uk`,
    /// Dropbox `account_id`, Google OIDC `sub`. The connector returns
    /// this from `OAuthCloudSource.accountIdentifier()`.
    public var accountUID: String
    /// Optional UI niceties — populated lazily by the OAuth flow when
    /// available, never load-bearing for identity.
    public var displayName: String?
    public var avatarURL: String?
    public var createdAt: Date
    /// Wall-clock of the most recent edit. Drives CloudKit LWW conflict
    /// resolution on this record type.
    public var modifiedAt: Date
    /// Soft-delete flag. A user "signing out" of a cloud account marks
    /// it deleted; the 30-day prune sweeps it for good. While deleted,
    /// dependent `MusicMount` rows are also hidden.
    public var isDeleted: Bool
    public var deletedAt: Date?

    public init(
        id: String,
        provider: MusicSourceType,
        accountUID: String,
        displayName: String? = nil,
        avatarURL: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isDeleted: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.accountUID = accountUID
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }

    /// Derive the stable account record id from `(provider, accountUID)`.
    /// SHA-256 → first 16 hex chars (8 bytes) — same shape as `Song.id`,
    /// keeps record identifiers visually consistent across the schema.
    /// Same account on every device produces the same id.
    public static func deriveID(provider: MusicSourceType, accountUID: String) -> String {
        let input = "\(provider.rawValue):\(accountUID)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

extension CloudAccount: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "cloudAccounts" }
}
