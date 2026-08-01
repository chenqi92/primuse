import Foundation

/// 一个音乐源的凭据(按 sourceID 归档)。密码 / OAuth token / client 密钥都可能有,
/// 取决于源类型。经 CloudKit `encryptedValues` 端到端加密同步到 Apple TV。
public struct CredentialEntry: Codable, Sendable, Equatable {
    public var username: String?
    public var password: String?
    public var token: String?
    public var refreshToken: String?
    public var clientID: String?
    public var clientSecret: String?
    public var extra: [String: String]

    public init(username: String? = nil, password: String? = nil, token: String? = nil,
                refreshToken: String? = nil, clientID: String? = nil, clientSecret: String? = nil,
                extra: [String: String] = [:]) {
        self.username = username
        self.password = password
        self.token = token
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.extra = extra
    }

    public var isEmpty: Bool {
        (password ?? "").isEmpty && (token ?? "").isEmpty && (refreshToken ?? "").isEmpty
    }

    public func toCredential(defaultUsername: String?) -> SourceCredential {
        SourceCredential(username: username ?? defaultUsername, password: password, token: token,
                         refreshToken: refreshToken, clientID: clientID, clientSecret: clientSecret, extra: extra)
    }
}

/// iPhone 局域网中继端点(Phase 3:本地/SMB/SFTP/NFS/WebDAV 等不可直连源经此播放)。
/// 由 iOS 中继服务启动时写入,随凭据包加密同步;TV 据此拼中继 URL。
public struct RelayEndpoint: Codable, Sendable, Equatable {
    public var host: String     // iPhone 局域网 IP
    public var port: Int
    public var token: String    // 会话令牌,中继服务校验
    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }
}

/// 全部源的凭据集合,作为一个整体加密同步。
public struct CredentialBundle: Codable, Sendable, Equatable {
    public var version: Int
    public var entries: [String: CredentialEntry]   // sourceID → 凭据
    public var relay: RelayEndpoint?                 // iPhone 中继端点(可选)

    public init(version: Int = 1, entries: [String: CredentialEntry] = [:], relay: RelayEndpoint? = nil) {
        self.version = version
        self.entries = entries
        self.relay = relay
    }

    public func jsonData() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> CredentialBundle? {
        try? JSONDecoder().decode(CredentialBundle.self, from: data)
    }

    public func credential(for sourceID: String, defaultUsername: String?) -> SourceCredential? {
        entries[sourceID]?.toCredential(defaultUsername: defaultUsername)
    }
}

/// Credential snapshots are whole-bundle values. Keep the destructive choices
/// in a pure policy so CloudKit and tvOS apply the same rules:
///
/// - an empty local bundle removes local persistence; CloudKit writes the same
///   value as a change-tagged empty tombstone because record-ID-only deletion
///   cannot protect a credential concurrently added by another device;
/// - downloaded bundles merge with TV-local credentials, but entries for
///   sources that no longer exist (or are soft-deleted) are pruned;
/// - an unavailable download is represented by `nil` at the call site and must
///   never be converted into an empty authoritative bundle.
public enum CredentialSnapshotWriteAction: Sendable, Equatable {
    case saveRecord
    case deleteRecord
}

public enum CredentialBundlePolicy {
    public static func writeAction(for bundle: CredentialBundle) -> CredentialSnapshotWriteAction {
        bundle.entries.isEmpty && bundle.relay == nil ? .deleteRecord : .saveRecord
    }

    public static func pruning(
        _ bundle: CredentialBundle,
        activeSourceIDs: Set<String>
    ) -> CredentialBundle {
        var result = bundle
        result.entries = result.entries.filter { activeSourceIDs.contains($0.key) }
        return result
    }

    /// Incoming Cloud/LAN data wins for matching sources while current entries
    /// remain available for active TV-only sources that are absent upstream.
    public static func merging(
        current: CredentialBundle,
        incoming: CredentialBundle?,
        activeSourceIDs: Set<String>
    ) -> CredentialBundle {
        var result = current
        if let incoming {
            result.version = max(current.version, incoming.version)
            for (sourceID, entry) in incoming.entries {
                result.entries[sourceID] = entry
            }
            if let relay = incoming.relay {
                result.relay = relay
            }
        }
        return pruning(result, activeSourceIDs: activeSourceIDs)
    }

    public static func removing(
        sourceID: String,
        from bundle: CredentialBundle
    ) -> CredentialBundle {
        removing(sourceIDs: [sourceID], relayIfMatching: nil, from: bundle)
    }

    /// Replays a previously observed removal against the conflict winner. Only
    /// source IDs present in the original read are removed, so a credential
    /// concurrently added under a different ID survives. Relay cleanup is
    /// likewise conditional on the server still containing the observed value.
    public static func removing(
        sourceIDs: Set<String>,
        relayIfMatching observedRelay: RelayEndpoint?,
        from bundle: CredentialBundle
    ) -> CredentialBundle {
        var result = bundle
        for sourceID in sourceIDs {
            result.entries.removeValue(forKey: sourceID)
        }
        if let observedRelay, result.relay == observedRelay {
            result.relay = nil
        }
        return result
    }
}

/// Durable intent captured when a source becomes a tombstone. The source row
/// may be removed locally before the delayed cleanup runs, so the intent keeps
/// the complete tombstone needed by snapshot synchronization as well as the two
/// independently retryable remote operations.
public struct SourceCloudCleanupIntent: Codable, Equatable, Sendable {
    public var tombstone: MusicSource
    public var needsSourceSnapshotUpload: Bool
    public var needsCredentialRemoval: Bool

    public init(
        tombstone: MusicSource,
        needsSourceSnapshotUpload: Bool = true,
        needsCredentialRemoval: Bool = true
    ) {
        self.tombstone = tombstone
        self.needsSourceSnapshotUpload = needsSourceSnapshotUpload
        self.needsCredentialRemoval = needsCredentialRemoval
    }
}

/// Pure state transitions for the persisted source-cleanup journal.
public enum SourceCloudCleanupPolicy {
    /// Coalesces repeated soft/permanent-delete signals without losing a newer
    /// tombstone or a still-pending half of the remote cleanup.
    public static func coalescing(
        current: SourceCloudCleanupIntent?,
        tombstone: MusicSource
    ) -> SourceCloudCleanupIntent? {
        guard tombstone.isDeleted else { return current }
        guard let current else {
            return SourceCloudCleanupIntent(tombstone: tombstone)
        }

        var result = current
        if sourceClock(tombstone) >= sourceClock(current.tombstone) {
            result.tombstone = tombstone
        }
        result.needsSourceSnapshotUpload = true
        result.needsCredentialRemoval = true
        return result
    }

    /// A newer restore supersedes an older delete intent. A missing local row
    /// does not: that is the normal permanent-delete race this journal covers.
    public static func isSuperseded(
        _ intent: SourceCloudCleanupIntent,
        by currentSource: MusicSource?
    ) -> Bool {
        guard let currentSource, !currentSource.isDeleted else { return false }
        return sourceClock(currentSource) > sourceClock(intent.tombstone)
    }

    /// Applies independently observed remote results. Returning nil means both
    /// durable operations completed and the journal row may be removed.
    public static func applying(
        sourceSnapshotUploaded: Bool,
        credentialRemoved: Bool,
        to intent: SourceCloudCleanupIntent
    ) -> SourceCloudCleanupIntent? {
        var result = intent
        if sourceSnapshotUploaded {
            result.needsSourceSnapshotUpload = false
        }
        if credentialRemoved {
            result.needsCredentialRemoval = false
        }
        return result.needsSourceSnapshotUpload || result.needsCredentialRemoval
            ? result
            : nil
    }

    private static func sourceClock(_ source: MusicSource) -> Date {
        max(source.modifiedAt, source.deletedAt ?? .distantPast)
    }
}
