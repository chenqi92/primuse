import Foundation
import Testing
@testable import PrimuseKit

struct MusicSourceSecurityScopeFingerprintTests {
    @Test func credentialRevisionChangesSecurityScopeWithoutCredentialMaterial() {
        let source = makeSource()

        let first = MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revision: 41
        )
        let repeated = MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revision: 41
        )
        let rotated = MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revision: 42
        )

        #expect(first == repeated)
        #expect(first != rotated)
        #expect(first.count == 64)
        #expect(first == "87a60ac7fb36c8fe135bf731c75f7a81da47515974b63eea1e3f47cb6e28eb95")
    }

    @Test func displayAndScanStateDoNotInvalidateSecurityScope() {
        let source = makeSource()
        var presentationUpdate = source
        presentationUpdate.name = "Renamed source"
        presentationUpdate.songCount = 9_999
        presentationUpdate.lastScannedAt = Date(timeIntervalSince1970: 2_000)
        presentationUpdate.modifiedAt = Date(timeIntervalSince1970: 3_000)

        #expect(
            MusicSourceSecurityScopeFingerprint.make(for: source, revision: 7)
                == MusicSourceSecurityScopeFingerprint.make(
                    for: presentationUpdate,
                    revision: 7
                )
        )
    }

    @Test func sourceAccountEndpointAndFailClosedEpochChangeSecurityScope() {
        let source = makeSource()
        let original = MusicSourceSecurityScopeFingerprint.make(
            for: source,
            revision: 7
        )
        var moved = source
        moved.host = "replacement.example.com"
        var differentAccount = source
        differentAccount.username = "another-user"
        var differentSource = source
        differentSource.id = "replacement-source"

        #expect(original != MusicSourceSecurityScopeFingerprint.make(for: moved, revision: 7))
        #expect(
            original != MusicSourceSecurityScopeFingerprint.make(
                for: differentAccount,
                revision: 7
            )
        )
        #expect(
            original != MusicSourceSecurityScopeFingerprint.make(
                for: differentSource,
                revision: 7
            )
        )
        #expect(
            MusicSourceSecurityScopeFingerprint.make(
                for: source,
                revisionIdentity: "unavailable-process-a"
            ) != MusicSourceSecurityScopeFingerprint.make(
                for: source,
                revisionIdentity: "unavailable-process-b"
            )
        )
    }

    private func makeSource() -> MusicSource {
        MusicSource(
            id: "security-source",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            port: 4_533,
            useSsl: true,
            username: "listener",
            basePath: "/music"
        )
    }
}
