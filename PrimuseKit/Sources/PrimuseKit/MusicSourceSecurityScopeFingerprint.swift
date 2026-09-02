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
        let sourceIdentity = MusicSourceScopeFingerprint.make(
            for: source,
            directories: nil,
            includeSourceID: true
        )
        let digest = SHA256.hash(
            data: Data("\(sourceIdentity)\u{1E}\(revisionIdentity)".utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
