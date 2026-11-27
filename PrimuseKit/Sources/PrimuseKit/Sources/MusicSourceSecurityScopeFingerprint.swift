import CryptoKit
import Foundation

/// Combines a source's account/endpoint identity with its credential epoch.
/// The epoch, rather than credential material, invalidates trusted transport
/// and cache state after a credential change.
public enum MusicSourceSecurityScopeFingerprint {
    public static func make(
        for source: MusicSource,
        revision: UInt64
    ) -> String {
        make(for: source, revisionIdentity: String(revision))
    }

    public static func make(
        for source: MusicSource,
        revisionIdentity: String
    ) -> String {
        // 每次取连接器都要核一遍指纹, 补读、播放、缓存一首歌就要取好几次。源配置
        // 不变时结果也不变, 按源记住上一次的输入和结果, 免得每次都重新拼串、算哈希。
        if let cached = memoLock.withLock({ memo[source.id] }),
           cached.revisionIdentity == revisionIdentity,
           cached.source == source {
            return cached.fingerprint
        }
        let sourceIdentity = MusicSourceScopeFingerprint.make(
            for: source,
            directories: nil,
            includeSourceID: true
        )
        let digest = SHA256.hash(
            data: Data("\(sourceIdentity)\u{1E}\(revisionIdentity)".utf8)
        )
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        memoLock.withLock {
            if memo.count >= 64 { memo.removeAll(keepingCapacity: true) }
            memo[source.id] = MemoEntry(
                source: source,
                revisionIdentity: revisionIdentity,
                fingerprint: fingerprint
            )
        }
        return fingerprint
    }

    private struct MemoEntry {
        let source: MusicSource
        let revisionIdentity: String
        let fingerprint: String
    }

    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: [String: MemoEntry] = [:]

    /// Same credential epoch, same content root, but blind to the address used
    /// to reach it. Rows that differ only by an alternate route share this
    /// value, which is what lets such an edit rebuild connectors without
    /// discarding trusted offline bytes.
    public static func credentialScoped(
        for source: MusicSource,
        revisionIdentity: String
    ) -> String {
        let credentialIdentity = MusicSourceScopeFingerprint.credentialScope(for: source)
        let digest = SHA256.hash(
            data: Data("\(credentialIdentity)\u{1E}\(revisionIdentity)".utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
